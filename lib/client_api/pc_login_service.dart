/// L3 客户端服务：PC NTLogin 扫码登录（纯 Dart，不依赖 Flutter）。
///
/// 链路（对齐 Diana / acidify 已验证流程）：
///   FetchQRCode(0x31, 带签名) → QueryQRCodeState(0x12, 轮询) → getFace
///   → CONFIRMED → PCLogin(wtlogin.login, 带签名) 换 a2/d2/d2Key
///   → SsoInfoSync 上线（WithD2Key + ssoReserved 带 uid）
///
/// 通过 [states] 广播阶段，供 UI 展示二维码与状态；签名由本机签名服务
/// （如 NTQQ-PureSignServer，`/sign`）提供。收发/会话层不在本服务范围。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../infra/coder.dart';
import '../infra/log/logger.dart';
import '../kernel/crypto/tea.dart';
import '../kernel/wlogin8/pc/pc_pc_login.dart';
import '../kernel/wlogin8/pc/pc_proto.dart';
import '../kernel/wlogin8/pc/pc_qr_login.dart';
import '../kernel/wlogin8/pc/pc_qr_tlv.dart';
import '../kernel/wlogin8/pc/pc_online.dart';
import '../kernel/wlogin8/pc/pc_register.dart';
import '../kernel/wlogin8/pc/pc_sign.dart';
import '../kernel/wlogin8/pc/pc_sso.dart';
import '../kernel/wlogin8/pc/pc_sso_reserved.dart';

/// PC 扫码登录阶段。
enum PcLoginStage {
  idle,
  connecting,
  qrReady, // 已拿到二维码，等待扫码
  waitingConfirm, // 已扫，等待手机确认
  loggingIn, // 已确认，正在 PCLogin / 上线
  online, // 登录 + 上线成功
  failed,
}

/// 一次登录状态快照。
class PcLoginSnapshot {
  const PcLoginSnapshot({
    required this.stage,
    this.qrUrl,
    this.qrImage,
    this.uin,
    this.error,
  });

  final PcLoginStage stage;
  final String? qrUrl;
  final Uint8List? qrImage; // 服务端返回的 0x17 PNG
  final int? uin;
  final String? error;

  static const idle = PcLoginSnapshot(stage: PcLoginStage.idle);
}

/// 登录成功后拿到的凭证。
class PcLoginCredentials {
  const PcLoginCredentials({
    required this.uin,
    required this.uid,
    required this.a2,
    required this.d2,
    required this.d2Key,
    required this.a1,
  });
  final int uin;
  final String uid;
  final Uint8List a2;
  final Uint8List d2;
  final Uint8List d2Key;
  final Uint8List a1; // encryptedA1
}

/// PC 扫码登录服务（纯 Dart）。
class PcLoginService {
  PcLoginService({
    this.host = 'msfwifi.3g.qq.com',
    this.port = 8080,
    this.signServer = '',
    required this.guid,
    this.deviceName = 'ubuntu-8a3f2c',
    this.pollInterval = const Duration(seconds: 3),
    this.signerOverride,
    this.pcDataDir,
  });

  /// 可注入的本地签名实现（如内嵌 flutter_qjs 跑 sign.js）。非空时优先于 HTTP 签名服务。
  final Future<PcSsoSecureInfo?> Function(String cmd, Uint8List body, int seq)?
      signerOverride;

  // ── 内置 AppInfo（Linux 3.2.34-53644，与签名服务 qua 一致）──
  static const int appId = 1600001615;
  static const int subAppId = 537391664;
  static const int appIdQrCode = 537391664;
  static const int mainSigMap = 169742560;
  static const int subSigMap = 0;
  static const int ssoVersion = 19;
  static const String packageName = 'com.tencent.qq';
  static const String ptVersion = '2.0.0';
  static const String currentVersion = '3.2.34-53644';
  static const String wtLoginSdk = 'nt.wtlogin.0.0.1';
  static const String os = 'Linux';
  static const String kernel = 'Linux';
  static const String vendorOs = 'linux';
  static const int appClientVersion = 53644;

  final String host;
  final int port;
  final String signServer;

  /// 持久化目录（存 session 凭证，用于启动时快速上线、免重复扫码）。
  final Directory? pcDataDir;
  final Uint8List guid;
  final String deviceName;
  final Duration pollInterval;

  final StreamController<PcLoginSnapshot> _ctrl =
      StreamController<PcLoginSnapshot>.broadcast();
  Stream<PcLoginSnapshot> get states => _ctrl.stream;

  PcLoginSnapshot _last = PcLoginSnapshot.idle;
  PcLoginSnapshot get last => _last;

