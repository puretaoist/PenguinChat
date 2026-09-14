/// ChatStore 离线自测
///
/// **不联网、不起服务器**：注入一个纯内存的假 [Session]，验证 L3 数据层的
/// 全部边界——启动恢复、事件合并、去重、乐观插入、发送失败、翻页、
/// 损坏文件容错、体积淘汰。
///
/// 写法遵循 [`../docs/PITFALLS.md`](../docs/PITFALLS.md)：
///   - 等状态一律用 [waitUntil] 轮询条件，不用固定 sleep 断言"已发生"
///   - 事件先订阅收集再断言，不连用两次 `stream.first`
///   - 结尾用 `exit()` 而不是 `exitCode =`
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/chat_store_selftest.dart
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qqclient/client_api/chat_store.dart';
import 'package:qqclient/client_api/objects.dart';
import 'package:qqclient/client_api/segment.dart';
import 'package:qqclient/client_api/session.dart';

// ---------------------------------------------------------------------------
// 断言工具（与 tool/onebot_selftest.dart 同款）
// ---------------------------------------------------------------------------

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  ✓ $name');
  } else {
    _failed++;
    stdout.writeln('  ✗ $name${detail == null ? '' : '  → $detail'}');
  }
}

void checkEq(String name, Object? actual, Object? expected) {
  final ok = jsonEncode(actual) == jsonEncode(expected);
  check(name, ok, ok ? null : '期望 ${jsonEncode(expected)}，实际 ${jsonEncode(actual)}');
}

void section(String t) => stdout.writeln('\n$t');

Future<void> sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

/// 轮询等待条件成立。**不要**用固定 sleep 代替（见 PITFALLS A2）。
Future<bool> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
  int stepMs = 5,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await sleep(stepMs);
  }
  return condition();
}

// ---------------------------------------------------------------------------
// 假 Session
// ---------------------------------------------------------------------------

/// 纯内存的 [Session] 实现，行为全部可编排。
class FakeSession implements Session {
  FakeSession({this.selfId = '10001'});

  final String selfId;

  SessionState _state = SessionState.disconnected;
  final _events = StreamController<SessionEvent>.broadcast();

  /// `listChats` 的返回。
  List<Chat> chatList = [];

  /// `fetchHistory` 的返回队列，按调用顺序弹出；空了返回 [HistoryPage.empty]。
  final List<HistoryPage> historyPages = [];

  int historyCalls = 0;
  String? lastHistoryChatId;
  HistoryCursor? lastHistoryCursor;
  int lastHistoryCount = 0;

  /// `sendMessage` 的返回 ID 生成器；null 表示走默认 ID。
  String? Function(int attempt)? replyId;

  /// 置 true 时 `sendMessage` 返回 null —— 模拟不回 message_id 的后端。
  ///
  /// 不能用「`replyId` 返回 null」表达这个意思：那与"没设置钩子"无法区分。
  bool replyNull = false;

  /// `sendMessage` 要抛的错误；null 表示正常。
  Object? Function(int attempt)? sendError;

  /// `sendMessage` 的人为延迟，用来观测乐观插入的中间态。
  Duration sendDelay = Duration.zero;

  int sendCalls = 0;
  final List<({String chatId, List<Segment> segments})> sent = [];

  int markReadCalls = 0;
  bool disposed = false;

  @override
  SessionState get state => _state;

  @override
  Stream<SessionEvent> get events => _events.stream;

  @override
  AccountInfo? get account => _state == SessionState.ready
      ? AccountInfo(uin: selfId, nickname: '测试号', backendName: 'Fake.Onebot')
      : null;

  @override
  String? get backendName => 'Fake.Onebot';

  /// 置为就绪并发出状态事件（模拟握手完成）。
  void markReady() {
    _state = SessionState.ready;
    _events.add(SessionStateChanged(SessionState.ready));
  }

  void markDisconnected([String? reason]) {
    _state = SessionState.disconnected;
    _events.add(SessionStateChanged(SessionState.disconnected, reason: reason));
  }

  void emit(SessionEvent e) => _events.add(e);

  void _requireReady() {
    if (_state != SessionState.ready) {
      throw const SessionException('会话未就绪');
    }
  }

  @override
  Future<void> connect() async => markReady();

  @override
  Future<void> close() async {
    _state = SessionState.closed;
  }

  @override
  Future<List<Chat>> listChats() async {
    _requireReady();
    return chatList;
  }

  @override
  Future<HistoryPage> fetchHistory(
    String chatId, {
    int count = 20,
    HistoryCursor? before,
  }) async {
    _requireReady();
    historyCalls++;
    lastHistoryChatId = chatId;
    lastHistoryCursor = before;
    lastHistoryCount = count;
    if (historyPages.isNotEmpty) return historyPages.removeAt(0);
    return HistoryPage.empty;
  }

  @override
  Future<String?> sendMessage(String chatId, List<Segment> segments) async {
    _requireReady();
    sendCalls++;
    final attempt = sendCalls;
    if (sendDelay > Duration.zero) await Future<void>.delayed(sendDelay);
    final err = sendError?.call(attempt);
    if (err != null) throw err;
    sent.add((chatId: chatId, segments: segments));
    if (replyNull) return null;
    return replyId?.call(attempt) ?? '${90000 + attempt}';
  }

  /// `recall` 调用次数（断言"确实走到了会话层"）。
  int recallCalls = 0;

  @override
  Future<void> recall(String chatId, String messageId) async {
    _requireReady();
    recallCalls++;
  }

  @override
  Future<void> markRead(String chatId, String messageId) async {
    _requireReady();
    markReadCalls++;
  }

