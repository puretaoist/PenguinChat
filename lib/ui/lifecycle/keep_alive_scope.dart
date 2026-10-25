/// L4 接线：把「应用生命周期 + 会话状态」翻译成「挂/不挂前台服务」。
///
/// 这一层只做一件事：观察。判据在 L1（[KeepAlivePolicy]），平台调用在
/// [ForegroundKeepAlive]，这里负责把两个数据源接起来：
///
/// ```text
///   WidgetsBindingObserver.didChangeAppLifecycleState  ─┐
///   Session.events (SessionStateChanged)               ─┴→ KeepAliveController.update()
/// ```
///
/// ## 为什么放在 MaterialApp 外面
///
/// 它不需要 `BuildContext`、不需要主题、不参与布局。放在 `ProviderScope`
/// 与 `MaterialApp` 之间，好处是**整个应用生命周期内只有一个实例**——
/// 前台服务是进程级资源，挂两个观察者就会有两份状态互相打架。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/session.dart';
import '../../client_api/session_providers.dart';
import '../../client_api/qq8_providers.dart';
import '../../infra/lifecycle/keep_alive.dart';
import '../../infra/log/logger.dart';

class KeepAliveScope extends ConsumerStatefulWidget {
  const KeepAliveScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<KeepAliveScope> createState() => _KeepAliveScopeState();
}

class _KeepAliveScopeState extends ConsumerState<KeepAliveScope>
    with WidgetsBindingObserver {
  late final KeepAliveController _controller;

  /// 应用是否处于「用户看不见」的状态。
  ///
  /// 判据不是简单的 `state == paused`：分屏、画中画、下拉通知栏都会在
  /// `inactive` 与 `resumed` 之间来回切，而那些时刻**进程不可能被回收**
  /// （还可见）。只有真正离开（`paused` / `hidden` / `detached`）才需要保活。
  bool _background = false;

  Session? _session;
  StreamSubscription<SessionEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _controller = KeepAliveController(
      ref.read(keepAliveProvider),
      log: (message, {error}) => Log.get('KeepAlive').i(message, error: error),
    );
    WidgetsBinding.instance.addObserver(this);
    _background = _isBackground(WidgetsBinding.instance.lifecycleState);
    // 冷启动时可能已经有会话（热重启 / 从后台被系统重建），先同步一次。
    _attach(ref.read(sessionProvider));
    _syncForeground();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    // 应用退出时不能留一条"正在保持连接"的通知。
    unawaited(_controller.shutdown());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _background = _isBackground(state);
    _syncForeground();
    _sync();
  }

  /// 把前后台状态告诉协议层，决定消息轮询的频率。
  ///
  /// 官方客户端不做定时轮询（`MessageSvc.PbGetMsg` 由 `MessageSvc.PushNotify`
  /// 触发），我们收不到推送才需要兜底轮询；而后台高频率轮询既无可见收益
  /// （还没有消息通知）又提高风控风险，所以后台降到 60 s，回前台立刻补拉。
  void _syncForeground() {
    ref.read(qq8LoginServiceProvider).setAppForeground(!_background);
  }

  @override
  Widget build(BuildContext context) {
    // 会话实例换了（连上 / 断开 / 换后端）要重新挂监听。
    // 用 `listen` 而不是 `watch`：这里不需要因为会话变化而重建整棵树，
    // 只需要在回调里重新订阅一次。
    ref.listen<Session?>(sessionProvider, (_, next) => _attach(next));
    return widget.child;
  }

  /// 状态快照变了就重新算一遍。
  ///
  /// 注意这里**不 await**：生命周期回调是同步的，等平台通道往返会让
  /// 主线程多挂一帧；而 `KeepAliveController` 内部已经做了去重与异常吞没，
  /// 并发调用的最坏结果是多一次幂等的 start/stop。
  void _sync() {
    unawaited(_controller.update(
      appInBackground: _background,
      sessionActive: _isSessionActive(_session),
    ));
  }

  void _attach(Session? session) {
    if (identical(session, _session)) {
      // 同一个会话实例：只需重新同步一次（它的 state 可能已经变了）。
      _sync();
      return;
    }
    unawaited(_sub?.cancel());
    _session = session;
    _sub = session?.events.listen((event) {
      // 只关心状态变化：收到消息不改变"该不该保活"。
      if (event is SessionStateChanged) _sync();
    });
    _sync();
  }

  static bool _isBackground(AppLifecycleState? state) => switch (state) {
        // 彻底不可见：可以（也会）被系统回收，必须挂前台服务。
        AppLifecycleState.paused ||
        AppLifecycleState.hidden ||
        AppLifecycleState.detached =>
          true,
        // resumed / inactive：还在屏幕上，进程不会被回收，挂服务纯属打扰。
        _ => false,
      };

  /// 会话是否"有连接可保"。
  ///
  /// `connecting` / `reconnecting` 也算：重连过程中进程被杀，就再也连不回来了。
  static bool _isSessionActive(Session? session) {
    if (session == null) return false;
    return switch (session.state) {
      SessionState.ready ||
      SessionState.connecting ||
      SessionState.reconnecting =>
        true,
      SessionState.disconnected || SessionState.closed => false,
    };
  }
}
