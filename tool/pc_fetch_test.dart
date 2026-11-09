// 真机：用 session 的 a1 走 EasyLogin 续期 → 上线 → 拉好友/群（验证 M2.2 真机链路）。
// 需要：本机签名服务(8099)可达 + 一个有效 a1（如 Diana 登录后落盘的 session.json）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/kernel/wlogin8/pc/pc_friend.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_group.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_key_exchange.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_nt_login.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_oidb.dart';
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
  stdout.writeln('session: uin=$uin guid=$guidHex a1=${a1.length}B');

  final socket =
      await Socket.connect(host, port, timeout: const Duration(seconds: 15));
  final conn = _Conn(socket);
  var seq = 0x10000 + DateTime.now().millisecondsSinceEpoch % 0x10000;
  try {
    // ① KeyExchange → sessionTicket/sessionKey
    final kx = PcKeyExchange.build(uin: '$uin', guid: guid);
    final kxResp = await _sendSigned(conn, uin, seq++, keyExchangeCmd, kx.bytes, guid);
    final kxR = PcKeyExchange.parse(response: kxResp.payload, keyPair: kx.keyPair);
    stdout.writeln('KeyExchange OK: sessionKey=${kxR.sessionKey.length}B ticket=${kxR.sessionTicket.length}B');

    // ② EasyLogin(a1) → 新票据
    final elPayload = PcNtLogin.buildEasyLoginPayload(
      sessionTicket: kxR.sessionTicket,
      sessionKey: kxR.sessionKey,
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
    final elResp = await _sendSigned(conn, uin, seq++, easyLoginCmd, elPayload, guid);
    final el = PcNtLogin.parseEasyLoginResponse(elResp.payload, kxR.sessionKey);
    stdout.writeln('EasyLogin: ${el.status} err=${el.errCode} ${el.errTag} ${el.errMsg}');
    if (el.status != PcNtLoginStatus.success) {
      stdout.writeln('❌ EasyLogin 未成功，停止');
      return;
    }
    final d2 = el.d2, d2Key = el.d2Key, a2 = el.a2;
    final uidStr = (j['uid'] as String?) ?? '';

    // ③ 上线 SsoInfoSync
    final infoSync = PcRegister.buildSsoInfoSync(
      guidHex: guidHex,
      currentVersion: currentVersion,
      deviceName: deviceName,
      kernel: kernel,
      systemKernel: kernel,
      vendorOs: vendorOs,
    );
    final upResp = await _sendD2(conn, uin, seq++, PcRegister.registerCommand, infoSync,
        guid, d2, d2Key, a2, uidStr);
    final upOidb = PcSso.parseResponse(upResp, d2Key: d2Key);
    final upMsg = PcRegister.parseSsoInfoSyncResponse(upOidb.payload);
    stdout.writeln('上线: retCode=${upOidb.retCode} msg="$upMsg"');
    if (!upMsg.contains('register success')) {
      stdout.writeln('❌ 上线失败');
      return;
    }

    // ④ 拉好友（OIDB 0xfd4_1）
    final friendReq = PcOidb.build(
        command: PcFriendService.command, service: PcFriendService.service,
        body: PcFriendService.buildIncPull());
    final frResp = await _sendRawD2(conn, uin, seq++, PcFriendService.cmd, friendReq, guid, d2, d2Key, a2, uidStr);
    final frSso = PcSso.parseResponse(frResp, d2Key: d2Key);
    final frOidb = PcOidb.parse(frSso.payload);
    stdout.writeln('拉好友: oidbResult=${frOidb.result} msg="${frOidb.message}" bodyLen=${frOidb.body.length}');
    if (frOidb.body.isNotEmpty) {
      final n = frOidb.body.length < 32 ? frOidb.body.length : 32;
      stdout.writeln('   body[0..$n]=${_hex(frOidb.body.sublist(0, n))}');
    }
    if (frOidb.ok) {
      final friends = PcFriendService.parseIncPullResp(frOidb.body);
      stdout.writeln('   好友数=${friends.length}');
      for (final f in friends.take(5)) {
        stdout.writeln('   - ${f.uin} ${f.nickname} (${f.remark})');
      }
    }

    // ⑤ 拉群（OIDB 0xfe5_2）
    final groupReq = PcOidb.build(
        command: PcGroupService.command, service: PcGroupService.service,
        body: PcGroupService.buildFetchGroupsReq());
    final grResp = await _sendRawD2(conn, uin, seq++, PcGroupService.cmd, groupReq, guid, d2, d2Key, a2, uidStr);
    final grSso = PcSso.parseResponse(grResp, d2Key: d2Key);
    final gl = grSso.payload.length;
    final gh = gl < 48 ? gl : 48;
    stdout.writeln('拉群 SSO: retCode=${grSso.retCode} payloadLen=$gl hex=${_hex(grSso.payload.sublist(0, gh))}');
    try {
      final grOidb = PcOidb.parse(grSso.payload);
      stdout.writeln('拉群: oidbResult=${grOidb.result} msg="${grOidb.message}" bodyLen=${grOidb.body.length}');
      if (grOidb.ok) {
        final groups = PcGroupService.parseFetchGroupsResp(grOidb.body);
        stdout.writeln('   群数=${groups.length}');
        for (final g in groups.take(5)) {
          stdout.writeln('   - ${g.uin} ${g.name} (${g.memberCount}/${g.capacity})');
        }
      }
    } catch (e) {
      stdout.writeln('群解析失败: $e');
    }
  } finally {
    await conn.close();
  }
  exit(0);
}

Future<PcSsoResponse> _sendSigned(
    _Conn conn, int uin, int seq, String cmd, Uint8List body, Uint8List guid) async {
  final sec = await _signer(cmd, body, seq);
  final reserved = PcSsoReserved.encode(msgType: 32, secureInfo: sec);
  final pkt = PcSso.buildRequest12(
      uin: uin, sequence: seq, subAppId: subAppId, currentVersion: currentVersion,
      command: cmd, payload: body, guid: guid,
      encryptType: PcSsoEncryptType.withEmptyKey, ssoReserved: reserved);
  return PcSso.parseResponse(await conn.request(pkt));
}

Future<Uint8List> _sendD2(_Conn conn, int uin, int seq, String cmd, Uint8List body,
    Uint8List guid, Uint8List d2, Uint8List d2Key, Uint8List a2, String uid) async {
  final pkt = PcSso.buildRequest12(
      uin: uin, sequence: seq, subAppId: subAppId, currentVersion: currentVersion,
      command: cmd, payload: body, guid: guid,
      encryptType: PcSsoEncryptType.withD2Key, d2: d2, d2Key: d2Key, a2: a2,
      ssoReserved: PcSsoReserved.encode(msgType: 32, uid: uid));
  return conn.request(pkt);
}

Future<Uint8List> _sendRawD2(_Conn conn, int uin, int seq, String cmd,
    Uint8List oidbBody, Uint8List guid, Uint8List d2, Uint8List d2Key, Uint8List a2,
    String uid) async {
  // 对 OIDB：body 已是「Oidb 外层」字节
  final pkt = PcSso.buildRequest12(
      uin: uin, sequence: seq, subAppId: subAppId, currentVersion: currentVersion,
      command: cmd, payload: oidbBody, guid: guid,
      encryptType: PcSsoEncryptType.withD2Key, d2: d2, d2Key: d2Key, a2: a2,
      ssoReserved: PcSsoReserved.encode(msgType: 32, uid: uid));
  return conn.request(pkt);
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
    return c.future.timeout(const Duration(seconds: 25));
  }

  Future<void> close() async {
    await _sub.cancel();
    await socket.close();
  }
}
