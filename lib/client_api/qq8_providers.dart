/// L3 客户端 API 层：协议线登录服务的 Riverpod 接线（**前端从这里接**）
///
/// 与 `session_providers.dart` 同一套约定：
/// * 只用 `package:riverpod`（不拉 Flutter，AGENTS §1.1）；
/// * 平台相关（数据目录、未来的加密存储）由 `main.dart` 通过
///   `ProviderScope.overrides` 注入，本层不碰 `path_provider`。
///
/// ## 前端怎么用
///
/// ```dart
/// // 读状态（驱动界面）
/// final snap = ref.watch(qq8LoginStateProvider).valueOrNull;
/// switch (snap?.stage) {
///   case Qq8LoginStage.needsSlider:  // 打开 snap.sliderUrl 给人解
///   case Qq8LoginStage.needsSmsCode: // 显示 snap.phone，收码后调 controller
///   case Qq8LoginStage.online:       // 进主界面
///   case Qq8LoginStage.failed:       // 显示 snap.error
///   ...
/// }
///
/// // 调动作
/// ref.read(qq8LoginServiceProvider).loginWithPassword(uin: ..., password: ...);
/// ref.read(qq8LoginServiceProvider).submitSliderTicket(ticket);
/// ```
///
/// 推送：原始帧 `ref.watch(qq8PushesProvider)`（在线后才有）；
/// 结构化事件 `ref.watch(qq8PushEventsProvider)`（收消息/被踢/新消息通知）。
///
/// ## 把协议线当成 UI 的后端（切后端时这么接）
///
/// ```dart
/// final adapter = Qq8SessionAdapter(
///   service: ref.read(qq8LoginServiceProvider), uin: uin);
/// await adapter.connect();   // 用本地票据上线
/// // 之后交给 chat_store / UI：adapter 就是 Session
/// ```
///
/// 口令/滑块/扫码登录仍走 [Qq8LoginService] 的动作（适配器的 `connect()` 只做
/// token 登录），认证完成后套上适配器即可。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:riverpod/riverpod.dart';

import '../infra/log/logger.dart';
import '../kernel/wlogin8/qq8_profiles.dart';
import '../kernel/wlogin8/qq8_push.dart';
import '../kernel/wlogin8/qq8_recv.dart';
import '../kernel/wlogin8/qq8_tran.dart';
import 'chat_store.dart';
import 'qq8_login_service.dart';
import 'qq8_session_adapter.dart';
import 'session.dart';
import 'session_providers.dart'
    show activeQq8BackendProvider, dataDirProvider, safetyGateProvider;

/// 票据存储——**必须由 `main.dart` override 注入**（需要一个可写目录）。
///
/// 例：`qq8TokenStoreProvider.overrideWithValue(FileQq8TokenStore(dir))`
final qq8TokenStoreProvider = Provider<Qq8TokenStore>(
  (ref) => throw UnimplementedError(
      'qq8TokenStoreProvider 必须被 override（见 main.dart：注入数据目录）'),
);

/// 使用的客户端档案（默认 8.9.50；可在设置里切换）。
final qq8ProfileProvider = Provider<Qq8ClientProfile>((ref) => qq8DefaultProfile);

/// 传输层构造器——测试可 override 成脚本传输；生产就是真实 TCP。
final qq8TransportBuilderProvider = Provider<Qq8Transport Function()>(
  (ref) => () => Qq8TcpTransport(),
);

/// 登录/会话服务实例（随 provider 生命周期创建与关闭）。
///
/// 注入与 OneBot 线**同一个** [safetyGateProvider]：协议线的联网前置校验
/// （真实服务器模式 + 有效同意）由它把关，见 [Qq8LoginService.gate]。
final qq8LoginServiceProvider = Provider<Qq8LoginService>((ref) {
  final svc = Qq8LoginService(
    profile: ref.watch(qq8ProfileProvider),
    tokenStore: ref.watch(qq8TokenStoreProvider),
    transportBuilder: ref.watch(qq8TransportBuilderProvider),
    gate: ref.watch(safetyGateProvider),
  );
  ref.onDispose(() => svc.close());
  return svc;
});

/// 当前状态快照流（UI 直接 watch；首个事件前的 loading 用 `.valueOrNull` 兜）。
final qq8LoginStateProvider = StreamProvider<Qq8LoginSnapshot>(
  (ref) => ref.watch(qq8LoginServiceProvider).states,
);

/// 服务端推送（只在 [Qq8LoginStage.online] 阶段有内容）。
///
/// 刻意依赖状态：未上线时给空流，上线后才接上会话层的广播流——
/// 这样 UI 不必关心"什么时候才有推送"。
final qq8PushesProvider = StreamProvider<Qq8SsoResponse>((ref) {
  final stage = ref.watch(qq8LoginStateProvider).valueOrNull?.stage;
  if (stage != Qq8LoginStage.online) {
    return const Stream<Qq8SsoResponse>.empty();
  }
  return ref.watch(qq8LoginServiceProvider).pushes;
});

