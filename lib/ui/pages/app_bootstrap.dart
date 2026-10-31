/// 冷启动壳：先放品牌页，等「账号恢复」有结论（或超时）再淡入主界面。
///
/// ## 它解决的问题
///
/// 旧版 main.dart 直接 home: HomePage()。冷启动时 HomePage 第一帧必然是
/// "没有会话"的空态（票据还在读盘、自动登录还没发出去），于是用户会看到
/// 一眼「未连接后端 / 暂无会话」，然后画面自己跳成会话列表 —— 既闪又像出了错。
///
/// 这里把那段"其实正在干活"的时间显式画出来，但**不设最短停留**：官方 QQ
/// 的闪屏只盖住真实工作（纯 assets 闪屏的 f1926a=0，工作一完立刻 realOnCreate），
/// Telegram 连闪屏都没有、直接上本地缓存。人为的 650ms 停留纯属自伤。
/// 最多等 3s，超时就先放人进主界面（会话栏显示「正在连接…」而不是假的
/// 「未连接后端」），恢复过程继续在后台跑（绝不把用户扣在启动页上）。
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

import '../../client_api/chat_index_preview.dart';
import '../../client_api/objects.dart';
import '../../client_api/qq8_login_service.dart';
import '../../infra/log/logger.dart';
import '../../client_api/qq8_providers.dart';
import '../pages/home_page.dart';
import '../pages/startup_splash.dart';

class AppBootstrap extends ConsumerStatefulWidget {
  const AppBootstrap({
    super.key,
    this.preview,
    this.minimumSplash = Duration.zero,
    this.maximumWait = const Duration(seconds: 3),
  });

  /// 冷启动会话预览：**有它就不放品牌页**——第一帧直接是用户的会话列表。
  ///
  /// 这就是官方 Telegram 的做法（LaunchActivity 里直接 addFragmentToStack
  /// 主界面，数据来自本地库），也是真机上"点图标 → 立刻看到会话"的唯一
  /// 实现方式：会话数据不能等登录，得从磁盘索引先画出来。
  final ChatIndexPreview? preview;

  /// 品牌页最短停留时间。默认 0 = 只盖住真实工作，工作一完立刻让位。
  final Duration minimumSplash;

  /// 最长等待：超时先放人进主界面（会话栏转为「正在连接…」），恢复继续在后台跑。
  final Duration maximumWait;

  @override
  ConsumerState<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends ConsumerState<AppBootstrap> {
  static final Logger _log = Log.get('启动壳');

  /// 有没有可用的会话预览（有 = 第一帧就画列表，不走品牌页）。
  bool get _hasPreview =>
      widget.preview != null && widget.preview!.chats.isNotEmpty;

  /// idle 的宽限期：启动瞬间还没开始恢复，不能当成"没有票"。
  static const Duration _idleGrace = Duration(milliseconds: 400);

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
    // 有预览就不需要计时器：第一帧已经是列表，登录完成后 store 接管，
    // 列表内容不变（同一份索引、同一套排序），所以没有"切换"要等。
    if (!_hasPreview) {
      _ticker =
          Timer.periodic(const Duration(milliseconds: 100), (_) => _check());
    }
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
    // idle 有两种含义：启动后头几百毫秒是"还没开始跑"，之后才是"没有可恢复的
    // 票"。没有最短停留后，第一帧就可能撞上前者 —— 那会让用户看到一瞬间的
    // 「未连接后端」。所以 idle 要过了这个宽限期才算结论。
    if (stage == Qq8LoginStage.idle) {
      if (elapsed < _idleGrace) return;
      _reveal();
      return;
    }
    if (_isSettled(stage)) {
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
    final int ms = DateTime.now().difference(_startedAt).inMilliseconds;
    final Qq8LoginStage stage =
        ref.read(qq8LoginStateProvider).valueOrNull?.stage ??
            Qq8LoginStage.idle;
    _log.i('冷启动壳 → 主界面：用时 ${ms}ms，stage=${stage.name}');
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
    final Qq8LoginStage stage = snap?.stage ?? Qq8LoginStage.idle;
    // 只有"恢复中"才把会话栏切到等待态；idle（没有可恢复的票）和终态都算
    // 已有结论，该显示真正的空态与登录入口。
    final bool connecting = stage != Qq8LoginStage.idle && !_isSettled(stage);
    // 有预览 = 立刻是列表（第一帧），没有才退回品牌页。刻意**不做
    // AnimatedSwitcher 淡入**：两棵全屏树交叉合成在 debug 帧率下会明显
    // 掉帧，而"淡入"本身没有任何信息量——官方两家也都不淡入。
    if (_revealed || _hasPreview) {
      return HomePage(
        key: const ValueKey<String>('home'),
        connecting: connecting,
        previewChats: widget.preview?.chats ?? const <Chat>[],
      );
    }
    return StartupSplash(
      key: const ValueKey<String>('splash'),
      status: _statusFor(snap),
    );
  }
}
