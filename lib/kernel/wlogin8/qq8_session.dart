/// L2 协议内核：会话层（登录之后的请求路由、注册与心跳）
///
/// ## 职责
///
/// * **seq 分配与配对**：每个请求一个 seq（[Qq8Uni.nextSeq]，1..0x7FFF 回绕），
///   响应按 SSO 头里的 seq 找回等待者；
/// * **推送**：没有匹配请求的帧进 [pushes] 流（服务端主动下发）；
/// * **两种发送形态**：登录层（[Qq8Sso.buildLoginPacket]，type 0/1）与
///   UNI 包（[Qq8Uni.build]，业务请求）；
/// * **注册与心跳三件套**：[register] / [heartbeatAlive] / [correctTime] /
///   [uniHeartbeat]，以及周期循环 [startHeartbeat]。
///
/// 收包路径：传输层每帧 → [qq8UnwrapRecv]（外壳 + SSO 头）→ 按 seq 配对，
/// 否则进推送流。对应参考实现 oicq 的 `packetListener`（挂在每个收到的包上）
/// + `HANDLERS`（按 seq 派发；未匹配的走 listeners）。
///
/// ## 为什么要这一层
///
/// 直连模式下没有 OneBot 后端替你维持连接：登录只解决"拿到票据"，
/// 之后要自己注册上线、按周期心跳、处理主动推送——这一层就是那些事的家。
///
/// 本文件是纯 Dart。
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'qq8_device.dart';
import 'qq8_login.dart';
import 'qq8_pb.dart';
import 'qq8_profiles.dart';
import 'qq8_recv.dart';
import 'qq8_register.dart';
import 'qq8_sso.dart';
import 'qq8_tran.dart';

/// 服务端要求重发该请求（官方 `msf/core/ag.java:1782-1793`：
/// `if (businessFailCode == -10008) { D.reSendMsg(toServiceMsgC); return; }`）。
///
/// 出处是反编译官方 9.3.60 的 MSF 层，不是猜的：真机 2026-10-26 21:46
/// 服务端连着回这个码，官方客户端会自动重发一次，我们之前是直接丢帧。
const int qq8RetcodeResend = -10008;

/// 官方认定为「票据/身份已失效」的 SSO 返回码。
///
/// 出处：反编译官方 9.3.60 的 MSF 失败码处理
/// `com/tencent/mobileqq/msf/core/ah.java:35-37`：
/// `return i2 == -12003 || i2 == 210 || i2 == -10001 || i2 == -10003
///         || i2 == -10004 || i2 == -10006 || i2 == -10106;`
/// 命中后官方做的是 `getAccountCenter().k(uin)`（清账号登录态）+
/// `setBusinessFail(CODE_NO_LOGIN)`，即**认定这条路已经没用，要重新登录**。
///
/// 为什么要单独拎出来：这类码跟 -10008（要求重发）、跟超时/网络错误完全不同——
/// 前者重试一万次也是同一句「身份验证失败」，继续轮询只是刷日志；
/// 后者才值得重连。真机 2026-10-26 21:46 起服务端连续回 -10003，
/// 我们当成普通失败每 8 秒重试，直到连接被 abort（C40/C42）。
///
/// 另外三个「连接层面已死」的码也归进来，理由同官方 `ah.java`：
/// -10009（cookie 失效，官方 `sender.a(ssoInvalidCookie)` 关连接）、
/// -10102（官方 `s.suspend()` 挂起 SDK）、
/// -10103（被踢且清票据，官方 `CODE_SSO_KICKEDANDCLEARTOKEN`）。
const Set<int> qq8RetcodesAuthDead = <int>{
  -12003,
  210,
  -10001,
  -10003,
  -10004,
  -10006,
  -10106,
  -10009,
  -10102,
  -10103,
};

/// 服务端用 SSO 返回码拒绝了一个请求（不是网络故障）。
///
/// 与 [Qq8TransportException] 分开是必须的：传输异常意味着"这条连接可能坏了"，
/// 而这个异常意味着"连接好着，服务端说这条请求不行"——上层的处理完全不同
/// （前者要重连，后者要么重试要么跳过）。
class Qq8ServerRetcodeException implements Exception {
  /// SSO 头里的 retcode（负数，如 -10003 / -10008）。
  final int retcode;

  /// 被拒的请求 seq。
  final int seq;