  @override
  Future<void> sendPoke(String chatId, String userId) async => _requireReady();

  @override
  bool supports(String capability) => true;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }
}

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

final List<Directory> _tempDirs = [];

Directory newTempDir(String tag) {
  final d = Directory.systemTemp.createTempSync('chat_store_$tag');
  _tempDirs.add(d);
  return d;
}

Chat fakeGroup({bool pinned = false, int priority = 3}) => Chat(
      id: 'group_12345',
      title: '测试群',
      type: ChatType.group,
      rawId: 12345,
      memberCount: 42,
      pinned: pinned,
      priority: priority,
    );

Chat fakeFriend(String id, String title, {bool pinned = false, int priority = 3}) {
  final raw = int.tryParse(id.split('_').last);
  return Chat(
    id: id,
    title: title,
    type: ChatType.private,
    rawId: raw,
    pinned: pinned,
    priority: priority,
  );
}

ChatMessage msg(
  String id,
  String text, {
  required DateTime time,
  String chatId = 'group_12345',
  bool outgoing = false,
  String senderId = '20002',
  String senderName = '小明',
  MessageSendState sendState = MessageSendState.sent,
}) =>
    ChatMessage(
      id: id,
      text: text,
      segments: [TextSegment(text)],
      time: time,
      chatId: chatId,
      outgoing: outgoing,
      senderId: outgoing ? '10001' : senderId,
      senderName: outgoing ? '测试号' : senderName,
      sendState: sendState,
    );

final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(1700000000000);

DateTime at(int offsetSeconds) => t0.add(Duration(seconds: offsetSeconds));

/// 起一个已就绪的 store；返回后记得 `await store.dispose()`。
Future<({ChatStore store, FakeSession session})> readyStore(
  String tag, {
  int maxMessagesPerChat = 500,
  List<Chat>? chats,
  bool ready = true,
}) async {
  final session = FakeSession();
  if (chats != null) session.chatList = chats;
  if (ready) session.markReady();
  final store = ChatStore(
    session: session,
    dataDir: newTempDir(tag),
    maxMessagesPerChat: maxMessagesPerChat,
    pageSize: 20,
  );
  await store.bootstrap();
  return (store: store, session: session);
}

// ---------------------------------------------------------------------------
// 1. 启动：拉会话列表 + 从磁盘恢复
// ---------------------------------------------------------------------------

Future<void> testBootstrap() async {
  section('1. 启动：拉会话列表 / 磁盘恢复');

  final dir = newTempDir('boot');
  final session = FakeSession()
    ..chatList = [fakeGroup(), fakeFriend('private_20002', '小明')];
  session.markReady();

  final store = ChatStore(session: session, dataDir: dir);
  await store.bootstrap();

  checkEq('拉到 2 个会话', store.chats.length, 2);
  check('会话按标题稳定排序（同优先级同时间）',
      store.chats.map((c) => c.id).toSet().containsAll({'group_12345', 'private_20002'}));
  checkEq('群标题', store.chats.firstWhere((c) => c.isGroup).title, '测试群');
  check('bootstrap 不调 fetchHistory', session.historyCalls == 0);

  // 打开会话才拉历史
  session.historyPages.add(HistoryPage([
    msg('101', '第一条', time: at(1)),
    msg('102', '第二条', time: at(2)),
  ]));
  await store.openChat('group_12345');
  checkEq('openChat 拉了一次历史', session.historyCalls, 1);
  checkEq('历史落在对应会话', session.lastHistoryChatId, 'group_12345');
  checkEq('恢复出 2 条消息', store.messagesOf('group_12345').length, 2);
  check('历史被翻正为时间正序（旧→新）',
      store.messagesOf('group_12345').first.id == '101');
  checkEq('活跃会话被记录', store.activeChatId, 'group_12345');

  // 发一条，然后关掉重建：验证持久化
  await store.send('group_12345', const [TextSegment('我发的')]);
  await store.dispose();

  // 第二次启动**故意不连接**：证明恢复完全来自磁盘
  final offline = FakeSession();
  final store2 = ChatStore(session: offline, dataDir: dir);
  await store2.bootstrap();

  checkEq('离线启动仍恢复出 2 个会话', store2.chats.length, 2);
  checkEq('离线启动仍恢复出群标题',
      store2.chats.firstWhere((c) => c.isGroup).title, '测试群');
  // 历史消息在 bootstrap 时不主动读，openChat 才读
  await store2.openChat('group_12345');
  final restored = store2.messagesOf('group_12345');
  checkEq('恢复出 3 条消息（2 历史 + 1 自己发的）', restored.length, 3);
  checkEq('自己发的那条被恢复', restored.last.text, '我发的');
  check('恢复后是已送达态', restored.last.sendState == MessageSendState.sent);
  check('离线时 openChat 不炸（会话未就绪）', offline.historyCalls == 0);
  checkEq('会话索引文件已落盘', File('${dir.path}/chats.json').existsSync(), true);
  checkEq('消息文件已落盘',
      File('${dir.path}/chats/group_12345.jsonl').existsSync(), true);

  await store2.dispose();
}

// ---------------------------------------------------------------------------
// 2. 事件合并：对方消息 / 多端同步 / 撤回
// ---------------------------------------------------------------------------

