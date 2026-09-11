/// L2 协议内核：QQ 登录的 TCP 传输层
///
/// ## 分帧格式
///
/// 官方客户端在 TCP 上用的是**4 字节大端长度前缀**，且**长度包含它自己**：
///
/// ```text
///   +--------+---------------------------+
///   | u32    | payload                   |
///   | total  | total - 4 字节             |
///   +--------+---------------------------+
///   total = 4 + payload.length
/// ```
///
/// 来源：参考实现 `takayama-lily/oicq` 的 `lib/client-net.js`：
///
/// ```js
/// this.on("data", (data) => {
///     this._data = Buffer.concat([this._data, data]);
///     while (this._data.length > 4) {
///         let len = this._data.readUInt32BE();      // ← 4 字节大端
///         if (this._data.length >= len) {
///             const packet = this._data.slice(4, len);   // ← 去掉 4 字节头
///             this._data = this._data.slice(len);
///             this.c.emit("internal.packet", packet);
///         } else break;                              // ← 不完整就等下一批
///     }
/// });
/// ```
///
/// ⚠️ 注意这与 OICQ 信封自己的 `0x02` + u16 头是**两层**，不要混。
///
/// ## 谁负责这个 u32（踩过坑）
///
/// **发送侧：调用方给的必须是"完整线上包"** —— 登录包自带这个 u32
/// （`Qq8Sso.buildLoginPacket` 返回值的第一个字段就是自己的总长），
/// 传输层**原样写出、不再加任何前缀**。对应 oicq 的发送路径
/// （`lib/core/base-client.ts` 的 `FN_SEND`；`Network extends net.Socket`，
/// `write` 就是字节原样）：
///
/// ```ts
/// private [FN_SEND](pkt: Uint8Array, timeout = 5) { … this[NET].write(pkt, …) … }
/// ```
///
/// **接收侧：解码器把这个 u32 剥掉**，交给上层的 payload 不含帧头。
///
/// ⚠️ 血泪注记：发送侧曾画蛇添足地又 `framePacket()` 了一次 →
/// 线上多 4 字节，服务端按错位长度解析、**静默不回**
/// （2026-09-11 真机实测：TCP 连上、1388 字节发出、15s 无任何响应）。
/// 别再犯——`framePacket` 只用于构造 mock 服务端的响应帧。
///
/// ## 为什么要抽象
///
/// 传输层做成接口，登录流程就能在**离线**、**确定性**的条件下被完整自测——
/// 与 OneBot 线用 mock WebSocket 服务器的做法一致。见
/// `tool/qq8_tran_selftest.dart`。
///
/// 本文件依赖 `dart:io`，**不能在纯 Dart VM 以外使用**（正常，传输层本来就
/// 是平台相关的），但除 [Qq8TcpTransport] 外的部分都是纯逻辑。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// 默认登录服务器（与 oicq 的 `default_host` 一致）。
const String qq8DefaultHost = 'msfwifi.3g.qq.com';

/// 默认端口。
const int qq8DefaultPort = 8080;

/// 单次请求的默认超时。
const Duration qq8DefaultTimeout = Duration(seconds: 15);

/// 传输层错误。
class Qq8TransportException implements Exception {
  final String message;
  final Object? cause;

  Qq8TransportException(this.message, [this.cause]);

  @override
  String toString() =>
      'Qq8TransportException: $message${cause == null ? '' : ' ($cause)'}';
}

/// 把 TCP 字节流切成一个个 packet。
///
/// 必须处理两种情况，二者都会真实发生：
/// * **半包** —— 一次 `data` 事件只到了一部分，要缓存等后续；
/// * **粘包** —— 一次 `data` 事件里含多个完整包，要全部吐出。
///
/// 还要能识别**长度非法**的包（服务端返回错误页/被中间设备劫持时会出现），
/// 否则会在等一个永远不来的包时静默卡死。
class Qq8FrameDecoder {
  /// 长度前缀的字节数。
  static const int headerLength = 4;