  _PcConn? _conn;
  bool _cancelled = false;
  Timer? _aliveTimer;
  int _aliveTick = 0;
  bool _reconnecting = false;
  int _seqCounter = 0x10000 + DateTime.now().millisecondsSinceEpoch % 0x10000;
  PcLoginCredentials? credentials;

  void _emit(PcLoginSnapshot s) {
    _last = s;
    Log.get('PCLogin').i(
        'stage=${s.stage.name} uin=${s.uin} error=${s.error ?? ""}');
    if (!_ctrl.isClosed) _ctrl.add(s);
  }

  /// 开始扫码登录全流程（异步推进 [states]）。
  Future<void> startQrLogin() async {
    _cancelled = false;
    _emit(const PcLoginSnapshot(stage: PcLoginStage.connecting));
    try {
      final sock =
          await Socket.connect(host, port, timeout: const Duration(seconds: 15));
      final conn = _PcConn(sock);
      _conn = conn;

      final qr = await _fetchQrCode(conn);
      _emit(PcLoginSnapshot(
          stage: PcLoginStage.qrReady, qrUrl: qr.url, qrImage: qr.png));
      if (_cancelled) return;

      for (var i = 0; i < 120 && !_cancelled; i++) {
        await Future<void>.delayed(pollInterval);
        final st = await _queryState(conn, qr.qrSig);
        if (st.state == 53) {
          _emit(PcLoginSnapshot(stage: PcLoginStage.waitingConfirm));
          try {
            await _getFace(qr.qrString);
          } catch (_) {}
        } else if (st.state == 48) {
          // 仍在等待扫码
        }
        if (st.confirmed) {
          _emit(const PcLoginSnapshot(stage: PcLoginStage.loggingIn));
          final r = await _pcLogin(conn, st);
          final ok = await _goOnline(conn, st.uin!, r);
          if (!ok) {
            _emit(PcLoginSnapshot(
                stage: PcLoginStage.failed, error: '上线失败'));
            return;
          }
          credentials = PcLoginCredentials(
            uin: st.uin!,
            uid: r.uid,
            a2: r.a2,
            d2: r.d2,
            d2Key: r.d2Key,
            a1: r.encryptedA1,
          );
          _saveSession();
          _emit(PcLoginSnapshot(stage: PcLoginStage.online, uin: st.uin));
          _startKeepAlive();
          return;
        }
        if (st.state == 17 || st.state == 54) {
          _emit(PcLoginSnapshot(
              stage: PcLoginStage.failed,
              error: st.state == 17 ? '二维码已过期' : '用户取消了登录'));
          return;
        }
      }
      if (!_cancelled) {
        _emit(
            const PcLoginSnapshot(stage: PcLoginStage.failed, error: '二维码超时'));
      }
    } catch (e) {
      _emit(PcLoginSnapshot(stage: PcLoginStage.failed, error: '$e'));
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    _aliveTimer?.cancel();
    _aliveTimer = null;
    await _conn?.close();
    _conn = null;
  }

  void dispose() {
    cancel();
    _ctrl.close();
  }

  // ───── 内部实现 ─────

  Future<_Qr> _fetchQrCode(_PcConn conn) async {
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
    return _Qr(qrSig, url, qrStr, tlv[0x17]);
  }

  Future<PcQrStateResult> _queryState(_PcConn conn, Uint8List qrSig) async {
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

  Future<PcLoginResult> _pcLogin(_PcConn conn, PcQrStateResult st) async {
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

  Future<bool> _goOnline(_PcConn conn, int uin, PcLoginResult r) => _onlineWith(
      conn, uin,
      d2: r.d2, d2Key: r.d2Key, a2: r.a2, uid: r.uid);

  Future<bool> _onlineWith(_PcConn conn, int uin,
      {required Uint8List d2,
      required Uint8List d2Key,
      required Uint8List a2,
      required String uid}) async {
    final infoSync = PcRegister.buildSsoInfoSync(
      guidHex: _hexUpper(guid),
      currentVersion: currentVersion,
      deviceName: deviceName,
      kernel: kernel,
      systemKernel: 'Ubuntu 22.04.4 LTS', // osVer：真实发行版串（绝不能填内核名 "Linux"）
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
      d2: d2,
      d2Key: d2Key,
      a2: a2,
      ssoReserved: PcSsoReserved.encode(msgType: 32, uid: uid),
    );
    final resp = PcSso.parseResponse(await conn.sendRaw(pkt), d2Key: d2Key);
    if (resp.retCode != 0) return false;
    return PcRegister.parseSsoInfoSyncResponse(resp.payload)
        .contains('register success');
  }

  File? get _sessionFile {
    final dir = pcDataDir;
    if (dir == null) return null;
    return File(
        '${dir.path}${Platform.pathSeparator}pc${Platform.pathSeparator}session.json');
  }

  void _saveSession() {
    final c = credentials;
    final f = _sessionFile;
    if (c == null || f == null) return;
    try {
      if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({
        'uin': c.uin,
        'uid': c.uid,
        'a2': base64.encode(c.a2),
        'd2': base64.encode(c.d2),
        'd2Key': base64.encode(c.d2Key),
        'a1': base64.encode(c.a1),
      }));
      Log.get('PCLogin').i('session 已持久化 uin=${c.uin}');
    } catch (_) {}
  }

  /// 启动时用持久化 session 直接上线（不重扫码）。成功→online 并返回 true。
  Future<bool> tryResumeOnline() async {
    final f = _sessionFile;
    if (f == null || !f.existsSync()) return false;
    Map<String, dynamic> j;
    try {
      j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return false;
    }
    try {
      final uin = (j['uin'] as num).toInt();
      final uid = (j['uid'] ?? '') as String;
      final a2 = base64.decode(j['a2'] as String);
      final d2 = base64.decode(j['d2'] as String);
      final d2Key = base64.decode(j['d2Key'] as String);
      final a1 = base64.decode((j['a1'] ?? '') as String);
      Log.get('PCLogin').i('尝试复用 session 上线 uin=$uin');
      _emit(const PcLoginSnapshot(stage: PcLoginStage.connecting));
      final sock =
          await Socket.connect(host, port, timeout: const Duration(seconds: 15));
      final conn = _PcConn(sock);
      _conn = conn;
      final ok =
          await _onlineWith(conn, uin, d2: d2, d2Key: d2Key, a2: a2, uid: uid);
      if (!ok) {
        await conn.close();
        _conn = null;
        Log.get('PCLogin').w('复用 session 上线失败，需重新扫码');
        return false;
      }
      credentials = PcLoginCredentials(
          uin: uin, uid: uid, a2: a2, d2: d2, d2Key: d2Key, a1: a1);
      _emit(PcLoginSnapshot(stage: PcLoginStage.online, uin: uin));
      _startKeepAlive();
      return true;
    } catch (_) {
      return false;
    }
  }

  int _nextSeq() => _seqCounter++;

  void _startKeepAlive() {
    _aliveTimer?.cancel();
    _aliveTick = 0;
    _aliveTimer = Timer.periodic(const Duration(seconds: 10), (t) async {
      final conn = _conn;
      final c = credentials;
      if (conn == null || c == null) return;
      try {
        _aliveTick++;
        if (_aliveTick % 27 == 0) {
          await _sendHeartbeat(conn, c);
        } else {
          await _sendAlive(conn, c);
        }
      } catch (_) {
        _onDisconnected();
      }
    });
    _conn?.done.then((_) => _onDisconnected());
  }

  Future<void> _sendAlive(_PcConn conn, PcLoginCredentials c) async {
    final pkt = PcSso.buildRequest13(
      uin: c.uin,
      sequence: _nextSeq(),
      command: PcOnline.aliveCmd,
      payload: PcOnline.buildAlivePayload(),
      encryptType: PcSsoEncryptType.none,
    );
    await conn.sendRaw(pkt);
  }

  Future<void> _sendHeartbeat(_PcConn conn, PcLoginCredentials c) async {
    final pkt = PcSso.buildRequest12(
      uin: c.uin,
      sequence: _nextSeq(),
      subAppId: subAppId,
      currentVersion: currentVersion,
      command: PcOnline.heartbeatCmd,
      payload: PcOnline.buildHeartbeatPayload(),
      guid: guid,
      encryptType: PcSsoEncryptType.withD2Key,
      d2: c.d2,
      d2Key: c.d2Key,
      a2: c.a2,
      ssoReserved: PcSsoReserved.encode(msgType: 32, uid: c.uid),
    );
    await conn.sendRaw(pkt);
  }

  void _onDisconnected() {
    if (_reconnecting) return;
    final c = credentials;
    if (c == null) return;
    _aliveTimer?.cancel();
    _reconnect(c);
  }

  Future<void> _reconnect(PcLoginCredentials c) async {
    _reconnecting = true;
    Log.get('PCLogin').w('连接断开，尝试重连上线 uin=${c.uin}');
    for (var i = 0; i < 6; i++) {
      try {
        await _conn?.close();
        _conn = null;
        final sock = await Socket.connect(host, port,
            timeout: const Duration(seconds: 15));
        final conn = _PcConn(sock);
        _conn = conn;
        final ok = await _onlineWith(conn, c.uin,
            d2: c.d2, d2Key: c.d2Key, a2: c.a2, uid: c.uid);
        if (ok) {
          _emit(PcLoginSnapshot(stage: PcLoginStage.online, uin: c.uin));
          _reconnecting = false;
          _startKeepAlive();
          return;
        }
      } catch (_) {}
      await Future<void>.delayed(Duration(seconds: 3 * (i + 1)));
    }
    _reconnecting = false;
    _emit(const PcLoginSnapshot(
        stage: PcLoginStage.failed, error: '连接断开，重连失败'));
  }

  Future<void> _getFace(String qrCodeString) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req =
          await client.postUrl(Uri.parse('https://ntlogin.qq.com/qr/getFace'));
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(
          '{"appid":$appId,"faceUpdateTime":0,"qrsig":"$qrCodeString"}'));
      await (await req.close()).drain<void>();
    } finally {
      client.close();
    }
  }

  Future<PcSsoSecureInfo?> _signer(
      String cmd, Uint8List wtloginBody, int seq) async {
    Log.get('PCSign').d('sign cmd=$cmd bodyLen=${wtloginBody.length}');
    final o = signerOverride;
    if (o != null) return o(cmd, wtloginBody, seq);
    // 可选：外部签名服务（兼容 PC 本机调试；App 默认不用）
    if (signServer.isNotEmpty) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client.postUrl(Uri.parse(signServer));
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(
            {'cmd': cmd, 'src': _hexLower(wtloginBody), 'seq': seq})));
        final resp = await req.close();
        final text = await resp.transform(utf8.decoder).join();
        if (resp.statusCode != 200) return null;
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
    // 默认：纯 Dart 内置签名（无需外部服务/native）
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final rnd = Uint8List.fromList(List<int>.generate(16, (_) => Random().nextInt(256)));
    final r = PcSign.computeSign(
        body: wtloginBody, us: (nowMs % 1000) * 1000, rand16: rnd);
    Log.get('PCSign').d('signed cmd=$cmd signLen=${r.signHex.length ~/ 2}B');
    return PcSsoSecureInfo(
      sign: _unhex(r.signHex),
      token: Uint8List(0),
      extra: _unhex(r.extraHex),
    );
  }
}

