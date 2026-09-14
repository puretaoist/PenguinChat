/// L3 客户端 API 层：协议线登录/会话服务——**前端对接的唯一入口**
///
/// ## 为什么要有这一层
///
/// `lib/kernel/wlogin8/` 是"零件"：TLV 怎么拼、三层信封怎么套、验证分支怎么走、
/// 防刷题怎么解。UI 不该碰这些，它只关心四件事：
///
/// 1. 现在处于什么阶段（连接中 / 等人工验证 / 在线 / 失败）；
/// 2. 需要人做什么（打开哪个地址、往哪输码）；
/// 3. 出错时给我一句能直接显示的话；
/// 4. 在线后服务端推来的东西从哪订阅。
///
/// 本文件就是这些事的家。**纯 Dart，不 import Flutter**（AGENTS §1.1）；
/// 需要平台能力（数据目录、凭据加密）时由上层通过构造参数注入。
///
/// ## 阶段与迁移
///
/// ```text
///   idle ──loginWithPassword/loginWithToken──▶ connecting
///        ┌──────────────┬──────────────┬──────────────┐
///        ▼              ▼              ▼              ▼
///   needsSlider    needsSmsCode   needsDeviceLock   failed(原因)
///        │              │              │
///        └─ 人工完成验证 / 自动解锁 ────┘
///                       ▼
///                    online（已注册上线 + 心跳中）
/// ```
///
/// ## 验证分支对应的方法
///
/// | 阶段 | 人看到的东西 | 调用的方法 |
/// |---|---|---|
/// | [Qq8LoginStage.needsSlider] | [Qq8LoginSnapshot.sliderUrl] 地址 | [Qq8LoginService.submitSliderTicket] |
/// | [Qq8LoginStage.needsSmsCode] | [Qq8LoginSnapshot.phone] 手机号 | [Qq8LoginService.requestSmsCode] / [Qq8LoginService.submitSmsCode] |
/// | [Qq8LoginStage.needsDeviceLock] | [Qq8LoginSnapshot.deviceLockHint] 提示 | [Qq8LoginService.unlockDevice] |
///
/// ## 票据存储
///
/// [Qq8TokenStore] 可注入；默认 [FileQq8TokenStore]（明文 JSON）。
/// ⚠️ 明文只是过渡：加密存储属于"票据安全存储"那条路线（见文件末尾 TODO），
/// 换实现时只需替换注入的 store，本文件其余部分不动。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../infra/log/logger.dart';
import '../kernel/crypto/ecdh.dart';
import '../kernel/safety/safety_gate.dart';
import '../kernel/wlogin8/qq8_config.dart';
import '../kernel/wlogin8/qq8_device.dart';
import '../kernel/wlogin8/qq8_login.dart';
import '../kernel/wlogin8/qq8_history.dart';
import '../kernel/wlogin8/qq8_image.dart';
import '../kernel/wlogin8/qq8_list.dart';
import '../kernel/wlogin8/qq8_msg.dart';
import '../kernel/wlogin8/qq8_push.dart';
import '../kernel/wlogin8/qq8_pow.dart';
import '../kernel/wlogin8/qq8_profiles.dart';
import '../kernel/wlogin8/qq8_qrcode.dart';
import '../kernel/wlogin8/qq8_recv.dart';
import '../kernel/wlogin8/qq8_session.dart';
import '../kernel/wlogin8/qq8_sso.dart';
import '../kernel/wlogin8/qq8_tlv.dart';
import '../kernel/wlogin8/qq8_tran.dart';
import 'qq8_token_store.dart';

export 'qq8_token_store.dart';

final Logger _log = Log.get('QQ8SVC');

/// 服务所处阶段。UI 据此决定显示哪个界面。
enum Qq8LoginStage {
  /// 还没开始（或已关闭）。
  idle,

  /// 已发出登录请求，等响应。
  connecting,

  /// 服务端要求滑动验证：把 [Qq8LoginSnapshot.sliderUrl] 给人打开。
  needsSlider,

  /// 服务端要求短信验证码：可能需要 [Qq8LoginService.requestSmsCode]，
  /// 也可能已被服务端自动下发（见 [Qq8LoginSnapshot.smsAutoSent]）。
  needsSmsCode,

  /// 服务端要求设备锁验证。
  needsDeviceLock,

  /// 已注册上线、心跳运行中。
  online,

  /// 二维码已取到，等人在手机 QQ 里扫码并确认
  /// （由调用方按秒级节奏调 [Qq8LoginService.pollQrcode]）。
  waitingQrScan,

  /// 曾上线、但连接已经掉了（心跳连续失败或传输层关闭）。
  ///
  /// 与 [failed] 分开：登录/验证阶段的问题要人重新操作，掉线则是"可以重连"，
  /// UI 对两者的处理通常不同（前者引导重登，后者提示重连/自动重连）。
  disconnected,

  /// 失败：原因在 [Qq8LoginSnapshot.error]（可直接显示给用户）。
  failed,
}

/// 未上线就想发消息等业务请求。
class Qq8NotOnlineException implements Exception {
  final String message;
  Qq8NotOnlineException(this.message);

  @override
  String toString() => 'Qq8NotOnlineException: $message';
}

/// 状态快照（不可变；UI 每次收到新的一份）。
class Qq8LoginSnapshot {
  final Qq8LoginStage stage;

  /// 当前账号（登录发起后才有值）。
  final int? uin;

  /// 滑动验证地址（[Qq8LoginStage.needsSlider] 时）。
  final String? sliderUrl;

  /// 短信验证的目标手机号（[Qq8LoginStage.needsSmsCode] 时，取不到则为 null）。
  final String? phone;

  /// 服务端是否已自动下发短信（这种情况下不必再调 `requestSmsCode`）。
  final bool smsAutoSent;

  /// 这次短信验证是不是"手机号短信登录"那条线（而不是密码登录后补短信）。
  ///
  /// 有区别：手机号线要 [Qq8LoginService.refreshSmsLoginCode]（子命令 19）
  /// 请求下发、[Qq8LoginService.submitSmsLoginCode]（子命令 18）提交；
  /// 密码线是 [Qq8LoginService.requestSmsCode]（8）/ [Qq8LoginService.submitSmsCode]（7）。
  final bool smsFlow;

  /// 设备锁提示语（[Qq8LoginStage.needsDeviceLock] 时）。
  final String? deviceLockHint;

  /// 二维码内容（[Qq8LoginStage.waitingQrScan] 时；交给 UI 渲染成二维码图片）。
  final Uint8List? qrToken;

  /// 扫码状态的一句话（"二维码尚未扫描" / "已扫描，请在手机上确认"…）。
  final String? qrMessage;

  /// 失败原因（[Qq8LoginStage.failed] 时，已转成给人看的话）。
  final String? error;

  const Qq8LoginSnapshot({
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
  });

  bool get isOnline => stage == Qq8LoginStage.online;
  bool get needsHumanAction =>
      stage == Qq8LoginStage.needsSlider ||
      stage == Qq8LoginStage.needsSmsCode ||
      stage == Qq8LoginStage.needsDeviceLock ||
      stage == Qq8LoginStage.waitingQrScan;

  @override
  String toString() => 'Qq8LoginSnapshot(${stage.name}'
      '${uin == null ? '' : ' uin=$uin'}'
      '${error == null ? '' : ' error=$error'})';
}

/// 协议线登录/会话服务。
///
/// 一个实例对应"一个账号的一次会话"：登录（含全部验证分支）→ 注册上线 →
/// 心跳 → 推送订阅；[close] 结束。要换账号就新建一个实例。
class Qq8LoginService {
  /// 客户端档案（默认 8.9.50，与档案层同一份定义）。
  final Qq8ClientProfile profile;

  /// 票据存储（默认内存；生产请注入 [FileQq8TokenStore] 或加密实现）。
  final Qq8TokenStore tokenStore;

  /// 传输层构造器——**测试注入脚本传输**，生产用真实 TCP。
  final Qq8Transport Function() transportBuilder;

  /// 设备构造器——默认按 uin 派生（同一账号恒定同一台设备）。
  /// 测试注入固定夹具；将来要复用持久化的设备信息也从这里接。
  final Qq8Device Function(int uin)? deviceBuilder;

  /// ECDH 构造器——默认随机密钥对；测试注入固定私钥以便预先造出密文。
  final EcdhKeyPair Function()? ecdhBuilder;

  /// 安全闸门：**非空时**在每次联网前校验"真实服务器模式 + 有效知情同意"。
  ///
  /// 协议线永远连生产服务器（没有回环测试一说），所以策略比 OneBot 线更严，
  /// 两个条件缺一不可。App 侧由 `qq8LoginServiceProvider` 注入同一个闸门实例；
  /// 命令行工具的"确认串"是另一道闸门（不依赖 App 的同意流程）。
  final SafetyGate? gate;

  /// 心跳间隔（默认 4.5 分钟，oicq 的量级）。
  final Duration heartbeatInterval;

  /// 网络层超时（连接/单请求）。
  final Duration timeout;

