/// 聊天页头部（ChatHeader）：三块玻璃胶囊，几何 100% 抄官方
/// \`ui/ActionBar/ActionBar.java:2232-2280 dispatchDraw()\`——
/// 胶囊高 s+2p=58、圆角 23；左胶囊宽 58；右胶囊宽 max(46,menuWidth)+12；
/// 中胶囊宽 min(W-106, 文字宽+82)、在 [52, W-(menuWidth+p)] 内居中。
/// 头像 40（\`ChatAvatarContainer.java:668\` dp(42)-2）、标题 17.5 / 副标题 13.5
/// （:756-765 setGlassMode）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/client_api/objects.dart';
import 'package:penguinchat/ui/theme/telegram_theme.dart';
import 'package:penguinchat/ui/widgets/chat_header.dart';
import 'package:penguinchat/ui/widgets/glass_surface.dart';
import 'package:penguinchat/ui/widgets/search_field_box.dart';
import 'package:penguinchat/ui/widgets/telegram_avatar.dart';

final bool goldenSkip = !Platform.isWindows;

Chat _group() => Chat(
  id: 'group_1',
  title: '产品讨论组',
  lastMessage: '',
  lastTime: DateTime(2026, 10, 30, 9, 12),
  type: ChatType.group,
  memberCount: 42,
);

