/// L3 客户端 API 层：把协议线（wlogin8）接到 UI 的 [Session] 契约上
///
/// ## 它是"薄桥"，不是第二个内核
///
/// 所有协议动作都已经在 [Qq8LoginService] 上（登录/扫码/发消息/拉历史/列表），
/// 本类只做三件翻译：
///
/// 1. **状态**：服务的 `Qq8LoginStage` → [SessionState]
///    （`needsSlider`/`needsSmsCode`/`needsDeviceLock`/`waitingQrScan` 都算"握手中"
///    即 [SessionState.connecting]；`online` → [SessionState.ready]）；
/// 2. **事件**：推送解析事件 → [SessionMessage]（其余事件进日志）；
/// 3. **参数**：UI 的 `chat_<id>` / 文本段 ↔ 内核的群号/uin/文本。
///
/// 为什么放在 L3 而不是像 `OneBotSession` 那样放 L2：它要**驱动** L3 的服务
/// （L2 依赖 L3 服务会反向依赖）。契约本身留在 `session.dart`，这里只是它的
/// 一个实现。
///
/// ## v1 的边界（都写在这里，避免以后翻代码）
///
/// * [connect] 只做 **token 登录**（用本地票据）；口令/滑块/扫码这条链走
///   [Qq8LoginService] 的动作，UI 的协议线登录页直接用它，认证完再套本类；
/// * **群历史**需要"最新 seq"定位：从收到的群消息里学（`_groupSeq`）。
///   学到之前返回空页（确实还没有消息），**不发猜测性请求**；
/// * 撤回 / 已读上报已接（消息 ID 反解出 seq/rand/time 再发，见
///   `Qq8Msg.buildC2cWithdrawBody` 等）；分片群消息的撤回、戳一戳、非文本段
///   仍是 [SessionException]；
/// * 昵称：协议线在登录阶段拿不到自己的昵称，先留空（`AccountInfo.nickname`）。
///
/// 本文件是纯 Dart。
library;

import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data';

import '../kernel/wlogin8/qq8_elem.dart';
import '../kernel/wlogin8/qq8_msg.dart';
import '../kernel/wlogin8/qq8_push.dart';
import 'objects.dart';
import 'qq8_login_service.dart';
import 'segment.dart';
import 'session.dart';

/// 协议线（wlogin8）的 [Session] 实现。
class Qq8SessionAdapter implements Session {
  /// 被桥接的服务实例（登录/扫码/发消息/拉取都在它上面）。
  final Qq8LoginService service;

  /// 自己打的标签（[backendName] 用）。
  final String label;

  /// [connect] 用哪个 uin 去读本地票据（null = 不允许 connect，只当"已登录"用）。
  final int? uin;

  /// 日志回调（UI 可接；纯 Dart 层不打日志框架）。
  final void Function(String level, String message, [Object? detail])? onLog;

  final StreamController<SessionEvent> _events =
      StreamController<SessionEvent>.broadcast();
  StreamSubscription<Qq8LoginSnapshot>? _stateSub;
  StreamSubscription<Qq8PushEvent>? _pushSub;

  /// 群号 → 见过的最新 seq（群历史翻页的锚点）。
  final Map<int, int> _groupSeq = <int, int>{};

  /// uin → 最近见到的昵称（群消息会带 `from_nick`）。
  final Map<int, String> _nickCache = <int, String>{};

  SessionState _state = SessionState.disconnected;
  AccountInfo? _account;
  bool _disposed = false;

  Qq8SessionAdapter({
    required this.service,
    this.uin,
    this.label = 'wlogin8',
    this.onLog,
  }) {
    _stateSub = service.states.listen(_onStage);
    _pushSub = service.events.listen(_onPush, onError: _onPushError);
    _onStage(service.snapshot);
  }

  /// 当前用的客户端档案标签（诊断用）。
  String get profileLabel => service.profile.label;

  // ------------------------------------------------------------------
  // Session 契约
  // ------------------------------------------------------------------

  @override
  SessionState get state => _state;

  @override
  Stream<SessionEvent> get events => _events.stream;

  @override
  AccountInfo? get account => _account;

  @override
  String? get backendName => label;

  @override
  bool supports(String capability) => _capabilities.contains(capability);

  static const Set<String> _capabilities = <String>{
    'list_chats',
    'fetch_history',
    'send_message',
    'recall', // 撤回自己发的消息（私聊 / 单包群消息）
    'set_message_read', // 已读上报（chat_store 问的就是这个能力名）
  };