  final StreamController<Qq8LoginSnapshot> _states =
      StreamController<Qq8LoginSnapshot>.broadcast();
  Qq8LoginSnapshot _snapshot = const Qq8LoginSnapshot(stage: Qq8LoginStage.idle);

  final StreamController<Qq8PushEvent> _events =
      StreamController<Qq8PushEvent>.broadcast();
  StreamSubscription<Qq8SsoResponse>? _pushSub;

  Qq8Transport? _tran;
  Qq8Session? _session;
  Qq8SigBundle? _sig;

  /// 增量拉消息的游标（`PbGetMsgResp.sync_cookie`，服务端靠它算增量）。
  Uint8List? _syncCookie;

  // 一次登录流程内固定的材料（与参考实现一致：同一客户端实例复用同一套）
  Qq8Device? _device;
  EcdhKeyPair? _ecdh;
  Uint8List? _sessionId;
  Uint8List? _randomKey;

  // 上一条"要求验证"响应里带回来的材料
  Uint8List _t104 = Uint8List(0);
  Uint8List _t174 = Uint8List(0);
  Uint8List? _t547;
  String? _sliderUrl;

  /// 二维码流程的中间态
  int _expectedUin = 0;
  Uint8List? _qrsig;
  Uint8List? _qrToken;

  // 手机号短信验证登录的中间态（三次请求跨调用保持）
  String? _smsPhone;
  Uint8List? _smsRandom;
  int _smsMsalt = 0;
  String? _smsMpasswd;
  int? _smsMsgCnt;
  int? _smsTimeLimit;

  Qq8LoginService({
    Qq8ClientProfile? profile,
    Qq8TokenStore? tokenStore,
    Qq8Transport Function()? transportBuilder,
    this.deviceBuilder,
    this.ecdhBuilder,
    this.gate,
    this.heartbeatInterval = const Duration(seconds: 270),
    this.timeout = const Duration(seconds: 15),
  })  : profile = profile ?? qq8DefaultProfile,
        tokenStore = tokenStore ?? _MemoryTokenStore(),
        transportBuilder = transportBuilder ?? (() => Qq8TcpTransport());

  /// 诊断钩子（可选）：每收到一条登录/验证类的**原始响应帧**就回调一次。
  ///
  /// 为什么需要它：真机失败时（风控拒绝等）光看一句中文提示没法定位，得把
  /// 原始帧落盘再离线复解——密码那条路由冒烟工具自己落盘，扫码这条走的是
  /// 服务层，以前没有这个口子，真机上一失败就抓瞎。
  ///
  /// [tag] 说明这条是哪一步（`fetch`/`poll`/`login`）；[parsed] 是能解出
  /// type/TLV 时的解析结果（扫码的响应类型不同，可能是 null）。
  void Function(String tag, Uint8List frame, Qq8LoginResponse? parsed)?
      onDiagnostic;

  /// 当前 ECDH 共享密钥（诊断落盘用；没握手前为 null）。
  Uint8List? get debugShareKey => _ecdh?.shareKey;

  /// 返回阻止联网的原因（null = 放行）。见 [gate] 的说明。
  String? _gateBlockReason() {
    final g = gate;
    if (g == null) return null;
    if (!g.isRealServer) {
      return '要连接真实 QQ 服务器，需要先在「风险确认」里开启真实服务器模式：'
          '先做环境检测，再逐条确认风险点。';
    }
    if (!g.hasValidConsent) {
      return '知情同意已失效（声明已更新到 $kConsentVersion），需要重新逐条确认。';
    }
    return null;
  }

  /// 联网前的统一闸门：不通过就直接落到 failed，**一个字节都不发**。
  bool _passGate() {
    final blocked = _gateBlockReason();
    if (blocked == null) return true;
    _emit(Qq8LoginSnapshot(
        stage: Qq8LoginStage.failed, uin: _snapshot.uin, error: blocked));
    return false;
  }

  /// 当前状态快照。
  Qq8LoginSnapshot get snapshot => _snapshot;

  /// 状态流（UI 用 `StreamBuilder`/provider 订阅）。
  Stream<Qq8LoginSnapshot> get states => _states.stream;

  /// 服务端主动推送的帧（仅在 [Qq8LoginStage.online] 后会有内容）。
  Stream<Qq8SsoResponse> get pushes =>
      _session?.pushes ?? const Stream<Qq8SsoResponse>.empty();

  /// 推送解析后的事件流（收到消息 / 被踢下线 / 新消息通知）。
  ///
  /// 服务在 [Qq8LoginStage.online] 后自己订阅推送并解析，所以即使没人订阅
  /// 本流，"被踢下线"也会照常改状态；这里只是把事件再广播给 UI。
  Stream<Qq8PushEvent> get events => _events.stream;

  /// 登录成功后的票据（未登录为 null）。
  Qq8SigBundle? get sig => _sig;

  /// 当前是否在线（已注册 + 心跳中）。
  bool get isOnline => _snapshot.isOnline && (_session?.isOnline ?? false);

  // ------------------------------------------------------------------
  // 入口：登录
  // ------------------------------------------------------------------

  /// 口令登录。
  ///
  /// [password] 只在本方法内转成 MD5，不落盘、不进日志。
  Future<void> loginWithPassword({
    required int uin,
    required String password,
  }) async {
    final md5 = md5Bytes(Uint8List.fromList(utf8.encode(password)));
    await _login(uin: uin, passwordMd5: md5);
  }

  /// 口令 MD5 已知时直接用它（调用方自己保证不在别处泄漏）。
  Future<void> loginWithPasswordMd5({
    required int uin,
    required Uint8List passwordMd5,
  }) =>
      _login(uin: uin, passwordMd5: passwordMd5);

  /// 用已存的票据续期登录（不需要口令）。
  Future<void> loginWithToken({required int uin}) async {
    final token = await tokenStore.load(uin);
    if (token == null || !token.usable) {
      _emit(const Qq8LoginSnapshot(
        stage: Qq8LoginStage.failed,
        error: '没有可用的票据（先做一次口令登录）',
      ));
      return;
    }
    await _login(uin: uin, passwordMd5: null, token: token);
  }

  Future<void> _login({
    required int uin,
    required Uint8List? passwordMd5,
    Qq8TokenData? token,
    bool smsLogin = false,
  }) async {
    _emit(Qq8LoginSnapshot(stage: Qq8LoginStage.connecting, uin: uin));
    try {
      // 一次登录流程内的固定材料：设备按 uin 派生（同一账号恒定同一台设备），
      // ECDH / 会话标识 / 随机密钥都只生成一次，验证分支复用同一套。
      //
      // 手机号短信那条线（[smsLogin]）是"同一流程的延续"：设备/密钥在
      // [loginWithPhone] 里就建好了（那时只有 uin=0），这里**沿用**——
      // 官方整条流程只有一个设备身份，中途换设备是多余的风控信号。
      if (!smsLogin) {
        _device = (deviceBuilder ?? Qq8Device.generate)(uin);
        if (token != null) {
          // token 路径的约定：tgtgt = MD5(d2key)（没有密码就派生不出新的）
          _device = _device!.withTgtgt(md5Bytes(token.d2key));
        }
        _ecdh = (ecdhBuilder ??
            () => Ecdh.exchange(Uint8List.fromList(Qq8Config.serverEcdhPublicKey)))();
        _sessionId = _randomBytes(4);
        _randomKey = _randomBytes(16);
      }

      final ctx = _tlvCtx(uin, passwordMd5: passwordMd5, token: token, smsLogin: smsLogin);
      final body = token == null
          ? Qq8LoginBody.build(
              ctx,
              Qq8SubCmd.password,
              // 维护版 oicq v1.26.25 的密码包：官方顺序表 + 包尾 0x542（ssoVer>12）。
              qq8PasswordTlvOrderFor(profile.apk),
              // 短信验证登录那次：账号是手机号（0x112），登录类型 3（0x185 也靠它）
              cond: smsLogin
                  ? Qq8LoginConditions(
                      accountIsUin: false,
                      loginType: 3,
                      t104: ctx.t104,
                      t548: ctx.t548)
                  : Qq8LoginConditions(t548: ctx.t548),
              args: smsLogin
                  ? <int, List<Object?>>{
                      0x112: <Object?>[_smsPhone],
                    }
                  : const <int, List<Object?>>{},
            )
          : Qq8LoginBody.buildToken(ctx, d2: token.d2);
      await _sendLoginBody(uin, ctx, body, token: token);
    } on Object catch (e, st) {
      _fail('登录请求失败', e, st);
    }
  }

  // ------------------------------------------------------------------
  // 验证分支：人工完成后继续
  // ------------------------------------------------------------------

