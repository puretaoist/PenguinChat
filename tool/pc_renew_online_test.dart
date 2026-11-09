// 用 session 的 a1 走 EasyLogin 免密续期 → 换新票据 → SsoInfoSync 上线。
// 验证纯 Dart：KeyExchange + EasyLogin + 上线 全链（不需要扫码）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/infra/coder.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_key_exchange.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_nt_login.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_proto.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_register.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_sso.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_sso_reserved.dart';

const host = 'msfwifi.3g.qq.com';
const port = 8080;
const subAppId = 537391664;
const appId = 1600001615;
const currentVersion = '3.2.34-53644';
const packageName = 'com.tencent.qq';
const kernel = 'Linux';
const systemKernel = 'Linux';
const vendorOs = 'linux';
const deviceName = 'DESKTOP-ACIDIFY';
const signServer = 'http://127.0.0.1:8099/sign';

const keyExchangeCmd = 'trpc.login.ecdh.EcdhService.SsoKeyExchange';
const easyLoginCmd = 'trpc.login.ecdh.EcdhService.SsoNTLoginEasyLogin';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty
      ? args[0]
      : r'C:/temp/diana/packages/app/.diana/session.json';
  final j = jsonDecode(File(path).readAsStringSync()) as Map;
  final uin = (j['uin'] as num).toInt();
  final guidHex = j['guid'] as String;
  final guid = _unhex(guidHex);
  final a1 = base64.decode(j['a1'] as String);
  final uid = j['uid'] as String? ?? '';
  stdout.writeln('session: uin=$uin guid=$guidHex a1=${a1.length}B');

  final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 15));
  final conn = _Conn(socket);
  var seq = 0x10000 + DateTime.now().millisecondsSinceEpoch % 0x10000;
  try {
    // ① KeyExchange → sessionTicket / sessionKey
    final kx = PcKeyExchange.build(uin: '$uin', guid: guid);
    final kxResp = await _sendSigned(conn, uin, seq++, keyExchangeCmd, kx.bytes, guid, uid);
    final kxResult = PcKeyExchange.parse(response: kxResp.payload, keyPair: kx.keyPair);
    stdout.writeln('KeyExchange: sessionKey=${kxResult.sessionKey.length}B ticket=${kxResult.sessionTicket.length}B');

    // ② EasyLogin（用 a1）→ 新票据
    final elPayload = PcNtLogin.buildEasyLoginPayload(
      sessionTicket: kxResult.sessionTicket,
      sessionKey: kxResult.sessionKey,
      encryptedA1: a1,
      account: '$uin',
      os: kernel,
      kernel: kernel,
      deviceName: deviceName,
      appId: appId,
      packageName: packageName,
      currentVersion: currentVersion,
      guid: guid,
    );
    final elResp = await _sendSigned(conn, uin, seq++, easyLoginCmd, elPayload, guid, uid);
    final el = PcNtLogin.parseEasyLoginResponse(elResp.payload, kxResult.sessionKey);
    stdout.writeln('EasyLogin: status=${el.status} errCode=${el.errCode} ${el.errTag} ${el.errMsg}');
    if (el.status != PcNtLoginStatus.success) {
      stdout.writeln('❌ EasyLogin 未成功，停止');
      return;
    }
    final d2 = el.d2, d2Key = el.d2Key, a2 = el.a2;
    stdout.writeln('新票据: a2=${a2.length}B d2=${d2.length}B d2Key=${d2Key.length}B');

    // ③ SsoInfoSync 上线（WithD2Key）
    final infoSync = PcRegister.buildSsoInfoSync(
      guidHex: guidHex,
      currentVersion: currentVersion,
      deviceName: deviceName,
      kernel: kernel,
      systemKernel: systemKernel,
      vendorOs: vendorOs,
    );
    final pkt = PcSso.buildRequest12(
      uin: uin, sequence: seq++, subAppId: subAppId, currentVersion: currentVersion,
      command: PcRegister.registerCommand, payload: infoSync, guid: guid,
      encryptType: PcSsoEncryptType.withD2Key, d2: d2, d2Key: d2Key, a2: a2,
      ssoReserved: PcSsoReserved.encode(msgType: 32, uid: uid),
    );
    final resp = PcSso.parseResponse(await conn.request(pkt), d2Key: d2Key);
    stdout.writeln('SsoInfoSync: retCode=${resp.retCode} extra=${resp.extra}');
    if (resp.retCode == 0) {
      final msg = PcRegister.parseSsoInfoSyncResponse(resp.payload);
      stdout.writeln('register message = "$msg"');
      stdout.writeln(msg.contains('register success') ? '✅ 续期+上线 成功' : '❌ 上线失败: $msg');
    }

    // ④ Alive 保活
    final alivePkt = PcSso.buildRequest13(
      uin: uin, sequence: seq++, command: 'Heartbeat.Alive',
      payload: Uint8List.fromList(<int>[0, 0, 0, 4]), encryptType: PcSsoEncryptType.none,
    );
    try {
      final ar = PcSso.parseResponse(await conn.request(alivePkt));
      stdout.writeln('Alive: retCode=${ar.retCode}');
    } catch (e) {
      stdout.writeln('Alive: 解析告警(不影响上线) $e');
    }
  } finally {
    await conn.close();
  }
  exit(0);
}

