/// 会话侧栏（`lib/ui/widgets/chat_list_panel.dart`）的外观与几何。
///
/// 这一组补的是此前**没有任何金样**的盲区：`test/message_bubble_test.dart`
/// 只覆盖气泡列表，`test/ui_test.dart` 只管接线能不能起来。会话行的字号
/// （17/16）、未读徽章（22dp 胶囊）、行间 1px 分隔线（从 76 起）都是按 TG
/// 的 `Cells/DialogCell` 对齐的，没有金样就只能靠肉眼，改坏了没人拦。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/client_api/objects.dart';
import 'package:penguinchat/ui/prefs/ui_prefs.dart';
import 'package:penguinchat/ui/theme/telegram_theme.dart';
import 'package:penguinchat/ui/widgets/chat_list_panel.dart';
import 'package:penguinchat/ui/widgets/message_bubble.dart' show formatTime;

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
  List<Chat>? chats,
  Size size = const Size(360, 560),
  UiPrefs prefs = const UiPrefs(),
  Future<void> Function(Chat chat)? onArchiveChat,
  Future<void> Function(Chat chat)? onToggleMuteChat,
}) async {
  TelegramColors.use(TelegramPalette.dark);
  addTearDown(() => TelegramColors.use(TelegramPalette.dark));
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTelegramTheme(),
      home: Scaffold(
        body: ChatListPanel(
          chats: chats ?? _chats(),
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
          onArchiveChat: onArchiveChat,
          onToggleMuteChat: onToggleMuteChat,
          prefs: prefs,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 行间分隔线（高 1、左边距 76）都有哪些——用来验证 `needDivider` 的规则。
Finder _dividers() => find.byWidgetPredicate(
  (w) =>
      w is Container &&
      w.margin == const EdgeInsets.only(left: 76) &&
      w.child == null,
);

void main() {
  testWidgets('头部阴影只在列表滚出 5dp 之后出现', (tester) async {
    // 够多的行才能滚（每行 70dp，12 行远超 560 高）。
    final List<Chat> many = List<Chat>.generate(
      12,
      (int i) => Chat(
        id: 'row_$i',
        title: '会话 $i',
        lastMessage: '最后一条 $i',
        lastTime: DateTime(2026, 10, 30, 9, i),
      ),
    );
    await _pump(tester, chats: many);

    AnimatedOpacity shadow() => tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byKey(const ValueKey<String>('chat-list-header-shadow')),
        matching: find.byType(AnimatedOpacity),
      ),
    );

    // 停在顶部时官方不画阴影（DialogsActivity.java:4607-4608 的 shadowVisible）。
    expect(shadow().opacity, 0);

    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(shadow().opacity, 1);
  });

  testWidgets('置顶或新消息重排时保留会话整行元素和滑动状态', (tester) async {
    final chats = _chats();
    Future<void> archive(Chat chat) async {}
    await _pump(tester, chats: chats, onArchiveChat: archive);
    final row = find.byKey(const ValueKey('chat-row-private_2'));
    final element = tester.element(row);
    final swipe = find.ancestor(of: row, matching: find.byType(Dismissible));
    final state = tester.state(swipe);
    await _pump(
      tester,
      chats: [chats[1], chats[2], chats[0], chats[3]],
      onArchiveChat: archive,
    );
    expect(tester.element(row), same(element));
    expect(tester.state(swipe), same(state));
    expect(tester.takeException(), isNull);
  });

  testWidgets('归档入口插入和移除不重建仍可见的会话行', (tester) async {
    final chats = _chats();
    await _pump(tester, chats: chats.take(3).toList());
    final row = find.byKey(const ValueKey('chat-row-private_2'));
    final element = tester.element(row);
    await _pump(tester, chats: chats);
    expect(find.byKey(const ValueKey('archived-row')), findsOneWidget);
    expect(tester.element(row), same(element));
    await _pump(tester, chats: chats.take(3).toList());
    expect(find.byKey(const ValueKey('archived-row')), findsNothing);
    expect(tester.element(row), same(element));
    expect(tester.takeException(), isNull);
  });

  testWidgets('会话名 17 / 摘要 16 / 时间 12：字号照 TG 的 DialogCell', (tester) async {
    await _pump(tester);

    final title = tester.widget<Text>(find.text('产品讨论组'));
    expect(title.style?.fontSize, 17, reason: 'TG 会话名 dp(17)');

    final sub = tester.widget<Text>(find.text('张三: 明天十点评审'));
    expect(sub.style?.fontSize, 16, reason: 'TG 摘要 dp(16)');

    final time = tester.widget<Text>(
      find.text(formatTime(DateTime(2026, 10, 30, 9, 12))),
    );
    expect(time.style?.fontSize, 12, reason: 'TG 会话时间 dp(12)');
  });

  testWidgets('未读徽章是 22dp 高、最小宽 22、字号 12 加粗的胶囊', (tester) async {
    await _pump(tester);

    final badgeText = tester.widget<Text>(find.text('12'));
    expect(badgeText.style?.fontSize, 12);
    expect(badgeText.style?.fontWeight, FontWeight.w700);

    final box = tester.widget<Container>(
      find
          .ancestor(of: find.text('12'), matching: find.byType(Container))
          .first,
    );
    expect(box.constraints?.minWidth, 22);
    expect(box.constraints?.maxHeight, 22);
  });

  testWidgets('会话名恒加粗：未读 w700、已读 w600（TG dialogs_namePaint 走 BOLD）', (
    tester,
  ) async {
    await _pump(tester);
    final unread = tester.widget<Text>(find.text('产品讨论组'));
    final read = tester.widget<Text>(find.text('李四'));
    expect(unread.style?.fontWeight, FontWeight.w700);
    expect(read.style?.fontWeight, FontWeight.w600);
  });

  testWidgets('行间分隔线：每行之间一条，最后一条不画；归档行也有', (tester) async {
    await _pump(tester);
    // 3 个在列表里的会话 + 1 个「已归档」入口 = 4 行 ⇒ 3 条分隔线
    expect(_dividers(), findsNWidgets(3));
  });

  testWidgets('关掉分隔线后一条都不画（prefs 开关生效）', (tester) async {
    await _pump(tester, prefs: const UiPrefs(disableDividers: true));
    expect(_dividers(), findsNothing);
  });

  testWidgets('时间带秒：开开关后时间变成 09:12:00', (tester) async {
    await _pump(tester, prefs: const UiPrefs(timeWithSeconds: true));
    expect(
      find.text(formatTime(DateTime(2026, 10, 30, 9, 12), withSeconds: true)),
      findsOneWidget,
    );
  });

  testWidgets('会话行高照 TG 的 70、头像 52（A1 尺寸对齐）', (tester) async {
    await _pump(tester);
    final row = tester.getSize(find.byKey(const ValueKey('chat-row-group_1')));
    expect(row.height, TelegramMetrics.chatRowHeight);
    expect(TelegramMetrics.chatRowHeight, 70.0);
    expect(TelegramMetrics.avatarSize, 52.0);
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

  testWidgets('左滑一行 = 归档、右滑一行 = 静音（TG 的 DialogCell 滑动动作）', (tester) async {
    Chat? archived;
    Chat? muted;
    await _pump(
      tester,
      onArchiveChat: (chat) async => archived = chat,
      onToggleMuteChat: (chat) async => muted = chat,
    );

    // 左滑（endToStart）→ 归档
    await tester.drag(
      find.byKey(const ValueKey('chat-row-private_2')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(archived?.id, 'private_2', reason: '左滑要回调归档');
    expect(muted, isNull, reason: '左滑不该同时触发静音');

    // 右滑（startToEnd）→ 静音
    await tester.drag(
      find.byKey(const ValueKey('chat-row-private_3')),
      const Offset(300, 0),
    );
    await tester.pumpAndSettle();
    expect(muted?.id, 'private_3', reason: '右滑要回调静音');
  });

  testWidgets('没有滑动回调时不挂 Dismissible（纯展示场景不受影响）', (tester) async {
    await _pump(tester);
    expect(find.byType(Dismissible), findsNothing);
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
