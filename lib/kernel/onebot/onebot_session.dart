/// L2 协议内核：OneBot 会话实现
///
/// 把三个下层组件装配成 [Session]：
///
/// ```
///   OneBotClient          传输（WS + echo 关联 + 事件 + 重连）
///        +
///   BackendProfileRegistry 归一化（各后端字段名差异）
///        +
///   Segment / Chat / ChatMessage   L3 数据对象
///        ↓
///   OneBotSession         会话（登录 → 会话列表 → 历史 → 收发 → 撤回）
/// ```
///
/// ## 握手顺序（有个鸡生蛋问题）
///
/// 适配表是由 `get_version_info` 的 `app_name` **选出来的**，所以第一次探版本
/// 不能用表——必须先发一个硬编码的 `get_version_info`：
///
/// ```
///   connect()
///     ├─ client.connect()
///     ├─ client.call('get_version_info')   ← 硬编码，此时还没有表
///     ├─ profiles.resolveOrDefault(appName) ← 选表
///     └─ _callSpec('login_info')            ← 之后一律走表
/// ```
///
/// Stapxs 遇到同样问题时是"拿到 app_name 之前先用硬编码兜底表"，本实现
/// 用一个裸调用把这个问题消掉，后续全部走表。
///
/// 本文件是纯 Dart。
library;

import 'dart:async';

import '../../client_api/objects.dart';
import '../../client_api/segment.dart';
import '../../client_api/session.dart';
import 'backend_profile.dart';
import 'onebot_client.dart';

/// [Session] 的 OneBot 11 实现。
class OneBotSession implements Session {
  /// 传输层客户端。
  final OneBotClient client;

  /// 后端适配表集合。
  final BackendProfileRegistry profiles;

  /// 日志回调。
  final void Function(String level, String message, [Object? detail])? onLog;

  final _events = StreamController<SessionEvent>.broadcast();
  StreamSubscription<OneBotEvent>? _sub;

  BackendProfile? _profile;
  AccountInfo? _account;
  SessionState _state = SessionState.disconnected;
  bool _disposed = false;

  OneBotSession({
    required this.client,
    required this.profiles,
    this.onLog,
  });

  // -- Session 契约 ---------------------------------------------------------

  @override
  SessionState get state => _state;

  @override
  Stream<SessionEvent> get events => _events.stream;

  @override
  AccountInfo? get account => _account;

  @override
  String? get backendName => _profile?.name;

  /// 当前生效的适配表（诊断用）。
  BackendProfile? get profile => _profile;

  @override
  bool supports(String capability) => _profile?.spec(capability) != null;

  @override
  Future<void> connect() async {
    if (_disposed) throw const SessionException('会话已释放');
    if (_state == SessionState.ready) return;

    _sub ??= client.events.listen(_onTransportEvent);
    _setState(SessionState.connecting);

    try {
      await client.connect();

      // 1) 探版本。此时还没有适配表，必须用硬编码 action。
      final version = await client.callMap('get_version_info');
      final appName = version['app_name']?.toString();
      _profile = profiles.resolveOrDefault(appName);

      // 2) 取登录信息（此后一律走表）。
      //    必须经 spec.oneFrom() 归一化：NapCat 返回的是 `user_id`，
      //    逻辑字段名是 `uin`，直接用原始响应会取到空值。
      final loginSpec = _profile?.spec('login_info');
      final login = loginSpec?.oneFrom(await _callSpec('login_info')) ??
          const <String, dynamic>{};
      _account = AccountInfo(
        uin: _str(login['uin']),
        nickname: _str(login['nickname']),
        backendName: appName,
        backendVersion: version['app_version']?.toString(),
        protocolVersion: version['protocol_version']?.toString(),
      );

      _log('info',
          '握手完成：账号=${_account!.uin} 后端=${appName ?? '未知'} 适配表=${_profile?.name}');
      _setState(SessionState.ready, reason: 'backend=${_profile?.name}');
    } on Object catch (e, st) {
      _setState(SessionState.disconnected, reason: 'handshake-failed');
      _emit(SessionFailure(e, st));
      throw SessionException('握手失败：$e', cause: e);
    }
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    await client.close();
    _setState(SessionState.closed);
  }

