/// L2 安全防护：连接模式闸门与知情同意
///
/// ## 设计立场
///
/// 本模块**不提供任何规避风控的能力**——不做设备指纹伪造、不绕验证码、
/// 不伪装成官方客户端。那些做法属于规避安全措施，且会让账号更快被标记。
///
/// 本模块要解决的问题是另一个：**避免「无心之失」造成不可逆后果**。
/// 一个把真实账号连上去的实验性客户端，最容易出事的场景是：
///
///   - 默认就连生产环境，用户没意识到自己在操作真实账号
///   - 程序内部自动重试，把失败次数刷上去
///   - 出错后继续跑，反复触发风控
///
/// 因此设计为：**默认离线** + **连接真实服务器需显式同意** + **随时可切断**。
///
/// ## 三层模式
///
/// | 模式 | 行为 | 风险 |
/// |---|---|---|
/// | [ConnectionMode.offline] | 不联网，UI 用内置样例数据 | 无 |
/// | [ConnectionMode.loopback] | 内存回环，可完整跑通逻辑 | 无 |
/// | [ConnectionMode.realServer] | 连腾讯生产服务器 | **有，且不可完全消除** |
///
/// 前两层足以完成绝大部分开发与演示；第三层只在明确需要时启用。
library;

import 'dart:convert';
import 'dart:io';

import 'environment_probe.dart';

/// 连接模式。
enum ConnectionMode {
  /// 完全离线：不发起任何网络请求。
  offline,

  /// 内存回环：协议链路完整可跑，但不触网。
  loopback,

  /// 真实服务器：⚠️ 会操作真实账号。
  realServer,
}

/// 同意记录。
class ConsentRecord {
  final DateTime at;
  final String statementVersion;
  final String acknowledgedRisk;

  const ConsentRecord({
    required this.at,
    required this.statementVersion,
    required this.acknowledgedRisk,
  });

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'v': statementVersion,
        'ack': acknowledgedRisk,
      };

  static ConsentRecord fromJson(Map<String, dynamic> j) => ConsentRecord(
        at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
        statementVersion: j['v'] as String? ?? '',
        acknowledgedRisk: j['ack'] as String? ?? '',
      );
}

/// 知情同意声明。版本变更时旧同意失效，需重新确认。
///
/// 措辞刻意具体，不使用「我已阅读并同意」这类空泛表述——
/// 用户必须复述自己理解到的具体风险。
const String kConsentVersion = '2026-09-10.1';

/// 用户必须明确复述的风险要点（界面应逐条勾选，不接受一键同意）。
const List<String> kRiskPoints = [
  '我理解：使用非官方客户端连接腾讯服务器，违反《QQ 用户协议》，'
      '账号可能被限制登录或永久封禁。',
  '我理解：腾讯会采集设备指纹（Qimei），并将每次登录失败与设备指纹'
      '一起上报；失败次数本身就会触发风控。',
  '我理解：本客户端不会伪造设备指纹、不绕过验证码与设备锁，'
      '因此它的行为特征与官方客户端不同，更容易被识别。',
  '我理解：我不会用主账号测试。若账号对我重要，我应使用专门注册的'
      '测试账号，并接受该账号可能损失的全部后果。',
  '我理解：腾讯的安全 SDK（libfekit）在 native 层检测 root / hook 框架，'
      '用户态隐藏已被证明不可靠；我应在环境干净的设备上操作，'
      '而不是指望把环境藏起来。',
];

/// 连接模式闸门。
class SafetyGate {
  final File? persistFile;

  ConnectionMode _mode = ConnectionMode.offline;
  ConsentRecord? _consent;

  SafetyGate({this.persistFile});

  ConnectionMode get mode => _mode;

  /// 默认是离线模式 —— 这是刻意的默认值。
  bool get isOffline => _mode == ConnectionMode.offline;
  bool get isRealServer => _mode == ConnectionMode.realServer;

  /// 是否已就当前声明版本取得有效同意。
  bool get hasValidConsent => _consent?.statementVersion == kConsentVersion;

