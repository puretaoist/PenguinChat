/// 底栏 / 联系人 / 资料页的组件测试。
///
/// 这三块是"参照最新 TG 补的"（MainTabsActivity 4 槽悬浮胶囊 / UserCell 行 /
/// ProfileActivity）。这里锁的是**行为**：
/// * 底栏 4 个槽能切换，切到设置 tab 时页头**没有返回箭头**（tab 是根视图）；
/// * 点联系人行能进资料页，资料页显示 QQ 号与信息行；
/// * 「发消息」在还没有会话时给出明确提示（不假装能发）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/client_api/objects.dart';
import 'package:penguinchat/client_api/qq8_login_service.dart';
import 'package:penguinchat/client_api/qq8_providers.dart';
import 'package:penguinchat/client_api/session_providers.dart';
import 'package:penguinchat/kernel/onebot/backend_profile.dart';
import 'package:penguinchat/kernel/safety/safety_gate.dart';
import 'package:penguinchat/kernel/wlogin8/qq8_list.dart';
import 'package:penguinchat/ui/pages/contacts_page.dart';
import 'package:penguinchat/ui/pages/friend_profile_page.dart';
import 'package:penguinchat/ui/pages/home_shell.dart';
import 'package:penguinchat/ui/pages/settings_page.dart';
import 'package:penguinchat/ui/theme/telegram_theme.dart';

final List<Qq8Friend> _friends = <Qq8Friend>[
  const Qq8Friend(uin: 20002, nick: '小明', remark: '', groupId: 1, sex: 1),
  const Qq8Friend(uin: 20003, nick: '小红', remark: '同事', groupId: 1, sex: 2),
];

Widget _wrap(Widget child) => ProviderScope(
      overrides: <Override>[
        dataDirProvider.overrideWithValue(Directory.systemTemp),
        backendRegistryProvider.overrideWithValue(
          BackendProfileRegistry.fromJsonStrings(const <String>[]),
        ),
        safetyGateProvider.overrideWithValue(SafetyGate()),
        qq8LoginServiceProvider.overrideWithValue(Qq8LoginService()),
        qq8FriendsProvider.overrideWith((ref) async => _friends),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTelegramTheme(),
        home: child,
      ),
    );

