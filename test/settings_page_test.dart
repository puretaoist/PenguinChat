/// 设置页的接线与交互测试（对应"一级列表 + 四个二级页"结构）。
///
/// 结构变更（抄 ayu MainPreferences）：一级只有入口，具体开关都在二级页，
/// 所以本文件既验证一级入口/账号卡/入场动画，也验证四个二级页的开关、
/// 弹层真的落到 provider 上。注意：push 二级页后，一级页处于 offstage，
/// 取 provider container 时必须 skipOffstage:false。
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
  // 足够高，让一级分组与二级页内容一次性进视口（ListView 懒构建）。
  tester.view.physicalSize = const Size(420, 2100);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  TelegramColors.use(TelegramPalette.dark);
  addTearDown(() => TelegramColors.use(TelegramPalette.dark));
  await tester.pumpWidget(
    ProviderScope(
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
    ),
  );
  await tester.pumpAndSettle();
}

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(SettingsPage, skipOffstage: false)),
);

Future<void> _open(WidgetTester tester, String key) async {
  final Finder entry = find.byKey(ValueKey<String>(key));
  expect(entry, findsOneWidget, reason: key);
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byTooltip('返回'));
  await tester.pumpAndSettle();
}

Future<void> _toggle(WidgetTester tester, String key) async {
  final Finder sw = find.descendant(
    of: find.byKey(ValueKey<String>(key)),
    matching: find.byType(Switch),
  );
  expect(sw, findsOneWidget, reason: key);
  await tester.tap(sw);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    dir = Directory.systemTemp.createTempSync('qqclient_settings');
  });
  tearDown(() {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  testWidgets('一级页：入口分组齐全，账号卡可点，入口行没有右箭头', (tester) async {
    await _pump(tester);
    // 页标题与分组名都叫「设置」，允许出现两次。
    expect(find.text('设置'), findsWidgets);
    for (final String section in <String>['数据', '连接', '关于']) {
      expect(find.text(section), findsOneWidget, reason: section);
    }
    for (final String key in <String>[
      'settings-general',
      'settings-appearance',
      'settings-chats',
      'settings-other',
    ]) {
      expect(find.byKey(ValueKey<String>(key)), findsOneWidget, reason: key);
    }
    expect(find.byKey(const ValueKey('account-card')), findsOneWidget);
    // 官方的 SettingCell 本身不画 chevron（SettingsActivity.java 全文只有
    // AccountCell 在 :1054-1074 画 msg_arrowright），靠水波纹表达可点。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings-general')),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsNothing,
    );
  });

  testWidgets('四个二级页都能打开并显示自己的标题', (tester) async {
    await _pump(tester);
    for (final MapEntry<String, String> e in <String, String>{
      'settings-general': '通用',
      'settings-appearance': '外观',
      'settings-chats': '聊天',
      'settings-other': '其他',
    }.entries) {
      await _open(tester, e.key);
      expect(find.text(e.value), findsWidgets, reason: e.key);
      await _back(tester);
    }
  });

  testWidgets('外观页：主题开关同时改 provider 与全局调色板', (tester) async {
    await _pump(tester);
    final ProviderContainer container = _container(tester);
    expect(container.read(themeModeProvider), isTrue);

    await _open(tester, 'settings-appearance');
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    expect(container.read(themeModeProvider), isFalse);
    // 先 applyThemePalette 才会换调色板：漏了这步本页会停在暗色。
    expect(TelegramColors.isDark, isFalse);
  });

  testWidgets('外观页：字号弹层选择后落到 uiPrefs', (tester) async {
    await _pump(tester);
    final ProviderContainer container = _container(tester);

    await _open(tester, 'settings-appearance');
    await tester.tap(find.byKey(const ValueKey('settings-font-scale')));
    await tester.pumpAndSettle();
    expect(find.text('文字大小'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('font-scale-1.1')));
    await tester.pumpAndSettle();
    expect(container.read(uiPrefsProvider).fontScale, 1.1);
  });

  testWidgets('外观页：主题色弹层选择后落到 uiPrefs', (tester) async {
    await _pump(tester);
    final ProviderContainer container = _container(tester);
    expect(container.read(uiPrefsProvider).accentId, 'default');

    await _open(tester, 'settings-appearance');
    await tester.tap(find.byKey(const ValueKey('settings-accent')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('accent-violet')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-blue')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('accent-blue')));
    await tester.pumpAndSettle();
    expect(container.read(uiPrefsProvider).accentId, 'blue');
    expect(TelegramColors.accent, const Color(0xFF3390EC));
  });

  testWidgets('外观页：聊天背景弹层选择后落到 uiPrefs', (tester) async {
    await _pump(tester);
    final ProviderContainer container = _container(tester);
    expect(container.read(uiPrefsProvider).wallpaperId, 'plain');

    await _open(tester, 'settings-appearance');
    await tester.tap(find.byKey(const ValueKey('settings-wallpaper')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('wallpaper-dusk')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('wallpaper-dusk')));
    await tester.pumpAndSettle();
    expect(container.read(uiPrefsProvider).wallpaperId, 'dusk');
  });

  testWidgets('外观页：聊天列表预览条在，滑块拖动改 uiPrefs.avatarCorners', (tester) async {
    await _pump(tester);
    final ProviderContainer container = _container(tester);

    await _open(tester, 'settings-appearance');
    // 预览条画的是真实会话行（Alice / Bob 两条样例）
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(container.read(uiPrefsProvider).avatarCorners, 30.0);

    // 外观页有两个滑块（气泡圆角/头像圆角，Slider 是行的兄弟节点），
    // 第二个才是头像圆角。
    final Finder slider = find.byType(Slider).at(1);
    await tester.drag(slider, const Offset(-80, 0));
    await tester.pumpAndSettle();
    expect(container.read(uiPrefsProvider).avatarCorners, lessThan(30.0));
  });

  testWidgets('外观页：分隔线开关落到 uiPrefs', (tester) async {
    await _pump(tester);
    final ProviderContainer container = _container(tester);
    await _open(tester, 'settings-appearance');
    await _toggle(tester, 'settings-disable-dividers');
    expect(container.read(uiPrefsProvider).disableDividers, isTrue);
  });

  testWidgets('通用页：时间带秒与未读数缩写落到 uiPrefs', (tester) async {
    await _pump(tester);
    final ProviderContainer container = _container(tester);

    await _open(tester, 'settings-general');
    await _toggle(tester, 'settings-time-with-seconds');
    expect(container.read(uiPrefsProvider).timeWithSeconds, isTrue);

    // 界面文案是「未读数缩写」，存储字段取反
    await _toggle(tester, 'settings-unread-rounding');
    expect(container.read(uiPrefsProvider).disableNumberRounding, isTrue);
  });

  testWidgets('聊天页：通知开关与长按菜单项开关落到 uiPrefs', (tester) async {
    await _pump(tester);
    final ProviderContainer container = _container(tester);

    await _open(tester, 'settings-chats');
    await _toggle(tester, 'settings-notifications');
    expect(container.read(uiPrefsProvider).notifications, isFalse);

    await _toggle(tester, 'settings-menu-copy');
    expect(container.read(uiPrefsProvider).menuShowCopy, isFalse);
  });

  testWidgets('入场动画是有限时长（pumpAndSettle 能静止）', (tester) async {
    tester.view.physicalSize = const Size(420, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    TelegramColors.use(TelegramPalette.dark);
    addTearDown(() => TelegramColors.use(TelegramPalette.dark));
    await tester.pumpWidget(
      ProviderScope(
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
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));
    final Iterable<FadeTransition> fades = tester.widgetList<FadeTransition>(
      find.byType(FadeTransition),
    );
    expect(fades.any((FadeTransition f) => f.opacity.value < 1.0), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('其他'), findsOneWidget);
  });
}
