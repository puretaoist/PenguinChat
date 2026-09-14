/// L3 客户端 API 层：会话与消息的本地状态 + 持久化
///
/// ## 职责边界（刻意窄）
///
/// 只做三件事：
///   1. 持有会话列表与每个会话的消息；
///   2. 订阅 [Session.events]，把事件合并进本地状态；
///   3. 持久化与启动恢复。
///
/// **不发网络请求**（那是 [Session] 的活）、**不碰 Widget**（那是 L4 的活）。
///
/// ## 为什么放在 L3
///
/// 类型全部来自 L3（[Chat] / [ChatMessage] / [Session]）。放 L2 会让 L2 依赖
/// L3 的对象（反向依赖）；放 L4 会被 Widget 细节污染，且无法在 `tool/` 里
/// 离线自测。本文件是纯 Dart（`dart:io` 是 SDK 库，不是 Flutter），
/// 自测见 `tool/chat_store_selftest.dart`。
///
/// ## 持久化格式
///
/// - 会话索引：`<dataDir>/chats.json`，JSON 数组，**防抖写**（200ms）+ dispose 时落盘
/// - 消息：`<dataDir>/chats/<chatId>.jsonl`，一行一条，**追加写**
///
/// 选 JSONL 而不是整份 JSON 重写：消息是只增不改的场景，追加写不需要读全量
/// 就能落盘，进程被杀时最多丢最后一行，而不是丢整份文件。
/// 需要改写既有条目时（撤回打标记、本地 ID 换成服务端 ID、体积淘汰）
/// 走 [_rewriteMessages] 整文件重写——这些都是低频操作。
///
/// 落盘一律用 `RandomAccessFile` 的同步 API，不用 `IOSink`：
/// `IOSink.flush()` 在并发下会**同步抛** `StateError` 并让出口静默失效
/// （见 `docs/PITFALLS.md` B1，日志层已经踩过）。
///
/// ## 两条不可让步的约束
///
/// - **媒体字节绝不进消息库**：消息里只有 [Segment] 的引用（file / url），
///   字节归 `infra/storage/` 的内容寻址存储管。见 `STORAGE-DESIGN.md`。
/// - **用户输入绝不静默丢弃**：发送失败的消息保留原文并标记
///   [MessageSendState.failed]，体积淘汰也不会碰它。
///
/// ## 存储策略（按 Telegram 分两类，不是"一刀切缓存"）
///
/// TG 的做法是**分成两类**：聊天记录是数据库（不自动删），媒体才进缓存
/// （有保留期 + 上限 + 一键清空）。这里照抄这个结构：
///
/// | 类别 | 位置 | 自动清理 | 手动清理 |
/// |---|---|---|---|
/// | 消息库 | `<dataDir>/chats.json` + `chats/*.jsonl` | **不删**（只有条数上限） | [clearChatHistory] / [clearAllHistory]（TG 的 Clear history） |
/// | 媒体缓存 | `<dataDir>/media/<分类>/…` | [pruneMediaCache]：保留期 [keepMediaFor] + 上限 [maxCacheBytes] | [clearMediaCache]（TG 的 Clear cache） |
///
/// 与 TG 的差别要说明白：TG 聊天记录能无限保留是因为它有**云端无限历史**；
/// QQ 的漫游有限（私聊按天、群按 seq 区间），所以这里给消息加了一个
/// **条数上限** [maxMessagesPerChat]（默认 500/会话）兜底——它只在单会话超过
/// 500 条时裁掉最旧的那些，且置顶会话豁免、`sending`/`failed`（用户没送出去
/// 的内容）永不裁。真要看更早的，靠 [Session.fetchHistory] 翻页再拉。
///
/// 媒体字节**永不进消息库**（见下条约束），所以清媒体缓存不会影响历史。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../infra/log/logger.dart';
import 'objects.dart';
import 'segment.dart';
import 'session.dart';

/// 状态变化的类别，UI 据此决定刷新哪一块。
enum ChatStoreChangeKind {
  /// 会话列表变了（增删、排序、未读数、摘要）。
  chats,

  /// 某个会话的消息变了；[ChatStoreChange.chatId] 指明是哪个。
  messages,

  /// 连接状态变了。
  connection,
}

/// 一次状态变化通知。
class ChatStoreChange {
  final ChatStoreChangeKind kind;
  final String? chatId;

  const ChatStoreChange(this.kind, {this.chatId});

  @override
  String toString() =>
      'ChatStoreChange(${kind.name}${chatId == null ? '' : ', $chatId'})';
}

/// 会话与消息的本地状态 + 持久化。
class ChatStore {
  ChatStore({
    required this.session,
    required this.dataDir,
    Logger? logger,
    this.maxMessagesPerChat = 500,
    this.pageSize = 20,
    this.maxCacheBytes = 512 * 1024 * 1024,
    this.keepMediaFor = const Duration(days: 30),
  }) : _log = logger ?? Log.get('ChatStore');

  /// 数据来源。ChatStore **不拥有**它的生命周期——不负责 connect / dispose，
  /// 那是创建方（`session_providers.dart`）的事。
  final Session session;

  /// 数据目录。**注入**而不是自己取平台路径，这样纯 Dart 自测能指向临时目录。
  final Directory dataDir;

  final Logger _log;

  /// 每个会话在内存与磁盘上保留的消息上限。
  ///
  /// 淘汰只针对已送达的消息：置顶会话整体豁免，未送达（sending / failed）
  /// 的一律保留——后者是用户输入，丢了不可恢复，更早的历史靠
  /// [Session.fetchHistory] 翻页还能拉回来。
  final int maxMessagesPerChat;

  /// 单次拉历史的条数。
  final int pageSize;

  /// **媒体缓存**上限（TG 的 "Maximum cache size"）。
  ///
  /// 只约束 `media/`（图片/视频/文件/语音），**不约束聊天记录**——
  /// 记录是数据库不是缓存，见文件头"存储策略"。
  final int maxCacheBytes;

  /// 媒体保留期（TG 的 "Keep media"：3 天 / 1 周 / 1 月 / 永久）。
  /// null = 永久保留（只受 [maxCacheBytes] 约束）。
  final Duration? keepMediaFor;

  /// 媒体缓存的分类子目录（对齐 TG "存储用量"页的分类）。
  static const List<String> mediaCategories = <String>[
    'photos',
    'videos',
    'files',
    'voices',
    'other',
  ];

