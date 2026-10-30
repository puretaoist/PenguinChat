/// 多账号数据隔离离线自测（**不联网、不起服务器**）
///
/// 证明「每个账号一个数据根」：两个账号哪怕 chatId 完全相同（私聊 id 就是对方
/// uin，群 id 就是群号），内存 / 磁盘消息文件 / 媒体缓存也互不可见。
///
/// 覆盖 A. AccountScope、B. 同 chatId 消息不串（含重启后）、C. 媒体按账号分开、
/// D. UI 数据口跟随当前后端。
///
/// 写法遵循 docs/PITFALLS.md：等状态用 [waitUntil] 轮询，结尾用 `exit()`。
/// 运行：`dart run tool/account_isolation_selftest.dart`
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qqclient/client_api/account_scope.dart';
import 'package:qqclient/client_api/chat_store.dart';
import 'package:qqclient/client_api/objects.dart';
import 'package:qqclient/client_api/segment.dart';
import 'package:qqclient/client_api/session.dart';
import 'package:qqclient/client_api/session_providers.dart';
import 'package:qqclient/kernel/onebot/backend_profile.dart';
import 'package:riverpod/riverpod.dart';

// ---------------------------------------------------------------------------
// 断言工具（与 tool/chat_store_selftest.dart 同款）
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

/// 路径分隔符。
final String sep = Platform.pathSeparator;

// ---------------------------------------------------------------------------
// 假 Session（整份照抄 tool/chat_store_selftest.dart 的实现）
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
  int sendCalls = 0;
  final List<({String chatId, List<Segment> segments})> sent = [];
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
    if (historyPages.isNotEmpty) return historyPages.removeAt(0);
    return HistoryPage.empty;
  }

  @override
  Future<String?> sendMessage(String chatId, List<Segment> segments) async {
    _requireReady();
    sendCalls++;
    sent.add((chatId: chatId, segments: segments));
    return '${90000 + sendCalls}';
  }

  @override
  Future<void> recall(String chatId, String messageId) async {
    _requireReady();
  }

  @override
  Future<void> markRead(String chatId, String messageId) async {
    _requireReady();
  }

  @override
  Future<void> sendPoke(String chatId, String userId) async {
    _requireReady();
  }

  @override
  Future<void> forwardAsCard(String chatId, List<ForwardNode> nodes) async {
    _requireReady();
  }

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

Chat fakeChat(String id) => Chat(
      id: id,
      title: '会话 $id',
      type: ChatType.private,
      rawId: int.tryParse(id),
    );

// ---------------------------------------------------------------------------
// A. AccountScope
// ---------------------------------------------------------------------------

void testScope(Directory tmpRoot) {
  section('A. AccountScope：每账号一个数据根');

  final a = AccountScope.of(tmpRoot, 10001);
  final b = AccountScope.of(tmpRoot, 10002);
  final accountsPath = AccountScope.accountsRoot(tmpRoot).path;

  check('A1 两个 uin 的 root 是两个不同目录',
      a.root.path != b.root.path, '${a.root.path} vs ${b.root.path}');
  check('A1 都在 <dir>/accounts/ 下',
      a.root.path == '$accountsPath${sep}10001' && b.root.path == '$accountsPath${sep}10002',
      '${a.root.path} / ${b.root.path}');
  check('A1 父目录名就是 accounts',
      accountsPath.split(sep).last == AccountScope.accountsDirName);
  check('A1 账号目录的父目录是 accounts', a.root.parent.path == accountsPath);

  final again = AccountScope.of(tmpRoot, 10001);
  check('A2 同一 uin 两次调用得到同一路径（稳定）',
      again.root.path == a.root.path && again.uin == 10001, again.root.path);

  check('A3 uin=0 无效', !AccountScope.isValidUin(0));
  check('A3 uin=-1 无效', !AccountScope.isValidUin(-1));
  check('A3 uin=0x100000000 无效', !AccountScope.isValidUin(0x100000000));
  check('A3 uin=1 有效', AccountScope.isValidUin(1));
  check('A3 uin=0xFFFFFFFF 有效', AccountScope.isValidUin(0xFFFFFFFF));
  var threw = false;
  try {
    AccountScope.of(tmpRoot, 0);
  } on ArgumentError {
    threw = true;
  }
  check('A3 of(dir, 0) 抛 ArgumentError（拒绝拼进路径）', threw);

  check('A4 tryOf(dir, null) == null', AccountScope.tryOf(tmpRoot, null) == null);
  check('A4 tryOf(dir, 0) == null', AccountScope.tryOf(tmpRoot, 0) == null);
  check('A4 tryOf(dir, 10001) 与 of 一致',
      AccountScope.tryOf(tmpRoot, 10001)?.root.path == a.root.path);
}

