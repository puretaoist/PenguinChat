/// 设备维度的登录节流。
///
/// ## 为什么需要这一层（2026-11-08，图灵盾逆向 + 真机证据）
///
/// 现有的 [LoginAttemptLimiter] 只管「**同一账号**短时间多次尝试」。
/// 但真正被服务端聚合看的是**设备维度**：
///
/// 1. 图灵盾（`com.tencent.turingfd.sdk.xq`）的持久化类 `b2.java` 里，
///    键 `402` 存的是 **30 条时间戳**（`b2.b(context)` 按 `_` 切开逐条解析）。
///    这是「这台设备多久活动一次」的行为画像，**跨进程持久化、加密保存**
///    （`SharedPreferences("turingfd_conf_" + 版本 + "_xq")`）。
/// 2. 我方真机日志实测（8 天）：**196 次登录 / 253 次断线重连**，
///    同一台设备登过 `2089495846` / `3499239040` /
///    测试号等多个账号。
/// 3. 结果：账号被渐进收权（加群 → 搜索 → 发消息 → 实名认证）。
///
/// 所以「单号节流」不够，必须再有一层「**这台设备**今天登了几个号、登了几次」。
///
/// ## 规则（都对齐「人类操作」的合理上限，不是拍脑袋）
///
/// | 规则 | 默认值 | 依据 |
/// |---|---|---|
/// | 24h 内不同账号数 | ≤ 3 | 正常人一台手机 1~2 个号 |
/// | 24h 内总登录次数 | ≤ 20 | 真机 8 天 196 次 = 日均 24.5，太多 |
/// | 换号最小间隔 | ≥ 10 分钟 | 人类不会 10 分钟内切号重登 |
///
/// ## 与 [LoginAttemptLimiter] 的分工
///
/// - 本类**不拒绝**登录，只给出「现在该不该发这个包」的判定；
///   拒绝的语义由调用方决定（我方选择：不发包 + 告知用户等待）。
/// - 本类记录的是**成功发出**的登录（`record` 由调用方在发包前调），
///   不像 attempt_limiter 那样记失败——因为这里要防的是「频率」，
///   不是「连续失败」。
///
/// ## 分层
///
/// 纯 Dart（L2），不 import Flutter；落盘文件由调用方注入（同 attempt_limiter）。
library;

import 'dart:convert';
import 'dart:io';

/// 一次登录记录。
class DeviceLoginRecord {
  const DeviceLoginRecord({required this.uin, required this.atMs});

  final int uin;
  final int atMs;

  Map<String, Object?> toJson() => <String, Object?>{'uin': uin, 'at': atMs};

  static DeviceLoginRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final uin = raw['uin'];
    final at = raw['at'];
    if (uin is! num || at is! num) return null;
    return DeviceLoginRecord(uin: uin.toInt(), atMs: at.toInt());
  }
}

/// 判定结果。
enum DeviceLoginVerdict {
  /// 放行。
  allow,

  /// 需要等待（换号太频繁）。[DeviceLoginDecision.waitFor] 给出建议时长。
  wait,

  /// 拒绝（今天这台设备登过的号太多 / 次数太多）。
  block,
}

class DeviceLoginDecision {
  const DeviceLoginDecision(this.verdict, {this.reason = '', this.waitFor});

  final DeviceLoginVerdict verdict;

  /// 给人看的原因（写日志 / 提示用户）。
  final String reason;

  /// 需要等待多久（仅 [DeviceLoginVerdict.wait] 时有值）。
  final Duration? waitFor;

  bool get allowed => verdict == DeviceLoginVerdict.allow;

  @override
  String toString() => 'DeviceLoginDecision(${verdict.name}, $reason)';
}

/// 设备维度的登录节流器。
class DeviceLoginGuard {
  /// 24 小时内允许登录的**不同账号**数上限。
  final int maxDistinctUinsPerDay;

  /// 24 小时内允许的**登录总次数**上限。
  final int maxLoginsPerDay;

  /// 换号（不同 uin 相继登录）之间的最小间隔。
  final Duration minSwitchInterval;

  /// 统计窗口。
  final Duration window;

  /// 持久化文件（null 则只在内存中记录）。
  final File? persistFile;

  List<DeviceLoginRecord> _records;

