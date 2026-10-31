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
import '../kernel/crypto/digest.dart';
import '../kernel/crypto/ecdh.dart';
import '../kernel/safety/login_policy.dart';
import '../kernel/safety/safety_gate.dart';
import '../kernel/wlogin8/qq8_config.dart';
import '../kernel/wlogin8/qq8_config_push.dart';
import '../kernel/wlogin8/qq8_device.dart';
import '../kernel/wlogin8/qq8_login.dart';
import '../kernel/wlogin8/qq8_history.dart';
import '../kernel/wlogin8/qq8_pb.dart';
import '../kernel/wlogin8/qq8_file.dart';
import '../kernel/wlogin8/qq8_gfs.dart';
import '../kernel/wlogin8/qq8_group_admin.dart';
import '../kernel/wlogin8/qq8_image.dart';
import '../kernel/wlogin8/qq8_list.dart';
import '../kernel/wlogin8/qq8_msg.dart';
import '../kernel/wlogin8/qq8_multimsg.dart';
import '../kernel/wlogin8/qq8_jce.dart';
import '../kernel/wlogin8/qq8_push.dart';
import '../kernel/wlogin8/qq8_pow.dart';
import '../kernel/wlogin8/qq8_profiles.dart';
import '../kernel/wlogin8/qq8_protocol_det.dart';
import '../kernel/wlogin8/qq8_online_check.dart';
import '../kernel/wlogin8/qq8_qrcode.dart';
import '../kernel/wlogin8/qq8_recv.dart';
import '../kernel/wlogin8/qq8_session.dart';
import '../kernel/wlogin8/qq8_sso.dart';
import '../kernel/wlogin8/qq8_tlv.dart';
import '../kernel/wlogin8/qq8_tran.dart';
import 'qq8_token_store.dart';
import 'recovery_planner.dart';

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

  /// **服务端准入拒绝**（`type=45` 版本过低 / `type=235` 验证通过后判版本 /
  /// `type=243` 不安全环境）。
  ///
  /// 与 [failed] 分开的理由是**后续动作不同**：
  ///
  /// * [failed]：换口令/换参数可能就好了，重试有意义；
  /// * [rejected]：服务端已经给出「这个账号在当前客户端代际不许进」的
  ///   结论，原地重发只会再问一遍同一句拒绝（真机 2026-10-27：自动重连
  ///   三次连吃三记 `type=16`）。上游必须**停止自动重试**，
  ///   改用「换线（OneBot）/ 换设备 / 换账号」这类不同层级的动作。
  ///   凭证失效请用 [sessionExpired]——它只需要重新登录，不应劝用户换号。
  ///
  /// 判据收在 [Qq8LoginResultType.isServerRejected]，不要在别处再写一遍
  /// 数字比较——这类返回码以后还会加。
  rejected,

  /// 凭证/身份失效（type=16 / 155 / authDead 系列）。与 [rejected] 的区别：
  /// 换一张票就能继续，**不要**给用户「账号被风控」的暗示，也不要冷却。
  sessionExpired,
}

