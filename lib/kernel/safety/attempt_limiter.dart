/// L2 安全防护：登录尝试限制器
///
/// ## 为什么这是最重要的一道闸门
///
/// 反编译证据（目标 APK 9.3.60）：
/// ```
/// com/tencent/mobileqq/login/ntlogin/LoginFailedQimeiReporter
/// com/tencent/mobileqq/reportlog/api/impl/QimeiReportLoginFailServlet
/// com/tencent/mobileqq/reportlog/api/impl/QimeiReportLoginFailFileManager
/// ```
/// 腾讯有一条**专用链路**：每次登录失败都把失败事件与 **Qimei 设备指纹**
/// 一起上报（`LoginFailedQimeiReporter`），且会先落盘再补报
/// （`QimeiReportLoginFailFileManager`）。
///
/// 而 Qimei 在目标 APK 的 **24 个 dex** 中都出现，是跨业务共享的设备标识。
///
/// 结论：「同一设备短时间内多次登录失败」是一个**被明确采集并上报的信号**。
/// 因此限制尝试次数不是体验优化，而是防止账号被标记的关键手段。
///
/// ## 与「重试」的取舍
///
/// 普通应用的用户体验习惯是「失败就自动重试」。在这里这个习惯是有害的：
/// 每次自动重试都会产生一次带指纹的失败上报。
/// 因此本实现**禁止自动重试**，并且：
///   - 限制采用**持久化**记录（重启应用不清零，否则限制形同虚设）
///   - 失败后进入**递增冷却**，不是固定间隔
///   - 达到上限后**当天不再允许尝试**，需人工次日再试
library;

import 'dart:convert';
import 'dart:io';

/// 一次尝试记录。
class AttemptRecord {
  final DateTime at;
  final bool success;
  final String? reasonCode;

  /// 发起时写的占位记录：请求已发出、结果未知。
  ///
  /// 窗口限速要算它（确实打了一次服务器），但**连败计数不能算**——
  /// 中途崩溃/退出留下的悬空占位不是"这次尝试失败了"。
  final bool pending;

  const AttemptRecord({
    required this.at,
    required this.success,
    this.reasonCode,
    this.pending = false,
  });

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'ok': success,
        if (reasonCode != null) 'rc': reasonCode,
        if (pending) 'pending': true,
      };

  static AttemptRecord fromJson(Map<String, dynamic> j) => AttemptRecord(
        at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
        success: j['ok'] as bool? ?? false,
        reasonCode: j['rc'] as String?,
        pending: j['pending'] as bool? ?? false,
      );
}

/// 限制器状态，用于界面展示（必须让用户看见还剩几次）。
class AttemptStatus {
  /// 是否允许尝试
  final bool allowed;

  /// 窗口内已用次数
  final int usedInWindow;

  /// 窗口内上限
  final int maxInWindow;

  /// 还需等待多久
  final Duration waitFor;

  /// 拒绝原因（用于提示用户）
  final String? reason;

  const AttemptStatus({
    required this.allowed,
    required this.usedInWindow,
    required this.maxInWindow,
    required this.waitFor,
    this.reason,
  });

  String describe() {
    if (allowed) {
      return '可尝试（本次窗口已用 $usedInWindow/$maxInWindow）';
    }
    final s = waitFor.inSeconds;
    final human = s >= 3600
        ? '${(s / 3600).toStringAsFixed(1)} 小时'
        : s >= 60
            ? '${(s / 60).round()} 分钟'
            : '$s 秒';
    return '已锁定，需等待 $human${reason == null ? '' : '（$reason）'}';
  }
}

/// 登录尝试限制器。
///
/// 默认参数（保守，宁可让用户多等也不触发风控）：
///   - 10 分钟内最多 3 次
///   - 每失败一次，冷却时间翻倍（30s / 1min / 2min / 4min …）
///   - 连续失败 5 次后，锁定 24 小时
class LoginAttemptLimiter {
  /// 滑动窗口长度
  final Duration window;

  /// 窗口内最大尝试次数
  final int maxInWindow;

  /// 基础冷却
  final Duration baseCooldown;

  /// 冷却上限（避免指数增长到不可用）
  final Duration maxCooldown;

  /// 连续失败达到此次数 -> 长锁
  final int hardLockAfter;

  /// 长锁时长
  final Duration hardLockDuration;

  /// 持久化文件（null 则只在内存中记录）
  final File? persistFile;

  List<AttemptRecord> _records = [];
  int _consecutiveFailures = 0;
  DateTime? _hardLockUntil;

  /// 最后一次失败的时刻——冷却的计时基准。
  ///
  /// 单独存一份而不是从 [_records] 反推：`beginAttempt` 记的占位记录
  /// （成功前也是 `success: false`）会把"最后一条记录"顶到当下，
  /// 拿它计时就会把尝试自己挡在冷却里。
  DateTime? _lastFailureAt;