  DeviceLoginGuard({
    this.maxDistinctUinsPerDay = 3,
    this.maxLoginsPerDay = 20,
    this.minSwitchInterval = const Duration(minutes: 10),
    this.window = const Duration(hours: 24),
    this.persistFile,
    List<DeviceLoginRecord>? seed,
  }) : _records = <DeviceLoginRecord>[...?seed];

  /// 规范落盘位置：与 `qqclient-attempts.json` **同目录**（日志目录的父目录）。
  ///
  /// 为什么要和它同目录：两者都是「这台设备的行为账本」，
  /// 放在一起便于人工核对，也避免某个工具只清其中一个。
  static File defaultFileFor(Directory logDir) => File(
    '${logDir.parent.path}${Platform.pathSeparator}device-login-guard.json',
  );

  /// 从磁盘加载。
  Future<void> load() async {
    final f = persistFile;
    if (f == null || !await f.exists()) return;
    try {
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return;
      final list = raw['records'];
      if (list is List) {
        _records = <DeviceLoginRecord>[
          for (final e in list) ?DeviceLoginRecord.fromJson(e),
        ];
      }
    } on Object {
      // 读坏了按空处理：这是「防频率」的账本，不是凭据，坏了不能阻断启动。
    }
  }

  /// 剪掉窗口外的记录（顺手落盘）。
  void _prune(DateTime now) {
    final cutoff = now.subtract(window).millisecondsSinceEpoch;
    _records.removeWhere((r) => r.atMs < cutoff);
  }

  /// 判定「现在能不能为 [uin] 发一个登录包」。
  ///
  /// 顺序：先看「换号间隔」（最贴近人类直觉的一条），再看两个上限。
  /// 不修改状态——真正的记账在 [record]。
  DeviceLoginDecision check({required int uin, DateTime? now}) {
    final t = now ?? DateTime.now();
    _prune(t);

    // 1) 换号间隔：如果上一条记录是**别的号**，且间隔小于阈值，就要等。
    if (_records.isNotEmpty) {
      final latest = _records.reduce((a, b) => a.atMs >= b.atMs ? a : b);
      if (latest.uin != uin) {
        final since = t.millisecondsSinceEpoch - latest.atMs;
        final need = minSwitchInterval.inMilliseconds;
        if (since < need) {
          final wait = Duration(milliseconds: need - since);
          return DeviceLoginDecision(
            DeviceLoginVerdict.wait,
            reason:
                '换号过于频繁（上次是别的账号，${since ~/ 1000}s 前；'
                '下限 ${minSwitchInterval.inMinutes} 分钟）',
            waitFor: wait,
          );
        }
      }
    }

    // 2) 同一天不同账号数上限。
    final distinct = _records.map((r) => r.uin).toSet();
    if (!distinct.contains(uin) &&
        distinct.length >= maxDistinctUinsPerDay) {
      return DeviceLoginDecision(
        DeviceLoginVerdict.block,
        reason:
            '这台设备 ${window.inHours}h 内已登录过 ${distinct.length} 个账号'
            '（上限 $maxDistinctUinsPerDay）。请换设备或明天再试',
      );
    }

    // 3) 总登录次数上限。
    if (_records.length >= maxLoginsPerDay) {
      return DeviceLoginDecision(
        DeviceLoginVerdict.block,
        reason:
            '这台设备 ${window.inHours}h 内已登录 ${_records.length} 次'
            '（上限 $maxLoginsPerDay）。频繁重登会被判为自动化行为',
      );
    }

    return const DeviceLoginDecision(DeviceLoginVerdict.allow);
  }

  /// 记一次登录（**在真正发包之前**调，与 check 配套）。
  Future<void> record({required int uin, DateTime? now}) async {
    final t = now ?? DateTime.now();
    _records.add(
      DeviceLoginRecord(uin: uin, atMs: t.millisecondsSinceEpoch),
    );
    _prune(t);
    await _save();
  }

  Future<void> _save() async {
    final f = persistFile;
    if (f == null) return;
    try {
      await f.writeAsString(
        jsonEncode(<String, Object?>{
          'records': <Object?>[for (final r in _records) r.toJson()],
        }),
        flush: true,
      );
    } on Object {
      // 落盘失败不影响判定（内存里这份仍然生效）。
    }
  }

  /// 诊断用：当前窗口内的记录（只读快照）。
  List<DeviceLoginRecord> get records =>
      List<DeviceLoginRecord>.unmodifiable(_records);
}