  /// 提交人工解出的滑动验证 ticket（[Qq8LoginStage.needsSlider] 之后调）。
  Future<void> submitSliderTicket(String ticket) async {
    final uin = _snapshot.uin;
    if (uin == null || _device == null) {
      _emit(const Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed, error: '还没发起登录，无法提交验证'));
      return;
    }
    if (_t104.isEmpty) {
      _emit(const Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed, error: '缺少服务端下发的盐（0x104），请重新发起登录'));
      return;
    }
    _emit(Qq8LoginSnapshot(stage: Qq8LoginStage.connecting, uin: uin));
    try {
      final ctx = _tlvCtx(uin, passwordMd5: null, token: null);
      final body = Qq8LoginBody.buildSlider(ctx, ticket: ticket);
      await _sendLoginBody(uin, ctx, body);
    } on Object catch (e, st) {
      _fail('提交滑动验证失败', e, st);
    }
  }

  /// 请求服务端下发短信验证码（[Qq8LoginStage.needsSmsCode] 且
  /// [Qq8LoginSnapshot.smsAutoSent] 为 false 时调）。
  Future<void> requestSmsCode() async {
    final uin = _snapshot.uin;
    if (uin == null || _device == null) {
      _emit(const Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed, error: '还没发起登录，无法请求短信'));
      return;
    }
    _emit(Qq8LoginSnapshot(stage: Qq8LoginStage.connecting, uin: uin));
    try {
      final ctx = _tlvCtx(uin, passwordMd5: null, token: null);
      await _sendLoginBody(uin, ctx, Qq8LoginBody.buildSendSms(ctx));
    } on Object catch (e, st) {
      _fail('请求短信验证码失败', e, st);
    }
  }

  /// 提交用户收到的 6 位短信验证码。
  Future<void> submitSmsCode(String code) async {
    final uin = _snapshot.uin;
    if (uin == null || _device == null) {
      _emit(const Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed, error: '还没发起登录，无法提交验证码'));
      return;
    }
    _emit(Qq8LoginSnapshot(stage: Qq8LoginStage.connecting, uin: uin));
    try {
      final ctx = _tlvCtx(uin, passwordMd5: null, token: null);
      await _sendLoginBody(
          uin, ctx, Qq8LoginBody.buildSubmitSms(ctx, code: code));
    } on Object catch (e, st) {
      _fail('提交短信验证码失败', e, st);
    }
  }

  /// 解锁设备锁（[Qq8LoginStage.needsDeviceLock] 之后调）。
  Future<void> unlockDevice() async {
    final uin = _snapshot.uin;
    if (uin == null || _device == null) {
      _emit(const Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed, error: '还没发起登录，无法解锁'));
      return;
    }
    _emit(Qq8LoginSnapshot(stage: Qq8LoginStage.connecting, uin: uin));
    try {
      final ctx = _tlvCtx(uin, passwordMd5: null, token: null);
      await _sendLoginBody(uin, ctx, Qq8LoginBody.buildDeviceUnlock(ctx));
    } on Object catch (e, st) {
      _fail('设备锁解锁失败', e, st);
    }
  }

  // ------------------------------------------------------------------
  // 手机号短信验证登录（子命令 17 → 19 → 18，之后用 mpasswd 续一次口令登录）
  // ------------------------------------------------------------------
  //
  // 官方三段式（`oicq/wlogin_sdk/request/{w,x,y}.java`）：
  //   17 检查手机号 → 208（盐 0x104 / 随机数 0x126 / 次数与时限 0x182 / msalt 0x183）
  //   19 下发验证码 → 232（新盐 + 0x52B 提示号）
  //   18 提交验证码 → **不给票据**，只回 0x113(uin) + 0x183 + 0x104
  //                   （`oicq_request.java:1525` 的 `i3 == 3 || i3 == 7` 分支）
  // 之后 `GetStViaSMSVerifyLogin` → `GetStWithPasswd(..., z2=true)`：把口令换成
  // 本地现生成的 `_mpasswd`（`WtloginHelper.java:1426-1439`），登录类型 = 3
  // （`:2310`），于是同一条子命令 9 就把票据换回来了。

  /// 短信登录第一步：检查这个手机号能否短信登录（子命令 17）。**不需要 uin**。
  ///
  /// 国内号传 11 位原文即可（官方 msf 层对非 86 开头的国家码才拼 `00` 前缀，
  /// 见 `msf/core/auth/l.java:796`）。
  Future<void> loginWithPhone({required String phone}) async {
    if (phone.isEmpty) {
      _emit(const Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed, error: '手机号不能为空'));
      return;
    }
    _emit(Qq8LoginSnapshot(stage: Qq8LoginStage.connecting, phone: phone));
    try {
      _smsPhone = phone;
      _smsRandom = null;
      _smsMsalt = 0;
      _smsMpasswd = null;
      _smsMsgCnt = null;
      _smsTimeLimit = null;
      // 手机号流程首包没有盐（与密码首登同理），盐由 208/232 下发
      _t104 = Uint8List(0);
      _t174 = Uint8List(0);
      _t547 = null;
      _sliderUrl = null;
      // 还不知道 uin（要等 18 号回包的 0x113）：设备按 0 派生，
      // 与官方"新建一个 uin=0 的会话"（`t.a(0L)`）是同一形状。
      _device = (deviceBuilder ?? Qq8Device.generate)(0);
      _ecdh = (ecdhBuilder ??
          () => Ecdh.exchange(Uint8List.fromList(Qq8Config.serverEcdhPublicKey)))();
      _sessionId = _randomBytes(4);
      _randomKey = _randomBytes(16);

      final ctx = _tlvCtx(0, passwordMd5: null, token: null);
      await _sendLoginBody(
        0,
        ctx,
        Qq8LoginBody.buildSmsLoginCheck(ctx, phone: phone),
        smsStep: _SmsStep.check,
      );
    } on Object catch (e, st) {
      _fail('检查手机号失败', e, st);
    }
  }

  /// 短信登录第二步：请求服务端下发（或刷新）验证码（子命令 19）。
  ///
  /// 必须在 [loginWithPhone] 的 208 回包之后调：这条要回带上一步的盐。
  Future<void> refreshSmsLoginCode() async {
    final phone = _smsPhone;
    if (phone == null || _device == null) {
      _emit(const Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed, error: '还没发起手机号登录，无法请求验证码'));
      return;
    }
    if (_t104.isEmpty) {
      _emit(const Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed, error: '缺少服务端下发的盐（0x104），请重新检查手机号'));
      return;
    }
    _emit(Qq8LoginSnapshot(stage: Qq8LoginStage.connecting, phone: phone));
    try {
      final ctx = _tlvCtx(0, passwordMd5: null, token: null);
      await _sendLoginBody(
        0,
        ctx,
        Qq8LoginBody.buildSmsLoginRefresh(ctx),
        smsStep: _SmsStep.refresh,
      );
    } on Object catch (e, st) {
      _fail('请求短信验证码失败', e, st);
    }
  }

  /// 短信登录第三步：提交收到的验证码（子命令 18）。
  ///
  /// 通过后**自动**再用 `mpasswd` 走一次子命令 9 换票据（官方同款两步），
  /// 成功时状态直接到 [Qq8LoginStage.online]，不需要调用方再做什么。
  Future<void> submitSmsLoginCode(String code) async {
    final phone = _smsPhone;
    if (phone == null || _device == null) {
      _emit(const Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed, error: '还没发起手机号登录，无法提交验证码'));
      return;
    }
    if (_t104.isEmpty) {
      _emit(const Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed, error: '缺少服务端下发的盐（0x104），请重新检查手机号'));
      return;
    }
    final random = _smsRandom;
    if (random == null || random.isEmpty) {
      _emit(const Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed,
          error: '缺少服务端下发的随机数（0x126），请重新检查手机号'));
      return;
    }
    _emit(Qq8LoginSnapshot(stage: Qq8LoginStage.connecting, phone: phone));
    try {
      // 官方每次提交都现生成（`get_mpasswd()`），之后这次登录就用它当口令
      final mpasswd = _randomMpasswd();
      _smsMpasswd = mpasswd;
      final ctx = _tlvCtx(0, passwordMd5: null, token: null);
      await _sendLoginBody(
        0,
        ctx,
        Qq8LoginBody.buildSmsLoginVerify(
          ctx,
          code: code,
          random: random,
          mpasswd: mpasswd,
          msalt: _smsMsalt,
        ),
        smsStep: _SmsStep.verify,
      );
    } on Object catch (e, st) {
      _fail('提交短信验证码失败', e, st);
    }
  }

  /// 验证码次数/时限（208 回包 `0x182`；没收到过就是 null）。
  ({int msgCnt, int timeLimit})? get smsLoginLimits {
    final c = _smsMsgCnt;
    final t = _smsTimeLimit;
    if (c == null || t == null) return null;
    return (msgCnt: c, timeLimit: t);
  }

  /// 导出手机号短信登录的中间材料（供 [resumeSmsLogin] 在另一段里接着跑）。
  ///
  /// 三道材料齐全（手机号 + 盐 + 随机数）才返回；否则 null——宁可从头发起，
  /// 也不拿半套材料去发请求。
  Qq8SmsLoginState? get smsLoginState {
    final phone = _smsPhone;
    final random = _smsRandom;
    if (phone == null || _t104.isEmpty || random == null || random.isEmpty) {
      return null;
    }
    return Qq8SmsLoginState(
      phone: phone,
      salt: _t104,
      random: random,
      msalt: _smsMsalt,
      msgCnt: _smsMsgCnt,
      timeLimit: _smsTimeLimit,
      hintPhone: _snapshot.phone,
    );
  }

  /// 恢复第 1 段导出的材料（之后直接调 [submitSmsLoginCode]）。
  ///
  /// 设备仍按 uin=0 派生——与 [loginWithPhone] 同一套（手机号流程在拿到 uin
  /// 之前就是这个身份，跨进程也要保持一致）。
  void resumeSmsLogin(Qq8SmsLoginState state) {
    _smsPhone = state.phone;
    _t104 = state.salt;
    _smsRandom = state.random;
    _smsMsalt = state.msalt;
    _smsMsgCnt = state.msgCnt;
    _smsTimeLimit = state.timeLimit;
    _smsMpasswd = null;
    _device = (deviceBuilder ?? Qq8Device.generate)(0);
    _ecdh = (ecdhBuilder ??
        () => Ecdh.exchange(Uint8List.fromList(Qq8Config.serverEcdhPublicKey)))();
    _sessionId = _randomBytes(4);
    _randomKey = _randomBytes(16);
    _emit(Qq8LoginSnapshot(
      stage: Qq8LoginStage.needsSmsCode,
      phone: state.hintPhone ?? state.phone,
      smsAutoSent: true,
      smsFlow: true,
    ));
  }

  // ------------------------------------------------------------------
  // 发消息（需在线）
  // ------------------------------------------------------------------

  /// 发一条私聊消息。**需已上线**，未上线抛 [Qq8NotOnlineException]。
  ///
  /// [elems] 是**有序的内容元素**（[Qq8Msg.textElem] / [Qq8Msg.faceElem]…），
  /// 文本消息就是"只有一个文本元素"。
  /// 返回服务端结果；[Qq8MsgSendResult.ok] 为假时 [Qq8MsgSendResult.message]
  /// 是可显示的原因（结果码 0 = 成功）。
  Future<Qq8MsgSendResult> sendC2c({
    required int uid,
    required List<Uint8List> elems,
    Qq8ReplyInfo? reply,
  }) async {
    final s = _requireOnline();
    final seq = s.nextSeq();
    final rand = _randomU32();
    final body = Qq8Msg.buildC2cTextBody(
      reply: reply,
      uid: uid,
      elems: elems,
      seq: seq,
      rand: rand,
      syncCookieSeed: _sessionSeedU32(),
      nowSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      syncR5: _randomU32(),
      syncR9: _randomU32(),
      syncR11: _randomU32(),
    );
    final rsp =
        await s.sendUni(Qq8Msg.sendCmd, body, seq: seq, timeout: timeout);
    final r = Qq8Msg.parseSendResponse(rsp.payload, seq: seq, rand: rand);
    _log.i('私聊发送 uid=$uid code=${r.code} seq=$seq ${r.ok ? 'ok' : r.message}');
    return r;
  }

  /// 发一条群聊消息。**需已上线**。[elems] 含义同 [sendC2c]。
  Future<Qq8MsgSendResult> sendGroup({
    required int gid,
    required List<Uint8List> elems,
    Qq8ReplyInfo? reply,
  }) async {
    final s = _requireOnline();
    final rand16 = _randomU32() & 0xFFFF;
    final rand32 = _randomU32();
    final body = Qq8Msg.buildGroupTextBody(
      reply: reply,
      gid: gid,
      elems: elems,
      rand16: rand16,
      rand32: rand32,
    );
    final rsp = await s.sendUni(Qq8Msg.sendCmd, body, timeout: timeout);
    final r = Qq8Msg.parseSendResponse(rsp.payload, seq: 0, rand: rand32);
    _log.i('群聊发送 gid=$gid code=${r.code} ${r.ok ? 'ok' : r.message}');
    return r;
  }

  Qq8Session _requireOnline() {
    final s = _session;
    if (s == null || !isOnline) {
      throw Qq8NotOnlineException('还没上线（当前 ${_snapshot.stage.name}），不能发消息');
    }
    return s;
  }

  // ------------------------------------------------------------------
  // 发图片（四步：探图 → PicUp 申请 → highway 传数据 → 元素回填再发）
  // ------------------------------------------------------------------

  /// 发一张图片。**需已上线**；[uid]（私聊）与 [gid]（群）二选一。
  ///
  /// 链路见 `lib/kernel/wlogin8/qq8_image.dart` 头注：本地探 md5/宽高/类型，
  /// 主 SSO 申请 fid/ticket/图床地址，另开 TCP 把数据传上去（服务端已有同
  /// md5 的图就跳过），最后把 fid 回填进元素走 [sendC2c]/[sendGroup]。
  ///
  /// [onProgress] 是 highway 上传进度（服务端按片确认时回调 0..1）。
  /// [asFace] 把图片当"动画表情"发（元素里的 29.1 / 34.1 标记）。
  Future<Qq8MsgSendResult> sendImage({
    required Uint8List bytes,
    int? uid,
    int? gid,
    bool asFace = false,
    void Function(double progress)? onProgress,
    Duration? uploadTimeout,
  }) async {
    final s = _requireOnline();
    if ((uid == null) == (gid == null)) {
      throw Qq8ImageException('sendImage 必须且只能给 uid（私聊）或 gid（群）之一');
    }
    final info = Qq8ImageProbe.probe(bytes);
    final targetUid = uid;
    final targetGid = gid;
    final dm = targetUid != null;
    _log.i('发图 ${dm ? '私聊 uid=$targetUid' : '群 gid=$targetGid'}：$info');

    // ① 申请：拿 fid / ticket / 图床地址（服务端已有该 md5 时会直接给 fid）
    final body = dm
        ? Qq8ImageUp.buildOffPicUpBody(
            uin: s.uin,
            uid: targetUid,
            images: <Qq8ImageInfo>[info],
            apkVersion: profile.versionCode,
          )
        : Qq8ImageUp.buildGroupPicUpBody(
            gid: targetGid!,
            uin: s.uin,
            images: <Qq8ImageInfo>[info],
            apkVersion: profile.versionCode,
          );
    final rsp = await s.sendUni(
      dm ? Qq8ImageUp.cmdOffPicUp : Qq8ImageUp.cmdGroupPicUp,
      body,
      timeout: timeout,
    );
    final replies = dm
        ? Qq8ImageUp.parseOffPicUpResponse(rsp.payload)
        : Qq8ImageUp.parseGroupPicUpResponse(rsp.payload);
    if (replies.isEmpty) {
      throw Qq8ImageException(
          '${dm ? 'OffPicUp' : 'GroupPicUp'} 申请没有回执（响应 ${rsp.payload.length} 字节）');
    }
    final r = replies.first;
    if (!r.ok) {
      throw Qq8ImageException(
          '${dm ? 'OffPicUp' : 'GroupPicUp'} 申请被拒：code=${r.code} ${r.message}');
    }
    _log.i('PicUp 回执：$r');

    // ② 传数据：服务端已有这张图（md5 命中）就跳过 —— 但 fid 仍然要换
    if (r.alreadyExists) {
      _log.i('服务端已有该图（md5 命中），跳过 highway 上传');
      onProgress?.call(1);
    } else {
      final host = r.host;
      final port = r.port;
      if (host == null || port == null || r.ticket.isEmpty) {
        throw Qq8ImageException('PicUp 回执缺图床地址或凭证'
            '（host=$host port=$port ticket=${r.ticket.length}B）');
      }
      await Qq8Highway.upload(
        host: host,
        port: port,
        uin: '${s.uin}',
        appid: profile.apk.subid,
        buCmdId: dm ? Qq8Highway.cmdIdDmImage : Qq8Highway.cmdIdGroupImage,
        ticket: r.ticket,
        fileMd5: info.md5,
        data: bytes,
        timeout: uploadTimeout ?? const Duration(seconds: 120),
        onProgress: onProgress,
      );
      _log.i('highway 上传完成：${bytes.length} 字节 → $host:$port');
    }

    // ③ 回填 fid 后照常发消息
    final elem = dm
        ? Qq8ImageElems.dm(info: info, fid: r.fid, asFace: asFace)
        : Qq8ImageElems.group(info: info, fid: r.fid, asFace: asFace);
    return dm
        ? sendC2c(uid: targetUid, elems: <Uint8List>[elem])
        : sendGroup(gid: targetGid!, elems: <Uint8List>[elem]);
  }

  // ------------------------------------------------------------------
  // 收消息的"主动取"：拉新消息 / 私聊历史 / 群历史
  // ------------------------------------------------------------------

  /// 拉新消息（`MessageSvc.PbGetMsg`）。**需已上线**。
  ///
  /// 首次用空 cookie，之后自动带上上一次响应里的 `sync_cookie`（服务端靠它
  /// 增量同步）——`PushNotify` 之后要做的"去拉"就是调它。
  Future<Qq8GetMsgPage> pullMessages() async {
    final s = _requireOnline();
    final frame = await s.sendUni(
      Qq8History.cmdGetMsg,
      Qq8History.buildGetMsgBody(syncCookie: _syncCookie),
      timeout: timeout,
    );
    final page = Qq8History.parseGetMsg(frame.payload);
    if (page.syncCookie != null && page.syncCookie!.isNotEmpty) {
      _syncCookie = page.syncCookie;
    }
    _log.i('拉新消息 result=${page.result} 会话块=${page.blocks.length} '
        '消息=${page.messages.length}');
    return page;
  }

  /// 私聊历史（`MessageSvc.PbGetOneDayRoamMsg`，按时间往前翻页）。**需已上线**。
  ///
  /// [before] 是翻页游标（服务端时间，单位**秒**，与 `msg_time` 同）；
  /// 不传则从当前时间往前。[count] 上限 20（官方与参考实现都是这个上限）。
  Future<Qq8HistoryPage> fetchC2cHistory({
    required int peerUin,
    int? before,
    int count = 20,
  }) async {
    final s = _requireOnline();
    final frame = await s.sendUni(
      Qq8History.cmdOneDayRoam,
      Qq8History.buildOneDayRoamBody(
        peerUin: peerUin,
        lastMsgTime: before ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000),
        readCnt: count > 20 ? 20 : count,
      ),
      timeout: timeout,
    );
    final page = Qq8History.parseOneDayRoam(frame.payload);
    _log.i('私聊历史 peer=$peerUin result=${page.result} '
        '条数=${page.messages.length} 到头=${page.isComplete}');
    return page;
  }

  /// 群历史（`MessageSvc.PbGetGroupMsg`，按 seq 区间取）。**需已上线**。
  Future<Qq8HistoryPage> fetchGroupHistory({
    required int groupCode,
    required int beginSeq,
    required int endSeq,
  }) async {
    final s = _requireOnline();
    final frame = await s.sendUni(
      Qq8History.cmdGetGroupMsg,
      Qq8History.buildGroupMsgBody(
        groupCode: groupCode,
        beginSeq: beginSeq,
        endSeq: endSeq,
      ),
      timeout: timeout,
    );
    final page = Qq8History.parseGroupMsg(frame.payload);
    _log.i('群历史 gid=$groupCode seq=$beginSeq-$endSeq result=${page.result} '
        '条数=${page.messages.length}');
    return page;
  }

  /// 好友列表（含分组，服务端分页自动翻完）。**需已上线**。
  ///
  /// [pageSize] 是每页条数（参考实现 150）；翻页条件是"已取条数 < 总数"，
  /// 另设 [maxPages] 上限，防止总数异常时死循环。
  Future<Qq8FriendListPage> fetchFriendList({
    int pageSize = 150,
    int maxPages = 50,
  }) async {
    final s = _requireOnline();
    final uin = s.uin;
    final friends = <Qq8Friend>[];
    var classes = const <Qq8FriendClass>[];
    var total = 0;
    var result = 0;
    var start = 0;
    var pages = 0;
    while (true) {
      final frame = await s.sendUni(
        Qq8List.cmdFriendList,
        Qq8List.buildFriendListBody(
          uin: uin,
          startIndex: start,
          count: pageSize,
        ),
        timeout: timeout,
      );
      final page = Qq8List.parseFriendList(frame.payload);
      result = page.result;
      if (!page.ok) {
        _log.w('好友列表第 ${pages + 1} 页失败：result=${page.result}');
        break;
      }
      classes = page.classes;
      total = page.total;
      friends.addAll(page.friends);
      pages++;
      start += pageSize;
      if (start >= total || friends.length >= total || pages >= maxPages) break;
    }
    _log.i('好友列表：${friends.length}/$total 人、${classes.length} 个分组'
        '（$pages 页，result=$result）');
    return Qq8FriendListPage(
      result: result,
      total: total,
      friends: friends,
      classes: classes,
    );
  }

  /// 群列表。**需已上线**。
  Future<Qq8GroupListPage> fetchGroupList() async {
    final s = _requireOnline();
    final frame = await s.sendUni(
      Qq8List.cmdGroupList,
      Qq8List.buildGroupListBody(uin: s.uin),
      timeout: timeout,
    );
    final page = Qq8List.parseGroupList(frame.payload);
    _log.i('群列表：${page.groups.length}/${page.total} 个群'
        '（result=${page.result}）');
    return page;
  }

  // ------------------------------------------------------------------
  // 撤回与已读上报（`PbMessageSvc.PbMsgWithDraw` / `PbMsgReadedReport`）
  // ------------------------------------------------------------------

  /// 撤回自己发的一条私聊消息。**需已上线**。
  ///
  /// [seq]/[rand]/[time] 用消息 ID 反解（见 `Qq8Msg.parseDmMessageId`）。
  /// 返回 `(result, errmsg)`；参考实现的成功判据是 `result <= 2`（见内核注释）。
  Future<({int result, String errmsg})> withdrawC2c({
    required int peerUin,
    required int seq,
    required int rand,
    required int time,
  }) async {
    final s = _requireOnline();
    final frame = await s.sendUni(
      Qq8Msg.withdrawCmd,
      Qq8Msg.buildC2cWithdrawBody(
        selfUin: s.uin,
        peerUin: peerUin,
        seq: seq,
        rand: rand,
        time: time,
      ),
      timeout: timeout,
    );
    final r = Qq8Msg.parseWithdrawResponse(frame.payload, group: false);
    _log.i('私聊撤回 peer=$peerUin seq=$seq result=${r.result} ${r.errmsg}');
    return r;
  }

  /// 撤回自己发的一条群消息（单包）。**需已上线**。
  Future<({int result, String errmsg})> withdrawGroup({
    required int gid,
    required int seq,
    required int rand,
  }) async {
    final s = _requireOnline();
    final frame = await s.sendUni(
      Qq8Msg.withdrawCmd,
      Qq8Msg.buildGroupWithdrawBody(gid: gid, seq: seq, rand: rand),
      timeout: timeout,
    );
    final r = Qq8Msg.parseWithdrawResponse(frame.payload, group: true);
    _log.i('群撤回 gid=$gid seq=$seq result=${r.result} ${r.errmsg}');
    return r;
  }

  /// 私聊已读上报（告诉服务端"这个会话读到 [lastReadTime]"）。**需已上线**。
  Future<void> reportC2cRead({
    required int peerUin,
    required int lastReadTime,
  }) async {
    final s = _requireOnline();
    await s.sendUni(
      Qq8Msg.readedReportCmd,
      Qq8Msg.buildC2cReadReportBody(
          peerUin: peerUin, lastReadTime: lastReadTime),
      timeout: timeout,
    );
  }

  /// 群已读上报（读到 [lastReadSeq]）。**需已上线**。
  Future<void> reportGroupRead({
    required int gid,
    required int lastReadSeq,
  }) async {
    final s = _requireOnline();
    await s.sendUni(
      Qq8Msg.readedReportCmd,
      Qq8Msg.buildGroupReadReportBody(gid: gid, lastReadSeq: lastReadSeq),
      timeout: timeout,
    );
  }

  /// 群成员列表（服务端分页自动翻完）。**需已上线**。
  ///
  /// [maxPages] 是防死循环的上限（参考实现用 `nextUin` 是否非 0 判断结束）。
  /// 成员里**没有"群主"标志位**——要判群主请拿 [Qq8Group.ownerUin] 比。
  Future<Qq8GroupMemberPage> fetchGroupMembers(
    int gid, {
    int maxPages = 20,
  }) async {
    final s = _requireOnline();
    final members = <Qq8GroupMember>[];
    var next = 0;
    var result = 0;
    var pages = 0;
    while (true) {
      final frame = await s.sendUni(
        Qq8List.cmdGroupMemberList,
        Qq8List.buildGroupMemberListBody(uin: s.uin, gid: gid, nextUin: next),
        timeout: timeout,
      );
      final page = Qq8List.parseGroupMemberList(frame.payload);
      result = page.result;
      if (!page.ok) {
        _log.w('群成员列表第 ${pages + 1} 页失败：result=$result');
        break;
      }
      members.addAll(page.members);
      next = page.nextUin;
      pages++;
      if (next == 0 || pages >= maxPages) break;
    }
    _log.i('群成员列表 gid=$gid：${members.length} 人（$pages 页，result=$result）');
    return Qq8GroupMemberPage(result: result, nextUin: next, members: members);
  }

  /// 会话标识（4 字节）当 u32 用——同步 cookie 的 seed（参考实现同款）。
  int _sessionSeedU32() {
    final id = _sessionId;
    if (id == null || id.length < 4) return 0;
    return ((id[0] << 24) | (id[1] << 16) | (id[2] << 8) | id[3]) & 0xFFFFFFFF;
  }

  // ------------------------------------------------------------------
  // 二维码扫码登录
  // ------------------------------------------------------------------

  /// 取二维码（`wtlogin.trans_emp` / code2d 0x31）。
  ///
  /// 成功后状态为 [Qq8LoginStage.waitingQrScan]，二维码内容在
  /// [Qq8LoginSnapshot.qrToken]（UI 拿去渲染）；此后由调用方按秒级节奏调
  /// [pollQrcode]（参考实现也是轮询，本层不自己起定时器——节奏归 UI/上层）。
  ///
  /// [expectedUin] 传非 0 时会校验"扫出来的账号就是它"；传 0 则采用扫码账号。
  Future<void> fetchQrcode({int expectedUin = 0}) async {
    if (!_passGate()) return;
    _emit(const Qq8LoginSnapshot(stage: Qq8LoginStage.connecting));
    try {
      _expectedUin = expectedUin;
      // 取码发生在"还不知道账号"之前，所以设备用 expectedUin（默认 0）派生；
      // 扫码确认后会按扫出来的账号**重新派生**，保证同一账号恒定同一台设备。
      _device = (deviceBuilder ?? Qq8Device.generate)(expectedUin);
      _ecdh = (ecdhBuilder ??
          () => Ecdh.exchange(Uint8List.fromList(Qq8Config.serverEcdhPublicKey)))();
      _sessionId = _randomBytes(4);
      _randomKey = _randomBytes(16);

      final watch = qq8ApkWatch;
      final ctx = _tlvCtx(expectedUin, passwordMd5: null, token: null);
      final body = Qq8Qrcode.buildFetchBody(ctx, watch);
      final tran = _tran ??= transportBuilder();
      await tran.connect();
      final frame = await tran.send(
        _code2dPacket(ctx, expectedUin, watch, Qq8Qrcode.cmdFetch,
            Qq8Qrcode.headFetch, body),
        timeout: timeout,
      );
      final sso = qq8UnwrapRecv(frame);
      onDiagnostic?.call('fetch', frame, null);
      final r = Qq8Qrcode.parseFetch(sso.payload, _ecdh!.shareKey);
      if (!r.ok) {
        _emit(Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed,
          error: '获取二维码失败（retcode=${r.retcode}），请重试',
        ));
        return;
      }
      _qrsig = r.qrsig;
      _qrToken = r.qrToken;
      _emit(Qq8LoginSnapshot(
        stage: Qq8LoginStage.waitingQrScan,
        qrToken: r.qrToken,
        qrMessage: '请用手机 QQ 扫码',
      ));
    } on Object catch (e, st) {
      _fail('取二维码失败', e, st);
    }
  }

  /// 轮询一次扫码状态（code2d 0x12）。扫到并确认后会自动发二维码登录请求。
  ///
  /// 返回后看 [snapshot]：仍是 [Qq8LoginStage.waitingQrScan] = 继续轮询；
  /// [Qq8LoginStage.online] = 成功；[Qq8LoginStage.failed] = 超时/取消/出错。
  Future<void> pollQrcode() async {
    if (!_passGate()) return;
    final qrsig = _qrsig;
    if (qrsig == null || qrsig.isEmpty) {
      _emit(const Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed, error: '还没有取二维码，无法轮询'));
      return;
    }
    try {
      final watch = qq8ApkWatch;
      final ctx = _tlvCtx(_expectedUin, passwordMd5: null, token: null);
      final body = Qq8Qrcode.buildQueryBody(qrsig);
      final tran = _tran ??= transportBuilder();
      await tran.connect();
      final frame = await tran.send(
        _code2dPacket(ctx, _expectedUin, watch, Qq8Qrcode.cmdQuery,
            Qq8Qrcode.headQuery, body),
        timeout: timeout,
      );
      final sso = qq8UnwrapRecv(frame);
      onDiagnostic?.call('poll', frame, null);
      final q = Qq8Qrcode.parseQuery(sso.payload, _ecdh!.shareKey);

      if (!q.confirmed) {
        final terminal = q.retcode == Qq8QrcodeResult.timeout ||
            q.retcode == Qq8QrcodeResult.canceled;
        if (terminal) _qrsig = null;
        _emit(Qq8LoginSnapshot(
          stage: terminal ? Qq8LoginStage.failed : Qq8LoginStage.waitingQrScan,
          qrToken: terminal ? null : _qrToken,
          qrMessage: q.message,
          error: terminal ? q.message : null,
        ));
        return;
      }

      // 已确认：先校验账号，再按扫码账号重建设备（tgtgt 用扫到的那个——
      // 成功响应的 0x119 就是用它加密的）。
      final uin = q.uin ?? 0;
      if (_expectedUin != 0 && uin != _expectedUin) {
        _emit(Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed,
          uin: uin,
          error: '扫码账号（$uin）与预期账号（$_expectedUin）不符',
        ));
        return;
      }
      _device = (deviceBuilder ?? Qq8Device.generate)(uin).withTgtgt(q.tgtgt!);
      _qrsig = null;
      _qrToken = null;

      final loginCtx = _tlvCtx(uin, passwordMd5: null, token: null);
      final body2 = Qq8LoginBody.buildQrLogin(
        loginCtx,
        t106: q.t106!,
        t16a: q.t16a!,
        t318: q.t318!,
      );
      await _sendLoginBody(uin, loginCtx, body2);
    } on Object catch (e, st) {
      _fail('轮询扫码状态失败', e, st);
    }
  }

  /// code2d 包：信封里 uin=0、OICQ 命令字 0x812、SSO 头 subid 用手表档案。
  Uint8List _code2dPacket(
    Qq8TlvContext tlvCtx,
    int uin,
    Qq8ApkInfo watch,
    int cmdid,
    int head,
    Uint8List body,
  ) {
    final ssoCtx = Qq8SsoContext(
      uin: uin,
      apk: profile.apk,
      device: _device!,
      sessionId: _sessionId!,
      randomKey: _randomKey!,
      ecdhPublicKey: _ecdh!.publicKey,
      ecdhShareKey: _ecdh!.shareKey,
      sig: Qq8SigInfo(),
      seqId: DateTime.now().millisecondsSinceEpoch & 0x7FFF,
    );
    return Qq8Qrcode.buildPacket(
      ssoCtx,
      cmdid,
      head,
      body,
      watch: watch,
      // code2d 内层的 timestamp 是**秒**（参考实现 timestamp() = 秒）
      timestampSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  /// 结束会话（停心跳、关连接）。之后要再用就重新登录。
  Future<void> close() async {
    await _pushSub?.cancel();
    _pushSub = null;
    await _session?.close();
    _session = null;
    try {
      await _tran?.close();
    } on Object {
      // 关闭失败无需上报
    }
    _tran = null;
    _emit(const Qq8LoginSnapshot(stage: Qq8LoginStage.idle));
    await _states.close();
    await _events.close();
  }

  /// 收推送：解析成事件；被踢下线要改状态（否则 UI 一直以为还在线）。
  void _onPush(Qq8SsoResponse r) {
    Qq8PushEvent ev;
    try {
      ev = qq8ParsePush(r.cmd, r.payload);
    } on Object catch (e) {
      _log.w('推送解析失败 cmd=${r.cmd}', error: e);
      return;
    }
    final uin = _snapshot.uin;
    switch (ev) {
      case Qq8MessagePush(:final message):
        _log.i('收到消息 ${message.brief()}');
      case Qq8KickPush(:final hint):
        _log.w('被服务端踢下线：$hint');
        _emit(Qq8LoginSnapshot(
          stage: Qq8LoginStage.disconnected,
          uin: uin,
          error: hint.isEmpty ? '被服务端踢下线' : hint,
        ));
      case Qq8NotifyPush(:final notifyType):
        _log.i('有新消息通知（type=$notifyType），去拉一次');
        // notifyType 可能是 null（畸形包）——那就只记日志，不猜
        if (notifyType != null) unawaited(_pullAfterNotify(notifyType));
      case Qq8UnknownPush(:final cmd, :final note):
        _log.d('未处理的推送 cmd=$cmd${note == null ? '' : '（$note）'}');
    }
    // 回执：多端同步 / 讨论组的推送要告诉服务端"收到了"，否则会被反复重推。
    // 参考实现只在处理成功后回，这里也一样（解析失败上面就 return 了）。
    if (ev is Qq8MessagePush && ev.needsAck) {
      unawaited(_ackPush(ev, r.seq));
    }
    if (!_events.isClosed) _events.add(ev);
  }

  /// 哪些"有新消息"的通知类型要触发一次 `PbGetMsg` 拉取。
  ///
  /// 照参考实现 `pushNotifyListener` 的 switch：33 群员入群 / 38 建群 /
  /// 85 群申请被同意 / 141 陌生人 / 166 好友 / 167 单向好友 / 208 好友语音 /
  /// 529 离线文件——这些**服务端只发通知不发内容**，不拉就真的收不到。
  /// 其余类型（84/87/525 群请求、187/191 好友请求、528 黑名单）要各自的命令字，
  /// 属于"好友申请/群申请"那条线，我们还没做（见 project-remaining-blocked）。
  static const Set<int> _notifyPullTypes = <int>{
    33, 38, 85, 141, 166, 167, 208, 529,
  };

  /// 收到"有新消息"通知后主动拉一次；拉回来的消息**复用推送那条流水线**
  /// （发一条 `Qq8MessagePush` 事件），这样去重、建会话、未读计数全走同一套逻辑。
  Future<void> _pullAfterNotify(int notifyType) async {
    if (!_notifyPullTypes.contains(notifyType)) return;
    if (_session == null) return;
    try {
      final page = await pullMessages();
      for (final m in page.messages) {
        if (_events.isClosed) return;
        _events.add(Qq8MessagePush(
          Qq8PushCmd.notify,
          message: m,
          needsAck: false,
        ));
      }
    } on Object catch (e) {
      // 拉取失败不致命：下次通知还会再来，打开会话时也会补拉
      _log.w('通知触发的拉取失败（type=$notifyType）', error: e);
    }
  }

  /// 推送回执（`OnlinePush.RespPush`）。失败只记日志：回执丢了顶多被重推，
  /// 不该因为回执失败把消息流打断。
  Future<void> _ackPush(Qq8MessagePush ev, int seq) async {
    final s = _session;
    final uin = _snapshot.uin;
    if (s == null || uin == null) return;
    try {
      final body = Qq8Msg.buildRespPushAck(
        uin: uin,
        svrip: ev.svrip ?? 0,
        seq: seq,
      );
      await s.sendUni(Qq8Msg.respPushCmd, body, seq: seq, timeout: timeout);
    } on Object catch (e) {
      _log.d('推送回执发送失败（$seq）', error: e);
    }
  }

  // ------------------------------------------------------------------
  // 内部：收发包与分支
  // ------------------------------------------------------------------

  Qq8TlvContext _tlvCtx(
    int uin, {
    required Uint8List? passwordMd5,
    required Qq8TokenData? token,
    bool smsLogin = false,
  }) {
    final device = _device!;
    return Qq8TlvContext(
      uin: uin,
      apk: profile.apk,
      device: device,
      passwordMd5: passwordMd5 ?? Uint8List(16),
      seqId: DateTime.now().millisecondsSinceEpoch & 0x7FFF,
      ksid: Uint8List.fromList(
          utf8.encode('|${device.imei}|${profile.apk.name}')),
      t104: _t104,
      t174: _t174,
      tgt: token?.tgt ?? Uint8List(0),
      srmToken: Uint8List(0),
      t547: _t547,
      // 维护版 oicq v1.26.25：密码首登包带客户端自构造 PoW（0x548）；
      // token 续期与手机号短信那条线不发。滑块提交走 buildSlider（清单里没有 548）。
      t548: (token == null && !smsLogin && profile.apk.ssoVer > 12)
          ? qq8BuildClientPow548().body
          : null,
      // 短信登录那次：盐用流程里拿到的 msalt（0x106 密钥种子 / 0x184 都用它），
      // 登录类型 3，账号串写手机号。
      msalt: smsLogin ? _smsMsalt : 0,
      loginType: smsLogin ? 3 : 1,
      account: smsLogin ? _smsPhone : null,
    );
  }

  /// 组三层信封 → 发送 → 拆壳 → 判读分支。
  Future<void> _sendLoginBody(
    int uin,
    Qq8TlvContext ctx,
    Uint8List body, {
    Qq8TokenData? token,
    _SmsStep? smsStep,
  }) async {
    if (!_passGate()) return;
    final ecdh = _ecdh!;
    final tran = _tran ??= transportBuilder();
    await tran.connect();

    // token 续期时票据要贯穿三层：SSO 信封的 tgt/d2（sig）、body 的 0x143。
    final sigInfo = token == null
        ? Qq8SigInfo()
        : Qq8SigInfo(
            tgt: token.tgt,
            d2: token.d2,
            d2key: token.d2key,
            sigKey: token.sigKey,
            ticketKey: token.ticketKey,
            srmToken: token.srmToken,
          );
    final ssoCtx = Qq8SsoContext(
      uin: uin,
      apk: profile.apk,
      device: _device!,
      sessionId: _sessionId!,
      randomKey: _randomKey!,
      ecdhPublicKey: ecdh.publicKey,
      ecdhShareKey: ecdh.shareKey,
      sig: sigInfo,
      seqId: DateTime.now().millisecondsSinceEpoch & 0x7FFF,
    );
    final cmd = token == null ? qq8LoginCmd : qq8ExchangeEmpCmd;
    final pkt = Qq8Sso.buildLoginPacket(
      ssoCtx,
      cmd,
      Qq8Sso.buildOicqPacket(ssoCtx, body),
      Qq8LoginType.login,
    );

    final frame = await tran.send(pkt, timeout: timeout);
    final sso = qq8UnwrapRecv(frame);
    late final Qq8LoginResponse r;
    try {
      r = Qq8LoginResponse.parse(sso.payload, ecdh.shareKey);
    } on Object {
      onDiagnostic?.call(token == null ? 'login' : 'token', frame, null);
      rethrow;
    }
    onDiagnostic?.call(token == null ? 'login' : 'token', frame, r);
    _log.i('登录响应 type=${r.type} '
        '${r.tlvs.keys.map((t) => '0x${t.toRadixString(16)}').join(',')}');
    await _handleResponse(uin, r, smsStep: smsStep);
  }

  /// 手机号短信登录三步各自的响应判读。
  Future<void> _handleSmsResponse(
      int uin, Qq8LoginResponse r, _SmsStep step) async {
    // 208 / 232：中间态，带回下一步要用的材料
    if (r.isSmsLoginStep) {
      final salt = r.smsLoginSalt;
      if (salt != null && salt.isNotEmpty) _t104 = salt;
      final random = r.smsLoginRandom;
      if (random != null && random.isNotEmpty) _smsRandom = random;
      final msalt = r.smsLoginMsalt;
      if (msalt != null) _smsMsalt = msalt;
      final limits = r.smsLoginLimits;
      if (limits != null) {
        _smsMsgCnt = limits.msgCnt;
        _smsTimeLimit = limits.timeLimit;
      }
      _log.i('短信登录 ${step.name}：type=${r.type} '
          '盐=${_t104.length}B random=${_smsRandom?.length}B msalt=$_smsMsalt '
          '次数=$_smsMsgCnt 时限=$_smsTimeLimit s');
      _emit(Qq8LoginSnapshot(
        stage: Qq8LoginStage.needsSmsCode,
        uin: _snapshot.uin,
        phone: r.smsLoginPhoneHint ?? _smsPhone,
        // 检查那一步（208）服务端还没发短信；下发那一步（232）才发。
        smsAutoSent: step == _SmsStep.refresh,
        smsFlow: true,
      ));
      return;
    }

    // 提交验证码（18）的"成功"：**没有票据**，只给 uin/msalt/新盐，
    // 还要再用 mpasswd 走一次子命令 9（官方 GetStViaSMSVerifyLogin 同款）。
    if (step == _SmsStep.verify && r.isSuccess) {
      final salt = r.smsLoginSalt;
      if (salt != null && salt.isNotEmpty) _t104 = salt;
      final msalt = r.smsLoginMsalt;
      if (msalt != null) _smsMsalt = msalt;
      final resolved = r.uinHint;
      final mpasswd = _smsMpasswd;
      if (resolved == null || resolved == 0 || mpasswd == null) {
        _emit(Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed,
          uin: _snapshot.uin,
          error: resolved == null || resolved == 0
              ? '验证码已通过，但响应里没有 uin（0x113），无法继续登录'
              : '验证码已通过，但本地缺少口令材料（mpasswd），无法继续登录',
        ));
        return;
      }
      _log.i('短信验证码通过：uin=$resolved，接着用 mpasswd 走一次口令登录');
      await _login(
        uin: resolved,
        passwordMd5: md5Bytes(Uint8List.fromList(utf8.encode(mpasswd))),
        smsLogin: true,
      );
      return;
    }

    // 其它情况：能读到服务端文案就显示文案，否则带上步骤和返回码
    final msg = r.serverMessage;
    final text = msg != null
        ? '${msg.$1}：${msg.$2}'
        : '短信登录（${step.name}）未通过（服务端返回 type=${r.type}）';
    _emit(Qq8LoginSnapshot(
        stage: Qq8LoginStage.failed, uin: _snapshot.uin, error: text.trim()));
  }

  Future<void> _handleResponse(int uin, Qq8LoginResponse r,
      {_SmsStep? smsStep}) async {
    if (smsStep != null) {
      await _handleSmsResponse(uin, r, smsStep);
      return;
    }

    // 成功：解票据 → 存 → 上线
    if (r.isSuccess) {
      final t119 = r.t119;
      if (t119 == null) {
        _emit(Qq8LoginSnapshot(
            stage: Qq8LoginStage.failed, uin: uin, error: '成功响应里没有票据块（0x119）'));
        return;
      }
      final bundle = Qq8SigBundle.parse(t119, _device!.tgtgt);
      _sig = bundle;
      await tokenStore.save(Qq8TokenData.fromSigBundle(uin, bundle));
      // 成功之后清掉验证材料，避免下一次登录误用
      _t104 = Uint8List(0);
      _t174 = Uint8List(0);
      _t547 = null;
      _sliderUrl = null;
      _smsPhone = null;
      _smsRandom = null;
      _smsMsalt = 0;
      _smsMpasswd = null;
      _smsMsgCnt = null;
      _smsTimeLimit = null;
      await _goOnline(uin, bundle);
      return;
    }

    // 滑动验证（服务端也可能借这条渠道发短信/其它验证页）
    if (r.needsSlider) {
      _t104 = r.tlvs[0x104] ?? Uint8List(0);
      _sliderUrl = r.sliderUrl;
      final challenge = r.tlvs[0x546];
      if (challenge != null && challenge.isNotEmpty) {
        final ans = qq8SolvePow(challenge);
        _t547 = ans?.body;
        _log.i('防刷题: ${ans == null ? '未解出' : '${ans.iterations} 次迭代'}');
      } else {
        _t547 = null;
      }
      _emit(Qq8LoginSnapshot(
        stage: Qq8LoginStage.needsSlider,
        uin: uin,
        sliderUrl: _sliderUrl,
      ));
      return;
    }

    // 短信码验证
    if (r.needsSmsVerify) {
      _t104 = r.tlvs[0x104] ?? Uint8List(0);
      _t174 = r.verifyToken ?? Uint8List(0);
      final autoSent = r.tlvs[0x204] == null && _t174.isEmpty;
      if (_t104.isEmpty || _t174.isEmpty) {
        _emit(Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed,
          uin: uin,
          error: '短信验证响应缺少盐或令牌（0x104/0x174），无法继续',
        ));
        return;
      }
      _emit(Qq8LoginSnapshot(
        stage: Qq8LoginStage.needsSmsCode,
        uin: uin,
        phone: r.verifyPhone,
        smsAutoSent: autoSent,
      ));
      return;
    }

    // 设备锁
    if (r.needsDeviceLock) {
      _t104 = r.tlvs[0x104] ?? Uint8List(0);
      if (_t104.isEmpty) {
        _emit(Qq8LoginSnapshot(
            stage: Qq8LoginStage.failed, uin: uin, error: '设备锁响应缺少盐（0x104）'));
        return;
      }
      _emit(Qq8LoginSnapshot(
        stage: Qq8LoginStage.needsDeviceLock,
        uin: uin,
        deviceLockHint: r.deviceLockHint,
      ));
      return;
    }

    // 其它：能读到服务端文案就显示文案，否则显示返回码
    final msg = r.serverMessage;
    final text = msg == null
        ? '登录未通过（服务端返回 type=${r.type}）'
        : '${msg.$1}：${msg.$2}';
    _emit(Qq8LoginSnapshot(
        stage: Qq8LoginStage.failed, uin: uin, error: text.trim()));
  }

  /// 注册上线 + 起心跳；成功则进入 [Qq8LoginStage.online]。
  Future<void> _goOnline(int uin, Qq8SigBundle bundle) async {
    final tran = _tran!;
    final session = Qq8Session(
      transport: tran,
      profile: profile,
      uin: uin,
      device: _device!,
      sessionId: _sessionId!,
      ecdhPublicKey: _ecdh!.publicKey,
      ecdhShareKey: _ecdh!.shareKey,
      sig: Qq8SigInfo(
        tgt: bundle.tgt ?? Uint8List(0),
        d2: bundle.d2 ?? Uint8List(0),
        d2key: bundle.d2key ?? Uint8List(0),
        sigKey: bundle.sigKey ?? Uint8List(0),
        ticketKey: bundle.ticketKey ?? Uint8List(0),
        srmToken: bundle.srmToken ?? Uint8List(0),
      ),
      randomKey: _randomKey!,
    )..onError = (e) => _log.w('收包解析失败', error: e);
    // 掉线必须让上层看见：会话层心跳连败两次会回调这里，UI 才能提示"已断开"。
    // 曾在真机前漏掉这条线——服务一直是 online，用户却什么都收不到。
    session.onOffline = () {
      _log.w('心跳连续失败，连接已断开');
      _emit(Qq8LoginSnapshot(
        stage: Qq8LoginStage.disconnected,
        uin: uin,
        error: '连接已断开（心跳连续失败），可重新登录或重连',
      ));
    };
    _session = session;
    _pushSub?.cancel();
    _pushSub = session.pushes.listen(
      _onPush,
      onError: (Object e) => _log.w('推送流出错', error: e),
    );
    await session.start();

    final ok = await session.register();
    if (!ok) {
      _emit(Qq8LoginSnapshot(
        stage: Qq8LoginStage.failed,
        uin: uin,
        error: '登录已通过，但上线注册被拒（票据或设备信息不符）',
      ));
      return;
    }
    session.startHeartbeat(interval: heartbeatInterval);
    _emit(Qq8LoginSnapshot(stage: Qq8LoginStage.online, uin: uin));
    _log.i('已上线 uin=$uin');
  }

  void _fail(String what, Object e, StackTrace st) {
    _log.e(what, error: e, stack: st);
    _emit(Qq8LoginSnapshot(
      stage: Qq8LoginStage.failed,
      uin: _snapshot.uin,
      error: '$what：$e',
    ));
  }

  void _emit(Qq8LoginSnapshot s) {
    _snapshot = s;
    if (!_states.isClosed) _states.add(s);
  }
}