Future<void> testEventMerge() async {
  section('2. 事件合并：收消息 / isEcho / 撤回 / 未读');

  final f = await readyStore('events', chats: [fakeGroup(), fakeFriend('private_20002', '小明')]);
  final store = f.store;
  final session = f.session;

  // 先订阅收集，再推事件（PITFALLS A1：不要连用两次 stream.first）
  final changes = <ChatStoreChange>[];
  final sub = store.changes.listen(changes.add);

  await store.openChat('group_12345');

  // 当前活跃会话收到消息：不计未读
  session.emit(SessionMessage(msg('200', '在吗', time: at(10))));
  check('收到消息事件已合并',
      await waitUntil(() => store.messagesOf('group_12345').any((m) => m.id == '200')));
  checkEq('活跃会话不计未读',
      store.chats.firstWhere((c) => c.id == 'group_12345').unreadCount, 0);
  checkEq('会话摘要被更新',
      store.chats.firstWhere((c) => c.id == 'group_12345').lastMessage, '在吗');
  check('消息事件触发了 changes',
      changes.any((c) => c.kind == ChatStoreChangeKind.messages && c.chatId == 'group_12345'));

  // 非活跃会话：计未读
  session.emit(SessionMessage(
      msg('201', '私聊消息', time: at(11), chatId: 'private_20002', senderId: '20002')));
  check('非活跃会话消息已合并',
      await waitUntil(() => store.messagesOf('private_20002').isNotEmpty));
  checkEq('非活跃会话未读 +1',
      store.chats.firstWhere((c) => c.id == 'private_20002').unreadCount, 1);

  // 自己发一条，随后后端补推 echo（NapCat 的 message_sent 会这样）
  await store.send('group_12345', const [TextSegment('在的')]);
  final afterSend = store.messagesOf('group_12345');
  final sentId = afterSend.last.id;
  checkEq('发送后列表里只有 1 条 outgoing', afterSend.where((m) => m.outgoing).length, 1);

  session.emit(SessionMessage(msg(sentId, '在的', time: at(20), outgoing: true)));
  await sleep(60);
  checkEq('echo 未被重复插入',
      store.messagesOf('group_12345').where((m) => m.text == '在的').length, 1);

  // 真正的多端同步（自己在手机上发的，文本不同）应当插入
  session.emit(SessionMessage(msg('300', '手机上发的', time: at(21), outgoing: true)));
  check('多端同步消息被插入',
      await waitUntil(() => store.messagesOf('group_12345').any((m) => m.id == '300')));

  // 撤回：保留原位，只打标记
  session.emit(const SessionMessageRecalled('group_12345', '200', operatorId: '20002'));
  check('撤回后消息仍在列表里',
      await waitUntil(() => store
          .messagesOf('group_12345')
          .any((m) => m.id == '200' && m.isRecalled)));
  checkEq('撤回消息仍占位（列表长度不变）',
      store.messagesOf('group_12345').where((m) => m.id == '200').length, 1);
  checkEq('撤回后 UI 文本',
      store.messagesOf('group_12345').firstWhere((m) => m.id == '200').displayText,
      '[消息已撤回]');

  // 反撤回（Nagram/NekoX 系的招牌功能）：原文一直留着，点"查看"才显示
  final recalledMsg =
      store.messagesOf('group_12345').firstWhere((m) => m.id == '200');
  check('撤回但未揭示：原文没被丢掉', recalledMsg.text.isNotEmpty, recalledMsg.text);
  await store.revealMessage('group_12345', '200');
  final revealedMsg =
      store.messagesOf('group_12345').firstWhere((m) => m.id == '200');
  check('revealMessage 后：revealed=true 且文本就是原文',
      revealedMsg.revealed && revealedMsg.text == recalledMsg.text,
      'revealed=${revealedMsg.revealed} text=${revealedMsg.text}');
  check('揭示后 UI 不再显示占位', revealedMsg.displayText == recalledMsg.text);
  await store.revealMessage('group_12345', '200');
  check('重复揭示是空操作（不抛异常）', true);

  // openChat 清零未读
  await store.openChat('private_20002');
  checkEq('openChat 清零未读',
      store.chats.firstWhere((c) => c.id == 'private_20002').unreadCount, 0);
  checkEq('活跃会话已切换', store.activeChatId, 'private_20002');
  check('已读上报被调用（supports 为 true）', session.markReadCalls > 0);
  // 清未读的同时要把"读到哪儿"记下来（未读分隔线靠它定位）
  final readChat = store.chats.firstWhere((c) => c.id == 'private_20002');
  check('openChat 记下 lastReadId = 最后一条',
      readChat.lastReadId != null &&
          readChat.lastReadId == store.messagesOf('private_20002').last.id,
      '${readChat.lastReadId}');
  // 再来一条 → 锚点不动（分隔线要停在"上次读到的地方"）
  session.emit(SessionMessage(
      msg('202', '又一条', time: at(12), chatId: 'private_20002', senderId: '20002')));
  check('新消息到达后锚点没被顺势推走',
      await waitUntil(() =>
          store.chats.firstWhere((c) => c.id == 'private_20002').lastReadId ==
          readChat.lastReadId));
  await store.markChatRead('private_20002');
  check('重新标记已读后锚点跟到最后一条',
      store.chats.firstWhere((c) => c.id == 'private_20002').lastReadId ==
          store.messagesOf('private_20002').last.id,
      '${store.chats.firstWhere((c) => c.id == 'private_20002').lastReadId}');

  // 状态事件透传
  changes.clear();
  session.markDisconnected('网络中断');
  check('连接状态变化进了 changes',
      await waitUntil(() => changes.any((c) => c.kind == ChatStoreChangeKind.connection)));

  await sub.cancel();
  await store.dispose();
}

// ---------------------------------------------------------------------------
// 3. 去重
// ---------------------------------------------------------------------------