  Future<void> load() async {
    final f = persistFile;
    if (f == null || !await f.exists()) return;
    try {
      final raw = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _mode = ConnectionMode.values.firstWhere(
        (m) => m.name == raw['mode'],
        orElse: () => ConnectionMode.offline,
      );
      final c = raw['consent'];
      _consent = c == null
          ? null
          : ConsentRecord.fromJson(c as Map<String, dynamic>);
      // 模式可以持久化，但「真实服务器」必须先过同意检查
      if (_mode == ConnectionMode.realServer && !hasValidConsent) {
        _mode = ConnectionMode.loopback;
      }
    } on FormatException {
      _mode = ConnectionMode.offline;
      _consent = null;
    }
  }

  Future<void> _save() async {
    final f = persistFile;
    if (f == null) return;
    await f.parent.create(recursive: true);
    await f.writeAsString(
      jsonEncode({
        'mode': _mode.name,
        'consent': _consent?.toJson(),
      }),
      flush: true,
    );
  }

  /// 切到低风险模式（离线/回环），随时可用，无需同意。
  Future<void> setSafeMode(ConnectionMode mode) async {
    if (mode == ConnectionMode.realServer) {
      throw ArgumentError('切换真实服务器模式请用 enableRealServer()');
    }
    _mode = mode;
    await _save();
  }

  /// 启用真实服务器模式。
  ///
  /// 两道关：
  ///   1. **环境关**：设备环境高危时直接拒绝（不是警告）。
  ///      依据是「官方 QQ + 隐藏 root 仍被封」的反馈——
  ///      判定基准是设备环境本身，环境不干净时做什么补救都没用。
  ///   2. **同意关**：必须逐条复述 [kRiskPoints] 的全部要点。
  ///
  /// [acknowledged] 必须是用户逐条确认后的复述内容。
  /// [environment] 为环境探测报告；为 null 表示未探测（会拒绝，要求先探测）。
  ///
  /// 返回 null 表示成功；非 null 为失败原因。
  Future<String?> enableRealServer(
    List<String> acknowledged, {
    EnvironmentReport? environment,
  }) async {
    // ---- 第一道关：环境 ----
    if (environment == null) {
      return '必须先完成环境检测（EnvironmentProbe.probe）';
    }
    _lastEnvironment = environment;
    if (environment.blocksRealServer) {
      final worst = environment.sortedFindings
          .where((f) => f.severity.blocksRealServer)
          .map((f) => f.label)
          .take(3)
          .join('、');
      return '设备环境风险等级「${environment.level.label}」，已拒绝开启'
          '（命中：$worst）。\n\n'
          '注意：正确做法不是在这样一台设备上隐藏环境，而是换一台干净设备。'
          '用户态隐藏对 native 层检测（libfekit 读 /proc/self/maps）无效，'
          '且「藏了但藏不干净」的状态反而更可疑。';
    }

    // ---- 第二道关：知情同意 ----
    if (acknowledged.length < kRiskPoints.length) {
      return '必须逐条确认全部 ${kRiskPoints.length} 项风险';
    }

    // 关键词匹配：确保不是随手点过
    const requiredKeywords = [
      ['封禁', '限制登录'],
      ['设备指纹', 'Qimei', 'qimei'],
      ['伪造', '绕过'],
      ['测试账号', '专门注册'],
      ['native', 'libfekit', '隐藏', '干净设备'],
    ];
    final joined = acknowledged.join(' ');
    for (final group in requiredKeywords) {
      if (!group.any(joined.contains)) {
        return '确认内容缺少要点：${group.first}';
      }
    }

    _consent = ConsentRecord(
      at: DateTime.now(),
      statementVersion: kConsentVersion,
      acknowledgedRisk: acknowledged.join(' | '),
    );
    _mode = ConnectionMode.realServer;
    await _save();
    return null;
  }

  EnvironmentReport? _lastEnvironment;

  /// 最近一次用于开启判定的环境报告。
  EnvironmentReport? get lastEnvironment => _lastEnvironment;

  /// 立即切断：回到离线模式。
  Future<void> killSwitch() async {
    _mode = ConnectionMode.offline;
    await _save();
  }