  LoginAttemptLimiter({
    this.window = const Duration(minutes: 10),
    this.maxInWindow = 3,
    this.baseCooldown = const Duration(seconds: 30),
    this.maxCooldown = const Duration(minutes: 8),
    this.hardLockAfter = 5,
    this.hardLockDuration = const Duration(hours: 24),
    this.persistFile,
  });

  /// 从磁盘加载历史记录。
  ///
  /// 持久化是必要的：如果重启应用就能清零，那限制形同虚设，
  /// 而「重启后继续猛试」正是最容易被风控捕捉的行为模式。
  Future<void> load() async {
    final f = persistFile;
    if (f == null || !await f.exists()) return;
    try {
      final raw = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _records = (raw['records'] as List<dynamic>? ?? [])
          .map((e) => AttemptRecord.fromJson(e as Map<String, dynamic>))
          .toList();
      _consecutiveFailures = raw['fails'] as int? ?? 0;
      final lock = raw['lockUntil'] as String?;
      _hardLockUntil = lock == null ? null : DateTime.tryParse(lock);
      final lastFail = raw['lastFailureAt'] as String?;
      _lastFailureAt = lastFail == null ? null : DateTime.tryParse(lastFail);
      // 老格式没有 lastFailureAt：从记录里回推最后一条失败的尝试
      // （占位记录与失败记录在旧格式里不可区分，取最后一条即可——
      //  旧格式下它要么是失败、要么是刚记下的那次，误差只在几十秒内）。
      if (_lastFailureAt == null && _consecutiveFailures > 0 && _records.isNotEmpty) {
        _lastFailureAt = _records.last.at;
      }
      // 「要求验证」不是失败：老数据里被按失败累计的那些（type=2 / type=204）
      // 在这里一次性重算掉。不这么做的话，正常走一次验证就被记一次失败，
      // 解两轮滑块就会被自己的保护逻辑锁 24 小时。
      if (_records.isNotEmpty) {
        final recomputed = _recomputeConsecutive();
        if (recomputed != _consecutiveFailures) {
          _consecutiveFailures = recomputed;
          if (_consecutiveFailures == 0) {
            _lastFailureAt = null;
            _hardLockUntil = null;
          } else {
            _lastFailureAt = _lastRealFailureAt() ?? _lastFailureAt;
          }
        }
      }
    } on FormatException {
      // 记录损坏就当没有，不阻塞启动
      _records = [];
      _consecutiveFailures = 0;
      _lastFailureAt = null;
    }
  }

  Future<void> _save() async {
    final f = persistFile;
    if (f == null) return;
    await f.parent.create(recursive: true);
    await f.writeAsString(
      jsonEncode({
        'records': _records.map((e) => e.toJson()).toList(),
        'fails': _consecutiveFailures,
        'lockUntil': _hardLockUntil?.toIso8601String(),
        'lastFailureAt': _lastFailureAt?.toIso8601String(),
      }),
      flush: true,
    );
  }

  /// 当前是否允许发起尝试，以及还需等多久。
  AttemptStatus status([DateTime? now]) {
    final t = now ?? DateTime.now();

    // 1. 硬锁
    if (_hardLockUntil != null && t.isBefore(_hardLockUntil!)) {
      return AttemptStatus(
        allowed: false,
        usedInWindow: _usedInWindow(t),
        maxInWindow: maxInWindow,
        waitFor: _hardLockUntil!.difference(t),
        reason: '连续失败 $_consecutiveFailures 次，已触发保护性锁定',
      );
    }

    // 2. 窗口内次数
    final used = _usedInWindow(t);
    if (used >= maxInWindow) {
      final oldest = _windowRecords(t).first.at;
      final until = oldest.add(window);
      return AttemptStatus(
        allowed: false,
        usedInWindow: used,
        maxInWindow: maxInWindow,
        waitFor: until.difference(t),
        reason: '${window.inMinutes} 分钟内尝试已达 $maxInWindow 次',
      );
    }

    // 3. 递增冷却——**从最后一次失败起算**。
    //
    // ⚠️ 不能拿"最后一条记录"当基准：beginAttempt 会先记一条占位记录，
    // 拿它当基准会把这次尝试自己挡在冷却里（2026-09-11 踩过：失败 79 分钟
    // 后的重试仍被要求"再等 29 秒"）。
    final cd = currentCooldown;
    final base = _lastFailureAt;
    if (cd > Duration.zero && base != null) {
      final until = base.add(cd);
      if (t.isBefore(until)) {
        return AttemptStatus(
          allowed: false,
          usedInWindow: used,
          maxInWindow: maxInWindow,
          waitFor: until.difference(t),
          reason: '冷却中（连续失败 $_consecutiveFailures 次）',
        );
      }
    }

    return AttemptStatus(
      allowed: true,
      usedInWindow: used,
      maxInWindow: maxInWindow,
      waitFor: Duration.zero,
    );
  }