  /// 索引落盘防抖：会话摘要每来一条消息就会变，逐条写盘不划算。
  static const Duration _indexDebounce = Duration(milliseconds: 200);

  final Map<String, Chat> _chats = {};
  final Map<String, List<ChatMessage>> _messages = {};
  final Map<String, HistoryCursor?> _cursors = {};
  final Map<String, bool> _hasMore = {};
  final Map<String, bool> _historyFetched = {};
  final Map<String, bool> _diskLoaded = {};

  /// 已经和某条 echo 事件配对过的本地临时 ID，避免同一条被匹配两次。
  final Set<String> _echoMatched = {};

  final StreamController<ChatStoreChange> _changes =
      StreamController<ChatStoreChange>.broadcast();
  StreamSubscription<SessionEvent>? _sub;
  Timer? _indexTimer;
  int _localSeq = 0;
  String? _activeChatId;
  bool _disposed = false;
  bool _bootstrapped = false;

  // ---------------------------------------------------------------------------
  // 读接口
  // ---------------------------------------------------------------------------

  /// 会话列表：置顶 → 优先级 → 最后消息时间倒序。
  List<Chat> get chats {
    final list = _chats.values.toList();
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final byPriority = a.priority.compareTo(b.priority);
      if (byPriority != 0) return byPriority;
      final at = a.lastTime;
      final bt = b.lastTime;
      if (at != null && bt != null) {
        final byTime = bt.compareTo(at);
        if (byTime != 0) return byTime;
      } else if (at != null) {
        return -1; // 有消息的排在还没消息的前面
      } else if (bt != null) {
        return 1;
      }
      return a.id.compareTo(b.id); // 兜底稳定序
    });
    return List.unmodifiable(list);
  }

  /// 某个会话的消息，时间正序（旧 → 新）。
  List<ChatMessage> messagesOf(String chatId) =>
      List.unmodifiable(_messages[chatId] ?? const <ChatMessage>[]);

  /// 状态变化通知。广播流，可多订阅。
  Stream<ChatStoreChange> get changes => _changes.stream;

  /// 当前打开的会话；用于判定未读与已读上报。
  String? get activeChatId => _activeChatId;

  /// 该会话是否还有更早的历史可翻。
  bool hasMore(String chatId) => _hasMore[chatId] ?? false;

  Chat? chatOf(String chatId) => _chats[chatId];

  /// 归档会话（TG/Nagram 的 Archived chats：列表里收起来，入口在列表顶部）。
  List<Chat> get archivedChats =>
      List<Chat>.unmodifiable(chats.where((c) => c.archived));

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 启动：建目录 → 读索引 → 订阅事件 →（会话就绪时）拉一次会话列表。
  ///
  /// 消息文件**不在这里读**：会话可能上百个，全读一遍会拖慢冷启动，
  /// 改为 [openChat] 时按会话懒加载。
  Future<void> bootstrap() async {
    await dataDir.create(recursive: true);
    await _chatsDir.create(recursive: true);
    _loadIndex();
    _bootstrapped = true;

    // TG 的做法：启动时顺手清一次媒体缓存（保留期 + 上限），不阻塞启动
    unawaited(pruneMediaCache());

    _sub = session.events.listen(
      _onEvent,
      onError: (Object e, StackTrace s) => _log.e('会话事件流错误', error: e, stack: s),
      cancelOnError: false,
    );

    if (session.state == SessionState.ready) {
      await refreshChats();
    } else {
      _log.i('会话未就绪，先用磁盘上的 ${_chats.length} 个会话');
    }
    _emit(ChatStoreChangeKind.chats);
  }

  /// 重新拉会话列表并与本地合并。UI 的下拉刷新走这里。
  Future<void> refreshChats() async {
    if (session.state != SessionState.ready) return;
    final List<Chat> remote;
    try {
      remote = await session.listChats();
    } on SessionException catch (e) {
      _log.w('拉会话列表失败：${e.message}');
      return;
    } catch (e) {
      _log.w('拉会话列表失败', error: e);
      return;
    }

    final merged = <String, Chat>{};
    for (final c in remote) {
      merged[c.id] = _mergeChat(_chats[c.id], c);
    }
    _chats
      ..clear()
      ..addAll(merged);
    _persistIndex();
    _emit(ChatStoreChangeKind.chats);
  }

  /// 打开一个会话：懒加载磁盘消息 → 清未读 → 上报已读 → 首次拉历史。
  Future<void> openChat(String chatId) async {
    _activeChatId = chatId;
    _ensureDiskLoaded(chatId);
    await markChatRead(chatId);

    if (_historyFetched[chatId] != true && session.state == SessionState.ready) {
      try {
        final page = await session.fetchHistory(chatId, count: pageSize);
        _historyFetched[chatId] = true;
        _mergePage(chatId, page);
      } on SessionException catch (e) {
        // 不标记为已拉取：下次打开还能重试
        _log.w('拉历史失败（${e.message}），下次打开重试');
      } catch (e) {
        _log.w('拉历史失败，下次打开重试', error: e);
      }
    }

    _emit(ChatStoreChangeKind.messages, chatId);
    _emit(ChatStoreChangeKind.chats);
  }

  /// 往前翻一页。没有更多时是空操作，不会白跑一次网络请求。
  Future<void> loadMore(String chatId) async {
    if (!hasMore(chatId)) return;
    if (session.state != SessionState.ready) return;
    try {
      final page = await session.fetchHistory(
        chatId,
        count: pageSize,
        before: _cursors[chatId],
      );
      _mergePage(chatId, page);
      _emit(ChatStoreChangeKind.messages, chatId);
    } on SessionException catch (e) {
      _log.w('翻页失败：${e.message}');
    } catch (e) {
      _log.w('翻页失败', error: e);
    }
  }

  /// 发送：**乐观插入**，随后异步确认。
  ///
  /// 不把异常抛给调用方——失败态由消息自身的 [ChatMessage.sendState] 承载，
  /// 这样 UI 只需要渲染状态，不必到处 try/catch，也不会在异常路径上丢掉输入框内容。
  Future<void> send(String chatId, List<Segment> segments) async {
    _ensureDiskLoaded(chatId);
    final uin = session.account?.uin ?? '';
    final local = ChatMessage.fromSegments(
      id: 'local:${++_localSeq}',
      segments: segments,
      time: DateTime.now(),
      outgoing: true,
      chatId: chatId,
      senderId: uin,
      senderName: session.account?.nickname ?? '',
      selfId: uin,
      sendState: MessageSendState.sending,
    );

    _insertMessage(local, persist: true);
    _touchChat(chatId, local);
    _emit(ChatStoreChangeKind.messages, chatId);
    _emit(ChatStoreChangeKind.chats);

    await _dispatch(chatId, local);
  }

  /// 重发一条失败的消息。非失败态或 ID 不存在时是空操作。
  Future<void> retry(String chatId, String messageId) async {
    _ensureDiskLoaded(chatId);
    final idx = _indexOf(chatId, messageId);
    if (idx < 0) return;
    final current = _messages[chatId]![idx];
    if (current.sendState != MessageSendState.failed) return;

    _messages[chatId]![idx] = current.copyWith(sendState: MessageSendState.sending);
    _rewriteMessages(chatId);
    _emit(ChatStoreChangeKind.messages, chatId);

    await _dispatch(chatId, _messages[chatId]![idx]);
  }

  /// 清零未读；若后端支持则顺带上报已读。
  ///
  /// 同时把 [Chat.lastReadId] 推到当前最后一条——"未读消息"分隔线就是靠它定位
  /// （见 `message_list_builder.dart`）。清未读与记位置必须一起做，否则会出现
  /// "计数器是 0、分隔线还停在三条之前"的错位。
  Future<void> markChatRead(String chatId) async {
    final chat = _chats[chatId];
    final list = _messages[chatId];
    final lastId = (list != null && list.isNotEmpty) ? list.last.id : null;
    if (chat != null &&
        (chat.unreadCount > 0 ||
            chat.manualUnread ||
            (lastId != null && lastId != chat.lastReadId))) {
      _chats[chatId] = chat.copyWith(
        unreadCount: 0,
        lastReadId: lastId ?? chat.lastReadId,
        // 打开会话（或主动标已读）时，手动的"标为未读"就该结束
        manualUnread: false,
      );
      _scheduleIndexPersist();
      _emit(ChatStoreChangeKind.chats);
    }

    if (session.state != SessionState.ready) return;
    // 各后端能力不同（实测只有 NapCat 有 mark_*_msg_as_read），先问再做
    if (!session.supports('set_message_read')) return;
    if (list == null || list.isEmpty) return;
    final last = list.last;
    if (last.outgoing || last.id.startsWith('local:')) return;
    try {
      await session.markRead(chatId, last.id);
    } on SessionException catch (e) {
      _log.d('已读上报失败：${e.message}');
    } catch (e) {
      _log.d('已读上报失败', error: e);
    }
  }

  /// 释放资源。**不** dispose [Session]（不拥有它）。幂等。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _sub?.cancel();
    _sub = null;
    _persistIndex();
    await _changes.close();
  }

  // ---------------------------------------------------------------------------
  // 事件合并
  // ---------------------------------------------------------------------------

  void _onEvent(SessionEvent event) {
    if (_disposed) return;
    switch (event) {
      case SessionStateChanged():
        _emit(ChatStoreChangeKind.connection);
      case SessionFailure(:final error):
        _log.w('会话层报错：$error');
        _emit(ChatStoreChangeKind.connection);
      case SessionMessage(:final message):
        _onIncoming(message);
      case SessionMessageRecalled():
        _onRecall(event);
      case SessionNotice():
      case SessionRequest():
        // 通知与申请不进本地状态：前者是瞬时提示，后者需要用户决策，
        // 都由 UI 直接订阅 Session.events 处理。
        break;
    }
  }

  void _onIncoming(ChatMessage raw) {
    final chatId = raw.chatId.isNotEmpty ? raw.chatId : (_activeChatId ?? '');
    if (chatId.isEmpty) {
      _log.d('收到无会话归属的消息 ${raw.id}，丢弃');
      return;
    }
    _ensureDiskLoaded(chatId);
    final message = raw.chatId.isEmpty ? raw.copyWith(chatId: chatId) : raw;

    // 幂等：历史与实时事件重叠、后端重推，都按 ID 去重。
    // 已有条目**不被事件覆盖**——本地可能已经打了撤回标记或换过服务端 ID。
    if (_indexOf(chatId, message.id) >= 0) return;

    // 多端同步：自己在别处发的消息会作为 echo 回来。若它与本地某条
    // 「后端没回 ID」的乐观消息是同一句，就地换 ID 而不是再插一条。
    if (message.outgoing) {
      final candidate = _findEchoCandidate(chatId, message);
      if (candidate != null) {
        _log.d('echo 与本地 ${candidate.id} 配对，换 ID 为 ${message.id}');
        _replaceLocalId(chatId, candidate.id, message.id);
        return;
      }
    }

    _insertMessage(message, persist: true);
    _touchChat(chatId, message, bumpUnread: chatId != _activeChatId);
    _emit(ChatStoreChangeKind.messages, chatId);
    _emit(ChatStoreChangeKind.chats);
  }

  void _onRecall(SessionMessageRecalled event) {
    _ensureDiskLoaded(event.chatId);
    final idx = _indexOf(event.chatId, event.messageId);
    if (idx < 0) {
      _log.d('撤回的消息 ${event.messageId} 不在本地，忽略');
      return;
    }
    // 撤回是**打补丁**不是删除：保留原位、置标记，才能支持"撤回后仍可查看"
    final info = jsonEncode({
      if (event.time != null) 'time': event.time!.toIso8601String(),
      if (event.operatorId != null) 'operator': event.operatorId,
    });
    _messages[event.chatId]![idx] =
        _messages[event.chatId]![idx].recalled(recallInfo: info);
    _rewriteMessages(event.chatId);
    _emit(ChatStoreChangeKind.messages, event.chatId);
  }

  // ---------------------------------------------------------------------------
  // 存储：用量统计 / 清理（按 TG 的做法，见文件头"存储策略"）
  // ---------------------------------------------------------------------------

  /// 本地占用统计：**消息库**（不自动清理）与**媒体缓存**（可清）分开报。
  Future<StorageStats> storageStats() async {
    final dbByChat = <String, int>{};
    var dbBytes = 0;
    if (_chatsDir.existsSync()) {
      for (final f in _chatsDir.listSync()) {
        if (f is! File) continue;
        dbBytes += f.lengthSync();
      }
      for (final id in _chats.keys) {
        final f = _messageFile(id);
        if (f.existsSync()) dbByChat[id] = f.lengthSync();
      }
    }
    if (_indexFile.existsSync()) dbBytes += _indexFile.lengthSync();

    final cacheByCategory = <String, int>{};
    var cacheBytes = 0;
    final media = _mediaDir;
    if (media.existsSync()) {
      for (final f in media.listSync(recursive: true)) {
        if (f is! File) continue;
        final size = f.lengthSync();
        cacheBytes += size;
        final rel = f.path.substring(media.path.length + 1).split(RegExp(r'[\\/]'));
        final category = rel.length > 1 ? rel.first : 'other';
        cacheByCategory[category] = (cacheByCategory[category] ?? 0) + size;
      }
    }

    return StorageStats(
      dbBytes: dbBytes,
      cacheBytes: cacheBytes,
      cacheByCategory: cacheByCategory,
      dbByChat: dbByChat,
      messageCount:
          _messages.values.fold<int>(0, (sum, list) => sum + list.length),
      chatCount: _chats.length,
    );
  }

  /// 清媒体缓存：先按保留期删过期文件，再按上限从最旧的删到预算内。
  ///
  /// 返回释放的字节数。对应 TG 的"自动清理缓存"（保留期 + 上限两档）。
  Future<int> pruneMediaCache() async {
    if (_disposed) return 0;
    final media = _mediaDir;
    if (!media.existsSync()) return 0;

    final files = <File>[
      for (final f in media.listSync(recursive: true))
        if (f is File) f,
    ];
    var freed = 0;
    final now = DateTime.now();

    final keep = keepMediaFor;
    if (keep != null) {
      for (final f in files.toList()) {
        if (now.difference(f.lastModifiedSync()) > keep) {
          freed += _deleteQuietly(f);
          files.remove(f);
        }
      }
    }

    var total = files.fold<int>(0, (sum, f) => sum + f.lengthSync());
    if (total > maxCacheBytes) {
      files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
      for (final f in files) {
        if (total <= maxCacheBytes) break;
        final size = f.lengthSync();
        if (_deleteQuietly(f) > 0) {
          total -= size;
          freed += size;
        }
      }
    }
    if (freed > 0) {
      _log.i('媒体缓存清理：释放 $freed 字节'
          '（上限 $maxCacheBytes，保留期 ${keepMediaFor ?? '永久'}）');
    }
    return freed;
  }

  /// 清空整个媒体缓存（TG 的 Clear cache 按钮）。返回释放的字节数。
  Future<int> clearMediaCache() async {
    final media = _mediaDir;
    if (!media.existsSync()) return 0;
    var freed = 0;
    for (final f in media.listSync(recursive: true)) {
      if (f is File) freed += _deleteQuietly(f);
    }
    _log.i('已清空媒体缓存（释放 $freed 字节）');
    return freed;
  }

  /// 清空某个会话的历史（TG 的 Clear history，单会话版）。
  ///
  /// 会话本身、未读数与摘要保留；清掉后下次打开会重新拉（[_historyFetched] 复位）。
  Future<void> clearChatHistory(String chatId) async {
    final f = _messageFile(chatId);
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (e) {
      _log.w('删除消息文件失败 $chatId', error: e);
    }
    _messages[chatId] = <ChatMessage>[];
    _resetHistoryState(chatId);
    _emit(ChatStoreChangeKind.messages, chatId);
    _log.i('已清空会话历史 $chatId');
  }

  /// 清空**全部**聊天记录（TG 的 Clear history，全局版；会话列表保留）。
  Future<void> clearAllHistory() async {
    var removed = 0;
    if (_chatsDir.existsSync()) {
      for (final f in _chatsDir.listSync()) {
        if (f is! File) continue;
        try {
          f.deleteSync();
          removed++;
        } catch (e) {
          _log.w('删除消息文件失败 ${f.path}', error: e);
        }
      }
    }
    for (final id in _messages.keys.toList()) {
      _messages[id] = <ChatMessage>[];
      _resetHistoryState(id);
    }
    _emit(ChatStoreChangeKind.messages);
    _log.i('已清空本地聊天记录（$removed 个文件）');
  }

  void _resetHistoryState(String chatId) {
    _cursors[chatId] = null;
    _hasMore[chatId] = false;
    _historyFetched[chatId] = false;
  }

  // ---------------------------------------------------------------------------
  // 会话级操作（置顶 / 免打扰 / 归档 / 标为未读 / 删除会话）
  //
  // 全都是**本地状态**：官方这几项在服务端也有一份，但那需要额外的 oidb 命令，
  // 我们还没核实过字段（见 AGENTS 的"语义二义只构建不自动发"）。先本地生效，
  // 协议同步留到做那一步时再加——所以这些开关在换设备后不会跟着走。
  // ---------------------------------------------------------------------------

  /// 置顶 / 取消置顶。
  Future<void> setChatPinned(String chatId, bool pinned) =>
      _patchChat(chatId, (c) => c.copyWith(pinned: pinned));

  /// 消息免打扰。
  Future<void> setChatMuted(String chatId, bool muted) =>
      _patchChat(chatId, (c) => c.copyWith(muted: muted));

  /// 归档 / 取消归档（列表里收进"已归档"入口）。
  Future<void> setChatArchived(String chatId, bool archived) =>
      _patchChat(chatId, (c) => c.copyWith(archived: archived));

  /// 草稿：随打随存（UI 侧做防抖），换会话/重启都还在。
  Future<void> setDraft(String chatId, String draft) => _patchChat(
        chatId,
        (c) => c.copyWith(draft: draft.isEmpty ? '' : draft),
      );

  /// 标为未读：把"已读位置"往回退一条，让未读分隔线落在最后一条之前。
  ///
  /// 退到哪儿：列表里倒数第二条之后（= 最后一条算未读）。只有一条消息时
  /// 锚点清空（整段都算未读）。没有消息可标就只是把计数设为 1。
  Future<void> markChatUnread(String chatId) {
    final list = _messages[chatId] ?? const <ChatMessage>[];
    final anchor = list.length >= 2 ? list[list.length - 2].id : null;
    return _patchChat(
      chatId,
      (c) => c.copyWith(
        unreadCount: 1,
        lastReadId: anchor,
        manualUnread: true,
      ),
    );
  }

  /// 删除会话：本地记录清空 + 从列表移除（官方叫"删除聊天"，不影响对方）。
  ///
  /// 和 [clearChatHistory] 的区别：那个留下会话壳子（还能收到新消息），
  /// 这个把壳子也去掉；下次服务端再推消息会重新建条目（[_touchChat] 有兜底）。
  Future<void> deleteChat(String chatId) async {
    final f = _messageFile(chatId);
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (e) {
      _log.w('删除消息文件失败 $chatId', error: e);
    }
    _messages.remove(chatId);
    _resetHistoryState(chatId);
    _chats.remove(chatId);
    if (_activeChatId == chatId) _activeChatId = null;
    _scheduleIndexPersist();
    _emit(ChatStoreChangeKind.messages, chatId);
    _emit(ChatStoreChangeKind.chats);
    _log.i('已删除会话 $chatId（仅本地）');
  }

  /// 删掉**一条**消息（仅本地，TG 的 "Delete for me"）。
  ///
  /// 对面不会知道（要让双方都看不到得走撤回，见 [recallMessage]）。
  /// 删的是最后一条时，顺手把会话摘要换成新的最后一条，否则列表上会留着
  /// 一条点不进去的预览。
  Future<void> deleteMessage(String chatId, String messageId) async {
    final list = _messages[chatId];
    if (list == null) return;
    final idx = _indexOf(chatId, messageId);
    if (idx < 0) return;
    list.removeAt(idx);
    _rewriteMessages(chatId);
    final chat = _chats[chatId];
    if (chat != null && chat.lastTime != null) {
      // 删的可能是最后一条（摘要要跟着换），也可能是唯一一条（摘要要清空）
      _chats[chatId] = list.isEmpty
          ? chat.clearedPreview()
          : chat.copyWith(
              lastMessage: list.last.displayText,
              lastTime: list.last.time,
            );
      _scheduleIndexPersist();
    }
    _emit(ChatStoreChangeKind.messages, chatId);
    _emit(ChatStoreChangeKind.chats);
    _log.d('已删除本地消息 $chatId/$messageId');
  }

  /// 在**已加载**的消息里搜文本（本地搜索，不打服务端）。
  ///
  /// 说明与边界：
  /// * 只搜内存/本地文件里已经有的消息——我们还没做服务端的全文检索
  ///   （官方是云端搜索，需要另一套协议），所以"搜不到"可能只是"这条还没拉下来"；
  /// * 大小写不敏感只对 ASCII 有意义；中文是子串匹配；
  /// * 结果按时间倒序（新的在前），最多 [limit] 条。
  List<({String chatId, ChatMessage message})> searchMessages(
    String query, {
    int limit = 50,
  }) {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final needle = q.toLowerCase();
    final hits = <({String chatId, ChatMessage message})>[];
    for (final entry in _messages.entries) {
      for (final m in entry.value) {
        if (m.text.toLowerCase().contains(needle)) {
          hits.add((chatId: entry.key, message: m));
        }
      }
    }
    hits.sort((a, b) => b.message.time.compareTo(a.message.time));
    return hits.length <= limit ? hits : hits.sublist(0, limit);
  }

  /// **仅测试用**：替换某条消息的 segments（自测里造富内容用，UI 不走这条路）。
  void replaceSegmentsForTest(
    String chatId,
    String messageId,
    List<Segment> segments,
  ) {
    final idx = _indexOf(chatId, messageId);
    if (idx < 0) return;
    final list = _messages[chatId]!;
    final m = list[idx];
    list[idx] = ChatMessage(
      id: m.id,
      text: m.text,
      segments: segments,
      time: m.time,
      outgoing: m.outgoing,
      senderId: m.senderId,
      senderName: m.senderName,
      chatId: m.chatId,
      replyToId: m.replyToId,
      replyPreview: m.replyPreview,
      deleted: m.deleted,
      recallInfo: m.recallInfo,
      revealed: m.revealed,
      atMe: m.atMe,
      system: m.system,
      senderTitle: m.senderTitle,
      sendState: m.sendState,
    );
    _emit(ChatStoreChangeKind.messages, chatId);
  }

  /// 把若干条消息**转发**到另一个会话。
  ///
  /// 语义：转发就是"把内容重发一遍"（官方经典线没有转发头，我们也不编）。
  /// 因此：
  /// * 引用关系**不带过去**——`src_msg` 指的是原会话里的某条消息，带过去就是错的；
  /// * 图片/语音/视频/文件/卡片**发不了**：它们要靠原来的 fid/md5 或上传后的新 fid
  ///   才能重发，我们还没做上传（见 `qq8_session_adapter.dart` 的说明）。
  ///   这种消息**一条都不发**并抛 [SessionException]——半截转发比失败更难查。
  ///
  /// 返回转发成功的条数。
  Future<int> forwardMessages({
    required String fromChatId,
    required List<String> messageIds,
    required String toChatId,
  }) async {
    final all = _messages[fromChatId] ?? const <ChatMessage>[];
    final picked = <ChatMessage>[
      for (final id in messageIds)
        for (final m in all)
          if (m.id == id) m,
    ];
    if (picked.isEmpty) return 0;

    for (final m in picked) {
      for (final seg in m.segments) {
        if (seg is TextSegment || seg is FaceSegment || seg is ReplySegment) {
          continue;
        }
        throw SessionException(
          '这条消息里有「${seg.preview}」，转发还没做（要先做文件上传/下载）',
        );
      }
    }

    var sent = 0;
    for (final m in picked) {
      final segments = <Segment>[
        for (final seg in m.segments)
          if (seg is! ReplySegment) seg,
      ];
      if (segments.isEmpty) continue;
      await send(toChatId, segments);
      sent++;
    }
    _log.i('转发 $sent 条：$fromChatId → $toChatId');
    return sent;
  }

  /// 改一个会话的本地字段并落盘、广播（上面几个开关的公共实现）。
  Future<void> _patchChat(String chatId, Chat Function(Chat) patch) async {
    final chat = _chats[chatId];
    if (chat == null) return;
    _chats[chatId] = patch(chat);
    _scheduleIndexPersist();
    _emit(ChatStoreChangeKind.chats);
  }

  /// 删文件并返回释放的字节数（失败只记日志，不抛）。
  int _deleteQuietly(File f) {
    try {
      final size = f.existsSync() ? f.lengthSync() : 0;
      if (f.existsSync()) f.deleteSync();
      return size;
    } catch (e) {
      _log.w('删除缓存文件失败 ${f.path}', error: e);
      return 0;
    }
  }

  /// 撤回自己发的一条消息（成功后本地立刻标记为已撤回）。
  ///
  /// 失败（超时时限、不是自己的消息、后端不支持…）会把 [SessionException]
  /// 原样抛给调用方——UI 该把服务端文案显示出来，**不要静默吞掉**。
  Future<void> recallMessage(String chatId, String messageId) async {
    if (session.state != SessionState.ready) {
      throw const SessionException('还没连上后端，不能撤回');
    }
    await session.recall(chatId, messageId);
    _ensureDiskLoaded(chatId);
    final idx = _indexOf(chatId, messageId);
    if (idx < 0) return;
    _messages[chatId]![idx] = _messages[chatId]![idx].recalled();
    _rewriteMessages(chatId);
    _emit(ChatStoreChangeKind.messages, chatId);
    _log.i('已撤回消息 $chatId/$messageId');
  }

  /// 揭示一条已撤回消息的原文（反撤回：撤回只打标记，内容一直留着）。
  ///
  /// 与 [ChatMessage.reveal] 对应；没撤回或已揭示的消息调用是空操作。
  /// 落盘走整文件重写（低频操作）。
  Future<void> revealMessage(String chatId, String messageId) async {
    _ensureDiskLoaded(chatId);
    final idx = _indexOf(chatId, messageId);
    if (idx < 0) return;
    final m = _messages[chatId]![idx];
    if (!m.deleted || m.revealed) return;
    _messages[chatId]![idx] = m.reveal();
    _rewriteMessages(chatId);
    _emit(ChatStoreChangeKind.messages, chatId);
    _log.i('已揭示撤回消息 $chatId/$messageId');
  }

  /// 找一条能与 echo 配对的本地乐观消息：同会话、同文本、还是 `local:` ID、
  /// 且没被配对过。失败的不算（它没发出去，不可能是 echo 的来源）。
  ChatMessage? _findEchoCandidate(String chatId, ChatMessage echo) {
    if (echo.text.isEmpty) return null;
    for (final m in _messages[chatId] ?? const <ChatMessage>[]) {
      if (!m.id.startsWith('local:')) continue;
      if (_echoMatched.contains(m.id)) continue;
      if (m.sendState == MessageSendState.failed) continue;
      if (m.text == echo.text) return m;
    }
    return null;
  }

  void _replaceLocalId(String chatId, String localId, String serverId) {
    final idx = _indexOf(chatId, localId);
    if (idx < 0) return;
    _echoMatched.add(localId);
    _messages[chatId]![idx] = _messages[chatId]![idx]
        .copyWith(id: serverId, sendState: MessageSendState.sent);
    _rewriteMessages(chatId);
    _emit(ChatStoreChangeKind.messages, chatId);
  }

  Future<void> _dispatch(String chatId, ChatMessage message) async {
    try {
      final serverId = await session.sendMessage(chatId, message.segments);
      _markDelivered(chatId, message.id, serverId);
    } on SessionException catch (e) {
      _markFailed(chatId, message.id, e.message);
    } catch (e) {
      _markFailed(chatId, message.id, '$e');
    }
  }

  void _markDelivered(String chatId, String localId, String? serverId) {
    final idx = _indexOf(chatId, localId);
    // idx < 0 说明这条已经被 echo 配对换过 ID 了，不用再做一遍
    if (idx < 0) return;
    final current = _messages[chatId]![idx];
    final hasServerId = serverId != null && serverId.isNotEmpty && serverId != current.id;
    _messages[chatId]![idx] = current.copyWith(
      id: hasServerId ? serverId : current.id,
      sendState: MessageSendState.sent,
    );
    if (hasServerId) _echoMatched.add(localId);
    _rewriteMessages(chatId);
    _emit(ChatStoreChangeKind.messages, chatId);
  }

  void _markFailed(String chatId, String messageId, String reason) {
    _log.w('发送失败（$reason），消息保留待重试');
    final idx = _indexOf(chatId, messageId);
    if (idx < 0) return;
    _messages[chatId]![idx] =
        _messages[chatId]![idx].copyWith(sendState: MessageSendState.failed);
    _rewriteMessages(chatId);
    _emit(ChatStoreChangeKind.messages, chatId);
  }

  // ---------------------------------------------------------------------------
  // 内存状态
  // ---------------------------------------------------------------------------

  int _indexOf(String chatId, String messageId) =>
      (_messages[chatId] ?? const <ChatMessage>[]).indexWhere((m) => m.id == messageId);

  /// 插入一条消息（按 ID 去重）。返回是否真的插进去了。
  bool _insertMessage(ChatMessage message, {required bool persist}) {
    final list = _messages.putIfAbsent(message.chatId, () => <ChatMessage>[]);
    if (list.any((m) => m.id == message.id)) return false;
    list.add(message);
    _sortMessages(message.chatId);
    if (persist) {
      _appendMessage(message);
      _trim(message.chatId);
    }
    return true;
  }

  /// 时间正序；同一时间戳保持插入先后。
  ///
  /// 不用 `List.sort`：Dart 的排序**不保证稳定**，同一秒内的多条消息
  /// 会在每次排序后随机换序，界面上表现为消息跳动。
  void _sortMessages(String chatId) {
    final list = _messages[chatId];
    if (list == null || list.length < 2) return;
    final decorated = [
      for (var i = 0; i < list.length; i++) (index: i, message: list[i]),
    ];
    decorated.sort((a, b) {
      final byTime = a.message.time.compareTo(b.message.time);
      return byTime != 0 ? byTime : a.index.compareTo(b.index);
    });
    _messages[chatId] = [for (final d in decorated) d.message];
  }

  void _mergePage(String chatId, HistoryPage page) {
    var added = 0;
    for (final m in page.messages) {
      if (_insertMessage(m, persist: false)) added++;
    }
    _cursors[chatId] = page.next;
    _hasMore[chatId] = page.hasMore;
    if (added == 0) return;

    _rewriteMessages(chatId);
    if (page.messages.isNotEmpty) {
      var newest = page.messages.first;
      for (final m in page.messages) {
        if (m.time.isAfter(newest.time)) newest = m;
      }
      _touchChat(chatId, newest);
    }
    _trim(chatId);
  }

  /// 更新会话摘要与未读数，并触发索引落盘。
  void _touchChat(String chatId, ChatMessage message, {bool bumpUnread = false}) {
    var chat = _chats[chatId];
    if (chat == null) {
      // 不在列表里的会话（陌生人临时会话、后端补推）：建占位，
      // 否则消息有了、入口没有，用户永远看不到它。
      final parsed = Chat.parseKey(chatId);
      chat = Chat(
        id: chatId,
        title: message.senderName.isNotEmpty ? message.senderName : chatId,
        type: parsed?.type ?? ChatType.private,
        rawId: parsed?.id,
      );
      _log.d('为未知会话 $chatId 建占位条目');
    }

    final newer = chat.lastTime == null || !message.time.isBefore(chat.lastTime!);
    if (newer) {
      chat = chat.copyWith(
        lastMessage: message.displayText,
        lastTime: message.time,
      );
    }
    if (bumpUnread && !message.outgoing) {
      chat = chat.copyWith(unreadCount: chat.unreadCount + 1);
    } else if (!message.outgoing) {
      // 活跃会话：用户人就在这个会话里，未读不涨，但"读到哪儿"要跟着走——
      // 否则下次打开会看到一条假的未读分隔线（那几条其实已经看过了）。
      chat = chat.copyWith(lastReadId: message.id);
    }
    _chats[chatId] = chat;
    _scheduleIndexPersist();
  }

  /// 合并远端会话与本地状态。
  ///
  /// 归属划分：标题/类型/成员数/在线状态以**服务端为准**（会改名、会退群）；
  /// 置顶/免打扰/优先级/未读**与已读位置**以**本地为准**（服务端不告诉我们这些，
  /// 已读位置丢了就等于"未读分隔线凭空跳到末尾"）；
  /// 摘要与时间取**更新的那个**（刚发出去的消息服务端列表里可能还没有）。
  Chat _mergeChat(Chat? local, Chat remote) {
    if (local == null) return remote;
    final keepLocalPreview = local.lastTime != null &&
        (remote.lastTime == null || local.lastTime!.isAfter(remote.lastTime!));
    return remote.copyWith(
      pinned: local.pinned,
      muted: local.muted,
      priority: local.priority,
      unreadCount: local.unreadCount,
      lastReadId: local.lastReadId,
      // 归档与草稿同样是本地状态，服务端那份列表里没有——不带上就会被合并冲掉
      archived: local.archived,
      draft: local.draft,
      manualUnread: local.manualUnread,
      lastMessage: keepLocalPreview ? local.lastMessage : remote.lastMessage,
      lastTime: keepLocalPreview ? local.lastTime : remote.lastTime,
    );
  }

  /// 体积闸门：把已送达消息压到 [maxMessagesPerChat] 以内。
  void _trim(String chatId) {
    if (_chats[chatId]?.pinned ?? false) return; // 置顶会话豁免
    final list = _messages[chatId];
    if (list == null) return;

    final delivered = <int>[
      for (var i = 0; i < list.length; i++)
        if (list[i].sendState == MessageSendState.sent) i,
    ];
    if (delivered.length <= maxMessagesPerChat) return;

    final drop = delivered.take(delivered.length - maxMessagesPerChat).toSet();
    _messages[chatId] = [
      for (var i = 0; i < list.length; i++)
        if (!drop.contains(i)) list[i],
    ];
    _rewriteMessages(chatId);
    _log.d('$chatId 淘汰最旧 ${drop.length} 条（上限 $maxMessagesPerChat）');
  }

  // ---------------------------------------------------------------------------
  // 持久化
  // ---------------------------------------------------------------------------

  Directory get _chatsDir => Directory('${dataDir.path}${Platform.pathSeparator}chats');

  /// 媒体缓存目录：`<dataDir>/media/<分类>/…`（分类见 [mediaCategories]）。
  Directory get _mediaDir => Directory('${dataDir.path}${Platform.pathSeparator}media');

  File get _indexFile => File('${dataDir.path}${Platform.pathSeparator}chats.json');

  File _messageFile(String chatId) =>
      File('${_chatsDir.path}${Platform.pathSeparator}${_safeName(chatId)}.jsonl');

  /// chatId 来自后端，不能让它决定磁盘路径。
  String _safeName(String chatId) =>
      chatId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  void _ensureDiskLoaded(String chatId) {
    if (_diskLoaded[chatId] == true) return;
    _diskLoaded[chatId] = true;

    final list = _messages.putIfAbsent(chatId, () => <ChatMessage>[]);
    final file = _messageFile(chatId);
    if (!file.existsSync()) return;

    var skipped = 0;
    for (final line in file.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) {
          skipped++;
          continue;
        }
        final message = _messageFromJson(decoded.cast<String, dynamic>());
        if (message == null) {
          skipped++;
          continue;
        }
        if (!list.any((m) => m.id == message.id)) list.add(message);
      } on FormatException {
        // 半截 JSON：进程被杀时最后一行没写完，属预期情况，跳过即可
        skipped++;
      } catch (_) {
        skipped++;
      }
    }
    if (skipped > 0) {
      _log.w('${file.path} 有 $skipped 行无法解析，已跳过');
    }
    _sortMessages(chatId);
  }

  void _appendMessage(ChatMessage message) {
    try {
      _chatsDir.createSync(recursive: true);
      final raf = _messageFile(message.chatId).openSync(mode: FileMode.append);
      try {
        raf.writeStringSync('${jsonEncode(_messageToJson(message))}\n');
      } finally {
        raf.closeSync();
      }
    } catch (e) {
      _log.w('消息落盘失败', error: e);
    }
  }

  void _rewriteMessages(String chatId) {
    try {
      _chatsDir.createSync(recursive: true);
      final raf = _messageFile(chatId).openSync(mode: FileMode.write);
      try {
        for (final m in _messages[chatId] ?? const <ChatMessage>[]) {
          raf.writeStringSync('${jsonEncode(_messageToJson(m))}\n');
        }
      } finally {
        raf.closeSync();
      }
    } catch (e) {
      _log.w('消息文件重写失败', error: e);
    }
  }

  void _scheduleIndexPersist() {
    _indexTimer?.cancel();
    _indexTimer = Timer(_indexDebounce, _persistIndex);
  }

  void _persistIndex() {
    _indexTimer?.cancel();
    _indexTimer = null;
    // 没 bootstrap 过就没读过索引：此时写下去等于把别人的会话列表清空
    if (!_bootstrapped) return;
    try {
      _indexFile.writeAsStringSync(
        jsonEncode(_chats.values.map(_chatToJson).toList()),
      );
    } catch (e) {
      _log.w('会话索引写入失败', error: e);
    }
  }

  void _loadIndex() {
    final file = _indexFile;
    if (!file.existsSync()) return;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      // 兼容裸数组与 {'chats': [...]} 两种写法
      final list = decoded is List
          ? decoded
          : (decoded is Map ? decoded['chats'] : null);
      if (list is! List) {
        _log.w('会话索引格式不认识，按空处理');
        return;
      }
      for (final entry in list) {
        if (entry is! Map) continue;
        final chat = _chatFromJson(entry.cast<String, dynamic>());
        if (chat != null) _chats[chat.id] = chat;
      }
    } on FormatException catch (e) {
      _log.w('会话索引损坏，按空处理：$e');
    } catch (e) {
      _log.w('会话索引读取失败，按空处理', error: e);
    }
  }

  void _emit(ChatStoreChangeKind kind, [String? chatId]) {
    if (_disposed || _changes.isClosed) return;
    _changes.add(ChatStoreChange(kind, chatId: chatId));
  }

  // ---------------------------------------------------------------------------
  // 序列化
  //
  // 段用 OneBot 的 array 格式（`[{type,data}]`）落盘，与 [Segment.parseList]
  // 对称。代价是个别段的次要字段会丢（`ReplySegment.time`、
  // `ForwardSegment.content`）——它们都能从后端重新拉，不值得为它们
  // 在 L3 里另造一套比协议更全的持久化格式。
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _messageToJson(ChatMessage m) => {
        'id': m.id,
        'chat': m.chatId,
        'time': m.time.millisecondsSinceEpoch,
        'text': m.text,
        'out': m.outgoing,
        'senderId': m.senderId,
        'senderName': m.senderName,
        'segments': Segment.toArrayData(m.segments),
        if (m.replyToId != null) 'replyTo': m.replyToId,
        if (m.replyPreview != null) 'replyPreview': m.replyPreview,
        if (m.deleted) 'deleted': true,
        if (m.recallInfo != null) 'recallInfo': m.recallInfo,
        if (m.revealed) 'revealed': true,
        if (m.atMe) 'atMe': true,
        if (m.system) 'system': true,
        if (m.senderTitle != null) 'senderTitle': m.senderTitle,
        if (m.sendState != MessageSendState.sent) 'send': m.sendState.name,
      };

  ChatMessage? _messageFromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final time = j['time'];
    if (id is! String || id.isEmpty || time is! int) return null;
    return ChatMessage(
      id: id,
      chatId: (j['chat'] as String?) ?? '',
      time: DateTime.fromMillisecondsSinceEpoch(time),
      text: (j['text'] as String?) ?? '',
      outgoing: j['out'] == true,
      senderId: (j['senderId'] as String?) ?? '',
      senderName: (j['senderName'] as String?) ?? '',
      segments: Segment.parseList(j['segments']),
      replyToId: j['replyTo'] as String?,
      replyPreview: j['replyPreview'] as String?,
      deleted: j['deleted'] == true,
      recallInfo: j['recallInfo'] as String?,
      revealed: j['revealed'] == true,
      atMe: j['atMe'] == true,
      system: j['system'] == true,
      senderTitle: j['senderTitle'] as String?,
      sendState: MessageSendState.values.firstWhere(
        (s) => s.name == j['send'],
        orElse: () => MessageSendState.sent,
      ),
    );
  }

  Map<String, dynamic> _chatToJson(Chat c) => {
        'id': c.id,
        'title': c.title,
        'type': c.type.wireName,
        if (c.rawId != null) 'rawId': c.rawId,
        if (c.memberCount != 0) 'memberCount': c.memberCount,
        if (c.ownerUin != 0) 'ownerUin': c.ownerUin,
        if (c.pinned) 'pinned': true,
        if (c.muted) 'muted': true,
        if (c.priority != 3) 'priority': c.priority,
        'lastMessage': c.lastMessage,
        if (c.lastTime != null) 'lastTime': c.lastTime!.millisecondsSinceEpoch,
        if (c.unreadCount != 0) 'unread': c.unreadCount,
        if (c.lastReadId != null) 'lastRead': c.lastReadId,
        if (c.archived) 'archived': true,
        if (c.draft.isNotEmpty) 'draft': c.draft,
        if (c.manualUnread) 'manualUnread': true,
        if (c.online) 'online': true,
      };

  Chat? _chatFromJson(Map<String, dynamic> j) {
    final id = j['id'];
    if (id is! String || id.isEmpty) return null;
    final lastTime = j['lastTime'];
    return Chat(
      id: id,
      title: (j['title'] as String?) ?? id,
      type: ChatType.parse(j['type'] as String?),
      rawId: j['rawId'] as int?,
      memberCount: (j['memberCount'] as int?) ?? 0,
      ownerUin: (j['ownerUin'] as int?) ?? 0,
      pinned: j['pinned'] == true,
      muted: j['muted'] == true,
      priority: (j['priority'] as int?) ?? 3,
      lastMessage: (j['lastMessage'] as String?) ?? '',
      lastTime: lastTime is int ? DateTime.fromMillisecondsSinceEpoch(lastTime) : null,
      unreadCount: (j['unread'] as int?) ?? 0,
      lastReadId: j['lastRead'] as String?,
      archived: j['archived'] == true,
      draft: (j['draft'] as String?) ?? '',
      manualUnread: j['manualUnread'] == true,
      online: j['online'] == true,
    );
  }
}