  /// 被拒的命令字（retcode != 0 时服务端不回 cmd，通常为空串）。
  final String cmd;

  /// 是否已经自动重发过一次（诊断用）。
  final bool resent;

  /// 这个返回码是否意味着「身份/票据已失效，只能重新登录」。
  ///
  /// 判据见 [qq8RetcodesAuthDead]。上层据此停止轮询并提示重登，
  /// 而不是把 -10003 当普通失败一直重试。
  bool get authDead => qq8RetcodesAuthDead.contains(retcode);

  const Qq8ServerRetcodeException({
    required this.retcode,
    required this.seq,
    this.cmd = '',
    this.resent = false,
  });

  @override
  String toString() =>
      'Qq8ServerRetcodeException: 服务端返回 retcode=$retcode'
      '（seq=$seq${cmd.isEmpty ? '' : '，cmd=$cmd'}'
      '${resent ? '，已自动重发一次' : ''}）';
}

/// 上线注册的三种结果（见 Qq8Session.registerWithOutcome）。
enum Qq8RegisterOutcome {
  /// 服务端回执 cReplyCode == 0（官方判据 msf/core/push/e.java:196-235）。
  confirmed,
  /// 收到回执但被明确拒绝（票据/设备信息不符）。
  rejected,
  /// 没有任何回执（超时或等回应时断线）：推送通道是否已建立未知。
  unconfirmed,
}

/// 长连接会话：路由（seq 配对/推送）、注册与心跳。
class Qq8Session {
  final Qq8Transport transport;
  final Qq8ClientProfile profile;
  final int uin;
  final Qq8Device device;

  /// 4 字节会话标识（UNI 包用；登录时生成，之后固定）。
  final Uint8List sessionId;

  /// 本次登录的 ECDH 公钥与共享密钥（登录层信封）。
  final Uint8List ecdhPublicKey;
  final Uint8List ecdhShareKey;

  /// 登录层信封里的随机密钥（oicq 的 `random_key`：登录时生成一次、之后复用）。
  final Uint8List randomKey;

  /// 票据集合；登录成功后用 [updateSig] 填。
  Qq8SigInfo sig;

  /// 与服务端的时间差（秒），[correctTime] 之后有值。
  int timeDiffSeconds = 0;

  /// QIMEI36（36 字符），写进 SSO 头的 reserve fields（tag 12）。
  ///
  /// 官方客户端总有值；为空时该 tag 不写，服务端多数命令仍接受，但
  /// `StatSvc.register` 这类业务包建议带上（2026-10-22 真机实证）。
  final String? qimei36;

  /// 收包解析失败的回调（不中断会话）。
  void Function(Object error)? onError;

  /// 原始帧旁路（诊断用）：每个解出的帧在解析**之前**回调一次。
  ///
  /// 与 [pushes] 的区别：这里给的是没被任何一层解析过的原始字节，用于
  /// 排查「解析丢帧 / seq 对不上」这类问题。
  void Function(Uint8List frame)? onRawFrame;

  /// 心跳连失败两次（视为掉线）时的回调（旧接口，保留给工具与自测）。
  void Function()? onOffline;

  /// 连接**非预期断开**时统一回调一次（传输层断开 / 心跳判坏）。
  ///
  /// 与 [onOffline] 的区别：这里带原因，且由会话层保证「一条连接只报一次」。
  /// 产品层（L3）只接这一条，别再各写一套。
  void Function(Object error)? onConnectionLost;

  /// 本条连接是否已判定断开：保证 [onOffline]/[onConnectionLost] 只报一次。
  bool _down = false;

  /// [close] 是否已执行过（重复关闭要安全）。
  bool _closed = false;

  final Map<int, Completer<Qq8SsoResponse>> _pending =
      <int, Completer<Qq8SsoResponse>>{};
  final StreamController<Qq8SsoResponse> _pushes =
      StreamController<Qq8SsoResponse>.broadcast();

  Timer? _timer;
  bool _online = false;
  bool _started = false;
  int _seq;

  Qq8Session({
    required this.transport,
    required this.profile,
    required this.uin,
    required this.device,
    required this.sessionId,
    required this.ecdhPublicKey,
    required this.ecdhShareKey,
    Qq8SigInfo? sig,
    Uint8List? randomKey,
    int seqStart = 0,
    this.qimei36,
  })  : sig = sig ?? Qq8SigInfo(),
        randomKey = randomKey ?? _secureBytes(16),
        _seq = seqStart;