Future<void> _setView(WidgetTester tester) async {
  TelegramColors.use(TelegramPalette.dark);
  addTearDown(() => TelegramColors.use(TelegramPalette.dark));
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('底栏：4 个槽可切换，设置 tab 的页头没有返回箭头', (tester) async {
    await _setView(tester);
    await tester.pumpWidget(_wrap(const HomeShell()));
    await tester.pumpAndSettle();

    // 4 个槽都在（文案来自 MainTabsActivity 的四槽语义）。
    // 注意：四个 Tab 现在都有同名页头标题，所以这里必须**限定在底栏内**找，
    // 否则「聊天/联系人/我的」各会命中页头 + 标签两个。
    Finder inBar(String label) => find.descendant(
          of: find.byKey(const ValueKey<String>('main-tab-bar')),
          matching: find.text(label),
        );
    expect(inBar('聊天'), findsOneWidget);
    expect(inBar('联系人'), findsOneWidget);
    expect(inBar('设置'), findsOneWidget);
    expect(inBar('我的'), findsOneWidget);

    // 容器是 HorizontalPager（水平滑动切页），非当前页只是 Offstage 隐藏，
    // 所以用默认 skipOffstage 的 find.text 判可见性即可。
    expect(find.text('小明'), findsNothing, reason: '初始在聊天 tab，联系人页不可见');

    await tester.tap(find.byKey(const ValueKey<String>('main-tab-1')));
    await tester.pumpAndSettle();
    expect(find.text('小明'), findsOneWidget);
    expect(find.text('小红'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('main-tab-2')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    // 作为 tab 出现时不能有返回箭头（否则用户会以为能退回上一页）
    expect(
      find.descendant(
        of: find.byType(SettingsPage),
        matching: find.byIcon(Icons.arrow_back),
      ),
      findsNothing,
    );
  });

  testWidgets('联系人：点行进资料页，「发消息」在没有会话时给提示', (tester) async {
    await _setView(tester);
    await tester.pumpWidget(_wrap(const ContactsPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('contact-20002')));
    await tester.pumpAndSettle();

    expect(find.byType(FriendProfilePage), findsOneWidget);
    expect(find.text('QQ 20002'), findsOneWidget);
    expect(find.text('昵称'), findsOneWidget);
    expect(find.text('小明'), findsWidgets);

    await tester.tap(find.text('发消息'));
    await tester.pumpAndSettle();
    // 没有会话 → 明确告知，而不是静默什么都不做
    expect(find.textContaining('还没有和 TA 的会话'), findsOneWidget);
  });

  testWidgets('资料页：备注与分组行按服务层数据渲染', (tester) async {
    await _setView(tester);
    await tester.pumpWidget(
      _wrap(const FriendProfilePage(friend: Qq8Friend(
        uin: 20003,
        nick: '小红',
        remark: '同事',
        groupId: 1,
        sex: 2,
      ))),
    );
    await tester.pumpAndSettle();

    expect(find.text('备注'), findsOneWidget);
    // displayName 备注优先（qq8_list.dart 的 Qq8Friend.displayName），
    // 所以"同事"既是页头名字也是备注值 —— 两处都算对。
    expect(find.text('同事'), findsWidgets);
    expect(find.text('女'), findsOneWidget);
  });

  // 平板（宽屏）是双栏，胶囊 tab 只落在左侧会话列表栏内（不跨两栏分界线）。
  // 依据：官方最新版（13.0.3）平板就是双栏 + 侧栏内的胶囊；
  // MainTabsLayout.java:64,69 把胶囊宽夹在 320~344，正好一个侧栏宽。
  // 锁四件事：胶囊存在且靠左（left=8、宽=侧栏宽-16）、4 槽齐全、
  // 没有上抬用的 AnimatedPadding、能点槽切 tab。
  testWidgets('宽屏：胶囊 tab 落在左侧栏内，内容区不上抬', (tester) async {
    TelegramColors.use(TelegramPalette.dark);
    addTearDown(() => TelegramColors.use(TelegramPalette.dark));
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(const HomeShell()));
    await tester.pumpAndSettle();

    final bar = find.byKey(const ValueKey<String>('main-tab-bar'));
    expect(bar, findsOneWidget);
    for (int i = 0; i < 4; i++) {
      expect(find.byKey(ValueKey<String>('main-tab-$i')), findsOneWidget);
    }
    // 位置：左侧栏内居中、左右各留 8dp（官方 MAIN_TABS_MARGIN=8）；内部再做 12dp padding。
    // 900dp → 侧栏 max(320,315)=320 → 胶囊 320-16=304。
    final rect = tester.getRect(bar);
    expect(rect.left, 8);
    expect(rect.width, 304);
    expect(rect.right, 312, reason: '胶囊仍在左侧栏内，不越分界线');

    // 宽屏不再有整页 IndexedStack：主壳只渲染一个 HomePage，
    // 左栏按 wideTabProvider 切页（官方平板换 tab 只换左栏）。
    expect(find.byType(IndexedStack), findsNothing);
    // 右栏始终是当前对话面板（此刻是空态）。
    expect(find.text('选择一个会话开始聊天'), findsOneWidget);

    // 竖栏可切 tab：点「设置」槽位后，左栏换成设置页，右栏保持不变。
    await tester.tap(find.byKey(const ValueKey<String>('main-tab-2')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('wide-left-pane-2')),
      findsOneWidget,
    );
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(
      find.text('选择一个会话开始聊天'),
      findsOneWidget,
      reason: '官方平板换 tab 只换左栏，右栏对话面板不动',
    );

    // 再点一次「联系人」→ 左栏换联系人页。
    await tester.tap(find.byKey(const ValueKey<String>('main-tab-1')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('wide-left-contacts')),
      findsOneWidget,
    );
  });

  // 打开会话时底栏要让位、内容区要长高；这两件事必须和 HomePage 的 150ms 转场
  // 同一节拍渐进而非瞬跳（否则整块布局先闪一下，转场动画看起来就像没有）。
  testWidgets('底栏让位与内容区让位同节拍：150ms 且初始可见', (tester) async {
    await _setView(tester);
    await tester.pumpWidget(_wrap(const HomeShell()));
    await tester.pumpAndSettle();

    final AnimatedPadding pad = tester.widget<AnimatedPadding>(
      find.ancestor(
        of: find.byKey(const ValueKey<String>('tab-content-pager')),
        matching: find.byType(AnimatedPadding),
      ).first,
    );
    expect(pad.duration, const Duration(milliseconds: 150));

    final AnimatedOpacity bar = tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byKey(const ValueKey<String>('main-tab-bar')),
        matching: find.byType(AnimatedOpacity),
      ).first,
    );
    expect(bar.duration, const Duration(milliseconds: 150));
    expect(bar.opacity, 1.0, reason: '列表态底栏必须可见');
  });
}
