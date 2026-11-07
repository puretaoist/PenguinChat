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

  testWidgets('三块胶囊几何照官方：左 58、右 max(46,48)+12=60、高 58', (tester) async {
    // 普通群聊右侧只有 ⋮ 一个 action item（官方 `searchIconItem` 非 self 会话
    // 是 GONE 的，ChatActivity.java:18503-18538），所以菜单宽 48。
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
    // 右胶囊 = max(46, menuWidth=48) + 2p = 48 + 12 = 60。
    expect(right.width, 60);
    expect(right.height, 58);
    // 中胶囊 = min(W-52-rightOffset, 文字宽+82)，必在两者之间。
    expect(middle.height, 58);
    expect(middle.width, lessThanOrEqualTo(360 - 52 - 54 + 0.01));
    // 三块互不重叠：左胶囊右缘 58、中胶囊左缘 ≥ 52、右胶囊左缘 = 360-60。
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

  testWidgets('搜索态：同一块玻璃扩宽，头像标题淡出、输入框淡入', (tester) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);

    // 先进普通态量一下中间玻璃的宽，作为形变起点。
    await _pump(tester, ChatHeader(chat: _group(), onBack: () {}));
    final double collapsed = tester
        .getSize(find.byType(GlassSurface).at(1))
        .width;

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

    // 官方 `ChatActivity.openSearchWithText` 把 headerItem 藏了，
    // avatarContainer 的 factor 到 0（`:46995-47004`）。
    expect(find.byKey(const ValueKey('chat-header-title')), findsNothing);
    expect(find.byKey(const ValueKey('chat-search-back')), findsOneWidget);

    // 同一块玻璃扩到中间可用宽：W - 左默认 52 - rightOffset(48+6=54) = 254。
    final double expanded = tester
        .getSize(find.byType(GlassSurface).at(1))
        .width;
    expect(expanded, greaterThan(collapsed));
    expect(expanded, closeTo(360 - 52 - 54, 0.01));
    // 居中：左界 = (rightDefault + leftDefault - width) / 2。
    final Rect glass = tester.getRect(find.byType(GlassSurface).at(1));
    expect(glass.left, closeTo((306 + 52 - expanded) / 2, 0.01));

    // 官方聊天页的搜索框是透明背景的内联 EditText（`ActionBarMenuItem.java:1527-1535`），
    // 不是另摆一颗带底色的 SearchFieldBox。
    expect(find.byType(SearchFieldBox), findsNothing);
    expect(find.byKey(const ValueKey('chat-search-input')), findsOneWidget);

    // 收起搜索（searching 为假）时反过来：头像标题回来、输入框淡出。
    await _pump(
      tester,
      ChatHeader(
        chat: _group(),
        onBack: () {},
        searchController: controller,
        searchFocus: focus,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-header-title')), findsOneWidget);
    expect(
      tester.getSize(find.byType(GlassSurface).at(1)).width,
      closeTo(collapsed, 0.01),
    );
  });

  testWidgets('玻璃形变是 320ms 渐变，不是一步到位', (tester) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);

    await _pump(tester, ChatHeader(chat: _group(), onBack: () {}));
    final double collapsed = tester
        .getSize(find.byType(GlassSurface).at(1))
        .width;

    // 换 searching=true 后只走 160ms（半程），宽度应介于两端之间。
    tester.view.physicalSize = const Size(360, 120);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTelegramTheme(dark: true),
        home: Scaffold(
          body: ChatHeader(
            chat: _group(),
            onBack: () {},
            onExitSearch: () {},
            searching: true,
            searchController: controller,
            searchFocus: focus,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 160));
    final double mid = tester.getSize(find.byType(GlassSurface).at(1)).width;
    await tester.pumpAndSettle();
    final double full = tester.getSize(find.byType(GlassSurface).at(1)).width;

    expect(mid, greaterThan(collapsed), reason: '160ms 后应该已经开始变宽');
    expect(mid, lessThan(full), reason: '320ms 才走完，半程不该一步到位');
  });

  testWidgets('输入内容是 150ms 淡入，首帧必须接近全透明', (tester) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);

    // 这个 widget 是「进搜索那一刻」才第一次挂载的，用 AnimatedOpacity 会因为
    // 首帧目标值已是 1 而直接跳到位、根本没有过渡；官方那是独立的 150ms
    // `searchFieldVisibleAlpha`（ActionBar.java:1207-1220），必须真的从 0 起。
    tester.view.physicalSize = const Size(360, 120);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTelegramTheme(dark: true),
        home: Scaffold(
          body: ChatHeader(
            chat: _group(),
            onBack: () {},
            onExitSearch: () {},
            searching: true,
            searchController: controller,
            searchFocus: focus,
          ),
        ),
      ),
    );

    double alphaOf() => tester
        .widget<Opacity>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('chat-search-input')),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;

    expect(alphaOf(), lessThan(0.2), reason: '首帧应该几乎全透明');

    await tester.pump(const Duration(milliseconds: 75));
    final double mid = alphaOf();
    expect(mid, greaterThan(0.2), reason: '半程应该已经明显可见');
    expect(mid, lessThan(0.98), reason: '150ms 才走完，半程不该到满');

    await tester.pumpAndSettle();
    expect(alphaOf(), 1.0);
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
