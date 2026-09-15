/// 协议线登录页的 widget 测试（`lib/ui/pages/qq8_connect_page.dart`）
///
/// 只测**哑视图 + 接线**，不连真实服务器：
/// * 每个 `Qq8ConnectStage` 该出现什么控件、该不该出现；
/// * 登录方式切换（顶部 SegmentedButton）后该出现对应表单；
/// * 输入与按钮回调有没有把正确的值交出去（ticket / 验证码 / uin+口令）；
/// * `Qq8ConnectPage` 在 ProviderScope 下能起来（provider 接线没断）。
///
/// 运行：`flutter test test/qq8_connect_page_test.dart`
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/client_api/qq8_login_service.dart';
import 'package:qqclient/client_api/qq8_providers.dart';
import 'package:qqclient/client_api/session_providers.dart';
import 'package:qqclient/kernel/onebot/backend_profile.dart';
import 'package:qqclient/kernel/safety/safety_gate.dart';
import 'package:qqclient/ui/pages/qq8_connect_page.dart';
import 'package:qqclient/ui/widgets/real_server_panel.dart';

Widget _wrapView(Qq8ConnectView view) =>
    MaterialApp(home: Scaffold(body: view));

/// 与 `main.dart` 同款的三处 override（见 `test/ui_test.dart` 的写法）。
List<Override> _overrides() => <Override>[
      dataDirProvider.overrideWithValue(Directory.systemTemp),
      backendRegistryProvider.overrideWithValue(
        BackendProfileRegistry.fromJsonStrings(const <String>[]),
      ),
      safetyGateProvider.overrideWithValue(SafetyGate()),
      qq8TokenStoreProvider.overrideWithValue(_NullStore()),
    ];

class _NullStore implements Qq8TokenStore {
  @override
  Future<Qq8TokenData?> load(int uin) async => null;
  @override
  Future<void> save(Qq8TokenData data) async {}
  @override
  Future<void> clear(int uin) async {}
}

