/// 协议线登录页的 widget 测试（`lib/ui/pages/qq8_connect_page.dart`）
///
/// 只测**哑视图 + 接线**，不连真实服务器：
/// * 每个 `Qq8ConnectStage` 该出现什么控件、该不该出现；
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

Widget _wrapView(Qq8ConnectView view) => MaterialApp(home: Scaffold(body: view));

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

void main() {
  group('Qq8ConnectView：按阶段渲染', () {
    testWidgets('未连接：有输入框与三个登录入口，没有验证区', (tester) async {
      await tester.pumpWidget(_wrapView(
        const Qq8ConnectView(status: Qq8ConnectStatus.idle),
      ));
      expect(find.byKey(const ValueKey('qq8-uin')), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-password')), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-phone')), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-login-password')), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-login-phone')), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-login-token')), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-fetch-qrcode')), findsOneWidget);
      expect(find.text('未连接'), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-ticket')), findsNothing);
      expect(find.byKey(const ValueKey('qq8-sms-code')), findsNothing);
      expect(find.byKey(const ValueKey('qq8-enter')), findsNothing);
    });

    testWidgets('手机号短信登录按钮把手机号原文交出去；空号不触发', (tester) async {
      String? gotPhone;
      await tester.pumpWidget(_wrapView(Qq8ConnectView(
        status: const Qq8ConnectStatus(stage: Qq8LoginStage.idle),
        onPhoneLogin: (p) => gotPhone = p,
      )));
      await tester.tap(find.byKey(const ValueKey('qq8-login-phone')));
      await tester.pump();
      expect(gotPhone, isNull, reason: '手机号为空时不该发起');
      await tester.enterText(
          find.byKey(const ValueKey('qq8-phone')), ' 13800138000 ');
      await tester.tap(find.byKey(const ValueKey('qq8-login-phone')));
      await tester.pump();
      expect(gotPhone, '13800138000', reason: '要去掉两头的空白');
    });

    testWidgets('短信阶段按 smsFlow 走不同的回调（手机号线：19/18）', (tester) async {
      var refreshes = 0;
      var legacyResends = 0;
      String? code;
      await tester.pumpWidget(_wrapView(Qq8ConnectView(
        status: const Qq8ConnectStatus(
          stage: Qq8LoginStage.needsSmsCode,
          phone: '13800138000',
          smsFlow: true,
        ),
        onSubmitSmsLoginCode: (c) => code = c,
        onRefreshSmsLoginCode: () => refreshes++,
        // 密码线那两个回调也接上：若走错线，计数/内容就会不对
        onSubmitSms: (c) => code = 'WRONG:$c',
        onRequestSms: () => legacyResends++,
      )));
      expect(find.textContaining('手机号短信登录'), findsNWidgets(2),
          reason: '一行是按钮「手机号短信登录」，一行是提示');
      expect(find.text('下发/重发验证码'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('qq8-sms-code')), '654321');
      await tester.tap(find.byKey(const ValueKey('qq8-submit-sms')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('qq8-request-sms')));
      await tester.pump();
      expect(code, '654321', reason: '要走 18（onSubmitSmsLoginCode）');
      expect(refreshes, 1, reason: '要走 19（onRefreshSmsLoginCode）');
      expect(legacyResends, 0, reason: '不能误走密码线的 8');
    });

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

    testWidgets('需要滑动验证：显示地址、收 ticket 并提交', (tester) async {
      String? gotTicket;
      await tester.pumpWidget(_wrapView(Qq8ConnectView(
        status: const Qq8ConnectStatus(
          stage: Qq8LoginStage.needsSlider,
          sliderUrl: 'https://ti.qq.com/safe/tools/captcha/sms-verify-login?uin=0',
        ),
        onSubmitTicket: (t) => gotTicket = t,
      )));
      expect(find.text('需要完成滑动验证'), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-slider-url')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('qq8-ticket')), 't03ABC');
      await tester.tap(find.byKey(const ValueKey('qq8-submit-ticket')));
      await tester.pump();
      expect(gotTicket, 't03ABC');
    });

    testWidgets('需要短信码：显示手机号与"已自动下发"，提交 6 位码', (tester) async {
      String? gotCode;
      var resend = 0;
      await tester.pumpWidget(_wrapView(Qq8ConnectView(
        status: const Qq8ConnectStatus(
          stage: Qq8LoginStage.needsSmsCode,
          phone: '138****0000',
          smsAutoSent: true,
        ),
        onSubmitSms: (c) => gotCode = c,
        onRequestSms: () => resend++,
      )));
      expect(find.textContaining('已向 138****0000 下发验证码'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('qq8-sms-code')), '123456');
      await tester.tap(find.byKey(const ValueKey('qq8-submit-sms')));
      await tester.pump();
      expect(gotCode, '123456');
      await tester.tap(find.byKey(const ValueKey('qq8-request-sms')));
      await tester.pump();
      expect(resend, 1);
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

    testWidgets('等待扫码：二维码内容不是合法 PNG 时降级为文字提示', (tester) async {
      await tester.pumpWidget(_wrapView(Qq8ConnectView(
        status: Qq8ConnectStatus(
          stage: Qq8LoginStage.waitingQrScan,
          qrMessage: '二维码尚未扫描',
          qrToken: Uint8List.fromList(<int>[1, 2, 3, 4]), // 故意不是 PNG
        ),
        onPollQrcode: () {},
      )));
      expect(find.text('二维码尚未扫描'), findsOneWidget);
      await tester.pump(); // Image.memory 的 errorBuilder 在下一帧生效
      expect(find.textContaining('二维码图片解析失败'), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-poll-qrcode')), findsOneWidget);
    });

    testWidgets('已上线：出现"进入"按钮；失败：显示错误原文', (tester) async {
      var entered = 0;
      await tester.pumpWidget(_wrapView(Qq8ConnectView(
        status: const Qq8ConnectStatus(stage: Qq8LoginStage.online, uin: 10001),
        onEnterApp: () => entered++,
      )));
      expect(find.text('已上线'), findsOneWidget);
      expect(find.text('uin=10001'), findsOneWidget);
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
  });

  group('Qq8ConnectPage：provider 接线', () {
    testWidgets('在 ProviderScope 下能起来（不抛异常）', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: _overrides(),
        child: const MaterialApp(home: Qq8ConnectPage()),
      ));
      await tester.pump();
      expect(find.text('协议线登录（QQ）'), findsOneWidget);
      expect(find.byKey(const ValueKey('qq8-uin')), findsOneWidget);
      expect(find.text('未连接'), findsOneWidget);
    });

    testWidgets('账号为空时点口令登录不会崩（只是什么都不做）', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: _overrides(),
        child: const MaterialApp(home: Qq8ConnectPage()),
      ));
      await tester.tap(find.byKey(const ValueKey('qq8-login-password')));
      await tester.pump();
      expect(find.text('未连接'), findsOneWidget);
    });
  });
}
