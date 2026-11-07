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

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/client_api/chat_store.dart';
import 'package:penguinchat/client_api/objects.dart';
import 'package:penguinchat/client_api/segment.dart';
import 'package:penguinchat/client_api/session.dart';
import 'package:penguinchat/client_api/session_providers.dart';
import 'package:penguinchat/kernel/onebot/backend_profile.dart';
import 'package:penguinchat/kernel/safety/safety_gate.dart';
import 'package:penguinchat/ui/pages/home_page.dart';
import 'package:penguinchat/ui/widgets/chat_header.dart';
import 'package:penguinchat/ui/widgets/chat_input_bar.dart';
import 'package:penguinchat/ui/widgets/message_bubble.dart';

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

Widget _wrap({
  EdgeInsets safePadding = EdgeInsets.zero,
  bool reverse = false,
}) => ProviderScope(
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
  child: MaterialApp(
    // 反向列表是构造参数（原型开关，默认关）：测试里逐例开关。
    home: HomePage(reverseMessageList: reverse),
    // 把状态栏/刘海/手势条伪装出来：真机上这些值来自系统，
    // widget 测试里只能用 MediaQuery 覆盖。
    builder: (BuildContext context, Widget? child) {
      final MediaQueryData mq = MediaQuery.of(context);
      return MediaQuery(
        data: mq.copyWith(padding: safePadding, viewPadding: safePadding),
        child: child ?? const SizedBox.shrink(),
      );
    },
  ),
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
    await session.dispose().timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
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

  testWidgets('竖屏：顶部/底部安全区都让开（缺陷5：标题压状态栏）', (tester) async {
    // 360x800 逻辑像素的竖屏手机，状态栏 44、手势条 34。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    const EdgeInsets insets = EdgeInsets.only(top: 44, bottom: 34);
    await tester.pumpWidget(_wrap(safePadding: insets));
    await tester.pumpAndSettle();

    // 列表页：第一行会话不能被状态栏压住
    final double listTop = tester
        .getTopLeft(find.byKey(const ValueKey('chat-row-private_20002')))
        .dy;
    expect(listTop, greaterThanOrEqualTo(insets.top), reason: '会话行要落在状态栏下面');

    await tester.tap(find.byKey(const ValueKey('chat-row-private_20002')));
    await tester.pumpAndSettle();

    final double headerTop = tester.getTopLeft(find.byType(ChatHeader)).dy;
    expect(headerTop, greaterThanOrEqualTo(insets.top), reason: '聊天标题不能在状态栏里');

    // 输入栏背景可以铺到屏幕底（edge-to-edge），但**内容**（输入框）必须让开
    // 手势条，而且只让一次。
    expect(find.byType(ChatInputBar), findsOneWidget);
    final double inputBottom = tester.getBottomLeft(find.byType(TextField)).dy;
    expect(
      inputBottom,
      lessThanOrEqualTo(800 - insets.bottom),
      reason: '输入框要避开手势条，而且不能把留白算两遍',
    );
  });

  testWidgets('发图片：点 📎 → 按路径发送 → 真的发出一个 ImageSegment', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    // 先开一个私聊会话（右侧对话面板要指着某个会话）
    await tester.tap(find.byKey(const ValueKey('chat-row-private_20002')));
    await tester.pumpAndSettle();

    // 本地放一张真的 1x1 PNG：新的发送流程会**读文件 + 预处理**，
    // 用假路径会走"文件不存在"的失败分支。
    final file = File('${dir.path}/cat.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
        ),
      );

    await tester.tap(find.byKey(const ValueKey('attach')));
    await tester.pumpAndSettle();
    // 桌面/测试环境没有 image_picker 的平台实现，走"按路径"这条兜底入口。
    await tester.tap(find.byKey(const ValueKey('attach-image-path')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('send-image-dialog')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('send-image-path')),
      file.path,
    );
    await tester.tap(find.byKey(const ValueKey('send-image-ok')));
    await tester.pumpAndSettle();

    expect(session.sent.length, 1, reason: '要真发一条消息给会话层');
    expect(session.sent.first.chatId, 'private_20002');
    final seg = session.sent.first.segments.single;
    expect(seg, isA<ImageSegment>());
    // 1x1 小图不触发压缩，路径原样传下去。
    expect((seg as ImageSegment).file, file.path);
    // 乐观插入：气泡立刻出现在会话里（状态由消息自己承载）
    expect(store.messagesOf('private_20002').isNotEmpty, isTrue);
    // 收尾：让"已发送"提示条（4s）自己走完，否则测试结束时会报 pending Timer。
    await tester.pump(const Duration(seconds: 5));
    await _teardownStore(tester);
  });

  testWidgets('发文件：点 📄 → 填路径与文件名 → 真的发出一个 FileSegment', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-row-private_20002')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('attach')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('attach-local-file')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('send-file-dialog')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('send-file-path')),
      r'C:	mp说明.pdf',
    );
    await tester.enterText(
      find.byKey(const ValueKey('send-file-name')),
      'rename.pdf',
    );
    await tester.tap(find.byKey(const ValueKey('send-file-ok')));
    await tester.pumpAndSettle();

    expect(session.sent.length, 1);
    expect(session.sent.first.chatId, 'private_20002');
    final seg = session.sent.first.segments.single;
    expect(seg, isA<FileSegment>());
    expect((seg as FileSegment).file, r'C:	mp说明.pdf');
    expect(seg.name, 'rename.pdf');

    // 文件气泡可点：离线（协议线没在线）时点它要给一句明确提示，而不是没反应
    await tester.tap(find.byKey(const ValueKey('open-file')));
    await tester.pumpAndSettle();
    expect(find.text('需要协议线在线才能下载文件'), findsOneWidget);
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
    expect(
      find.byKey(const ValueKey('chat-row-group_12345')),
      findsNothing,
      reason: '归档后不该留在主列表里',
    );

    await tester.tap(find.byKey(const ValueKey('archived-row')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('archived-group_12345')), findsOneWidget);
    await _teardownStore(tester);
  });

  testWidgets('标为未读 → 未读计数回到 1', (tester) async {
    session.emit(
      SessionMessage(
        ChatMessage(
          id: 'm1',
          text: '在吗',
          segments: <Segment>[const TextSegment('在吗')],
          time: DateTime(2026, 9, 12, 10),
          chatId: 'private_20002',
          senderId: '20002',
          senderName: '小明',
        ),
      ),
    );
    // 等事件进 store：这里必须用 pump 推进假时钟，
    // `await Future.delayed(...)` 在 FakeAsync 里是假定时器，不 pump 会一直挂
    await tester.pump(const Duration(milliseconds: 50));
    expect(store.chatOf('private_20002')?.unreadCount, 1);

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    // 打开会话会清未读
    expect(store.chatOf('private_20002')?.unreadCount, 0);

    await tester.longPress(
      find.byKey(const ValueKey('chat-row-private_20002')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-action-unread')));
    await tester.pumpAndSettle();

    expect(
      store.chatOf('private_20002')?.unreadCount,
      1,
      reason: '标为未读后列表上要有未读点',
    );
    await _teardownStore(tester);
  });

  testWidgets('草稿：在 A 打字 → 切到 B → 切回 A，字还在（列表上也有"草稿:"）', (tester) async {
    _wideScreen(tester);
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    // 默认选中第一个会话（小明），打一行字
    await tester.enterText(find.byType(TextField).first, '还没发出去的话');
    await tester.pump(const Duration(milliseconds: 700)); // 过防抖
    expect(store.chatOf('private_20002')?.draft, '还没发出去的话');
    expect(
      find.textContaining('草稿:'),
      findsOneWidget,
      reason: '会话列表上要显示草稿，否则用户以为字丢了',
    );

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
    expect(
      find.byKey(const ValueKey('chat-row-private_20002')),
      findsOneWidget,
      reason: '别的会话不能跟着一起没',
    );
    await _teardownStore(tester);
  });

  testWidgets('转发：单击消息 → 转发 → 选目标会话 → 目标会话收到同一条内容', (tester) async {
    _wideScreen(tester);
    session.emit(
      SessionMessage(
        ChatMessage(
          id: 'fwd-1',
          text: '要转发的原话',
          segments: <Segment>[const TextSegment('要转发的原话')],
          time: DateTime(2026, 9, 12, 10),
          chatId: 'private_20002',
          senderId: '20002',
          senderName: '小明',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    // 单击气泡弹菜单（TG 的 popup）；长按现在是进多选。
    await tester.tap(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.textContaining('要转发的原话', findRichText: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('action-forward')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('action-forward')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('forward-title')), findsOneWidget);
    // 不能把消息转发到它自己所在的会话
    expect(
      find.byKey(const ValueKey('forward-to-private_20002')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('forward-to-group_12345')));
    await tester.pumpAndSettle();

    expect(session.sent.length, 1, reason: '转发就是往目标会话发一条');
    expect(session.sent.last.chatId, 'group_12345');
    expect((session.sent.last.segments.first as TextSegment).text, '要转发的原话');
    expect(
      store.messagesOf('group_12345').any((m) => m.text == '要转发的原话'),
      isTrue,
      reason: '目标会话本地也要能看到',
    );
    await _teardownStore(tester);
  });

  testWidgets('多选：勾选两条 → 工具条显示条数 → 批量删除', (tester) async {
    _wideScreen(tester);
    for (final (id, text) in const <(String, String)>[
      ('s-1', '第一条'),
      ('s-2', '第二条'),
    ]) {
      session.emit(
        SessionMessage(
          ChatMessage(
            id: id,
            text: text,
            segments: <Segment>[TextSegment(text)],
            time: DateTime(2026, 9, 12, 10, id == 's-2' ? 1 : 0),
            chatId: 'private_20002',
            senderId: '20002',
            senderName: '小明',
          ),
        ),
      );
    }
    await tester.pump(const Duration(milliseconds: 50));

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    // 长按第一条 → 多选
    await tester.longPress(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.textContaining('第一条', findRichText: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('ms-count')), findsOneWidget);
    expect(find.text('已选 1 条'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('ms-check-s-1')),
      findsOneWidget,
      reason: '选中的那条要有勾',
    );

    // 再点第二条
    await tester.tap(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.textContaining('第二条', findRichText: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条'), findsOneWidget);

    // 批量删除
    await tester.tap(find.byKey(const ValueKey('ms-delete')));
    await tester.pumpAndSettle();
    expect(find.text('删除这 2 条消息？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ms-delete-confirm')));
    await tester.pumpAndSettle();

    expect(store.messagesOf('private_20002'), isEmpty);
    expect(
      find.byKey(const ValueKey('ms-count')),
      findsNothing,
      reason: '删除后要退出多选',
    );
    await _teardownStore(tester);
  });

  testWidgets('多选：复制会按顺序把选中的消息拼成文本', (tester) async {
    _wideScreen(tester);
    for (final (id, text) in const <(String, String)>[
      ('c-1', '甲'),
      ('c-2', '乙'),
    ]) {
      session.emit(
        SessionMessage(
          ChatMessage(
            id: id,
            text: text,
            segments: <Segment>[TextSegment(text)],
            time: DateTime(2026, 9, 12, 11, id == 'c-2' ? 1 : 0),
            chatId: 'private_20002',
            senderId: '20002',
            senderName: '小明',
          ),
        ),
      );
    }
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.longPress(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.textContaining('甲', findRichText: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.textContaining('乙', findRichText: true),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ms-copy')));
    await tester.pumpAndSettle();

    // 注意：**不要**在 widget 测试里 `Clipboard.getData()`——剪贴板要走
    // platform channel，测试环境没有实现，那个 future 永远不返回（会把整个
    // 文件卡到超时）。这里断言界面反馈：提示条 + 退出多选。
    expect(find.textContaining('已复制'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('ms-count')),
      findsNothing,
      reason: '复制完退出多选',
    );
    await _teardownStore(tester);
  });

  testWidgets('多选：合并转发 → 选目标会话 → 走 forwardAsCard（不是逐条发）', (tester) async {
    _wideScreen(tester);
    session.emit(
      SessionMessage(
        ChatMessage(
          id: 'm-1',
          text: '要合并的',
          segments: <Segment>[const TextSegment('要合并的')],
          time: DateTime(2026, 9, 12, 12),
          chatId: 'private_20002',
          senderId: '20002',
          senderName: '小明',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.longPress(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.textContaining('要合并的', findRichText: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();

    final sentBefore = session.sent.length;
    await tester.tap(find.byKey(const ValueKey('ms-merge-forward')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('forward-title')),
      findsOneWidget,
      reason: '先弹目标会话选择层',
    );

    await tester.tap(find.byKey(const ValueKey('forward-to-group_12345')));
    await tester.pumpAndSettle();

    expect(session.lastCardChatId, 'group_12345');
    expect(session.lastCardNodeCount, 1);
    expect(session.sent.length, sentBefore, reason: '合并转发不走逐条 sendMessage');
    expect(find.textContaining('已合并转发'), findsOneWidget);
    await _teardownStore(tester);
  });

  testWidgets('删除单条消息：确认后消息消失，会话还在', (tester) async {
    _wideScreen(tester);
    session.emit(
      SessionMessage(
        ChatMessage(
          id: 'msg-1',
          text: '这条要删掉',
          segments: <Segment>[const TextSegment('这条要删掉')],
          time: DateTime(2026, 9, 12, 10),
          chatId: 'private_20002',
          senderId: '20002',
          senderName: '小明',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.textContaining('这条要删掉', findRichText: true),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.textContaining('这条要删掉', findRichText: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action-delete')));
    await tester.pumpAndSettle();

    expect(find.text('删除这条消息？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('msg-delete-confirm')));
    await tester.pumpAndSettle();

    expect(store.messagesOf('private_20002'), isEmpty);
    expect(find.textContaining('这条要删掉', findRichText: true), findsNothing);
    expect(store.chatOf('private_20002'), isNotNull, reason: '删消息不该把会话也删掉');
    await _teardownStore(tester);
  });

  testWidgets('群聊头像必须是正圆（槽宽 >= 头像 + 左右内边距）', (tester) async {
    _wideScreen(tester);
    session.emit(
      SessionMessage(
        ChatMessage(
          id: 'g-avatar-1',
          text: '群里说话',
          segments: <Segment>[const TextSegment('群里说话')],
          time: DateTime(2026, 9, 12, 10),
          chatId: 'group_12345',
          senderId: '20003',
          senderName: '小明',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-row-group_12345')));
    await tester.pumpAndSettle();

    final avatars = find.byType(ClipOval);
    expect(avatars, findsWidgets, reason: '群里要有真头像（ClipOval）');
    for (final Element e in avatars.evaluate()) {
      final Size s = e.size!;
      expect(
        s.width,
        moreOrLessEquals(s.height, epsilon: 0.01),
        reason: '头像盒必须是正方形；非正方盒画出来就是椭圆，实测 $s',
      );
    }
    await _teardownStore(tester);
  });

  testWidgets('系统返回键：窄屏对话页先回列表，不直接退出应用', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-row-private_20002')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatHeader), findsOneWidget);

    // 模拟系统返回键：PopScope(canPop: _showChatList) 应拦下这次 pop。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(ChatHeader), findsNothing, reason: '应当回到列表');
    expect(
      find.byKey(const ValueKey('chat-row-private_20002')),
      findsOneWidget,
    );
    await _teardownStore(tester);
  });

  testWidgets('单击气泡 → 气泡旁 popup（不是底部弹层，也没有多选项）', (tester) async {
    _wideScreen(tester);
    session.emit(
      SessionMessage(
        ChatMessage(
          id: 'p-1',
          text: '单击弹菜单',
          segments: <Segment>[const TextSegment('单击弹菜单')],
          time: DateTime(2026, 9, 12, 13),
          chatId: 'private_20002',
          senderId: '20002',
          senderName: '小明',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.textContaining('单击弹菜单', findRichText: true),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('action-copy')),
      findsOneWidget,
      reason: '单击要弹 TG 的 popup',
    );
    expect(
      find.byType(BottomSheet),
      findsNothing,
      reason: 'popup 是 Overlay，不是底部弹层',
    );
    expect(
      find.byKey(const ValueKey('action-select')),
      findsNothing,
      reason: '多选改由长按进入，不再作为菜单项',
    );
    expect(
      find.byKey(const ValueKey('action-cancel')),
      findsNothing,
      reason: 'popup 点空白即关，没有「取消」这一行（TG 也没有）',
    );

    // 菜单必须贴着**气泡**（不是整行、更不是屏幕边）：对方气泡在左，
    // 菜单左缘就在气泡右缘外侧一点点。曾经用过外层整行 Box 当锚点，
    // 菜单会被顶到屏幕右侧，这里把它钉死。
    final textRect = tester.getRect(
      find
          .descendant(
            of: find.byType(MessageBubble),
            matching: find.textContaining('单击弹菜单', findRichText: true),
          )
          .first,
    );
    final menuRect = tester.getRect(find.byKey(const ValueKey('action-copy')));
    expect(menuRect.left, greaterThan(textRect.right), reason: '菜单在气泡右侧');
    expect(
      menuRect.left - textRect.right,
      lessThan(96),
      reason: '菜单要贴着气泡，不能跑到屏幕边上',
    );

    // 点遮罩关闭，不执行动作
    await tester.tap(find.byKey(const ValueKey('message-popup-barrier')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('action-copy')), findsNothing);
    await _teardownStore(tester);
  });

  testWidgets('长按气泡 → 直接进多选（不再先弹菜单）', (tester) async {
    _wideScreen(tester);
    session.emit(
      SessionMessage(
        ChatMessage(
          id: 'lp-1',
          text: '长按多选',
          segments: <Segment>[const TextSegment('长按多选')],
          time: DateTime(2026, 9, 12, 14),
          chatId: 'private_20002',
          senderId: '20002',
          senderName: '小明',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.longPress(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.textContaining('长按多选', findRichText: true),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('ms-count')),
      findsOneWidget,
      reason: '长按应立即进入多选工具条',
    );
    expect(find.text('已选 1 条'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('action-copy')),
      findsNothing,
      reason: '长按不该再弹菜单',
    );
    await _teardownStore(tester);
  });

  testWidgets('竖屏：聊天页记住上次滚动位置（切走再回来不清零）', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // 60 条历史：远大于一屏，才有"上翻过"这回事
    session.historyPages.add(
      HistoryPage(<ChatMessage>[
        for (int i = 0; i < 60; i++)
          ChatMessage(
            id: 'h$i',
            text: '历史消息 $i',
            segments: <Segment>[TextSegment('历史消息 $i')],
            time: DateTime(2026, 9, 12, 9).add(Duration(minutes: i)),
            chatId: 'private_20002',
            senderId: '20002',
            senderName: '小明',
          ),
      ]),
    );

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-row-private_20002')));
    await tester.pumpAndSettle();
    expect(find.byType(ListView), findsOneWidget, reason: '会话里应有消息列表');

    // 上翻（非 reverse 列表：手指往下拖 = 看更早的消息）
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    final ScrollableState before = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    final double offsetBefore = before.position.pixels;
    expect(offsetBefore, greaterThan(100), reason: '先要真的滚上去了');

    // 返回列表再进来
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-row-private_20002')));
    await tester.pumpAndSettle();

    final ScrollableState after = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      after.position.pixels,
      closeTo(offsetBefore, 1),
      reason: '回到会话应回到原来的位置，而不是贴顶/贴底',
    );
    await _teardownStore(tester);
  });

  testWidgets('竖屏：离开时在最新，之后来了新消息，再进来仍是最新', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // 40 条历史：够长，能滚
    session.historyPages.add(
      HistoryPage(<ChatMessage>[
        for (int i = 0; i < 40; i++)
          ChatMessage(
            id: 'h$i',
            text: '历史消息 $i',
            segments: <Segment>[TextSegment('历史消息 $i')],
            time: DateTime(2026, 9, 12, 9).add(Duration(minutes: i)),
            chatId: 'private_20002',
            senderId: '20002',
            senderName: '小明',
          ),
      ]),
    );

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-row-private_20002')));
    await tester.pumpAndSettle();

    ScrollableState list = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      list.position.pixels,
      closeTo(list.position.maxScrollExtent, 1),
      reason: '打开会话应贴最新一条',
    );

    // 返回列表
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    // 期间又来了 30 条新消息（列表变高；真机上图片/语音解码也会这样长高）
    for (int i = 0; i < 30; i++) {
      session.emit(
        SessionMessage(
          ChatMessage(
            id: 'n$i',
            text: '新消息 $i',
            segments: <Segment>[TextSegment('新消息 $i')],
            time: DateTime(2026, 9, 12, 11).add(Duration(minutes: i)),
            chatId: 'private_20002',
            senderId: '20002',
            senderName: '小明',
          ),
        ),
      );
    }
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('chat-row-private_20002')));
    await tester.pumpAndSettle();

    list = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      list.position.pixels,
      closeTo(list.position.maxScrollExtent, 1),
      reason: '再进来必须贴最新，不能停在离开时的旧底部',
    );
    expect(find.textContaining('新消息 29'), findsOneWidget, reason: '最新一条要在屏幕上');
    await _teardownStore(tester);
  });

  testWidgets('反向列表（原型开关）：打开贴最新在 offset 0，切走再回来仍停在原处', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    session.historyPages.add(
      HistoryPage(<ChatMessage>[
        for (int i = 0; i < 60; i++)
          ChatMessage(
            id: 'h$i',
            text: '历史消息 $i',
            segments: <Segment>[TextSegment('历史消息 $i')],
            time: DateTime(2026, 9, 12, 9).add(Duration(minutes: i)),
            chatId: 'private_20002',
            senderId: '20002',
            senderName: '小明',
          ),
      ]),
    );

    await tester.pumpWidget(_wrap(reverse: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-row-private_20002')));
    await tester.pumpAndSettle();

    expect(find.byType(ListView), findsOneWidget);
    ScrollableState list = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    // 反向列表：offset 0 就是"最新"那一端（非反向时是 maxScrollExtent）。
    expect(list.position.pixels, closeTo(0, 1), reason: '反向列表打开应贴在 offset 0');
    expect(find.textContaining('历史消息 59'), findsOneWidget, reason: '最新一条要在屏幕上');
    expect(
      find.byKey(const ValueKey('jump-to-latest')),
      findsNothing,
      reason: '已经在最新端，不该显示跳到最新',
    );

    // 往历史方向滚一段（反向列表里"更早"在 offset 更大的那一端）
    list.position.jumpTo(600);
    await tester.pumpAndSettle();
    final double offsetBefore = list.position.pixels;
    expect(offsetBefore, greaterThan(100), reason: '要先真的离开最新端');
    expect(
      find.textContaining('历史消息 59'),
      findsNothing,
      reason: '滚上去之后最新一条应该已经不在屏幕上',
    );

    // 返回列表再进来
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-row-private_20002')));
    await tester.pumpAndSettle();

    list = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      list.position.pixels,
      closeTo(offsetBefore, 2),
      reason: '反向列表也要按锚点还原，而不是被拽回最新端',
    );
    await _teardownStore(tester);
  });

  testWidgets('锚点按消息 id 记：离开期间来了新消息，回来仍停在同一处', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    session.historyPages.add(
      HistoryPage(<ChatMessage>[
        for (int i = 0; i < 60; i++)
          ChatMessage(
            id: 'h$i',
            text: '历史消息 $i',
            segments: <Segment>[TextSegment('历史消息 $i')],
            time: DateTime(2026, 9, 12, 9).add(Duration(minutes: i)),
            chatId: 'private_20002',
            senderId: '20002',
            senderName: '小明',
          ),
      ]),
    );

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-row-private_20002')));
    await tester.pumpAndSettle();

    ScrollableState list = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    list.position.jumpTo(900);
    await tester.pumpAndSettle();
    final double offsetBefore = list.position.pixels;
    // 记下这一刻屏幕最上面那条消息：回来时它还应该在最上面。
    // （直接读 MessageBubble.message，不靠 Text 的 data——气泡内部可能用 RichText。）
    final List<MessageBubble> beforeBubbles = tester
        .widgetList<MessageBubble>(find.byType(MessageBubble))
        .toList();
    expect(beforeBubbles, isNotEmpty, reason: '屏幕上必须能看到气泡');
    final String anchorText = beforeBubbles.first.message.text;
    expect(anchorText, startsWith('历史消息'), reason: '最上面应是历史消息');
    expect(anchorText, isNotEmpty, reason: '屏幕上必须能看到一条历史消息');

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    // 离开期间来了 12 条新消息：非反向列表里它们在末尾，像素位置本该不变，
    // 但"像素缓存"方案在内容长高后仍可能漂——锚点方案必须稳住。
    for (int i = 0; i < 12; i++) {
      session.emit(
        SessionMessage(
          ChatMessage(
            id: 'n$i',
            text: '新消息 $i',
            segments: <Segment>[TextSegment('新消息 $i')],
            time: DateTime(2026, 9, 12, 11).add(Duration(minutes: i)),
            chatId: 'private_20002',
            senderId: '20002',
            senderName: '小明',
          ),
        ),
      );
    }
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('chat-row-private_20002')));
    await tester.pumpAndSettle();

    list = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      list.position.pixels,
      closeTo(offsetBefore, 2),
      reason: '锚点还原应回到离开时的像素',
    );
    final List<MessageBubble> afterBubbles = tester
        .widgetList<MessageBubble>(find.byType(MessageBubble))
        .toList();
    expect(afterBubbles, isNotEmpty, reason: '回来时也该有气泡');
    expect(
      afterBubbles.first.message.text,
      anchorText,
      reason: '离开时屏幕最上面那条消息，回来还要在最上面',
    );
    await _teardownStore(tester);
  });

  // 转场参数是抄来的（Telegram/AyuGram ActionBarLayout 默认路径）：150ms、
  // DecelerateInterpolator(1.5)、新页 alpha 0→1 且 translationX 48dp→0。
  // 钉住这几个数，以后谁改回 220ms 或加了 scale 都会被这条拦下。
  testWidgets('打开会话的转场：150ms 内从右侧 48dp 淡入，旧页静止', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    session.historyPages.add(
      HistoryPage(<ChatMessage>[
        ChatMessage(
          id: 'tr1',
          text: '转场',
          segments: <Segment>[TextSegment('转场')],
          time: DateTime(2026, 9, 12, 9),
          chatId: 'private_20002',
          senderId: '20002',
          senderName: '小明',
        ),
      ]),
    );

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('chat-row-private_20002')));
    await tester.pump(); // 转场第 1 帧：对话页刚进树

    final Finder pane = find.byKey(const ValueKey<String>('chat-pane'));
    expect(pane, findsOneWidget, reason: '对话页应立刻进树（淡入而不是等加载完再出现）');

    FadeTransition paneFade() => tester.widget<FadeTransition>(
      find.ancestor(of: pane, matching: find.byType(FadeTransition)).first,
    );
    bool shifted() => tester
        .widgetList<Transform>(
          find.ancestor(of: pane, matching: find.byType(Transform)),
        )
        .any((Transform w) => w.transform.getTranslation().x > 1.0);

    expect(paneFade().opacity.value, lessThan(0.9), reason: '第 1 帧还在淡入');
    expect(shifted(), isTrue, reason: '起始位置应向右偏 48dp');

    // 150ms 是抄来的时长：160ms 后必须已经完全显现、位移归零。
    await tester.pump(const Duration(milliseconds: 160));
    expect(paneFade().opacity.value, 1.0, reason: '150ms 后应完全显现');
    expect(shifted(), isFalse, reason: '落位后不该留位移');

    await tester.pumpAndSettle();
    await _teardownStore(tester);
  });

  // 退出方向也得有动画。同一套 ActionBarLayout 默认路径，关闭时旧页淡出，
  // 150ms 内它必须还留在树里——没有动画的话，第一帧就会被摘掉，人眼只看到瞬切。
  testWidgets('关闭会话的转场：旧页 150ms 内淡出，不是瞬间消失', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    session.historyPages.add(
      HistoryPage(<ChatMessage>[
        ChatMessage(
          id: 'tr2',
          text: '退出',
          segments: <Segment>[TextSegment('退出')],
          time: DateTime(2026, 9, 12, 9),
          chatId: 'private_20002',
          senderId: '20002',
          senderName: '小明',
        ),
      ]),
    );

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('chat-row-private_20002')));
    await tester.pumpAndSettle();

    final Finder pane = find.byKey(const ValueKey<String>('chat-pane'));
    expect(pane, findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump(); // 退场第 1 帧

    expect(pane, findsOneWidget, reason: '动画还在播，对话页不该立刻消失');
    final FadeTransition fade = tester.widget<FadeTransition>(
      find.ancestor(of: pane, matching: find.byType(FadeTransition)).first,
    );

    await tester.pump(const Duration(milliseconds: 80));
    expect(fade.opacity.value, lessThan(0.8), reason: '80ms 时应已明显变淡');

    await tester.pump(const Duration(milliseconds: 100));
    expect(pane, findsNothing, reason: '150ms 后应完全移除');

    await tester.pumpAndSettle();
    await _teardownStore(tester);
  });
  // 私聊气泡上不该再出现绿色发送者名：手机上私聊只有两个人，
  // 标题栏已经写明对方是谁，再标一遍纯属噪音（TG 的 needDrawName 也只在群里为真）。
  testWidgets('私聊气泡不显示发送者名，群聊气泡显示', (tester) async {
    _wideScreen(tester);

    session.historyPages.add(
      HistoryPage(<ChatMessage>[
        ChatMessage(
          id: 'sn1',
          text: '私聊一句',
          segments: <Segment>[TextSegment('私聊一句')],
          time: DateTime(2026, 9, 12, 9),
          chatId: 'private_20002',
          senderId: '20002',
          senderName: '小明',
        ),
      ]),
    );
    session.historyPages.add(
      HistoryPage(<ChatMessage>[
        ChatMessage(
          id: 'sn2',
          text: '群里一句',
          segments: <Segment>[TextSegment('群里一句')],
          time: DateTime(2026, 9, 12, 9),
          chatId: 'group_12345',
          senderId: '30001',
          senderName: '群友',
        ),
      ]),
    );

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    // 宽屏默认选中第一个会话（私聊）。
    List<MessageBubble> bubbles = tester
        .widgetList<MessageBubble>(find.byType(MessageBubble))
        .toList();
    expect(bubbles, isNotEmpty, reason: '私聊的历史应该已经铺出来了');
    expect(
      bubbles.every((MessageBubble b) => !b.showSenderName),
      isTrue,
      reason: '私聊气泡不该显示发送者名',
    );

    await tester.tap(find.byKey(const ValueKey('chat-row-group_12345')));
    await tester.pumpAndSettle();

    bubbles = tester
        .widgetList<MessageBubble>(find.byType(MessageBubble))
        .toList();
    expect(
      bubbles.any((MessageBubble b) => b.showSenderName),
      isTrue,
      reason: '群聊里多人说话，必须标出发送者',
    );

    await _teardownStore(tester);
  });
}
