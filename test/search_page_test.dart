/// 搜索页测试：会话按名字、消息按内容，点结果要能回调出去。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/client_api/chat_store.dart';
import 'package:qqclient/client_api/objects.dart';
import 'package:qqclient/client_api/segment.dart';
import 'package:qqclient/ui/pages/search_page.dart';

/// 一个只有消息、没有网络的假 store（搜索只读内存，够用）。
class _FakeStore implements ChatStore {
  final Map<String, List<ChatMessage>> messages = {};

  @override
  List<({String chatId, ChatMessage message})> searchMessages(
    String query, {
    int limit = 50,
  }) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final hits = <({String chatId, ChatMessage message})>[];
    for (final e in messages.entries) {
      for (final m in e.value) {
        if (m.text.toLowerCase().contains(q)) {
          hits.add((chatId: e.key, message: m));
        }
      }
    }
    hits.sort((a, b) => b.message.time.compareTo(a.message.time));
    return hits.length <= limit ? hits : hits.sublist(0, limit);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 不该在这条用例里被调到');
}

ChatMessage _msg(String id, String text, {required String chatId, int minute = 0}) =>
    ChatMessage(
      id: id,
      text: text,
      segments: <Segment>[TextSegment(text)],
      time: DateTime(2026, 9, 12, 10, minute),
      chatId: chatId,
      senderId: '20002',
      senderName: '小明',
    );

void main() {
  final chats = <Chat>[
    const Chat(id: 'private_20002', title: '小明', type: ChatType.private),
    const Chat(id: 'group_12345', title: '测试群', type: ChatType.group),
  ];

  Future<void> pump(WidgetTester tester, _FakeStore store,
      {void Function(Chat)? onOpen}) async {
    await tester.pumpWidget(MaterialApp(
      home: SearchPage(
        chats: chats,
        store: store,
        onOpenChat: onOpen ?? (_) {},
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('没输入时给提示，不列结果', (tester) async {
    final store = _FakeStore();
    await pump(tester, store);
    expect(find.textContaining('输入名字找会话'), findsOneWidget);
    expect(find.byKey(const ValueKey('search-results')), findsNothing);
  });

  testWidgets('按名字搜会话', (tester) async {
    final store = _FakeStore();
    await pump(tester, store);
    await tester.enterText(find.byKey(const ValueKey('search-input')), '测试');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search-chat-group_12345')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-chat-private_20002')), findsNothing);
  });

  testWidgets('按内容搜消息：显示会话名 + 文本，点一下回调打开该会话',
      (tester) async {
    final store = _FakeStore();
    store.messages['private_20002'] = <ChatMessage>[
      _msg('m1', '会议改到三点', chatId: 'private_20002'),
    ];
    Chat? opened;
    await pump(tester, store, onOpen: (c) => opened = c);

    await tester.enterText(find.byKey(const ValueKey('search-input')), '会议');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search-msg-m1')), findsOneWidget);
    expect(find.textContaining('小明'), findsWidgets, reason: '结果里要标明是哪个会话');

    await tester.tap(find.byKey(const ValueKey('search-msg-m1')));
    await tester.pumpAndSettle();
    expect(opened?.id, 'private_20002');
  });

  testWidgets('搜不到时给"只搜已加载"的说明，而不是空白', (tester) async {
    final store = _FakeStore();
    await pump(tester, store);
    await tester.enterText(find.byKey(const ValueKey('search-input')), '找不到的词');
    await tester.pumpAndSettle();

    expect(find.textContaining('只搜已加载'), findsOneWidget);
  });

  testWidgets('金样：搜索结果长什么样（会话 + 消息两段）', (tester) async {
    // 金样按本机字体渲染，跨平台有差异，只在 Windows 上跑（CI 是 Linux）
    if (!Platform.isWindows) return;
    tester.view.physicalSize = const Size(420, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final store = _FakeStore();
    store.messages['private_20002'] = <ChatMessage>[
      _msg('m2', '会议纪要我整理好了', chatId: 'private_20002', minute: 30),
      _msg('m1', '会议改到三点', chatId: 'private_20002'),
    ];
    await pump(tester, store);
    await tester.enterText(find.byKey(const ValueKey('search-input')), '会议');
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/search_page.png'),
    );
  });

  testWidgets('清空按钮把结果收回去', (tester) async {
    final store = _FakeStore();
    store.messages['private_20002'] = <ChatMessage>[
      _msg('m1', '会议改到三点', chatId: 'private_20002'),
    ];
    await pump(tester, store);
    await tester.enterText(find.byKey(const ValueKey('search-input')), '会议');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-msg-m1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-msg-m1')), findsNothing);
    expect(find.textContaining('输入名字找会话'), findsOneWidget);
  });
}