/// 手机号短信登录的中间材料：**第 1 段跑完导出、第 2 段导入**。
///
/// 为什么要有它：检查（17）和提交（18）之间隔着"人去看短信"——在命令行工具
/// 里就是两次进程。盐/随机数/msalt 都只活在服务实例的内存里，不导出就只能
/// 从头再来（那会多发一条短信、多一次风控痕迹）。
class Qq8SmsLoginState {
  /// 用户输入的手机号（17/18 都要带）。
  final String phone;

  /// `0x104` 盐（19/18 要原样回带）。
  final Uint8List salt;

  /// `0x126` 随机数（进 18 的 `0x127`）。
  final Uint8List random;

  /// `0x183` msalt（进 18 的 `0x184`，也是之后那次登录的盐）。
  final int msalt;

  /// `0x182` 已下发次数上限 / 有效期（展示用，可为 null）。
  final int? msgCnt;
  final int? timeLimit;

  /// 服务端提示的号码（`0x52B`，展示用，可为 null）。
  final String? hintPhone;

  const Qq8SmsLoginState({
    required this.phone,
    required this.salt,
    required this.random,
    required this.msalt,
    this.msgCnt,
    this.timeLimit,
    this.hintPhone,
  });

  static String _hex(List<int> b) =>
      b.map((v) => (v & 0xff).toRadixString(16).padLeft(2, '0')).join();

