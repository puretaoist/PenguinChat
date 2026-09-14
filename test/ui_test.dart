/// UI 层 widget 测试
///
/// ## 为什么需要这一组
///
/// `tool/` 下的自测全是纯 Dart，**跑不了 Widget**。所以 UI 接线
/// （ProviderScope / 三个 override / 页面从 provider 取数）此前完全没有测试，
/// 而 CI 里那步 `flutter test` 还带着 `|| true`——挂了也不阻断构建。
///
/// 这组测试要抓的是**接线错误**，不是外观：
///
/// * provider 没被 override → 构建时抛 `ProviderScope` 相关的异常
/// * 未连接（`chatStoreProvider == null`）时页面崩溃
/// * 页面在空数据下的降级路径
///
/// 外观由人工看，这里只管"能不能起来"。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/client_api/session_providers.dart';
import 'package:qqclient/kernel/onebot/backend_profile.dart';
import 'package:qqclient/kernel/safety/safety_gate.dart';
import 'package:qqclient/ui/pages/connect_page.dart';
import 'package:qqclient/ui/pages/home_page.dart';
import 'package:qqclient/ui/theme/telegram_theme.dart';
import 'package:qqclient/ui/theme/theme_mode.dart';

/// 与 `main.dart` 相同的三处 override，只是注入测试用的路径。
///
/// **刻意照抄 `main.dart` 的构造方式**：如果哪天 `main.dart` 少 override 一个，
/// 这里也会一起失败，而不是被一份"更宽松的测试配置"掩盖过去。
List<Override> _overrides() => <Override>[
      dataDirProvider.overrideWithValue(Directory.systemTemp),
      backendRegistryProvider.overrideWithValue(
        BackendProfileRegistry.fromJsonStrings(const <String>[]),
      ),
      safetyGateProvider.overrideWithValue(SafetyGate()),
    ];

Widget _wrap(Widget child) => ProviderScope(
      overrides: _overrides(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: child,
      ),
    );