  /// 单包上限。超过就认为流已经错位，宁可直接报错也不要无限缓存。
  static const int maxFrameLength = 1 << 22; // 4 MiB

  final List<int> _buf = <int>[];

  /// 已缓存但尚未成帧的字节数。
  int get bufferedBytes => _buf.length;

  /// 送入一批字节，返回其中所有**完整**的 payload（不含长度头）。
  ///
  /// 遇到非法长度抛 [Qq8TransportException]。
  List<Uint8List> add(List<int> chunk) {
    final out = <Uint8List>[];
    if (chunk.isNotEmpty) _buf.addAll(chunk);

    var cursor = 0;
    while (_buf.length - cursor >= headerLength) {
      final total = (_buf[cursor] << 24) |
          (_buf[cursor + 1] << 16) |
          (_buf[cursor + 2] << 8) |
          _buf[cursor + 3];

      if (total < headerLength || total > maxFrameLength) {
        // 流已经错位。把缓冲清掉，避免后续每一轮都报同一个错。
        _buf.clear();
        throw Qq8TransportException(
          '非法帧长度 $total（应在 $headerLength..$maxFrameLength 之间）；'
          '流已错位，缓冲区已清空',
        );
      }

      if (_buf.length - cursor < total) break; // 半包，等下一批

      out.add(Uint8List.fromList(
        _buf.sublist(cursor + headerLength, cursor + total),
      ));
      cursor += total;
    }

    if (cursor > 0) _buf.removeRange(0, cursor);
    return out;
  }

  /// 清空缓冲（重连时用）。
  void reset() => _buf.clear();
}

/// 给 payload 套上 4 字节长度头，得到**线上字节**。
///
/// 只用于构造/模拟线上的帧（自测里的 mock 服务端、脚本传输）——
/// **生产发送路径不调用它**：登录包自己已经带了同样的 u32
/// （见文件头"谁负责这个 u32"），再套一层就是把流写错位。
Uint8List framePacket(List<int> payload) {
  final body = payload is Uint8List ? payload : Uint8List.fromList(payload);
  final out = Uint8List(4 + body.length);
  final total = out.length;
  out[0] = (total >> 24) & 0xff;
  out[1] = (total >> 16) & 0xff;
  out[2] = (total >> 8) & 0xff;
  out[3] = total & 0xff;
  out.setRange(4, out.length, body);
  return out;
}

/// 传输层抽象。
///
/// **请求-响应严格配对、串行**：本协议里一个请求只会带回一个响应包，
/// 且登录流程天然是顺序的，所以不需要多路复用。
abstract class Qq8Transport {
  /// 建立连接。已连接时应为幂等。
  Future<void> connect();

  /// 发一个**完整线上包**（自带 u32 分帧头，原样写出），
  /// 等一个完整的响应 payload（帧头已在接收侧剥掉）。
  Future<Uint8List> send(Uint8List payload, {Duration? timeout});

  /// 关闭连接。
  Future<void> close();

  /// 是否处于已连接状态。
  bool get isConnected;
}

/// 真实 TCP 传输。
class Qq8TcpTransport implements Qq8Transport {
  final String host;
  final int port;

  /// 建连超时。
  final Duration connectTimeout;

  /// 默认的单请求超时。
  final Duration timeout;

  Socket? _socket;
  final Qq8FrameDecoder _decoder = Qq8FrameDecoder();

  /// 待响应的 Completer（串行，最多一个）。
  Completer<Uint8List>? _pending;

  Qq8TcpTransport({
    this.host = qq8DefaultHost,
    this.port = qq8DefaultPort,
    this.connectTimeout = const Duration(seconds: 10),
    this.timeout = qq8DefaultTimeout,
  });

  @override
  bool get isConnected => _socket != null;