  /// 服务端主动下发的帧（没有匹配请求的那些）。
  Stream<Qq8SsoResponse> get pushes => _pushes.stream;

  /// 是否已注册上线（[register] 成功后由 [startHeartbeat] 置位）。
  bool get isOnline => _online;

  /// 已连接并开始接收帧。
  Future<void> start() async {
    if (_started) return;
    await transport.connect();
    transport.onFrame = _onFrame;
    transport.onDisconnected = _handleTransportDown;
    _started = true;
  }

  /// 传输层报「非预期断开」：立即终结所有挂起请求、停心跳、上报一次。
  void _handleTransportDown(Object error) {
    if (_closed || _down) return;
    _down = true;
    _online = false;
    stopHeartbeat();
    // 统一成一句话再往上传：上层日志不该出现 "Bad state: ..." 这种泄漏。
    final wrapped = error is Qq8TransportException
        ? error
        : Qq8TransportException('连接已断开', error);
    _failAllPending(wrapped);
    onConnectionLost?.call(wrapped);
    onOffline?.call();
  }

  /// 把挂起请求全部以同一原因失败——不要留它们等到各自超时。
  void _failAllPending(Object error) {
    if (_pending.isEmpty) return;
    final waiting = List<Completer<Qq8SsoResponse>>.of(_pending.values);
    _pending.clear();
    for (final c in waiting) {
      if (!c.isCompleted) c.completeError(error);
    }
  }

  /// 登录成功后的票据映射（[Qq8SigBundle] → 会话内 [Qq8SigInfo]）。
  void updateSig(Qq8SigBundle bundle) {
    sig = Qq8SigInfo(
      tgt: bundle.tgt,
      d2: bundle.d2,
      d2key: bundle.d2key,
      sigKey: bundle.sigKey,
      ticketKey: bundle.ticketKey,
      srmToken: bundle.srmToken,
    );
  }

  // ------------------------------------------------------------------
  // 收包路由
  // ------------------------------------------------------------------

  void _onFrame(Uint8List frame) {
    onRawFrame?.call(frame);
    final Qq8SsoResponse r;
    try {
      r = qq8UnwrapRecv(frame, d2key: sig.d2key);
    } on Object catch (e) {
      onError?.call(e);
      return;
    }
    final p = _pending.remove(r.seq);
    if (p != null && !p.isCompleted) {
      p.complete(r);
    } else {
      _pushes.add(r); // 没人在等 → 推送
    }
  }

  int _nextSeq() {
    _seq = Qq8Uni.nextSeq(_seq);
    return _seq;
  }

  Qq8SsoContext _ctx(int seq) => Qq8SsoContext(
        uin: uin,
        apk: profile.apk,
        device: device,
        sessionId: sessionId,
        randomKey: randomKey,
        ecdhPublicKey: ecdhPublicKey,
        ecdhShareKey: ecdhShareKey,
        sig: sig,
        seqId: seq,
        qimei36: qimei36,
      );

