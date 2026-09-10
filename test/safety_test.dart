/// 安全防护层单元测试
///
/// 运行：flutter test test/safety_test.dart
///
/// 更完整的验证见 `tool/safety_selftest.dart`（纯 Dart，53 项）。
/// 本文件覆盖最关键的不变式，作为 CI 的第一道闸门。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/kernel/safety/attempt_limiter.dart';
import 'package:qqclient/kernel/safety/safety_gate.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('qqsafety_flutter_test_');
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('LoginAttemptLimiter', () {
    test('窗口内次数达上限后拒绝尝试', () async {
      final l = LoginAttemptLimiter(
        window: const Duration(minutes: 10),
        maxInWindow: 2,
        baseCooldown: Duration.zero,
      );
      await l.beginAttempt();
      await l.beginAttempt();
      expect(l.status().allowed, isFalse);
    });

    test('冷却时长随连续失败递增', () async {
      final l = LoginAttemptLimiter(
        baseCooldown: const Duration(seconds: 30),
        window: const Duration(minutes: 10),
        maxInWindow: 100,
      );
      await l.recordFailure();
      final c1 = l.currentCooldown;
      await l.recordFailure();
      final c2 = l.currentCooldown;
      expect(c2, greaterThan(c1));
    });

    test('连续失败达阈值触发硬锁', () async {
      final l = LoginAttemptLimiter(
        hardLockAfter: 3,
        hardLockDuration: const Duration(hours: 24),
        window: const Duration(minutes: 10),
        maxInWindow: 100,
        baseCooldown: Duration.zero,
      );
      for (var i = 0; i < 3; i++) {
        await l.recordFailure();
      }
      final st = l.status();
      expect(st.allowed, isFalse);
      expect(st.waitFor.inHours, greaterThanOrEqualTo(23));
    });

    test('计数持久化：重启后仍受限（关键不变式）', () async {
      final f = File('${tmp.path}/a.json');
      final l1 = LoginAttemptLimiter(
        window: const Duration(minutes: 10),
        maxInWindow: 5,
        baseCooldown: const Duration(minutes: 5),
        persistFile: f,
      );
      await l1.load();
      await l1.beginAttempt();
      await l1.recordFailure();

      final l2 = LoginAttemptLimiter(
        window: const Duration(minutes: 10),
        maxInWindow: 5,
        baseCooldown: const Duration(minutes: 5),
        persistFile: f,
      );
      await l2.load();
      expect(l2.consecutiveFailures, 1);
      expect(l2.status().allowed, isFalse, reason: '不能靠重启绕过冷却');
    });

    test('成功记录清零失败计数', () async {
      final l = LoginAttemptLimiter(hardLockAfter: 2);
      await l.recordFailure();
      await l.recordFailure();
      expect(l.status().allowed, isFalse);
      await l.recordSuccess();
      expect(l.consecutiveFailures, 0);
      expect(l.status().allowed, isTrue);
    });
  });

  group('SafetyGate', () {
    test('默认是离线模式', () async {
      final g = SafetyGate(persistFile: File('${tmp.path}/g.json'));
      await g.load();
      expect(g.mode, ConnectionMode.offline);
      expect(g.hasValidConsent, isFalse);
    });

    test('确认条目不足时拒绝开启真实服务器', () async {
      final g = SafetyGate(persistFile: File('${tmp.path}/g2.json'));
      await g.load();
      expect(await g.enableRealServer(['我同意']), isNotNull);
      expect(g.mode, ConnectionMode.offline);
    });

    test('敷衍确认（缺关键词）被拒绝', () async {
      final g = SafetyGate(persistFile: File('${tmp.path}/g3.json'));
      await g.load();
      final lazy = List.filled(kRiskPoints.length, '我知道');
      expect(await g.enableRealServer(lazy), isNotNull);
    });

    test('完整确认后开启并持久化', () async {
      final f = File('${tmp.path}/g4.json');
      final g = SafetyGate(persistFile: f);
      await g.load();
      final ok = await g.enableRealServer([
        '可能被限制登录或封禁',
        '设备指纹 Qimei 会上报',
        '我不会伪造设备指纹、不绕过',
        '用专门注册的测试账号',
      ]);
      expect(ok, isNull);
      expect(g.isRealServer, isTrue);

      final g2 = SafetyGate(persistFile: f);
      await g2.load();
      expect(g2.isRealServer, isTrue);
      expect(g2.hasValidConsent, isTrue);
    });

    test('紧急切断回到离线', () async {
      final g = SafetyGate(persistFile: File('${tmp.path}/g5.json'));
      await g.load();
      await g.enableRealServer([
        '可能被限制登录或封禁',
        '设备指纹 Qimei 会上报',
        '我不会伪造设备指纹、不绕过',
        '用专门注册的测试账号',
      ]);
      await g.killSwitch();
      expect(g.isOffline, isTrue);
    });
  });

  group('RiskControl', () {
    test('返回码映射正确', () {
      expect(RiskControl.classify(0), RiskSignal.none);
      expect(RiskControl.classify(1), RiskSignal.captchaRequired);
      expect(RiskControl.classify(2), RiskSignal.smsRequired);
      expect(RiskControl.classify(40), RiskSignal.accountRestricted);
      expect(RiskControl.classify(43), RiskSignal.deviceLocked);
    });

    test('除无信号外一律要求中止（不存在自动重试路径）', () {
      for (final s in RiskSignal.values) {
        if (s == RiskSignal.none) continue;
        expect(RiskControl.mustAbort(s), isTrue, reason: '$s 应中止');
      }
    });

    test('处置建议不诱导继续尝试', () {
      expect(RiskControl.advice(RiskSignal.captchaRequired), contains('停止'));
      expect(RiskControl.advice(RiskSignal.accountRestricted), contains('官方'));
    });
  });
}