  /// 撤销同意（同时回到离线）。
  Future<void> revokeConsent() async {
    _consent = null;
    _mode = ConnectionMode.offline;
    await _save();
  }

  ConsentRecord? get consent => _consent;

  /// 供界面展示的当前状态摘要。
  String describe() {
    switch (_mode) {
      case ConnectionMode.offline:
        return '离线模式 —— 不发起任何网络请求';
      case ConnectionMode.loopback:
        return '回环模式 —— 逻辑可完整跑通，不触网';
      case ConnectionMode.realServer:
        return '⚠️ 真实服务器模式 —— 正在操作真实账号'
            '${hasValidConsent ? '' : '（同意已失效，将在下次连接时降级）'}';
    }
  }
}

/// 从服务端返回识别出的风控信号。
enum RiskSignal {
  none,

  /// 需要短信验证 —— 正常流程，但频繁触发会累积风险
  smsRequired,

  /// 需要图形/网关验证码 —— 通常是频率异常的强信号
  captchaRequired,

  /// 需要新设备鉴权
  newDeviceAuth,

  /// 账号被限制登录
  accountRestricted,

  /// 设备被锁定
  deviceLocked,

  /// 未知的拒绝
  unknownRejection,
}

/// 风控信号判定。
///
/// ⚠️ 本类只做**识别与停止**，不做任何绕过。
/// 识别到信号的正确反应是立即中止并告知用户，
/// 而不是换参数重试——重试只会加重标记。
class RiskControl {
  RiskControl._();

  /// 从服务端返回码判定信号。
  ///
  /// 返回码取值参考公开的 QQ 协议研究与本项目反编译结果。
  static RiskSignal classify(int resultCode) {
    switch (resultCode) {
      case 0:
        return RiskSignal.none;
      case 1:
        return RiskSignal.captchaRequired;
      case 2:
        return RiskSignal.smsRequired;
      case 40:
      case 41:
        return RiskSignal.accountRestricted;
      case 43:
        return RiskSignal.deviceLocked;
      default:
        return RiskSignal.unknownRejection;
    }
  }

  /// 该信号是否应导致**立即中止**（不允许自动重试）。
  ///
  /// 除「无信号」外全部为 true。这是刻意的保守设计：
  /// 任何形式的拒绝都在告诉我们「不要再试了」。
  static bool mustAbort(RiskSignal s) => s != RiskSignal.none;

  /// 是否需要用户介入（而非程序自己处理）。
  static bool needsHumanAction(RiskSignal s) {
    switch (s) {
      case RiskSignal.smsRequired:
      case RiskSignal.captchaRequired:
      case RiskSignal.newDeviceAuth:
      case RiskSignal.accountRestricted:
      case RiskSignal.deviceLocked:
        return true;
      case RiskSignal.none:
      case RiskSignal.unknownRejection:
        return false;
    }
  }

  /// 给用户看的处置建议（措辞要求：不诱导继续尝试）。
  static String advice(RiskSignal s) {
    switch (s) {
      case RiskSignal.none:
        return '正常。';
      case RiskSignal.smsRequired:
        return '服务端要求短信验证。若你使用的是重要账号，建议停止尝试，'
            '改用官方客户端完成验证。';
      case RiskSignal.captchaRequired:
        return '服务端要求图形验证码。这通常意味着请求频率已被判定异常。'
            '强烈建议立即停止，等待数小时后再考虑。';
      case RiskSignal.newDeviceAuth:
        return '服务端将本设备识别为新设备，要求额外鉴权。'
            '这是正常的保护机制，不代表账号异常，但请勿反复触发。';
      case RiskSignal.accountRestricted:
        return '账号可能已被限制登录。请立即停止所有自动尝试，'
            '用官方客户端确认账号状态；若确已被限制，需走官方申诉流程。';
      case RiskSignal.deviceLocked:
        return '设备已被锁定。需通过 QQ 安全中心解锁，本客户端无法也不应绕过。';
      case RiskSignal.unknownRejection:
        return '服务端返回了未识别的拒绝。在弄清原因前不要重试——'
            '盲目重试会累积失败上报。';
    }
  }
}