  @override
  Future<List<Chat>> listChats() async {
    _ensureReady();
    final chats = <Chat>[];

    // 好友
    final friendSpec = _profile?.spec('friend_list');
    if (friendSpec != null) {
      final data = await _callSpec('friend_list');
      for (final item in friendSpec.itemsFrom(data)) {
        final f = friendSpec.itemFrom(item);
        final id = _int(f['user_id']);
        if (id == null) continue;
        chats.add(Chat(
          id: Chat.keyOf(ChatType.private, id),
          title: _pickName(f['remark'], f['nickname'], id),
          type: ChatType.private,
          rawId: id,
        ));
      }
    }

    // 群
    final groupSpec = _profile?.spec('group_list');
    if (groupSpec != null) {
      final data = await _callSpec('group_list');
      for (final item in groupSpec.itemsFrom(data)) {
        final g = groupSpec.itemFrom(item);
        final id = _int(g['group_id']);
        if (id == null) continue;
        chats.add(Chat(
          id: Chat.keyOf(ChatType.group, id),
          title: _pickName(null, g['group_name'], id),
          type: ChatType.group,
          rawId: id,
          memberCount: _int(g['member_count']) ?? 0,
        ));
      }
    }

    _log('info', '会话列表：${chats.length} 个（好友/群）');
    return chats;
  }

  @override
  Future<HistoryPage> fetchHistory(
    String chatId, {
    int count = 20,
    HistoryCursor? before,
  }) async {
    _ensureReady();
    final (isGroup, peerId) = _splitChatId(chatId);

    final spec = _profile?.spec('message_history');
    if (spec == null) throw SessionException('后端 ${_profile?.name} 不支持拉取历史消息');

    final params = <String, dynamic>{
      if (isGroup) 'group_id': peerId else 'user_id': peerId,
      'count': count,
    };
    // 游标：优先用群消息序号（各后端一致支持），其次用 message_id
    if (before?.seq != null) {
      params['message_seq'] = before!.seq;
    } else if (before != null && before.messageId != null) {
      final mid = before.messageId;
      params['message_id'] = _int(mid) ?? mid;
    }

    final data = await _callSpec('message_history', params: params, isPrivate: !isGroup);

    final messages = <ChatMessage>[];
    // 游标要用的群序号来自适配表归一化后的记录，ChatMessage 不承载它，
    // 因此在这里旁路记录一份。
    final seqById = <String, int?>{};
    for (final item in spec.itemsFrom(data)) {
      final rec = spec.itemFrom(item);
      final msg = _messageFromRecord(rec, chatId);
      if (msg == null) continue;
      messages.add(msg);
      seqById[msg.id] = _int(rec['seq']);
    }
    // 统一按时间倒序（最新在前），不依赖后端返回顺序
    messages.sort((a, b) => b.time.compareTo(a.time));

    // 返回条数等于请求数 → 大概率还有更早的。
    // 无法精确判断"到底有没有更多"（OneBot 没有 total 字段），
    // 因此用这个启发式，多翻一次空页的代价可以接受。
    HistoryCursor? next;
    if (messages.length >= count && count > 0) {
      final oldest = messages.last;
      next = HistoryCursor(
        messageId: oldest.id,
        seq: seqById[oldest.id],
        time: oldest.time,
      );
    }

    return HistoryPage(messages, next: next);
  }

  @override
  Future<String?> sendMessage(String chatId, List<Segment> segments) async {
    _ensureReady();
    if (segments.isEmpty) throw const SessionException('消息内容为空');

    final (isGroup, peerId) = _splitChatId(chatId);
    final logical = isGroup ? 'send_group_msg' : 'send_private_msg';
    final spec = _profile?.spec(logical);
    if (spec == null) throw SessionException('后端 ${_profile?.name} 不支持发送消息');

    final params = <String, dynamic>{
      if (isGroup) 'group_id': peerId else 'user_id': peerId,
      'message': Segment.toArrayData(segments),
    };

    final data = await _callSpec(logical, params: params);
    final id = spec.oneFrom(data)['message_id'];
    _log('info', '已发送到 $chatId，返回 message_id=$id');
    return id?.toString();
  }

  @override
  Future<void> recall(String chatId, String messageId) async {
    _ensureReady();
    final id = _int(messageId);
    if (id == null) {
      throw SessionException('撤回需要数字型消息 ID，收到 "$messageId"');
    }
    await _callSpec('delete_msg', params: {'message_id': id});
  }

  @override
  Future<void> markRead(String chatId, String messageId) async {
    _ensureReady();
    if (!supports('set_message_read')) {
      // 实测：Lagrange.OneBot 没有已读上报接口。这里显式失败而不是静默忽略，
      // 调用方应先 supports('set_message_read') 再调。
      throw SessionException('后端 ${_profile?.name} 不支持已读上报');
    }
    final (isGroup, _) = _splitChatId(chatId);
    await _callSpec(
      'set_message_read',
      params: {'message_id': _int(messageId) ?? messageId},
      isPrivate: !isGroup,
    );
  }

