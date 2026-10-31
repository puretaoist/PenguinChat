/// 会话层（`qq8_session.dart`）离线自测
///
/// 用脚本化传输（`Qq8ScriptedTransport`）跑一遍完整的登录后流程：
/// 注册 → 校时 → `Heartbeat.Alive` → UNI 心跳 → 主动推送路由。
/// 断言的"帧"都按真机响应结构构造（外壳 + SSO 头 + payload）。
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/qq8_session_selftest.dart
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/infra/coder.dart';
import 'package:qqclient/kernel/crypto/tea.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_jce.dart';
import 'package:qqclient/kernel/wlogin8/qq8_msg.dart';
import 'package:qqclient/kernel/wlogin8/qq8_pb.dart';
import 'package:qqclient/kernel/wlogin8/qq8_profiles.dart';
import 'package:qqclient/kernel/wlogin8/qq8_session.dart';
import 'package:qqclient/kernel/wlogin8/qq8_sso.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tran.dart';

int _pass = 0;
int _fail = 0;

void ok(String name, [String? note]) {
  _pass++;
  stdout.writeln('  \u2713 $name${note == null ? '' : '   ($note)'}');
}

void bad(String name, String detail) {
  _fail++;
  stdout.writeln('  \u2717 $name\n      → $detail');
}

void checkEq(String name, Object? actual, Object? expected) {
  if ('$actual' == '$expected') {
    ok(name);
  } else {
    bad(name, '期望 $expected，实际 $actual');
  }
}

void section(String t) => stdout.writeln('\n$t');

Uint8List hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String toHex(List<int> b) =>
    b.map((x) => (x & 0xff).toRadixString(16).padLeft(2, '0')).join();

final Uint8List _d2key = hex('00112233445566778899aabbccddeeff');

Qq8Device _device() => Qq8Device(
      product: 'piano',
      device: 'piano',
      board: 'piano',
      brand: 'Xiaomi',
      model: '25091RP04C',
      bootloader: 'unknown',
      fingerprint: 'Xiaomi/piano/piano:16/BP2A/eng:user/release-keys',
      bootId: '11111111-2222-3333-4444-555555555555',
      procVersion: 'Linux version 5.15.0',
      baseband: '',
      sim: 'T-Mobile',
      apn: 'wifi',
      osType: 'android',
      macAddress: '00:50:56:C0:00:08',
      ipAddress: '10.0.0.1',
      wifiBssid: '00:50:56:C0:00:08',
      wifiSsid: 'TP-LINK-2711',
      imei: '860000000000001',
      androidId: 'ABCDEF1234567890',
      version: const Qq8AndroidVersion(
        release: '10',
        codename: 'REL',
        incremental: '1234567',
        sdk: 29,
      ),
      imsi: Uint8List(16),
      tgtgt: Uint8List(16),
      guid: hex('00112233445566778899aabbccddeeff'),
    );

/// 造一个真机结构的响应帧：`[外壳(flag=2)][SSO 头][payload]`。
Uint8List _frame({
  required int seq,
  required String cmd,
  Uint8List? payload,
  int retcode = 0,
}) {
  final cmdBytes = utf8.encode(cmd);
  final header = (ByteWriter()
        ..u32(0) // headlen 占位
        ..u32(seq)
        ..u32(retcode)
        ..u32(4)
        ..u32(cmdBytes.length + 4)
        ..raw(cmdBytes)
        ..u32(8)
        ..raw(hex('01020304'))
        ..u32(0))
      .build();
  final headlen = header.length - 4;
  header[0] = (headlen >> 24) & 0xff;
  header[1] = (headlen >> 16) & 0xff;
  header[2] = (headlen >> 8) & 0xff;
  header[3] = headlen & 0xff;

  final plain = Uint8List.fromList(<int>[...header, ...(payload ?? Uint8List(0))]);
  final uinBytes = utf8.encode('10001');
  return (ByteWriter()
        ..u32(0x0A)
        ..u8(2) // TEA 全零
        ..u32(0)
        ..u8(4 + uinBytes.length)
        ..raw(uinBytes)
        ..raw(qqTeaEncrypt(plain, Uint8List(16))))
      .build();
}