/// 推送解析后的事件流：收到消息 / 被踢下线 / 新消息通知（UI 用这条）。
///
/// 与 [qq8PushesProvider] 的分工：那条是原始帧（排障），这条是结构化事件。
/// 服务层始终在解析（"被踢下线"要改状态），所以这里不按阶段过滤。
final qq8PushEventsProvider = StreamProvider<Qq8PushEvent>((ref) {
  return ref.watch(qq8LoginServiceProvider).events;
});

// ---------------------------------------------------------------------------
// 协议线后端：连接控制器（UI 用这个驱动登录，不必自己拼动作）
// ---------------------------------------------------------------------------

/// 协议线连接状态（UI 直接渲染这个）。
class Qq8ConnectStatus {
  /// 登录状态机的当前阶段。
  final Qq8LoginStage stage;

  /// 当前账号（发起登录后才有值）。
  final int? uin;

  /// 滑动验证地址（[Qq8LoginStage.needsSlider] 时）。
  final String? sliderUrl;

  /// 短信验证的手机号，以及"服务端已自动下发"标记。
  final String? phone;
  final bool smsAutoSent;

  /// 这次短信验证是"手机号短信登录"（true）还是"密码登录后补短信"（false）。
  final bool smsFlow;

  /// 设备锁提示语（[Qq8LoginStage.needsDeviceLock] 时）。
  final String? deviceLockHint;

  /// 二维码内容与扫码状态一句话（[Qq8LoginStage.waitingQrScan] 时）。
  final Uint8List? qrToken;
  final String? qrMessage;

  /// 失败原因（已转成给人看的话）。
  final String? error;

  /// 有动作在跑（UI 该禁用按钮）。
  final bool busy;

  const Qq8ConnectStatus({
    required this.stage,
    this.uin,
    this.sliderUrl,
    this.phone,
    this.smsAutoSent = false,
    this.smsFlow = false,
    this.deviceLockHint,
    this.qrToken,
    this.qrMessage,
    this.error,
    this.busy = false,
  });

  static const idle = Qq8ConnectStatus(stage: Qq8LoginStage.idle);

  bool get isOnline => stage == Qq8LoginStage.online;

  /// 需要人做点什么（UI 据此弹对应的表单）。
  bool get needsHumanAction =>
      stage == Qq8LoginStage.needsSlider ||
      stage == Qq8LoginStage.needsSmsCode ||
      stage == Qq8LoginStage.needsDeviceLock ||
      stage == Qq8LoginStage.waitingQrScan;

  String get stateLabel => switch (stage) {
        Qq8LoginStage.idle => '未连接',
        Qq8LoginStage.connecting => '连接中…',
        Qq8LoginStage.needsSlider => '需要完成滑动验证',
        Qq8LoginStage.needsSmsCode => '需要短信验证码',
        Qq8LoginStage.needsDeviceLock => '需要设备锁验证',
        Qq8LoginStage.waitingQrScan => '等待扫码确认',
        Qq8LoginStage.online => '已上线',
        Qq8LoginStage.disconnected => '已断开',
        Qq8LoginStage.failed => '登录失败',
      };
}

/// 协议线的连接控制器：把 [Qq8LoginService] 的多步认证搬给 UI。
///
/// 与 OneBot 那条（`ConnectionController`）的区别：协议线登录是**多步交互**
/// （口令 → 滑块/短信/设备锁，或扫码），所以这里把每一步都开成独立动作，
/// UI 按 [Qq8ConnectStatus.stage] 渲染对应表单。
///
/// 上线成功后自动套 [Qq8SessionAdapter] 并建 [ChatStore]——此后与 OneBot 那条
/// **完全同构**：`sessionProvider` / `chatStoreProvider` 都会切过来。
class Qq8ConnectController extends StateNotifier<Qq8ConnectStatus> {
  Qq8ConnectController({
    required this.service,
    required this.dataDir,
    this.log,
    this.onBackendChanged,
  }) : super(Qq8ConnectStatus.idle) {
    _sub = service.states.listen(_onSnapshot);
    _onSnapshot(service.snapshot);
  }

  /// 被桥接的登录服务（需要更细的控制时可直接用它）。
  final Qq8LoginService service;

  /// ChatStore 的落盘位置。
  final Directory dataDir;

  /// 日志回调。
  final void Function(String level, String message, [Object? detail])? log;

  /// 上线/断开时把"当前后端"报出去（UI 侧的 sessionProvider 靠它切换）。
  final void Function(Qq8SessionAdapter? session, ChatStore? store)?
      onBackendChanged;

  StreamSubscription<Qq8LoginSnapshot>? _sub;
  Qq8LoginSnapshot _snap = const Qq8LoginSnapshot(stage: Qq8LoginStage.idle);
  bool _busy = false;
  Qq8SessionAdapter? _adapter;
  ChatStore? _store;

  /// 当前状态（`StateNotifier.state` 是 protected，这里开个公开读口，
  /// 给"直接持有控制器"的调用方与测试用；provider 消费方 watch 即可）。
  Qq8ConnectStatus get status => state;