  /// 建连 = 用本地票据登录并上线。**认证类动作（口令/滑块/扫码）走服务本身**。
  @override
  Future<void> connect() async {
    if (_disposed) throw const SessionException('会话已释放');
    if (_state == SessionState.ready) return;
    final target = uin;
    if (target == null) {
      throw const SessionException(
          '协议线 connect() 需要 uin（构造时传入）；口令/扫码登录请直接用 Qq8LoginService 的动作');
    }
    await service.loginWithToken(uin: target);
    // 状态流是异步投递的：这里直接从快照同步一次，否则"刚登录完就调别的动作"
    // 会撞上"还没 ready"的假象（真机与自测都踩得到）。
    _onStage(service.snapshot);
    if (state != SessionState.ready) {
      throw SessionException(service.snapshot.error ?? '登录未完成（${service.snapshot.stage.name}）');
    }
  }

  @override
  Future<void> close() async {
    await service.close();
    _setState(SessionState.closed);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _stateSub?.cancel();
    await _pushSub?.cancel();
    await _events.close();
  }

  /// 会话列表 = 好友（私聊）+ 群（群聊）。
  ///
  /// 未读数先给 0：协议线的未读数在 `PbGetMsg` 的会话块里，
  /// 等 [pullMessages] 被调用时再补（UI 侧由 store 维护）。
  @override
  Future<List<Chat>> listChats() async {
    _requireReady();
    final friends = await service.fetchFriendList();
    final groups = await service.fetchGroupList();
    return <Chat>[
      for (final f in friends.friends)
        Chat(
          id: Chat.keyOf(ChatType.private, f.uin),
          title: f.displayName,
          type: ChatType.private,
          rawId: f.uin,
        ),
      for (final g in groups.groups)
        Chat(
          id: Chat.keyOf(ChatType.group, g.gid),
          title: g.name,
          type: ChatType.group,
          rawId: g.gid,
          memberCount: g.memberCount,
          ownerUin: g.ownerUin,
        ),
    ];
  }

  /// 历史消息（按时间倒序，最新在前）。
  ///
  /// 私聊走 `PbGetOneDayRoamMsg`（游标 = 时间）；群走 `PbGetGroupMsg`
  /// （游标 = seq，需要先"见过"该群的消息才知道最新 seq）。
  @override
  Future<HistoryPage> fetchHistory(
    String chatId, {
    int count = 20,
    HistoryCursor? before,
  }) async {
    _requireReady();
    final key = Chat.parseKey(chatId);
    if (key == null || key.id == null) {
      throw SessionException('会话 ID 不合法：$chatId');
    }
    if (key.type == ChatType.private) {
      final page = await service.fetchC2cHistory(
        peerUin: key.id!,
        before: before?.time?.millisecondsSinceEpoch == null
            ? null
            : before!.time!.millisecondsSinceEpoch ~/ 1000,
        count: count,
      );
      final messages = <ChatMessage>[
        for (final m in page.messages) _toChatMessage(m),
      ]..sort((a, b) => b.time.compareTo(a.time));
      return HistoryPage(
        messages,
        next: (page.isComplete != true && messages.isNotEmpty)
            ? HistoryCursor(time: messages.last.time)
            : null,
      );
    }

    final gid = key.id!;
    final end = before?.seq ?? _groupSeq[gid];
    if (end == null || end <= 0) {
      // 还没见过这个群的消息 ⇒ 确实没有可显示的历史，不发猜测性请求
      _log('debug', '群 $gid 还没有已知 seq，历史返回空页');
      return HistoryPage.empty;
    }
    final begin = (end - count + 1).clamp(1, end);
    final page = await service.fetchGroupHistory(
      groupCode: gid,
      beginSeq: begin,
      endSeq: end,
    );
    final messages = <ChatMessage>[
      for (final m in page.messages) _toChatMessage(m),
    ]..sort((a, b) => b.time.compareTo(a.time));
    return HistoryPage(
      messages,
      next: (begin > 1 && messages.isNotEmpty)
          ? HistoryCursor(seq: begin - 1)
          : null,
    );
  }