  @override
  Future<void> sendPoke(String chatId, String userId) async {
    _ensureReady();
    final (isGroup, peerId) = _splitChatId(chatId);
    await _callSpec(
      'poke',
      params: isGroup
          ? {'group_id': peerId, 'user_id': _int(userId) ?? userId}
          : {'user_id': _int(userId) ?? userId},
      isPrivate: !isGroup,
    );
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _sub?.cancel();
    _sub = null;
    client.dispose();
    await _events.close();
  }

  // -- 内部：请求 -----------------------------------------------------------

  /// 按适配表调用一个逻辑 API，返回原始 `data`。
  ///
  /// 返回 `Object?` 而非 `Map`：列表类 API（`get_friend_list` 等）的 `data`
  /// 是数组。调用方用 `spec.oneFrom()` / `spec.itemsFrom()` 解释它。
  ///
  /// 表里声明的 `a|b` 备选写法会按顺序尝试（同一份数据在不同版本里换过
  /// action 名的情况）。
  Future<Object?> _callSpec(
    String logical, {
    Map<String, dynamic> params = const {},
    bool isPrivate = false,
  }) async {
    final spec = _profile?.spec(logical);
    if (spec == null) {
      throw SessionException('后端 ${_profile?.name} 不支持逻辑 API「$logical」');
    }
    Object? lastError;
    for (final action in spec.actions(isPrivate: isPrivate)) {
      try {
        return await client.call(action, params);
      } on OneBotApiException catch (e) {
        lastError = e;
        _log('debug', 'action $action 失败，尝试下一个候选', e);
      }
    }
    throw SessionException('「$logical」的全部候选 action 均失败', cause: lastError);
  }

  // -- 内部：事件 -----------------------------------------------------------

  void _onTransportEvent(OneBotEvent e) {
    switch (e) {
      case OneBotMessageEvent m:
        final msg = _messageFromEvent(m);
        if (msg != null) _emit(SessionMessage(msg));

      case OneBotNoticeEvent n:
        _handleNotice(n);

      case OneBotRequestEvent r:
        _emit(SessionRequest(
          r.requestType,
          r.flag,
          (r.userId ?? '').toString(),
          chatId: r.groupId == null ? null : Chat.keyOf(ChatType.group, r.groupId!),
          comment: (r.raw['comment'] as String?),
        ));

      case OneBotStateChanged s:
        _setState(_mapState(s.state), reason: s.reason);

      case OneBotTransportError err:
        _emit(SessionFailure(err.error, err.stackTrace));

      // 心跳/生命周期由传输层自己消费（看门狗），会话层不关心
      case OneBotMetaEvent _:
        break;

      case OneBotUnknownEvent _:
        break;
    }
  }

  void _handleNotice(OneBotNoticeEvent n) {
    final rawId = n.groupId ?? n.userId;
    final isGroup = n.groupId != null;
    final chatId = rawId == null
        ? ''
        : Chat.keyOf(isGroup ? ChatType.group : ChatType.private, rawId);

    switch (n.noticeType) {
      case 'group_recall':
      case 'friend_recall':
        _emit(SessionMessageRecalled(
          chatId,
          (n.messageId ?? '').toString(),
          operatorId: n.operatorId?.toString(),
          time: n.time == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(n.time! * 1000),
        ));
        return;

      case 'group_increase':
        _emit(_notice('member_increase', chatId, n));
        return;

      case 'group_decrease':
        _emit(_notice('member_decrease', chatId, n));
        return;

      case 'group_admin':
        _emit(_notice('admin_change', chatId, n));
        return;

      case 'group_ban':
        _emit(_notice('ban', chatId, n));
        return;

      case 'group_upload':
        _emit(_notice('upload', chatId, n));
        return;

      case 'friend_add':
        _emit(_notice('friend_add', chatId, n));
        return;

      case 'notify':
        final kind = switch (n.subType) {
          'poke' => 'poke',
          'title' => 'title_change',
          'honor' => 'honor',
          _ => 'unknown',
        };
        _emit(_notice(kind, chatId, n));
        return;

      default:
        _emit(_notice('unknown', chatId, n));
    }
  }

  SessionNotice _notice(String kind, String chatId, OneBotNoticeEvent n) =>
      SessionNotice(
        kind,
        chatId,
        userId: n.userId?.toString(),
        operatorId: n.operatorId?.toString(),
        raw: n.raw,
      );

