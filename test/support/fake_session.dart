/// widget 测试用的最小 [Session] 假实现。
///
/// 为什么再写一份（`tool/chat_store_selftest.dart` 里那份更全）：那边是**纯 Dart
/// 脚本**，而 widget 测试需要把 store/session 注入 ProviderScope，从 `test/`
/// 里 import 一个 self-test 脚本会很怪。这里只实现 ChatStore 与 UI 真正会碰的
/// 那几个方法，其余一律 no-op——**动作记在字段上**（`sent`/`markReadCalls`…），
/// 测试直接断言，不用再搭一套 spy。
library;

import 'dart:async';

import 'package:qqclient/client_api/objects.dart';
import 'package:qqclient/client_api/segment.dart';
import 'package:qqclient/client_api/session.dart';

class FakeSession implements Session {
  FakeSession({this.selfId = '10001'});

  final String selfId;

  SessionState _state = SessionState.disconnected;
  final StreamController<SessionEvent> _events =
      StreamController<SessionEvent>.broadcast();

  /// `listChats` 的返回值。
  List<Chat> chatList = <Chat>[];

  /// `fetchHistory` 的返回队列（按调用顺序弹出，空了给空页）。
  final List<HistoryPage> historyPages = <HistoryPage>[];

  int sendCalls = 0;
  final List<({String chatId, List<Segment> segments})> sent = [];
  int markReadCalls = 0;
  int recallCalls = 0;
  bool disposed = false;

  @override
  SessionState get state => _state;

  @override
  Stream<SessionEvent> get events => _events.stream;

  @override
  AccountInfo? get account => _state == SessionState.ready
      ? AccountInfo(uin: selfId, nickname: '测试号', backendName: 'Fake')
      : null;

  @override
  String? get backendName => 'Fake';

  /// 置为就绪并广播状态事件（模拟握手完成）。
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
    if (historyPages.isNotEmpty) return historyPages.removeAt(0);
    return HistoryPage.empty;
  }

  @override
  Future<String?> sendMessage(String chatId, List<Segment> segments) async {
    _requireReady();
    sendCalls++;
    sent.add((chatId: chatId, segments: segments));
    return 'srv-$sendCalls';
  }

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
  Future<void> sendPoke(String chatId, String userId) async {
    throw const SessionException('假实现不支持戳一戳');
  }

  @override
  bool supports(String capability) =>
      capability == 'list_chats' ||
      capability == 'fetch_history' ||
      capability == 'send_message' ||
      capability == 'recall' ||
      capability == 'set_message_read';

  @override
  Future<void> dispose() async {
    disposed = true;
    _state = SessionState.closed;
    await _events.close();
  }
}
