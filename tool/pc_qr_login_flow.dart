// 扫码登录全流程 + PCLogin + 长连接上线（真机用）。
//
// 链路：FetchQRCode(0x31) → QueryQRCodeState(0x12) → getFace → CONFIRMED
//       → PCLogin(wtlogin.login,2064) 换 A2/D2/d2Key
//       → Register 上线 → 心跳(Alive 10s / Heartbeat 270s) → Ctrl+C 时 UnRegister。
//
// 票据/凭证落盘在项目本地 ./tmp/。
// ⚠️ 真机运行：单次扫码即可，切忌高频重试（触发风控）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:penguinchat/infra/coder.dart';
import 'package:penguinchat/kernel/crypto/tea.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_online.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_pc_login.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_proto.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_register.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_qr_login.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_qr_tlv.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_sso.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_sso_reserved.dart';

const appId = 1600001615;
const subAppId = 537391664;
const appIdQrCode = 537391664;
const mainSigMap = 169742560;
const subSigMap = 0;
const ssoVersion = 19;
const packageName = 'com.tencent.qq';
const ptVersion = '2.0.0';
const currentVersion = '3.2.34-53644';
const wtLoginSdk = 'nt.wtlogin.0.0.1';
const os = 'Linux';
const kernel = 'Linux';
const vendorOs = 'linux';
const deviceName = 'DESKTOP-ACIDIFY';
const appClientVersion = 53644;
/// 本机 JS 签名服务（NTQQ-PureSignServer 的 sign.js 封装）。
const signServer = 'http://127.0.0.1:8099/sign';
const host = 'msfwifi.3g.qq.com';
const port = 8080;

final _tmpDir = () {
  final d = Directory('tmp');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d.path;
}();

/// 设备 guid：优先读项目本地持久化文件 `tmp/device_guid.bin`（真实客户端 guid 是固定的），
/// 没有则随机生成并保存；也支持 `PC_GUID_HEX`（32 hex）环境变量覆盖。
/// 不再用固定假 guid（0x20+i 序列），避免同一伪造指纹反复扫码触发风控。
final guid = _loadOrCreateGuid();

Uint8List _loadOrCreateGuid() {
  final f = File('$_tmpDir/device_guid.bin');
  if (f.existsSync()) {
    final b = f.readAsBytesSync();
    if (b.length == 16) return Uint8List.fromList(b);
  }
  final env = Platform.environment['PC_GUID_HEX'];
  if (env != null && env.length == 32) {
    final g = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      g[i] = int.parse(env.substring(i * 2, i * 2 + 2), radix: 16);
    }
    f.writeAsBytesSync(g);
    return g;
  }
  final r = Random.secure();
  final g = Uint8List.fromList(List<int>.generate(16, (_) => r.nextInt(256)));
  f.writeAsBytesSync(g);
  return g;
}