  @override
  Future<void> connect() async {
    if (_socket != null) return;
    try {
      _socket = await Socket.connect(host, port, timeout: connectTimeout);
    } on Object catch (e) {
      throw Qq8TransportException('连接 $host:$port 失败', e);
    }
    _socket!.setOption(SocketOption.tcpNoDelay, true);
    _decoder.reset();

    _socket!.listen(
      (chunk) {
        List<Uint8List> frames;
        try {
          frames = _decoder.add(chunk);
        } on Qq8TransportException catch (e) {
          _failPending(e);
          return;
        }
        for (final f in frames) {
          final p = _pending;
          if (p == null || p.isCompleted) {
            // 没有人在等响应。丢弃而不是报错 —— 服务端偶发推送属正常。
            continue;
          }
          _pending = null;
          p.complete(f);
        }
      },
      onError: (Object e) => _failPending(Qq8TransportException('读取失败', e)),
      onDone: () {
        _socket = null;
        _failPending(Qq8TransportException('连接被对端关闭'));
      },
      cancelOnError: true,
    );
  }

  void _failPending(Object error) {
    final p = _pending;
    _pending = null;
    if (p != null && !p.isCompleted) p.completeError(error);
  }

  @override
  Future<Uint8List> send(Uint8List payload, {Duration? timeout}) async {
    if (_socket == null) await connect();
    if (_pending != null) {
      throw Qq8TransportException('上一个请求还没收到响应，本协议不支持并发');
    }

    final completer = Completer<Uint8List>();
    _pending = completer;

    try {
      // 原样写出：包自己带的 u32 长度头就是分帧头（对应 oicq `net.write(pkt)`）。
      // 千万不能再 `framePacket()` —— 多一层会让服务端静默丢弃（见文件头）。
      _socket!.add(payload);
      await _socket!.flush();
    } on Object catch (e) {
      _pending = null;
      throw Qq8TransportException('发送失败', e);
    }

    return completer.future.timeout(
      timeout ?? this.timeout,
      onTimeout: () {
        _pending = null;
        throw Qq8TransportException(
          '等待响应超时（${(timeout ?? this.timeout).inSeconds}s）',
        );
      },
    );
  }

  @override
  Future<void> close() async {
    final s = _socket;
    _socket = null;
    _failPending(Qq8TransportException('传输层已关闭'));
    _decoder.reset();
    if (s != null) {
      try {
        await s.close();
      } on Object {
        // 关闭失败无需上报。
      }
    }
  }
}

/// 按脚本回放响应的传输层（自测用）。
///
/// 与 [Qq8TcpTransport] 共用 [Qq8FrameDecoder] 与 [framePacket]，
/// 因此**分帧逻辑本身是被真实验证过的**，不是把测试做成了空转。
class Qq8ScriptedTransport implements Qq8Transport {
  /// 预设的响应 payload（已去帧头）。
  final List<Uint8List> scriptedResponses;

  /// 记录收到的请求 payload，供断言检查。
  final List<Uint8List> sent = <Uint8List>[];

  /// 可选的"把响应再拆成多块"模式，用来验证半包处理。
  final bool splitResponses;

  bool _connected = false;
  int _cursor = 0;

  Qq8ScriptedTransport(
    this.scriptedResponses, {
    this.splitResponses = false,
  });

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async => _connected = true;

  @override
  Future<Uint8List> send(Uint8List payload, {Duration? timeout}) async {
    if (!_connected) await connect();
    sent.add(payload);
    if (_cursor >= scriptedResponses.length) {
      throw Qq8TransportException('脚本已用尽（第 ${_cursor + 1} 个请求无响应）');
    }
    final resp = scriptedResponses[_cursor++];

    if (!splitResponses) return resp;

    // 拆成两半再拼回来 —— 走一遍真实的解码路径。
    final framed = framePacket(resp);
    final mid = framed.length ~/ 2;
    final decoder = Qq8FrameDecoder();
    final first = decoder.add(framed.sublist(0, mid));
    if (first.isNotEmpty) {
      throw Qq8TransportException('半包不应产出完整帧（测试自身有问题）');
    }
    final second = decoder.add(framed.sublist(mid));
    if (second.length != 1) {
      throw Qq8TransportException('拼回后应恰好得到 1 帧，实得 ${second.length}');
    }
    return second.first;
  }

  @override
  Future<void> close() async => _connected = false;
}