  static Uint8List? _unhex(Object? v) {
    if (v is! String || v.isEmpty || v.length.isOdd) return null;
    final out = Uint8List(v.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final b = int.tryParse(v.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return null;
      out[i] = b;
    }
    return out;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'phone': phone,
        't104': _hex(salt),
        't126': _hex(random),
        'msalt': msalt,
        if (msgCnt != null) 'msg_cnt': msgCnt,
        if (timeLimit != null) 'time_limit': timeLimit,
        if (hintPhone != null) 'hint_phone': hintPhone,
      };

  /// 反序列化；缺关键字段（手机号/盐/随机数）时返回 null——**不猜**。
  static Qq8SmsLoginState? fromJson(Map<String, Object?> json) {
    final phone = json['phone'];
    final salt = _unhex(json['t104']);
    final random = _unhex(json['t126']);
    if (phone is! String || phone.isEmpty || salt == null || random == null) {
      return null;
    }
    return Qq8SmsLoginState(
      phone: phone,
      salt: salt,
      random: random,
      msalt: (json['msalt'] as num?)?.toInt() ?? 0,
      msgCnt: (json['msg_cnt'] as num?)?.toInt(),
      timeLimit: (json['time_limit'] as num?)?.toInt(),
      hintPhone: json['hint_phone'] as String?,
    );
  }
}

/// 手机号短信登录走到哪一步（决定响应怎么判读）。
enum _SmsStep {
  /// 子命令 17：检查手机号。
  check,

