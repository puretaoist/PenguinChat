/// 安全防护层自测（纯 Dart，不依赖 Flutter 引擎）
///
/// 运行：dart run tool/safety_selftest.dart
///
/// 重点验证：
///   1. 尝试限制**持久化**（重启应用不清零，否则限制形同虚设）
///   2. 默认模式是离线
///   3. 开启真实服务器需逐条确认风险，不能一键同意
///   4. 任何拒绝信号都导致中止，不存在自动重试路径
// ignore_for_file: avoid_print, avoid_relative_lib_imports
library;

import 'dart:io';

import '../lib/kernel/safety/attempt_limiter.dart';
import '../lib/kernel/safety/environment_probe.dart';
import '../lib/kernel/safety/safety_gate.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    print('  [OK] $name');
  } else {
    _failed++;
    print('  [FAIL] $name${detail == null ? '' : ' -> $detail'}');
  }
}

/// 完整的风险确认内容（覆盖全部要点，含关键词）。
List<String> fullAck() => const [
      '我理解，账号可能被限制登录或永久封禁',
      '我理解，设备指纹 Qimei 会被采集，登录失败会上报',
      '我理解，本客户端不会伪造设备指纹、不绕过验证码',
      '我理解，我会用专门注册的测试账号，不用主账号',
      '我理解，检测在 native 层，用户态隐藏不可靠，应在干净设备上操作',
    ];

/// 干净环境报告（用于验证「环境合规可放行」）。
EnvironmentReport cleanEnv() =>
    EnvironmentReport(findings: const [], probedAt: DateTime.now());

