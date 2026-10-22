/// L1 基础设施：后台保活（纯 Dart，不 import Flutter）
///
/// ## 要解决的问题
///
/// 这是一个聊天客户端。用户切出去回微信、看视频、锁屏——连接不能断。
/// 但 Android 从 6.0 起对后台进程的处置是：**应用一进后台就开始倒计时，
/// 到点直接杀进程**。进程没了，Dart 隔离区就没了，WebSocket 自然也没了。
///
/// 唯一的正路是**前台服务**（`startForeground`）：带一条常驻通知，
/// 系统就把它当"用户知道它在跑"的进程，不再按后台进程回收。
/// Telegram、微信、所有能收消息的 App 都是这条路。
///
/// ## 为什么抽象成接口而不是直接调 MethodChannel
///
/// 1. **L1 不能 import Flutter**（`tool/layering_selftest.dart` 会拦，
///    但更重要的是这条规矩本身：协议内核与基础设施要能在纯 Dart 环境里
///    跑自测）。真正的 `MethodChannel` 实现在 L4（`lib/ui/platform/`），
///    由 `main.dart` 注入。
/// 2. **桌面 / 测试环境没有前台服务**。`NoopKeepAlive` 让这些场景零配置可用，
///    也让 `KeepAliveController` 的决策逻辑能用假实现完整测。
///
/// ## 「什么时候该挂」的判据
///
/// 不是"永远挂着"。理由：常驻通知对用户是实打实的打扰，
/// 而**前台时进程本来就不会被回收**——那时挂服务纯属多余。
/// 所以判据是「**在后台** 且 **有活跃连接**」：
///
/// ```text
///   前台 + 已连接 → 不挂（进程活着，没必要打扰）
///   后台 + 已连接 → 挂（这是唯一需要保活的场景）
///   后台 + 未连接 → 不挂（没连接可保，挂了只是白占通知栏）
/// ```
///
/// 这条判据是 [KeepAlivePolicy]，被单独抽出来是为了它能被穷举测试。
library;

/// 平台侧的后台保活能力。
///
/// 实现必须满足：**重复调用 start/stop 不抛异常**（生命周期回调会重复触发，
/// 而"已经在跑"不是错误）。
abstract class KeepAlive {
  /// 请求开始保活（拉起前台服务 + 常驻通知）。
  ///
  /// 允许失败：Android 12+ 对"从后台启动前台服务"有限制，抛
  /// `ForegroundServiceStartNotAllowedException` 是合法结果。
  /// 实现应把失败吞掉并记日志——保活失败不该让应用崩。
  Future<void> start();

  /// 请求结束保活。同样允许失败（服务可能已经被系统停掉）。
  Future<void> stop();

  /// 当前是否在保活中。用于避免重复调用与日志去重。
  Future<bool> isRunning();

  /// 申请通知权限（Android 13+ 的 `POST_NOTIFICATIONS` 是运行时权限）。
  ///
  /// 没有通知权限时前台服务仍然能跑，但通知不显示——用户会看到一个
  /// "看不见的服务"，这在某些 ROM 上反而更危险（用户无法手动停掉）。
  /// 所以调用方应在首次保活前申请一次。
  ///
  /// 默认实现什么都不做（桌面/测试环境不需要）。
  Future<bool> ensurePermission() async => true;
}

/// 什么都不做的实现。桌面、纯 Dart 自测、以及"用户明确关掉保活"时用。
class NoopKeepAlive implements KeepAlive {
  const NoopKeepAlive();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<bool> isRunning() async => false;

  @override
  Future<bool> ensurePermission() async => true;
}

/// 「现在该不该保活」的判据。抽成独立类是为了能穷举三种状态组合。
///
/// 见文件头那张表。注意 [sessionActive] 的定义是**连接处于
/// 已连接/重连中**，而不是"用户配置过连接"——配置过但没连上的时候，
/// 后台没有东西可保。
class KeepAlivePolicy {
  const KeepAlivePolicy();

  bool shouldRun({
    required bool appInBackground,
    required bool sessionActive,
  }) =>
      appInBackground && sessionActive;
}

/// 把「生命周期变化」翻译成「start/stop」，并做去重。
///
/// 为什么需要去重而不是每次变化都无脑调一遍：
/// - 生命周期回调在真机上很密集（下拉通知栏、来电、分屏都会触发
///   `inactive`/`resumed` 来回切），每次都跨平台通道往返一次是浪费；
/// - 更重要的是**日志会变得没法读**——排查"为什么连接断了"时，
///   一屏的 `keepalive start` 会盖掉真正有用的信息。
///
/// 所以只在**判据结果发生变化**时才真正调用平台侧。
class KeepAliveController {
  KeepAliveController(
    this._keepAlive, {
    KeepAlivePolicy policy = const KeepAlivePolicy(),
    void Function(String message, {Object? error})? log,
  })
      // 下面是误报：Dart 不允许私有名字作**命名**参数（`{this._policy}` 编译不过），
      // 所以只能用初始化列表转一手。lint 只看到"参数直接赋给同义字段"就报了。
      // ignore: prefer_initializing_formals
      : _policy = policy,
        // ignore: prefer_initializing_formals
        _log = log;

  final KeepAlive _keepAlive;
  final KeepAlivePolicy _policy;
  final void Function(String message, {Object? error})? _log;

  /// 上一次**实际下发**给平台侧的目标状态。
  ///
  /// 初值是 `false` 而不是 `null`：进程刚起来时前台服务确实没在跑，
  /// 这是**已知事实**不是"未知"。用 `null` 表示未知会让第一次 `update`
  /// 在「前台 + 未连接」时也下发一次 `stop()`——空调一次幂等接口不致命，
  /// 但会在自测里把「初始状态应该是安静的」这条断言弄成假的。
  bool _applied = false;

  /// 最近一次下发的**目标状态**（供测试断言"没变化就不重复调"）。
  ///
  /// 注意它是目标而非实测：`start()` 抛异常时这里仍然是 true——
  /// 这是刻意的，见 [update] 里的注释。
  bool get running => _applied;

  /// 输入一次状态快照，必要时下发到平台侧。
  ///
  /// 返回本次是否真的调用了平台侧（测试用它断言"没变化就不重复调"）。
  Future<bool> update({
    required bool appInBackground,
    required bool sessionActive,
  }) async {
    final want = _policy.shouldRun(
      appInBackground: appInBackground,
      sessionActive: sessionActive,
    );
    if (want == _applied) return false;
    // 先记目标值再调用：即使平台侧抛异常，也不要让它反复重试同一次
    // 状态迁移（生命周期回调会持续触发，重试只会刷屏）。
    _applied = want;
    try {
      if (want) {
        await _keepAlive.ensurePermission();
        await _keepAlive.start();
        _log?.call('后台保活已开启（前台服务）');
      } else {
        await _keepAlive.stop();
        _log?.call('后台保活已关闭');
      }
    } catch (e) {
      // 保活失败不能让应用崩：Android 12+ 的后台启动限制、
      // 部分 ROM 的省电策略都会让 startForeground 抛异常。
      // 连接本身还在，只是可能在后台被系统回收——这是可接受的降级。
      _log?.call('后台保活${want ? '开启' : '关闭'}失败', error: e);
    }
    return true;
  }

  /// 应用退出前收尾（不抛异常）。
  Future<void> shutdown() async {
    if (_applied != true) return;
    _applied = false;
    try {
      await _keepAlive.stop();
    } catch (e) {
      _log?.call('退出时关闭后台保活失败', error: e);
    }
  }
}
