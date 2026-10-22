/// 原始帧探针：只发一个 UNI 包，把回包原样 hex dump 出来。
///
/// 用于给 `qq8_recv.dart` 补 `magic=0x0B` 外壳与 SSO `gzip` 支持提供真实样本。
///
/// 用法：
/// ```bash
/// QQ_LIVE_CONFIRM=I_UNDERSTAND_THE_RISK dart run tool/qq8_raw_probe.dart --send \
///   --token-file=... --uin=2089495846 --cmd=OidbSvc.0x480_9_IMCore
/// ```
///
/// 先走一次 token 登录拿新 d2key，再发目标 UNI 包。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:qqclient/kernel/crypto/ecdh.dart';
import 'package:qqclient/kernel/wlogin8/qq8_config.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_login.dart';
import 'package:qqclient/kernel/wlogin8/qq8_pb.dart';
import 'package:qqclient/kernel/wlogin8/qq8_profiles.dart';
import 'package:qqclient/kernel/wlogin8/qq8_protocol_det.dart';
import 'package:qqclient/kernel/wlogin8/qq8_recv.dart';
import 'package:qqclient/kernel/wlogin8/qq8_sso.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tlv.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tran.dart';

void out(String s) => stdout.writeln(s);

Uint8List _hexToBytes(String? s) {
  if (s == null || s.isEmpty) return Uint8List(0);
  final r = Uint8List(s.length ~/ 2);
  for (var i = 0; i < r.length; i++) {
    r[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return r;
}

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _rnd(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

Future<void> main(List<String> argv) async {
  final args = <String, String>{};
  for (final a in argv) {
    if (!a.startsWith('--')) continue;
    final i = a.indexOf('=');
    if (i < 0) {
      args[a.substring(2)] = 'true';
    } else {
      args[a.substring(2, i)] = a.substring(i + 1);
    }
  }
  final send = args.containsKey('send');
  final uin = int.parse(args['uin']!);
  final profile =
      qq8ClientProfiles[args['profile'] ?? '8.2.11'] ?? qq8DefaultProfile;
  final cmd = args['cmd'] ?? 'OidbSvc.0x480_9_IMCore';

  final tj = jsonDecode(File(args['token-file']!).readAsStringSync())
      as Map<String, dynamic>;
  final tgt = _hexToBytes(tj['tgt'] as String?);
  final d2 = _hexToBytes(tj['d2'] as String?);
  final d2key = _hexToBytes(tj['d2key'] as String?);

  Qq8DeviceIdentity? identity;
  final ip = args['identity'];
  if (ip != null && File(ip).existsSync()) {
    identity = Qq8DeviceIdentity.fromJson(
        jsonDecode(File(ip).readAsStringSync()) as Map<String, Object?>);
  }
  var device = identity != null
      ? Qq8Device.fromIdentity(identity)
      : Qq8Device.generate(uin);

  Uint8List? protocolDet;
  final pd2 = args['pd2'];
  if (pd2 != null && File(pd2).existsSync()) {
    protocolDet = Qq8ProtocolDet.encode(
        Qq8ProtocolDet.decodeFile(File(pd2).readAsBytesSync()));
  }

  final ecdh = Ecdh.exchange(Uint8List.fromList(Qq8Config.serverEcdhPublicKey));
  final sessionId = _rnd(4);
  final randomKey = _rnd(16);

  // ---- 第一步：token 登录，拿新 d2key ----
  final ctx = Qq8TlvContext(
    uin: uin,
    apk: profile.apk,
    device: device,
    passwordMd5: Uint8List(0),
    seqId: 1,
    ksid: Uint8List.fromList(utf8.encode('|${device.imei}|${profile.apk.name}')),
    t104: Uint8List(0),
    t174: Uint8List(0),
    tgt: tgt,
    srmToken: Uint8List(0),
    protocolDet: protocolDet,
    t544SubCmd: Qq8SubCmd.token,
  );
  final loginBody = Qq8LoginBody.buildToken(ctx, d2: d2);

  if (!send) {
    out('dry-run：cmd=$cmd，登录 body ${loginBody.length}B');
    return;
  }
  if (Platform.environment['QQ_LIVE_CONFIRM'] != 'I_UNDERSTAND_THE_RISK') {
    out('✗ 需要 QQ_LIVE_CONFIRM=I_UNDERSTAND_THE_RISK');
    exit(2);
  }

  final tran = Qq8TcpTransport();
  await tran.connect();
  out('已连接 ${tran.host}:${tran.port}');

  final newSig = Qq8SigInfo(tgt: tgt, d2: d2, d2key: d2key);
  final ssoCtx = Qq8SsoContext(
    uin: uin,
    apk: profile.apk,
    device: device,
    sessionId: sessionId,
    randomKey: randomKey,
    ecdhPublicKey: ecdh.publicKey,
    ecdhShareKey: ecdh.shareKey,
    sig: newSig,
    qimei36: args['qimei'] ?? identity?.qimei,
    seqId: 1,
  );

  // 登录
  final pkt1 = Qq8Sso.buildLoginPacket(ssoCtx, qq8ExchangeEmpCmd,
      Qq8Sso.buildOicqPacket(ssoCtx, loginBody), Qq8LoginType.login);
  final resp1 = await tran.send(pkt1, timeout: const Duration(seconds: 20));
  out('登录回包 ${resp1.length}B，前 32B: ${_hex(Uint8List.fromList(resp1.take(32).toList()))}');
  final sso1 = qq8UnwrapRecv(resp1, d2key: d2key);
  out('SSO: cmd=${sso1.cmd} seq=${sso1.seq} 负载 ${sso1.payload.length}B '
      '前16=${_hex(Uint8List.fromList(sso1.payload.take(16).toList()))}');
  final parsed = Qq8LoginResponse.parse(sso1.payload, ecdh.shareKey);
  out('登录 type=${parsed.type} t119=${parsed.t119?.length} TLV=${parsed.tlvs.keys.toList()}');
  if (parsed.t119 == null) {
    final t146 = parsed.tlvs[0x146];
    if (t146 != null && t146.length > 6) {
      // 0x146 = u16 ? ‖ u16 titleLen ‖ title ‖ u16 msgLen ‖ msg
      final tl = (t146[2] << 8) | t146[3];
      final title = utf8.decode(t146.sublist(4, 4 + tl), allowMalformed: true);
      final ml = (t146[4 + tl] << 8) | t146[5 + tl];
      final msg = utf8.decode(t146.sublist(6 + tl, 6 + tl + ml),
          allowMalformed: true);
      out('  0x146: title=$title msg=$msg');
    }
    out('✗ 无 t119，退出');
    await tran.close();
    return;
  }
  final bundle = Qq8SigBundle.parse(parsed.t119!, device.tgtgt);
  out('新票据: tgt ${bundle.tgt!.length}B / d2 ${bundle.d2!.length}B / '
      'd2key ${bundle.d2key!.length}B');

  final sig2 = Qq8SigInfo(
    tgt: bundle.tgt,
    d2: bundle.d2,
    d2key: bundle.d2key,
  );

  // ---- 第二步：发目标 UNI 包 ----
  final Uint8List uniBody;
  if (cmd == 'OidbSvc.0x480_9_IMCore') {
    final buf = Uint8List(9);
    ByteData.sublistView(buf)
      ..setUint32(0, uin)
      ..setUint32(5, 0x19e39);
    uniBody = Qq8Pb.encode(<int, Object?>{1: 1152, 2: 9, 4: buf});
  } else {
    uniBody = Uint8List(0);
  }

  final pkt2 = Qq8Uni.build(
    uin: uin,
    cmd: cmd,
    body: uniBody,
    seq: 2,
    session: sessionId,
    d2key: sig2.d2key,
  );
  out('UNI 包 ${pkt2.length}B，前 32B: ${_hex(Uint8List.fromList(pkt2.take(32).toList()))}');
  final resp2 = await tran.send(pkt2, timeout: const Duration(seconds: 15));
  out('');
  out('=== 原始回包 ${resp2.length} 字节 ===');
  out(_hex(resp2));
  out('');
  out('外壳前 16 字节: ${_hex(Uint8List.fromList(resp2.take(16).toList()))}');
  out('  magic = 0x${_hex(resp2.sublist(0, 4))}');
  out('  byte[4] = 0x${resp2[4].toRadixString(16).padLeft(2, '0')}');
  await tran.close();
}