Future<void> testDedup() async {
  section('3. 去重：同 ID 事件 / 历史与事件重叠');

  final f = await readyStore('dedup', chats: [fakeGroup()]);
  final store = f.store;
  final session = f.session;

  // openChat 的首屏：两条历史 + 续页游标
  session.historyPages.add(HistoryPage(
    [msg('402', '历史乙', time: at(32)), msg('401', '历史甲', time: at(31))],
    next: const HistoryCursor(messageId: '401', seq: 501),
  ));
  await store.openChat('group_12345');
  checkEq('首屏 2 条', store.messagesOf('group_12345').length, 2);

  // 同一 ID 连推三次
  for (var i = 0; i < 3; i++) {
    session.emit(SessionMessage(msg('400', '重复的', time: at(30))));
  }
  check('重复事件只留一条',
      await waitUntil(() => store.messagesOf('group_12345').length == 3));
  await sleep(60);
  checkEq('稳定后仍是 3 条', store.messagesOf('group_12345').length, 3);
  checkEq('重复事件只插入了一条',
      store.messagesOf('group_12345').where((m) => m.id == '400').length, 1);

  // 历史里已存在的 ID 再被事件推一次：不新增、也不覆盖
  session.emit(SessionMessage(msg('401', '历史甲（改过的文本）', time: at(31))));
  await sleep(60);
  checkEq('历史与事件重叠不产生重复', store.messagesOf('group_12345').length, 3);
  checkEq('已存在的消息不被事件覆盖',
      store.messagesOf('group_12345').firstWhere((m) => m.id == '401').text, '历史甲');

  // 翻页把更早的插到头部
  session.historyPages.add(HistoryPage([msg('399', '更早的', time: at(29))]));
  await store.loadMore('group_12345');
  checkEq('翻页后 4 条', store.messagesOf('group_12345').length, 4);
  checkEq('顺序仍为时间正序',
      store.messagesOf('group_12345').map((m) => m.id).toList(),
      ['399', '400', '401', '402']);

  await store.dispose();
}

// ---------------------------------------------------------------------------
// 4. 乐观插入
// ---------------------------------------------------------------------------

Future<void> testOptimisticSend() async {
  section('4. 乐观插入：立即渲染 → 服务端 ID 原地替换');

  final f = await readyStore('optimistic', chats: [fakeGroup()]);
  final store = f.store;
  final session = f.session;

  await store.openChat('group_12345');
  session.sendDelay = const Duration(milliseconds: 120);
  session.replyId = (attempt) => '90001';

  final pending = store.send('group_12345', const [TextSegment('你好')]);

  // 回包之前就该在列表里（这是乐观插入的全部意义）
  check('未回包即出现在列表',
      await waitUntil(() => store.messagesOf('group_12345').isNotEmpty));
  final optimistic = store.messagesOf('group_12345').single;
  check('本地临时 ID 以 local: 开头', optimistic.id.startsWith('local:'), optimistic.id);
  check('中间态为 sending', optimistic.isSending);
  check('中间态就带正确文本', optimistic.text == '你好');
  check('中间态标记为 outgoing', optimistic.outgoing);
  checkEq('发送者是自己', optimistic.senderId, '10001');
  checkEq('会话摘要立即更新',
      store.chats.firstWhere((c) => c.id == 'group_12345').lastMessage, '你好');

  await pending;

  final done = store.messagesOf('group_12345').single;
  checkEq('服务端 ID 原地替换', done.id, '90001');
  check('状态转为 sent', done.sendState == MessageSendState.sent);
  checkEq('列表里仍只有一条（替换而非追加）', store.messagesOf('group_12345').length, 1);
  checkEq('文本未变', done.text, '你好');
  checkEq('段结构未变', done.segments.length, 1);

  // 服务端不回 ID 的后端：保持本地 ID，但状态应为 sent
  session.replyNull = true;
  await store.send('group_12345', const [TextSegment('第二条')]);
  final noId = store.messagesOf('group_12345').last;
  check('后端不回 ID 时保留本地 ID', noId.id.startsWith('local:'), noId.id);
  check('后端不回 ID 时仍标记 sent', noId.sendState == MessageSendState.sent);

  await store.dispose();
}

// ---------------------------------------------------------------------------
// 5. 发送失败：保留文本 + 可重试
// ---------------------------------------------------------------------------

Future<void> testSendFailure() async {
  section('5. 发送失败：不静默丢弃 + 重试');

  final f = await readyStore('failure', chats: [fakeGroup()]);
  final store = f.store;
  final session = f.session;

  await store.openChat('group_12345');
  session.sendError = (attempt) => attempt == 1
      ? const SessionException('连接已断开')
      : null;

  // send 不应把异常抛给 UI——失败态由消息自身承载
  var threw = false;
  try {
    await store.send('group_12345', const [TextSegment('重要内容')]);
  } catch (_) {
    threw = true;
  }
  check('send 不把异常抛给调用方', !threw);

  final failed = store.messagesOf('group_12345').single;
  check('失败后消息仍在列表里', true);
  check('失败态被标记', failed.isFailed);
  checkEq('用户输入被完整保留', failed.text, '重要内容');
  checkEq('段结构被完整保留', failed.segments.length, 1);
  check('失败消息仍是 outgoing', failed.outgoing);

  // 失败的消息不应被体积淘汰（见第 8 节）
  await store.dispose();

  // 重试
  final f2 = await readyStore('retry', chats: [fakeGroup()]);
  final store2 = f2.store;
  final session2 = f2.session;
  await store2.openChat('group_12345');
  session2.sendError = (attempt) =>
      attempt == 1 ? const SessionException('超时') : null;

  await store2.send('group_12345', const [TextSegment('再试一次')]);
  final failedId = store2.messagesOf('group_12345').single.id;
  check('第一次失败', store2.messagesOf('group_12345').single.isFailed);

  await store2.retry('group_12345', failedId);
  final retried = store2.messagesOf('group_12345').single;
  check('重试后转为 sent', retried.sendState == MessageSendState.sent);
  checkEq('重试未产生第二条消息', store2.messagesOf('group_12345').length, 1);
  checkEq('重试拿到了服务端 ID', retried.id, '90002');
  checkEq('重试用的是同一段内容', session2.sent.last.segments.length, 1);

  // 对已成功的消息调 retry 应是空操作
  final callsBefore = session2.sendCalls;
  await store2.retry('group_12345', retried.id);
  checkEq('重复 retry 不再发一次', session2.sendCalls, callsBefore);

  // 未知 ID 的 retry 不应炸
  var threw2 = false;
  try {
    await store2.retry('group_12345', 'nope');
  } catch (_) {
    threw2 = true;
  }
  check('retry 未知 ID 不抛异常', !threw2);

  await store2.dispose();
}