Chat _priv({bool online = true}) => Chat(
  id: 'private_2',
  title: '李四',
  lastMessage: '',
  lastTime: DateTime(2026, 10, 30, 8, 5),
  online: online,
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(360, 120),
  bool dark = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 颜色是全局单例（TelegramColors.use），测试里必须自己切，否则"亮色"图仍是暗的。
  TelegramColors.use(dark ? TelegramPalette.dark : TelegramPalette.light);
  addTearDown(() => TelegramColors.use(TelegramPalette.dark));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTelegramTheme(dark: dark),
      home: Scaffold(body: child),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('几何：胶囊高 58、标题 17.5 w700、副标题 13.5、头像 40', (tester) async {
    await _pump(tester, ChatHeader(chat: _group(), onOpenSettings: () {}));
    expect(tester.getSize(find.byType(ChatHeader)).height, 58);
    final title = tester.widget<Text>(
      find.byKey(const ValueKey('chat-header-title')),
    );
    expect(title.style!.fontSize, 17.5);
    expect(title.style!.fontWeight, FontWeight.w700);
    final sub = tester.widget<Text>(
      find.byKey(const ValueKey('chat-header-subtitle')),
    );
    expect(sub.style!.fontSize, 13.5);
    expect(sub.data, '群聊 · 42 人');
    final avatar = tester.widget<TelegramAvatar>(find.byType(TelegramAvatar));
    expect(avatar.size, 40);
  });

  testWidgets('三块胶囊几何照官方：左 58、右 max(46,2*48)+12=108、高 58', (tester) async {
    // 给出 onBack + onSearch + 群菜单 → 三个胶囊齐全（360 宽）。
    await _pump(
      tester,
      ChatHeader(
        chat: _group(),
        onBack: () {},
        onSearch: () {},
        onOpenSettings: () {},
      ),
    );
    final capsules = find.byType(GlassSurface);
    expect(capsules, findsNWidgets(3));
    final left = tester.getSize(capsules.at(0));
    final middle = tester.getSize(capsules.at(1));
    final right = tester.getSize(capsules.at(2));
    // 左胶囊 = s + 2p = 58，正方形。
    expect(left.width, 58);
    expect(left.height, 58);
    // 右胶囊 = max(46, menuWidth=2*48) + 2p = 96 + 12 = 108。
    expect(right.width, 108);
    expect(right.height, 58);
    // 中胶囊 = min(W-52-rightOffset, 文字宽+82)，必在两者之间。
    expect(middle.height, 58);
    expect(middle.width, lessThanOrEqualTo(360 - 52 - 102 + 0.01));
    // 三块互不重叠：左胶囊右缘 58、中胶囊左缘 ≥ 52、右胶囊左缘 = 360-108。
    final leftRect = tester.getRect(capsules.at(0));
    final midRect = tester.getRect(capsules.at(1));
    final rightRect = tester.getRect(capsules.at(2));
    expect(leftRect.left, 0);
    expect(midRect.left, greaterThanOrEqualTo(52));
    // 官方胶囊是「左右重叠 p=6」的关系：中胶囊右缘 rightDefault=W-(menuWidth+p)
    // 可比右胶囊左缘（W-max(s,menuWidth)-2p）多出 p=6dp。
    expect(midRect.right, lessThanOrEqualTo(rightRect.left + 6.01));
    expect(rightRect.right, 360);
  });

  testWidgets('私聊显示在线/离线，没有群工具菜单', (tester) async {
    await _pump(tester, ChatHeader(chat: _priv()));
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('chat-header-subtitle')))
          .data,
      '在线',
    );
    expect(find.byKey(const ValueKey('group-menu')), findsNothing);
    await _pump(tester, ChatHeader(chat: _priv(online: false)));
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('chat-header-subtitle')))
          .data,
      '离线',
    );
  });

  testWidgets('群工具菜单三项，回调按项触发', (tester) async {
    final calls = <String>[];
    await _pump(
      tester,
      ChatHeader(
        chat: _group(),
        onOpenGroupFiles: () => calls.add('files'),
        onOpenGroupSettings: () => calls.add('settings'),
        onOpenMembers: () => calls.add('members'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('group-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-menu-files')), findsOneWidget);
    expect(find.byKey(const ValueKey('group-menu-settings')), findsOneWidget);
    expect(find.byKey(const ValueKey('group-menu-members')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('group-menu-settings')));
    await tester.pumpAndSettle();
    expect(calls, <String>['settings']);
  });

  testWidgets('返回键只在给了 onBack 时出现', (tester) async {
    await _pump(tester, ChatHeader(chat: _group()));
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    var back = 0;
    await _pump(tester, ChatHeader(chat: _group(), onBack: () => back++));
    await tester.tap(find.byIcon(Icons.arrow_back));
    expect(back, 1);
  });

  testWidgets('搜索态：群名胶囊消失，搜索框铺到右边距', (tester) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);

    await _pump(
      tester,
      ChatHeader(
        chat: _group(),
        onBack: () {},
        onSearch: () {},
        onExitSearch: () {},
        searching: true,
        searchController: controller,
        searchFocus: focus,
      ),
    );
    await tester.pumpAndSettle();

    // 官方 ChatActivity.openSearchWithText 里 headerItem 直接 INVISIBLE。
    expect(find.text('产品讨论组'), findsNothing);
    expect(find.byKey(const ValueKey('chat-search-back')), findsOneWidget);

    // 搜索框从左侧胶囊右边（58）铺到右边距 6：官方 toggleSearch 只做 alpha
    // 交叉，没有任何宽度动画，所以位置上就该一步到位。
    final double w = tester.getSize(find.byType(ChatHeader)).width;
    final Rect field = tester.getRect(find.byType(SearchFieldBox));
    expect(field.left, 58);
    expect(field.right, w - 6);

    // 收起搜索（searching 为假）时反过来：胶囊回来、搜索框消失。
    await _pump(tester, ChatHeader(chat: _group(), onBack: () {}));
    await tester.pumpAndSettle();
    expect(find.text('产品讨论组'), findsOneWidget);
    expect(find.byType(SearchFieldBox), findsNothing);
  });

  testWidgets('⋮ 菜单里有搜索，点了走 onSearch', (tester) async {
    var searched = 0;
    await _pump(tester, ChatHeader(chat: _group(), onSearch: () => searched++));
    await tester.tap(find.byKey(const ValueKey('group-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-menu-search')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('group-menu-search')));
    await tester.pumpAndSettle();
    expect(searched, 1);
  });

  testWidgets('金样：群聊头部（暗）', (tester) async {
    await _pump(tester, ChatHeader(chat: _group(), onOpenSettings: () {}));
    await expectLater(
      find.byType(ChatHeader),
      matchesGoldenFile('goldens/chat_header_group.png'),
      skip: goldenSkip,
    );
  });

  testWidgets('金样：私聊头部（亮）', (tester) async {
    await _pump(tester, ChatHeader(chat: _priv()), dark: false);
    await expectLater(
      find.byType(ChatHeader),
      matchesGoldenFile('goldens/chat_header_private_light.png'),
      skip: goldenSkip,
    );
  });
}