class _Qr {
  const _Qr(this.qrSig, this.url, this.qrString, this.png);
  final Uint8List qrSig;
  final String url;
  final String qrString;
  final Uint8List? png;
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

/// PC 长连接封装（SSO 分帧）。
class _PcConn {
  _PcConn(this.socket) {
    _sub = socket.listen(_onData,
        onError: (Object _) => _markDone(),
        onDone: _markDone,
        cancelOnError: false);
  }
  final Socket socket;
  late final StreamSubscription<List<int>> _sub;
  final BytesBuilder _buf = BytesBuilder();
  final List<Completer<Uint8List>> _pending = [];
  final Completer<void> _done = Completer<void>();
  Future<void> get done => _done.future;
  void _markDone() {
    if (!_done.isCompleted) _done.complete();
    for (final c in _pending) {
      if (!c.isCompleted) c.completeError(StateError('连接已断开'));
    }
    _pending.clear();
  }

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

  Future<Uint8List> sendRaw(Uint8List packet) {
    final c = Completer<Uint8List>();
    _pending.add(c);
    socket.add(packet);
    socket.flush();
    return c.future.timeout(const Duration(seconds: 25));
  }

  Future<Uint8List> transWtLogin(Uint8List packet, Uint8List shareKey) async {
    final pkt = await sendRaw(packet);
    final resp = PcSso.parseResponse(pkt);
    if (!resp.ok) throw StateError('retCode=${resp.retCode} extra=${resp.extra}');
    final r = ByteReader(resp.payload);
    if (r.readUint8() != 0x02) throw StateError('wtlogin 头不是 0x02');
    r.read(15);
    final encrypted = r.read(r.remaining - 1);
    final decrypted = qqTeaDecrypt(encrypted, shareKey);
    if (r.readUint8() != 0x03) throw StateError('wtlogin 尾不是 0x03');
    return Uint8List.fromList(decrypted);
  }

  Future<Uint8List> transEmp(Uint8List packet, Uint8List shareKey) async {
    final decrypted = await transWtLogin(packet, shareKey);
    final w = ByteReader(decrypted);
    w.readUint32();
    w.read(4);
    w.readUint16();
    w.read(40);
    w.readUint32();
    return Uint8List.fromList(decrypted.sublist(w.pos));
  }

  Future<void> close() async {
    await _sub.cancel();
    await socket.close();
  }
}
