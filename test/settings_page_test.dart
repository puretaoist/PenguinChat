/// 设置页的接线与交互测试。
///
/// 为什么单独写一个文件：设置页此前**一个测试都没有**（它读 5 个 provider、
/// 还带入场动画），重构时最容易犯的错是"watch 了 themeModeProvider 却忘了
/// applyThemePalette"和"动画不是有限时长导致 pumpAndSettle 挂死"。
/// 这里把这两条钉住，顺带验字号弹层与主题开关真的落到了 provider 上。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/client_api/session_providers.dart';
import 'package:penguinchat/kernel/onebot/backend_profile.dart';
import 'package:penguinchat/kernel/safety/safety_gate.dart';
import 'package:penguinchat/ui/pages/settings_page.dart';
import 'package:penguinchat/ui/prefs/ui_prefs.dart';
import 'package:penguinchat/ui/theme/telegram_theme.dart';
import 'package:penguinchat/ui/theme/theme_mode.dart';

late Directory dir;

Future<void> _pump(WidgetTester tester) async {
  // 足够高，让六个分组一次性进视口（ListView 是懒构建的，
  // 屏外的分组根本不在树上，find.text 会误报缺失）。
  tester.view.physicalSize = const Size(420, 1500);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  TelegramColors.use(TelegramPalette.dark);
  addTearDown(() => TelegramColors.use(TelegramPalette.dark));
  await tester.pumpWidget(ProviderScope(
    overrides: <Override>[
      dataDirProvider.overrideWithValue(dir),
      backendRegistryProvider.overrideWithValue(
        BackendProfileRegistry.fromJsonStrings(const <String>[]),
      ),
      safetyGateProvider.overrideWithValue(SafetyGate()),
    ],
    child: MaterialApp(
      theme: buildTelegramTheme(),
      home: const SettingsPage(),
    ),
  ));
  await tester.pumpAndSettle();
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(SettingsPage)));

void main() {
  setUp(() {
    dir = Directory.systemTemp.createTempSync('qqclient_settings');
  });
  tearDown(() {
    // Windows 上 provider 刚写完 ui_settings.json/ui_prefs.json 时句柄
    // 还没完全放开，删不掉不该让测试红 —— 临时目录留给系统清。
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  testWidgets('六个分组都在，账号卡可点，可点行自带 chevron', (tester) async {
    await _pump(tester);
    expect(find.text('设置'), findsOneWidget);
    for (final section in <String>['通用', '消息', '数据', '连接', '关于']) {
      expect(find.text(section), findsOneWidget, reason: section);
    }
    expect(find.byKey(const ValueKey('account-card')), findsOneWidget);
    // 文字大小是"可点 + 没自带 trailing"的行 → 必须有自动箭头。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings-font-scale')),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsOneWidget,
    );
  });

  testWidgets('主题开关同时改 provider 与全局调色板', (tester) async {
    await _pump(tester);
    final container = _container(tester);
    expect(container.read(themeModeProvider), isTrue);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    expect(container.read(themeModeProvider), isFalse);
    // 先 applyThemePalette 才会换调色板：漏了这步本页会停在暗色。
    expect(TelegramColors.isDark, isFalse);
  });

  testWidgets('字号弹层选择后落到 uiPrefs', (tester) async {
    await _pump(tester);
    final container = _container(tester);

    await tester.tap(find.byKey(const ValueKey('settings-font-scale')));
    await tester.pumpAndSettle();
    expect(find.text('立即生效'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('font-scale-1.1')));
    await tester.pumpAndSettle();
    expect(container.read(uiPrefsProvider).fontScale, 1.1);
  });

  testWidgets('入场动画是有限时长（pumpAndSettle 能静止）', (tester) async {
    tester.view.physicalSize = const Size(420, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    TelegramColors.use(TelegramPalette.dark);
    addTearDown(() => TelegramColors.use(TelegramPalette.dark));
    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[
        dataDirProvider.overrideWithValue(dir),
        backendRegistryProvider.overrideWithValue(
          BackendProfileRegistry.fromJsonStrings(const <String>[]),
        ),
        safetyGateProvider.overrideWithValue(SafetyGate()),
      ],
      child: MaterialApp(
        theme: buildTelegramTheme(),
        home: const SettingsPage(),
      ),
    ));
    // 动画未走完时第一组透明度 < 1（FadeTransition 在树上）。
    await tester.pump(const Duration(milliseconds: 80));
    final fades = tester.widgetList<FadeTransition>(find.byType(FadeTransition));
    expect(fades.any((f) => f.opacity.value < 1.0), isTrue);
    // 有限时长：settle 不会超时（无限动画这里会直接报超时）。
    await tester.pumpAndSettle();
    expect(find.text('关于'), findsOneWidget);
  });
}
