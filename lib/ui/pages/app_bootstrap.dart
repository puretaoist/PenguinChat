/// 冷启动壳：先放品牌页，等「账号恢复」有结论（或超时）再淡入主界面。
///
/// ## 它解决的问题
///
/// 旧版 main.dart 直接 home: HomePage()。冷启动时 HomePage 第一帧必然是
/// "没有会话"的空态（票据还在读盘、自动登录还没发出去），于是用户会看到
/// 一眼「未连接后端 / 暂无会话」，然后画面自己跳成会话列表 —— 既闪又像出了错。
///
/// 这里把那段"其实正在干活"的时间显式画出来，并且**至少 650ms** 才让位，
/// 免得本机很快时闪一下品牌页更难看；最多等 6s，超时就先放人进主界面，
/// 恢复过程继续在后台跑（绝不把用户扣在启动页上）。
///
/// ## 为什么可以在这里 watch qq8 的 provider
///
/// HomePage / SettingsPage / ChatListPanel 在 widget 测试里被单独 pump，
/// 那套 override 里没有 qq8LoginServiceProvider（会抛）。所以"读登录状态"
/// 只能放在 main.dart 的这层壳里 —— 这里在真机上 provider 一定齐。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/qq8_login_service.dart';
import '../../client_api/qq8_providers.dart';
import '../pages/home_page.dart';
import '../pages/startup_splash.dart';

class AppBootstrap extends ConsumerStatefulWidget {
  const AppBootstrap({
    super.key,
    this.minimumSplash = const Duration(milliseconds: 650),
    this.maximumWait = const Duration(seconds: 6),
  });

  /// 品牌页最短停留时间（再快也要让人看清是谁在启动）。
  final Duration minimumSplash;

  /// 最长等待：超时先放人进主界面，恢复继续在后台跑。
  final Duration maximumWait;

  @override
  ConsumerState<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends ConsumerState<AppBootstrap> {
  late final DateTime _startedAt = DateTime.now();
  Timer? _ticker;
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    // 主动建一次控制器：它的构造里就会跑 autoLoginIfSaved()，
    // 也就是"后端账号随冷启动加载"真正开始的地方。不读它就不会开始。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        ref.read(qq8ConnectControllerProvider);
      } catch (_) {
        // 真机上不会失败；万一 provider 缺依赖，也别把启动页卡死。
        _reveal();
      }
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) => _check());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _check() {
    if (_revealed || !mounted) return;
    final Duration elapsed = DateTime.now().difference(_startedAt);
    if (elapsed < widget.minimumSplash) return;
    final Qq8LoginSnapshot? snap = ref.read(qq8LoginStateProvider).valueOrNull;
    final Qq8LoginStage stage = snap?.stage ?? Qq8LoginStage.idle;
    // idle = 没有任何可恢复的票（或还没开始）；其余终态 = 已经有结论了。
    if (stage == Qq8LoginStage.idle || _isSettled(stage)) {
      _reveal();
      return;
    }
    // connecting / needsSlider 之类：再等等，但别超过上限。
    if (elapsed >= widget.maximumWait) _reveal();
  }

  static bool _isSettled(Qq8LoginStage stage) => switch (stage) {
        Qq8LoginStage.online ||
        Qq8LoginStage.failed ||
        Qq8LoginStage.rejected ||
        Qq8LoginStage.sessionExpired ||
        Qq8LoginStage.disconnected ||
        Qq8LoginStage.needsSlider ||
        Qq8LoginStage.needsSmsCode ||
        Qq8LoginStage.needsDeviceLock ||
        Qq8LoginStage.waitingQrScan =>
          true,
        _ => false,
      };

  void _reveal() {
    if (_revealed || !mounted) return;
    _ticker?.cancel();
    setState(() => _revealed = true);
  }

  String _statusFor(Qq8LoginSnapshot? snap) {
    final Qq8LoginStage stage = snap?.stage ?? Qq8LoginStage.idle;
    return switch (stage) {
      Qq8LoginStage.connecting => snap?.uin == null
          ? '正在恢复账号…'
          : '正在恢复账号 ${snap!.uin}…',
      Qq8LoginStage.online => '已恢复，正在进入…',
      Qq8LoginStage.waitingQrScan => '等待扫码确认…',
      Qq8LoginStage.needsSlider ||
      Qq8LoginStage.needsSmsCode ||
      Qq8LoginStage.needsDeviceLock =>
        '需要重新验证…',
      Qq8LoginStage.sessionExpired || Qq8LoginStage.rejected => '需要在设置里重新登录',
      _ => '正在启动…',
    };
  }

  @override
  Widget build(BuildContext context) {
    final Qq8LoginSnapshot? snap = ref.watch(qq8LoginStateProvider).valueOrNull;
    final Widget child = _revealed
        ? const HomePage(key: ValueKey<String>('home'))
        : StartupSplash(
            key: const ValueKey<String>('splash'),
            status: _statusFor(snap),
          );
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: child,
    );
  }
}