/// 返回码 → 登录阶段。这是**唯一判据出处**，UI/provider/adapter 都调它。
Qq8LoginStage qq8StageForResultType(int type) {
  if (Qq8LoginResultType.isSessionExpired(type)) {
    return Qq8LoginStage.sessionExpired;
  }
  if (Qq8LoginResultType.isServerRejected(type)) {
    return Qq8LoginStage.rejected;
  }
  return Qq8LoginStage.failed;
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

  /// 这次状态变化是不是**网络不可用**导致的（而不是服务端给了结论）。
  ///
  /// 断线自动恢复时，每轮重试失败都只是"连不上网"，不该被上层当成登录失败
  /// 弹错/刷日志（真机缺陷②：恢复期间每次重试都多一条 `W/ChatStore 会话层报错`）。
  /// 上层据此静默处理。
  final bool networkIssue;

  /// 服务端返回码（[Qq8LoginStage.rejected] 时非空）。
  ///
  /// 单独留着是因为 UI 要能显示「服务端返回 type=45」这种可检索的一手
  /// 事实：文案是服务端给的、会变，返回码不会。排查时两者都要。
  final int? resultType;

  /// 原始异常栈（[Qq8LoginStage.failed] 时非空）。
  ///
  /// 上游把它塞进 [SessionFailure] 是刻意保留的：出错现场只有一份，
  /// 换算成「人话」之后如果连栈也丢了，再想定位就只能复现。
  final StackTrace? stackTrace;

  /// 这份快照产生时的用户动作序号。
  ///
  /// 由 [_emit] 统一打戳（业务代码不必手填）。上层据此区分「用户又点了一次」
  /// 与「同一次动作里状态被重复 emit」——注意**不能在收到时去问服务当前序号**：
  /// 状态流是异步投递的，一批快照会在同一步里送达，那时序号早已推进。
  final int actionSeq;

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
    this.resultType,
    this.networkIssue = false,
    this.stackTrace,
    this.actionSeq = 0,
  });

  /// 复制一份并打上动作序号（[_emit] 用；本类不可变，只能整份重建）。
  Qq8LoginSnapshot stamped(int seq) => Qq8LoginSnapshot(
        stage: stage,
        uin: uin,
        sliderUrl: sliderUrl,
        phone: phone,
        smsAutoSent: smsAutoSent,
        smsFlow: smsFlow,
        deviceLockHint: deviceLockHint,
        qrToken: qrToken,
        qrMessage: qrMessage,
        error: error,
        resultType: resultType,
        networkIssue: networkIssue,
        stackTrace: stackTrace,
        actionSeq: seq,
      );

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
  /// 上线后是否补发一次在线状态上报（`StatSvc.SetStatusFromClient`）。
  ///
  /// 官方（icqq `internal/listeners.js:93`）登录成功回调第一件事就是它，
  /// 之后每 11 次心跳补发（`client.js:225-229`，由会话层自动做）。
  ///
  /// 留成开关不是为了关掉产品行为，而是**测试需要**：脚本化传输按"一个请求
  /// 消耗一个预设响应"推进，多出来的一个包会让后面所有帧错位一格，
  /// 断言就变成在验错位后的东西。需要断言的用例显式打开它。
  /// 登录后是否发官方那两个 JCE 检查（[Qq8OnlineCheck]）。
  ///
  /// 默认发。脚本化自测要传 `false`：假传输按固定脚本回包，多两个包
  /// 会让后面每一帧的 seq 错位一格（与 [reportOnlineStatus] 同一个道理）。
  final bool reportOnlineChecks;

  /// 是否允许自动尝试**未经真机验证**的恢复分支（A2KEY / A1+noPicSig / A2-only）。
  /// 默认 false：产品只自动走 [qq8VerifiedRecoveryMaterials]（当前仅 D2 链）。
  /// 自测或显式实验时才打开，避免把没有真机成功记录的分支拿去撞真实服务端。
  final bool allowExperimentalRecovery;

  final bool reportOnlineStatus;

  final Duration heartbeatInterval;
  /// 收消息兜底轮询间隔（推送不可靠时的补拉频率）。
  ///
  /// 服务端对我们**完全不推消息**（真机 2026-10-25：只有 `StatSvc.QueryHB` 与
  /// `ConfigPushSvc.*`，一条 `MessageSvc.PushNotify` / `OnlinePush.*` 都没有），
  /// 所以收消息只能靠这个轮询——**它就是延迟上限**。原先 20 s 意味着最坏
  /// 等 20 秒才看到新消息，用户体感"不实时"。
  ///
  /// **2026-10-31 起推送已实测可用**（私聊 `MessageSvc.PushNotify` → 立刻拉、
  /// 群 `OnlinePush.PbPushGroupMsg` 带体直达），所以这里不再是"延迟上限"，
  /// 而是**对账兜底**：推送丢了也要在一个可接受的时间内自己发现。
  ///
  /// 取 15 s：一次对账只打 2 个包（`MessageSvc.PbGetMsg` + 需要探的群），
  /// 频率 4 次/分，低于原先 8 s 的 7.5 次/分。群侧另有"窗口问空就不再重复
  /// 问"的短路（见 [_groupWindowIdle]），实际包量更低。
  final Duration pullInterval;
  /// 应用在后台时的轮询间隔。
  ///
  /// 官方客户端**根本不做定时轮询**：`MessageHandler` 里 `MessageSvc.PbGetMsg`
  /// 的触发点是 `MessageSvc.PushNotify`（服务端推一个很小的通知包），收到才
  /// 去拉；群消息更常直接走 `OnlinePush.PbPushGroupMsg`。也就是说官方的新鲜
  /// 度来自推送，`onRunningForeground` 那条链路里没有消息拉取。
  ///
  /// 我方现在也能收到推送（2026-10-31 实测），后台的即时性靠推送就够；
  /// 定时对账只在"推送漏了"时兜底，120 s 一次完全够用，且把后台的主动
  /// 请求压到接近官方水平（官方在后台根本不轮询）。
  /// 所以前台 15 s、后台 120 s。
  final Duration backgroundPullInterval;
  /// 上线后延迟多久做第一次补拉（0 = 不做）。测试里调大避免抢帧。
  final Duration startupPullDelay;
  /// 上线后是否对每个群发一次探测把最新 seq 记下来（群消息轮询的前提）
  final bool primeGroupSeqs;

  /// 网络层超时（连接/单请求）。
  final Duration timeout;

  /// 上线注册（StatSvc.register）的单次等待上限。
  ///
  /// 官方是 30 秒（msf/core/push/e.java setTimeout(30000L)）。测试里调小，
  /// 免得一条"无回执"用例挂 30 秒。
  final Duration registerTimeout;

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

  /// 纯「连不上网络」时的重试间隔。
  ///
  /// 断网不是凭证问题：网络一回来，同一份票据就能续上。真机 2026-10-31 10:28
  /// 现场：飞行模式 30 秒，三轮 2s/4s/6s 全落在断网窗口里，三次失败后直接停在
  /// 断线状态——网络恢复时应用再没自己上线。所以「网络不可用」单独一类：不消耗
  /// [reconnectAttempts] 这个有界次数，按固定间隔慢慢等。
  Duration reconnectOfflineDelay = const Duration(seconds: 15);

  /// 网络一直不可用时最多等多久（超过就停在断线状态，别无限耗着）。
  Duration reconnectOfflineGiveUpAfter = const Duration(minutes: 30);

  bool _reconnecting = false;

  /// 会话代际：每建一次新会话 / 拆一次连接就 +1。
  ///
  /// 异步任务（注册、在线检查、延迟补拉）在写回状态前必须核对自己拿到
  /// 的 epoch——断线重连后旧会话的回调不能踩新会话的状态。
  int _sessionEpoch = 0;

  /// 用户动作序号：每发起一次 UI 驱动的动作（登录 / 交码 / 换票 …）就 +1。
  ///
  /// 上层用它区分两件不同的事：「用户又点了一次」必须让同样的失败再报一次
  /// （否则点两次只看到一次提示）；「同一次动作里状态被重复 emit」必须继续
  /// 去重（否则自动重连每轮都会刷一条同样的错）。
  int _actionSerial = 0;
  int get actionSerial => _actionSerial;
  void beginAction() => _actionSerial++;
  /// 收消息兜底轮询（PushNotify 不可靠时的补拉）。
  Timer? _pullTimer;
  Qq8Session? _session;
  Qq8SigBundle? _sig;

  /// 本次登录是不是**续期**（`loginWithToken` 进来的）。只用于区分
  /// 「首次登录」与「续期」两套时间戳，成功保存票据后立刻清掉。
  bool _loginIsRenewal = false;

  /// 本次免密恢复实际用的是哪条材料（[Qq8TokenData.materialD2Key] 等）。
  /// 只用于把 16/155 的失效结论**限定到这一条材料**上，不整体判死其它材料。
  /// 口令链（不是免密恢复）时为 null。
  String? _attemptMaterial;

  /// **私聊**显示名缓存：uin → 好友备注/昵称。
  ///
  /// 为什么要服务层兜这一层：消息体里的发送者昵称（`msg_head` 字段 14）经常为空，
  /// 内核只能回落成 QQ 号，于是聊天气泡和通知栏都会出现一串数字。
  ///
  /// **必须和群名片分开存**：同一个人在群里可能叫「无道极法魔君」、私聊备注却是「净凾」。
  /// 真机反馈过「私聊里显示的是对方在群里的名字」——就是一张全局 uin→名字 表混着用导致的。
  final Map<int, String> _friendNames = <int, String>{};

  /// **群内**显示名缓存：gid → (uin → 群名片/昵称)。
  ///
  /// 群名片只在该群有效，绝不能拿去当私聊名字。
  final Map<int, Map<int, String>> _groupMemberNames = <int, Map<int, String>>{};

  /// 群成员名单的最近拉取时间（同一个群 10 分钟内不重复拉）。
  final Map<int, DateTime> _groupNamesFetchedAt = <int, DateTime>{};

  /// 查**私聊**显示名（好友备注优先）。没有就返回 null（回落交给调用方）。
  String? displayNameOf(int uin) {
    final n = _friendNames[uin];
    return (n == null || n.isEmpty) ? null : n;
  }

  /// 查**该群内**的显示名：群名片优先，退到好友名。都没有返回 null。
  String? groupMemberNameOf(int gid, int uin) {
    final inGroup = _groupMemberNames[gid]?[uin];
    if (inGroup != null && inGroup.isNotEmpty) return inGroup;
    return displayNameOf(uin);
  }

  void _rememberFriendName(int uin, String? name) {
    if (uin == 0 || name == null || name.isEmpty) return;
    _friendNames[uin] = name;
  }

  void _rememberGroupMemberName(int gid, int uin, String? name) {
    if (gid == 0 || uin == 0 || name == null || name.isEmpty) return;
    (_groupMemberNames[gid] ??= <int, String>{})[uin] = name;
  }

  /// 确保某个群的成员名字已缓存（10 分钟内只拉一次，失败静默）。
  ///
  /// 只为「让通知/气泡能显示网名」服务，所以绝不抛异常、绝不阻塞消息处理。
  Future<void> ensureGroupNames(int gid) async {
    final at = _groupNamesFetchedAt[gid];
    if (at != null && DateTime.now().difference(at) < const Duration(minutes: 10)) {
      return;
    }
    _groupNamesFetchedAt[gid] = DateTime.now();
    try {
      await fetchGroupMembers(gid);
    } catch (_) {
      // 名字是装饰，拉不到就算了。
    }
  }

  /// 增量拉消息的游标（`PbGetMsgResp.sync_cookie`，服务端靠它算增量）。
  Uint8List? _syncCookie;
  /// 每个群「已收到的最大消息 seq」。
  ///
  /// 初始值来自 `PbUnReadMsgSeq`（那是**水位**，见 `_groupSynced`），之后
  /// 只由 `_advanceGroupCursor` 按实际收到的消息推进。
  final Map<int, int> _groupLastSeq = {};
  /// 已经把「水位之前一窗」补过的群。
  ///
  /// [PbUnReadMsgSeq] 给的 `group_seq` 是**最新消息序号（水位）**，不是
  /// 「已消费到哪」。若直接把它当游标只往前拉 `+1..+20`，请求区间永远落在
  /// 最新之后 ⇒ 空。首次同步必须往**回**拉一窗（C36）。
  final Set<int> _groupSynced = {};

  /// 供自测读取某群的当前游标（`null` = 还没铺底）。只读，无副作用。
  int? debugGroupCursor(int groupCode) => _groupLastSeq[groupCode];
  /// 供自测：下一次请求会拿到的 seq（不消耗号；null = 未上线）。
  int? get debugSeqCursor => _session?.seqCursor;

  /// 供自测：直接跑一轮群轮询（不经过定时器，也不碰私聊）。
  Future<void> debugPollGroups({String reason = '自测轮询'}) => _pollGroups(reason);

  /// 供自测：所有群的当前游标（只读快照）。
  Map<int, int> get debugGroupCursors => Map<int, int>.unmodifiable(_groupLastSeq);

  /// 供自测：当前因"窗口问空"被短路的群（只读快照）。
  Set<int> get debugGroupWindowIdle => Set<int>.unmodifiable(_groupWindowIdle);

  /// 供自测：直接铺一个群游标（跳过上线探测）。
  void debugSeedGroupCursor(int groupCode, int seq, {bool synced = true}) {
    _groupLastSeq[groupCode] = seq;
    if (synced) {
      _groupSynced.add(groupCode);
    } else {
      _groupSynced.remove(groupCode);
    }
  }
  /// seq 探测两路都拿不到的群（本轮会话内不再重试，避免请求风暴）。
  final Set<int> _primeFailed = {};

  /// 服务端明确回 103（「该群对本账号无可下发内容」）的群。
  ///
  /// 真机实证（analysis/_ref/applog-20261025.log:45-51 等四份日志）：
  /// 7 个群两天固定分成两组，364425216 / 631157274 / 786409471 恒 103，
  /// 486045673 / 932740593 / 1032107787 / 1128570010 恒 104 —— result
  /// 是**群级别的准入结论**，不是请求区间问题。官方离线库
  /// （analysis/_ref/offdb-3499239040.db）里这三个 103 群连
  /// `mr_troop_<md5>` 表都不存在，反证「服务端确实不给我们这个群的内容」。
  ///
  /// 因此 103 之后再拉就是纯浪费：每 20 秒一轮 ×3 群，四份日志累计
  /// 8517 次群历史请求里 0 次成功。这里记死，本会话不再重试。
  final Set<int> _groupDead = {};

  /// 「窗口已经问空、且此后没有任何新证据」的群。
  ///
  /// 群的消息发现原本是"每轮都把 `[游标+1, 游标+20]` 问一遍"——真机上这就是
  /// 每 16 秒一次 `群历史 gid=486045673 seq=59159-59178 result=104`，四份日志
  /// 累计 8517 次请求里 0 次拿到消息（P2 实测：水位停在 59158，窗口永远落在
  /// 水位之外）。而群侧现在有推送（`OnlinePush.PbPushGroupMsg` 带体直达），
  /// 没有推送时还有 `PbUnReadMsgSeq` 对账（见 [_resyncGroupSeqs]，它自己会
  /// `_catchUpGroup` 补齐缺口）。所以「窗口问空 + 无推送 + 水位没动」这三件事
  /// 同时成立时，再问同一个窗口是纯浪费。
  ///
  /// 只在这个前提下跳过；一旦出现新证据（收到群推送 / 水位跳变 / 拉到消息 /
  /// 重新上线）立即移出集合，回到逐轮探测。**不推进游标**，所以不可能跳过
  /// 真消息（C36 的「永久跳过」错法在这里不成立）。
  final Set<int> _groupWindowIdle = {};

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

  /// ConfigPushSvc.PushReq（config_type=2）带下来的 bigdata 会话
  /// （群推送可能走这条通道；icqq 存盘并在需要时读回）。
  Uint8List? _bigdataSigSession;
  Uint8List? _bigdataSessionKey;

  /// bigdata 上传通道的地址（同一份 PushReq 的 `1281.3` 里）。
  ///
  /// 离线文件上传是 **HTTP**（`http://<host>:<port>/cgi-bin/httpconn?...`），
  /// 不像图床那样由 PicUp 回执直接给地址，只能从这条通道拿（参考实现
  /// `lib/internal/highway.ts:162-171` 用的就是 `sig.bigdata.ip/port`）。
  String? _bigdataHost;
  int? _bigdataPort;

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
    this.pullInterval = const Duration(seconds: 15),
    this.backgroundPullInterval = const Duration(seconds: 120),
    this.startupPullDelay = const Duration(seconds: 2),
    this.primeGroupSeqs = true,
    this.reportOnlineChecks = true,
    this.reportOnlineStatus = true,
    this.allowExperimentalRecovery = false,
    this.timeout = const Duration(seconds: 15),
    this.registerTimeout = const Duration(seconds: 30),
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
    // 闸门只看「有没有任何一条免密材料」：D2 链（子命令 11）或 A1 对
    // （子命令 15）。两者都没有才是真的没料——这时才报错，具体走哪条由
    // 下面的 planner 决定（材料不足的话术也由 planner 的 Stop 分支负责）。
    if (token == null || !token.recoveryUsable) {
      _emit(const Qq8LoginSnapshot(
        stage: Qq8LoginStage.failed,
        error: '没有可用的票据（先做一次口令登录）',
      ));
      return;
    }
    // **本地已知不可用就别发包**：服务端已判失效 / 服务端给过的到期时间已过。
    // 反过来，没给到期时间（unknown）必须照常尝试——服务端才是最终裁决者，
    // 本地绝不猜 TTL。
    final v = token.evaluateValidity(DateTime.now());
    if (v == Qq8TokenValidity.invalidated || v == Qq8TokenValidity.expired) {
      _log.w('票据不可用（$v），不发包，直接让用户重新登录');
      _emit(Qq8LoginSnapshot(
        stage: Qq8LoginStage.sessionExpired,
        uin: uin,
        error: '上次登录已失效（票据过期或被服务端作废），请重新登录',
        resultType: token.invalidatedType,
      ));
      return;
    }
    if (v == Qq8TokenValidity.expiringSoon) _log.i('票据将在 30 分钟内到期，仍尝试续期');
    if (v == Qq8TokenValidity.unknown) {
      _log.i('服务端未给到期时间，照常尝试续期（由服务端裁决）');
    }
    // ---- 免密恢复编排（P4）---------------------------------------------
    // 闸门之后，由纯函数 planner 决定"这次用哪份材料"。**失败一次就停**：
    // 本方法只跑一次 packet，不在这里循环重试（有界重试是
    // `Qq8RecoveryCoordinator.runBounded` 的职责，由上层调用）。所以 tried
    // 恒为空、networkError/challengeActive 都交给上层判断。
    //
    // 关键纪律：**永不静默退回密码**。密码不是免密材料，没经用户授权不许再发。
    final avail = Qq8RecoveryAvailability.fromToken(token);
    final decision = planNext(
      a: avail,
      tried: const <Qq8RecoveryMaterial>{},
      networkError: false,
      challengeActive: false,
      // 默认只自动走已证可用的 D2 链；实验分支要显式打开才参与。
      allowUnverifiedMaterials: allowExperimentalRecovery,
    );
    if (decision is Qq8RecoveryStop) {
      _log.w('免密恢复停止 code=${decision.code}（${decision.message}）'
          '材料=$avail');
      _emit(Qq8LoginSnapshot(
        stage: Qq8LoginStage.sessionExpired,
        uin: uin,
        error: decision.code == 'unverified'
            ? '登录凭证不足以自动恢复（只剩未验证的恢复材料），请重新登录一次'
            : '登录凭证不足，请重新登录一次',
        resultType: token.invalidatedType,
      ));
      return;
    }
    final material = (decision as Qq8RecoveryAttempt).material;
    // 记下这次实际走的材料：一旦服务端回 16/155，失效结论只限定在这一条上。
    _attemptMaterial = qq8RecoveryMaterialName(material);
    _log.i('免密恢复选择材料=$material（${decision.why}）');
    switch (material) {
      case Qq8RecoveryMaterial.d2Key:
        // 已接线：`_login` 里 tgtgt = MD5(token.d2key)（见 :666）。
        break;
      case Qq8RecoveryMaterial.a1NoPicSig:
        // 已接线：子命令 15（`wtlogin.exchange_emp`）直接发 A1 + noPicSig。
        // body 形态依据 z.java 的 `tlv_t106.set_data(bArr2, len)` 与
        // `tlv_t16aVar.get_tlv_16a(bArr3)`（原样塞料，不再自己派生）。
        // **live 未验证**（没有真机证据），失败就按现有失败分支收尾。
        // 不降级成 d2Key、更不降级成密码。
        await _login(
          uin: uin,
          passwordMd5: null,
          a1: token.a1,
          noPicSig: token.noPicSig,
        );
        return;
      case Qq8RecoveryMaterial.a2Key:
        // 已接线：3 元组 A2+A2KEY（`WtloginHelper.java:607-690`）。tgtgt 直接用
        // A2KEY 原样（`tVarA.b = bArr2[2]`，不做 MD5），body 走子命令 11 且不带
        // 0x143；A2KEY 来自 0x119 明文 TLV 0x10d（官方 tk_file 的 _TGTKey）。
        // **live 未验证**（离线实现，没有真机证据）。失败按现有失败分支收尾，
        // 不降级成 d2Key、更不降级成密码。
        //
        // 为什么把 token 也传进去：3 元组的第一个参数 A2 就是 body 的 `0x10a`
        // （本仓 `Qq8TokenData.tgt`）。不传 token，`ctx.tgt` 会是空 → 等于材料
        // 不足还硬发包。传 token 只取 tgt 与 SSO 信封 sig，**不进 body 的
        // 0x143**（见 `_login` 里 a2Key 分支显式 `d2: null`）。
        await _login(
          uin: uin,
          passwordMd5: null,
          a2Key: token.a2Key,
          token: token,
        );
        return;
      case Qq8RecoveryMaterial.a2Only:
        // a2Only：无 key 时 tgtgt 该填什么（空 / 全零）官方未在证据里给死。
        // 因此这里**明确停**，绝不降级成 d2key 或密码，也不假装已实现。
        _log.w('免密恢复分支 $material 未接线（live=unavailable），'
            '不发包，请用户重新登录一次');
        _emit(Qq8LoginSnapshot(
          stage: Qq8LoginStage.sessionExpired,
          uin: uin,
          error: '登录凭证不足，请重新登录一次',
          resultType: token.invalidatedType,
        ));
        return;
    }
    await _login(uin: uin, passwordMd5: null, token: token);
  }

  Future<void> _login({
    required int uin,
    required Uint8List? passwordMd5,
    Qq8TokenData? token,
    // A1 对那条恢复分支（子命令 15）：给了 [a1] 就发 exchange_emp 包，
    // 不再走 token/password 两条。
    Uint8List? a1,
    Uint8List? noPicSig,
    // A2KEY 那条恢复分支（官方 3 元组 A2+A2KEY）：给出它就把它**原样**当 tgtgt
    // （不做 MD5），body 不带 0x143。见下方 withTgtgt / buildToken 两处注释。
    Uint8List? a2Key,
    bool smsLogin = false,
  }) async {
    // 闸门：口令链（token == null 且没有 A1，含手机号验证登录）没有官方 native
    // 真签时默认禁止。理由见 lib/kernel/safety/login_policy.dart 与
    // docs/RESEARCH-code45.md。
    // 票据续期（token != null）与 A1 对那条（a1 != null，子命令 15）都不是口令链，
    // 不受这条闸门影响。
    // 组包用的是纯 Dart 真签（`_tlvCtx` 恒为 Qq8T544Mode.oicq），如实上报给闸门；
    // 只有退回官方降级体（4 个零字节）时闸门才会重新拦下口令链。
    Qq8LoginPolicy.deviceSignatureAvailable = true;
    if (token == null &&
        a1 == null &&
        a2Key == null &&
        Qq8LoginPolicy.passwordLoginBlocked) {
      _emit(Qq8LoginSnapshot(
        stage: Qq8LoginStage.failed,
        uin: uin,
        error: Qq8LoginPolicy.blockedMessage,
      ));
      return;
    }
    _emit(Qq8LoginSnapshot(stage: Qq8LoginStage.connecting, uin: uin));
    _loginIsRenewal = token != null || a1 != null || a2Key != null;
    // 口令链（含短信续跑）不是免密恢复：清掉材料标记，让这类 16/155 仍按
    // 整票失效处理（没有"某条材料"可归因）。
    if (!_loginIsRenewal) _attemptMaterial = null;
    // 材料不足**不硬发**：空 A2KEY 既装不上 tgtgt，又不该退到口令链去发一个
    // 全零口令包（那就等于静默降级成密码登录）。planner 侧 `hasA2Key` 已保证
    // 非空，这里只是最后一层防线，直接报"凭证不足"让用户重登。
    if (a2Key != null && a2Key.isEmpty) {
      _log.w('A2KEY 为空（0 字节），不组包、不降级成口令链，请用户重新登录一次');
      _emit(Qq8LoginSnapshot(
        stage: Qq8LoginStage.sessionExpired,
        uin: uin,
        error: '登录凭证不足，请重新登录一次',
      ));
      return;
    }
    try {
      // 一次登录流程内的固定材料：设备按 uin 派生（同一账号恒定同一台设备），
      // ECDH / 会话标识 / 随机密钥都只生成一次，验证分支复用同一套。
      //
      // 手机号短信那条线（[smsLogin]）是"同一流程的延续"：设备/密钥在
      // [loginWithPhone] 里就建好了（那时只有 uin=0），这里**沿用**——
      // 官方整条流程只有一个设备身份，中途换设备是多余的风控信号。
      if (!smsLogin) {
        _device = (deviceBuilder ?? Qq8Device.generate)(uin);
        if (a2Key != null && a2Key.isNotEmpty) {
          // A2KEY 分支的约定：tgtgt **就是 A2KEY 原样**，不做任何派生。
          // 依据 `WtloginHelper.java:607-690` 的 3 元组形态 `tVarA.b = bArr2[2]`
          // （对比 4 元组的 `MD5.toMD5Byte(bArr2[3])`）；A2KEY 来自 0x119 明文里的
          // TLV `0x10d`（官方 tk_file 的 `WloginSigInfo._TGTKey`）。
          // 响应 0x119 就是用这个密钥加密的，`Qq8SigBundle.parse` 拿依赖它解开。
          _device = _device!.withTgtgt(a2Key);
        } else if (token != null) {
          // token 路径的约定：tgtgt = MD5(d2key)（没有密码就派生不出新的）
          _device = _device!.withTgtgt(md5Bytes(token.d2key));
        } else if (a1 != null) {
          // A1 路径的约定：tgtgt 取 A1 的尾部 16 字节。响应 0x119 票据块就是
          // 用这个 tgtgt 加密的，`Qq8SigBundle.parse(t119, _device!.tgtgt)`
          // 不换成它必然解不开（A1 里尾部就是 tgtgt，这也是给 0x106 去尾
          // 16B 的依据）。A1 短于 16B 时不猜、不崩：记一条 w 日志后照常发，
          // 由服务端裁决。
          if (a1.length >= 16) {
            _device = _device!.withTgtgt(a1.sublist(a1.length - 16));
          } else {
            _log.w('A1 只有 ${a1.length}B（不足 16B，取不出尾部 tgtgt），'
                '按服务端裁决照常发包');
          }
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
      final body = a2Key != null
          // A2+A2KEY 3 元组形态（`WtloginHelper.java:607-690`）：tgtgt 已经在上面
          // 用 A2KEY 原样装上，body 走子命令 11 但**不带 0x143**（官方该形态的 d2
          // 实参就是 null）。所以这里传 `d2: null`，**不用** `token?.d2`——
          // token 带进来只为提供 A2（body 的 0x10a）与 SSO 信封，把 d2 写进 body
          // 就变成官方没有的第三种形态（A2KEY 派生 + 又发 0x143）。
          ? Qq8LoginBody.buildToken(ctx, d2: null)
          : a1 != null
          // 子命令 15：0x106 塞 A1 密文（0x119 里的 0x106 是 en_A1），0x16A 塞
          // noPicSig，两者都是原样字节（`request/z.java` 的 set_data / get_tlv_16a）。
          // A1 带得比 16B 长时去掉尾部 16B（tgtgt）：官方 exchange_emp 原样塞密文，
          // 解不开时用这个回退形态。依据是 z.java，**live 未验证**。
          ? Qq8LoginBody.buildA1Exchange(
              ctx,
              a1: a1.length > 16 ? a1.sublist(0, a1.length - 16) : a1,
              noPicSig: noPicSig ?? Uint8List(0),
            )
          : token == null
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
          passwordMd5: null,
          token: null,
          da2BitActive: false,
          t544SubCmd: Qq8SubCmd.slider);
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
      final ctx = _tlvCtx(uin,
          passwordMd5: null, token: null, t544SubCmd: Qq8SubCmd.sendSms);
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
      final ctx = _tlvCtx(uin,
          passwordMd5: null, token: null, t544SubCmd: Qq8SubCmd.submitSms);
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
  // 发文件（私聊离线文件：申请 → HTTP 上传 → 声明完成 → 消息体）
  // ------------------------------------------------------------------

  /// 发一个**离线文件**（私聊）。**需已上线**。
  ///
  /// 链路见 `lib/kernel/wlogin8/qq8_file.dart`：1700 申请拿 fid/ticket →
  /// 走 bigdata 通道用 HTTP 把数据传上去（服务端已有同 md5 就跳过）→
  /// 800 声明完成 → 用 `msg_content`（`NotOnlineFile`）发一条消息。
  ///
  /// [name] 留空时用 `file<md5>`（与参考实现一致）；[onProgress] 是上传进度。
  ///
  /// 群文件是另一套命令（`GROUP_FILE` 系列、还有目录概念），本方法只管私聊。
  Future<Qq8MsgSendResult> sendFile({
    required Uint8List bytes,
    String name = '',
    required int uid,
    void Function(double progress)? onProgress,
    Duration? uploadTimeout,
  }) async {
    final s = _requireOnline();
    final info = Qq8FileInfo.of(name, bytes);
    _log.i('发文件 私聊 uid=$uid：$info');

    // ① 申请：拿 fid / ticket / 完整响应体
    final rsp = await s.sendUni(
      Qq8File.cmdApplyUpload,
      Qq8File.buildApplyUploadBody(uin: s.uin, peerUin: uid, file: info),
      timeout: timeout,
    );
    final t = Qq8File.parseApplyUpload(rsp.payload);
    if (!t.ok) {
      throw Qq8FileException('申请上传被拒：code=${t.code} ${t.message}');
    }
    _log.i('1700 回执：$t');

    // ② 传数据：服务端已有同 md5 就跳过（fid 仍按目标换）
    if (t.alreadyExists) {
      _log.i('服务端已有同 md5 的文件，跳过上传');
      onProgress?.call(1);
    } else {
      final ch = await _ensureBigdataChannel(s);
      final ext = Qq8File.buildHighwayExt(
        uin: s.uin,
        peerUin: uid,
        applyUploadResponse: t.rawResponse,
        file: info,
        fid: t.fid,
        ticket: t.ticket,
        subid: profile.apk.subid,
      );
      await Qq8File.uploadHttp(
        host: ch.host,
        port: ch.port,
        uin: '${s.uin}',
        subid: profile.apk.subid,
        ticket: ch.ticket,
        fileMd5: info.md5,
        data: bytes,
        ext: ext,
        timeout: uploadTimeout ?? const Duration(seconds: 300),
        onProgress: onProgress,
      );
      _log.i('文件上传完成：${bytes.length} 字节 → ${ch.host}:${ch.port}');
    }

    // ③ 声明上传完成
    final rsp2 = await s.sendUni(
      Qq8File.cmdUploadSucc,
      Qq8File.buildUploadSuccBody(uin: s.uin, peerUin: uid, fid: t.fid),
      timeout: timeout,
    );
    if (!Qq8File.parseUploadSucc(rsp2.payload)) {
      throw Qq8FileException(
          '上传完成（800）被拒：响应 ${rsp2.payload.length} 字节');
    }

    // ④ 发消息体
    final seq = s.nextSeq();
    final rand = _randomU32();
    final body = Qq8FileMsg.buildC2cBody(
      uid: uid,
      seq: seq,
      rand: rand,
      fid: t.fid,
      md5: info.md5,
      name: info.name,
      size: info.size,
      syncCookieSeed: _sessionSeedU32(),
      nowSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      syncR5: _randomU32(),
      syncR9: _randomU32(),
      syncR11: _randomU32(),
    );
    final rsp3 =
        await s.sendUni(Qq8Msg.sendCmd, body, seq: seq, timeout: timeout);
    final r = Qq8Msg.parseSendResponse(rsp3.payload, seq: seq, rand: rand);
    _log.i('文件消息 uid=$uid fid=${t.fid} code=${r.code} '
        '${r.ok ? 'ok' : r.message}');
    return r;
  }

/// 把若干条消息合并转发成一张"聊天记录"卡片（QQ 的合并转发）。
  ///
  /// **需已上线**。[target] 在 [group] 为真时是群号，否则是好友 uin。
  /// 链路见 `lib/kernel/wlogin8/qq8_multimsg.dart` 头注：
  /// ApplyUp → highway(id=27) → 发 XML 卡片。任何一步失败都抛
  /// [Qq8LoginException]（不返回"半个结果"）。
  Future<Qq8MsgSendResult> sendMultiMsg({
    required int target,
    required bool group,
    required List<Qq8MultiMsgNode> nodes,
    String cardFileName = 'MULTIMSG',
  }) async {
    if (nodes.isEmpty) {
      throw Qq8LoginException('合并转发至少要有一条消息');
    }
    final s = _requireOnline();
    final built = <Uint8List>[];
    for (final n in nodes) {
      built.add(Qq8MultiMsg.buildNode(
        senderUin: n.senderUin,
        target: target,
        dm: !group,
        seq: _randomU32() & 0xFFFF,
        time: n.time,
        rand: _randomU32(),
        rich: Qq8Msg.richElems(n.elems),
        nickname: n.nickname,
      ));
    }
    final content = Qq8MultiMsg.buildContent(built);
    final compressed = Qq8MultiMsg.gzipContent(content);

    // ① 申请上传
    final up = await s.sendUni(
      Qq8MultiMsg.cmdApplyUp,
      Qq8MultiMsg.buildApplyUpBody(
        target: target,
        size: compressed.length,
        md5: md5Bytes(compressed),
        apkVersion: profile.apk.ver,
      ),
      timeout: timeout,
    );
    final ticket = Qq8MultiMsg.parseApplyUp(up.payload);
    if (ticket == null) {
      throw Qq8LoginException(
          'MultiMsg.ApplyUp 应答解析失败（${up.payload.length} 字节）');
    }
    if (!ticket.ok) {
      throw Qq8LoginException('MultiMsg.ApplyUp 被拒（code=${ticket.code}）');
    }
    if (ticket.host.isEmpty || ticket.port <= 0 || ticket.ticket.isEmpty) {
      throw Qq8LoginException(
          'MultiMsg.ApplyUp 没给上传通道（${ticket.host}:${ticket.port}）');
    }
    _log.i('合并转发 ApplyUp resid=${ticket.resid} 通道=${ticket.host}:${ticket.port} '
        '压缩后 ${compressed.length} B');

    // ② highway 传内容（业务号 27）
    final body = Qq8MultiMsg.buildUploadBody(
      target: target,
      compressed: compressed,
      uploadKey: ticket.uploadKey,
    );
    await Qq8Highway.upload(
      host: ticket.host,
      port: ticket.port,
      uin: '${s.uin}',
      appid: profile.apk.subid,
      buCmdId: Qq8MultiMsg.cmdIdMultiMsg,
      ticket: ticket.ticket,
      fileMd5: md5Bytes(body),
      data: body,
      timeout: const Duration(seconds: 120),
    );

    // ③ 发卡片
    final previews = <String>[
      for (final n in nodes.take(4))
        n.brief.isEmpty ? n.nickname : '${n.nickname}: ${n.brief}',
    ];
    final xml = Qq8MultiMsg.buildXmlCard(
      resid: ticket.resid,
      total: built.length,
      fileSize: compressed.length,
      previews: previews,
      fileName: cardFileName,
    );
    final elem = Qq8MultiMsg.buildXmlElem(xml);
    final r = group
        ? await sendGroup(gid: target, elems: <Uint8List>[elem])
        : await sendC2c(uid: target, elems: <Uint8List>[elem]);
    _log.i('合并转发 → ${group ? 'group' : 'c2c'} $target 共 ${built.length} 条 '
        'resid=${ticket.resid} code=${r.code} ${r.ok ? 'ok' : r.message}');
    return r;
  }

  /// 取（必要时主动查一次）bigdata 上传通道。
  ///
  /// 通道一般由登录后的 `ConfigPushSvc.PushReq`（type=2）下发；没收到时
  /// 用 `HttpConn.0x6ff_501` 补问一次。
  Future<({String host, int port, Uint8List ticket})> _ensureBigdataChannel(
      Qq8Session s) async {
    final cached = _bigdataSigSession;
    final host = _bigdataHost;
    final port = _bigdataPort;
    if (host != null && port != null && cached != null && cached.isNotEmpty) {
      return (host: host, port: port, ticket: cached);
    }
    _log.i('还没有 bigdata 通道，主动查一次（${Qq8File.cmdBigdataChannel}）');
    final rsp = await s.sendUni(
      Qq8File.cmdBigdataChannel,
      Qq8File.buildBigdataChannelBody(uin: s.uin),
      timeout: timeout,
    );
    final got = Qq8File.parseBigdataChannel(rsp.payload);
    if (got == null || got.ticket.isEmpty) {
      throw Qq8FileException('没有 bigdata 上传通道'
          '（响应 ${rsp.payload.length} 字节，解析不出 ip/port）');
    }
    _bigdataHost = got.host;
    _bigdataPort = got.port;
    _bigdataSigSession = got.ticket;
    _log.i('bigdata 通道：${got.host}:${got.port} '
        'ticket=${got.ticket.length}B');
    return got;
  }

  /// 取一个离线文件的下载直链（1200）。需已上线。
  Future<Qq8FileLink> fetchFileLink({required String fid}) async {
    final s = _requireOnline();
    final rsp = await s.sendUni(
      Qq8File.cmdApplyDownload,
      Qq8File.buildApplyDownloadBody(uin: s.uin, fid: fid),
      timeout: timeout,
    );
    final link = Qq8File.parseApplyDownload(rsp.payload);
    _log.i('文件直链 fid=$fid → ${link.url}（${link.size} B）');
    return link;
  }

  /// 把一个离线文件**下载到内存**（1200 取直链 → HTTP GET）。
  ///
  /// 需要落到磁盘时由调用方写文件——L3 不碰具体存储路径。
  Future<Uint8List> downloadFile({
    required String fid,
    Duration? downloadTimeout,
    int maxBytes = 100 << 20,
  }) async {
    final link = await fetchFileLink(fid: fid);
    final bytes = await Qq8File.downloadHttp(
      url: link.url,
      timeout: downloadTimeout ?? const Duration(seconds: 120),
      maxBytes: maxBytes,
    );
    _log.i('文件下载完成 fid=$fid ${bytes.length} B');
    return bytes;
  }

  /// 撤回一个离线文件（400）。需已上线。
  Future<void> recallFile({required String fid}) async {
    final s = _requireOnline();
    final rsp = await s.sendUni(
      Qq8File.cmdRecall,
      Qq8File.buildRecallBody(uin: s.uin, fid: fid),
      timeout: timeout,
    );
    if (!Qq8File.parseRecall(rsp.payload)) {
      throw Qq8FileException('撤回文件被拒（响应 ${rsp.payload.length} 字节）');
    }
    _log.i('文件已撤回 fid=$fid');
  }

  /// 把一个离线文件转发给另一个私聊（700），返回**新的** fid。
  Future<String> forwardFile({required String fid, required int toUid}) async {
    final s = _requireOnline();
    final rsp = await s.sendUni(
      Qq8File.cmdForward,
      Qq8File.buildForwardBody(uin: s.uin, peerUin: toUid, fid: fid),
      timeout: timeout,
    );
    final r = Qq8File.parseForward(rsp.payload);
    if (!r.ok || r.newFid.isEmpty) {
      throw Qq8FileException('转发文件被拒：${r.message}');
    }
    _log.i('文件已转发 fid=$fid → ${r.newFid}（to=$toUid）');
    return r.newFid;
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
    // 游标只按**实际拿到的消息 seq** 推进，绝不用 `returnEndSeq`。
    // 后者只是把我们请求的 endSeq 原样回显（C33 实证）：真机 2026-10-25
    // 曾被它推到 10114，而服务端真实最新只有 9934，之后所有轮询都在请求
    // 「最新之后」的空区间，于是「群消息一条都没有」。
    _advanceGroupCursor(groupCode, page);
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
    for (final fr in friends) {
      _rememberFriendName(fr.uin, fr.displayName);
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
    // 给群消息轮询铺底：每个群探一次最新 seq（不 emit，历史由用户
    // 打开会话时再拉）。没有这个底，轮询不知道从哪个 seq 开始。
    if (page.groups.isNotEmpty) {
      if (primeGroupSeqs) unawaited(primeGroups([for (final g in page.groups) g.gid]));
    }
    return page;
  }

  /// 探一遍群的最新 seq（`endSeq=0` = 服务端补成最新）。
  ///
  /// 只记 seq 不发消息事件——启动时把每个群最近的消息都 emit 一遍
  /// 没有意义，历史在用户打开会话时按需拉。
  /// 重新问一次 `PbUnReadMsgSeq`，把游标校准到服务端真值。
  /// 探测失败（抛/全空）就保持现状——不影响本轮私聊拉取。
  Future<void> _resyncGroupSeqs() async {
    final session = _session;
    if (session == null) return;
    final codes = [
      for (final e in _groupLastSeq.entries)
        // 103 的群水位永远不会变（服务端对本账号没有可下发内容），
        // 每轮都问它只是白烧一个 TLV（见 [_groupDead]）。
        if (!_primeFailed.contains(e.key) && !_groupDead.contains(e.key)) e.key,
    ];
    if (codes.isEmpty) return;
    try {
      final rsp = await session.sendUni(
        'PbMessageSvc.PbUnReadMsgSeq',
        Qq8Pb.encode(<int, Object?>{
          3: Qq8Pb.encode(<int, Object?>{
            1: <Object?>[
              for (final g in codes) Qq8Pb.encode(<int, Object?>{1: g, 2: 0}),
            ],
          }),
        }),
      );
      final m = Qq8Pb.decode(rsp.payload);
      final inner = (Qq8Pb.bytesAt(m, 3) ?? Uint8List(0));
      final m3 = Qq8Pb.decode(inner);
      final result = Qq8Pb.intAt(m3, 1) ?? -1;
      final infos = (m3[3] ?? const <Object>[]).cast<Object>();
      var updated = 0;
      for (final raw in infos) {
        final info = Qq8Pb.decode(Uint8List.fromList(raw as List<int>));
        final code = Qq8Pb.intAt(info, 1) ?? 0;
        final seq = Qq8Pb.intAt(info, 3) ?? 0;
        final known = _groupLastSeq[code] ?? 0;
        if (code > 0 && seq != known) {
          // 水位动了 = 有新消息，之前"窗口问空"的结论失效，放开探测。
          _groupWindowIdle.remove(code);
          // 服务端真值可能**低于**盲推进的光标——(0,0)/103/104 的
          // returnEndSeq 把光标越推越远（真机 17:47 实证：盲 10214 vs 真 9934）。
          // 无论方向都以真值为准；真值更高才回看（真值更低说明之前
          // 拉到的窗口本来就空，无需补）。
          _log.w('群 $code 游标重校准：$known → $seq');
          // **先把缺口补上再推游标**。之前是 `unawaited(_catchUpGroup(...))`
          // 紧接着就写游标：补拉一旦失败（超时/空页），游标已经跳过去了，
          // 那段消息就再也拉不回来（C36 的「永久跳过」同一类错）。
          if (seq > known) {
            await _catchUpGroup(code, from: known + 1, to: seq);
          }
          _groupLastSeq[code] = seq;
          updated++;
        }
      }
      if (updated > 0) {
        _log.i('群 seq 重校准：$updated 个群有跳变（result=$result）');
      }
    } on Object catch (err) {
      if (_markAuthLost(err, '群 seq 重校准')) return;
      _log.d('群 seq 重校准失败（保持现状）：$err');
    }
  }

  /// 回看某群的 [from, to] seq 区间（游标跳变时补拉），**分页补齐，不丢中间段**。
  ///
  /// 旧实现只拉最后 20 条就完事：离线一小时、水位跳了 300 条时，中间 280 条
  /// 永久消失，只剩最后 20 条能看见——用户看到的就是"消息断了一大段"。
  /// 现在按 PbGetGroupMsg 的窗口上限（20 条）一页页往前推。
  ///
  /// 上限 [_catchUpMaxPages] 页（=120 条）是刻意的：真出现几百条的缺口时，
  /// 一次性补完会把轮询拖成几十秒、还会挤掉私聊。缺口更大时保留最新的一段，
  /// 其余靠用户打开会话时的历史翻页（`fetchHistory`）自己取。
  static const int _catchUpPageSize = 20;
  static const int _catchUpMaxPages = 6;

  Future<void> _catchUpGroup(int groupCode,
      {required int from, required int to}) async {
    if (from < 1) from = 1;
    if (to < from) return;
    final total = to - from + 1;
    var begin = from;
    final maxSpan = _catchUpPageSize * _catchUpMaxPages;
    if (total > maxSpan) {
      begin = to - maxSpan + 1;
      _log.w('群 $groupCode 缺口 $total 条，超过补拉上限 $maxSpan，只补 $begin-$to（更早的靠翻历史）');
    }
    try {
      while (begin <= to) {
        final end = (begin + _catchUpPageSize - 1 > to) ? to : begin + _catchUpPageSize - 1;
        final page = await fetchGroupHistory(
          groupCode: groupCode,
          beginSeq: begin,
          endSeq: end,
        );
        _log.i('群 $groupCode 回看 $begin-$end：result=${page.result} 条数=${page.messages.length}');
        if (page.result == 103) {
          // 服务端对该群的准入结论，本会话不再试（与 _pollGroups 同一判据）。
          _groupDead.add(groupCode);
          _log.i('群 $groupCode 服务端判 103（该群无内容可下发），本会话不再拉取');
          return;
        }
        if (page.messages.isNotEmpty) _emitGroupPage(groupCode, page);
        // 空页也要往前走，否则同一个窗口会一直重试到上限。
        begin = end + 1;
      }
    } on Object catch (err) {
      _log.d('群 $groupCode 回看失败：$err');
    }
  }

  Future<void> primeGroups(List<int> groupCodes) async {
    final session = _session;
    if (session == null) return;
    // 只对还没铺底的群发探测；已铺底（哪怕没拿到 seq）不重发——
    // 真机教训：群列表每 12~23 秒刷一次，重发会变成请求风暴，
    // 私聊轮询也被挤在后面（用户感知"私聊变慢"）。
    final pending = [
      for (final gid in groupCodes)
        if (!_groupLastSeq.containsKey(gid) && !_primeFailed.contains(gid)) gid,
    ];
    if (pending.isEmpty) return;
    // 批量引导一次：官方 `PbMessageSvc.PbUnReadMsgSeq` 本来就是批量的——
    // 之前放在 per-gid 循环里，每群都全量重发一遍 = 7 群 49 请求，纯浪费。
    // 出处：jadx8950 msg_svc$PbUnReadMsgSeqReq/Resp 的 __fieldMap__、
    // MessageHandler.java:5246-5287（response handler）。
    //   PbUnReadMsgSeqReq.__fieldMap__ = [10,18,26,34,42]
    //   ⇒ group_unread_info 是字段 3；响应同布局：字段 3 =
    //     PbPullGroupMsgSeqResp{1:result, 2:errmsg, 3:[GroupInfoResp]}
    //     GroupInfoResp{1:group_code, 2:member_seq, 3:group_seq}。
    try {
      final rsp2 = await session.sendUni(
        'PbMessageSvc.PbUnReadMsgSeq',
        Qq8Pb.encode(<int, Object?>{
          3: Qq8Pb.encode(<int, Object?>{
            1: <Object?>[
              for (final g in pending) Qq8Pb.encode(<int, Object?>{1: g, 2: 0}),
            ],
          }),
        }),
      );
      final m2 = Qq8Pb.decode(rsp2.payload);
      final inner = (Qq8Pb.bytesAt(m2, 3) ?? Uint8List(0));
      final m3 = Qq8Pb.decode(inner);
      final result = Qq8Pb.intAt(m3, 1) ?? -1;
      final infos = (m3[3] ?? const <Object>[]).cast<Object>();
      _log.d('unreadseq result=$result 条目=${infos.length}');
      for (final raw in infos) {
        final info = Qq8Pb.decode(Uint8List.fromList(raw as List<int>));
        final code = Qq8Pb.intAt(info, 1) ?? 0;
        final seq = Qq8Pb.intAt(info, 3) ?? 0;
        if (code > 0 && seq > 0) {
          _groupLastSeq[code] = seq;
          _log.i('群 $code 最新 seq=$seq（PbUnReadMsgSeq）');
        }
      }
    } on Object catch (err) {
      _log.d('unreadseq 抛 $err');
    }
    for (final gid in pending) {
      if (_groupLastSeq.containsKey(gid)) continue;
      try {
        // (0,0) 区间会被服务端拒（真机 result=103/108），必须先问真实 seq
        // OIDB 命令要再包一层 `{1: cmd, 2: sub, 3: 0, 4: body, 6: "android <ver>"}`
        // （oicq client.ts:584 sendOidb / icqq base-client.js:1125 同款）。
        // 第一版直接把内层 body 发出去，服务端回了个空壳。
        final rsp = await session.sendUni(
          Qq8History.cmdGroupInfo,
          Qq8Pb.encode(<int, Object?>{
            1: 0x88d,
            2: 0,
            3: 0,
            4: Qq8History.buildGroupLastSeqBody(
              subAppId: profile.apk.subid,
              groupCode: gid,
            ),
            6: 'android ${profile.apk.ver}',
          }),
        );
        var seq = Qq8History.parseGroupLastSeq(rsp.payload);
        if (seq != null && seq > 0) {
          _groupLastSeq[gid] = seq;
          _log.d('群 $gid 最新 seq=$seq');
        } else {
          _primeFailed.add(gid);
          _log.w('群 $gid 没拿到最新 seq（两路都空，本轮会话不再重试）');
        }
      } on Object catch (e) {
        _log.d('群 $gid seq 探测失败', error: e);
      }
    }
  }

  /// 把群游标推进到本页**实际收到的最大 seq**。
  ///
  /// 只认「真的收到了什么」，不认响应里的 `returnEndSeq`——那只是把请求的
  /// endSeq 原样回显（C33 实证），拿它推进会让游标越推越远（C36）。
  void _advanceGroupCursor(int groupCode, Qq8HistoryPage page) {
    if (page.messages.isEmpty) return;
    final maxSeq = page.messages
        .map((m) => m.seq)
        .fold<int>(0, (a, b) => b > a ? b : a);
    // 真收到消息 ⇒ 群里确实有流量，放开窗口探测。
    _groupWindowIdle.remove(groupCode);
    if (maxSeq > (_groupLastSeq[groupCode] ?? 0)) {
      _groupLastSeq[groupCode] = maxSeq;
    }
  }

  /// 把一页群消息派发成推送事件（走与真推送同一条流水线：建会话/未读/去重）。
  void _emitGroupPage(int groupCode, Qq8HistoryPage page) {
    if (page.messages.isEmpty) return;
    for (final m in page.messages) {
      if (_events.isClosed) return;
      _events.add(Qq8MessagePush(
        Qq8PushCmd.pushGroup,
        message: m,
        needsAck: false,
      ));
    }
  }

  /// 群消息轮询。
  ///
  /// 8.2.11 代际群消息**没有拉式同步**（`PbGetMsg` 的会话块只有私聊，
  /// icqq 同款——群消息只走 `OnlinePush.PbPushGroupMsg` 推送），
  /// 推送不来时唯一可靠的路就是按 seq 区间轮询。
  ///
  /// 每个群分两阶段（C36）：
  /// - **首次**：`_groupLastSeq` 里是服务端给的**水位**，往**回**拉一窗
  ///   `[水位-19, 水位]`，这窗才是「用户没看过的最近消息」。
  /// - **之后**：按游标往前 `[游标+1, 游标+20]`。
  Future<void> _pollGroups(String reason) async {
    // 重入闩：`_pullNewMessagesInner` 是在 finally 里 `unawaited(_pollGroups(...))`
    // 的，上一轮还没跑完下一轮就开始了。真机日志里同一个群同一个窗口在
    // 114ms 内被问了两遍（`群历史 gid=486045673 seq=57661-57680 result=104` 连出
    // 两条），每个群翻一倍请求量，弱网下正是 -10008 堆积的推手。
    // 丢一轮不丢消息：游标没动，下一轮问的还是同一个窗口（C36）。
    if (_pollingGroups) return;
    _pollingGroups = true;
    try {
      await _pollGroupsInner(reason);
    } finally {
      _pollingGroups = false;
    }
  }

  bool _pollingGroups = false;

  Future<void> _pollGroupsInner(String reason) async {
    for (final e in _groupLastSeq.entries.toList()) {
      if (_snapshot.stage != Qq8LoginStage.online) return;
      final gid = e.key, last = e.value;
      // 103 = 服务端对该群的准入结论（见 [_groupDead]），本会话不再试。
      if (_groupDead.contains(gid)) continue;
      // 窗口已问空且之后没有任何新证据：这一轮别再问（见 [_groupWindowIdle]）。
      if (_groupWindowIdle.contains(gid)) continue;
      final firstSync = !_groupSynced.contains(gid);
      final begin = firstSync ? (last - 19 < 1 ? 1 : last - 19) : last + 1;
      final end = firstSync ? last : last + 20;
      try {
        if (firstSync) {
          if (last <= 20) {
            // 水位太小，往回一窗没有意义（群里还没几条消息）。
            _groupSynced.add(gid);
            continue;
          }
          _groupSynced.add(gid);
        }
        final page = await fetchGroupHistory(
          groupCode: gid,
          beginSeq: begin,
          endSeq: end,
        );
        if (page.messages.isEmpty) {
          // 空页不等于出错：必须按 result 分流。
          // 四份真机日志累计 8517 次群历史请求、result=0 一次都没有，
          // 其中 103 是「该群对本账号无可下发内容」的准入结论（见
          // [_groupDead]），再拉一万次也还是 103。
          switch (page.result) {
            case 103:
              // 官方离线库（offdb）里这三个 103 群连
              // mr_troop_<md5(群号)> 表都不存在，反证服务端确实不给内容。
              _groupDead.add(gid);
              _log.i('群 $gid 服务端判 103（该群无内容可下发），本会话不再拉取');
            case 0:
            case 104:
              // 0/104 = 窗口内没有新消息（104 = 区间越界/无更新）。
              // **不能推进游标**：新消息就落在 `游标+1..` 这段，推进到
              // 窗口末尾会把真消息永远跳过去（C36 的教训）。
              // 但**也不必每轮重问**：记进 [_groupWindowIdle]，等出现新证据
              // （群推送 / 水位跳变 / 重新上线）再回来问。
              // 第一次的往回窗口例外——它拉的是历史，空就是空，标记已同步，
              // 下一轮的向前窗口才是真正的探测起点。
              if (!firstSync) _groupWindowIdle.add(gid);
              break;
            default:
              _log.d('$reason（群 $gid）空页但 result=${page.result}');
          }
          continue;
        }
        _log.i('$reason（群）：gid=$gid 新消息 ${page.messages.length} 条'
            '${firstSync ? '（首次同步回看 $begin-$end）' : ''}');
        _emitGroupPage(gid, page);
      } on Object catch (err) {
        // 103/104 之外唯一的"群级"硬失败：身份没了。整轮都别跑了。
        if (_markAuthLost(err, '$reason（群 $gid）')) return;
        _log.d('$reason（群 $gid）失败', error: err);
      }
    }
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

  /// 撤回自己发的一条群消息（单包或**分片**）。**需已上线**。
  ///
  /// [pktNum] > 1 表示这条是被分片发出的（消息 ID 里带片数），
  /// 撤回体要按片展开，见 `Qq8Msg.buildGroupWithdrawBody` 的注释。
  Future<({int result, String errmsg})> withdrawGroup({
    required int gid,
    required int seq,
    required int rand,
    int pktNum = 1,
  }) async {
    final s = _requireOnline();
    final frame = await s.sendUni(
      Qq8Msg.withdrawCmd,
      Qq8Msg.buildGroupWithdrawBody(
        gid: gid,
        seq: seq,
        rand: rand,
        pktNum: pktNum,
      ),
      timeout: timeout,
    );
    final r = Qq8Msg.parseWithdrawResponse(frame.payload, group: true);
    _log.i('群撤回 gid=$gid seq=$seq pktNum=$pktNum result=${r.result} ${r.errmsg}');
    return r;
  }

  /// 戳一戳。**需已上线**。
  ///
  /// [gid] 为 null 表示私聊（只有 [peerUin] 有意义），否则是群。
  /// 群/私聊同一个命令字 `OidbSvc.0xed3`，只是 body 不同
  /// （参考实现 `lib/member.ts:189-196` 与 `lib/friend.ts:388-396`）。
  ///
  /// 判据见 `Qq8Msg.parsePokeResponse`（参考实现看应答 `[3] === 0`）。
  Future<({bool ok, int? code})> sendPoke({
    required int peerUin,
    int? gid,
  }) async {
    final s = _requireOnline();
    final selfUin = snapshot.uin;
    if (selfUin == null) throw Qq8LoginException('还没上线，不知道自己的 uin');
    final inner = gid == null
        ? Qq8Msg.buildFriendPokeBody(selfUin: selfUin, peerUin: peerUin)
        : Qq8Msg.buildGroupPokeBody(uid: peerUin, gid: gid);
    final frame = await s.sendUni(
      Qq8Msg.pokeCmd,
      Qq8Msg.buildOidbWrapper(
        type1: Qq8Msg.pokeType1,
        type2: Qq8Msg.pokeType2,
        body: inner,
        apkVersion: profile.apk.ver,
      ),
      timeout: timeout,
    );
    final r = Qq8Msg.parsePokeResponse(frame.payload);
    _log.i('戳一戳 peer=$peerUin gid=$gid code=${r.code} ok=${r.ok}');
    return r;
  }

  /// 群设置 / 成员管理共用的 OIDB 外壳。
  ///
  /// 命令字形如 `OidbSvc.0x89a_0`：`type1 = 0x89a`、`type2 = 0`；
  /// 参考实现 `lib/client.ts:584-598 sendOidb`（`type2` 解析不出时按 1）。
  static ({int type1, int type2}) _oidbTypesOf(String cmd) {
    final body = cmd.startsWith('OidbSvc.') ? cmd.substring(8) : cmd;
    final parts = body.split('_');
    final head = parts.first;
    final hex = head.startsWith('0x') || head.startsWith('0X')
        ? head.substring(2)
        : head;
    final type1 = int.tryParse(hex, radix: 16) ?? 0;
    final type2 = parts.length > 1 ? (int.tryParse(parts[1]) ?? 1) : 1;
    return (type1: type1, type2: type2);
  }

  Future<Qq8SsoResponse> _sendGroupOidb(String cmd, Uint8List body) async {
    final s = _requireOnline();
    final t = _oidbTypesOf(cmd);
    return s.sendUni(
      cmd,
      Qq8Msg.buildOidbWrapper(
        type1: t.type1,
        type2: t.type2,
        body: body,
        apkVersion: profile.apk.ver,
      ),
      timeout: timeout,
    );
  }

  /// 改群名（`OidbSvc.0x89a_0` 的字段 3）。**需已上线，且自己是群主/管理员**。
  Future<({bool ok, int? code, String? message})> setGroupName({
    required int gid,
    required String name,
  }) async {
    final frame = await _sendGroupOidb(
      Qq8GroupAdmin.cmdSetting,
      Qq8GroupAdmin.buildSettingBody(gid: gid, name: name),
    );
    final r = Qq8GroupAdmin.parseSetting(frame.payload);
    _log.i('改群名 gid=$gid ok=${r.ok} code=${r.code}');
    return r;
  }

  /// 发（简易）群公告（同命令的字段 4）。**需已上线**。
  Future<({bool ok, int? code, String? message})> setGroupAnnounce({
    required int gid,
    required String content,
  }) async {
    final frame = await _sendGroupOidb(
      Qq8GroupAdmin.cmdSetting,
      Qq8GroupAdmin.buildSettingBody(gid: gid, announce: content),
    );
    final r = Qq8GroupAdmin.parseSetting(frame.payload);
    _log.i('发群公告 gid=$gid len=${content.length} ok=${r.ok} code=${r.code}');
    return r;
  }

  /// 全员禁言开/关（同命令的字段 17）。**需已上线**。
  Future<({bool ok, int? code, String? message})> setGroupWholeMute({
    required int gid,
    required bool enable,
  }) async {
    final frame = await _sendGroupOidb(
      Qq8GroupAdmin.cmdSetting,
      Qq8GroupAdmin.buildSettingBody(gid: gid, wholeMute: enable),
    );
    final r = Qq8GroupAdmin.parseSetting(frame.payload);
    _log.i('全员禁言 gid=$gid enable=$enable ok=${r.ok} code=${r.code}');
    return r;
  }

  /// 踢群成员（`OidbSvc.0x8a0_0`）。**需已上线，且自己是管理员**。
  Future<({bool ok, int? code, String? message})> kickGroupMember({
    required int gid,
    required int uid,
    bool rejectAddRequest = false,
  }) async {
    final frame = await _sendGroupOidb(
      Qq8GroupAdmin.cmdKick,
      Qq8GroupAdmin.buildKickBody(
          gid: gid, uid: uid, rejectAddRequest: rejectAddRequest),
    );
    final r = Qq8GroupAdmin.parseKick(frame.payload);
    _log.i('踢人 gid=$gid uid=$uid ok=${r.ok} code=${r.code}');
    return r;
  }

  /// 禁言单个成员（`OidbSvc.0x570_8`，秒数 0 = 解除）。**需已上线**。
  Future<({bool ok, int? code, String? message})> muteGroupMember({
    required int gid,
    required int uid,
    int seconds = 1800,
  }) async {
    final frame = await _sendGroupOidb(
      Qq8GroupAdmin.cmdMuteMember,
      Qq8GroupAdmin.buildMuteMemberBody(gid: gid, uid: uid, seconds: seconds),
    );
    final r = Qq8GroupAdmin.parseMuteMember(frame.payload);
    _log.i('禁言 gid=$gid uid=$uid seconds=$seconds ok=${r.ok} code=${r.code}');
    return r;
  }

  /// 设/取消管理员（`OidbSvc.0x55c_1`）。**需已上线，且自己是群主**。
  Future<({bool ok, int? code, String? message})> setGroupAdmin({
    required int gid,
    required int uid,
    required bool enable,
  }) async {
    final frame = await _sendGroupOidb(
      Qq8GroupAdmin.cmdSetAdmin,
      Qq8GroupAdmin.buildSetAdminBody(gid: gid, uid: uid, enable: enable),
    );
    final r = Qq8GroupAdmin.parseSetAdmin(frame.payload);
    _log.i('设管理员 gid=$gid uid=$uid enable=$enable ok=${r.ok} code=${r.code}');
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
    for (final m in members) {
      _rememberGroupMemberName(gid, m.uin, m.displayName);
    }
    _log.i('群成员列表 gid=$gid：${members.length} 人（$pages 页，result=$result）');
    return Qq8GroupMemberPage(result: result, nextUin: next, members: members);
  }

  // ------------------------------------------------------------------
  // 群文件（GFS：0x6d8 读 / 0x6d6 写 / 0x6d9 回执 + highway 71）
  // ------------------------------------------------------------------

  /// 群文件目录列表。**需已上线**。
  ///
  /// [pid] 传 `/` 就是根目录；目录条目的 fid 会以 `/` 开头（服务端约定）。
  /// 一页最多 100 条（参考实现固定 100），继续翻页把 [start] 加上已拿到的条数。
  Future<({int code, String? message, List<Qq8GfsEntry> entries})>
      fetchGroupFiles(
    int gid, {
    String pid = Qq8Gfs.rootPid,
    int start = 0,
    int limit = 100,
  }) async {
    final s = _requireOnline();
    final frame = await s.sendUni(
      Qq8Gfs.cmdDir,
      Qq8Msg.buildOidbWrapper(
        type1: Qq8Gfs.type1Dir,
        type2: 1,
        body: Qq8Gfs.buildDirBody(gid: gid, pid: pid, start: start, limit: limit),
        apkVersion: profile.apk.ver,
      ),
      timeout: timeout,
    );
    final r = Qq8Gfs.parseDir(frame.payload);
    _log.i('群文件列表 gid=$gid pid=$pid start=$start code=${r.code} '
        '条目=${r.entries.length}');
    return r;
  }

  /// 单个群文件/目录的属性（`0x6d8_0`）。**需已上线**。
  Future<({int code, String? message, Qq8GfsEntry? entry})> groupFileStat(
    int gid,
    String fid,
  ) async {
    final s = _requireOnline();
    final frame = await s.sendUni(
      Qq8Gfs.cmdStat,
      Qq8Msg.buildOidbWrapper(
        type1: Qq8Gfs.type1Dir,
        type2: 0,
        body: Qq8Gfs.buildStatBody(gid: gid, fid: fid),
        apkVersion: profile.apk.ver,
      ),
      timeout: timeout,
    );
    return Qq8Gfs.parseStat(frame.payload);
  }

  /// 取群文件的下载直链（`0x6d6_2`）。**需已上线**。
  ///
  /// 返回的 URL 形如 `http://<host>/ftn_handler/<token>/?fname=<名字>`，
  /// 由调用方用 [Qq8File.downloadHttp] 或自己的 HttpClient 去下。
  Future<({String name, String url, int size, String fid})>
      groupFileDownloadUrl(int gid, String fid) async {
    final stat = await groupFileStat(gid, fid);
    final e = stat.entry;
    if (stat.code != 0 || e == null) {
      throw Qq8GfsException(
          '取群文件属性失败：${stat.message ?? stat.code}');
    }
    final s = _requireOnline();
    final frame = await s.sendUni(
      Qq8Gfs.cmdDownload,
      Qq8Msg.buildOidbWrapper(
        type1: Qq8Gfs.type1File,
        type2: 2,
        body: Qq8Gfs.buildDownloadBody(gid: gid, busid: e.busid, fid: e.fid),
        apkVersion: profile.apk.ver,
      ),
      timeout: timeout,
    );
    final r = Qq8Gfs.parseDownload(frame.payload);
    if (r.code != 0 || r.host.isEmpty) {
      throw Qq8GfsException('取群文件下载地址失败：${r.message ?? r.code}');
    }
    final url = Qq8Gfs.buildDownloadUrl(
        host: r.host, tokenHex: r.tokenHex, name: e.name);
    _log.i('群文件下载地址 gid=$gid fid=${e.fid} → $url');
    return (name: e.name, url: url, size: e.size, fid: e.fid);
  }

  /// 上传一个文件到群（申请 `0x6d6_0` → highway 71 → 回执 `0x6d9_4`）。
  /// **需已上线**。
  ///
  /// 服务端已有同 md5 文件时会**秒传**（应答字段 10 非 0），此时跳过传输直接回执。
  Future<Qq8GfsEntry> uploadGroupFile({
    required int gid,
    required String name,
    required Uint8List bytes,
    String pid = Qq8Gfs.rootPid,
    void Function(double progress)? onProgress,
    Duration uploadTimeout = const Duration(seconds: 300),
  }) async {
    if (bytes.isEmpty) throw Qq8GfsException('要上传的文件是空的');
    final s = _requireOnline();
    final self = s.uin;
    final md5 = md5Bytes(bytes);
    final sha1 = sha1Bytes(bytes);

    final applyFrame = await s.sendUni(
      Qq8Gfs.cmdApplyUpload,
      Qq8Msg.buildOidbWrapper(
        type1: Qq8Gfs.type1File,
        type2: 0,
        body: Qq8Gfs.buildApplyUploadBody(
          gid: gid,
          name: name,
          size: bytes.length,
          md5: md5,
          sha1: sha1,
          pid: pid,
        ),
        apkVersion: profile.apk.ver,
      ),
      timeout: timeout,
    );
    final ap = Qq8Gfs.parseApplyUpload(applyFrame.payload);
    if (ap.code != 0 || ap.fid.isEmpty) {
      throw Qq8GfsException('群文件申请上传失败：${ap.message ?? ap.code}');
    }
    _log.i('群文件申请上传 gid=$gid name=$name size=${bytes.length} '
        '秒传=${ap.exists} busid=${ap.busid} fid=${ap.fid}');

    if (!ap.exists) {
      final ch = await _ensureBigdataChannel(s);
      final ext = Qq8Gfs.buildUploadExt(
        uin: self,
        gid: gid,
        name: name,
        size: bytes.length,
        md5: md5,
        sha1: sha1,
        busid: ap.busid,
        fid: ap.fid,
        uploadTicket: ap.uploadTicket,
        subid: profile.apk.subid,
        ext500a: ap.ext500a,
        ext500b: ap.ext500b,
      );
      await Qq8Highway.upload(
        host: ch.host,
        port: ch.port,
        uin: '$self',
        appid: profile.apk.subid,
        buCmdId: Qq8Gfs.highwayCmdIdGroupFile,
        ticket: ch.ticket,
        fileMd5: md5,
        data: bytes,
        ext: ext,
        netFlag: 2052,
        timeout: uploadTimeout,
        onProgress: onProgress,
      );
    }

    final feedFrame = await s.sendUni(
      Qq8Gfs.cmdFeed,
      Qq8Msg.buildOidbWrapper(
        type1: Qq8Gfs.type1Feed,
        type2: 4,
        body: Qq8Gfs.buildFeedBody(
          gid: gid,
          busid: ap.busid,
          fid: ap.fid,
          rand: Random().nextInt(0x7FFFFFFF),
        ),
        apkVersion: profile.apk.ver,
      ),
      timeout: timeout,
    );
    final fr = Qq8Gfs.parseFeed(feedFrame.payload);
    if (fr.code != 0) {
      throw Qq8GfsException('群文件上传回执失败：${fr.message ?? fr.code}');
    }
    final finalFid = fr.fid.isEmpty ? ap.fid : fr.fid;
    _log.i('群文件上传完成 gid=$gid fid=$finalFid');

    final stat = await groupFileStat(gid, finalFid);
    final e = stat.entry;
    if (e == null) {
      // 属性读失败不算上传失败：用本地已知信息拼一个等价条目回去。
      return Qq8GfsEntry(
        fid: finalFid,
        pid: pid,
        name: name,
        isDir: false,
        size: bytes.length,
        busid: ap.busid,
        md5: md5,
        sha1: sha1,
        uploaderUin: self,
      );
    }
    return e;
  }

  /// 删除群文件**或目录**。**需已上线**。
  ///
  /// 文件和目录是两条命令（`0x6d6_3` / `0x6d7_1`），但是同一件事，
  /// 调用方不需要知道自己删的是哪种——按 [file].isDir 内部分流。
  /// **删目录会连带删掉里面所有文件**，确认由 UI 负责。
  Future<({int code, String? message})> deleteGroupFile({
    required int gid,
    required Qq8GfsEntry file,
  }) async {
    final s = _requireOnline();
    if (file.isDir) {
      final frame = await s.sendUni(
        Qq8Gfs.cmdDeleteDir,
        Qq8Msg.buildOidbWrapper(
          type1: Qq8Gfs.type1DirWrite,
          type2: 1,
          body: Qq8Gfs.buildDeleteDirBody(gid: gid, fid: file.fid),
          apkVersion: profile.apk.ver,
        ),
        timeout: timeout,
      );
      final r = Qq8Gfs.parseDeleteDir(frame.payload);
      _log.i('删除群文件夹 gid=$gid fid=${file.fid} code=${r.code}');
      return r;
    }
    final frame = await s.sendUni(
      Qq8Gfs.cmdDelete,
      Qq8Msg.buildOidbWrapper(
        type1: Qq8Gfs.type1File,
        type2: 3,
        body: Qq8Gfs.buildDeleteBody(
          gid: gid,
          busid: file.busid,
          pid: file.pid.isEmpty ? Qq8Gfs.rootPid : file.pid,
          fid: file.fid,
        ),
        apkVersion: profile.apk.ver,
      ),
      timeout: timeout,
    );
    final r = Qq8Gfs.parseDelete(frame.payload);
    _log.i('删除群文件 gid=$gid fid=${file.fid} code=${r.code}');
    return r;
  }



  /// 建群文件夹（`0x6d7_0`，官方只允许建在**根目录**下）。**需已上线**。
  Future<({int code, String? message, Qq8GfsEntry? entry})> createGroupDir({
    required int gid,
    required String name,
  }) async {
    if (name.trim().isEmpty) throw Qq8GfsException('文件夹名字不能为空');
    final s = _requireOnline();
    final frame = await s.sendUni(
      Qq8Gfs.cmdMkdir,
      Qq8Msg.buildOidbWrapper(
        type1: Qq8Gfs.type1DirWrite,
        type2: 0,
        body: Qq8Gfs.buildMkdirBody(gid: gid, name: name.trim()),
        apkVersion: profile.apk.ver,
      ),
      timeout: timeout,
    );
    final r = Qq8Gfs.parseMkdir(frame.payload);
    _log.i('建群文件夹 gid=$gid name=${name.trim()} code=${r.code} '
        'fid=${r.entry?.fid}');
    return r;
  }

  /// 给群文件/目录改名（文件走 `0x6d6_4`、目录走 `0x6d7_2`）。**需已上线**。
  Future<({int code, String? message})> renameGroupEntry({
    required int gid,
    required Qq8GfsEntry entry,
    required String name,
  }) async {
    final newName = name.trim();
    if (newName.isEmpty) throw Qq8GfsException('新名字不能为空');
    final s = _requireOnline();
    final frame = await s.sendUni(
      entry.isDir ? Qq8Gfs.cmdRenameDir : Qq8Gfs.cmdRenameFile,
      Qq8Msg.buildOidbWrapper(
        type1: entry.isDir ? Qq8Gfs.type1DirWrite : Qq8Gfs.type1File,
        type2: entry.isDir ? 2 : 4,
        body: entry.isDir
            ? Qq8Gfs.buildRenameDirBody(gid: gid, fid: entry.fid, name: newName)
            : Qq8Gfs.buildRenameFileBody(
                gid: gid,
                busid: entry.busid,
                fid: entry.fid,
                pid: entry.pid.isEmpty ? Qq8Gfs.rootPid : entry.pid,
                name: newName,
              ),
        apkVersion: profile.apk.ver,
      ),
      timeout: timeout,
    );
    final r = entry.isDir
        ? Qq8Gfs.parseRenameDir(frame.payload)
        : Qq8Gfs.parseRenameFile(frame.payload);
    _log.i('群文件改名 gid=$gid fid=${entry.fid} dir=${entry.isDir} '
        'name=$newName code=${r.code}');
    return r;
  }

  /// 把群文件移到另一个目录（`0x6d6_5`）。**需已上线**。
  Future<({int code, String? message})> moveGroupFile({
    required int gid,
    required Qq8GfsEntry file,
    required String toPid,
  }) async {
    if (file.isDir) throw Qq8GfsException('移动只支持文件（目录不能移动）');
    final s = _requireOnline();
    final frame = await s.sendUni(
      Qq8Gfs.cmdMoveFile,
      Qq8Msg.buildOidbWrapper(
        type1: Qq8Gfs.type1File,
        type2: 5,
        body: Qq8Gfs.buildMoveFileBody(
          gid: gid,
          busid: file.busid,
          fid: file.fid,
          pid: file.pid.isEmpty ? Qq8Gfs.rootPid : file.pid,
          toPid: toPid,
        ),
        apkVersion: profile.apk.ver,
      ),
      timeout: timeout,
    );
    final r = Qq8Gfs.parseMoveFile(frame.payload);
    _log.i('移动群文件 gid=$gid fid=${file.fid} to=$toPid code=${r.code}');
    return r;
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
      if (sso.retcode != 0) {
        throw Qq8ServerRetcodeException(
          retcode: sso.retcode,
          seq: sso.seq,
          // 两条 code2d 请求走同一个信封命令字（见 qq8_qrcode.dart 头注）
          cmd: 'wtlogin.trans_emp',
        );
      }
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
      if (sso.retcode != 0) {
        throw Qq8ServerRetcodeException(
          retcode: sso.retcode,
          seq: sso.seq,
          cmd: 'wtlogin.trans_emp',
        );
      }
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
      // QIMEI 与密码路径同口径：有才进 0x545，没有就整条不发（官方 j.java
      // case 1349）。扫码链路此前不带 QIMEI，补表后与密码包对齐。
      final effectiveQimei = await _resolveQimei();
      final body2 = Qq8LoginBody.buildQrLogin(
        loginCtx,
        t106Data: q.t106!,
        tgtgt: q.tgtgt!,
        t16a: q.t16a!,
        tgtQR: q.t318!,
        qimei: effectiveQimei,
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

  /// 只拆连接（会话 + 传输层），**不动状态流**。
  ///
  /// 断线恢复用它：要换一条新连接，但不能因此把 `_states`/`_events` 关掉——
  /// 那会连带 UI 的 provider 一起结束。关闭失败吞掉：这条连接本来就已经坏了。
  Future<void> _teardownConnection() async {
    _sessionEpoch++; // 旧会话的异步任务从此作废
    _registerInFlight = null; // 旧会话的在途注册不可被新会话复用
    _pullTimer?.cancel();
    _pullTimer = null;
    await _pushSub?.cancel();
    _pushSub = null;
    final s = _session;
    _session = null;
    if (s != null) {
      try {
        await s.close();
      } on Object {
        // 已断的连接关闭时报错属正常
      }
    }
    final t = _tran;
    _tran = null;
    if (t != null) {
      try {
        await t.close();
      } on Object {
        // 同上
      }
    }
  }

  /// 结束会话（停心跳、关连接）。之后要再用就重新登录。
  Future<void> close() async {
    await _teardownConnection();
    _emit(const Qq8LoginSnapshot(stage: Qq8LoginStage.idle));
    await _states.close();
    await _events.close();
  }

  /// 回执 `ConfigPushSvc.PushResp`（只发不等）。
  ///
  /// 字段序与请求不同：请求是 1=type/2=data/3=seq，回执是 1=type/2=seq/
  /// 3=data(仅 type==3)。SSO 层 seq 取原推送帧的 seq（官方 a/c.java:606
  /// setRequestSsoSeq(fromServiceMsg.getRequestSsoSeq())）。
  void _ackConfigPush(Qq8ConfigPushReq req, int pushSeq) {
    final session = _session;
    if (session == null) return;
    final body = buildPushRespBody(
      type: req.type,
      seq: req.seq,
      data: req.data,
    );
    // 服务端从不回这个回执的包，必须只发不等；以前走 sendUni 会空等 10 秒。
    unawaited(session
        .sendUniNoReply('ConfigPushSvc.PushResp', body, seq: pushSeq)
        .then((_) => _log.i('ConfigPushSvc.PushReq 已回执（type=${req.type}）'))
        .catchError(
            (Object e) => _log.d('ConfigPushSvc.PushResp 失败', error: e)));
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
        // 群推送带体直达：之前"窗口问空"的结论作废（见 [_groupWindowIdle]）。
        final pushedGid = message.groupCode;
        if (pushedGid != null) _groupWindowIdle.remove(pushedGid);
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
      case Qq8ReqPush(
          :final svrip,
          :final pushType,
          :final groupCode,
          :final eventType,
        ):
        // 「有新消息，自己来拉」——不带消息体。之前这个命令字落在 default
        // 分支被当未知包丢掉（四份真机日志里一次都没出现过，说明服务端
        // 压根没进到会推它的状态，但**丢掉它等于把唯一的唤醒信号扔掉**）。
        // 处理：回执（服务端在等）+ 触发一次拉取。不动事件语义。
        _log.i('ReqPush 唤醒（pushType=$pushType gid=$groupCode event=$eventType）→ 回执 + 拉一次');
        if (svrip != null) unawaited(_ackPushRaw(svrip, r.seq));
        unawaited(_pullNewMessages(reason: 'ReqPush 唤醒'));
      case Qq8TransPush(:final svrip, :final transCmd, :final groupCode):
        // 群事件（禁言/撤回/成员进出/管理员变更）：只回执 + 记日志。
        // 事件本身要另建模型（成员列表、禁言状态），不在本轮范围。
        _log.i('群事件推送 gid=$groupCode cmd=$transCmd');
        if (svrip != null) unawaited(_ackPushRaw(svrip, r.seq));
      case Qq8UnknownPush(:final cmd, :final note):
        _log.d('未处理的推送 cmd=$cmd${note == null ? '' : '（$note）'}');
        // SSO.HelloPush = 推送通道握手。官方 msf/core/push/g.java:2343-2363
        // 的做法是「把收到的 wupBuffer 原样回送」（putWupBuffer + sendSsoMsg，
        // serviceCmd 仍是 SSO.HelloPush、seq 原样带回）。没回送 = 服务端认为
        // 推送通道不可用，于是只推配置类（不需要握手的）消息，
        // 真机 2026-10-24 全天 12 次 HelloPush 全被我们当"未注册"丢掉，
        // 这就是群消息/实时推送一直收不到的根因候选。
        if (cmd == 'SSO.HelloPush' && _session != null &&
            _snapshot.stage == Qq8LoginStage.online) {
          _log.i('SSO.HelloPush → 回送握手（官方语义：原样回声）');
          // 服务端**不回**这条回声（官方是同一条长连接上单向回送，
          // setNeedCallback(false) 语义）。以前用 sendUni 等应答，必然空等
          // 10 秒再报失败——改用只发不等。
          unawaited(_session!
              .sendUniNoReply('SSO.HelloPush', Uint8List.fromList(r.payload),
                  seq: r.seq)
              .then((_) => _log.d('HelloPush 回送已发出'))
              .catchError((Object e) {
            _log.d('HelloPush 回送失败', error: e);
          }));
        }
        // 官方对 StatSvc.QueryHB 的处理就是"重新注册推送"
        // （jadx-main msf/core/push/g.java:601-607，RegPushReason.serverPush）。
        // 服务端发 QueryHB 意思是"你还在吗，需要继续收推送吗"——
        // 不理它就会被降到只收配置推送（真机 11:41/12:12：QueryHB
        // 之后一条消息推送都没有）。这里照官方语义重注册 + 顺手拉一把。
        if (cmd == 'StatSvc.QueryHB' && _session != null &&
            _snapshot.stage == Qq8LoginStage.online) {
          _log.i('QueryHB → 重新注册推送（官方语义）并补拉');
          unawaited(_registerOnce(_session!).then((Qq8RegisterOutcome o) {
            // QueryHB 触发的重注册也要统一提交结果（旧版只打日志）：
            // 成功即恢复推送通道标记，未确认即置位，供在线检查降级。
            _lastRegisterOutcome = o;
            if (o == Qq8RegisterOutcome.confirmed) {
              _pushChannelUnconfirmed = false;
            } else if (o == Qq8RegisterOutcome.unconfirmed) {
              _pushChannelUnconfirmed = true;
            }
            _log.d('QueryHB 触发的重注册完成：${o.name}');
          }).catchError((Object e) {
            _log.d('QueryHB 触发的重注册失败', error: e);
          }));
          unawaited(_pullNewMessages(reason: 'QueryHB 补拉'));
        }
        // ConfigPushSvc.PushReq：icqq（base-client.js:1263-1324）的语义是
        // 「收到必须回 PushResp」，不回的话服务端不把推送全量打开
        // （真机 14:2x：私聊能拉到、群消息内容被扣——与只差「回执」的
        // 假设吻合）。响应体 = JCE wrapper：
        //   servant  QQService.ConfigPushSvc.MainServant
        //   method   PushResp
        //   struct   [config_type(嵌套[1]), seq(嵌套[3])]
        // 完整处理：先按 PushReq 解析 → 回执，再应用 type2 的 bigdata。
        //
        // 回执顺序按官方 a/c.java:500-524：dispatch（type2 只是转交应用进程）
        // 之后统一 b() 回执，故回执不依赖内层 pb 解析是否成功。以前把两者挤在
        // 一个流程里，内层解码一抛异常就连回执一起丢掉。
        if (cmd == 'ConfigPushSvc.PushReq' && _session != null) {
          try {
            final req = decodePushReq(r.payload);
            if (req == null) {
              _log.d('ConfigPush 请求解析失败（不回执）');
            } else {
              _ackConfigPush(req, r.seq);
              final bigdata = req.data;
              if (req.type == 2 && bigdata.isNotEmpty) {
              // icqq 两步解：`jce.decode(nested[2])[5][5]` 是 pb 的
              // `{1281: {1: sig_session, 2: session_key, 3: [...]}}`
              //（直接 pb.decode 会撞 wiretype 1，真机 15:13 实证）。
              final j = Qq8Jce.decode(Uint8List.fromList(bigdata));
              final l5 = j[5];
              if (l5 is List) {
                final inner5 = (l5 as List<Object?>)[4];
                if (inner5 is List<int> && inner5.isNotEmpty) {
                  final mi = Qq8Pb.decode(Uint8List.fromList(inner5));
                  final inner = Qq8Pb.bytesAt(mi, 1281);
                  if (inner != null) {
                    final m = Qq8Pb.decode(inner);
                    _bigdataSigSession = Qq8Pb.bytesAt(m, 1);
                    _bigdataSessionKey = Qq8Pb.bytesAt(m, 2);
                    // 1281.3 = [{1: 10, 2: [{2: ip(u32), 3: port}]}]（v[1]==10 才是
                    // 上传通道；参考实现 base-client.ts:612-622）。
                    final eps = m[3];
                    if (eps != null) {
                      for (final e in eps) {
                        if (e is! Uint8List) continue;
                        final em = Qq8Pb.decode(e);
                        if (Qq8Pb.intAt(em, 1) != 10) continue;
                        final list = em[2];
                        if (list == null || list.isEmpty) continue;
                        final first = list.first;
                        if (first is! Uint8List) continue;
                        final hm = Qq8Pb.decode(first);
                        final ip = Qq8Pb.intAt(hm, 2);
                        final port = Qq8Pb.intAt(hm, 3);
                        if (ip != null && port != null && port > 0) {
                          _bigdataHost = Qq8File.u32ToIp(ip);
                          _bigdataPort = port;
                        }
                      }
                    }
                    _log.i('bigdata 会话已存（sig_session=${_bigdataSigSession!.length}B '
                        'key=${_bigdataSessionKey!.length}B '
                        '通道=${_bigdataHost ?? '-'}:${_bigdataPort ?? '-'}）');
                  }
                }
              }
            }
            }
          } on Object catch (e) {
            _log.d('ConfigPush 处理失败', error: e);
          }
        }
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
  ///
  /// **只发不等**：服务端从不回执回包。以前用 [Qq8Session.sendUni] 等应答，
  /// 而推送的 seq 是服务端给的负数，必然空等 10 秒再抛超时
  /// （真机：`等待响应超时（seq=-1807239620，10s）`）。
  /// 官方对应实现 `MessageHandler` 里是 `setNeedCallback(false)`，发完就忘。
  Future<void> _ackPush(Qq8MessagePush ev, int seq) async {
    await _ackPushRaw(ev.svrip ?? 0, seq);
  }

  /// 回执通用实现：`ReqPush` / `PbPushTransMsg` / 消息推送都走这里。
  Future<void> _ackPushRaw(int svrip, int seq) async {
    final s = _session;
    final uin = _snapshot.uin;
    if (s == null || uin == null) return;
    try {
      final body = Qq8Msg.buildRespPushAck(
        uin: uin,
        svrip: svrip,
        seq: seq,
      );
      await s.sendUniNoReply(Qq8Msg.respPushCmd, body, seq: seq);
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
    // 0x544 的签要区分「这条请求是哪个子命令」（salt 里含子命令号）。
    // 登录 = 9、滑块提交 = 2、发短信 = 8、交短信码 = 7。
    // 复用同一个签会让服务端读到 sub 不一致的 0x544 → type=45（PITFALLS C70）。
    int t544SubCmd = 9,
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
      // 0x544：纯 Dart 真签（oicq 布局）。2026-10-29 实测：39 字节纯算法签
      // 首包直接过闸 → type=2（不再 45），不需要 libfekit/qsign。
      t544Mode: Qq8T544Mode.oicq,
      t544SubCmd: t544SubCmd,
      // 0x548 官方只有一条路径：服务端在 0x547/0x546 里下发挑战，客户端解完
      // 放进 t.an（pow/b.java:65）才会带。我们自己造一份 PoW 是维护版 oicq 的
      // 土办法，官方包里从来没有（TIM 密码首登 body 1038B，不含 0x548）。
      // 2026-10-28 实测：造它只会让包长从 1070 涨到 1558，且服务端回 45 的概率
      // 明显更高 —— 所以 lib 侧不再自造，只保留官方 an 路径。
      // （CLI 仍有 --pow / --no-pow 开关用于对照实验，见 tool/qq8_live_smoke.dart）
      t548: null,
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
    // 只在这条连接**从无到有**时记「已建立」。
    //
    // 以前无条件打，于是复用已有 socket 的那些调用（扫码轮询每 2 s 一次）
    // 全都印一遍「已建立」——真机 2026-10-26 23:00 那轮日志看起来像
    // 「每秒重建一次 TCP」，实际只是重复打印：`connect()` 开头有
    // `if (_socket != null) return;`，压根没重连。假日志比没日志更坏，
    // 它把人的注意力引到一个不存在的 bug 上。
    final wasConnected = tran.isConnected;
    await tran.connect();
    if (tran is Qq8TcpTransport) {
      final ep = tran.connectedEndpoint;
      if (ep == null) return;
      if (wasConnected) {
        _log.d('[连接] 复用已有连接 ${ep.key}');
      } else {
        _log.i('[连接] 已建立 ${ep.key}');
      }
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
    // **发出什么**也要记：原先只记响应，发出去的 TLV 一直靠推断。真机上
    // "档案换了、实际清单变没变""某项是不是被 guard 滤掉了"都只能靠猜
    // （2026-09-21 的教训：9.3.60 有没有真发 0x553 无从确认）。
    final peek = Qq8LoginBody.peekBody(body);
    _log.i('发登录包 uin=$uin subCmd=${peek.$1} TLV=${peek.$2.length}项 '
        '${peek.$2.map((t) => '0x${t.toRadixString(16)}').join(',')}');
    // 命令字按 **body 的实际子命令**定，不按有没有 token 猜：子命令 15
    // （A1 对）调进来时 token 是 null，但官方命令字仍是
    // `wtlogin.exchange_emp`（`request/z.java` 构造器 `this.v`），发成
    // `wtlogin.login` 服务端必拒。token 链（11）与口令链（9）行为不变。
    final subCmd = peek.$1;
    final cmd = qq8LoginCmdForSubCmd(subCmd);
    // 诊断标签要能区分 A1 包，别把它记成口令登录包。
    final diagTag = subCmd == Qq8SubCmd.a1Exchange
        ? 'a1'
        : (token == null ? 'login' : 'token');
    final pkt = Qq8Sso.buildLoginPacket(
      ssoCtx,
      cmd,
      Qq8Sso.buildOicqPacket(ssoCtx, body),
      Qq8LoginType.login,
    );

    final frame = await tran.send(pkt, timeout: timeout);
    final sso = qq8UnwrapRecv(frame);
    // retcode != 0 时拆壳层不再抛（2026-10-26 21:46 的教训：抛等于丢帧，
    // 等待方只能超时，服务端说的话一个字都读不到）。登录包的应答被拒要
    // 立刻按"服务端拒绝"报错，而不是拿空 payload 去解析出一句看不懂的话。
    if (sso.retcode != 0) {
      onDiagnostic?.call(diagTag, frame, null);
      throw Qq8ServerRetcodeException(
        retcode: sso.retcode,
        seq: sso.seq,
        cmd: cmd,
      );
    }
    late final Qq8LoginResponse r;
    try {
      r = Qq8LoginResponse.parse(sso.payload, ecdh.shareKey);
    } on Object {
      onDiagnostic?.call(diagTag, frame, null);
      rethrow;
    }
    onDiagnostic?.call(diagTag, frame, r);
    _log.i('登录响应 uin=$uin type=${r.type} '
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

  /// 从响应 0x130 读服务端时间（毫秒）。body 长度不足 6 或解析失败都返回 null。
  ///
  /// 结构：offset 0 的 u16 是标志/长度前缀，**offset 2 起是 u32 秒**。
  /// 只用来估本地时钟偏差，**绝不**据此推算票据到期时间。
  static int? _serverTimeMsFrom(Qq8LoginResponse r) {
    try {
      final b = r.tlvs[0x130];
      if (b == null || b.length < 6) return null;
      final secs = (b[2] << 24) | (b[3] << 16) | (b[4] << 8) | b[5];
      return secs * 1000;
    } catch (_) {
      return null;
    }
  }

  /// 小写 hex；空或 null 返回 null。
  static String? _hexOrNull(Uint8List? b) {
    if (b == null || b.isEmpty) return null;
    final sb = StringBuffer();
    for (final v in b) {
      sb.write(v.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
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
      // 票据落盘：**新建**一份，而不是 copyWith 旧票——重新登录就该把上一次的
      // invalidated 结论洗白（copyWith 传 null 表示"保持原值"，洗不掉）。
      //
      // 时间戳只记服务端明确给的东西：0x130 是服务端时间（用于估时钟偏差），
      // 0x138 只留原文 hex 作诊断，**不参与任何判定**（各项时长语义未证实）。
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final serverTimeMs = _serverTimeMsFrom(r);
      final lifetimeHex = _hexOrNull(r.tlvs[0x138]);
      // 续期要沿用这张票**首次**成功登录的时间，所以得读一遍旧票。
      int? issuedAtMs = nowMs;
      if (_loginIsRenewal) {
        final old = await tokenStore.load(uin);
        issuedAtMs = old?.issuedAtMs ?? nowMs;
      }
      await tokenStore.save(Qq8TokenData.fromSigBundle(
        uin,
        bundle,
        issuedAtMs: issuedAtMs,
        serverTimeMs: serverTimeMs,
        lifetimeTlvHex: lifetimeHex,
      ).copyWith(renewedAtMs: _loginIsRenewal ? nowMs : null));
      _loginIsRenewal = false;
      // 成功换票后材料标记用完即清（新票是全新的，不带任何失效结论）。
      _attemptMaterial = null;
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
      // 换号/重登时群状态必须归零：`_groupSynced` 残留会让新会话跳过
      // 「首次往回看一窗」，`_groupLastSeq` 残留则可能带着别的账号的 seq。
      _groupLastSeq.clear();
      _groupSynced.clear();
      _groupWindowIdle.clear();
      _primeFailed.clear();
      _groupDead.clear();
      _syncCookie = null;
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
    // 其他关键 TLV 一律打长度 + hex（超 64B 只打前 64B）。
    // 235（版本过低/可更换设备）专带 0x543，此前从未解过；0x546 是防刷题挑战；
    // 0x544/0x553 是我方客户端证明。被拒时这几格是唯一还没被读过的证据。
    for (final tag in const <int>[0x543, 0x544, 0x546, 0x553, 0x130]) {
      final b = r.tlvs[tag];
      if (b == null) continue;
      final hex =
          b.take(64).map((v) => v.toRadixString(16).padLeft(2, '0')).join();
      _log.i('TLV 0x${tag.toRadixString(16)} 长度=${b.length}'
          '${b.length > 64 ? '（只显示前 64B）' : ''} hex=$hex');
    }
    final text = msg == null
        ? '登录未通过（服务端返回 type=${r.type}）'
        : '${msg.$1}：${msg.$2}';
    // 45 / 235 / 243 是**服务端对这个账号的准入结论**，不是这次组包写错了；
    // 16 / 155 则是**凭证时效**——换一张票就能继续，跟账号风险无关。两者都
    // 不原地重试（failed 靠改参数可以重试），但对用户说的话完全不同，所以按
    // 阶段分开（唯一判据见 [qq8StageForResultType]）。
    final stage = qq8StageForResultType(r.type);
    // 走到这里说明这次是**发包**了（准入/凭证结论都来自服务端应答），
    // 续期标志用完即清，绝不能让下一次登录误用。
    _loginIsRenewal = false;
    if (stage == Qq8LoginStage.rejected) {
      final why = msg == null ? '无文案' : msg.$1;
      _log.w('服务端准入拒绝 type=${r.type}（$why）——不再自动重试；'
          '连续重试只会让账号风险更高，请等待一段时间后再试一次。'
          '注：2026-10-28 21:25 真机见到 235（验证通过后）与 45（提交包多带 '
          '0x544/0x553）两种情况，但两次档案不同，尚未做干净单变量 A/B。');
    } else if (stage == Qq8LoginStage.sessionExpired) {
      _log.w('凭证失效 type=${r.type} 停止重试，等待用户重新登录');
      // 服务端**已经判过**这张票失效：记下来，冷启动别白试一次。
      // 只标记，不删文件——留作诊断，重新登录成功会被新票覆盖。
      try {
        final old = await tokenStore.load(uin);
        if (old != null) {
          // 失效范围**只记到本次实际走的那条材料**（_attemptMaterial）。
          // 口令链为 null → legacy 整票语义（见 Qq8TokenData.materialKnownInvalid）。
          await tokenStore.save(old.markInvalidated(
            atMs: DateTime.now().millisecondsSinceEpoch,
            type: r.type,
            material: _attemptMaterial,
          ));
          _log.w('票据已标记失效（type=${r.type} 材料=${_attemptMaterial ?? '整票'}），'
              '冷启动将跳过该材料');
        }
      } catch (e) {
        _log.w('标记票据失效失败（不影响本次结论）', error: e);
      }
    }
    _emit(Qq8LoginSnapshot(
      stage: stage,
      uin: uin,
      error: text.trim(),
      resultType: r.type,
    ));
  }

  /// 注册上线 + 起心跳；成功则进入 [Qq8LoginStage.online]。
  Future<void> _goOnline(int uin, Qq8SigBundle bundle) async {
    // 新会话 = 新票据：上一次的「身份失效」结论作废。
    _authLost = false;
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
    // 掉线必须让上层看见。**唯一入口**：传输层读错误 / 对端关闭 / 写失败 /
    // 心跳连败，会话层都收敛成这一条回调，服务层只在这里决定恢复。
    // 曾在真机前漏掉这条线——服务一直是 online，用户却什么都收不到。
    _sessionEpoch++;
    final epoch = _sessionEpoch;
    session.onConnectionLost = (Object error) =>
        _handleConnectionLost(session, epoch, error);
    // 旧接口保留兼容：不要在这里重复触发恢复（单飞会挡，但语义要干净）。
    session.onOffline = () {};
    // 心跳里的注册续租收到 authDead：终态，走与上线注册同一条"身份失效"路径。
    session.onAuthDead = (e) => _markAuthLost(e, '心跳续租注册');
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
    //
    // **不等它**：真机 2026-10-25 10:59 / 11:47 两次实测，登录应答 0.35 s
    // 就回来了，但「已上线」要等 10.2 s——全耗在 register 的 10 s 超时上
    // （服务端从不回 ack）。而 register 之后的心跳、校时、拉好友/群列表
    // 都不读它的返回值，所以先放行上线，register 在后台跑完即可。
    // 只有「拿到应答且 cReplyCode 非 0」（明确被拒）才把状态改回 failed。
    // 判据出处：SvcRespRegister.java:63-85 的 tag2 = cReplyCode，官方
    // msf/core/push/e.java:196-235 判 `cReplyCode == 0`。
    unawaited(_registerInBackground(session, uin, epoch));
    // 官方登录后立刻发这两个 JCE 检查（见 [Qq8OnlineCheck] 的注释）。
    // 我们从不发它们时，服务端只推配置类推送——`OnlinePush.*` /
    // `MessageSvc.PushNotify` 一条都不来（真机全量日志 0 命中）。
    if (reportOnlineChecks) unawaited(_runOnlineChecks(session, uin, epoch));
    session.startHeartbeat(interval: heartbeatInterval);

    // 上线后立刻上报一次在线状态（`StatSvc.SetStatusFromClient`，0x0B 外壳）。
    // 与上面的 register 是两个独立请求：register 注册连接，这个声明"我在线"。
    // 官方 icqq 在登录成功回调里第一件事就是它（`internal/listeners.js:93`），
    // 之后每 11 次心跳补报一次（`client.js:225-229`）。
    // 失败不阻断上线：register 已过、心跳已起，状态上报是维护性请求。
    if (reportOnlineStatus) {
      try {
        final statusOk = await session.setOnlineStatus();
        _log.i('在线状态上报: ${statusOk ? '已确认' : '未确认（不影响上线）'}');
      } on Object catch (e) {
        _log.w('在线状态上报失败（不影响上线）', error: e);
      }
    }

    // 上面 await 过 setOnlineStatus：期间可能已经切号 / 关闭 / 断线重连。
    // 旧会话的流程跑完，不许把 online 写到新会话上（迟到结果）。
    if (!identical(_session, session) || epoch != _sessionEpoch) return;
    _emit(Qq8LoginSnapshot(stage: Qq8LoginStage.online, uin: uin));
    _log.i('已上线 uin=$uin');

    // 上线先拉一次漏掉的消息：PushNotify 推送在真机上并不可靠
    // （2026-10-24 11:41 真机：上线后服务端只推了 StatSvc.QueryHB，
    //  一条 MessageSvc.PushNotify 都没来），所以不能只等推送——
    // 主动 PbGetMsg 一把，把上线前攒的离线消息先收进来。
    // 延迟 2 秒再补拉：上线瞬间好友/群列表请求正在飞，
    // 立刻再打一个 PbGetMsg 会让「按序吃应答」的测试夹具错位。
    Future.delayed(startupPullDelay, () {
      // 2 秒里可能已经断线/重登——只在这个 session 还在线时拉
      if (_session == session &&
          epoch == _sessionEpoch &&
          _snapshot.stage == Qq8LoginStage.online) {
        unawaited(_pullNewMessages(reason: '上线补拉'));
      }
    });
    // 兜底轮询：推送不来时靠拉（真机 11:41 一条 PushNotify 都没收到）。
    // 间隔取心跳的 1/3，错开心跳的节奏。
    _restartPullTimer();
  }

  /// 连接非预期断开后的**统一恢复入口**（单飞）。
  ///
  /// 只认当前会话与当前代际；断开时立刻停轮询，避免断网期间继续空转
  /// 出一串「等待响应超时」。
  void _handleConnectionLost(Qq8Session session, int epoch, Object error) {
    if (!identical(_session, session) || epoch != _sessionEpoch) return;
    if (_authLost) return; // 凭证失效已走专门路径，别再重连
    final stage = _snapshot.stage;
    if (stage != Qq8LoginStage.online && stage != Qq8LoginStage.connecting) {
      return; // 已在恢复/失败态，不重复触发
    }
    _pullTimer?.cancel();
    _pullTimer = null;
    _log.w('连接已断开，进入统一恢复入口', error: error);
    _emit(Qq8LoginSnapshot(
      stage: Qq8LoginStage.disconnected,
      uin: session.uin,
      error: '连接已断开，正在尝试自动恢复',
    ));
    unawaited(reconnect(uin: session.uin));
  }

  /// 当前生效的轮询间隔（前台/后台不同）。
  Duration get _activePullInterval =>
      _foreground ? pullInterval : backgroundPullInterval;

  /// 应用是否在前台（决定轮询频率与是否立即补拉）。
  bool _foreground = true;

  /// 前台/后台切换。
  ///
  /// 从后台回到前台时**立刻拉一次**：这段时间的消息一条都没拿，等下一个
  /// 60 s 定时器太慢，而用户此刻正盯着界面。反向（进后台）只降频，不补拉。
  ///
  /// 由 L4 的 [以 `KeepAliveScope` 为准的] 生命周期观察者调用——本文件是纯
  /// Dart（L3），不能 import Flutter，所以这里只收一个 bool。
  void setAppForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (foreground) {
      if (_snapshot.stage == Qq8LoginStage.online) {
        unawaited(_pullNewMessages(reason: '前台恢复'));
      }
    }
    if (_pullTimer != null) _restartPullTimer();
  }

  /// 按当前前后台状态重设定时器。
  void _restartPullTimer() {
    _pullTimer?.cancel();
    _pullTimer = Timer.periodic(
      _activePullInterval,
      (_) => unawaited(_pullNewMessages(
            reason: _foreground ? '轮询' : '后台轮询',
          )),
    );
  }

  /// 轮询周期计数：每 [_groupResyncEvery] 次重新问一次 UnReadMsgSeq。
  int _pullCycles = 0;

  /// 隔几个轮询周期对齐一次群水位。
  ///
  /// 原先是 10。后台轮询 60s 一轮时，那就是**10 分钟才校准一次**——
  /// 期间游标只能靠"盲推进窗口"猜，服务端后来才放行的消息根本看不见
  /// （真机 2026-10-26 现场：水位停在 57662，窗口反复请求 57663-57682 全是 104）。
  /// 一个 `PbUnReadMsgSeq` 批量覆盖所有群，成本是一次往返，不值得省。
  static const int _groupResyncEvery = 2;

  /// 注册是否已确认（confirmed）。false 时在线检查降级为诊断。
  bool _pushChannelUnconfirmed = false;

  /// 最近一次注册分类（诊断用）。
  Qq8RegisterOutcome? _lastRegisterOutcome;

  /// 最近一次注册结果（只读，供测试与界面诊断）。
  Qq8RegisterOutcome? get lastRegisterOutcome => _lastRegisterOutcome;

  /// 推送通道是否已知不可用/未确认。
  bool get pushChannelUnconfirmed => _pushChannelUnconfirmed;

  /// 在途的注册请求（single-flight）。
  ///
  /// 存会话与代际：只复用**同一会话、同一代**的结果。否则断线重连后
  /// 新会话会误用旧会话那条永远回不来的 Future（表现：新会话上线 30 秒
  /// 内注册全部被「复用」成旧会话的 pending）。
  ({Qq8Session session, int epoch, Future<Qq8RegisterOutcome> future})?
      _registerInFlight;

  /// 注册 single-flight：同一时刻只允许一条 `StatSvc.register` 在途。
  ///
  /// 真机缺陷1：上线注册 30 秒超时的同时，`StatSvc.QueryHB` 每 3 分钟又
  /// 触发一次重注册，两条请求各自等 30 秒、日志里叠成一团。复用同一次
  /// 结果即可——重注册本来就是这个意思。
  Future<Qq8RegisterOutcome> _registerOnce(
    Qq8Session session, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final inFlight = _registerInFlight;
    if (inFlight != null &&
        identical(inFlight.session, session) &&
        inFlight.epoch == _sessionEpoch) {
      _log.d('注册已在途（同一会话），复用这次结果');
      return inFlight.future;
    }
    final f = session.registerWithOutcome(timeout: timeout);
    _registerInFlight = (session: session, epoch: _sessionEpoch, future: f);
    return f.whenComplete(() {
      final cur = _registerInFlight;
      if (cur != null && identical(cur.future, f)) _registerInFlight = null;
    });
  }

  /// 后台发 `StatSvc.register`，不挡上线。
  ///
  /// 三态判据：`true` = 收到且 `SvcRespRegister.cReplyCode == 0`（官方判据，
  /// `msf/core/push/e.java:196-235`）；`false` = 收到但 cReplyCode 非 0
  /// （明确被拒）；抛异常（超时）= 等价 icqq 的 `-2`，继续当成功。
  /// 只有明确被拒才回退状态——那时会话确实不可用，藏起来只会让用户
  /// 以为在线却什么都收不到。
  Future<void> _registerInBackground(
      Qq8Session session, int uin, int epoch) async {
    final Qq8RegisterOutcome outcome;
    try {
      outcome = await _registerOnce(session, timeout: registerTimeout);
    } on Object catch (e) {
      if (epoch != _sessionEpoch) return; // 旧会话的失败不算新会话的
      // 身份/票据失效是终态：不能再当「无回执」继续上线（会一直重注册）。
      if (_markAuthLost(e, '上线注册')) return;
      _log.w('上线注册无应答（等价 icqq -2），继续上线', error: e);
      return;
    }
    if (epoch != _sessionEpoch) return;
    _lastRegisterOutcome = outcome;
    switch (outcome) {
      case Qq8RegisterOutcome.confirmed:
        // 确认成功必须清掉「未确认」标记，否则一旦某次超时置过位，
        // 之后即使注册成功，在线检查也会一直被跳过（永久降级）。
        _pushChannelUnconfirmed = false;
        _log.i('上线注册已确认（cReplyCode=0）${session.lastRegisterDiagnostic ?? ''}');
        return;
      case Qq8RegisterOutcome.unconfirmed:
        // 真机现场：30 秒一个字都没回来。这时服务端到底有没有把推送通道
        // 挂上我们不知道——既不能当成功，也不该把 online 打回 failed（用户
        // 明明能收发消息，全是靠轮询）。标记成「推送未确认」，让后面的
        // 在线检查降级为诊断，省掉 2×8 秒的空等。
        _pushChannelUnconfirmed = true;
        _log.w('上线注册无回执（等价 icqq -2）：推送通道未确认，继续上线并保底轮询');
        return;
      case Qq8RegisterOutcome.rejected:
        break;
    }
    // 期间可能已经断线/重登，别把新会话的状态踩掉
    if (!identical(_session, session) || _snapshot.stage != Qq8LoginStage.online) {
      return;
    }
    _emit(Qq8LoginSnapshot(
      stage: Qq8LoginStage.failed,
      uin: uin,
      error: '登录已通过，但上线注册被拒（票据或设备信息不符）',
    ));
  }

  /// 发官方登录后那两个 JCE 检查：`PhSigLcId.Check` 与 `GrayUinPro.Check`。
  ///
  /// 请求体是抓包回放（见 [Qq8OnlineCheck]：那两条是官方登录后唯一以
  /// `flag=2`（全零密钥）发出的请求，所以抓包里能直接解出明文）。
  ///
  /// 为什么值得发：我们从不发它们时，真机全量日志里服务端只推
  /// `StatSvc.QueryHB` / `ConfigPushSvc.*`，`OnlinePush.PbPushGroupMsg` 与
  /// `MessageSvc.PushNotify` 一条都不来——但推送通道本身是通的（ConfigPush
  /// 收得到）。官方先过这两关才收消息推送，所以这是「主动拉」之外唯一的
  /// 可能让服务端开始推的入口。
  ///
  /// 用 [Qq8LoginType.login]（= 2）发：与官方包同形（全零密钥加密 SSO 层）。
  /// 任何一条失败都只记日志——它们不是上线的前置条件，不该拖垮登录。
  Future<void> _runOnlineChecks(Qq8Session session, int uin, int epoch) async {
    // 真机 2026-10-31：本方法在 [_registerInBackground] 之后**立刻**启动，那时
    // 注册还在途、`_pushChannelUnconfirmed` 仍是 false，于是两条回放检查照样
    // 发出去，各空等 7-8 秒（日志里落在「在线状态上报: 未确认」之后）。
    // 先等这次注册有结论（single-flight，最多一条在途），再决定发不发。
    final inFlight = _registerInFlight;
    if (inFlight != null) {
      try {
        await inFlight.future;
      } on Object catch (_) {
        // 超时/失败都算「没有确认结论」，下面统一按 outcome 判断。
      }
      if (!identical(_session, session) || epoch != _sessionEpoch) return;
    }
    // 注册没到 confirmed（无回执 / 被拒 / 从没跑过），说明推送通道压根没谈成；
    // 这两条只是"试探服务端会不会因为见过它们就开始推"，此刻发只会各空等
    // 8 秒。降级为诊断：跳过。
    if (_pushChannelUnconfirmed ||
        _lastRegisterOutcome != Qq8RegisterOutcome.confirmed) {
      _log.i('注册未确认：跳过两条在线检查（回放仅作诊断，省 16s 空等）');
      return;
    }
    const checks = <String>[
      Qq8OnlineCheck.cmdPhSigLcId,
      Qq8OnlineCheck.cmdGrayUinPro,
    ];
    for (final cmd in checks) {
      if (!identical(_session, session) || epoch != _sessionEpoch) {
        return; // 期间断线/重登，别再发
      }
      final body = cmd == Qq8OnlineCheck.cmdPhSigLcId
          ? Qq8OnlineCheck.phSigLcIdPayload(uin)
          : Qq8OnlineCheck.grayUinProPayload(uin);
      try {
        final r = await session.sendLoginLayer(
          cmd,
          body,
          type: Qq8LoginType.login,
          timeout: const Duration(seconds: 8),
        );
        final head = r.payload.length <= 24
            ? r.payload
            : Uint8List.sublistView(r.payload, 0, 24);
        _log.i(
          '在线检查 $cmd 应答 len=${r.payload.length} '
          'head=${head.map((e) => e.toRadixString(16).padLeft(2, '0')).join()}',
        );
      } on Object catch (e) {
        _log.w('在线检查 $cmd 失败（不影响上线）', error: e);
      }
    }
  }

  /// 服务端已判定「身份/票据失效」——停掉后台动作，只留一句给人看的话。
  ///
  /// 判据是 [qq8RetcodesAuthDead]（官方 `msf/core/ah.java:35-37` 那一组，
  /// 官方命中后做的是清账号登录态 + `CODE_NO_LOGIN`）。与普通失败的关键
  /// 区别：**重试没有意义**。真机 2026-10-26 21:46 起服务端连续回 -10003，
  /// 我们每 8 s 当普通失败重试一次，一路刷到 21:47:52 连接被 abort，
  /// 日志里只剩这一种噪音，真正的信息（服务端说"身份验证失败"）被淹掉。
  ///
  /// 返回 true 表示「这个错误是身份失效，已处理」，调用方直接返回即可。
  bool _markAuthLost(Object e, String where) {
    if (e is! Qq8ServerRetcodeException || !e.authDead) return false;
    if (_authLost) return true;
    _authLost = true;
    _log.w('$where：服务端判定身份已失效（retcode=${e.retcode}），'
        '停止后台轮询，等用户重新登录');
    _pullTimer?.cancel();
    _pullTimer = null;
    _session?.stopHeartbeat();
    _emit(Qq8LoginSnapshot(
      stage: Qq8LoginStage.sessionExpired,
      uin: _snapshot.uin,
      error: '登录凭证已失效，请重新登录',
    ));
    return true;
  }

  /// 本会话是否已经判定身份失效（见 [_markAuthLost]）。
  bool _authLost = false;

  /// 主动拉新消息并走推送同一条流水线（建会话/未读/去重全复用）。
  Future<void> _pullNewMessages({required String reason}) async {
    // 身份失效后定时器已被取消，但可能在取消前又入队了一次。
    if (_authLost) return;
    if (_session == null || _snapshot.stage != Qq8LoginStage.online) return;
    // 断网期重发风暴：暂停**非必要**的轮询，让统一恢复入口去处理。
    // 用户触发的补拉（上线补拉/前台恢复/ReqPush）不受此限。
    final voluntary = reason != '轮询' && reason != '后台轮询';
    if (!voluntary && _session!.resendStormSuspected) {
      _log.d('重发风暴中，暂停本轮轮询（reason=$reason）');
      return;
    }
    // 防重入：定时器、上线补拉、QueryHB 触发的补拉可能撞在一起。
    // 真机 2026-10-25 11:52:29 日志里同一秒出现两组完全相同的群历史请求
    // （`拉新消息` 与 7 个 `群历史` 各打了两遍），就是并发进来的——
    // 除了浪费包，两组 `_pollGroups` 还会互相推进/回退群游标。
    if (_pulling) return;
    _pulling = true;
    try {
      // **必须有超时兜底**：`_pullNewMessagesInner` 里会 await 多次网络往返，
      // 而 `_pulling` 是「在跑」的闩。真机 2026-10-25 14:59:56 复现过：重新
      // 登录后那次上线补拉卡在传输层（同一时段 register/在线检查也都在超时），
      // 之后每 8 秒的轮询全被这个闩静默挡掉——日志里连一行都没有，看起来像
      // 「轮询定时器死了」。加超时保证闩一定会被 `finally` 放开。
      await _pullNewMessagesInner(reason: reason)
          .timeout(const Duration(seconds: 30));
    } on Object catch (e) {
      if (_markAuthLost(e, '拉新消息')) return;
      _log.w('拉新消息失败（reason=$reason）', error: e);
    } finally {
      _pulling = false;
    }
  }

  bool _pulling = false;

  Future<void> _pullNewMessagesInner({required String reason}) async {
    if (_session == null || _snapshot.stage != Qq8LoginStage.online) return;
    // 每 10 个周期重新问一次真实群 seq：盲推进的光标会跳过"后来才放行"的
    // 消息（服务端先扣后放，或窗口恰好错过），这里用 1 个请求把游标拉回真值。
    // 仅在有群且上次引导拿到了结果时做（_primeFailed 的群不重复问）。
    if ((++_pullCycles % _groupResyncEvery) == 0 &&
        _groupLastSeq.isNotEmpty &&
        _primeFailed.length < _groupLastSeq.length) {
      await _resyncGroupSeqs();
    }
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
    } finally {
      // 群消息走独立通道（见 _pollGroups 注释）
      unawaited(_pollGroups(reason));
    }
  }

  /// 这段文本看起来是「网络根本连不上」而不是「服务端给了结论」吗？
  ///
  /// 判据用错误文本而不是异常类型：连接失败一路被包了好几层
  /// （Qq8TransportException 里套 SocketException / DNS 失败），拿到的始终是文本。
  /// 注意**不收**「等待响应超时」——那说明网络通、服务端不回，按正常失败计数。
  static bool _networkUnavailable(String text) =>
      text.contains('连接失败') ||
      text.contains('SocketException') ||
      text.contains('Failed host lookup') ||
      text.contains('Network is unreachable') ||
      text.contains('连接已断开') ||
      text.contains('No route to host');

  /// 断线自动恢复：重连 + 用已存票据续期重上线（不用密码）。
  ///
  /// 官方对照（wtlogin 日志）：连接断了会自动重建并用已有票据续登，
  /// 全程不惊动用户。这里同样只用票据；没有可用票据就停在 disconnected
  /// 等用户手动重登——**不要**在自动路径里退化成密码登录。
  ///
  /// 也公开给 UI 的「重连」按钮用（断线提示里写的就是"可重新登录或重连"）。
  /// [reconnectAttempts] 次退避重试全失败后停在 disconnected；纯「连不上网络」
  /// 不计入这个次数，按 [reconnectOfflineDelay] 继续等（见 [reconnectOfflineGiveUpAfter]）。
  Future<void> reconnect({required int uin}) async {
    if (_reconnecting) return;
    _reconnecting = true;
    try {
      // **每轮都换一条新连接**。
      // 真机 2026-10-26 21:47:57 现场：服务端 abort 后我们复用旧 transport，
      // 那句「[连接] 已建立 msfwifi.3g.qq.com:8080」其实是旧 socket 的地址被重印，
      // 紧接着 loginWithToken 就 `SocketException: Software caused connection abort`。
      // 旧的 Qq8Session 也要一起扔掉——它的 _pending / 心跳定时器不该带进新一轮。
      await _teardownConnection();
      // attempt 只数「服务端给了结论 / 连上但没上线」的失败；
      // 纯粹连不上网络时 offline=true，按固定间隔继续等，不消耗有界次数。
      var attempt = 0;
      var offline = false;
      final offlineDeadline = DateTime.now().add(reconnectOfflineGiveUpAfter);
      while (!_states.isClosed && attempt < reconnectAttempts) {
        if (offline) {
          if (!DateTime.now().isBefore(offlineDeadline)) {
            _log.w('断线恢复：网络已中断超过 '
                '${reconnectOfflineGiveUpAfter.inMinutes} 分钟，停在断线状态等手动重登');
            break;
          }
          await Future<void>.delayed(reconnectOfflineDelay);
        } else {
          await Future<void>.delayed(reconnectBaseDelay * (attempt + 1));
        }
        if (_states.isClosed) return;
        // 上一轮 loginWithToken 可能已经把 transport 弄坏（连上又断、或写失败），
        // 所以每次都重建，而不是只在循环开始时重建一次。
        if (attempt > 0 || offline) await _teardownConnection();
        final token = await tokenStore.load(uin);
        // 判据与 loginWithToken 的闸门一致：D2 链或 A1 对任一条在就不算"没料"。
        if (token == null || !token.recoveryUsable) {
          _log.w('断线恢复：没有可用的免密材料（D2/A1 都缺），停在断线状态等手动重登');
          return;
        }
        _log.i(offline
            ? '断线恢复：等网络恢复后再试（票据续期，已尝试 $attempt/$reconnectAttempts 次）'
            : '断线恢复：第 ${attempt + 1}/$reconnectAttempts 次（票据续期）');
        try {
          await loginWithToken(uin: uin);
        } on Object catch (e) {
          offline = _networkUnavailable(e.toString());
          if (!offline) attempt++;
          if (offline) {
            _log.w('断线恢复：网络不可用，'
                '${reconnectOfflineDelay.inSeconds}s 后再试（不计入 $reconnectAttempts 次上限）');
            // 断网不是「登录失败」：让界面显示断线（可手动重连），别报成登录错误。
            _emit(Qq8LoginSnapshot(
              stage: Qq8LoginStage.disconnected,
              uin: uin,
              networkIssue: true,
              error: '网络不可用，正在等待网络恢复后自动续连',
            ));
          } else {
            _log.w('断线恢复第 $attempt 次抛异常', error: e);
          }
          continue;
        }
        if (_snapshot.stage == Qq8LoginStage.online) {
          _log.i('断线恢复成功（第 ${attempt + 1} 次尝试）');
          return;
        }
        // **准入拒绝不重试**。
        // 真机 2026-10-27 现场：票据续期连吃三记 type=16，三轮退避（2s/4s/6s）
        // 每轮都把同一句「服务端拒绝」再问一遍——既救不回来，又白耗尝试次数、
        // 给账号再添三条可疑记录。这种拒绝是服务端对「这个账号 + 这一代客户端」
        // 的结论。而且连打会让账号风险升级（真机 2026-10-28：静默 40 分钟后
        // type=2，被连续尝试 5 次后同一参数立刻变 type=45），所以要停手。
        // 所以直接退出，把 _snapshot 停在 rejected / sessionExpired 让 UI 说清楚。
        if (_snapshot.stage == Qq8LoginStage.rejected ||
            _snapshot.stage == Qq8LoginStage.sessionExpired) {
          if (_snapshot.stage == Qq8LoginStage.sessionExpired) {
            _log.w('断线恢复遇到凭证失效（type=${_snapshot.resultType}），'
                '凭证失效，停止重试，等用户重登');
          } else {
            _log.w('断线恢复遇到服务端准入拒绝（type=${_snapshot.resultType}），停止重试');
          }
          return;
        }
        // _fail 已把网络类失败归一成「网络不可用，请检查网络后重试」并打了
        // networkIssue 标；这里必须认那个标——只看错误文本会漏判（S3 回归：
        // 断网 5 轮被当成 3 次服务端失败直接停住）。
        offline = _snapshot.networkIssue ||
            _networkUnavailable(_snapshot.error ?? '');
        if (!offline) attempt++;
        if (offline) {
          _emit(Qq8LoginSnapshot(
            stage: Qq8LoginStage.disconnected,
            uin: uin,
            networkIssue: true,
            error: '网络不可用，正在等待网络恢复后自动续连',
          ));
        }
        _log.w(offline
            ? '断线恢复：网络不可用（stage=${_snapshot.stage.name}），'
                '${reconnectOfflineDelay.inSeconds}s 后再试'
            : '断线恢复第 $attempt 次未上线（stage=${_snapshot.stage.name}），退避后重试');
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
    // 网络不可用不是"登录失败"：报 disconnected（可静默等网络），并在快照上
    // 打 networkIssue，让适配层不要往事件流里发 SessionFailure（缺陷②）。
    final network = _networkUnavailable(e.toString());
    _emit(Qq8LoginSnapshot(
      stage: network ? Qq8LoginStage.disconnected : Qq8LoginStage.failed,
      uin: _snapshot.uin,
      networkIssue: network,
      error: network ? '网络不可用，请检查网络后重试' : '$what：$e',
      // 只有真正的登录失败才带栈；断网那支不值得污染事件流。
      stackTrace: network ? null : st,
    ));
  }

  void _emit(Qq8LoginSnapshot s) {
    // 打戳：这份状态是「第几次用户动作」产生的。异步投递时序号可能已经
    // 推进，所以必须在**产出这一刻**记住，不能让上层自己去问。
    final stamped = s.actionSeq == _actionSerial ? s : s.stamped(_actionSerial);
    _snapshot = stamped;
    if (!_states.isClosed) _states.add(stamped);
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