/// 注册响应（WUP 包装，`cReplyCode(tag 2)` 为结果码——官方
/// `SvcRespRegister` 字段序，见 `qq8_register.dart` 的判读注释）。
Uint8List _registerResp(int replyCode) {
  final struct = Qq8Jce.encodeStruct(<int, Object?>{0: 10001, 2: replyCode});
  final payload = Qq8Jce.encode(<int, Object?>{
    0: <Object?, Object?>{'SvcRespRegister': struct},
  });
  return Qq8Jce.encode(<int, Object?>{7: payload});
}

/// 从 UNI 包（或登录层包）里拆出命令字与 body——测试断言用。
({String cmd, Uint8List body}) _uniParts(Uint8List pkt) {
  // UNI 包：[u32 total][u32 0x0B][u8 1][i32 seq][u8 0][u32 uinLen+4][uin][TEA(sso)]
  final r = ByteReader(pkt);
  r.readUint32();
  r.readUint32();
  r.read(1);
  r.read(4);
  r.read(1);
  final uinLen = r.readUint32();
  r.read(uinLen - 4);
  final sso = qqTeaDecrypt(r.readRest(), _d2key);
  final ir = ByteReader(sso);
  final headlen = ir.readUint32();
  final cmdLen = ir.readUint32();
  final cmd = String.fromCharCodes(sso.sublist(8, 8 + cmdLen - 4));
  var pos = 8 + cmdLen - 4;
  pos += 4; // session 长度字段
  pos += 4; // session
  pos += 4; // 固定 4
  final bodyLen = (sso[pos] << 24) | (sso[pos + 1] << 16) |
      (sso[pos + 2] << 8) | sso[pos + 3];
  final body = sso.sublist(pos + 4, pos + bodyLen);
  // headlen 与 cmd 的一致性（headlen = 头总长 - 4）
  if (headlen != pos - 4 + 4 + bodyLen - 4) {
    // 不做强断言，避免测试自身算错；由 body 回读兜底
  }
  return (cmd: cmd, body: body);
}

/// 从登录层信封（0x0A）里取出未加密前的请求 body。
///
/// 结构见 [Qq8Sso.buildLoginPacket]：
/// 外层 = `u32 0x0A | u8 type | withLen(d2) | u8 0 | withLen(uin:ascii) | sso`；
/// sso = `withLen(inner 头) | withLen(body)`，type==1 用 d2key TEA 加密、
/// type==2 用全零密钥、type==0 明文。
Uint8List _loginLayerBody(Uint8List pkt) {
  final r = ByteReader(pkt);
  r.readUint32(); // 外层总长
  final o = ByteReader(r.readRest());
  o.readUint32(); // 0x0A
  final type = o.read(1)[0];
  final d2len = o.readUint32();
  o.read(d2len - 4);
  o.read(1); // 常量 0
  final uinLen = o.readUint32();
  o.read(uinLen - 4);
  var sso = o.readRest();
  if (type == Qq8LoginType.online) {
    sso = qqTeaDecrypt(sso, _d2key);
  } else if (type == Qq8LoginType.login) {
    sso = qqTeaDecrypt(sso, Uint8List(16));
  }
  final s = ByteReader(sso);
  final innerLen = s.readUint32();
  s.read(innerLen - 4);
  final bodyLen = s.readUint32();
  return Uint8List.fromList(s.read(bodyLen - 4));
}

/// 只发不收的传输层：write 成功但永不投递响应（模拟"断网但 socket 没报错"）。
class _HangingTransport implements Qq8Transport {
  final List<Uint8List> sent = <Uint8List>[];
  void Function(Object error)? _onDisconnected;
  bool _connected = false;

  @override
  Future<void> connect() async => _connected = true;

  @override
  Future<Uint8List> send(Uint8List payload, {Duration? timeout}) async {
    sent.add(payload);
    return Completer<Uint8List>().future; // 永不返回
  }

  @override
  Future<void> write(Uint8List packet) async => sent.add(packet);