  /// 子命令 19：下发 / 刷新验证码。
  refresh,

  /// 子命令 18：提交验证码。
  verify,
}

/// 内存版票据存储（默认；进程退出即丢）。
class _MemoryTokenStore implements Qq8TokenStore {
  final Map<int, Qq8TokenData> _byUin = <int, Qq8TokenData>{};

  @override
  Future<Qq8TokenData?> load(int uin) async => _byUin[uin];

  @override
  Future<void> save(Qq8TokenData data) async => _byUin[data.uin] = data;

  @override
  Future<void> clear(int uin) async => _byUin.remove(uin);
}

int _randomU32() {
  final r = Random.secure();
  return ((r.nextInt(1 << 16) << 16) | r.nextInt(1 << 16)) & 0xFFFFFFFF;
}

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(n, (_) => r.nextInt(256), growable: false),
  );
}

/// 官方 `util.get_mpasswd()`：16 位随机**字母**串（大小写各半）。
///
/// 短信登录里它当"一次性口令"用：18 号请求把 `MD5(mpasswd) ‖ msalt` 的摘要
/// 交给服务端（0x184），随后那次子命令 9 就用 `MD5(mpasswd)` 当口令
/// （`WtloginHelper.java:1489` 的 `_tmp_pwd = MD5.toMD5Byte(str2)`）。
String _randomMpasswd() {
  final r = Random.secure();
  final sb = StringBuffer();
  for (var i = 0; i < 16; i++) {
    final upper = r.nextBool();
    sb.writeCharCode((upper ? 0x41 : 0x61) + r.nextInt(26));
  }
  return sb.toString();
}