Future<void> main() async {
  stdout.writeln('连接 $host:$port ...');
  final socket = await Socket.connect(host, port,
      timeout: const Duration(seconds: 15));
  final conn = _Conn(socket);
  _Online? online;
  try {
    final qr = await _fetchQrCode(conn);
    File('$_tmpDir/qq_url.txt').writeAsStringSync(qr.url);
    stdout.writeln('=== 二维码已生成 ===');
    stdout.writeln('扫码 URL: ${qr.url}');
    stdout.writeln('请用手机 QQ 扫描并点「确认登录」...');
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      final st = await _queryState(conn, qr.qrSig);
      stdout.writeln('[${i * 3}s] ${st.stateName}');
      if (st.state == 53) {
        try {
          await _getFace(appId, qr.qrString);
        } catch (e) {
          stdout.writeln('  getFace 失败: $e');
        }
      }
      if (st.confirmed) {
        stdout.writeln('=== 确认成功 ===');
        stdout.writeln('uin=${st.uin} tgtgt=${st.tgtgt?.length}B '
            'encryptedA1=${st.encryptedA1?.length}B noPicSig=${st.noPicSig?.length}B');
        File('$_tmpDir/qr_tickets.txt').writeAsStringSync(
            'uin=${st.uin}\ntgtgt=${base64.encode(st.tgtgt!)}\n'
            'encryptedA1=${base64.encode(st.encryptedA1!)}\n'
            'noPicSig=${base64.encode(st.noPicSig!)}');

        // ★ PCLogin 换完整凭证
        final r = await _pcLogin(conn, st);
        stdout.writeln('=== PCLogin 成功 ===');
        stdout.writeln('uid=${r.uid} a2=${r.a2.length}B '
            'd2=${r.d2.length}B d2Key=${r.d2Key.length}B encryptedA1=${r.encryptedA1.length}B');
        File('$_tmpDir/pc_credentials.txt').writeAsStringSync(
            'uin=${st.uin}\nuid=${r.uid}\n'
            'a2=${base64.encode(r.a2)}\nd2=${base64.encode(r.d2)}\n'
            'd2Key=${base64.encode(r.d2Key)}\nencryptedA1=${base64.encode(r.encryptedA1)}');

        // ★ 长连接上线（Register + 心跳）
        online = await _goOnline(conn, st.uin!, r, r.uid);
        stdout.writeln('=== 已上线，心跳 10s/次（270s 补 Heartbeat），Ctrl+C 退出 ===');
        await Completer<void>().future; // 保持在线，直到进程被中断
        return;
      }
      if (st.state == 17 || st.state == 54) {
        stdout.writeln('二维码过期/已取消');
        exit(2);
      }
    }
    exit(3);
  } finally {
    if (online != null) {
      try {
        await online.offline();
      } catch (_) {}
    }
    await conn.close();
  }
}

/// PCLogin：用扫码票据换 A2/D2/d2Key。
Future<PcLoginResult> _pcLogin(_Conn conn, PcQrStateResult st) async {
  final req = await PcPcLogin.build(
    appId: appId,
    subAppId: subAppId,
    appClientVersion: appClientVersion,
    mainSigMap: mainSigMap,
    subSigMap: subSigMap,
    uin: st.uin!,
    guid: guid,
    tgtgt: st.tgtgt!,
    encryptedA1: st.encryptedA1!,
    noPicSig: st.noPicSig!,
    packageName: packageName,
    ptVersion: ptVersion,
    os: os,
    deviceName: deviceName,
    wtLoginSdk: wtLoginSdk,
    currentVersion: currentVersion,
    signer: _signer,
  );
  final decrypted = await conn.transWtLogin(req.packet, req.shareKey);
  return PcPcLogin.parse(decrypted, st.tgtgt!);
}

/// 上线（SsoInfoSync，WithD2Key + ssoReserved 带 uid），成功后起心跳。
Future<_Online?> _goOnline(
    _Conn conn, int uin, PcLoginResult r, String uid) async {
  final infoSync = PcRegister.buildSsoInfoSync(
    guidHex: _hexUpper(guid),
    currentVersion: currentVersion,
    deviceName: deviceName,
    kernel: kernel,
    systemKernel: kernel,
    vendorOs: vendorOs,
  );
  final seq = 0x10000 + DateTime.now().millisecondsSinceEpoch % 0x10000;
  final pkt = PcSso.buildRequest12(
    uin: uin,
    sequence: seq,
    subAppId: subAppId,
    currentVersion: currentVersion,
    command: PcRegister.registerCommand,
    payload: infoSync,
    guid: guid,
    encryptType: PcSsoEncryptType.withD2Key,
    d2: r.d2,
    d2Key: r.d2Key,
    a2: r.a2,
    ssoReserved: PcSsoReserved.encode(msgType: 32, uid: uid),
  );
  final resp = PcSso.parseResponse(await conn.sendRaw(pkt), d2Key: r.d2Key);
  stdout.writeln('SsoInfoSync: retCode=${resp.retCode} extra=${resp.extra}');
  if (resp.retCode != 0) return null;
  final msg = PcRegister.parseSsoInfoSyncResponse(resp.payload);
  stdout.writeln('register message = "$msg"');
  if (!msg.contains('register success')) return null;
  final online = _Online(conn, uin, r, uid);
  online.startHeartbeat();
  return online;
}

