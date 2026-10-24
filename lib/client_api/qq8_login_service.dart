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
import '../kernel/wlogin8/qq8_protocol_det.dart';
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
  /// 测试注入固定夹具；真机身份材料也从这里接（`Qq8Device.fromIdentity`）。
  final Qq8Device Function(int uin)? deviceBuilder;

  /// 注入的 QIMEI（真机身份材料里的那个，36 字符）。
  ///
  /// 非空时进 TLV `0x545`（8.2.11 的 body = `MD5(它)`，16 字节）；为空则
  /// **整条不发**——这是官方行为（`k.java:383-393` 取不到就跳过），不是缺陷。
  /// App 侧由 `qq8DeviceIdentityProvider` 从身份文件读出来注入。
  final String? qimei;

  /// QIMEI **自动取号**接缝（灯塔 OLA 接口，见 `Qq8Qimei.fetch`）。
  ///
  /// 为什么不直接在本类里调 `Qq8Qimei.fetch`：那是联网动作，必须过 [gate]，
  /// 且要能被单测换成假实现（本项目的单测纪律是"不联网"）。所以只留接缝：
  /// **不注入这个函数就永远不取号**，沿用 [qimei] 字段。
  ///
  /// 取号只提交设备属性（**没有 uin、没有口令、没有票据**），不涉及账号；
  /// 返回 null / 抛异常都表示取不到 → 整条 `0x545` 不发（与官方一致）。
  /// 取到的号缓存在实例里，同一实例只取一次。
  ///
  /// 传入的 [Qq8Device] 是服务层本次登录用的那台——取号请求里的
  /// `androidId`/`guid` 必须与登录包一致，否则两者对不上（同一台设备）。
  final Future<String?> Function(Qq8Device device)? qimeiFetcher;

  /// 本次会话已取到的 QIMEI（[qimeiFetcher] 的结果；null = 没取/取不到）。
  String? _fetchedQimei;

  /// 设备身份状态的回写接缝：把**服务端下发的 ksid** 与**本次取到的 QIMEI**
  /// 交给上层落盘。
  ///
  /// ## 为什么必须是接缝而不是内部直接写文件
  ///
  /// 同 [qimeiFetcher]：L3 不该知道 App 数据目录在哪，也不该在自测里真写盘。
  /// 上层（`qq8_providers.dart`）接到 `qq8_device_store.dart` 的
  /// `FileQq8DeviceStore`。
  ///
  /// ## 不写会怎样
  ///
  /// `ksid` 是「服务端给一次、之后原样回带」的值（官方 `util.set_ksid` 只在
  /// SP 为空时写）。丢掉它 → 每次登录都自称没有 ksid → 每次都是一台新设备。
  /// 而它恰恰要登录**成功**才下发，于是形成死循环：
  /// 失败 → 没有 ksid → 更像新设备 → 失败。
  ///
  /// `qimei` 同理：每次启动都换号 = 设备标识漂移。
  final void Function({String? ksid, String? qimei})? deviceStateRecorder;

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

  /// 断线自动恢复的尝试次数与退避基数（每次翻倍：2s / 4s / 6s…）。
  ///
  /// 可变字段是给自测用的：测试把它们缩到毫秒级，不用真等几秒。
  /// 恢复只用票据续期（`loginWithToken`），**绝不用密码**——自动流程里
  /// 把口令再发一遍，等于向服务端呈现"无限重试爆破"的信号。
  int reconnectAttempts = 3;

  Duration reconnectBaseDelay = const Duration(seconds: 2);

  bool _reconnecting = false;
  /// 收消息兜底轮询（PushNotify 不可靠时的补拉）。
  Timer? _pullTimer;
  Qq8Session? _session;
  Qq8SigBundle? _sig;

  /// 增量拉消息的游标（`PbGetMsgResp.sync_cookie`，服务端靠它算增量）。
  Uint8List? _syncCookie;

  // 一次登录流程内固定的材料（与参考实现一致：同一客户端实例复用同一套）
  Qq8Device? _device;
  EcdhKeyPair? _ecdh;
  Uint8List? _sessionId;
  Uint8List? _randomKey;

  /// 一次登录流程共用的 SSO 序号。
  ///
  /// 官方 `WtloginHelper.CheckPictureAndGetSt` 用的是
  /// `wUserSigInfo._seqence`——与首包**同一个值**：真机日志
  /// `analysis/_ref/official-logs/wtlogin_20260919-b.txt:2911` 首包 `Seq:6`、
  /// `:3055` 滑块提交 `Seq:6`、`:3215` 完成 `Seq:6 ret=0`。
  /// `oicq` 侧同样是 `sig.seq` 自增一次后在同流程内复用。
  ///
  /// 原实现在 [_tlvCtx] 与 [_sendLoginBody] 里各取一次
  /// `DateTime.now().millisecondsSinceEpoch & 0x7FFF`，导致「登录包」与
  /// 「滑块提交包」的 seq 必然不同——服务端看到的是一次登录里两个互不
  /// 相干的会话。现状（真机 2026-10-22 18:42）：提交回 `type=16`
  /// 「你的用户身份已失效，为保证账号安全，请你重新登录」。
  int? _flowSeq;

  /// 取（或首次分配）本次登录流程的 SSO 序号。
  int get _seq => _flowSeq ??= DateTime.now().millisecondsSinceEpoch & 0x7FFF;

  // 上一条"要求验证"响应里带回来的材料
  Uint8List _t104 = Uint8List(0);
  Uint8List _t174 = Uint8List(0);
  Uint8List? _t547;
  String? _sliderUrl;

  /// 密码线短信验证的目标手机号（`0x178`）。
  ///
  /// 单独缓存的原因：「重新下发」的应答**不带 `0x178`**（号码没变），
  /// 不留一份就会让界面从「已发往 138****」退化成「绑定手机」。
  String? _verifyPhone;

  /// 二维码流程的中间态
  int _expectedUin = 0;
  Uint8List? _qrsig;
  Uint8List? _qrToken;

  /// 上一次轮询到的 retcode（只在**状态变化**时记一条日志，避免秒级刷屏）。
  int? _lastQrRetcode;

  // 手机号短信验证登录的中间态（三次请求跨调用保持）
  String? _smsPhone;
  Uint8List? _smsRandom;
  int _smsMsalt = 0;
  String? _smsMpasswd;
  int? _smsMsgCnt;
  int? _smsTimeLimit;

  /// TLV `0x525` 内嵌 `0x536` 的 body 构造接缝（官方 `ProtocolDet.getLoginExtraData`）。
  ///
  /// 官方这块数据是**历史登录出口 IP 缓存**（`files/pd2.dat`），每次登录成功后
  /// 追加一条，下次登录带上最近至多 3 条，供服务端判断「是不是常用出口」。
  /// 官方真机的密码登录**成功**样本（`qq8211/wtlogin_20260930.txt:375`）里
  /// 这内层是 65 字节（3 条）；我方此前恒发 `01 00`（0 条），等于每次都自称
  /// 全新环境。
  ///
  /// 留成接缝而不是在本类里直接读文件：本层是 `client_api`，不该知道 App 的
  /// 数据目录在哪（同 [qimeiFetcher] 的理由）。App 侧注入一个从磁盘读
  /// `pd2.dat` 的实现即可；不注入则退回官方的空形态 `01 00`。
  ///
  /// 编码用 `Qq8ProtocolDet.encode`，解码用 `Qq8ProtocolDet.decodeFile`。
  final Uint8List? Function()? protocolDetBuilder;

  /// 登录成功后把服务端下发的 `0x537` 记录落盘的接缝。
  ///
  /// 官方在同一位置（`oicq_request.java:1632`）调
  /// `ProtocolDet.setLoginExtraData`，满 3 条时替换最旧一条。
  /// 不注入就只打日志、不落盘。
  final void Function(Qq8ProtocolDetEntry entry)? protocolDetRecorder;

  Qq8LoginService({
    Qq8ClientProfile? profile,
    Qq8TokenStore? tokenStore,
    Qq8Transport Function()? transportBuilder,
    this.deviceBuilder,
    this.qimei,
    this.qimeiFetcher,
    this.deviceStateRecorder,
    this.protocolDetBuilder,
    this.protocolDetRecorder,
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
      return '要连接真实 QQ 服务器，需要先开启「真实服务器模式」：'
          '在页面上方的提示里做环境检测，并逐条确认风险点。';
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
        _flowSeq = null;
        // 新流程从零开始：上一条流程留下的盐/令牌不能带进来。
        // （密码→滑块→短信是同一条流程，只有这一层是流程起点；
        //  `smsLogin: true` 那次续跑要沿用刚拿到的盐与 mpasswd，故不在上面重置。）
        _t104 = Uint8List(0);
        _t174 = Uint8List(0);
        _t547 = null;
        _verifyPhone = null;
      }

      final ctx = _tlvCtx(uin, passwordMd5: passwordMd5, token: token, smsLogin: smsLogin);
      // QIMEI：优先用手工/身份文件注入的值；没有才去灯塔取号（只取一次）。
      // 取号失败不阻断登录——官方取不到 0x545 就整条不发（`k.java` case 1349）。
      final effectiveQimei = await _resolveQimei();
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
                      qimei: effectiveQimei,
                      t548: ctx.t548)
                  : Qq8LoginConditions(qimei: effectiveQimei, t548: ctx.t548),
              // 0x545 的 body 从 args 取（ctx 只做承载）；有 QIMEI 时才进包。
              args: <int, List<Object?>>{
                if (smsLogin) 0x112: <Object?>[_smsPhone],
                if (effectiveQimei != null) 0x545: <Object?>[effectiveQimei],
              },
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
      // 官方 `CheckPictureAndGetSt`（`WtloginHelper.java:2252`）把
      // `this.mMiscBitmap` **原值**交给 `n.a(...)`，不叠 `WLOGIN_DA2`；
      // 叠位只发生在密码首包 `GetStWithPasswd`（`:1415-1418`）。
      // 故这条包的 0x116 发 `0x08F7FF7C`（150470524）。
      final ctx = _tlvCtx(uin,
          passwordMd5: null, token: null, da2BitActive: false);
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

      _flowSeq = null;

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
    _flowSeq = null;
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
    // 群聊判据：只看 code（字段 14 不在群应答里，消息序号走推送回显）。
    final r = Qq8Msg.parseSendResponse(rsp.payload, seq: 0, rand: rand32, groupSend: true);
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

      _flowSeq = null;

      final watch = qq8ApkWatch;
      final ctx = _tlvCtx(expectedUin, passwordMd5: null, token: null);
      final body = Qq8Qrcode.buildFetchBody(ctx, watch);
      final tran = _tran ??= transportBuilder();
      await _connect(tran);
      final frame = await tran.send(
        _code2dPacket(ctx, expectedUin, watch, Qq8Qrcode.cmdFetch,
            Qq8Qrcode.headFetch, body),
        timeout: timeout,
      );
      final sso = qq8UnwrapRecv(frame);
      onDiagnostic?.call('fetch', frame, null);
      final r = Qq8Qrcode.parseFetch(sso.payload, _ecdh!.shareKey);
      // 扫码这条链走的是 code2d 命令（0x12），不经过 _sendLoginBody，所以那里的
      // "登录响应 type=… + 0x146 文案" 日志在这里不生效——真机上取码失败时
      // 什么都看不到（只有一个 retcode）。这里补一条，够判断"码是不是真码"。
      _log.i('取码响应 retcode=${r.retcode} ok=${r.ok} '
          'qrToken=${r.qrToken.length}字节 qrsig=${r.qrsig.length}字节');
      if (!r.ok) {
        _emit(Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed,
          error: '获取二维码失败（retcode=${r.retcode}），请重试',
        ));
        return;
      }
      _qrsig = r.qrsig;
      _qrToken = r.qrToken;
      _lastQrRetcode = null;
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
      await _connect(tran);
      final frame = await tran.send(
        _code2dPacket(ctx, _expectedUin, watch, Qq8Qrcode.cmdQuery,
            Qq8Qrcode.headQuery, body),
        timeout: timeout,
      );
      final sso = qq8UnwrapRecv(frame);
      onDiagnostic?.call('poll', frame, null);
      // 响应外壳偶有未知形态（2026-09-21 17:18：d2 长度解出 0x14000000 的乱值），
      // 此时把会话作废、引导重新取码，而不是把异常直接抛给 UI 卡死流程。
      final Qq8QrQuery q;
      try {
        q = Qq8Qrcode.parseQuery(sso.payload, _ecdh!.shareKey);
      } on Qq8LoginException catch (e) {
        _qrsig = null;
        _qrToken = null;
        _emit(Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed,
          error: '二维码状态响应解析异常（${e.message}），请重新获取二维码',
        ));
        return;
      }
      // 轮询是秒级的：只在 retcode **变了**时记一条。这条日志用来回答
      // "码是不是真码"——UP 主提醒过：mock 签名下服务端会 ret=0 但没真处理，
      // 所以还要看后面 register/心跳是否真的通。
      if (_lastQrRetcode != q.retcode) {
        _lastQrRetcode = q.retcode;
        _log.i('扫码轮询 retcode=${q.retcode} confirmed=${q.confirmed} '
            'uin=${q.uin ?? 0} msg=${q.message}');
      }

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
      // 官方扫码登录（TIM 反编译，2026-09-21）：
      // 0x106 body = concat(t24料, t30料) 原样（j.java case 262 的 _tmp_pwd 路径），
      // 0x16A ← t25(nopicsig)、0x318 ← t101(tgtQR)。见 buildQrLogin 头注释。
      final body2 = Qq8LoginBody.buildQrLogin(
        loginCtx,
        t106Data: q.t106!,
        tgtgt: q.tgtgt!,
        t16a: q.t16a!,
        tgtQR: q.t318!,
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
      seqId: _seq,
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
    _pullTimer?.cancel();
    _pullTimer = null;
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
    bool da2BitActive = true,
  }) {
    final device = _device!;
    return Qq8TlvContext(
      uin: uin,
      da2BitActive: da2BitActive,
      apk: profile.apk,
      device: device,
      passwordMd5: passwordMd5 ?? Uint8List(16),
      seqId: _seq,
      // 官方 `util.get_ksid` -> `string_to_buf`：SP 里的十六进制串按两字符
      // 一字节解码（真机 32 字符 -> 16 字节）。**没注入就是空**——官方首次
      // 登录 SP 无 ksid 时整条 0x108 不发（`k.java` case 264 guard），
      // 而不是发一条编造的 `|<imei>|<apkName>`（2026-10-23 修正）。
      ksid: qq8KsidBytes(device.ksid),
      // 0x154 的官方实参是 `t.i`，而 `t.i` 来自 `WUserSigInfo._reserveData`，
      // 后者由 `com/tencent/mobileqq/msf/core/auth/l.java:209` 与
      // `n.b()/n.c()`（`msf/core/auth/n.java:289/300`）用
      // `MsfSdkUtils.convertInt2Bytes(toServiceMsg.getRequestSsoSeq())` 填入；
      // 而 `l.java:181/191/257/268/279/…` 又把 `_seqence` 设成同一个 `p.f`。
      // 官方真机日志实证：`MSF SSO SEQ:2838`（10-22）与 `Seq:3` 同一次登录里并存，
      // 二者是本流程内绑定的两个编号，但都随流程走。
      // 我们没有 MSF 层，取本流程的 [_seq]：既非 0（官方 else 分支才是 0），
      // 又在整条流程（密码 → 滑块提交）里保持不变，与官方语义最接近。
      msfSsoSeq: _seq,
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
      // 0x525 内嵌 0x536：官方 ProtocolDet 的历史出口 IP 缓存。
      // 未注入构造器（或构造器返回空）时由 TLV 层退回官方空形态 `01 00`。
      protocolDet: _buildProtocolDet(),
    );
  }

  /// 把服务端给的 `0x537` 裸条目交给 [protocolDetRecorder] 落盘。
  ///
  /// 官方在同一位置（`oicq_request.java:1632-1637`）把去掉 2 字节前缀的
  /// 21/33 字节交给 `ProtocolDet.setLoginExtraData`，后者解析成
  /// `LoginExtraData` 再 `updateCachedExtraDataFile`（满 3 条时**替换最旧的那条**，
  /// 见 `ProtocolDet.java` 的 `updateCachedExtraDataFile`）。
  ///
  /// 本层只做转发与日志，不碰文件系统（同上 [protocolDetBuilder] 的分层理由）。
  /// 记录失败绝不阻断登录。
  void _recordProtocolDet(Uint8List? raw) {
    if (raw == null || raw.length < 21) return;
    final entry = Qq8ProtocolDet.decodeSingle(raw);
    if (entry == null) {
      _log.d('0x537 条目解析失败（${raw.length}B），跳过记录');
      return;
    }
    _log.i('0x537 出口记录: uin=${entry.uin} ip=${entry.ipText} '
        'time=${entry.time} ver=${entry.version}');
    final rec = protocolDetRecorder;
    if (rec == null) return;
    try {
      rec(entry);
    } on Object catch (e) {
      _log.w('pd2.dat 记录失败（不影响登录）', error: e);
    }
  }

  /// 组装 `0x536` body，并记一条诊断日志（条数能直接反映"带了几条历史出口"）。
  Uint8List? _buildProtocolDet() {
    final build = protocolDetBuilder;
    if (build == null) return null;
    final Uint8List? body;
    try {
      body = build();
    } on Object catch (e) {
      // 读盘失败绝不能阻断登录——官方 ProtocolDet 自己也把异常吞成 `01 00`。
      _log.d('ProtocolDet 构造失败，退回空形态', error: e);
      return null;
    }
    if (body == null || body.length < 2) return null;
    if (body[0] != Qq8ProtocolDet.emptyBody[0]) {
      _log.d('ProtocolDet 版本字节异常（${body[0]}），退回空形态');
      return null;
    }
    // body = [版本][条目数][条目...]，条目数 0（`01 00`）等价于"没有历史"。
    final n = body[1];
    _log.d('ProtocolDet: $n 条历史出口，${body.length} 字节');
    return body;
  }

  /// 解析本次登录要用的 QIMEI：先看注入值，再（可选）走灯塔取号。
  ///
  /// 取号只提交设备属性（无 uin / 无口令 / 无票据），所以不涉及账号；
  /// 但它仍是联网动作 → 先过 [gate]，被拦就跳过（不阻断登录）。
  /// 结果缓存进 [_fetchedQimei]，同一实例不重复取。
  Future<String?> _resolveQimei() async {
    if (qimei != null && qimei!.isNotEmpty) return qimei;
    if (_fetchedQimei != null) return _fetchedQimei;
    final fetch = qimeiFetcher;
    final device = _device;
    if (fetch == null || device == null) return null;
    final blocked = _gateBlockReason();
    if (blocked != null) {
      _log.i('跳过 QIMEI 取号：$blocked');
      return null;
    }
    try {
      final v = await fetch(device);
      if (v != null && v.isNotEmpty) {
        _fetchedQimei = v;
        _log.i('QIMEI 取号成功（${v.length} 字符）→ 进 TLV 0x545');
        // 落盘：否则每次启动都换号 = 设备标识漂移。
        _recordQimei(v);
        return v;
      }
      _log.i('QIMEI 取号未返回值 → 0x545 整条不发（与官方一致）');
    } on Object catch (e) {
      // 取不到就整条不发，**不阻断登录**：官方拿不到 QIMEI 时同样跳过 0x545
      //（`k.java` case 1349 只在非空时组包）。
      _log.w('QIMEI 取号失败 → 0x545 整条不发（不阻断登录）', error: e);
    }
    return null;
  }

  /// 记录服务端下发的 `ksid`（TLV `0x108`）。
  ///
  /// 官方 `util.string_to_buf` 把 32 位十六进制串解成 16 字节；这里如实把
  /// **原始字节**交给上层，由上层决定存成 hex 串还是别形态。
  ///
  /// 空/超长一律忽略（`0x108` 正常就是 16 字节；见到别的长度说明解析错了，
  /// 存下来只会污染下次登录）。
  void _recordKsid(Uint8List? raw) {
    if (raw == null || raw.isEmpty) return;
    if (raw.length > 64) {
      _log.w('0x108 ksid 长度异常（${raw.length} 字节），忽略');
      return;
    }
    final hex = raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    _log.i('0x108 ksid 下发（${raw.length} 字节）→ 落盘，下次登录原样回带');
    final rec = deviceStateRecorder;
    if (rec == null) return;
    try {
      rec(ksid: hex);
    } on Object catch (e) {
      _log.w('ksid 落盘失败（不影响登录）', error: e);
    }
  }

  /// 记录本次取到的 QIMEI（跨进程稳定的设备标识）。
  void _recordQimei(String value) {
    final rec = deviceStateRecorder;
    if (rec == null) return;
    try {
      rec(qimei: value);
    } on Object catch (e) {
      _log.w('QIMEI 落盘失败（不影响登录）', error: e);
    }
  }

  /// 建连，并把每一次端点尝试写进日志。
  ///
  /// ## 为什么需要这层包装（2026-10-23）
  ///
  /// 真机上出现过 `Failed host lookup: 'msfwifi.3g.qq.com'` —— 登录包一个字节
  /// 都没发出去。而日志里只有最后一句异常，看不出「到底试过几个地址、
  /// 每个是 DNS 失败还是连接被重置」。这两类失败的处置完全不同（前者只能
  /// 换 IP，后者可能是被中间设备拦），没有这个记录就只能猜。
  ///
  /// 顺带记下**实际连上了哪个端点**：日志里出现裸 IP 就说明走了兜底，
  /// 也就说明当时 DNS 是坏的。否则「连上了」会把网络异常掩盖过去。
  Future<void> _connect(Qq8Transport tran) async {
    if (tran is Qq8TcpTransport && tran.onConnectAttempt == null) {
      tran.onConnectAttempt = (String msg) => _log.i('[连接] $msg');
    }
    await tran.connect();
    if (tran is Qq8TcpTransport) {
      final ep = tran.connectedEndpoint;
      if (ep != null) _log.i('[连接] 已建立 ${ep.key}');
    }
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
    await _connect(tran);

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
      seqId: _seq,
    );
    final cmd = token == null ? qq8LoginCmd : qq8ExchangeEmpCmd;
    // **发出什么**也要记：原先只记响应，发出去的 TLV 一直靠推断。真机上
    // "档案换了、实际清单变没变""某项是不是被 guard 滤掉了"都只能靠猜
    // （2026-09-21 的教训：9.3.60 有没有真发 0x553 无从确认）。
    final peek = Qq8LoginBody.peekBody(body);
    _log.i('发登录包 subCmd=${peek.$1} TLV=${peek.$2.length}项 '
        '${peek.$2.map((t) => '0x${t.toRadixString(16)}').join(',')}');
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
      // 服务端下发的「本次登录出口」记录（0x537）→ 交给上层落进 pd2.dat，
      // 下次登录的 0x525/0x536 就能带上真实历史（官方 oicq_request.java:1632
      // 在**同一步**调 ProtocolDet.setLoginExtraData）。记录失败不影响登录。
      _recordProtocolDet(r.t537);
      // 服务端下发的 ksid（0x108）——必须落盘。官方在同一步做同样的事
      // （`oicq_request.java:1594` → `util.set_ksid`，且 set_ksid 只在 SP 为空时写）。
      // 丢掉它等于每次登录都自称"没有 ksid"，而它要成功才下发 → 死循环。
      _recordKsid(r.t108Ksid);
      // 成功之后清掉验证材料，避免下一次登录误用
      _t104 = Uint8List(0);
      _t174 = Uint8List(0);
      _t547 = null;
      _sliderUrl = null;
      _verifyPhone = null;
      _smsPhone = null;
      _smsRandom = null;
      _smsMsalt = 0;
      _smsMpasswd = null;
      _smsMsgCnt = null;
      _smsTimeLimit = null;
      // 登录已成功（type=0 票据已落盘）。从这里开始再出错也绝不能归因成
      // 「提交短信验证码失败」——那会把成功登录误报成失败。
      try {
        await _goOnline(uin, bundle);
      } catch (e, st) {
        _fail('登录已通过，但上线流程失败', e, st);
      }
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
      // ⚠️ 2026-10-24 修正：这里原来是
      //   `_t104 = r.tlvs[0x104] ?? Uint8List(0); _t174 = r.verifyToken ?? …;`
      // 即**无条件下发空值覆盖**。而"重新下发短信"的应答长这样：
      //   `type=160  TLV=0x104, 0x17b`
      // 没有 `0x174`/`0x178`——不是缺字段，而是**令牌仍然有效、手机号没变**。
      // 参考实现（icqq `base-client.js:1810-1822`）的判据是
      //   `if (!t[0x204] && !t[0x174]) return "已向密保手机发送短信验证码"`
      //   `if (t[0x174] && t[0x178]) this.sig.t174 = t[0x174]`
      // 令牌只在"新给了"时才更新，从不被清空。照抄旧写法时，点一次"重新下发"
      // 就会把好令牌换成空、随后报"缺少盐或令牌"、状态机跳 failed，
      // 用户再也进不回输入框（真机现象：验证码能收到，但界面卡死）。
      final salt = r.tlvs[0x104];
      if (salt != null && salt.isNotEmpty) _t104 = salt;
      final token = r.verifyToken;
      if (token != null && token.isNotEmpty) _t174 = token;
      final phone = r.verifyPhone;
      if (phone != null) _verifyPhone = phone;

      if (_t104.isEmpty || _t174.isEmpty) {
        // 只有"从来没拿到过令牌"才是真失败（首包就不给，说明链路不对）。
        _emit(Qq8LoginSnapshot(
          stage: Qq8LoginStage.failed,
          uin: uin,
          error: '短信验证响应缺少盐或令牌（0x104/0x174），无法继续',
        ));
        return;
      }

      // 本次是否属于"重新下发"：没有 0x204（设备锁文案）也没有新令牌。
      final resent = (r.tlvs[0x204] == null) && (token == null || token.isEmpty);
      final quota = r.smsResendQuota;
      if (quota != null) {
        _log.i('短信已重新下发：${quota.count} 次 / ${quota.seconds}s 内可再发');
      }
      _emit(Qq8LoginSnapshot(
        stage: Qq8LoginStage.needsSmsCode,
        uin: uin,
        // 重新下发不带 0x178，用上一条记住的号码，避免界面突然显示"绑定手机"。
        phone: phone ?? _verifyPhone,
        smsAutoSent: resent,
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
    // 服务端进阶提示块（0x508）——诊断关键：真机被拒时确认服务端究竟回了什么。
    // userBuf 是加密的 notice 载荷，需再走 ts{7,8,9}.qq.com:8080/msg 才变明文；
    // 这里先打原始 hex，供离线比对官方 g.b() 的换文案链路是否值得补。
    final notice = r.t508Notice;
    if (notice != null) {
      _log.i('0x508 进阶提示: doFetch=${notice.doFetch} '
          'timeout=${notice.timeoutMs}ms userBuf[${notice.userBuf.length}]='
          '${notice.userBuf.map((v) => v.toRadixString(16).padLeft(2, '0')).join()}');
    }
    // 服务端文案（0x146 = 标题 + 内容）——**必须进日志**：被拒时这是唯一能读到的
    // "服务端原话"（0x508 那份详情要么要再走 ts7/ts8 换明文，而那条路实测已死，
    // 要么就是这段话本身）。以前只把它显示在界面上、不落盘，排查时只能靠人回忆。
    if (msg != null) {
      _log.i('0x146 服务端文案: 「${msg.$1}」${msg.$2.isEmpty ? '' : ' / ${msg.$2}'}');
    } else {
      _log.i('0x146 缺失：本次响应只有 type=${r.type}，无服务端文案');
    }
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
        error: '连接已断开（心跳连续失败），正在尝试自动恢复',
      ));
      unawaited(reconnect(uin: uin));
    };
    _session = session;
    _pushSub?.cancel();
    _pushSub = session.pushes.listen(
      _onPush,
      onError: (Object e) => _log.w('推送流出错', error: e),
    );
    await session.start();

    // register 超时不算失败：icqq `_register` 的三态判据（1 / -1 / -2）里
    // `-2`（等响应超时）照样继续走上线流程——服务端本就可能不回 ack，
    // 真机日志里 register 发出后到达的是 ConfigPushSvc 推送而不是应答。
    // 真机 2026-10-24 09:09：登录 type=0 票据已下发，却因 register 10s
    // 超时把整条流程标成「提交短信验证码失败」——归因错了，登录是成功的。
    bool ok;
    try {
      ok = await session.register();
    } catch (e) {
      _log.w('上线注册无应答（等价 icqq -2），继续上线', error: e);
      ok = true;
    }
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

    // 上线先拉一次漏掉的消息：PushNotify 推送在真机上并不可靠
    // （2026-10-24 11:41 真机：上线后服务端只推了 StatSvc.QueryHB，
    //  一条 MessageSvc.PushNotify 都没来），所以不能只等推送——
    // 主动 PbGetMsg 一把，把上线前攒的离线消息先收进来。
    // 延迟 2 秒再补拉：上线瞬间好友/群列表请求正在飞，
    // 立刻再打一个 PbGetMsg 会让「按序吃应答」的测试夹具错位。
    Future.delayed(const Duration(seconds: 2), () {
      // 2 秒里可能已经断线/重登——只在这个 session 还在线时拉
      if (_session == session && _snapshot.stage == Qq8LoginStage.online) {
        unawaited(_pullNewMessages(reason: '上线补拉'));
      }
    });
    // 兜底轮询：推送不来时靠拉（真机 11:41 一条 PushNotify 都没收到）。
    // 间隔取心跳的 1/3，错开心跳的节奏。
    _pullTimer?.cancel();
    _pullTimer = Timer.periodic(
      heartbeatInterval ~/ 3,
      (_) => unawaited(_pullNewMessages(reason: '轮询')),
    );
  }

  /// 主动拉新消息并走推送同一条流水线（建会话/未读/去重全复用）。
  Future<void> _pullNewMessages({required String reason}) async {
    if (_session == null || _snapshot.stage != Qq8LoginStage.online) return;
    try {
      final page = await pullMessages();
      if (page.messages.isEmpty) return;
      _log.i('$reason：${page.messages.length} 条新消息');
      for (final m in page.messages) {
        if (_events.isClosed) return;
        _events.add(Qq8MessagePush(
          Qq8PushCmd.notify,
          message: m,
          needsAck: false,
        ));
      }
    } on Object catch (e) {
      // 拉取失败不致命：轮询下一轮 / 下次通知还会再试
      _log.d('$reason失败', error: e);
    }
  }

  /// 断线自动恢复：重连 + 用已存票据续期重上线（不用密码）。
  ///
  /// 官方对照（wtlogin 日志）：连接断了会自动重建并用已有票据续登，
  /// 全程不惊动用户。这里同样只用票据；没有可用票据就停在 disconnected
  /// 等用户手动重登——**不要**在自动路径里退化成密码登录。
  ///
  /// 也公开给 UI 的「重连」按钮用（断线提示里写的就是"可重新登录或重连"）。
  /// [reconnectAttempts] 次退避重试全失败后停在 disconnected。
  Future<void> reconnect({required int uin}) async {
    if (_reconnecting) return;
    _reconnecting = true;
    try {
      for (var attempt = 1; attempt <= reconnectAttempts; attempt++) {
        if (_states.isClosed) return; // close() 之后不再抢跑
        await Future<void>.delayed(reconnectBaseDelay * attempt);
        if (_states.isClosed) return;
        final token = await tokenStore.load(uin);
        if (token == null || !token.usable) {
          _log.w('断线恢复：没有可用票据，停在断线状态等手动重登');
          return;
        }
        _log.i('断线恢复：第 $attempt/$reconnectAttempts 次（票据续期）');
        try {
          await loginWithToken(uin: uin);
        } on Object catch (e) {
          _log.w('断线恢复第 $attempt 次抛异常', error: e);
          continue;
        }
        if (_snapshot.stage == Qq8LoginStage.online) {
          _log.i('断线恢复成功（第 $attempt 次）');
          return;
        }
        _log.w('断线恢复第 $attempt 次未上线（stage=${_snapshot.stage.name}），退避后重试');
      }
      _log.w('断线恢复 $reconnectAttempts 次均失败，停在断线状态等手动重登');
      _emit(Qq8LoginSnapshot(
        stage: Qq8LoginStage.disconnected,
        uin: uin,
        error: '自动重连失败（已尝试 $reconnectAttempts 次），请手动重新登录',
      ));
    } finally {
      _reconnecting = false;
    }
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
  @override
  Future<List<int>> listUins() async => _byUin.keys.toList()..sort();

  @override
  Future<DateTime?> lastModified(int uin) async => null;

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

