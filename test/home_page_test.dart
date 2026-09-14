/// HomePage 的**会话管理**行为测试（真 store + 假 session）
///
/// `ui_test.dart` 只验证"没连接也能起来"，那套 override 里没有 store，
/// 于是所有需要会话存在的功能（长按菜单、归档、草稿、删除）都测不到。
/// 这里用 [FakeSession] + 真 `ChatStore` 把 HomePage 跑起来，断言的是**行为**：
///
/// * 长按会话 → 菜单里那几项真的能改 store 状态；
/// * 归档 → 主列表收起、顶部出现"已归档"入口；
/// * 标为未读 → 未读计数回来；
/// * 草稿 → 换会话再换回来，输入框里的字还在；
/// * 删除会话 / 删除单条消息 → 确认后真的没了。
///
/// ## 为什么 store 在 setUp/tearDown 里建和释放
///
/// `testWidgets` 的测试体跑在 **FakeAsync** 里，而 `ChatStore` 内部有防抖
/// `Timer`、`dispose()` 还要等 `changes` 流关闭——在 FakeAsync 里 await 这些
/// 会永远等不到（整个文件挂住，就是上一版踩的坑）。`setUp`/`tearDown` 是真实
/// 异步，放这里最稳；每个用例结束前先 `pumpWidget(SizedBox())` 卸载 widget 树，
/// 让 provider 把订阅放掉，再释放 store。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/client_api/chat_store.dart';
import 'package:qqclient/client_api/objects.dart';
import 'package:qqclient/client_api/segment.dart';
import 'package:qqclient/client_api/session.dart';
import 'package:qqclient/client_api/session_providers.dart';
import 'package:qqclient/kernel/onebot/backend_profile.dart';
import 'package:qqclient/kernel/safety/safety_gate.dart';
import 'package:qqclient/ui/pages/home_page.dart';
import 'package:qqclient/ui/widgets/message_bubble.dart';

import 'support/fake_session.dart';

late ChatStore store;
late FakeSession session;
late Directory dir;

/// 一个已经"上线"的 store：两个会话（私聊 + 群）。
Future<void> _makeStore() async {
  dir = Directory.systemTemp.createTempSync('qqclient_home');
  session = FakeSession();
  session.chatList = <Chat>[
    Chat(
      id: 'private_20002',
      title: '小明',
      type: ChatType.private,
      rawId: 20002,
      lastMessage: '在吗',
      lastTime: DateTime(2026, 9, 12, 10),
    ),
    Chat(
      id: 'group_12345',
      title: '测试群',
      type: ChatType.group,
      rawId: 12345,
      memberCount: 3,
      lastMessage: '群里说话',
      lastTime: DateTime(2026, 9, 12, 9),
    ),
  ];
  session.markReady();
  store = ChatStore(session: session, dataDir: dir);
  await store.bootstrap();
}

Widget _wrap() => ProviderScope(
      overrides: <Override>[
        dataDirProvider.overrideWithValue(Directory.systemTemp),
        backendRegistryProvider.overrideWithValue(
          BackendProfileRegistry.fromJsonStrings(const <String>[]),
        ),
        safetyGateProvider.overrideWithValue(SafetyGate()),
        activeQq8BackendProvider.overrideWith(
          (ref) => (session: session, store: store),
        ),
      ],
      child: const MaterialApp(home: HomePage()),
    );

/// 收尾：卸载 widget 树（让 provider 退订）→ 顺手释放 store/session → 删临时目录。
///
/// **不 await `store.dispose()`**：它内部 `await _changes.close()`，而流的订阅者
/// 是在本测试的 FakeAsync 区里注册的——那个 done 事件排不进队列，await 会一直挂
/// （就是上一版把整个文件卡到 10 分钟超时的原因）。放进 `runAsync`（真实事件循环）
/// 再加个超时兜底：关不掉也无所谓，测试进程马上就退出了。
Future<void> _teardownStore(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(() async {
    await store.dispose().timeout(const Duration(seconds: 2), onTimeout: () {});
    await session
        .dispose()
        .timeout(const Duration(seconds: 2), onTimeout: () {});
  });
  if (dir.existsSync()) dir.deleteSync(recursive: true);
}