Future<PcSsoResponse> _sendSigned(
    _Conn conn, int uin, int seq, String cmd, Uint8List body, Uint8List guid,
    String uid) async {
  final sec = await _signer(cmd, body, seq);
  final reserved = PcSsoReserved.encode(msgType: 32, uid: uid, secureInfo: sec);
  final pkt = PcSso.buildRequest12(
    uin: uin, sequence: seq, subAppId: subAppId, currentVersion: currentVersion,
    command: cmd, payload: body, guid: guid,
    encryptType: PcSsoEncryptType.withEmptyKey, ssoReserved: reserved,
  );
  return PcSso.parseResponse(await conn.request(pkt));
}

Future<PcSsoSecureInfo> _signer(String cmd, Uint8List body, int seq) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.postUrl(Uri.parse(signServer));
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode({'cmd': cmd, 'src': _hex(body), 'seq': seq})));
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    final m = (jsonDecode(text) as Map)['value'] as Map;
    return PcSsoSecureInfo(
      sign: _unhex((m['sign'] ?? '') as String),
      token: _unhex((m['token'] ?? '') as String),
      extra: _unhex((m['extra'] ?? '') as String),
    );
  } finally {
    client.close();
  }
}

String _hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List _unhex(String s) {
  if (s.isEmpty) return Uint8List(0);
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

class _Conn {
  _Conn(this.socket) {
    _sub = socket.listen(_onData, onError: (Object _) {}, cancelOnError: false);
  }
  final Socket socket;
  late final StreamSubscription<List<int>> _sub;
  final BytesBuilder _buf = BytesBuilder();
  final List<Completer<Uint8List>> _pending = [];

  void _onData(List<int> chunk) {
    _buf.add(chunk);
    var d = _buf.toBytes();
    while (d.length >= 4) {
      final len = (d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3];
      if (len < 4 || d.length < len) break;
      final frame = Uint8List.fromList(d.sublist(4, len));
      d = d.length > len ? d.sublist(len) : Uint8List(0);
      if (_pending.isNotEmpty) _pending.removeAt(0).complete(frame);
    }
    _buf.clear();
    _buf.add(d);
  }

  Future<Uint8List> request(Uint8List packet) {
    final c = Completer<Uint8List>();
    _pending.add(c);
    socket.add(packet);
    socket.flush();
    return c.future.timeout(const Duration(seconds: 20));
  }

  Future<void> close() async {
    await _sub.cancel();
    await socket.close();
  }
}
