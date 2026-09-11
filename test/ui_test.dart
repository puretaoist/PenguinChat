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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/client_api/session_providers.dart';
import 'package:qqclient/kernel/onebot/backend_profile.dart';
import 'package:qqclient/kernel/safety/safety_gate.dart';
import 'package:qqclient/ui/pages/connect_page.dart';
import 'package:qqclient/ui/pages/home_page.dart';

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