  Future<Qq8SsoResponse> _send(
    int seq,
    Uint8List packet,
    Duration timeout,
  ) async {
    var resends = 0;
    // 总时限跨「首发 + 重发」只算一次：重发不能把超时预算翻倍。
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (_down) {
        throw Qq8TransportException('连接已断开（seq=$seq）');
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        throw Qq8TransportException(
            '等待响应超时（seq=$seq，${timeout.inSeconds}s）');
      }
      final r = await _awaitResponse(seq, packet, left);
      if (r.retcode == 0) {
        _resendStreak = 0;
        return r;
      }
      // -10008 = 服务端要求重发（官方 `msf/core/ag.java:1782-1793` 的
      // `D.reSendMsg(toServiceMsgC)` 会自动重发一次）。真机 2026-10-26 21:46
      // 连着回了 -10008，我们每条都当超时丢掉，请求全部石沉大海。
      if (r.retcode == qq8RetcodeResend && resends < 1) {
        resends++;
        onError?.call(Qq8ServerRetcodeException(
          retcode: r.retcode,
          seq: seq,
          cmd: r.cmd,
          resent: true,
        ));
        continue;
      }
      if (r.retcode == qq8RetcodeResend) _noteResendExhausted();
      throw Qq8ServerRetcodeException(
        retcode: r.retcode,
        seq: seq,
        cmd: r.cmd,
      );
    }
  }

  /// 记一次「重发预算耗尽」，用于识别断网期的重发风暴（见 [resendStormSuspected]）。
  void _noteResendExhausted() {
    final now = DateTime.now();
    final at = _resendAt;
    if (at == null || now.difference(at) > qq8ResendStormWindow) {
      _resendStreak = 1;
    } else {
      _resendStreak++;
    }
    _resendAt = now;
  }

  DateTime? _resendAt;
  int _resendStreak = 0;

  /// 最近一次 `StatSvc.register` 应答里服务端给的推送相关字段（诊断用，
  /// 见 [Qq8Register.describeResponse]）。仅用于日志，不参与任何判读。
  String? lastRegisterDiagnostic;

  /// 推送会话状态：服务端在 `SvcRespRegister` 里下发，下次注册必须回送
  /// （官方 `msf/core/push/e.java:104-105` 用 PushInfo.timeStamp / iLargeSeq）。
  int _pushTimeStamp = 0;
  int _pushLargeSeq = 0;
  int _pushHelloInterval = 0;

  /// 服务端要求的注册/推送续租间隔（`SvcRespRegister.iHelloInterval`，秒）。
  int get pushHelloInterval => _pushHelloInterval;

  /// 短窗口内多个请求都耗尽重发预算 ⇒ 连接大概率已经不可用。
  ///
  /// 仅用于让上层**暂停非必要的轮询**，绝不据此判定凭证失效
  /// （凭证失效有专门的 retcode 集合）。阈值与窗口是本地策略，不是协议常量。
  static const int qq8ResendStormThreshold = 3;
  static const Duration qq8ResendStormWindow = Duration(seconds: 30);

  bool get resendStormSuspected {
    final at = _resendAt;
    if (at == null) return false;
    return _resendStreak >= qq8ResendStormThreshold &&
        DateTime.now().difference(at) <= qq8ResendStormWindow;
  }

  /// 发一次包、等一次应答（[retcode] 非 0 也照常返回，由 [_send] 判读）。
  Future<Qq8SsoResponse> _awaitResponse(
    int seq,
    Uint8List packet,
    Duration timeout,
  ) async {
    final c = Completer<Qq8SsoResponse>();
    _pending[seq] = c;
    // 超时必须覆盖「写出去 + 等回来」整段：只罩 c.future 的话，写本身
    // 卡住（断网时 socket 不退不报）就永远等不到超时。
    // 立即开始写（async 闭包在第一个 await 前是同步执行的，与旧行为一致：
    // 调用方 await 之前包就已经进了 socket，测试能同步断言"发了几个包"）。
    final work = () async {
      await transport.write(packet);
      return c.future;
    }();
    try {
      return await work.timeout(timeout, onTimeout: () {
        throw Qq8TransportException(
            '等待响应超时（seq=$seq，${timeout.inSeconds}s）');
      });
    } on Object {
      _pending.remove(seq);
      rethrow;
    } finally {
      // 超时/关闭后底层 work 才失败时，不要再冒成"未捕获异常"。
      work.ignore();
    }
  }

  /// 登录层请求（命令字 + 信封 type=0/1/2）。
  ///
  /// type 见 [Qq8LoginType]：心跳类用 0（SSO 层不加密）、上线后用 1
  /// （SSO 层用 d2key 加密）、登录/取票用 2（SSO 层用全零密钥）。
  ///
  /// ## OICQ 信封只属于 type=2（2026-10-31 修正，缺陷1 根因候选）
  ///
  /// 以前这里无条件给 body 套一层 `buildOicqPacket`——那本是 `wtlogin.*`
  /// 登录/取票命令的格式。但注册（`StatSvc.register`）、校时
  /// （`Client.CorrectTime`）、心跳（`Heartbeat.Alive`）的 body 本身就是
  /// WUP 原始字节，**不该再套一层**：
  ///
  /// * oicq 参考 `lib/core/base-client.ts:829-864` 的 `buildLoginPacket`
  ///   只在 `type === 2` 时把 body 包成 OICQ（`writeU8(0x02)...`）；
  ///   `register()`（:728-729）用 type 1 传原始 WUP，`syncTimeDiff()`
  ///   （:759）用 type 0 传 4 字节，`exchange_emp` 默认 type 2。
  /// * 官方注册 `msf/core/push/e.java:94-164` 是把 `SvcReqRegister` 的 WUP
  ///   直接 `putWupBuffer` → `sendSsoMsg`，body 就是 WUP 原始字节，没有
  ///   第二层 OICQ。
  ///
  /// 所以只有 type==login(=2) 才套 OICQ；type 0/1 直接进 SSO。
  Future<Qq8SsoResponse> sendLoginLayer(
    String cmd,
    Uint8List body, {
    int type = Qq8LoginType.online,
    Duration timeout = const Duration(seconds: 10),
  }) {
    final seq = _nextSeq();
    final ctx = _ctx(seq);
    final carry = type == Qq8LoginType.login
        ? Qq8Sso.buildOicqPacket(ctx, body)
        : body;
    final pkt = Qq8Sso.buildLoginPacket(ctx, cmd, carry, type);
    return _send(seq, pkt, timeout);
  }

  /// UNI 包请求（业务命令字）。响应按 SSO 头里的 seq 配对。
  ///
  /// [seq] 指定包序号（不给就自动分配）——业务包里带"消息 seq"的场合
  /// （如 `MessageSvc.PbSendMsg` 的 tag4）要求**包序号 == 消息序号**
  /// （参考实现同款），调用方先 [nextSeq] 取号、再组装 body、再带上它发送。
  Future<Qq8SsoResponse> sendUni(
    String cmd,
    Uint8List body, {
    Duration timeout = const Duration(seconds: 10),
    int? seq,
  }) {
    final s = seq ?? _nextSeq();
    final pkt = Qq8Uni.build(
      uin: uin,
      cmd: cmd,
      body: body,
      seq: s,
      session: sessionId,
      d2key: sig.d2key,
    );
    return _send(s, pkt, timeout);
  }

  /// **只发不等**的 UNI 包（回执类请求专用）。
  ///
  /// 服务端对回执（[Qq8PushCmd.respPush] / `SSO.HelloPush` /
  /// `ConfigPushSvc.PushResp`）**不会回包**——用 [sendUni] 就必然等到超时。
  /// 真机实证：`ConfigPushSvc.PushResp 失败 | Qq8TransportException: 等待响应
  /// 超时（seq=-1807239620，10s）`——推送的 seq 是服务端给的负数，
  /// 我们却拿它当请求号去等一个永远不来的响应。
  ///
  /// 官方这三处全是 `setNeedCallback(false)` 发完就忘
  /// （`MessageHandler.java:1043/1078` 等）；参考实现 `writeUni` 同义。
  /// 因此这里**不登记 _pending**，直接写出去。
  Future<void> sendUniNoReply(String cmd, Uint8List body, {int? seq}) {
    final s = seq ?? _nextSeq();
    final pkt = Qq8Uni.build(
      uin: uin,
      cmd: cmd,
      body: body,
      seq: s,
      session: sessionId,
      d2key: sig.d2key,
    );
    return transport.write(pkt);
  }

  /// 预取一个包序号（配合 [sendUni] 的 `seq` 参数）。
  int nextSeq() => _nextSeq();

  // ------------------------------------------------------------------
  // 注册与心跳
  // ------------------------------------------------------------------

  /// 上线注册（`StatSvc.register`）：登录成功后必须发的第一个业务请求。
  ///
  /// 出处：oicq `lib/core/base-client.ts` 的 `register()`；结构见 [Qq8Register]。
  ///
  /// 超时 **30 秒**：官方 `msf/core/push/e.java` 对这条请求
  /// `setTimeout(30000L)`，比业务请求（10 秒）宽——注册要等服务端在
  /// push 通道上落一次记录，10 秒偏紧（真机多份日志都是 10s 超时）。
  /// 上线注册的结果分类（真机缺陷1）。
  ///
  /// 以前 register() 只有 bool：false = 被拒、抛异常 = 「无应答」。
  /// 但真机 2026-10-31 装的是「发出去 30 秒没有任何回执」——那既不能当成功
  /// （推送通道没落记录），也不该当被拒（会把上线状态打回 failed）。
  Future<Qq8RegisterOutcome> registerWithOutcome({
    bool logout = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    try {
      final parse = await registerParsed(logout: logout, timeout: timeout);
      return switch (parse) {
        Qq8RegisterParse.ok => Qq8RegisterOutcome.confirmed,
        Qq8RegisterParse.rejected => Qq8RegisterOutcome.rejected,
        // 畸形包不等于被拒：可能只是坏包，按「未确认」处理，别把上线打回 failed。
        Qq8RegisterParse.malformed => Qq8RegisterOutcome.unconfirmed,
      };
    } on Qq8ServerRetcodeException catch (e) {
      // 服务端明确回了「身份/票据失效」：这是终态，不是「没收到回执」。
      // 若在这里一并吞成 unconfirmed，上层会一直重注册（真机 -10003 风暴）。
      if (e.authDead) rethrow;
      return Qq8RegisterOutcome.unconfirmed;
    } on Object {
      // 超时 / 等回应期间连接断开：请求可能到了、也可能没到，无法判断。
      return Qq8RegisterOutcome.unconfirmed;
    }
  }

  Future<bool> register({
    bool logout = false,
    Duration timeout = const Duration(seconds: 30),
  }) async =>
      (await registerParsed(logout: logout, timeout: timeout)) ==
      Qq8RegisterParse.ok;

  /// 发一次 `StatSvc.register`，返回三态解析（供 [registerWithOutcome] 区分
  /// 明确被拒 / 坏包）。
  Future<Qq8RegisterParse> registerParsed({
    bool logout = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final body = Qq8Register.buildBody(
      uin: uin,
      device: device,
      logout: logout,
      pushTimeStamp: _pushTimeStamp,
      pushLargeSeq: _pushLargeSeq,
    );
    final r = await sendLoginLayer(
      Qq8Register.cmd,
      body,
      type: Qq8LoginType.online,
      timeout: timeout,
    );
    lastRegisterDiagnostic = Qq8Register.describeResponse(r.payload);
    final state = Qq8Register.parsePushState(r.payload);
    if (state != null) {
      _pushTimeStamp = state.timeStamp;
      _pushLargeSeq = state.largeSeq;
      _pushHelloInterval = state.helloInterval;
    }
    return Qq8Register.parseResponseDetailed(r.payload);
  }

  /// 在线状态上报（`StatSvc.SetStatusFromClient`，**UNI 外壳 0x0B**）。
  ///
  /// 与 [register] 是两个独立请求：register 用登录外壳（0x0A）注册连接，
  /// 这个用 UNI 外壳（0x0B）告诉服务端"我现在是在线状态"。
  ///
  /// 官方（[icqq] `lib/internal/listeners.js:93`）在登录成功回调里**立刻**发一次，
  /// 之后 `lib/client.js:225-229` 每 11 次心跳再发一次。
  ///
  /// 失败不抛：状态上报失败不该把在线状态打掉（register 已成功、心跳仍在），
  /// 只记 [onError] 让调用方知道。
  Future<bool> setOnlineStatus({
    int status = Qq8OnlineStatus.online,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final body = Qq8Register.buildSetStatusBody(
      uin: uin,
      device: device,
      status: status,
    );
    try {
      final r = await sendUni(Qq8Register.cmdSetStatus, body, timeout: timeout);
      return Qq8Register.parseResponse(r.payload);
    } on Object catch (e) {
      onError?.call(e);
      return false;
    }
  }

  /// `Heartbeat.Alive`：登录层 type=0、空 body。
  ///
  /// 出处：oicq js `lib/wtlogin/wt.js` 的 `heartbeat()`。
  Future<Qq8SsoResponse> heartbeatAlive() =>
      sendLoginLayer('Heartbeat.Alive', Uint8List(0), type: Qq8LoginType.heartbeat);
  /// `Client.CorrectTime`：登录层 type=0、body = 4 个零字节；
  /// 响应的前 4 字节是服务端时间（i32），据此更新 [timeDiffSeconds]。
  ///
  /// 出处：oicq ts `lib/core/base-client.ts` 的 `syncTimeDiff()`。
  Future<int> correctTime() async {
    final r = await sendLoginLayer(
      'Client.CorrectTime',
      Uint8List(4),
      type: Qq8LoginType.heartbeat,
    );
    if (r.payload.length < 4) {
      throw Qq8LoginException('CorrectTime 响应太短（${r.payload.length} 字节）');
    }
    final ts = (r.payload[0] << 24) |
        (r.payload[1] << 16) |
        (r.payload[2] << 8) |
        r.payload[3];
    timeDiffSeconds = ts - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return ts;
  }

  /// `OidbSvc.0x480_9_IMCore`：UNI 包心跳。
  ///
  /// body 的构造（oicq ts `base-client.ts` 的 `hb480`）：
  /// `pb {1: 1152, 2: 9, 4: <9 字节：u32 uin(大端) + 1 字节空洞 + i32 0x19e39>}`。
  Future<Qq8SsoResponse> uniHeartbeat() {
    final buf = Uint8List(9);
    ByteData.sublistView(buf)
      ..setUint32(0, uin) // 大端（参考实现 writeUInt32BE）
      ..setUint32(5, 0x19e39);
    return sendUni(
      'OidbSvc.0x480_9_IMCore',
      Qq8Pb.encode(<int, Object?>{1: 1152, 2: 9, 4: buf}),
    );
  }

  /// 开始心跳循环（默认 4.5 分钟，oicq 的 `interval` 量级）。
  ///
  /// 每轮：校时 → `Heartbeat.Alive` → UNI 心跳；UNI 心跳连失败两次视为
  /// 掉线：停表、置离线、回调 [onOffline]（对应 oicq 两次超时后 destroy）。
  void startHeartbeat({Duration interval = const Duration(seconds: 270)}) {
    stopHeartbeat();
    _online = true;
    _timer = Timer.periodic(interval, (_) => unawaited(heartbeatOnce()));
  }

  void stopHeartbeat() {
    _timer?.cancel();
    _timer = null;
  }

  /// 单次心跳（循环里调用；测试与手动触发也用它）。
  ///
  /// 心跳主体成功后，每 [_statusReportEvery] 次额外发一次在线状态上报
  /// （参考实现 `icqq/lib/client.js:225-229` 的 `n > 10` 计数，即第 11 次触发）。
  Future<bool> heartbeatOnce() async {
    try {
      await correctTime();
    } on Object {
      // 校时失败不致命，继续走心跳主体
    }
    try {
      await heartbeatAlive();
      // 官方把「注册」当作推送会话的续租：`msf/core/push/e.java:318-327`
      // 拿 `iHelloInterval` 排下一次注册（`g.java:665-670` 默认 300 s），
      // 且下次注册要回送服务端给的 timeStamp / iLargeSeq。缺了这步，
      // 服务端看到的是「一条只在登录时注册过一次的连接」。
      try {
        await registerParsed(timeout: const Duration(seconds: 10));
      } on Object {
        // 续租失败不致命（注册成功与否另有在线检查判读），下一轮再来。
      }
      await uniHeartbeat();
      await _maybeReportStatus();
      return true;
    } on Object {
      // 一次失败重试一次（参考实现同款）
      try {
        await uniHeartbeat();
        await _maybeReportStatus();
        return true;
      } on Object {
        // 心跳连败 = 这条连接不可用：走与传输层断开同一条上报路径。
        _handleTransportDown(Qq8TransportException('心跳连续失败，连接已断开'));
        return false;
      }
    }
  }

  /// 心跳计数器与重发间隔（11 = 参考实现的 `n > 10`）。
  int _heartbeatCount = 0;
  static const int _statusReportEvery = 11;

  /// 每 11 次心跳补报一次在线状态。
  ///
  /// 服务端似乎会遗忘客户端状态（心跳只证明"连接活着"，不证明"我在线"），
  /// 官方因此周期性重报。失败静默——它只是维护性请求，不该影响心跳结论。
  Future<void> _maybeReportStatus() async {
    if (++_heartbeatCount < _statusReportEvery) return;
    _heartbeatCount = 0;
    try {
      await setOnlineStatus();
    } on Object {
      // setOnlineStatus 内部已吞异常，这里只是双保险
    }
  }

  /// 结束会话：停心跳、关推送流、关连接。
  Future<void> close() async {
    if (_closed) return; // 重复关闭必须安全（teardown 与 UI 都会调）
    _closed = true;
    stopHeartbeat();
    _online = false;
    _started = false;
    _failAllPending(Qq8TransportException('会话已关闭'));
    if (!_pushes.isClosed) await _pushes.close();
    await transport.close();
  }

  static Uint8List _secureBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(n, (_) => r.nextInt(256), growable: false),
    );
  }
}
