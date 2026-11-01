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

    IndexedStack stack() =>
        tester.widget<IndexedStack>(find.byType(IndexedStack).first);
    expect(stack().index, 0);

    await tester.tap(find.byKey(const ValueKey<String>('main-tab-1')));
    await tester.pumpAndSettle();
    expect(stack().index, 1);
    // 联系人页已经在树上（IndexedStack 全量构建）：好友名与分组头都在
    expect(find.text('小明'), findsOneWidget);
    expect(find.text('小红'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('main-tab-2')));
    await tester.pumpAndSettle();
    expect(stack().index, 2);
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
}