  /// 发一条消息（**支持文本 / QQ 表情 / 本地单张图片**，其他段会抛错而不是
  /// 静默丢），返回服务端消息 ID。
  ///
  /// 图片走完整上传链路（[Qq8LoginService.sendImage]：探图 → PicUp 申请 →
  /// highway 传数据 → 元素回填）。暂不支持的：
  /// * 图片 + 其他内容混排（要先把多个元素排好再发，还没做）；
  /// * **转发收到的图**——`ImageSegment.file` 里只有 QQ 的图片文件名，
  ///   本地没有文件可传（服务端 md5 命中也不能免传，fid 是按目标换的）。
  @override
  Future<String?> sendMessage(String chatId, List<Segment> segments) async {
    _requireReady();
    final key = Chat.parseKey(chatId);
    if (key == null || key.id == null) {
      throw SessionException('会话 ID 不合法：$chatId');
    }
    final self = service.snapshot.uin ?? 0;

    if (segments.any((s) => s is ImageSegment)) {
      if (segments.length != 1 || segments.first is! ImageSegment) {
        throw SessionException('图片暂时只能单独发（文字/表情混排还没做）');
      }
      final img = segments.first as ImageSegment;
      final path = img.file;
      final f = File(path);
      if (path.isEmpty || !f.existsSync()) {
        throw SessionException(
            '这张图没有本地文件（收到/转发的图暂时发不出去）：$path');
      }
      final bytes = await f.readAsBytes();
      final r = key.type == ChatType.private
          ? await service.sendImage(bytes: bytes, uid: key.id)
          : await service.sendImage(bytes: bytes, gid: key.id);
      if (!r.ok) {
        throw SessionException(
            '发送失败：${r.message.isEmpty ? 'code=${r.code}' : r.message}');
      }
      return key.type == ChatType.private
          ? Qq8Msg.dmMessageId(
              peerUin: key.id!,
              seq: r.seq,
              rand: r.rand,
              time: r.time,
              outgoing: true,
            )
          : Qq8Msg.groupMessageId(
              gid: key.id!,
              senderUin: self,
              seq: r.seq,
              rand: r.rand,
              time: r.time,
            );
    }

    final elems = _elemsOf(segments);
    final reply = _replyOf(segments, chatId);

    if (key.type == ChatType.private) {
      final r = await service.sendC2c(uid: key.id!, elems: elems, reply: reply);
      if (!r.ok) {
        throw SessionException('发送失败：${r.message.isEmpty ? 'code=${r.code}' : r.message}');
      }
      return Qq8Msg.dmMessageId(
        peerUin: key.id!,
        seq: r.seq,
        rand: r.rand,
        time: r.time,
        outgoing: true,
      );
    }
    final r = await service.sendGroup(gid: key.id!, elems: elems, reply: reply);
    if (!r.ok) {
      throw SessionException('发送失败：${r.message.isEmpty ? 'code=${r.code}' : r.message}');
    }
    return Qq8Msg.groupMessageId(
      gid: key.id!,
      senderUin: self,
      seq: r.seq,
      rand: r.rand,
      time: r.time,
    );
  }

  /// 把引用回复段翻成内核的 [Qq8ReplyInfo]（没有引用段就返回 null）。
  ///
  /// 被引用消息的**发送者**要从消息 ID 里推：私聊 ID 只带"对方"，那条到底是
  /// 自己发的还是对方发的要看 flag（1 = 自己发的）。
  Qq8ReplyInfo? _replyOf(List<Segment> segments, String chatId) {
    final key = Chat.parseKey(chatId);
    final self = service.snapshot.uin ?? 0;
    for (final s in segments) {
      if (s is! ReplySegment) continue;
      if (key?.type == ChatType.group) {
        final m = Qq8Msg.parseGroupMessageId(s.messageId);
        if (m == null) {
          throw SessionException('引用的消息 ID 不是本协议的格式：${s.messageId}');
        }
        return Qq8ReplyInfo(
          seq: m.seq,
          senderUin: m.senderUin,
          time: m.time,
          preview: s.text ?? '',
        );
      }
      final m = Qq8Msg.parseDmMessageId(s.messageId);
      if (m == null) {
        throw SessionException('引用的消息 ID 不是本协议的格式：${s.messageId}');
      }
      return Qq8ReplyInfo(
        seq: m.seq,
        senderUin: m.flag == 1 ? self : m.peerUin,
        time: m.time,
        preview: s.text ?? '',
      );
    }
    return null;
  }