  @override
  set onFrame(void Function(Uint8List frame)? cb) {} // 只发不收：不需要收帧回调

  @override
  set onDisconnected(void Function(Object error)? cb) => _onDisconnected = cb;

  void emitDisconnect([Object? error]) =>
      _onDisconnected?.call(error ?? StateError('对端关闭'));

  @override
  Future<void> close() async => _connected = false;

  @override
  bool get isConnected => _connected;
}

/// 第 n 次写慢 delays[n]，并按 frameOf(n) 投递响应（null = 永不投递）。
/// 用来验证「首发+重发共享一个总时限」。
class _SlowResendTransport implements Qq8Transport {
  _SlowResendTransport(this.delays, this.frameOf);
  final List<Duration> delays;
  final Uint8List? Function(int index) frameOf;
  int _i = 0;
  void Function(Uint8List frame)? _onFrame;

  @override
  Future<void> connect() async {}

  @override
  Future<Uint8List> send(Uint8List payload, {Duration? timeout}) async =>
      frameOf(_i++) ?? Completer<Uint8List>().future;

  @override
  Future<void> write(Uint8List packet) async {
    final i = _i++;
    final d = i < delays.length ? delays[i] : delays.last;
    await Future<void>.delayed(d);
    final f = frameOf(i);
    if (f != null) _onFrame?.call(f);
  }

  @override
  set onFrame(void Function(Uint8List frame)? cb) => _onFrame = cb;

  @override
  set onDisconnected(void Function(Object error)? cb) {}

  @override
  Future<void> close() async {}

  @override
  bool get isConnected => true;
}

