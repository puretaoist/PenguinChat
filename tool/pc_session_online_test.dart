// 用已有会话（Diana 登录后落盘的 session.json）验证纯 Dart 上线能力。
// 流程：连 msfwifi → 发 SsoInfoSync（WithD2Key 加密）→ 看 register message → Alive/Heartbeat。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/infra/coder.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_proto.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_register.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_sso.dart';

const host = 'msfwifi.3g.qq.com';
const port = 8080;
const subAppId = 537391664;
const currentVersion = '3.2.34-53644';
const kernel = 'Linux';
const systemKernel = 'Linux';
const vendorOs = 'linux';
const deviceName = 'DESKTOP-ACIDIFY';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty
      ? args[0]
      : r'C:/temp/diana/packages/app/.diana/session.json';
  final j = jsonDecode(File(path).readAsStringSync()) as Map;
  final uin = (j['uin'] as num).toInt();
  final uid = j['uid'] as String? ?? '';
  final guidHex = j['guid'] as String;
  final guid = _unhex(guidHex);
  final d2 = base64.decode(j['d2'] as String);
  final d2Key = base64.decode(j['d2Key'] as String);
  final a2 = base64.decode(j['a2'] as String);
  stdout.writeln('session: uin=$uin uid=$uid guid=$guidHex d2=${d2.length}B d2Key=${d2Key.length}B');

  final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 15));
  final conn = _Conn(socket);
  var seq = 0x10000 + DateTime.now().millisecondsSinceEpoch % 0x10000;
  try {
    // ① SsoInfoSync 上线
    final infoSync = PcRegister.buildSsoInfoSync(
      guidHex: guidHex,
      currentVersion: currentVersion,
      deviceName: deviceName,
      kernel: kernel,
      systemKernel: systemKernel,
      vendorOs: vendorOs,
    );
    final pkt = PcSso.buildRequest12(
      uin: uin,
      sequence: seq++,
      subAppId: subAppId,
      currentVersion: currentVersion,
      command: PcRegister.registerCommand,
      payload: infoSync,
      guid: guid,
      encryptType: PcSsoEncryptType.withD2Key,
      d2: d2,
      d2Key: d2Key,
      a2: a2,
    );
    final resp = PcSso.parseResponse(await conn.request(pkt), d2Key: d2Key);
    stdout.writeln('SsoInfoSync: retCode=${resp.retCode} extra=${resp.extra}');
    if (resp.retCode == 0) {
      final msg = PcRegister.parseSsoInfoSyncResponse(resp.payload);
      stdout.writeln('register message = "$msg"');
      stdout.writeln(msg.contains('register success') ? '✅ 上线成功' : '❌ 上线失败: $msg');
    }

    // ② Alive（protocol13 / None）
    final alivePkt = PcSso.buildRequest13(
      uin: uin,
      sequence: seq++,
      command: 'Heartbeat.Alive',
      payload: Uint8List.fromList(<int>[0, 0, 0, 4]),
      encryptType: PcSsoEncryptType.none,
    );
    final aliveResp = PcSso.parseResponse(await conn.request(alivePkt));
    stdout.writeln('Alive: retCode=${aliveResp.retCode}');

    // ③ Heartbeat（protocol12 / WithD2Key）
    final hbPkt = PcSso.buildRequest12(
      uin: uin,
      sequence: seq++,
      subAppId: subAppId,
      currentVersion: currentVersion,
      command: 'trpc.qq_new_tech.status_svc.StatusService.SsoHeartBeat',
      payload: PcRegister.buildHeartbeat(),
      guid: guid,
      encryptType: PcSsoEncryptType.withD2Key,
      d2: d2,
      d2Key: d2Key,
      a2: a2,
    );
    final hbResp = PcSso.parseResponse(await conn.request(hbPkt), d2Key: d2Key);
    stdout.writeln('Heartbeat: retCode=${hbResp.retCode}');
  } finally {
    await conn.close();
  }
  exit(0);
}

Uint8List _unhex(String s) {
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