  /// 撤回自己发的消息：消息 ID 是内核那套打包，反解出 seq/rand/time 再发。
  ///
  /// 只能撤回**自己发的**（QQ 的规则）；消息太旧服务端会拒（返回码由服务层带出）。
  @override
  Future<void> recall(String chatId, String messageId) async {
    _requireReady();
    final key = Chat.parseKey(chatId);
    if (key == null || key.id == null) {
      throw SessionException('会话 ID 不合法：$chatId');
    }
    if (key.type == ChatType.private) {
      final m = Qq8Msg.parseDmMessageId(messageId);
      if (m == null) throw SessionException('消息 ID 不是本协议的格式：$messageId');
      if (m.flag != 1) throw const SessionException('只能撤回自己发的消息');
      final r = await service.withdrawC2c(
        peerUin: key.id!,
        seq: m.seq,
        rand: m.rand,
        time: m.time,
      );
      if (r.result > 2) {
        throw SessionException(
            '撤回失败：${r.errmsg.isEmpty ? 'result=${r.result}' : r.errmsg}');
      }
      return;
    }
    final m = Qq8Msg.parseGroupMessageId(messageId);
    if (m == null) throw SessionException('消息 ID 不是本协议的格式：$messageId');
    final self = service.snapshot.uin ?? 0;
    if (m.senderUin != self) throw const SessionException('只能撤回自己发的消息');
    if (m.pktNum > 1) {
      throw const SessionException('分片消息的撤回协议还没核实（见 qq8_msg.dart 注释）');
    }
    final r = await service.withdrawGroup(
      gid: key.id!,
      seq: m.seq,
      rand: m.rand,
    );
    if (r.result != 0) {
      throw SessionException(
          '撤回失败：${r.errmsg.isEmpty ? 'result=${r.result}' : r.errmsg}');
    }
  }

  /// 已读上报：私聊报到消息时间、群报到消息 seq（TG/QQ 都是这个语义）。
  @override
  Future<void> markRead(String chatId, String messageId) async {
    _requireReady();
    final key = Chat.parseKey(chatId);
    if (key == null || key.id == null) {
      throw SessionException('会话 ID 不合法：$chatId');
    }
    if (key.type == ChatType.private) {
      final m = Qq8Msg.parseDmMessageId(messageId);
      final time = m?.time ??
          (DateTime.now().millisecondsSinceEpoch ~/ 1000);
      await service.reportC2cRead(peerUin: key.id!, lastReadTime: time);
      return;
    }
    final m = Qq8Msg.parseGroupMessageId(messageId);
    if (m == null) {
      throw SessionException('消息 ID 不是本协议的格式：$messageId');
    }
    await service.reportGroupRead(gid: key.id!, lastReadSeq: m.seq);
  }

  @override
  Future<void> sendPoke(String chatId, String userId) =>
      throw const SessionException('协议线暂不支持戳一戳');

  // ------------------------------------------------------------------
  // 内部：状态与事件映射
  // ------------------------------------------------------------------

  void _onStage(Qq8LoginSnapshot s) {
    if (_disposed) return;
    final before = _state;
    _state = _mapStage(s.stage);
    if (s.stage == Qq8LoginStage.online && s.uin != null) {
      _account = AccountInfo(
        uin: '${s.uin}',
        nickname: _account?.nickname ?? '',
        backendName: label,
      );
    }
    if (_state != before) {
      _emit(SessionStateChanged(_state, reason: s.error));
    }
    if (s.stage == Qq8LoginStage.failed && s.error != null) {
      _emit(SessionFailure(StateError(s.error!), null));
    }
  }

  void _onPush(Qq8PushEvent ev) {
    if (_disposed) return;
    switch (ev) {
      case Qq8MessagePush(:final message):
        if (message.kind == Qq8IncomingKind.group && message.groupCode != null) {
          final gid = message.groupCode!;
          final seen = _groupSeq[gid] ?? 0;
          if (message.seq > seen) _groupSeq[gid] = message.seq;
        }
        final nick = message.fromNick;
        if (nick != null && nick.isNotEmpty) _nickCache[message.fromUin] = nick;
        _emit(SessionMessage(_toChatMessage(message)));
      case Qq8KickPush(:final hint):
        _log('warn', '被服务端踢下线：$hint');
      case Qq8NotifyPush(:final notifyType):
        _log('debug', '新消息通知（type=$notifyType）');
      case Qq8UnknownPush(:final cmd, :final note):
        _log('debug', '未处理的推送 cmd=$cmd（${note ?? '无说明'}）');
    }
  }

  void _onPushError(Object e, StackTrace st) {
    _emit(SessionFailure(e, st));
  }