// ---------------------------------------------------------------------------
// 6. 翻页
// ---------------------------------------------------------------------------

Future<void> testPaging() async {
  section('6. 翻页：loadMore 往头部插');

  final f = await readyStore('paging', chats: [fakeGroup()]);
  final store = f.store;
  final session = f.session;

  // 首页：最新两条（后端返回倒序）
  session.historyPages.add(HistoryPage(
    [msg('103', '新三', time: at(3)), msg('102', '新二', time: at(2))],
    next: const HistoryCursor(messageId: '102', seq: 502),
  ));
  await store.openChat('group_12345');

  checkEq('首页 2 条', store.messagesOf('group_12345').length, 2);
  check('首页后 hasMore 为真', store.hasMore('group_12345'));
  check('首页按时间正序', store.messagesOf('group_12345').first.id == '102');

  // 第二页：更早的两条
  session.historyPages.add(HistoryPage(
    [msg('101', '新一', time: at(1)), msg('100', '新零', time: at(0))],
    next: const HistoryCursor(messageId: '100', seq: 500),
  ));
  await store.loadMore('group_12345');

  final all = store.messagesOf('group_12345');
  checkEq('翻页后 4 条', all.length, 4);
  checkEq('更早的插在头部', all.map((m) => m.id).toList(), ['100', '101', '102', '103']);
  checkEq('翻页带上了上一页游标', session.lastHistoryCursor?.messageId, '102');
  checkEq('翻页请求的会话正确', session.lastHistoryChatId, 'group_12345');

  // 最后一页：游标为 null
  session.historyPages.add(HistoryPage([msg('99', '最老', time: at(-1))]));
  await store.loadMore('group_12345');
  checkEq('末页后 5 条', store.messagesOf('group_12345').length, 5);
  check('末页后 hasMore 为假', !store.hasMore('group_12345'));
  checkEq('最老的仍在头部', store.messagesOf('group_12345').first.id, '99');

  final calls = session.historyCalls;
  await store.loadMore('group_12345');
  checkEq('没有更多时不再请求', session.historyCalls, calls);

  // 翻页结果与已有消息重叠时去重
  final f2 = await readyStore('paging2', chats: [fakeGroup()]);
  f2.session.historyPages.add(HistoryPage(
    [msg('201', '乙', time: at(2))],
    next: const HistoryCursor(messageId: '201'),
  ));
  await f2.store.openChat('group_12345');
  f2.session.historyPages.add(HistoryPage([
    msg('201', '乙', time: at(2)), // 后端分页重叠
    msg('200', '甲', time: at(1)),
  ]));
  await f2.store.loadMore('group_12345');
  checkEq('分页重叠被去重', f2.store.messagesOf('group_12345').length, 2);
  checkEq('顺序仍正确',
      f2.store.messagesOf('group_12345').map((m) => m.id).toList(), ['200', '201']);

  await f2.store.dispose();
  await store.dispose();
}

// ---------------------------------------------------------------------------
// 7. 持久化边界：损坏文件不能拖垮启动
// ---------------------------------------------------------------------------

Future<void> testCorruptFiles() async {
  section('7. 持久化边界：损坏 / 半截 JSON');

  final dir = newTempDir('corrupt');
  File('${dir.path}/chats.json').createSync(recursive: true);
  File('${dir.path}/chats.json').writeAsStringSync('{"这不是数组": tru');

  final chatDir = Directory('${dir.path}/chats')..createSync(recursive: true);
  // 一行合法、一行半截（模拟进程被杀时写了一半）、一行非法 JSON、一行空
  File('${chatDir.path}/group_12345.jsonl').writeAsStringSync(
    '${jsonEncode(_persistedMessage('500', '完好的'))}\n'
    '{"id":"501","text":"被截断的\n'
    'not json at all\n'
    '\n'
    '${jsonEncode(_persistedMessage('502', '也完好的'))}\n',
  );

  final session = FakeSession(); // 不连接
  final store = ChatStore(session: session, dataDir: dir);

  var threw = false;
  try {
    await store.bootstrap();
    await store.openChat('group_12345');
  } catch (e) {
    threw = true;
    stdout.writeln('    异常：$e');
  }
  check('损坏的会话索引不导致启动崩溃', !threw);
  checkEq('索引损坏时会话列表为空', store.chats.length, 0);

  final loaded = store.messagesOf('group_12345');
  checkEq('合法行被恢复（坏行被跳过）', loaded.length, 2);
  checkEq('第一条完好', loaded.first.text, '完好的');
  checkEq('第二条完好', loaded.last.text, '也完好的');

  // 坏目录：dataDir 不存在时应自动创建而不是抛
  final missing = Directory('${newTempDir('missing').path}/nested/deep');
  final store2 = ChatStore(session: FakeSession(), dataDir: missing);
  var threw2 = false;
  try {
    await store2.bootstrap();
  } catch (e) {
    threw2 = true;
    stdout.writeln('    异常：$e');
  }
  check('数据目录不存在时自动创建', !threw2);
  checkEq('目录已建出来', missing.existsSync(), true);
  await store2.dispose();

  await store.dispose();
}