  /// 上线后的 Session（未上线为 null）。
  Session? get session => _adapter;

  /// 上线后的数据层（未上线为 null）。
  ChatStore? get store => _store;

  /// 口令登录（口令只在本进程内转 MD5，不落盘）。
  Future<void> loginWithPassword(int uin, String password) =>
      _run(() => service.loginWithPassword(uin: uin, password: password));

  /// 用本地票据登录（不需要口令）。
  Future<void> loginWithToken(int uin) =>
      _run(() => service.loginWithToken(uin: uin));

  /// 提交滑动验证票据（人工在浏览器解出来之后填回来）。
  Future<void> submitSliderTicket(String ticket) =>
      _run(() => service.submitSliderTicket(ticket));

  /// 手机号短信登录第一步：检查手机号（子命令 17，不需要 uin）。
  Future<void> loginWithPhone(String phone) =>
      _run(() => service.loginWithPhone(phone: phone));

  /// 手机号短信登录：请求下发验证码（子命令 19）。
  Future<void> refreshSmsLoginCode() =>
      _run(() => service.refreshSmsLoginCode());

  /// 手机号短信登录：提交验证码（子命令 18，通过后服务自动续一次口令登录）。
  Future<void> submitSmsLoginCode(String code) =>
      _run(() => service.submitSmsLoginCode(code));

  /// 请求下发短信验证码（密码登录那条线的子命令 8）。
  Future<void> requestSmsCode() => _run(() => service.requestSmsCode());

  /// 提交短信验证码。
  Future<void> submitSmsCode(String code) =>
      _run(() => service.submitSmsCode(code));

  /// 设备锁解锁。
  Future<void> unlockDevice() => _run(() => service.unlockDevice());

  /// 取登录二维码（扫码登录第一步）。
  Future<void> fetchQrcode() => _run(() => service.fetchQrcode());

  /// 轮询扫码状态（UI 按秒级节奏调）。
  Future<void> pollQrcode() => _run(() => service.pollQrcode());

  /// 断开并回到未连接（票据保留，下次可 [loginWithToken]）。
  Future<void> disconnect() async {
    await _teardown();
    await service.close();
    _snap = const Qq8LoginSnapshot(stage: Qq8LoginStage.idle);
    _emit();
  }

  /// provider 释放时调用（不抛异常）。
  Future<void> shutdown() async {
    try {
      await _sub?.cancel();
      await _teardown();
    } catch (e) {
      log?.call('warn', '释放协议线资源时出错', e);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    _emit();
    try {
      await action();
    } on Object catch (e) {
      // 服务自己会把失败写进快照（stage=failed + error），这里只兜底日志
      log?.call('warn', '协议线动作失败', e);
    } finally {
      _busy = false;
      _onSnapshot(service.snapshot);
    }
  }

  void _onSnapshot(Qq8LoginSnapshot s) {
    _snap = s;
    if (s.stage == Qq8LoginStage.online && _adapter == null) {
      unawaited(_attach());
    }
    _emit();
  }

  /// 上线后：套适配器 + 建数据层（幂等）。
  Future<void> _attach() async {
    if (!mounted || _adapter != null) return;
    final adapter = Qq8SessionAdapter(
      service: service,
      uin: _snap.uin,
      onLog: (level, message, [detail]) => log?.call(level, message, detail),
    );
    final store = ChatStore(session: adapter, dataDir: dataDir);
    await store.bootstrap();
    _adapter = adapter;
    _store = store;
    onBackendChanged?.call(adapter, store);
    log?.call('info', '协议线已上线 uin=${_snap.uin}，会话数=${store.chats.length}');
    _emit();
  }

  Future<void> _teardown() async {
    await _store?.dispose();
    await _adapter?.dispose();
    _store = null;
    _adapter = null;
    onBackendChanged?.call(null, null);
  }

  void _emit() {
    if (!mounted) return;
    state = Qq8ConnectStatus(
      stage: _snap.stage,
      uin: _snap.uin,
      sliderUrl: _snap.sliderUrl,
      phone: _snap.phone,
      smsAutoSent: _snap.smsAutoSent,
      smsFlow: _snap.smsFlow,
      deviceLockHint: _snap.deviceLockHint,
      qrToken: _snap.qrToken,
      qrMessage: _snap.qrMessage,
      error: _snap.error,
      busy: _busy,
    );
  }
}

/// 协议线的连接控制器（生命周期随 provider）。
final qq8ConnectControllerProvider =
    StateNotifierProvider<Qq8ConnectController, Qq8ConnectStatus>((ref) {
  final controller = Qq8ConnectController(
    service: ref.watch(qq8LoginServiceProvider),
    dataDir: ref.watch(dataDirProvider),
    log: (level, message, [detail]) => Log.get('Qq8Connect')
        .i('[$level] $message${detail == null ? '' : ' · $detail'}'),
    onBackendChanged: (session, store) {
      ref.read(activeQq8BackendProvider.notifier).state =
          session == null || store == null
              ? null
              : (session: session, store: store);
    },
  );
  ref.onDispose(controller.shutdown);
  return controller;
});
