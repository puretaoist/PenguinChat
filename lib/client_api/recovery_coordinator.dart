/// L3 客户端 API 层：**恢复编排的执行壳**——单飞 + 有界重试。
///
/// 与 [recovery_planner.dart] 的分工：
/// - planner 回答"**用什么材料**"（纯决策，可穷举单测）；
/// - 本文件回答"**要不要跑、跑几次**"（纯 Dart，无 IO、无 Flutter）。
///
/// 两条硬纪律：
///
/// 1. **单飞**：冷启动时 UI 侧可能有多处同时触发自动登录（构造期、
///    页面 initState、连接控制器回调），并发发同一张票既浪费又给风控加信号。
///    后来者直接拿到 `null`——不抛、不排队、不重复执行。
/// 2. **有界**：最多 [Qq8RecoveryCoordinator.maxAttempts] 次。"多试几次总会成功"
///    是错的（见 providers 里被拒冷却那段真机记录），这里绝不无限重试。
///
/// live 状态：**unavailable**——本文件只调度 `body`，自己不联网。
library;

import 'dart:async';

class Qq8RecoveryCoordinator {
  /// 两次尝试之间的等待（测试注入 [sleeper] 到 0 延迟）。
  final Duration delay;

  /// 测试注入的睡眠实现；null = 真等 [delay]。
  final Future<void> Function(Duration)? sleeper;

  /// 上限。**不是**"票能活多久"之类的时长常量，纯粹是尝试次数护栏。
  static const int maxAttempts = 4;

  Qq8RecoveryCoordinator({
    this.delay = const Duration(milliseconds: 800),
    this.sleeper,
  });

  Future<void>? _inflight;

  /// 当前是否有一次恢复在跑。
  bool get busy => _inflight != null;

  /// 单飞执行：并发的第二个及之后的调用立刻拿到 `null`。
  ///
  /// 不抛异常给后来者——它们没做任何事，不该收到 `body` 的失败。
  Future<T?> runSingleFlight<T>(Future<T?> Function() body) {
    if (_inflight != null) return Future<T?>.value(null);
    final done = Completer<void>();
    _inflight = done.future;
    Future<T?> run() async {
      try {
        return await body();
      } finally {
        _inflight = null;
        if (!done.isCompleted) done.complete();
      }
    }

    return run();
  }

  /// 有界执行：最多 [maxAttempts] 次；`body` 返回非 null 即成功、提前结束。
  ///
  /// 每次**失败**（返回 null 或抛异常）后等 [delay] 再试；次数用完返回最后一次的
  /// `null`（不抛：调用方关心的是"恢复了没有"）。
  Future<T?> runBounded<T>(Future<T?> Function(int attempt) body) async {
    for (var i = 1; i <= maxAttempts; i++) {
      try {
        final r = await body(i);
        if (r != null) return r;
      } on Object catch (_) {
        // 单次失败不向上抛：调用方只关心"最终恢复了没有"，失败原因由 body 自己记录。
      }
      if (i < maxAttempts) await _sleep(delay);
    }
    return null;
  }

  Future<void> _sleep(Duration d) {
    final s = sleeper;
    if (s != null) return s(d);
    if (d <= Duration.zero) return Future<void>.value();
    return Future<void>.delayed(d);
  }
}