  /// 当前冷却时长（随连续失败次数指数增长，有上限）。
  Duration get currentCooldown {
    if (_consecutiveFailures == 0) return Duration.zero;
    final exp = _consecutiveFailures - 1;
    final ms = baseCooldown.inMilliseconds * (1 << exp.clamp(0, 20));
    return ms >= maxCooldown.inMilliseconds
        ? maxCooldown
        : Duration(milliseconds: ms);
  }

  /// 「要求验证」的响应码：`type=2`（滑块/短信验证）、`type=204`（设备锁）。
  ///
  /// 这两类是**流程往前走了一步**，靠后续请求继续，不是"这次尝试废了"。
  /// 若按失败累计，解一次验证就记一次，五轮下来把自己锁 24 小时。
  static bool isProgressCode(String? rc) => rc == 'type=2' || rc == 'type=204';

  /// 从记录尾部重算连败次数：跳过"要求验证"与未定结果的占位记录，遇到成功即止。
  int _recomputeConsecutive() {
    var n = 0;
    for (final r in _records.reversed) {
      if (r.success) break;
      if (r.pending || isProgressCode(r.reasonCode)) continue;
      n++;
    }
    return n;
  }

  /// 最后一次"真失败"的时刻（冷却的计时基准）。
  DateTime? _lastRealFailureAt() {
    for (final r in _records.reversed) {
      if (r.success) break;
      if (r.pending || isProgressCode(r.reasonCode)) continue;
      return r.at;
    }
    return null;
  }

  /// 记录「服务端要求验证」：给占位记录补上返回码，但**不加连败、不延长冷却**
  /// （窗口限速仍然生效——一次验证往返照样占一个名额）。
  Future<void> recordProgress({String? reasonCode, DateTime? now}) async {
    if (_records.isEmpty) {
      _records.add(AttemptRecord(
        at: now ?? DateTime.now(),
        success: false,
        reasonCode: reasonCode,
      ));
    } else {
      final last = _records.removeLast();
      _records.add(AttemptRecord(
        at: last.at,
        success: last.success,
        reasonCode: reasonCode ?? last.reasonCode,
      ));
    }
    await _save();
  }

  List<AttemptRecord> _windowRecords(DateTime now) => _records
      .where((r) => now.difference(r.at) < window)
      .toList()
    ..sort((a, b) => a.at.compareTo(b.at));

  int _usedInWindow(DateTime now) => _windowRecords(now).length;

  /// 记录一次尝试（在发起请求前调用）。
  ///
  /// ⚠️ 必须先调用此方法再发请求。若先发请求再记录，用户在冷却期
  /// 内的点击会漏记，限制就失效了。
  ///
  /// 返回的是**预检结果**：记录了这条占位记录之后才放行，所以不能拿
  /// 记录后的状态再判一次（那会把这次尝试自己挡下来）。
  Future<AttemptStatus> beginAttempt({DateTime? now}) async {
    final st = status(now);
    if (!st.allowed) return st;
    _records.add(
        AttemptRecord(at: now ?? DateTime.now(), success: false, pending: true));
    await _save();
    return st;
  }

  /// 记录失败（带服务端返回码，便于事后分析）。
  Future<void> recordFailure({String? reasonCode, DateTime? now}) async {
    _consecutiveFailures++;
    final t = now ?? DateTime.now();
    _lastFailureAt = t;
    if (_records.isEmpty) {
      _records.add(AttemptRecord(at: t, success: false, reasonCode: reasonCode));
    } else {
      final last = _records.removeLast();
      _records.add(AttemptRecord(
        at: last.at,
        success: false,
        reasonCode: reasonCode ?? last.reasonCode,
      ));
    }

    if (_consecutiveFailures >= hardLockAfter) {
      _hardLockUntil = t.add(hardLockDuration);
    }
    await _save();
  }

  /// 记录成功（清零连续失败计数）。
  ///
  /// 与 [recordFailure] 对称：**改标记而不是再记一条**，否则一次尝试会在
  /// 窗口里占两条（成功那次腾出的一条名额被凭空吃掉）。
  Future<void> recordSuccess({DateTime? now}) async {
    _consecutiveFailures = 0;
    _hardLockUntil = null;
    _lastFailureAt = null;
    if (_records.isEmpty) {
      _records.add(AttemptRecord(at: now ?? DateTime.now(), success: true));
    } else {
      final last = _records.removeLast();
      _records.add(AttemptRecord(at: last.at, success: true));
    }
    await _save();
  }

  /// 供用户手动解除误解锁（例如换用官方客户端成功登录后）。
  ///
  /// 注意：这是**本地**记录，解除它不会改变服务端可能已有的标记。
  Future<void> reset() async {
    _records = [];
    _consecutiveFailures = 0;
    _hardLockUntil = null;
    _lastFailureAt = null;
    await _save();
  }

  int get consecutiveFailures => _consecutiveFailures;
  DateTime? get hardLockUntil => _hardLockUntil;
}