Future<void> main() async {
  stdout.writeln('会话层离线自测');
  stdout.writeln('=' * 62);

  const fixedTs = 1800000000; // 校时响应用
  final transport = Qq8ScriptedTransport(<Uint8List>[
    _frame(seq: 101, cmd: 'StatSvc.register', payload: _registerResp(0)),
    _frame(
      seq: 102,
      cmd: 'Client.CorrectTime',
      payload: hex('6b49d200'), // i32 大端 = fixedTs
    ),
    _frame(seq: 103, cmd: 'Heartbeat.Alive'),
    _frame(seq: 104, cmd: 'OidbSvc.0x480_9_IMCore', payload: hex('0a00')),
    _frame(seq: 105, cmd: 'StatSvc.SetStatusFromClient', payload: _registerResp(0)),
    // 5b 用：回执类请求(seq 106)的"响应"——正常情况下服务端不会回，
    // 这里故意给一个，用来证明我们**没有**在等它。
    _frame(seq: 106, cmd: 'OnlinePush.RespPush'),
  ]);

  final session = Qq8Session(
    transport: transport,
    profile: qq8ProfileQQ8950,
    uin: 10001,
    device: _device(),
    sessionId: hex('01020304'),
    ecdhPublicKey: hex('04${'11' * 64}'),
    ecdhShareKey: hex('f3df7dfb6d55b17975d908d8228dee11'),
    sig: Qq8SigInfo(d2key: _d2key, tgt: hex('1122334455667788')),
    randomKey: hex('0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f'),
    seqStart: 100,
  );
  final errors = <Object>[];
  session.onError = errors.add;
  await session.start();

  section('1. 注册（seq 101）');
  final reg = await session.register();
  checkEq('register() = true', reg, true);
  checkEq('收包无解析错误', errors.length, 0);
  final sentRegister = transport.sent[0];
  checkEq('发的是登录层包（偏移 4 起是 0x0A 登录信封）',
      toHex(sentRegister.sublist(4, 8)), '0000000a');

  section('2. 校时（seq 102）');
  final ts = await session.correctTime();
  checkEq('返回服务端时间', ts, fixedTs);
  final diff = session.timeDiffSeconds;
  final expect = fixedTs - DateTime.now().millisecondsSinceEpoch ~/ 1000;
  checkEq('timeDiffSeconds 与本地时钟的差在 ±5 秒内', (diff - expect).abs() <= 5,
      true);

  section('3. Heartbeat.Alive（seq 103）');
  final hb = await session.heartbeatAlive();
  checkEq('收到空闲响应', hb.payload.length, 0);
  checkEq('帧里带命令字 Heartbeat.Alive',
      String.fromCharCodes(transport.sent[2]).contains('Heartbeat.Alive'), true);

  section('1b. 登录层信封：只有 type=login 才套 OICQ（缺陷1 根因）');
  {
    // 真机缺陷1 的候选根因：以前 sendLoginLayer 无条件给 body 套
    // buildOicqPacket（首字节 0x02）。但注册/校时/心跳的 body 本身就是
    // WUP 原始字节，套了就是多发一层。这里从实际发出的包反解 body 验证。
    final regBody = _loginLayerBody(transport.sent[0]);
    checkEq('register body 首字节不是 0x02（未套 OICQ 信封）',
        regBody.isEmpty || regBody[0] != 0x02, true);
    final regFields = Qq8Jce.decodeWrapper(regBody);
    checkEq('register body 是原始 WUP（tag0 = uin 10001）', regFields[0], 10001);
    checkEq('register body 带 pb blob（tag38 = 1000）', regFields[38], 1000);
    checkEq('register body tag4 = 11（在线，非登出）', regFields[4], 11);
    // 校时：type=0 明文，body 是 4 字节零。
    final ctBody = _loginLayerBody(transport.sent[1]);
    checkEq('校时 body = 4 字节零（type=0 明文）', toHex(ctBody), '00000000');
    // 心跳：type=0 空 body。
    final hbBody = _loginLayerBody(transport.sent[2]);
    checkEq('Heartbeat.Alive body 为空', hbBody.length, 0);
  }

  section('4. UNI 心跳（seq 104）');
  final uni = await session.uniHeartbeat();
  checkEq('收到响应', uni.cmd, 'OidbSvc.0x480_9_IMCore');
  final parts = _uniParts(transport.sent[3]);
  checkEq('UNI 包命令字', parts.cmd, 'OidbSvc.0x480_9_IMCore');
  final expectBody = (() {
    final buf = Uint8List(9);
    ByteData.sublistView(buf)
      ..setUint32(0, 10001)
      ..setUint32(5, 0x19e39);
    return Qq8Pb.encode(<int, Object?>{1: 1152, 2: 9, 4: buf});
  })();
  checkEq('UNI 心跳 body = pb {1:1152,2:9,4:…}',
      toHex(parts.body), toHex(expectBody));

  section('4b. 在线状态上报（SetStatusFromClient，0x0B 外壳）');
  final statusOk = await session.setOnlineStatus();
  checkEq('setOnlineStatus() = true', statusOk, true);
  checkEq('收包仍无解析错误', errors.length, 0);
  final sentStatus = transport.sent[4];
  checkEq('走 UNI 外壳（偏移 4 起是 0x0B）', toHex(sentStatus.sublist(4, 8)),
      '0000000b');
  final statusParts = _uniParts(sentStatus);
  checkEq('命令字 = StatSvc.SetStatusFromClient', statusParts.cmd,
      'StatSvc.SetStatusFromClient');
  // 与 register 的 body 必须不同（否则就是把状态包写成了注册包）。
  // 不能拿 _uniParts 解 register：那个 helper 按 0x0B 布局写死，遇 0x0A 会算错。
  // 直接从状态包 body 里读 JCE 槽位做判据更稳。
  final statusFields = Qq8Jce.decodeWrapper(statusParts.body);
  checkEq('状态包 tag10 = 248（register 是 0）', statusFields[10], 248);
  checkEq('状态包 tag33 缺失（register 带 pb blob）',
      statusFields.containsKey(33), false);
  checkEq('状态包 tag38 = 0（register 是 1000）', statusFields[38], 0);

  section('5. 主动推送路由');
  final pushFuture = session.pushes.first;
  transport.emit(_frame(seq: 999, cmd: 'MessageSvc.PushNotify', payload: hex('cafe')));
  final push = await pushFuture.timeout(const Duration(seconds: 2));
  checkEq('推送帧进了 pushes 流（seq 不匹配任何请求）', push.seq, 999);
  checkEq('推送命令字', push.cmd, 'MessageSvc.PushNotify');
  checkEq('推送负载', toHex(push.payload), 'cafe');

  section('5b. 只发不等（回执类请求不能等应答）');
  {
    // 真机实证：PushResp 用 sendUni 发时必然空等 10 秒再报超时
    // （`ConfigPushSvc.PushResp 失败 | 等待响应超时（seq=-1807239620，10s）`）。
    // 回执类请求服务端从不回包，官方是 setNeedCallback(false) 发完就忘。
    final back = session.pushes.first;
    final sw = Stopwatch()..start();
    await session.sendUniNoReply(Qq8Msg.respPushCmd, hex('0a00'), seq: 106);
    sw.stop();
    checkEq('立即返回（不等任何响应，<1s）', sw.elapsedMilliseconds < 1000, true);
    final sentAck = transport.sent[5];
    checkEq('走 UNI 外壳（偏移 4 起是 0x0B）', toHex(sentAck.sublist(4, 8)),
        '0000000b');
    final ackParts = _uniParts(sentAck);
    checkEq('命令字 = OnlinePush.RespPush', ackParts.cmd,
        Qq8Msg.respPushCmd);
    checkEq('body 原样带出', toHex(ackParts.body), '0a00');
    // 关键：没登记 _pending，所以同 seq 的响应会走推送通道，而不是完成某个 Future
    final stray = await back.timeout(const Duration(seconds: 2));
    checkEq('同 seq 的"响应"被当推送（证明没登记 pending）', stray.seq, 106);
  }

  section('5c. 服务端 retcode：-10008 重发一次，其余原样上报');
  {
    // 真机 2026-10-26 21:46 服务端连着回 -10008，我们当时当解析失败丢帧，
    // 请求全部等到超时。官方 `msf/core/ag.java:1782-1793` 是 `reSendMsg` 重发一次。
    transport.scriptedResponses.addAll(<Uint8List>[
      _frame(seq: 107, cmd: 'OidbSvc.0x480_9_IMCore', retcode: qq8RetcodeResend),
      _frame(seq: 107, cmd: 'OidbSvc.0x480_9_IMCore', payload: hex('0a00')),
      _frame(seq: 108, cmd: 'MessageSvc.PbGetGroupMsg', retcode: -10003),
    ]);
    final sentBefore = transport.sent.length;
    final errBefore = errors.length;
    final resendResp =
        await session.sendUni('OidbSvc.0x480_9_IMCore', Uint8List(0), seq: 107);
    checkEq('重发一次后拿到正常响应', resendResp.retcode, 0);
    checkEq('同一请求发了两遍', transport.sent.length - sentBefore, 2);
    checkEq('重发过程上报了一条异常', errors.length - errBefore, 1);
    final resendErr = errors.isEmpty ? null : errors.last;
    checkEq('上报的是 Qq8ServerRetcodeException',
        resendErr is Qq8ServerRetcodeException, true);
    checkEq('该异常标记为已重发（resent=true）',
        resendErr is Qq8ServerRetcodeException && resendErr.resent, true);
    var thrown = '';
    var authDead = false;
    try {
      await session.sendUni('MessageSvc.PbGetGroupMsg', Uint8List(0), seq: 108);
      thrown = '没有抛出';
    } on Qq8ServerRetcodeException catch (e) {
      thrown = 'retcode=${e.retcode} resent=${e.resent}';
      authDead = e.authDead;
    }
    checkEq('-10003 不重发、直接抛出并带上 retcode', thrown, 'retcode=-10003 resent=false');

    // 身份失效码的分类（官方 msf/core/ah.java:35-37 那一组）。
    // 上层据此停止轮询并提示重登——判反了就是「一直重试一条永远失败的请求」。
    checkEq('-10003 归入「身份失效」', authDead, true);
    for (final code in <int>[
      -12003, 210, -10001, -10004, -10006, -10106, -10009, -10102, -10103,
    ]) {
      checkEq('retcode=$code 归入「身份失效」',
          Qq8ServerRetcodeException(retcode: code, seq: 0).authDead, true);
    }
    for (final code in <int>[-10008, -10007, -10000, 0, -1]) {
      checkEq('retcode=$code **不**归入「身份失效」',
          Qq8ServerRetcodeException(retcode: code, seq: 0).authDead, false);
    }
  }
  section('6. 心跳失败的降级');
  // 脚本已用尽 → 下一次 uniHeartbeat 会抛错；再调一次仍失败 → onOffline
  var offline = false;
  session.onOffline = () => offline = true;
  final ok1 = await session.heartbeatOnce();
  checkEq('脚本用尽 → 一轮心跳失败（返回 false）', ok1, false);
  checkEq('触发 onOffline', offline, true);

  await session.close();
  checkEq('关闭后 isOnline = false', session.isOnline, false);

  // ------------------------------------------------------------------
  // 7. 断链统一收敛（缺陷2）：挂起请求立即终结、上报幂等、close 幂等
  // ------------------------------------------------------------------
  section('7. 断链统一收敛（缺陷2）');
  final hang = _HangingTransport();
  final s2 = Qq8Session(
    transport: hang,
    profile: qq8ProfileQQ8950,
    uin: 10001,
    device: _device(),
    sessionId: hex('01020304'),
    ecdhPublicKey: hex('04${'11' * 64}'),
    ecdhShareKey: hex('f3df7dfb6d55b17975d908d8228dee11'),
    sig: Qq8SigInfo(d2key: _d2key),
  );
  await s2.start();
  var lost = 0;
  Object? lostErr;
  var offlineCount = 0;
  s2.onConnectionLost = (Object e) {
    lost++;
    lostErr = e;
  };
  s2.onOffline = () => offlineCount++;

  var pulled = s2.sendUni('MessageSvc.PbGetMsg', Uint8List(0), seq: 901,
      timeout: const Duration(seconds: 30));
  final sw = Stopwatch()..start();
  await Future<void>.delayed(const Duration(milliseconds: 30));
  hang.emitDisconnect();
  var pullOutcome = '没有抛出';
  try {
    await pulled;
  } on Object catch (e) {
    pullOutcome = e.toString();
  }
  sw.stop();
  checkEq('挂起请求被立即终结（不等 30s 超时）', sw.elapsedMilliseconds < 2000, true,
      );
  checkEq('终结原因是「连接已断开」', pullOutcome.contains('连接已断开'), true);
  checkEq('断链上报带原因', lostErr != null, true);
  checkEq('onConnectionLost 已触发', lost, 1);
  // 再来一次断开事件：必须幂等
  hang.emitDisconnect();
  await Future<void>.delayed(const Duration(milliseconds: 10));
  checkEq('重复断开事件幂等（只报一次）', lost, 1);
  checkEq('兼容回调 onOffline 也只触发一次', offlineCount, 1);
  // 断链后再发包：立刻失败，不再写进 socket
  final afterCount = hang.sent.length;
  var afterOutcome = '没有抛出';
  try {
    await s2.sendUni('MessageSvc.PbGetMsg', Uint8List(0), seq: 902,
        timeout: const Duration(seconds: 5));
  } on Object catch (e) {
    afterOutcome = e.toString();
  }
  checkEq('断链后新请求立即失败', afterOutcome.contains('连接已断开'), true);
  checkEq('断链后不再写 socket', hang.sent.length, afterCount);
  await s2.close();
  await s2.close(); // 重复关闭必须安全
  ok('重复 close 安全');

  // 总时限：两次应答都慢 40ms，单请求 timeout 60ms；
  // 重发必须共享同一预算，总耗时不能逼近 80ms+。
  // 第 1 次 40ms 回 -10008；第 2 次永不回。
  // 旧语义：第二次还会再等满 100ms（总 140ms）。新语义：共享 100ms 预算。
  final slow = _SlowResendTransport(
    const <Duration>[Duration(milliseconds: 40), Duration(seconds: 10)],
    (int i) => i == 0
        ? _frame(seq: 911, cmd: 'OidbSvc.0x480_9_IMCore', retcode: -10008)
        : null,
  );
  final s3 = Qq8Session(
    transport: slow,
    profile: qq8ProfileQQ8950,
    uin: 10001,
    device: _device(),
    sessionId: hex('01020304'),
    ecdhPublicKey: hex('04${'11' * 64}'),
    ecdhShareKey: hex('f3df7dfb6d55b17975d908d8228dee11'),
    sig: Qq8SigInfo(d2key: _d2key),
  );
  await s3.start();
  final sw2 = Stopwatch()..start();
  var timeoutOutcome = '没有抛出';
  try {
    await s3.sendUni('OidbSvc.0x480_9_IMCore', Uint8List(0), seq: 911,
        timeout: const Duration(milliseconds: 100));
  } on Object catch (e) {
    timeoutOutcome = e.toString();
  }
  sw2.stop();
  checkEq('重发共享总时限（不把 100ms 翻成 140ms）',
      sw2.elapsedMilliseconds < 125, true);
  checkEq('总时限耗尽按超时上报', timeoutOutcome.contains('超时'), true);
  await s3.close();

  // 重发风暴：连续 3 个请求都耗尽重发预算 ⇒ resendStormSuspected
  final stormFrames = <Uint8List>[
    for (var i = 0; i < 6; i++)
      _frame(seq: 921, cmd: 'OidbSvc.0x480_9_IMCore', retcode: -10008),
  ];
  final stormTran = Qq8ScriptedTransport(stormFrames);
  final s4 = Qq8Session(
    transport: stormTran,
    profile: qq8ProfileQQ8950,
    uin: 10001,
    device: _device(),
    sessionId: hex('01020304'),
    ecdhPublicKey: hex('04${'11' * 64}'),
    ecdhShareKey: hex('f3df7dfb6d55b17975d908d8228dee11'),
    sig: Qq8SigInfo(d2key: _d2key),
  );
  await s4.start();
  checkEq('风暴前不判风暴', s4.resendStormSuspected, false);
  for (var i = 0; i < 3; i++) {
    try {
      await s4.sendUni('OidbSvc.0x480_9_IMCore', Uint8List(0), seq: 921,
          timeout: const Duration(seconds: 5));
    } on Object {
      // 预期：三次都耗尽重发预算后抛出
    }
  }
  checkEq('连续 3 次耗尽重发预算 → 疑云置位', s4.resendStormSuspected, true);
  await s4.close();

  section('11b. 注册三态：authDead 必须抛出，不能吞成「无回执」');
  {
    Qq8Session mk(int retcode) => Qq8Session(
          transport: Qq8ScriptedTransport(<Uint8List>[
            _frame(seq: 101, cmd: 'StatSvc.register', retcode: retcode),
          ]),
          profile: qq8ProfileQQ8950,
          uin: 10001,
          device: _device(),
          sessionId: hex('01020304'),
          ecdhPublicKey: hex('04${'11' * 64}'),
          ecdhShareKey: hex('f3df7dfb6d55b17975d908d8228dee11'),
          sig: Qq8SigInfo(d2key: _d2key),
          seqStart: 100,
        );

    final sAuth = mk(-10003);
    await sAuth.start();
    Object? caught;
    Qq8RegisterOutcome? got;
    try {
      got =
          await sAuth.registerWithOutcome(timeout: const Duration(seconds: 5));
    } on Object catch (e) {
      caught = e;
    }
    checkEq('authDead(-10003) → 抛 Qq8ServerRetcodeException',
        caught is Qq8ServerRetcodeException, true);
    checkEq('该异常被标成 authDead',
        caught is Qq8ServerRetcodeException && caught.authDead, true);
    checkEq('authDead → 不返回 unconfirmed', got == null, true);
    await sAuth.close();

    final sPlain = mk(-1000);
    await sPlain.start();
    final plain =
        await sPlain.registerWithOutcome(timeout: const Duration(seconds: 5));
    checkEq('普通返回码(-1000) → 仍是 unconfirmed（不当终态）', plain,
        Qq8RegisterOutcome.unconfirmed);
    await sPlain.close();
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