void main() {
  group('DI 接线', () {
    test('三个必须 override 的 provider 都能解析', () {
      final container = ProviderContainer(overrides: _overrides());
      addTearDown(container.dispose);

      expect(container.read(dataDirProvider), isA<Directory>());
      expect(container.read(backendRegistryProvider),
          isA<BackendProfileRegistry>());
      expect(container.read(safetyGateProvider), isA<SafetyGate>());
    });

    test('未注册任何适配表时，注册表仍能兜底（不抛异常）', () {
      final container = ProviderContainer(overrides: _overrides());
      addTearDown(container.dispose);
      final reg = container.read(backendRegistryProvider);
      // resolveOrDefault 的契约：宁可退回 NapCat 表，也不能抛。
      expect(() => reg.resolveOrDefault('不存在的后端'), returnsNormally);
    });

    test('未连接时 chatStore / session 为 null（而不是抛异常）', () {
      final container = ProviderContainer(overrides: _overrides());
      addTearDown(container.dispose);
      expect(container.read(sessionProvider), isNull);
      expect(container.read(chatStoreProvider), isNull);
      expect(container.read(accountProvider), isNull);
    });

    test('默认地址是本机 NapCat 的 3001 端口', () {
      final container = ProviderContainer(overrides: _overrides());
      addTearDown(container.dispose);
      final cfg = container.read(connectionConfigProvider);
      expect(cfg.address, kDefaultOneBotAddress);
      expect(kDefaultOneBotAddress, 'ws://127.0.0.1:3001');
    });
  });

  group('HomePage', () {
    testWidgets('未连接（无 store、无会话）时能构建，不抛异常', (tester) async {
      await tester.pumpWidget(_wrap(const HomePage()));
      await tester.pump();

      expect(tester.takeException(), isNull,
          reason: '未连接状态下构建 HomePage 不应该抛异常');
      expect(find.byType(HomePage), findsOneWidget);
    });

    testWidgets('空会话列表下不崩（降级到空态)', (tester) async {
      await tester.pumpWidget(_wrap(const HomePage()));
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull,
          reason: '会话列表为空时应有空态，而不是索引越界之类的错误');
    });

    testWidgets('宽屏与窄屏都能量出布局（不依赖具体断点数值）', (tester) async {
      // 窄屏（手机）
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrap(const HomePage()));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '窄屏布局不应抛异常');

      // 宽屏（平板）：本项目的目标设备之一
      tester.view.physicalSize = const Size(3200, 2136);
      tester.view.devicePixelRatio = 2.0;
      await tester.pumpWidget(_wrap(const HomePage()));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '宽屏布局不应抛异常');
    });
  });

  group('主题切换', () {
    testWidgets('头部按钮：暗 → 亮 → 暗，调色板与 provider 同步', (tester) async {
      // 调色板是全局单例，跑完必须还原，否则会污染同文件后面的测试。
      addTearDown(() => TelegramColors.use(TelegramPalette.dark));

      final container = ProviderContainer(overrides: _overrides());
      addTearDown(container.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomePage()),
      ));
      await tester.pump();

      // 默认暗色：provider 为 true，且页面构建时把调色板设成了暗色。
      expect(container.read(themeModeProvider), isTrue);
      expect(TelegramColors.current, same(TelegramPalette.dark));
      expect(find.byIcon(Icons.light_mode), findsOneWidget,
          reason: '暗色下按钮应提示"切到亮色"');

      await tester.tap(find.byKey(const ValueKey('toggle-theme')));
      await tester.pumpAndSettle();

      expect(container.read(themeModeProvider), isFalse);
      expect(TelegramColors.current, same(TelegramPalette.light));
      expect(find.byIcon(Icons.dark_mode), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('toggle-theme')));
      await tester.pumpAndSettle();

      expect(container.read(themeModeProvider), isTrue);
      expect(TelegramColors.current, same(TelegramPalette.dark));
    });

    test('assets/theme.json 与 TelegramPalette 颜色一致（防两边各改一半）', () {
      // 权威值是 Dart 里的 TelegramPalette；这份 JSON 是给以后的
      // 主题编辑/导入导出留的数据形态。它没有代码读，所以极易烂掉——
      // 这条测试就是它的读者。
      final raw = File('assets/theme.json').readAsStringSync();
      final json = jsonDecode(raw) as Map<String, dynamic>;

      // 不透明色写 6 位（#RRGGBB），带 alpha 的写 8 位（#AARRGGBB）——
      // 与 assets/theme.json 里的人手写法一致。
      String hex(Color c) {
        final argb = c.toARGB32();
        final body = argb.toRadixString(16).padLeft(8, '0').toUpperCase();
        return (argb >> 24) == 0xFF ? '#${body.substring(2)}' : '#$body';
      }

      void check(String section, Map<String, String> fields) {
        final map = json[section] as Map<String, dynamic>;
        for (final e in fields.entries) {
          expect(map[e.key], e.value,
              reason: 'theme.json 的 $section.${e.key} 与 TelegramPalette 不一致');
        }
      }

      check('dark', {
        'bg_app': hex(TelegramPalette.dark.bgApp),
        'bg_sidebar': hex(TelegramPalette.dark.bgSidebar),
        'bg_chat': hex(TelegramPalette.dark.bgChat),
        'bg_header': hex(TelegramPalette.dark.bgHeader),
        'bg_input': hex(TelegramPalette.dark.bgInput),
        'bg_hover': hex(TelegramPalette.dark.bgHover),
        'bg_selected': hex(TelegramPalette.dark.bgSelected),
        'bubble_out': hex(TelegramPalette.dark.bubbleOut),
        'bubble_in': hex(TelegramPalette.dark.bubbleIn),
        'bubble_out_text': hex(TelegramPalette.dark.bubbleOutText),
        'bubble_out_time': hex(TelegramPalette.dark.bubbleOutTime),
        'accent': hex(TelegramPalette.dark.accent),
        'accent_hover': hex(TelegramPalette.dark.accentHover),
        'text_primary': hex(TelegramPalette.dark.textPrimary),
        'text_secondary': hex(TelegramPalette.dark.textSecondary),
        'text_muted': hex(TelegramPalette.dark.textMuted),
        'divider': hex(TelegramPalette.dark.divider),
        'online': hex(TelegramPalette.dark.online),
        'danger': hex(TelegramPalette.dark.danger),
        'badge': hex(TelegramPalette.dark.badge),
      });
      check('light', {
        'bg_app': hex(TelegramPalette.light.bgApp),
        'bg_sidebar': hex(TelegramPalette.light.bgSidebar),
        'bg_chat': hex(TelegramPalette.light.bgChat),
        'bg_header': hex(TelegramPalette.light.bgHeader),
        'bg_input': hex(TelegramPalette.light.bgInput),
        'bg_hover': hex(TelegramPalette.light.bgHover),
        'bg_selected': hex(TelegramPalette.light.bgSelected),
        'bubble_out': hex(TelegramPalette.light.bubbleOut),
        'bubble_in': hex(TelegramPalette.light.bubbleIn),
        'bubble_out_text': hex(TelegramPalette.light.bubbleOutText),
        'bubble_out_time': hex(TelegramPalette.light.bubbleOutTime),
        'accent': hex(TelegramPalette.light.accent),
        'accent_hover': hex(TelegramPalette.light.accentHover),
        'text_primary': hex(TelegramPalette.light.textPrimary),
        'text_secondary': hex(TelegramPalette.light.textSecondary),
        'text_muted': hex(TelegramPalette.light.textMuted),
        'divider': hex(TelegramPalette.light.divider),
        'online': hex(TelegramPalette.light.online),
        'danger': hex(TelegramPalette.light.danger),
        'badge': hex(TelegramPalette.light.badge),
      });

      final metrics = json['metrics'] as Map<String, dynamic>;
      expect(metrics['sidebar_width'], TelegramMetrics.sidebarWidth);
      expect(metrics['chat_row_height'], TelegramMetrics.chatRowHeight);
      expect(metrics['avatar_size'], TelegramMetrics.avatarSize);
      expect(metrics['bubble_radius'], TelegramMetrics.bubbleRadius);
      expect(metrics['input_radius'], TelegramMetrics.inputRadius);
      expect(metrics['font_body'], TelegramMetrics.fontBody);
    });

    test('主题选择落盘，重开应用能读回（不是每次启动都回暗色）', () async {
      final dir = Directory.systemTemp.createTempSync('qqclient_theme');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      List<Override> overrides() => <Override>[
            dataDirProvider.overrideWithValue(dir),
            backendRegistryProvider.overrideWithValue(
              BackendProfileRegistry.fromJsonStrings(const <String>[]),
            ),
            safetyGateProvider.overrideWithValue(SafetyGate()),
          ];

      // 第一次启动：切到亮色
      final c1 = ProviderContainer(overrides: overrides());
      addTearDown(c1.dispose);
      await c1.read(themeModeProvider.notifier).toggle();
      expect(c1.read(themeModeProvider), isFalse);

      final settings = File('${dir.path}${Platform.pathSeparator}ui_settings.json');
      expect(settings.existsSync(), isTrue, reason: '选择应写到 ui_settings.json');
      expect(jsonDecode(settings.readAsStringSync())['dark'], isFalse);

      // 第二次启动（新容器，同一个目录）：读回亮色
      final c2 = ProviderContainer(overrides: overrides());
      addTearDown(c2.dispose);
      await c2.read(themeModeProvider.notifier).load();
      expect(c2.read(themeModeProvider), isFalse, reason: '重启后应保持上次的选择');
    });

    test('ui_settings.json 坏掉时回暗色，不抛异常（不拦住启动）', () async {
      final dir = Directory.systemTemp.createTempSync('qqclient_theme_bad');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      File('${dir.path}${Platform.pathSeparator}ui_settings.json')
          .writeAsStringSync('{ 这不是 JSON');

      final container = ProviderContainer(overrides: <Override>[
        dataDirProvider.overrideWithValue(dir),
        backendRegistryProvider.overrideWithValue(
          BackendProfileRegistry.fromJsonStrings(const <String>[]),
        ),
        safetyGateProvider.overrideWithValue(SafetyGate()),
      ]);
      addTearDown(container.dispose);

      await container.read(themeModeProvider.notifier).load();
      expect(container.read(themeModeProvider), isTrue);
    });
  });

  group('表情面板', () {
    testWidgets('点表情按钮 → 面板出来 → 选一个插进输入框（断开也能用）',
        (tester) async {
      await tester.pumpWidget(_wrap(const HomePage()));
      await tester.pump();

      // 没连接也要能开（先打字选表情、连上再发）
      await tester.tap(find.byKey(const ValueKey('open-faces')));
      await tester.pumpAndSettle();
      expect(find.text('QQ 表情'), findsOneWidget);
      expect(find.byKey(const ValueKey('face-grid')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('face-微笑')));
      await tester.pumpAndSettle();

      // 面板关掉，输入框里留下 `/微笑`（发送时由协议层翻成表情元素）
      expect(find.text('QQ 表情'), findsNothing);
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller?.text, '/微笑');
    });
  });

  group('ConnectPage', () {
    testWidgets('能构建并显示默认地址', (tester) async {
      await tester.pumpWidget(_wrap(const ConnectPage()));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(ConnectPage), findsOneWidget);
      expect(find.textContaining(kDefaultOneBotAddress), findsWidgets,
          reason: '连接页应把默认地址展示出来，用户才知道该填什么');
    });

    testWidgets('默认处于离线模式（不联网）', (tester) async {
      final container = ProviderContainer(overrides: _overrides());
      addTearDown(container.dispose);

      // 安全层的第一道闸：默认必须不连真实服务器。
      expect(container.read(safetyGateProvider).isOffline, isTrue,
          reason: 'SafetyGate 默认必须是离线模式');
    });

    testWidgets('能输入文本（输入框可用）', (tester) async {
      await tester.pumpWidget(_wrap(const ConnectPage()));
      await tester.pump();

      final field = find.byType(TextField);
      expect(field, findsWidgets, reason: '连接页应有可输入的地址框');

      await tester.enterText(field.first, 'ws://192.168.1.10:3001');
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('ws://192.168.1.10:3001'), findsWidgets);
    });
  });
}