/// 本地占用统计（UI 的"存储与缓存"页用它显示）。
///
/// 刻意把**消息库**与**媒体缓存**分开报：前者不该被当成缓存清掉，
/// 用户看到"聊天记录 3MB / 媒体缓存 800MB"才知道清哪个有用。
class StorageStats {
  /// 消息库（`chats.json` + `chats/*.jsonl`）。
  final int dbBytes;

  /// 媒体缓存（`media/` 下的全部文件）。
  final int cacheBytes;

  /// 按分类拆开的媒体占用（键见 [ChatStore.mediaCategories]，未来才可能有内容）。
  final Map<String, int> cacheByCategory;

  /// 按会话拆开的消息库占用（chatId → 字节）。
  final Map<String, int> dbByChat;

  /// 内存里当前持有的消息条数（不是磁盘上的全量）。
  final int messageCount;
  final int chatCount;

  const StorageStats({
    required this.dbBytes,
    required this.cacheBytes,
    this.cacheByCategory = const <String, int>{},
    this.dbByChat = const <String, int>{},
    this.messageCount = 0,
    this.chatCount = 0,
  });

  int get totalBytes => dbBytes + cacheBytes;

  /// 给人看的体积（B / KB / MB / GB）。
  static String formatBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  String toString() => 'StorageStats(db=${formatBytes(dbBytes)}, '
      'cache=${formatBytes(cacheBytes)}, chats=$chatCount, msgs=$messageCount)';
}