  ChatMessage _toChatMessage(Qq8IncomingMessage m) {
    final self = service.snapshot.uin ?? 0;
    final isGroup = m.kind == Qq8IncomingKind.group;
    final outgoing = m.isSelf(self);
    final senderName = m.fromNick ??
        _nickCache[m.fromUin] ??
        (outgoing ? (_account?.nickname ?? '') : '${m.fromUin}');
    final segments = m.elems.map(_toSegment).toList(growable: false);
    // 引用的原文来自 src_msg（Elem 45）：气泡顶部的引用条读 replyPreview。
    // 注意**不设 replyToId**——src_msg 里没有 rand，拼不出可靠的消息 ID
    //（见 qq8_elem.dart 的 Qq8ReplyElem），宁可不给也不能给个假 ID。
    final reply = m.elems.whereType<Qq8ReplyElem>().firstOrNull;
    return ChatMessage(
      id: m.messageId(self),
      // text 用内核给的"线上纯文本"（图片/表情在那里是 `[图片]`/`[表情]` 占位），
      // 会话列表摘要与通知都读它；segments 才是给气泡渲染用的结构。
      text: m.text,
      segments: segments.isEmpty && m.text.isNotEmpty
          ? <Segment>[TextSegment(m.text)]
          : segments,
      time: DateTime.fromMillisecondsSinceEpoch(m.time * 1000),
      outgoing: outgoing,
      senderName: senderName,
      senderId: '${m.fromUin}',
      chatId: Chat.keyOf(
        isGroup ? ChatType.group : ChatType.private,
        m.chatId(self),
      ),
      replyPreview:
          reply != null && reply.preview.isNotEmpty ? reply.preview : null,
      atMe: m.mentions(self),
      system: m.text.isEmpty,
    );
  }

  /// 内核元素 → 消息段（[ChatMessage.segments]）。
  static Segment _toSegment(Qq8Elem e) => switch (e) {
        Qq8TextElem(:final text) => TextSegment(text),
        Qq8AtElem(:final target, :final name) => AtSegment(target, name: name),
        Qq8FaceElem(:final id, :final isBig) => FaceSegment(id, isBig: isBig),
        Qq8ImageElem(
          :final file,
          :final url,
          :final width,
          :final height,
          :final flash,
        ) =>
          ImageSegment(file,
              url: url,
              summary: e.summary,
              flash: flash,
              width: width,
              height: height),
        Qq8VoiceElem(:final md5, :final url, :final seconds, :final size) =>
          RecordSegment(md5 ?? '', url: url, seconds: seconds, size: size),
        Qq8VideoElem(
          :final fileId,
          :final md5,
          :final name,
          :final seconds,
          :final size
        ) =>
          VideoSegment(fileId ?? md5 ?? '',
              name: name, seconds: seconds, size: size),
        Qq8FileElem(:final fileId, :final name, :final size, :final md5) =>
          FileSegment(fileId ?? md5 ?? '',
              fileId: fileId, name: name, size: size),
        Qq8CardElem(:final kind, :final raw, :final summary) => kind == 'json'
            ? JsonSegment(raw, summary: summary)
            : XmlSegment(raw, summary: summary),
        Qq8PokeElem(:final id) => PokeSegment('poke', id: id?.toString()),
        // 引用：气泡的引用条读 ChatMessage.replyPreview（上面单独设了），
        // 段里留一份是为了**存储与转发时引用不丢**（plainText 会跳过它）
        Qq8ReplyElem(:final preview) => ReplySegment('', text: preview),
        // 认不出的：用官方的 `[不支持显示的消息]` 当文案（UnknownSegment.preview 会
        // 包成 `[文案]`），字段名与类型名塞进 data —— 存盘、日志、排查都还在，
        // 但界面上不会出现"一个空气泡"
        Qq8UnsupportedElem(:final name, :final field) => UnknownSegment(
            '不支持显示的消息',
            <String, dynamic>{'elem': name, 'field': field},
          ),
      };

  static SessionState _mapStage(Qq8LoginStage s) => switch (s) {
        Qq8LoginStage.idle => SessionState.disconnected,
        Qq8LoginStage.online => SessionState.ready,
        Qq8LoginStage.disconnected => SessionState.disconnected,
        Qq8LoginStage.failed => SessionState.disconnected,
        _ => SessionState.connecting,
      };

  void _setState(SessionState s) {
    if (_state == s) return;
    _state = s;
    _emit(SessionStateChanged(s));
  }

