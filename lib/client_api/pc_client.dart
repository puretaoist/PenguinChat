/// L3 PC NTQQ 长连接客户端（SSO 收发地基，纯 Dart）。
///
/// 职责：TCP 分帧 + SSO 编解码 + 请求/响应（按 seq 匹配）+ 服务端推送流 + 心跳。
/// 上层（登录 / 拉列表 / 收发）都在此之上发命令。参照 Diana/mania 的 SSO 结构。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../kernel/wlogin8/pc/pc_sso.dart';
import '../kernel/wlogin8/pc/pc_sso_reserved.dart';

/// 会话凭据（登录后由 PCLogin/SsoInfoSync 得到）。
class PcSession {
  const PcSession({
    required this.uin,
    required this.uid,
    required this.a2,
    required this.d2,
    required this.d2Key,
    required this.guid,
  });
  final int uin;
  final String uid;
  final Uint8List a2;
  final Uint8List d2;
  final Uint8List d2Key;
  final Uint8List guid;

  PcSession copyWith({
    Uint8List? a2,
    Uint8List? d2,
    Uint8List? d2Key,
    String? uid,
  }) =>
      PcSession(
        uin: uin,
        uid: uid ?? this.uid,
        a2: a2 ?? this.a2,
        d2: d2 ?? this.d2,
        d2Key: d2Key ?? this.d2Key,
        guid: guid,
      );
}

/// PC NTQQ 长连接客户端。
class PcClient {
  PcClient({
    this.subAppId = 537391664,
    this.currentVersion = '3.2.34-53644',
    this.timeout = const Duration(seconds: 20),
  });

  final int subAppId;
  final String currentVersion;
  final Duration timeout;

  Socket? _socket;
  StreamSubscription<List<int>>? _sub;
  final BytesBuilder _buf = BytesBuilder();
  final Map<int, Completer<PcSsoResponse>> _pending = {};
  final StreamController<PcSsoResponse> _pushCtl =
      StreamController<PcSsoResponse>.broadcast();
  int _seq = 0x10000 + DateTime.now().millisecondsSinceEpoch % 0x10000;
  PcSession? _session;
  bool _connected = false;

  /// 服务端主动推送（seq 不匹配任何 in-flight 请求的包）。
  Stream<PcSsoResponse> get pushes => _pushCtl.stream;
  bool get isConnected => _connected;
  PcSession? get session => _session;

  /// 建立 TCP 连接（可断线重连时再次调用）。
  Future<void> connect(String host, int port,
      {required PcSession session}) async {
    await close();
    _session = session;
    final socket =
        await Socket.connect(host, port, timeout: const Duration(seconds: 15));
    _socket = socket;
    _connected = true;
    _sub = socket.listen(_onData,
        onError: (Object _) {}, onDone: _onDone, cancelOnError: false);
  }

  /// 发送请求并等待匹配 seq 的响应。simple=true 走 protocol13/None（如 Alive），
  /// 否则 protocol12/WithD2Key（带 d2/d2Key/a2 + ssoReserved.uid）。
  Future<PcSsoResponse> request(
    String command,
    Uint8List payload, {
    bool simple = false,
    Uint8List? ssoReserved,
    Duration? timeoutOverride,
  }) async {
    final s = _session;
    if (s == null) throw StateError('PcClient: 未设置会话');
    final seq = _seq++;
    final reserved = ssoReserved ??
        PcSsoReserved.encode(msgType: 32, uid: s.uid);
    final pkt = simple
        ? PcSso.buildRequest13(
            uin: s.uin,
            sequence: seq,
            command: command,
            payload: payload,
            encryptType: PcSsoEncryptType.none,
          )
        : PcSso.buildRequest12(
            uin: s.uin,
            sequence: seq,
            subAppId: subAppId,
            currentVersion: currentVersion,
            command: command,
            payload: payload,
            guid: s.guid,
            encryptType: PcSsoEncryptType.withD2Key,
            d2: s.d2,
            d2Key: s.d2Key,
            a2: s.a2,
            ssoReserved: reserved,
          );
    final c = Completer<PcSsoResponse>();
    _pending[seq] = c;
    _socket!.add(pkt);
    _socket!.flush();
    try {
      return await c.future.timeout(timeoutOverride ?? timeout);
    } finally {
      _pending.remove(seq);
    }
  }

  void _onData(List<int> chunk) {
    _buf.add(chunk);
    var d = _buf.toBytes();
    while (d.length >= 4) {
      final len = (d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3];
      if (len < 4 || d.length < len) break;
      final frame = Uint8List.fromList(d.sublist(4, len));
      d = d.length > len ? d.sublist(len) : Uint8List(0);
      _dispatch(frame);
    }
    _buf.clear();
    _buf.add(d);
  }

  void _dispatch(Uint8List frame) {
    final d2Key = _session?.d2Key ?? Uint8List(16);
    PcSsoResponse resp;
    try {
      resp = PcSso.parseResponse(frame, d2Key: d2Key);
    } catch (_) {
      return; // 解析失败（如推送为其它加密形态）先忽略，不崩连接
    }
    final p = _pending.remove(resp.sequence);
    if (p != null && !p.isCompleted) {
      p.complete(resp);
    } else {
      // 未匹配 = 服务端推送
      if (!_pushCtl.isClosed) _pushCtl.add(resp);
    }
  }

  void _onDone() {
    _connected = false;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('连接已关闭'));
      }
    }
    _pending.clear();
  }

  Future<void> close() async {
    _connected = false;
    await _sub?.cancel();
    _sub = null;
    await _socket?.close();
    _socket = null;
  }

  void dispose() {
    close();
    _pushCtl.close();
  }
}