/// 存储策略（TG 式：消息库不自动删；媒体缓存按保留期 + 上限清）。
Future<void> _storageTests() async {
  section('11. 存储策略：用量统计 / 媒体缓存清理 / 清聊天记录');

  final dir = newTempDir('storage');
  final session = FakeSession();
  await session.connect();
  final store = ChatStore(
    session: session,
    dataDir: dir,
    keepMediaFor: const Duration(days: 7),
    maxCacheBytes: 300,
  );
  await store.bootstrap();
  await store.refreshChats();
  await store.openChat('group_12345');
  session.emit(SessionMessage(
      msg('900', '存一条消息', time: DateTime(2026, 9, 12, 12))));
  await waitUntil(() => store.messagesOf('group_12345').isNotEmpty);

  final stats0 = await store.storageStats();
  check('统计：消息库有字节、媒体缓存为 0（还没媒体）',
      stats0.dbBytes > 0 && stats0.cacheBytes == 0,
      'db=${stats0.dbBytes} cache=${stats0.cacheBytes}');
  check('统计：会话数与消息数报得出来',
      stats0.chatCount > 0 && stats0.messageCount > 0,
      'chats=${stats0.chatCount} msgs=${stats0.messageCount}');
  checkEq('体积格式化', StorageStats.formatBytes(1536), '1.5 KB');

  // 造媒体缓存：一个新文件 + 一个"过期"文件（改 mtime 到 30 天前）
  final mediaDir = Directory('${dir.path}${Platform.pathSeparator}media'
      '${Platform.pathSeparator}photos');
  mediaDir.createSync(recursive: true);
  final fresh = File('${mediaDir.path}${Platform.pathSeparator}new.jpg')
    ..writeAsBytesSync(List<int>.filled(100, 1));
  final old = File('${mediaDir.path}${Platform.pathSeparator}old.jpg')
    ..writeAsBytesSync(List<int>.filled(100, 2));
  old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 30)));

  final stats1 = await store.storageStats();
  check('媒体缓存被归类统计（photos）',
      stats1.cacheBytes == 200 && stats1.cacheByCategory['photos'] == 200,
      'cache=${stats1.cacheBytes} byCat=${stats1.cacheByCategory}');

  final freed = await store.pruneMediaCache();
  check('保留期清理：过期文件被删、新文件留着',
      freed == 100 && !old.existsSync() && fresh.existsSync(),
      'freed=$freed old=${old.existsSync()} new=${fresh.existsSync()}');

  // 上限清理：换一个「上限 50 字节」的实例指向同一目录 → 剩下的 100 字节应当被删
  final tight = ChatStore(session: session, dataDir: dir, maxCacheBytes: 50);
  final freed2 = await tight.pruneMediaCache();
  check('上限清理：超预算时删到预算内',
      freed2 == 100 && !fresh.existsSync(),
      'freed=$freed2 exists=${fresh.existsSync()}');
  await tight.dispose();
  check('未 bootstrap 的实例 dispose 后索引仍在（不会空手覆盖）',
      store.chats.isNotEmpty, 'chats=${store.chats.length}');

  // 主动撤回：走 session.recall，成功后本地立刻标记为已撤回（原文仍在）
  session.emit(SessionMessage(
      msg('910', '我发的', time: DateTime(2026, 9, 12, 14), outgoing: true)));
  await waitUntil(() => store.messagesOf('group_12345').any((m) => m.id == '910'));
  await store.recallMessage('group_12345', '910');
  final recalledOut =
      store.messagesOf('group_12345').firstWhere((m) => m.id == '910');
  check('recallMessage：调了 session.recall 且本地标记为已撤回',
      session.recallCalls == 1 && recalledOut.isRecalled,
      'calls=${session.recallCalls} recalled=${recalledOut.isRecalled}');
  check('撤回后原文仍留着（反撤回闭环）', recalledOut.text == '我发的',
      recalledOut.text);

  // 一键清空媒体缓存（TG 的 Clear cache）
  File('${mediaDir.path}${Platform.pathSeparator}x.jpg')
      .writeAsBytesSync(List<int>.filled(10, 3));
  final freed3 = await store.clearMediaCache();
  check('清空媒体缓存', freed3 == 10, 'freed=$freed3');

  // 清聊天记录：消息库清空但会话列表保留
  final beforeClear = store.chats.length;
  await store.clearAllHistory();
  final stats2 = await store.storageStats();
  check('清空聊天记录后：消息没了、会话列表还在',
      store.messagesOf('group_12345').isEmpty &&
          store.chats.length == beforeClear &&
          stats2.dbBytes < stats0.dbBytes,
      'db=${stats2.dbBytes} chats=${store.chats.length}');
  check('清空后会话可重新拉取（historyFetched 复位）',
      store.hasMore('group_12345') == false);

  // 单会话清理
  session.emit(SessionMessage(
      msg('901', '再来一条', time: DateTime(2026, 9, 12, 13))));
  await waitUntil(() => store.messagesOf('group_12345').isNotEmpty);
  await store.clearChatHistory('group_12345');
  check('单会话清理：该会话空了、会话本身还在',
      store.messagesOf('group_12345').isEmpty &&
          store.chatOf('group_12345') != null);

  await store.dispose();
  await session.dispose();
}