  void _emit(SessionEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _requireReady() {
    if (_disposed) throw const SessionException('会话已释放');
    if (_state != SessionState.ready) {
      throw SessionException('协议线还没就绪（当前 ${_state.name}）');
    }
  }

  /// 把消息段翻成**有序的内核元素**（文本 / 表情）。
  ///
  /// 顺序照原样保留（文本和表情可以交替）。表情走哪个字段由 **id** 决定
  /// （≤ 0xFF 是小表情，再大走超级表情），与参考实现 `converter.ts` 的
  /// `face()` 一致——所以 [FaceSegment.isBig] 在这里不参与判断。
  ///
  /// 文本段里的 `/表情名` 会按 QQ 的输入约定切成表情元素（见 [splitFaceTokens]）：
  /// 这是官方客户端就有的写法，所以放在协议层而不是输入框里做——拉历史、
  /// 转发、粘贴进来的文本同样生效。
  ///
  /// 不认识的段**抛错**而不是丢掉：发出去的内容少一块，比发送失败更难查。
  static List<Uint8List> _elemsOf(List<Segment> segments) {
    final elems = <Uint8List>[];
    final buf = StringBuffer();
    void flushText() {
      if (buf.isEmpty) return;
      elems.add(Qq8Msg.textElem(buf.toString()));
      buf.clear();
    }

    for (final s in segments) {
      switch (s) {
        case TextSegment(:final text):
          for (final piece in splitFaceTokens(text)) {
            if (piece is int) {
              flushText();
              elems.add(Qq8Msg.faceElem(piece));
            } else {
              buf.write(piece as String);
            }
          }
        case FaceSegment(:final id):
          final fid = int.tryParse(id);
          if (fid == null) throw SessionException('表情 ID 不是数字：$id');
          flushText();
          elems.add(Qq8Msg.faceElem(fid));
        case AtSegment(:final qq, :final name):
          buf.write(name != null && name.isNotEmpty ? '@$name ' : '@$qq ');
        case ReplySegment():
          break; // 引用不走正文
        default:
          throw SessionException('协议线暂不支持这种消息段：${s.runtimeType}');
      }
    }
    flushText();
    // 空消息也发一个空文本元素（与改动前一致：服务端会拒绝，但错在服务端那里更好查）
    if (elems.isEmpty) elems.add(Qq8Msg.textElem(''));
    return elems;
  }

  /// 按 QQ 的输入约定把 `/表情名` 切成"文本 / 表情 id"两类片段。
  ///
  /// 返回值里 `String` = 文本片段，`int` = 表情 id，顺序即消息顺序。
  /// 只有名字表（[Qq8FaceNames]）里查得到的才当表情——`/notaface` 这种
  /// 原样当文本，不能把用户打的斜杠命令吞掉。
  ///
  /// 名字后面紧跟标点也认：`/微笑，你好` → 表情 + `，你好`。做法是从长到短
  /// 试名字（名字最长几个字，代价可忽略），而不是要求用空格隔开——QQ 用户
  /// 不会专门为表情加空格。
  static List<Object> splitFaceTokens(String text) {
    final out = <Object>[];
    final buf = StringBuffer();
    var i = 0;
    while (i < text.length) {
      final slash = text.indexOf('/', i);
      if (slash < 0) {
        buf.write(text.substring(i));
        break;
      }
      // 候选名字：斜杠后面到空白/下一个斜杠为止
      var end = slash + 1;
      while (end < text.length &&
          text[end] != '/' &&
          !_faceNameStop.hasMatch(text[end])) {
        end++;
      }
      int? id;
      var nameEnd = end;
      while (nameEnd > slash + 1) {
        id = Qq8FaceNames.idOf(text.substring(slash + 1, nameEnd));
        if (id != null) break;
        nameEnd--;
      }
      if (id == null) {
        buf.write(text.substring(i, slash + 1));
        i = slash + 1;
        continue;
      }
      if (slash > i) buf.write(text.substring(i, slash));
      if (buf.isNotEmpty) {
        out.add(buf.toString());
        buf.clear();
      }
      out.add(id);
      i = nameEnd;
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  /// 表情名候选的终止符（空白与常见标点）。
  static final RegExp _faceNameStop =
      RegExp(r'[\s\u3000，。！？、,.!?~～:：;；]');

  void _log(String level, String message, [Object? detail]) {
    onLog?.call(level, message, detail);
  }
}