// ---------------------------------------------------------------------------
// B / C. 消息与媒体按账号隔离
// ---------------------------------------------------------------------------

Future<void> testIsolation(Directory tmpRoot) async {
  section('B. 两个账号、同一个 chatId 的消息不串');

  const chatId = 'c_same';
  const textA = 'A号的消息';
  const textB = 'B号的消息';
  final scopeA = AccountScope.of(tmpRoot, 111);
  final scopeB = AccountScope.of(tmpRoot, 222);

  final sessionA = FakeSession(selfId: '111')..chatList = [fakeChat(chatId)];
  final sessionB = FakeSession(selfId: '222')..chatList = [fakeChat(chatId)];
  sessionA.markReady();
  sessionB.markReady();

  final aStore = ChatStore(session: sessionA, dataDir: scopeA.root);
  final bStore = ChatStore(session: sessionB, dataDir: scopeB.root);
  await aStore.bootstrap();
  await bStore.bootstrap();

  checkEq('B2 A 的会话列表只有自己的 c_same', aStore.chats.map((c) => c.id).toList(), [chatId]);
  checkEq('B2 两个 store 的 dataDir 不同', aStore.dataDir.path == bStore.dataDir.path, false);

  await aStore.send(chatId, [TextSegment(textA)]);
  await bStore.send(chatId, [TextSegment(textB)]);
  check('B2 A 的消息已落入内存',
      await waitUntil(() => aStore.messagesOf(chatId).isNotEmpty));
  check('B2 B 的消息已落入内存',
      await waitUntil(() => bStore.messagesOf(chatId).isNotEmpty));

  checkEq('B3 A 只看到自己的那条', aStore.messagesOf(chatId).map((m) => m.text).toList(), [textA]);
  checkEq('B3 B 只看到自己的那条', bStore.messagesOf(chatId).map((m) => m.text).toList(), [textB]);
  check('B3 A 看不到 B 的文本',
      !aStore.messagesOf(chatId).any((m) => m.text.contains('B号')));
  check('B3 B 看不到 A 的文本',
      !bStore.messagesOf(chatId).any((m) => m.text.contains('A号')));

  final fileA = File([scopeA.root.path, 'chats', '$chatId.jsonl'].join(sep));
  final fileB = File([scopeB.root.path, 'chats', '$chatId.jsonl'].join(sep));
  check('B4 磁盘上有 accounts/111/chats/c_same.jsonl', fileA.existsSync(), fileA.path);
  check('B4 磁盘上有 accounts/222/chats/c_same.jsonl', fileB.existsSync(), fileB.path);
  check('B4 是两个不同的文件', fileA.absolute.path != fileB.absolute.path);
  final bodyA = fileA.existsSync() ? fileA.readAsStringSync() : '';
  final bodyB = fileB.existsSync() ? fileB.readAsStringSync() : '';
  check('B4 A 的文件含自己的文本', bodyA.contains(textA));
  check('B4 A 的文件不含对方的文本', !bodyA.contains(textB));
  check('B4 B 的文件含自己的文本', bodyB.contains(textB));
  check('B4 B 的文件不含对方的文本', !bodyB.contains(textA));

  section('C. 媒体缓存也按账号分开');
  final mediaA = aStore.mediaCache?.root.path ?? '${aStore.dataDir.path}${sep}media';
  final mediaB = bStore.mediaCache?.root.path ?? '${bStore.dataDir.path}${sep}media';
  check('C 两个 store 的媒体目录路径不同', mediaA != mediaB, '$mediaA vs $mediaB');
  check('C A 的媒体目录在 A 的账号根下', mediaA.startsWith(scopeA.root.path));
  check('C B 的媒体目录在 B 的账号根下', mediaB.startsWith(scopeB.root.path));
  check('C 媒体目录不在对方账号根下',
      !mediaA.startsWith(scopeB.root.path) && !mediaB.startsWith(scopeA.root.path));
  check('C 目录名都是 media',
      mediaA.endsWith('${sep}media') && mediaB.endsWith('${sep}media'), '$mediaA / $mediaB');

  section('B5. dispose 后重新 bootstrap：历史仍各自独立（落盘隔离）');
  await aStore.dispose();
  await bStore.dispose();
  await sessionA.dispose();
  await sessionB.dispose();

  // 新会话**故意不 markReady**：证明历史完全来自磁盘，不靠后端补推
  final offlineA = FakeSession(selfId: '111');
  final offlineB = FakeSession(selfId: '222');
  final a2 = ChatStore(session: offlineA, dataDir: scopeA.root);
  final b2 = ChatStore(session: offlineB, dataDir: scopeB.root);
  await a2.bootstrap();
  await b2.bootstrap();
  await a2.openChat(chatId);
  await b2.openChat(chatId);

  checkEq('B5 重启后 A 仍只有自己的消息',
      a2.messagesOf(chatId).map((m) => m.text).toList(), [textA]);
  checkEq('B5 重启后 B 仍只有自己的消息',
      b2.messagesOf(chatId).map((m) => m.text).toList(), [textB]);
  check('B5 离线启动不向后端要历史（openChat 不炸）', offlineA.historyCalls == 0);

  await a2.dispose();
  await b2.dispose();
  await offlineA.dispose();
  await offlineB.dispose();
}