/// 在线会话：心跳（Alive 10s / Heartbeat 270s）+ 下线 UnRegister。
class _Online {
  _Online(this.conn, this.uin, this.r, this.uid);
  final _Conn conn;
  final int uin;
  final PcLoginResult r;
  final String uid;
  Timer? _timer;
  final PcHeartbeatScheduler _sched = PcHeartbeatScheduler();
  int _seq = 0x10000 + DateTime.now().millisecondsSinceEpoch % 0x10000;

  void startHeartbeat() {
    _timer ??= Timer.periodic(
        const Duration(seconds: PcHeartbeatScheduler.aliveIntervalSeconds),
        (_) => _tick());
  }

  Future<void> _tick() async {
    for (final cmd in _sched.nextTick()) {
      try {
        if (cmd == PcOnline.aliveCmd) {
          await _send(cmd, PcOnline.buildAlivePayload(), simple: true);
        } else {
          await _send(cmd, PcOnline.buildHeartbeatPayload(), simple: false);
        }
      } catch (_) {}
    }
  }

  Future<PcSsoResponse> _send(String command, Uint8List payload,
      {required bool simple}) async {
    final seq = _seq++;
    final pkt = simple
        ? PcSso.buildRequest13(
            uin: uin,
            sequence: seq,
            command: command,
            payload: payload,
            encryptType: PcSsoEncryptType.none,
          )
        : PcSso.buildRequest12(
            uin: uin,
            sequence: seq,
            subAppId: subAppId,
            currentVersion: currentVersion,
            command: command,
            payload: payload,
            guid: guid,
            encryptType: PcSsoEncryptType.withD2Key,
            d2: r.d2,
            d2Key: r.d2Key,
            a2: r.a2,
            ssoReserved: PcSsoReserved.encode(msgType: 32, uid: uid),
          );
    return PcSso.parseResponse(await conn.sendRaw(pkt), d2Key: r.d2Key);
  }

  Future<void> offline() async {
    _timer?.cancel();
    _timer = null;
    try {
      final pkt = PcSso.buildRequest12(
        uin: uin,
        sequence: _seq++,
        subAppId: subAppId,
        currentVersion: currentVersion,
        command: PcRegister.unregisterCommand,
        payload: PcRegister.buildUnRegister(
          deviceName: deviceName,
          kernel: kernel,
          systemKernel: kernel,
          vendorOs: vendorOs,
        ),
        guid: guid,
        encryptType: PcSsoEncryptType.withD2Key,
        d2: r.d2,
        d2Key: r.d2Key,
        a2: r.a2,
        ssoReserved: PcSsoReserved.encode(msgType: 32, uid: uid),
      );
      await conn.sendRaw(pkt);
    } catch (_) {}
  }
}

String _hexUpper(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

String _hexLower(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String s) {
  if (s.isEmpty) return Uint8List(0);
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// 给 wtlogin 包算签名：POST 本机签名服务 {cmd,src(hex),seq} → {value:{sign,token,extra}}。
Future<PcSsoSecureInfo?> _signer(
    String cmd, Uint8List wtloginBody, int seq) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.postUrl(Uri.parse(signServer));
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode(
        {'cmd': cmd, 'src': _hexLower(wtloginBody), 'seq': seq})));
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      throw StateError('签名服务返回 ${resp.statusCode}: $text');
    }
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

Future<void> _getFace(int appId, String qrCodeString) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  try {
    final req =
        await client.postUrl(Uri.parse('https://ntlogin.qq.com/qr/getFace'));
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(
        '{"appid":$appId,"faceUpdateTime":0,"qrsig":"$qrCodeString"}'));
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    stdout.writeln('  getFace(${resp.statusCode}) -> $text');
  } finally {
    client.close();
  }
}

class _Qr {
  const _Qr(this.qrSig, this.url, this.qrString);
  final Uint8List qrSig;
  final String url;
  final String qrString;
}

