import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/client_api/objects.dart';
import 'package:penguinchat/ui/widgets/chat_input_bar.dart';
import 'package:penguinchat/ui/widgets/home_chat_pane.dart';
import 'package:penguinchat/ui/widgets/message_list_builder.dart';

void main() {
  const chat = Chat(id: 'private_1', title: 'A', unreadCount: 3);
  final items = buildMessageItems([
    ChatMessage(id: 'old', time: DateTime(2026, 11, 1), text: '旧消息'),
    ChatMessage(id: 'new', time: DateTime(2026, 11, 1, 0, 1), text: '新消息'),
  ], showAvatars: false);

  Future<void> pumpPane(
    WidgetTester tester,
    ScrollController controller, {
    bool reverse = true,
    bool hasMessages = true,
    bool atBottom = true,
    VoidCallback? onJump,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(
              size: Size(800, 600),
              padding: EdgeInsets.only(bottom: 24),
            ),
            child: HomeChatPane(
              chat: chat,
              items: items,
              hasMessages: hasMessages,
              wallpaperId: 'plain',
              controller: controller,
              reverse: reverse,
              topInset: 24,
              atBottom: atBottom,
              header: const SizedBox(key: ValueKey('header'), height: 58),
              inputBar: const SizedBox(key: ValueKey('input'), height: 80),
              messagesEmpty: const Text('空消息'),
              onScrollNotification: (_) => false,
              onJumpToLatest: onJump ?? () {},
              itemBuilder: (_, index, item) => SizedBox(
                key: ValueKey('source-$index'),
                height: 32,
                child: Text(item.message?.id ?? 'day'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final reverse in [false, true]) {
    testWidgets('消息布局保留 source 索引和朝向 reverse=$reverse', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await pumpPane(tester, controller, reverse: reverse);
      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('msglist-private_1')),
      );
      expect(list.reverse, reverse);
      expect(list.controller, same(controller));
      // 顶部留白 = 状态栏 24 + 页头 58 + 8（列表铺到状态栏后面）。
      expect(list.padding, const EdgeInsets.only(top: 90, bottom: 88));
      // reverse 同时翻转布局方向和取项顺序，视觉时间顺序仍是旧在上、新在下。
      expect(
        tester.getTopLeft(find.text('old')).dy,
        lessThan(tester.getTopLeft(find.text('new')).dy),
      );
      final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
      final first = delegate.builder(
        tester.element(find.byType(ListView)),
        0,
      ) as SizedBox;
      expect(first.key, ValueKey('source-${reverse ? items.length - 1 : 0}'));
      expect(tester.getTopLeft(find.byKey(const ValueKey('header'))).dy, 24);
      // 状态栏后面压一层暗渐变（壁纸亮时白图标会糊）。
      expect(find.byKey(const ValueKey('status-bar-scrim')), findsOneWidget);
      expect(tester.getBottomLeft(find.byKey(const ValueKey('input'))).dy, 600);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('翻旧消息时浮动按钮在输入预留之上，点击只派发动作', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var jumps = 0;
    await pumpPane(tester, controller, atBottom: false, onJump: () => jumps++);
    final jump = find.byKey(const ValueKey('jump-to-latest'));
    expect(tester.getBottomLeft(jump).dy, 512);
    await tester.tap(jump);
    expect(jumps, 1);
    await pumpPane(tester, controller);
    expect(jump, findsNothing);
  });

  testWidgets('消息空态不绑定滚动控制器，输入浮层保留', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpPane(tester, controller, hasMessages: false);
    expect(find.text('空消息'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    expect(controller.hasClients, isFalse);
    expect(find.byKey(const ValueKey('input')), findsOneWidget);
  });

  testWidgets('无会话空态根据连接状态展示入口且输入仍贴底', (tester) async {
    var connects = 0;
    Future<void> pump(bool connected) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeEmptyPane(
            wallpaperId: 'plain',
            connected: connected,
            inputBar: const SizedBox(key: ValueKey('empty-input'), height: 64),
            onConnect: () => connects++,
          ),
        ),
      ),
    );
    await pump(false);
    await tester.tap(find.text('去连接设置'));
    expect(connects, 1);
    expect(
      tester.getBottomLeft(find.byKey(const ValueKey('empty-input'))).dy,
      600,
    );
    await pump(true);
    expect(find.text('去连接设置'), findsNothing);
    expect(find.text('选择一个会话开始聊天'), findsOneWidget);
    expect(ChatInputBar.overlayHeight, 56);
  });
}
