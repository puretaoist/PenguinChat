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
import 'package:qqclient/kernel/safety/environment_probe.dart';
import 'package:qqclient/kernel/safety/safety_gate.dart';

/// 完整的风险确认内容（覆盖全部要点）。
const _fullAck = [
  '我理解，账号可能被限制登录或永久封禁',
  '我理解，设备指纹 Qimei 会被采集，登录失败会上报',
  '我理解，本客户端不会伪造设备指纹、不绕过验证码',
  '我理解，我会用专门注册的测试账号，不用主账号',
  '我理解，检测在 native 层，用户态隐藏不可靠，应在干净设备上操作',
];

EnvironmentReport _cleanEnv() =>
    EnvironmentReport(findings: const [], probedAt: DateTime.now());

EnvironmentReport _riskyEnv() => EnvironmentReport(
      findings: const [
        EnvFinding(
          id: 'magisk',
          label: 'Magisk 痕迹',
          severity: EnvRiskLevel.high,
          detail: '单元测试注入',
        ),
      ],
      probedAt: DateTime.now(),
    );

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

    test('未做环境检测时拒绝开启真实服务器', () async {
      final g = SafetyGate(persistFile: File('${tmp.path}/g0.json'));
      await g.load();
      final r = await g.enableRealServer(_fullAck);
      expect(r, isNotNull);
      expect(g.mode, ConnectionMode.offline);
    });

    test('环境高危时直接拒绝（不是警告）', () async {
      final g = SafetyGate(persistFile: File('${tmp.path}/g1.json'));
      await g.load();
      final r = await g.enableRealServer(_fullAck, environment: _riskyEnv());
      expect(r, isNotNull);
      expect(r, contains('干净设备'), reason: '正确做法是换设备而非隐藏环境');
      expect(r, contains('libfekit'), reason: '说明用户态隐藏对 native 检测无效');
      expect(g.mode, ConnectionMode.offline);
    });

    test('环境干净 + 完整确认 -> 开启', () async {
      final g = SafetyGate(persistFile: File('${tmp.path}/g2.json'));
      await g.load();
      expect(
          await g.enableRealServer(_fullAck, environment: _cleanEnv()), isNull);
      expect(g.isRealServer, isTrue);
    });

    test('确认条目不足时拒绝', () async {
      final g = SafetyGate(persistFile: File('${tmp.path}/g3.json'));
      await g.load();
      expect(
          await g.enableRealServer(['我同意'], environment: _cleanEnv()),
          isNotNull);
    });

    test('敷衍确认（缺关键词）被拒绝', () async {
      final g = SafetyGate(persistFile: File('${tmp.path}/g4.json'));
      await g.load();
      final lazy = List.filled(kRiskPoints.length, '我知道');
      expect(
          await g.enableRealServer(lazy, environment: _cleanEnv()), isNotNull);
    });

    test('开启后跨实例持久化', () async {
      final f = File('${tmp.path}/g5.json');
      final g1 = SafetyGate(persistFile: f);
      await g1.load();
      expect(
          await g1.enableRealServer(_fullAck, environment: _cleanEnv()), isNull);

      final g2 = SafetyGate(persistFile: f);
      await g2.load();
      expect(g2.isRealServer, isTrue);
      expect(g2.hasValidConsent, isTrue);
    });

    test('紧急切断回到离线', () async {
      final g = SafetyGate(persistFile: File('${tmp.path}/g6.json'));
      await g.load();
      await g.enableRealServer(_fullAck, environment: _cleanEnv());
      await g.killSwitch();
      expect(g.isOffline, isTrue);
    });
  });

  group('EnvironmentReport', () {
    test('无发现 -> clean 且不阻断', () {
      final r = _cleanEnv();
      expect(r.level, EnvRiskLevel.clean);
      expect(r.blocksRealServer, isFalse);
    });

    test('单项 high -> 阻断', () {
      expect(_riskyEnv().level, EnvRiskLevel.high);
      expect(_riskyEnv().blocksRealServer, isTrue);
    });

    test('两项 high -> critical', () {
      final r = EnvironmentReport(
        findings: const [
          EnvFinding(id: 'a', label: 'A', severity: EnvRiskLevel.high, detail: 'x'),
          EnvFinding(id: 'b', label: 'B', severity: EnvRiskLevel.high, detail: 'y'),
        ],
        probedAt: DateTime.now(),
      );
      expect(r.level, EnvRiskLevel.critical);
    });

    test('单项 medium 不阻断（给用户判断空间）', () {
      final r = EnvironmentReport(
        findings: const [
          EnvFinding(
              id: 'd', label: '可调试', severity: EnvRiskLevel.medium, detail: 'x'),
        ],
        probedAt: DateTime.now(),
      );
      expect(r.level, EnvRiskLevel.medium);
      expect(r.blocksRealServer, isFalse);
    });

    test('发现列表按严重度排序', () {
      expect(_riskyEnv().sortedFindings.first.severity, EnvRiskLevel.high);
    });

    test('真实探针可运行且如实列出局限', () async {
      final rep =
          await EnvironmentProbe(perCheckTimeout: const Duration(milliseconds: 500))
              .probe();
      expect(rep.undetectable, isNotEmpty);
      expect(
        rep.undetectable.any((u) => u.contains('maps')),
        isTrue,
        reason: 'libfekit 读 /proc/self/maps 的深度检测需 native，必须如实说明',
      );
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