// ---------------------------------------------------------------------------
// D. UI 数据口跟随当前后端
// ---------------------------------------------------------------------------

Future<void> testUiFollowsBackend(Directory tmpRoot) async {
  section('D. UI 数据口跟随当前后端');

  final scopeA = AccountScope.of(tmpRoot, 333);
  final scopeB = AccountScope.of(tmpRoot, 444);
  final fakeA = FakeSession(selfId: '333')..chatList = [fakeChat('c_only_a')];
  final fakeB = FakeSession(selfId: '444')..chatList = [fakeChat('c_only_b')];
  fakeA.markReady();
  fakeB.markReady();

  final storeA = ChatStore(session: fakeA, dataDir: scopeA.root);
  final storeB = ChatStore(session: fakeB, dataDir: scopeB.root);
  await storeA.bootstrap();
  await storeB.bootstrap();
  await storeA.send('c_only_a', [TextSegment('A 独有')]);
  await storeB.send('c_only_b', [TextSegment('B 独有')]);

  final container = ProviderContainer(overrides: [
    dataDirProvider.overrideWithValue(tmpRoot),
    backendRegistryProvider.overrideWithValue(BackendProfileRegistry(const [])),
    mediaFetcherProvider.overrideWithValue(null),
  ]);
  try {
    check('D1 初始 chatStoreProvider == null',
        container.read(chatStoreProvider) == null);

    container.read(activeQq8BackendProvider.notifier).state =
        (session: fakeA, store: storeA);
    check('D2 回填 A 后 chatStoreProvider 返回 storeA',
        identical(container.read(chatStoreProvider), storeA));

    container.read(activeQq8BackendProvider.notifier).state =
        (session: fakeB, store: storeB);
    check('D3 切到 B 后返回 storeB（不是 storeA）',
        identical(container.read(chatStoreProvider), storeB));

    container.read(activeQq8BackendProvider.notifier).state = null;
    check('D4 清回 null 后 chatStoreProvider == null',
        container.read(chatStoreProvider) == null);

    // D5：订阅 chatsProvider，断言只发出当前账号的会话
    final emitted = <List<String>>[];
    final sub = container.listen<AsyncValue<List<Chat>>>(chatsProvider, (prev, next) {
      if (next is AsyncData<List<Chat>>) {
        emitted.add(next.value.map((c) => c.id).toList());
      }
    });

    container.read(activeQq8BackendProvider.notifier).state =
        (session: fakeA, store: storeA);
    final sawA = await waitUntil(
        () => emitted.any((ids) => ids.contains('c_only_a') && !ids.contains('c_only_b')));
    check('D5 当前后端为 A：发出 A 的会话，不发 B 的', sawA, '$emitted');

    container.read(activeQq8BackendProvider.notifier).state =
        (session: fakeB, store: storeB);
    final sawB = await waitUntil(
        () => emitted.any((ids) => ids.contains('c_only_b') && !ids.contains('c_only_a')));
    check('D5 切到 B 后：发出 B 的会话，不发 A 的', sawB, '$emitted');

    sub.close();
    container.read(activeQq8BackendProvider.notifier).state = null;
    check('D5 清回 null 后 chatStoreProvider 再次为 null',
        container.read(chatStoreProvider) == null);
  } finally {
    container.dispose();
  }

  await storeA.dispose();
  await storeB.dispose();
  await fakeA.dispose();
  await fakeB.dispose();
}

// ---------------------------------------------------------------------------

Future<void> main() async {
  final tmpRoot = Directory.systemTemp.createTempSync('qq8iso_');
  try {
    testScope(tmpRoot);
    await testIsolation(tmpRoot);
    await testUiFollowsBackend(tmpRoot);
  } catch (e, s) {
    _failed++;
    stdout.writeln('  ✗ 自测异常中断：$e\n$s');
  } finally {
    try {
      tmpRoot.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录清理失败不影响判据
    }
  }

  stdout.writeln('\n通过 $_passed 项，失败 $_failed 项');
  exit(_failed == 0 ? 0 : 1);
}