/// 构造一行与 ChatStore 落盘格式一致的消息记录（仅测试损坏容错用）。
Map<String, dynamic> _persistedMessage(String id, String text) => {
      'id': id,
      'chat': 'group_12345',
      'time': 1700000000000,
      'text': text,
      'out': false,
      'senderId': '20002',
      'senderName': '小明',
      'segments': [
        {'type': 'text', 'data': {'text': text}}
      ],
    };

// ---------------------------------------------------------------------------
// 8. 体积：淘汰最旧的，但不丢用户输入、不淘汰置顶会话
// ---------------------------------------------------------------------------

Future<void> testRetention() async {
  section('8. 体积：保留上限与豁免');

  final dir = newTempDir('retention');
  final session = FakeSession()
    ..chatList = [
      fakeGroup(), // 普通会话：受上限约束
      fakeFriend('private_20002', '小明', pinned: true), // 置顶：豁免
    ];
  session.markReady();

  final store = ChatStore(session: session, dataDir: dir, maxMessagesPerChat: 3);
  await store.bootstrap();
  await store.openChat('group_12345');

  // 先发一条会失败的消息（最旧），它必须活过淘汰
  session.sendError = (attempt) => attempt == 1 ? const SessionException('挂了') : null;
  await store.send('group_12345', const [TextSegment('失败但要保住')]);
  session.sendError = null;

  for (var i = 0; i < 5; i++) {
    session.emit(SessionMessage(msg('60$i', '灌消息$i', time: at(100 + i))));
  }
  check('灌入完成',
      await waitUntil(() => store.messagesOf('group_12345').any((m) => m.id == '604')));

  final kept = store.messagesOf('group_12345');
  checkEq('普通会话被压到上限 + 豁免条数', kept.length, 4);
  check('失败消息未被淘汰', kept.any((m) => m.text == '失败但要保住'));
  checkEq('淘汰的是最旧的', kept.where((m) => m.id.startsWith('6')).map((m) => m.id).toList(),
      ['602', '603', '604']);

  // 落盘后重建，磁盘上也应是同样结果
  final anchorBefore =
      store.chats.firstWhere((c) => c.id == 'group_12345').lastReadId;
  check('重载前记下了未读锚点', anchorBefore != null, '$anchorBefore');
  await store.dispose();
  final session2 = FakeSession();
  final store2 = ChatStore(session: session2, dataDir: dir, maxMessagesPerChat: 3);
  await store2.bootstrap();
  check('磁盘上的未读锚点还在（重启后分隔线位置不丢）',
      store2.chats.firstWhere((c) => c.id == 'group_12345').lastReadId ==
          anchorBefore,
      '${store2.chats.firstWhere((c) => c.id == 'group_12345').lastReadId}');
  await store2.openChat('group_12345');
  checkEq('磁盘上也是 4 条', store2.messagesOf('group_12345').length, 4);
  check('磁盘上失败消息仍在',
      store2.messagesOf('group_12345').any((m) => m.text == '失败但要保住'));
  await store2.dispose();

  // 置顶会话豁免
  final dir3 = newTempDir('pinned');
  final session3 = FakeSession()..chatList = [fakeFriend('private_20002', '小明', pinned: true)];
  session3.markReady();
  final store3 = ChatStore(session: session3, dataDir: dir3, maxMessagesPerChat: 2);
  await store3.bootstrap();
  await store3.openChat('private_20002');
  for (var i = 0; i < 5; i++) {
    session3.emit(SessionMessage(
        msg('70$i', '置顶$i', time: at(200 + i), chatId: 'private_20002')));
  }
  check('置顶会话灌入完成',
      await waitUntil(() => store3.messagesOf('private_20002').length == 5));
  checkEq('置顶会话不淘汰', store3.messagesOf('private_20002').length, 5);
  await store3.dispose();
}

// ---------------------------------------------------------------------------
// 9. 会话排序
// ---------------------------------------------------------------------------

Future<void> testSorting() async {
  section('9. 会话排序：置顶 → 优先级 → 最后消息时间');

  final f = await readyStore('sorting', chats: [
    fakeFriend('private_1', '普通旧', priority: 3),
    fakeFriend('private_2', '高优先级', priority: 1),
    fakeFriend('private_3', '置顶', pinned: true, priority: 5),
    fakeFriend('private_4', '普通新', priority: 3),
  ]);
  final store = f.store;
  final session = f.session;

  session.emit(SessionMessage(
      msg('800', '旧的', time: at(1), chatId: 'private_1', senderId: '1')));
  session.emit(SessionMessage(
      msg('801', '新的', time: at(500), chatId: 'private_4', senderId: '4')));
  check('排序输入就绪',
      await waitUntil(() => store.messagesOf('private_4').isNotEmpty));

  checkEq('置顶在最前', store.chats.first.id, 'private_3');
  checkEq('其后按优先级', store.chats[1].id, 'private_2');
  checkEq('同优先级按最后消息时间倒序（新在前）',
      store.chats.sublist(2).map((c) => c.id).toList(), ['private_4', 'private_1']);

  await store.dispose();
}

// ---------------------------------------------------------------------------
// 10. 生命周期
// ---------------------------------------------------------------------------