  // -- 内部：对象构造 -------------------------------------------------------

  /// 由推送事件构造消息。
  ChatMessage? _messageFromEvent(OneBotMessageEvent e) {
    final isGroup = e.messageType == 'group';
    final peerId = isGroup ? e.groupId : e.userId;
    if (peerId == null) return null;

    final chatId = Chat.keyOf(isGroup ? ChatType.group : ChatType.private, peerId);

    // 段数组优先；为空时回落到 CQ 码字符串（老实现或 text 模式）
    final segments = e.segments.isNotEmpty
        ? Segment.parseList(e.segments)
        : Segment.parseList(e.rawMessage);

    final sender = e.sender;
    final senderId = _str(sender['user_id'] ?? e.userId);
    final selfId = _str(e.raw['self_id']);
    final outgoing = e.isSelfSent || (selfId.isNotEmpty && senderId == selfId);

    return ChatMessage.fromSegments(
      id: _str(e.messageId),
      segments: segments,
      time: _timeOf(e.time),
      outgoing: outgoing,
      senderName: _nameOf(sender, senderId),
      senderId: senderId,
      chatId: chatId,
      selfId: selfId,
      senderTitle: sender['title'] as String?,
    );
  }

  /// 由历史记录（已过适配表归一化）构造消息。
  ChatMessage? _messageFromRecord(Map<String, dynamic> rec, String chatId) {
    final id = _str(rec['message_id']);
    if (id.isEmpty) return null;

    final segments = Segment.parseList(rec['message']);
    final sender = (rec['sender'] as Map?)?.cast<String, dynamic>() ?? const {};
    final senderId = _str(rec['user_id'] ?? sender['user_id']);
    final selfId = _account?.uin ?? '';
    final outgoing = selfId.isNotEmpty && senderId == selfId;

    return ChatMessage.fromSegments(
      id: id,
      segments: segments,
      time: _timeOf(_int(rec['time'])),
      outgoing: outgoing,
      senderName: _nameOf(sender, senderId),
      senderId: senderId,
      chatId: chatId,
      selfId: selfId,
      system: rec['post_type'] == 'notice',
    );
  }

  // -- 内部：状态 -----------------------------------------------------------

  SessionState _mapState(OneBotState s) => switch (s) {
        OneBotState.disconnected => SessionState.disconnected,
        OneBotState.connecting => SessionState.connecting,
        // 传输层联通 ≠ 会话可用：还要等握手拿到账号信息
        OneBotState.connected => _account == null ? SessionState.connecting : SessionState.ready,
        OneBotState.reconnecting => SessionState.reconnecting,
        OneBotState.closed => SessionState.closed,
      };

  void _setState(SessionState s, {String? reason}) {
    if (_state == s && reason == null) return;
    _state = s;
    _emit(SessionStateChanged(s, reason: reason));
  }

  void _ensureReady() {
    if (_disposed) throw const SessionException('会话已释放');
    if (_state != SessionState.ready) {
      throw SessionException('会话未就绪（当前 ${_state.name}），请先 connect()');
    }
  }

  void _emit(SessionEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _log(String level, String message, [Object? detail]) {
    onLog?.call(level, message, detail);
  }

  // -- 内部：工具 -----------------------------------------------------------

  /// 拆解复合会话 ID；非法则抛异常。
  (bool isGroup, int peerId) _splitChatId(String chatId) {
    final key = Chat.parseKey(chatId);
    if (key == null || key.id == null) {
      throw SessionException('非法会话 ID：「$chatId」（应为 group_<id> 或 private_<id>）');
    }
    return (key.type == ChatType.group, key.id!);
  }

  String _pickName(Object? remark, Object? nickname, int fallbackId) {
    final r = _str(remark);
    if (r.isNotEmpty) return r;
    final n = _str(nickname);
    if (n.isNotEmpty) return n;
    return fallbackId.toString();
  }

  String _nameOf(Map<String, dynamic> sender, String fallback) {
    final card = _str(sender['card']);
    if (card.isNotEmpty) return card;
    final nick = _str(sender['nickname']);
    if (nick.isNotEmpty) return nick;
    return fallback;
  }

  DateTime _timeOf(int? seconds) => seconds == null || seconds <= 0
      ? DateTime.now()
      : DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
}

// ---------------------------------------------------------------------------

String _str(Object? v) {
  if (v == null) return '';
  return v.toString();
}

int? _int(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}
