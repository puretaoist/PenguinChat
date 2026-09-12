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

  /// 收包解析失败的回调（不中断会话）。
  void Function(Object error)? onError;

  /// 心跳连失败两次（视为掉线）时的回调。
  void Function()? onOffline;

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
    _started = true;
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
      );

  Future<Qq8SsoResponse> _send(
    int seq,
    Uint8List packet,
    Duration timeout,
  ) async {
    final c = Completer<Qq8SsoResponse>();
    _pending[seq] = c;
    try {
      await transport.write(packet);
    } on Object {
      _pending.remove(seq);
      rethrow;
    }
    return c.future.timeout(timeout, onTimeout: () {
      _pending.remove(seq);
      throw Qq8TransportException('等待响应超时（seq=$seq，${timeout.inSeconds}s）');
    });
  }

  /// 登录层请求（命令字 + 信封 type=0/1）。
  ///
  /// type 见 [Qq8LoginType]：心跳类用 0（SSO 层不加密）、上线后用 1
  /// （SSO 层用 d2key 加密）。
  Future<Qq8SsoResponse> sendLoginLayer(
    String cmd,
    Uint8List body, {
    int type = Qq8LoginType.online,
    Duration timeout = const Duration(seconds: 10),
  }) {
    final seq = _nextSeq();
    final ctx = _ctx(seq);
    final pkt = Qq8Sso.buildLoginPacket(
      ctx,
      cmd,
      Qq8Sso.buildOicqPacket(ctx, body),
      type,
    );
    return _send(seq, pkt, timeout);
  }

  /// UNI 包请求（业务命令字）。响应按 SSO 头里的 seq 配对。
  Future<Qq8SsoResponse> sendUni(
    String cmd,
    Uint8List body, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    final seq = _nextSeq();
    final pkt = Qq8Uni.build(
      uin: uin,
      cmd: cmd,
      body: body,
      seq: seq,
      session: sessionId,
      d2key: sig.d2key,
    );
    return _send(seq, pkt, timeout);
  }

  // ------------------------------------------------------------------
  // 注册与心跳
  // ------------------------------------------------------------------

  /// 上线注册（`StatSvc.register`）：登录成功后必须发的第一个业务请求。
  ///
  /// 出处：oicq `lib/core/base-client.ts` 的 `register()`；结构见 [Qq8Register]。
  Future<bool> register({bool logout = false}) async {
    final body = Qq8Register.buildBody(
      uin: uin,
      device: device,
      logout: logout,
    );
    final r = await sendLoginLayer(
      Qq8Register.cmd,
      body,
      type: Qq8LoginType.online,
    );
    return Qq8Register.parseResponse(r.payload);
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
  Future<bool> heartbeatOnce() async {
    try {
      await correctTime();
    } on Object {
      // 校时失败不致命，继续走心跳主体
    }
    try {
      await heartbeatAlive();
      await uniHeartbeat();
      return true;
    } on Object {
      // 一次失败重试一次（参考实现同款）
      try {
        await uniHeartbeat();
        return true;
      } on Object {
        _online = false;
        stopHeartbeat();
        onOffline?.call();
        return false;
      }
    }
  }

  /// 结束会话：停心跳、关推送流、关连接。
  Future<void> close() async {
    stopHeartbeat();
    _online = false;
    _started = false;
    await _pushes.close();
    await transport.close();
  }

  static Uint8List _secureBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(n, (_) => r.nextInt(256), growable: false),
    );
  }
}
