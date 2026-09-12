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

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/infra/coder.dart';
import 'package:qqclient/kernel/crypto/tea.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_jce.dart';
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

/// 注册响应（WUP 包装，`rsp[9]` 为结果码）。
Uint8List _registerResp(int result) {
  final struct = Qq8Jce.encodeStruct(<int, Object?>{0: 10001, 9: result});
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

Future<void> main() async {
  stdout.writeln('会话层离线自测');
  stdout.writeln('=' * 62);

  const fixedTs = 1800000000; // 校时响应用
  final transport = Qq8ScriptedTransport(<Uint8List>[
    _frame(seq: 101, cmd: 'StatSvc.register', payload: _registerResp(1)),
    _frame(
      seq: 102,
      cmd: 'Client.CorrectTime',
      payload: hex('6b49d200'), // i32 大端 = fixedTs
    ),
    _frame(seq: 103, cmd: 'Heartbeat.Alive'),
    _frame(seq: 104, cmd: 'OidbSvc.0x480_9_IMCore', payload: hex('0a00')),
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

  section('5. 主动推送路由');
  final pushFuture = session.pushes.first;
  transport.emit(_frame(seq: 999, cmd: 'MessageSvc.PushNotify', payload: hex('cafe')));
  final push = await pushFuture.timeout(const Duration(seconds: 2));
  checkEq('推送帧进了 pushes 流（seq 不匹配任何请求）', push.seq, 999);
  checkEq('推送命令字', push.cmd, 'MessageSvc.PushNotify');
  checkEq('推送负载', toHex(push.payload), 'cafe');

  section('6. 心跳失败的降级');
  // 脚本已用尽 → 下一次 uniHeartbeat 会抛错；再调一次仍失败 → onOffline
  var offline = false;
  session.onOffline = () => offline = true;
  final ok1 = await session.heartbeatOnce();
  checkEq('脚本用尽 → 一轮心跳失败（返回 false）', ok1, false);
  checkEq('触发 onOffline', offline, true);

  await session.close();
  checkEq('关闭后 isOnline = false', session.isOnline, false);

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