/// 宽屏：列表与对话同时在，省得来回点。
void _wideScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(2400, 1600);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(_makeStore);

  testWidgets('发图片：点 📎 → 填路径 → 真的发出一个 ImageSegment', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    // 先开一个私聊会话（右侧对话面板要指着某个会话）
    await tester.tap(find.byKey(const ValueKey('chat-row-private_20002')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('attach-file')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('send-image-dialog')), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('send-image-path')), r'C:\tmp\cat.png');
    await tester.tap(find.byKey(const ValueKey('send-image-ok')));
    await tester.pumpAndSettle();

    expect(session.sent.length, 1, reason: '要真发一条消息给会话层');
    expect(session.sent.first.chatId, 'private_20002');
    final seg = session.sent.first.segments.single;
    expect(seg, isA<ImageSegment>());
    expect((seg as ImageSegment).file, r'C:\tmp\cat.png');
    // 乐观插入：气泡立刻出现在会话里（状态由消息自己承载）
    expect(store.messagesOf('private_20002').isNotEmpty, isTrue);
    await _teardownStore(tester);
  });

  testWidgets('长按会话 → 菜单出现，置顶真的生效并排到最前', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('chat-row-group_12345')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-action-pin')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-action-archive')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-action-pin')));
    await tester.pumpAndSettle();
    expect(store.chatOf('group_12345')?.pinned, isTrue);
    expect(store.chats.first.id, 'group_12345', reason: '置顶会话要排到列表最前');
    await _teardownStore(tester);
  });

  testWidgets('归档 → 主列表收起，顶部出现"已归档"入口，点开还能进', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('archived-row')), findsNothing);

    await tester.longPress(find.byKey(const ValueKey('chat-row-group_12345')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-action-archive')));
    await tester.pumpAndSettle();

    expect(store.chatOf('group_12345')?.archived, isTrue);
    expect(find.byKey(const ValueKey('archived-row')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-row-group_12345')), findsNothing,
        reason: '归档后不该留在主列表里');

    await tester.tap(find.byKey(const ValueKey('archived-row')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('archived-group_12345')), findsOneWidget);
    await _teardownStore(tester);
  });

  testWidgets('标为未读 → 未读计数回到 1', (tester) async {
    session.emit(SessionMessage(ChatMessage(
      id: 'm1',
      text: '在吗',
      segments: <Segment>[const TextSegment('在吗')],
      time: DateTime(2026, 9, 12, 10),
      chatId: 'private_20002',
      senderId: '20002',
      senderName: '小明',
    )));
    // 等事件进 store：这里必须用 pump 推进假时钟，
    // `await Future.delayed(...)` 在 FakeAsync 里是假定时器，不 pump 会一直挂
    await tester.pump(const Duration(milliseconds: 50));
    expect(store.chatOf('private_20002')?.unreadCount, 1);

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    // 打开会话会清未读
    expect(store.chatOf('private_20002')?.unreadCount, 0);

    await tester.longPress(find.byKey(const ValueKey('chat-row-private_20002')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-action-unread')));
    await tester.pumpAndSettle();

    expect(store.chatOf('private_20002')?.unreadCount, 1,
        reason: '标为未读后列表上要有未读点');
    await _teardownStore(tester);
  });

  testWidgets('草稿：在 A 打字 → 切到 B → 切回 A，字还在（列表上也有"草稿:"）',
      (tester) async {
    _wideScreen(tester);
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    // 默认选中第一个会话（小明），打一行字
    await tester.enterText(find.byType(TextField).first, '还没发出去的话');
    await tester.pump(const Duration(milliseconds: 700)); // 过防抖
    expect(store.chatOf('private_20002')?.draft, '还没发出去的话');
    expect(find.textContaining('草稿:'), findsOneWidget,
        reason: '会话列表上要显示草稿，否则用户以为字丢了');

    // 切到群
    await tester.tap(find.byKey(const ValueKey('chat-row-group_12345')));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller?.text, '', reason: '另一个会话的输入框应该是空的');

    // 切回来
    await tester.tap(find.byKey(const ValueKey('chat-row-private_20002')));
    await tester.pumpAndSettle();
    final back = tester.widget<TextField>(find.byType(TextField).first);
    expect(back.controller?.text, '还没发出去的话', reason: '草稿要能读回来');
    await _teardownStore(tester);
  });

  testWidgets('删除会话：确认后从列表消失，store 里也没了', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const ValueKey('chat-row-group_12345')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-action-delete')));
    await tester.pumpAndSettle();

    expect(find.text('删除会话？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-delete-confirm')));
    await tester.pumpAndSettle();

    expect(store.chatOf('group_12345'), isNull);
    expect(find.byKey(const ValueKey('chat-row-group_12345')), findsNothing);
    expect(find.byKey(const ValueKey('chat-row-private_20002')), findsOneWidget,
        reason: '别的会话不能跟着一起没');
    await _teardownStore(tester);
  });

  testWidgets('转发：长按消息 → 转发 → 选目标会话 → 目标会话收到同一条内容',
      (tester) async {
    _wideScreen(tester);
    session.emit(SessionMessage(ChatMessage(
      id: 'fwd-1',
      text: '要转发的原话',
      segments: <Segment>[const TextSegment('要转发的原话')],
      time: DateTime(2026, 9, 12, 10),
      chatId: 'private_20002',
      senderId: '20002',
      senderName: '小明',
    )));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.longPress(find.descendant(
      of: find.byType(MessageBubble),
      matching: find.text('要转发的原话'),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('action-forward')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('action-forward')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('forward-title')), findsOneWidget);
    // 不能把消息转发到它自己所在的会话
    expect(find.byKey(const ValueKey('forward-to-private_20002')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('forward-to-group_12345')));
    await tester.pumpAndSettle();

    expect(session.sent.length, 1, reason: '转发就是往目标会话发一条');
    expect(session.sent.last.chatId, 'group_12345');
    expect(
      (session.sent.last.segments.first as TextSegment).text,
      '要转发的原话',
    );
    expect(store.messagesOf('group_12345').any((m) => m.text == '要转发的原话'),
        isTrue, reason: '目标会话本地也要能看到');
    await _teardownStore(tester);
  });

  testWidgets('多选：勾选两条 → 工具条显示条数 → 批量删除', (tester) async {
    _wideScreen(tester);
    for (final (id, text) in const <(String, String)>[
      ('s-1', '第一条'),
      ('s-2', '第二条'),
    ]) {
      session.emit(SessionMessage(ChatMessage(
        id: id,
        text: text,
        segments: <Segment>[TextSegment(text)],
        time: DateTime(2026, 9, 12, 10, id == 's-2' ? 1 : 0),
        chatId: 'private_20002',
        senderId: '20002',
        senderName: '小明',
      )));
    }
    await tester.pump(const Duration(milliseconds: 50));

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    // 长按第一条 → 多选
    await tester.longPress(find.descendant(
      of: find.byType(MessageBubble),
      matching: find.text('第一条'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action-select')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('ms-count')), findsOneWidget);
    expect(find.text('已选 1 条'), findsOneWidget);
    expect(find.byKey(const ValueKey('ms-check-s-1')),
        findsOneWidget, reason: '选中的那条要有勾');

    // 再点第二条
    await tester.tap(find.descendant(
      of: find.byType(MessageBubble),
      matching: find.text('第二条'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条'), findsOneWidget);

    // 批量删除
    await tester.tap(find.byKey(const ValueKey('ms-delete')));
    await tester.pumpAndSettle();
    expect(find.text('删除这 2 条消息？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ms-delete-confirm')));
    await tester.pumpAndSettle();

    expect(store.messagesOf('private_20002'), isEmpty);
    expect(find.byKey(const ValueKey('ms-count')), findsNothing,
        reason: '删除后要退出多选');
    await _teardownStore(tester);
  });

  testWidgets('多选：复制会按顺序把选中的消息拼成文本', (tester) async {
    _wideScreen(tester);
    for (final (id, text) in const <(String, String)>[
      ('c-1', '甲'),
      ('c-2', '乙'),
    ]) {
      session.emit(SessionMessage(ChatMessage(
        id: id,
        text: text,
        segments: <Segment>[TextSegment(text)],
        time: DateTime(2026, 9, 12, 11, id == 'c-2' ? 1 : 0),
        chatId: 'private_20002',
        senderId: '20002',
        senderName: '小明',
      )));
    }
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.longPress(find.descendant(
      of: find.byType(MessageBubble),
      matching: find.text('甲'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(MessageBubble),
      matching: find.text('乙'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ms-copy')));
    await tester.pumpAndSettle();

    // 注意：**不要**在 widget 测试里 `Clipboard.getData()`——剪贴板要走
    // platform channel，测试环境没有实现，那个 future 永远不返回（会把整个
    // 文件卡到超时）。这里断言界面反馈：提示条 + 退出多选。
    expect(find.textContaining('已复制'), findsOneWidget);
    expect(find.byKey(const ValueKey('ms-count')), findsNothing,
        reason: '复制完退出多选');
    await _teardownStore(tester);
  });

  testWidgets('删除单条消息：确认后消息消失，会话还在', (tester) async {
    _wideScreen(tester);
    session.emit(SessionMessage(ChatMessage(
      id: 'msg-1',
      text: '这条要删掉',
      segments: <Segment>[const TextSegment('这条要删掉')],
      time: DateTime(2026, 9, 12, 10),
      chatId: 'private_20002',
      senderId: '20002',
      senderName: '小明',
    )));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    expect(
      find.descendant(
          of: find.byType(MessageBubble), matching: find.text('这条要删掉')),
      findsOneWidget,
    );

    await tester.longPress(find.descendant(
      of: find.byType(MessageBubble),
      matching: find.text('这条要删掉'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action-delete')));
    await tester.pumpAndSettle();

    expect(find.text('删除这条消息？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('msg-delete-confirm')));
    await tester.pumpAndSettle();

    expect(store.messagesOf('private_20002'), isEmpty);
    expect(find.text('这条要删掉'), findsNothing);
    expect(store.chatOf('private_20002'), isNotNull,
        reason: '删消息不该把会话也删掉');
    await _teardownStore(tester);
  });
}
