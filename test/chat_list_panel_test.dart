/// 会话侧栏（`lib/ui/widgets/chat_list_panel.dart`）的外观与几何。
///
/// 这一组补的是此前**没有任何金样**的盲区：`test/message_bubble_test.dart`
/// 只覆盖气泡列表，`test/ui_test.dart` 只管接线能不能起来。会话行的字号
/// （17/16）、未读徽章（22dp 胶囊）、行间 1px 分隔线（从 72 起）都是按 TG
/// 的 `Cells/DialogCell` 对齐的，没有金样就只能靠肉眼，改坏了没人拦。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/client_api/objects.dart';
import 'package:qqclient/ui/theme/telegram_theme.dart';
import 'package:qqclient/ui/widgets/chat_list_panel.dart';
import 'package:qqclient/ui/widgets/message_bubble.dart' show formatTime;

List<Chat> _chats() => <Chat>[
      Chat(
        id: 'group_1',
        title: '产品讨论组',
        lastMessage: '张三: 明天十点评审',
        lastTime: DateTime(2026, 10, 30, 9, 12),
        unreadCount: 12,
        type: ChatType.group,
        memberCount: 42,
        pinned: true,
      ),
      Chat(
        id: 'private_2',
        title: '李四',
        lastMessage: '好的，我看看',
        lastTime: DateTime(2026, 10, 30, 8, 5),
        online: true,
        draft: '在吗',
      ),
      Chat(
        id: 'private_3',
        title: '王五',
        lastMessage: '[图片]',
        lastTime: DateTime(2026, 10, 29, 21, 40),
        unreadCount: 1,
        muted: true,
      ),
      // 归档会话不进主列表，只出现在顶部「已归档 (1)」入口里
      Chat(
        id: 'group_4',
        title: '闲聊',
        lastMessage: '赵六: 哈哈哈',
        lastTime: DateTime(2026, 10, 29, 18, 0),
        type: ChatType.group,
        archived: true,
      ),
    ];

Future<void> _pump(
  WidgetTester tester, {
  String? selected,
  Size size = const Size(360, 560),
}) async {
  TelegramColors.use(TelegramPalette.dark);
  addTearDown(() => TelegramColors.use(TelegramPalette.dark));
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTelegramTheme(),
    home: Scaffold(
      body: ChatListPanel(
        chats: _chats(),
        store: null,
        selectedChatId: selected,
        onOpenChat: (_) {},
        onLongPressChat: (_, _) {},
        onRefresh: () async {},
        onOpenSearch: () {},
        onToggleTheme: () {},
        onOpenSettings: () {},
        onOpenArchive: (_, _) {},
        onOpenConnect: () {},
        onOpenQq8Login: () {},
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// 行间分隔线（高 1、左边距 72）都有哪些——用来验证 `needDivider` 的规则。
Finder _dividers() => find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.margin == const EdgeInsets.only(left: 72) &&
          w.child == null,
    );

void main() {
  testWidgets('会话名 17 / 摘要 16 / 时间 12：字号照 TG 的 DialogCell', (tester) async {
    await _pump(tester);

    final title = tester.widget<Text>(find.text('产品讨论组'));
    expect(title.style?.fontSize, 17, reason: 'TG 会话名 dp(17)');

    final sub = tester.widget<Text>(find.text('张三: 明天十点评审'));
    expect(sub.style?.fontSize, 16, reason: 'TG 摘要 dp(16)');

    final time =
        tester.widget<Text>(find.text(formatTime(DateTime(2026, 10, 30, 9, 12))));
    expect(time.style?.fontSize, 12, reason: 'TG 会话时间 dp(12)');
  });

  testWidgets('未读徽章是 22dp 高、最小宽 22、字号 12 加粗的胶囊', (tester) async {
    await _pump(tester);

    final badgeText = tester.widget<Text>(find.text('12'));
    expect(badgeText.style?.fontSize, 12);
    expect(badgeText.style?.fontWeight, FontWeight.w700);

    final box = tester.widget<Container>(
      find.ancestor(of: find.text('12'), matching: find.byType(Container)).first,
    );
    expect(box.constraints?.minWidth, 22);
    expect(box.constraints?.maxHeight, 22);
  });

  testWidgets('未读行标题加粗、非未读行不加粗', (tester) async {
    await _pump(tester);
    final unread = tester.widget<Text>(find.text('产品讨论组'));
    final read = tester.widget<Text>(find.text('李四'));
    expect(unread.style?.fontWeight, FontWeight.w700);
    expect(read.style?.fontWeight, FontWeight.w500);
  });

  testWidgets('行间分隔线：每行之间一条，最后一条不画；归档行也有', (tester) async {
    await _pump(tester);
    // 3 个在列表里的会话 + 1 个「已归档」入口 = 4 行 ⇒ 3 条分隔线
    expect(_dividers(), findsNWidgets(3));
  });

  testWidgets('归档会话不出现在主列表里，只在「已归档」入口计数', (tester) async {
    await _pump(tester);
    expect(find.byKey(const ValueKey('chat-row-group_4')), findsNothing);
    expect(find.byKey(const ValueKey('archived-row')), findsOneWidget);
    expect(find.text('已归档'), findsOneWidget);
  });

  testWidgets('草稿行显示「草稿: 」前缀（避免用户以为字丢了）', (tester) async {
    await _pump(tester);
    expect(find.textContaining('草稿'), findsOneWidget);
    expect(find.textContaining('在吗'), findsOneWidget);
  });

  testWidgets('选中行整行刷强调色、文字翻白', (tester) async {
    await _pump(tester, selected: 'private_2');
    final title = tester.widget<Text>(find.text('李四'));
    expect(title.style?.color, Colors.white);
  });

  testWidgets('金样：会话侧栏长什么样', (tester) async {
    // 金样按本机字体渲染（中文缺字体会变方框），跨平台有差异，只在 Windows 上跑
    if (!Platform.isWindows) return;
    await _pump(tester);
    await expectLater(
      find.byType(ChatListPanel),
      matchesGoldenFile('goldens/chat_list_panel.png'),
    );
  });
}