Future<_Qr> _fetchQrCode(_Conn conn) async {
  final body = PcWtLogin.buildFetchQrCodeBody(
    appId: appId,
    subAppId: subAppId,
    appIdQrCode: appIdQrCode,
    mainSigMap: mainSigMap,
    ssoVersion: ssoVersion,
    packageName: packageName,
    ptVersion: ptVersion,
    os: os,
    deviceName: deviceName,
    guid: guid,
  );
  final req = await PcWtLogin.buildTransEmp(
    transEmpSubCmd: 0x31,
    appId: appId,
    subAppId: subAppId,
    appClientVersion: appClientVersion,
    uin: 0,
    tlvPack: body,
    guid: guid,
    currentVersion: currentVersion,
    signer: _signer,
  );
  final code2d = await conn.transEmp(req.packet, req.shareKey);
  final r = ByteReader(code2d);
  r.readUint8();
  final qrSig = r.readBytesWithLen16();
  final tlv = pcReadTlv(Uint8List.fromList(code2d.sublist(r.pos)));
  final d1 = tlv[0xD1];
  var url = '';
  var qrStr = '';
  if (d1 != null) {
    final p = PbReader(d1);
    while (!p.atEnd) {
      final (f, w) = p.readTag();
      if (f == 2) {
        url = p.readString();
      } else if (f == 3) {
        qrStr = p.readString();
      } else {
        p.skip(w);
      }
    }
  }
  return _Qr(qrSig, url, qrStr);
}

Future<PcQrStateResult> _queryState(_Conn conn, Uint8List qrSig) async {
  final body = pcBuildQueryStateBody(appId: appId, qrSig: qrSig);
  final req = await PcWtLogin.buildTransEmp(
    transEmpSubCmd: 0x12,
    appId: appId,
    subAppId: subAppId,
    appClientVersion: appClientVersion,
    uin: 0,
    tlvPack: body,
    guid: guid,
    currentVersion: currentVersion,
    signer: _signer,
  );
  final code2d = await conn.transEmp(req.packet, req.shareKey);
  return pcParseQueryState(code2d);
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
      if (_pending.isNotEmpty) {
        _pending.removeAt(0).complete(frame);
      }
    }
    _buf.clear();
    _buf.add(d);
  }

  Future<Uint8List> _request(Uint8List packet) {
    final c = Completer<Uint8List>();
    _pending.add(c);
    socket.add(packet);
    socket.flush();
    return c.future.timeout(const Duration(seconds: 25));
  }

  /// 直接发送原始 SSO 包并返回响应帧（长连接/通用请求用）。
  Future<Uint8List> sendRaw(Uint8List packet) => _request(packet);

  /// 发送任意 wtlogin(2064/2066) 包，解出内层 wtLogin 明文（已去 0x02 头/TEA/0x03 尾）。
  Future<Uint8List> transWtLogin(Uint8List packet, Uint8List shareKey) async {
    final pkt = await _request(packet);
    final resp = PcSso.parseResponse(pkt);
    if (!resp.ok) {
      throw StateError('retCode=${resp.retCode} extra=${resp.extra}');
    }
    final r = ByteReader(resp.payload);
    if (r.readUint8() != 0x02) throw StateError('wtlogin 头不是 0x02');
    r.read(15);
    final encrypted = r.read(r.remaining - 1);
    final decrypted = qqTeaDecrypt(encrypted, shareKey);
    if (r.readUint8() != 0x03) throw StateError('wtlogin 尾不是 0x03');
    return Uint8List.fromList(decrypted);
  }

  /// trans_emp 专用：在 wtLogin 明文基础上再跳 code2D 头，返回 code2D body。
  Future<Uint8List> transEmp(Uint8List packet, Uint8List shareKey) async {
    final decrypted = await transWtLogin(packet, shareKey);
    final w = ByteReader(decrypted);
    w.readUint32(); // packetLength
    w.read(4);
    w.readUint16(); // command
    w.read(40);
    w.readUint32(); // appid
    return Uint8List.fromList(decrypted.sublist(w.pos));
  }

  Future<void> close() async {
    await _sub.cancel();
    await socket.close();
  }
}