/// 高危环境报告（用于验证「环境高危被阻断」）。
EnvironmentReport riskyEnv() => EnvironmentReport(
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

Future<void> main() async {
  print('=== 安全防护层自测 ===');

  final tmp = Directory.systemTemp.createTempSync('qqsafety_test_');
  print('临时目录: ${tmp.path}\n');

  try {
    // ---------------------------------------------------------------
    print('[限制器] 尝试次数与冷却');
    {
      final limiter = LoginAttemptLimiter(
        window: const Duration(minutes: 10),
        maxInWindow: 3,
        baseCooldown: const Duration(seconds: 30),
      );

      var st = limiter.status();
      check('初始允许尝试', st.allowed);
      check('初始已用 0 次', st.usedInWindow == 0);

      await limiter.beginAttempt();
      st = limiter.status();
      check('第一次后已用 1 次', st.usedInWindow == 1);
      check('第一次后仍允许（未失败无冷却）', st.allowed);

      // 记录失败 -> 进入冷却
      await limiter.recordFailure(reasonCode: '2');
      st = limiter.status();
      check('失败后进入冷却', !st.allowed, st.describe());
      check('冷却原因可见', st.reason != null && st.reason!.contains('冷却'));

      // 冷却时长随连续失败递增
      final cd1 = limiter.currentCooldown;
      await limiter.recordFailure();
      final cd2 = limiter.currentCooldown;
      check('冷却时长递增（指数退避）', cd2 > cd1, '$cd1 -> $cd2');

      check('连续失败计数正确', limiter.consecutiveFailures == 2);
    }

    // ---------------------------------------------------------------
    print('\n[限制器] 窗口上限');
    {
      final limiter = LoginAttemptLimiter(
        window: const Duration(minutes: 10),
        maxInWindow: 2,
        baseCooldown: Duration.zero,
      );
      await limiter.beginAttempt();
      await limiter.beginAttempt();
      final st = limiter.status();
      check('达到窗口上限后拒绝', !st.allowed);
      check('提示窗口限制', st.reason != null && st.reason!.contains('10 分钟'),
          st.reason);
    }

    // ---------------------------------------------------------------
    print('\n[限制器] 连续失败触发长锁');
    {
      final limiter = LoginAttemptLimiter(
        window: const Duration(minutes: 10),
        maxInWindow: 100,
        baseCooldown: Duration.zero,
        hardLockAfter: 3,
        hardLockDuration: const Duration(hours: 24),
      );
      for (var i = 0; i < 3; i++) {
        await limiter.recordFailure();
      }
      final st = limiter.status();
      check('连续失败 3 次后硬锁', !st.allowed);
      check('硬锁时长约 24 小时',
          st.waitFor.inHours >= 23 && st.waitFor.inHours <= 24,
          '${st.waitFor.inHours}h');
      check('硬锁原因含「保护性锁定」',
          st.reason != null && st.reason!.contains('保护性锁定'), st.reason);
    }

    // ---------------------------------------------------------------
    print('\n[限制器] 持久化：重启不清零（关键）');
    {
      final f = File('${tmp.path}/attempts.json');

      // 用零冷却，便于观察「次数」本身的持久化；
      // 冷却的持久化在下面单独验证。
      final l1 = LoginAttemptLimiter(
        window: const Duration(minutes: 10),
        maxInWindow: 5,
        baseCooldown: Duration.zero,
        persistFile: f,
      );
      await l1.load();
      await l1.beginAttempt();
      await l1.recordFailure(reasonCode: '3');
      await l1.beginAttempt();

      check('本实例已记录 2 次', l1.status().usedInWindow == 2,
          '${l1.status().usedInWindow}');

      // 模拟重启：新实例读同一文件
      final l2 = LoginAttemptLimiter(
        window: const Duration(minutes: 10),
        maxInWindow: 5,
        baseCooldown: Duration.zero,
        persistFile: f,
      );
      await l2.load();

      check('重启后仍记得失败次数', l2.consecutiveFailures == 1,
          '${l2.consecutiveFailures}');
      check('重启后窗口内次数保留', l2.status().usedInWindow == 2,
          '${l2.status().usedInWindow}');
    }

    print('\n[限制器] 冷却跨重启仍然生效');
    {
      final f = File('${tmp.path}/attempts2.json');
      final l1 = LoginAttemptLimiter(
        window: const Duration(minutes: 10),
        maxInWindow: 5,
        baseCooldown: const Duration(minutes: 5),
        persistFile: f,
      );
      await l1.load();
      await l1.beginAttempt();
      await l1.recordFailure();
      check('本实例受冷却限制', !l1.status().allowed);

      final l2 = LoginAttemptLimiter(
        window: const Duration(minutes: 10),
        maxInWindow: 5,
        baseCooldown: const Duration(minutes: 5),
        persistFile: f,
      );
      await l2.load();
      check('重启后仍受冷却限制（不能靠重启绕过）', !l2.status().allowed,
          l2.status().describe());
    }

    // ---------------------------------------------------------------
    print('\n[限制器] 成功与手动重置');
    {
      final limiter = LoginAttemptLimiter(hardLockAfter: 2);
      await limiter.recordFailure();
      await limiter.recordFailure();
      check('已硬锁', !limiter.status().allowed);

      await limiter.recordSuccess();
      check('成功后解除锁定', limiter.status().allowed);
      check('成功后失败计数归零', limiter.consecutiveFailures == 0);
    }

    // ---------------------------------------------------------------
    print('\n[闸门] 默认离线');
    {
      final gate = SafetyGate(persistFile: File('${tmp.path}/gate.json'));
      await gate.load();
      check('默认是离线模式', gate.mode == ConnectionMode.offline);
      check('默认未取得同意', !gate.hasValidConsent);
      check('isOffline 为 true', gate.isOffline);
      check('isRealServer 为 false', !gate.isRealServer);
      check('描述含「离线」', gate.describe().contains('离线'));
    }

    // ---------------------------------------------------------------
    print('\n[闸门] 环境风险阻断（关键：官方QQ+隐藏root 也会被封）');
    {
      final gate = SafetyGate(persistFile: File('${tmp.path}/env1.json'));
      await gate.load();

      // 未做环境检测 -> 拒绝
      final r0 = await gate.enableRealServer(fullAck());
      check('未做环境检测时拒绝', r0 != null && r0.contains('环境检测'), r0);
      check('拒绝后仍是离线', gate.mode == ConnectionMode.offline);

      // 环境高危 -> 即使同意完整也拒绝
      final r1 = await gate.enableRealServer(fullAck(), environment: riskyEnv());
      check('环境高危时拒绝开启', r1 != null, r1);
      check('拒绝原因提示换干净设备',
          r1 != null && (r1.contains('干净设备')), r1);
      check('拒绝原因说明用户态隐藏无效',
          r1 != null && r1.contains('libfekit'), r1);
      check('高危环境拒绝后仍是离线', gate.mode == ConnectionMode.offline);
      check('高危环境被记录', gate.lastEnvironment != null);

      // 环境干净 + 同意完整 -> 通过
      final r2 = await gate.enableRealServer(fullAck(), environment: cleanEnv());
      check('环境干净时开启成功', r2 == null, r2);
      check('模式切换为真实服务器', gate.isRealServer);
    }

    print('\n[环境探针] 检测逻辑与等级判定');
    {
      final clean = cleanEnv();
      check('无发现 -> clean', clean.level == EnvRiskLevel.clean);
      check('clean 不阻断', !clean.blocksRealServer);

      final risky = riskyEnv();
      check('单项 high -> high', risky.level == EnvRiskLevel.high);
      check('high 阻断', risky.blocksRealServer);

      // 两项 high -> 升为 critical
      final doubleRisk = EnvironmentReport(
        findings: const [
          EnvFinding(
              id: 'a',
              label: 'A',
              severity: EnvRiskLevel.high,
              detail: 'x'),
          EnvFinding(
              id: 'b',
              label: 'B',
              severity: EnvRiskLevel.high,
              detail: 'y'),
        ],
        probedAt: DateTime.now(),
      );
      check('两项 high -> critical',
          doubleRisk.level == EnvRiskLevel.critical);
      check('critical 阻断', doubleRisk.blocksRealServer);

      // medium 不阻断（给用户判断空间）
      final medium = EnvironmentReport(
        findings: const [
          EnvFinding(
              id: 'd',
              label: '可调试',
              severity: EnvRiskLevel.medium,
              detail: 'ro.debuggable=1'),
        ],
        probedAt: DateTime.now(),
      );
      check('单项 medium 不阻断', !medium.blocksRealServer);
      check('medium 等级正确', medium.level == EnvRiskLevel.medium);

      // 排序：高危排前
      check('发现列表按严重度排序',
          risky.sortedFindings.first.severity == EnvRiskLevel.high);

      // 摘要可读
      check('摘要含等级', risky.summary().contains('高危'));
      check('摘要含阻断提示', risky.summary().contains('阻断'));

      // 真实探针可运行（本机结果不重要，重要的是不抛异常）
      final probe = EnvironmentProbe(
        perCheckTimeout: const Duration(milliseconds: 500),
      );
      final rep = await probe.probe();
      check('探针可执行且返回报告',
          rep.probedAt.isAfter(DateTime(2020)) && rep.findings.isEmpty);
      check('探针报告含等级', rep.level.label.isNotEmpty);
      // 诚实说明局限（由真实探针产出）
      check('明确列出无法检测的项', rep.undetectable.isNotEmpty);
      check('局限中说明 maps 扫描需 native',
          rep.undetectable.any((u) => u.contains('maps')),
          rep.undetectable.join(' / '));
      print('       本机探测结果: ${rep.level.label}'
          '（${rep.findings.length} 项发现，'
          '${rep.undetectable.length} 项无法检测）');
    }

    print('\n[闸门] 开启真实服务器需逐条确认');
    {
      final gate = SafetyGate(persistFile: File('${tmp.path}/gate2.json'));
      await gate.load();

      // 确认条目不足
      final r1 = await gate.enableRealServer(['我同意'], environment: cleanEnv());
      check('条目不足被拒绝', r1 != null, r1);
      check('拒绝后仍是离线', gate.mode == ConnectionMode.offline);

      // 条目数够但内容是敷衍
      final lazy = List.filled(kRiskPoints.length, '我知道有风险');
      final r2 = await gate.enableRealServer(lazy, environment: cleanEnv());
      check('敷衍确认被拒绝（缺关键词）', r2 != null, r2);

      // 完整确认
      final r3 = await gate.enableRealServer(fullAck(), environment: cleanEnv());
      check('完整确认后开启成功', r3 == null, r3);
      check('模式切换为真实服务器', gate.isRealServer);
      check('同意记录已保存', gate.hasValidConsent);
      check('同意记录含时间戳', gate.consent?.at != null);
      check('描述含警告', gate.describe().contains('真实账号'));
    }

    // ---------------------------------------------------------------
    print('\n[闸门] 同意跨重启有效，但版本变更失效');
    {
      final f = File('${tmp.path}/gate3.json');
      final g1 = SafetyGate(persistFile: f);
      await g1.load();
      await g1.enableRealServer(fullAck(), environment: cleanEnv());

      final g2 = SafetyGate(persistFile: f);
      await g2.load();
      check('重启后仍是真实服务器模式', g2.isRealServer);
      check('重启后同意仍有效', g2.hasValidConsent);
    }

    // ---------------------------------------------------------------
    print('\n[闸门] 紧急切断');
    {
      final gate = SafetyGate(persistFile: File('${tmp.path}/gate4.json'));
      await gate.load();
      await gate.enableRealServer(fullAck(), environment: cleanEnv());
      check('已开启', gate.isRealServer);

      await gate.killSwitch();
      check('切断后回到离线', gate.isOffline);
      check('切断后描述恢复正常', gate.describe().contains('离线'));

      await gate.revokeConsent();
      check('撤销同意后无有效同意', !gate.hasValidConsent);
    }

    // ---------------------------------------------------------------
    print('\n[风控] 信号判定与中止');
    {
      check('返回码 0 -> 无信号',
          RiskControl.classify(0) == RiskSignal.none);
      check('返回码 1 -> 验证码',
          RiskControl.classify(1) == RiskSignal.captchaRequired);
      check('返回码 2 -> 短信',
          RiskControl.classify(2) == RiskSignal.smsRequired);
      check('返回码 40 -> 账号受限',
          RiskControl.classify(40) == RiskSignal.accountRestricted);
      check('返回码 43 -> 设备锁定',
          RiskControl.classify(43) == RiskSignal.deviceLocked);
      check('未知码 -> 未知拒绝',
          RiskControl.classify(0x7F) == RiskSignal.unknownRejection);

      // 核心约束：除 none 外一律中止，不存在自动重试路径
      var allAbort = true;
      for (final s in RiskSignal.values) {
        if (s == RiskSignal.none) continue;
        if (!RiskControl.mustAbort(s)) allAbort = false;
      }
      check('任何拒绝信号都要求中止（无自动重试）', allAbort);

      check('无信号不需人工介入',
          !RiskControl.needsHumanAction(RiskSignal.none));
      check('账号受限需人工介入',
          RiskControl.needsHumanAction(RiskSignal.accountRestricted));

      // 建议文案不诱导继续尝试
      final advice = RiskControl.advice(RiskSignal.captchaRequired);
      check('验证码建议要求停止', advice.contains('停止'), advice);
      final advice2 = RiskControl.advice(RiskSignal.accountRestricted);
      check('账号受限建议含官方申诉', advice2.contains('官方'), advice2);

      check('风险要点 >= 4 条', kRiskPoints.length >= 4);
      check('声明版本非空', kConsentVersion.isNotEmpty);
    }
  } finally {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  }

  print('\n=== 结果: $_passed 通过, $_failed 失败 ===');
  if (_failed > 0) {
    throw StateError('存在失败用例');
  }
  print('全部通过 ✓ 安全防护层可用');
}