/// 点顶部方式切换的 segment。label 是「密码/二维码/短信/免密」。
Future<void> _switchMode(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  group('Qq8ConnectView：登录方式切换', () {
    testWidgets('默认口令表单：有 QQ 号/密码/登录主按钮，无其他方式表单', (tester) async {
      await tester.pumpWidget(_wrapView(
        const Qq8ConnectView(status: Qq8ConnectStatus.idle),
      ));
      expect(find.byKey(const ValueKey('qq8-uin')), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-password')), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-login-password')), findsOneWidget);
      // 口令是主推：登录主按钮文字就是「登录」
      expect(find.text('登录'), findsOneWidget);
      // 其他方式表单不应出现
      expect(find.byKey(const ValueKey('qq8-phone')), findsNothing);
      expect(find.byKey(const ValueKey('qq8-fetch-qrcode')), findsNothing);
      expect(find.byKey(const ValueKey('qq8-login-token')), findsNothing);
      // 状态行
      expect(find.text('未连接'), findsOneWidget);
    });

    testWidgets('切换到二维码：出现获取二维码按钮，口令表单消失', (tester) async {
      await tester.pumpWidget(_wrapView(
        const Qq8ConnectView(status: Qq8ConnectStatus.idle),
      ));
      await _switchMode(tester, '二维码');
      expect(find.byKey(const ValueKey('qq8-fetch-qrcode')), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-password')), findsNothing);
    });

    testWidgets('切换到短信：出现手机号与发送验证码按钮', (tester) async {
      await tester.pumpWidget(_wrapView(
        const Qq8ConnectView(status: Qq8ConnectStatus.idle),
      ));
      await _switchMode(tester, '短信');
      expect(find.byKey(const ValueKey('qq8-phone')), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-login-phone')), findsOneWidget);
      expect(find.text('发送验证码'), findsOneWidget);
    });

    testWidgets('切到免密：出现免密登录按钮', (tester) async {
      await tester.pumpWidget(_wrapView(
        const Qq8ConnectView(status: Qq8ConnectStatus.idle),
      ));
      await _switchMode(tester, '免密');
      expect(find.byKey(const ValueKey('qq8-login-token')), findsOneWidget);
      expect(find.text('免密登录'), findsOneWidget);
    });
  });

  group('Qq8ConnectView：口令登录', () {
    testWidgets('口令登录：把 uin 与口令原文交给回调', (tester) async {
      int? gotUin;
      String? gotPassword;
      await tester.pumpWidget(_wrapView(Qq8ConnectView(
        status: const Qq8ConnectStatus(stage: Qq8LoginStage.idle),
        onPasswordLogin: (uin, password) {
          gotUin = uin;
          gotPassword = password;
        },
      )));
      await tester.enterText(find.byKey(const ValueKey('qq8-uin')), '10001');
      await tester.enterText(find.byKey(const ValueKey('qq8-password')), 'hunter2');
      await tester.tap(find.byKey(const ValueKey('qq8-login-password')));
      await tester.pump();
      expect(gotUin, 10001);
      expect(gotPassword, 'hunter2');
    });

    testWidgets('账号为空时点口令登录不触发（uin 解析失败）', (tester) async {
      var called = 0;
      await tester.pumpWidget(_wrapView(Qq8ConnectView(
        status: const Qq8ConnectStatus(stage: Qq8LoginStage.idle),
        onPasswordLogin: (uin, password) => called++,
      )));
      await tester.tap(find.byKey(const ValueKey('qq8-login-password')));
      await tester.pump();
      expect(called, 0);
    });
  });

  group('Qq8ConnectView：二维码', () {
    testWidgets('点击获取二维码触发回调；无二维码时不显示刷新状态按钮', (tester) async {
      var fetched = 0;
      await tester.pumpWidget(_wrapView(Qq8ConnectView(
        status: const Qq8ConnectStatus(stage: Qq8LoginStage.idle),
        onFetchQrcode: () => fetched++,
      )));
      await _switchMode(tester, '二维码');
      expect(find.byKey(const ValueKey('qq8-poll-qrcode')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('qq8-fetch-qrcode')));
      await tester.pump();
      expect(fetched, 1);
    });

    testWidgets('等待扫码：有二维码时显示图片与刷新状态；PNG 坏时降级文字', (tester) async {
      var polled = 0;
      await tester.pumpWidget(_wrapView(Qq8ConnectView(
        status: Qq8ConnectStatus(
          stage: Qq8LoginStage.waitingQrScan,
          qrMessage: '二维码尚未扫描',
          qrToken: Uint8List.fromList(<int>[1, 2, 3, 4]), // 故意不是 PNG
        ),
        onPollQrcode: () => polled++,
      )));
      await tester.pump(); // Image.memory 的 errorBuilder 在下一帧生效
      expect(find.textContaining('二维码图片解析失败'), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-poll-qrcode')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('qq8-poll-qrcode')));
      await tester.pump();
      expect(polled, 1);
    });
  });

  group('Qq8ConnectView：手机号短信', () {
    testWidgets('发送验证码：手机号原文交给回调；空号不触发', (tester) async {
      String? gotPhone;
      await tester.pumpWidget(_wrapView(Qq8ConnectView(
        status: const Qq8ConnectStatus(stage: Qq8LoginStage.idle),
        onPhoneLogin: (p) => gotPhone = p,
      )));
      await _switchMode(tester, '短信');
      await tester.tap(find.byKey(const ValueKey('qq8-login-phone')));
      await tester.pump();
      expect(gotPhone, isNull, reason: '手机号为空时不该发起');
      await tester.enterText(
          find.byKey(const ValueKey('qq8-phone')), ' 13800138000 ');
      await tester.tap(find.byKey(const ValueKey('qq8-login-phone')));
      await tester.pump();
      expect(gotPhone, '13800138000', reason: '要去掉两头的空白');
    });
  });

  group('Qq8ConnectView：验证阶段（状态卡下）', () {
    testWidgets('滑块阶段：显示地址 + 浏览器按钮 + ticket 提交', (tester) async {
      String? gotTicket;
      String? openedUrl;
      await tester.pumpWidget(_wrapView(Qq8ConnectView(
        status: const Qq8ConnectStatus(
          stage: Qq8LoginStage.needsSlider,
          sliderUrl: 'https://ti.qq.com/safe/tools/captcha/sms-verify-login?uin=0',
        ),
        onSubmitTicket: (t) => gotTicket = t,
        onOpenBrowser: (u) => openedUrl = u,
      )));
      expect(find.text('需要完成滑动验证'), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-slider-url')), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-open-browser')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('qq8-open-browser')));
      await tester.pump();
      expect(openedUrl, 'https://ti.qq.com/safe/tools/captcha/sms-verify-login?uin=0');
      await tester.enterText(find.byKey(const ValueKey('qq8-ticket')), 't03ABC');
      await tester.tap(find.byKey(const ValueKey('qq8-submit-ticket')));
      await tester.pump();
      expect(gotTicket, 't03ABC');
    });

    testWidgets('短信阶段(smsFlow=true)：显示手机号与"下发验证码"，走 19/18 回调', (tester) async {
      var refreshes = 0;
      var legacyResends = 0;
      String? code;
      await tester.pumpWidget(_wrapView(Qq8ConnectView(
        status: const Qq8ConnectStatus(
          stage: Qq8LoginStage.needsSmsCode,
          phone: '138****0000',
          smsAutoSent: true,
          smsFlow: true,
        ),
        onSubmitSmsLoginCode: (c) => code = c,
        onRefreshSmsLoginCode: () => refreshes++,
        onSubmitSms: (c) => code = 'WRONG:$c',
        onRequestSms: () => legacyResends++,
      )));
      expect(find.textContaining('已向 138****0000 下发验证码'), findsOneWidget);
      expect(find.text('重发验证码'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('qq8-sms-code')), '654321');
      await tester.tap(find.byKey(const ValueKey('qq8-submit-sms')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('qq8-request-sms')));
      await tester.pump();
      expect(code, '654321', reason: '要走 18（onSubmitSmsLoginCode）');
      expect(refreshes, 1, reason: '要走 19（onRefreshSmsLoginCode）');
      expect(legacyResends, 0, reason: '不能误走密码线的 8');
    });

    testWidgets('设备锁：显示提示语并解锁', (tester) async {
      var unlocked = 0;
      await tester.pumpWidget(_wrapView(Qq8ConnectView(
        status: const Qq8ConnectStatus(
          stage: Qq8LoginStage.needsDeviceLock,
          deviceLockHint: '请验证密保手机',
        ),
        onUnlock: () => unlocked++,
      )));
      expect(find.text('请验证密保手机'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('qq8-unlock')));
      await tester.pump();
      expect(unlocked, 1);
    });

    testWidgets('已上线：出现"进入聊天"；失败：显示错误原文', (tester) async {
      var entered = 0;
      await tester.pumpWidget(_wrapView(Qq8ConnectView(
        status: const Qq8ConnectStatus(stage: Qq8LoginStage.online, uin: 10001),
        onEnterApp: () => entered++,
      )));
      expect(find.text('已上线'), findsOneWidget);
      expect(find.text('账号=10001'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('qq8-enter')));
      await tester.pump();
      expect(entered, 1);

      await tester.pumpWidget(_wrapView(const Qq8ConnectView(
        status: Qq8ConnectStatus(
          stage: Qq8LoginStage.failed,
          error: '登录失败：口令或账号不正确',
        ),
      )));
      expect(find.text('登录失败'), findsOneWidget);
      expect(find.text('登录失败：口令或账号不正确'), findsOneWidget);
    });

    testWidgets('busy 时按钮禁用并显示进度条', (tester) async {
      await tester.pumpWidget(_wrapView(Qq8ConnectView(
        status: const Qq8ConnectStatus(
          stage: Qq8LoginStage.connecting,
          busy: true,
        ),
        onPasswordLogin: (uin, password) {},
        onFetchQrcode: () {},
      )));
      expect(find.text('连接中…'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      final btn = tester.widget<FilledButton>(
          find.byKey(const ValueKey('qq8-login-password')));
      expect(btn.onPressed, isNull);
    });

    testWidgets('导出日志按钮存在且触发回调', (tester) async {
      var exported = 0;
      await tester.pumpWidget(_wrapView(Qq8ConnectView(
        status: const Qq8ConnectStatus(stage: Qq8LoginStage.idle),
        onExportLog: () => exported++,
      )));
      await tester.tap(find.byKey(const ValueKey('qq8-export-log')));
      await tester.pump();
      expect(exported, 1);
    });
  });

  group('Qq8ConnectPage：provider 接线', () {
    testWidgets('在 ProviderScope 下能起来（不抛异常）', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: _overrides(),
        child: const MaterialApp(home: Qq8ConnectPage()),
      ));
      await tester.pump();
      expect(find.text('QQ 账号登录'), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-uin')), findsOneWidget);
      expect(find.text('未连接'), findsOneWidget);
      // 风险确认入口必须在本页可见（旧版只在 OneBot 页有，真机上无处可开）
      expect(find.byKey(const ValueKey('real-server-banner')), findsOneWidget);
    });
  });

  group('RealServerPanel：风险确认入口', () {
    Widget wrapPanel(Widget panel) => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: panel,
            ),
          ),
        );

    Future<void> pumpPanel(WidgetTester tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: _overrides(),
        child: wrapPanel(const RealServerPanel()),
      ));
      await tester.pump();
    }

    testWidgets('未开启：单行横幅；点击展开出现检测 / 逐条确认 / 开启', (tester) async {
      await pumpPanel(tester);
      expect(find.byKey(const ValueKey('real-server-banner')), findsOneWidget);
      expect(find.byKey(const ValueKey('real-server-probe')), findsNothing,
          reason: '折叠态不该显示完整流程');

      await tester.tap(find.byKey(const ValueKey('real-server-banner')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('real-server-probe')), findsOneWidget);
      expect(find.text('开启真实服务器模式'), findsOneWidget);
      // 未勾选任何项 → 开启按钮必须是禁用的
      final btn = tester.widget<FilledButton>(
          find.byKey(const ValueKey('real-server-enable')));
      expect(btn.onPressed, isNull);
    });

    testWidgets('全部勾选后才可点开启；未做环境检测时显示闸门拒绝原文', (tester) async {
      await pumpPanel(tester);
      await tester.tap(find.byKey(const ValueKey('real-server-banner')));
      await tester.pumpAndSettle();

      for (var i = 0; i < kRiskPoints.length; i++) {
        final f = find.byKey(ValueKey('real-server-ack-$i'));
        await tester.ensureVisible(f);
        await tester.tap(f);
        await tester.pump();
      }
      final btnFinder = find.byKey(const ValueKey('real-server-enable'));
      await tester.ensureVisible(btnFinder);
      final btn = tester.widget<FilledButton>(btnFinder);
      expect(btn.onPressed, isNotNull, reason: '全勾选后应可点');

      await tester.tap(btnFinder);
      await tester.pumpAndSettle();
      // environment: null → 闸门第一道关拒绝（不联网，纯本地判定）
      expect(find.textContaining('必须先完成环境检测'), findsOneWidget);
    });
  });
}