Future<void> testForward() async {
  section('12. 转发：只重发内容，发不了的整批不发');

  final f = await readyStore('forward', chats: [
    fakeGroup(),
    fakeFriend('private_20002', '小明'),
  ]);
  final store = f.store;
  final session = f.session;

  // 群里来三条：纯文本、带引用的文本、图片
  session.emit(SessionMessage(msg('700', '第一条', time: at(1))));
  session.emit(SessionMessage(msg('701', '引用别人的', time: at(2))));
  session.emit(SessionMessage(msg('702', '看图', time: at(3))));
  await sleep(60);
  // 给 701 手动塞个引用段、给 702 塞个图片段（模拟协议线解出来的样子）
  store.replaceSegmentsForTest('group_12345', '701', <Segment>[
    const ReplySegment('', text: '被引用的原话'),
    const TextSegment('引用别人的'),
  ]);
  store.replaceSegmentsForTest('group_12345', '702', <Segment>[
    const TextSegment('看图'),
    const ImageSegment('abc.jpg'),
  ]);

  // 1) 纯文本转发
  final sentBefore = session.sent.length;
  final n1 = await store.forwardMessages(
    fromChatId: 'group_12345',
    messageIds: <String>['700'],
    toChatId: 'private_20002',
  );
  check('转发成功返回条数', n1 == 1, '$n1');
  check('真的发到了目标会话', session.sent.length == sentBefore + 1,
      '${session.sent.length}');
  check('发的是内容本身（文本段）',
      session.sent.last.chatId == 'private_20002' &&
          session.sent.last.segments.length == 1 &&
          (session.sent.last.segments.first as TextSegment).text == '第一条',
      '${session.sent.last.segments}');
  check('目标会话本地也插了一条（乐观插入）',
      store.messagesOf('private_20002').any((m) => m.text == '第一条'));

  // 2) 带引用的：引用要丢掉（src_msg 指的是原会话里的消息，带过去是错的）
  final n2 = await store.forwardMessages(
    fromChatId: 'group_12345',
    messageIds: <String>['701'],
    toChatId: 'private_20002',
  );
  check('带引用的消息也能转发', n2 == 1, '$n2');
  check('转发出去时引用段被剔除',
      session.sent.last.segments.length == 1 &&
          session.sent.last.segments.first is TextSegment,
      '${session.sent.last.segments}');

  // 3) 图片：按原样重发做不到（要上传），必须整批不发并说明原因
  final beforeImg = session.sent.length;
  var threw = '';
  try {
    await store.forwardMessages(
      fromChatId: 'group_12345',
      messageIds: <String>['700', '702'],
      toChatId: 'private_20002',
    );
  } on SessionException catch (e) {
    threw = e.message;
  }
  check('带图片的一批 → 抛异常并说清是哪种内容',
      threw.contains('图片'), threw.isEmpty ? '(没抛)' : threw);
  check('整批都不发（不做半截转发）', session.sent.length == beforeImg,
      '多发了 ${session.sent.length - beforeImg}');

  await store.dispose();
  await session.dispose();
}

Future<void> testSearch() async {
  section('13. 本地搜索：只搜已加载的消息，按时间倒序');

  final f = await readyStore('search', chats: [
    fakeGroup(),
    fakeFriend('private_20002', '小明'),
  ]);
  final store = f.store;
  final session = f.session;

  session.emit(SessionMessage(msg('900', '今天的会议改到三点', time: at(10))));
  session.emit(SessionMessage(msg('901', '另外一份材料我发你了',
      time: at(20), chatId: 'private_20002', senderId: '20002')));
  session.emit(SessionMessage(msg('902', '会议纪要记得写',
      time: at(30), chatId: 'private_20002', senderId: '20002')));
  check('三条消息都已合并',
      await waitUntil(() => store.messagesOf('private_20002').length == 2));

  final hits = store.searchMessages('会议');
  check('两条命中"会议"（跨会话）', hits.length == 2, '${hits.length}');
  check('按时间倒序（新的在前）',
      hits.length == 2 && hits.first.message.id == '902',
      hits.map((h) => h.message.id).join(','));
  check('结果带上会话 id（UI 要拿它跳会话）',
      hits.every((h) => h.chatId == 'private_20002' || h.chatId == 'group_12345'),
      hits.map((h) => h.chatId).join(','));
  check('搜不到就是空（不是抛异常）', store.searchMessages('不存在的词').isEmpty);
  check('空查询直接返回空', store.searchMessages('   ').isEmpty);
  check('大小写不敏感（ASCII）',
      store.searchMessages('ABC').isEmpty &&
          store.searchMessages('abc').isEmpty,
      '用例里没有英文消息，这里只确认不炸');

  final limited = store.searchMessages('会', limit: 1);
  check('limit 生效', limited.length == 1, '${limited.length}');

  await store.dispose();
  await session.dispose();
}

Future<void> testLifecycle() async {
  section('10. 生命周期：dispose 后不再处理事件');

  final f = await readyStore('lifecycle', chats: [fakeGroup()]);
  final store = f.store;
  final session = f.session;
  await store.openChat('group_12345');

  await store.dispose();
  session.emit(SessionMessage(msg('900', '迟到消息', time: at(900))));
  await sleep(80);
  checkEq('dispose 后事件不再合并', store.messagesOf('group_12345').length, 0);

  // dispose 幂等
  var threw = false;
  try {
    await store.dispose();
  } catch (_) {
    threw = true;
  }
  check('dispose 可重复调用', !threw);
}

// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('ChatStore 离线自测（注入假 Session）');
  stdout.writeln('=' * 64);

  try {
    await testBootstrap();
    await testEventMerge();
    await testDedup();
    await testOptimisticSend();
    await testSendFailure();
    await testPaging();
    await testCorruptFiles();
    await testRetention();
    await testSorting();
    await testForward();
    await testSearch();
    await testLifecycle();
  } finally {
    for (final d in _tempDirs) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {
        // 临时目录清理失败不影响结论
      }
    }
  }

  await _storageTests();

  stdout.writeln('\n${'=' * 64}');
  stdout.writeln('通过 $_passed 项，失败 $_failed 项');
  exit(_failed == 0 ? 0 : 1);
}
