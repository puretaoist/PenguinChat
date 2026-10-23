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

/// 一个可连接的端点。
///
/// ## 为什么需要「端点列表」而不是单个 host（2026-10-23）
///
/// 真机日志里出现过这个错误：
///
/// ```text
/// Qq8TransportException: 连接 msfwifi.3g.qq.com:8080 失败
///   (SocketException: Failed host lookup: 'msfwifi.3g.qq.com'
///    (OS Error: No address associated with hostname, errno = 7))
/// ```
///
/// 也就是**DNS 没能解析出名字**——登录包一个字节都没发出去。当天在电脑上
/// `nslookup` 同一个名字、TCP 8080 都是通的，纯粹是平板所在网络（校园网
/// 的 DNS 拦截 / Wi-Fi 刚切换）解析失败。
///
/// 这种情况下「重试同一个域名」没有意义：解析失败是确定性的，重试还是失败。
/// 唯一能自救的是**直接用 IP**。下面的种子表就是为此存在。
///
/// ## 种子表从哪来
///
/// `POST https://configsvr.msf.3g.qq.com/configsvr/serverlist.jsp?mType=getssolist`
/// 的真实返回（用 icqq 的 `fetchServerList()` 拉了一次，10 个条目）。取其中
/// **8080/443/80 三个常用端口的 4 个**，14000 端口的那几个没用上——本协议
/// 走 8080。
///
/// 这些 IP 会随腾讯调度变化、也可能被单个运营商屏蔽，所以它们**只是兜底**：
/// 永远是「先试域名，失败再试 IP」。宁可多花几秒，也不要让「DNS 抖一下」
/// 变成「今天用不了」。
///
/// 注意：走 serverlist 接口拿最新列表这条路在 DNS 挂掉时同样不可用
/// （`configsvr.msf.3g.qq.com` 也要解析），所以没有实现它——写了也救不了
/// 这个场景，只会增加一条永远走不到的分支。
class Qq8Endpoint {
  /// 主机名或点分十进制 IP。
  final String host;
  final int port;

  /// 是不是「主端点」（域名）。主端点用完整的 [connectTimeout]，
  /// 兜底 IP 用更短的超时——它们本来就是备胎，不该让用户等太久。
  final bool isPrimary;

  const Qq8Endpoint(this.host, this.port, {this.isPrimary = false});

  String get key => '$host:$port';

  @override
  String toString() => key;
}

/// 主端点（域名）。
const Qq8Endpoint qq8PrimaryEndpoint =
    Qq8Endpoint(qq8DefaultHost, qq8DefaultPort, isPrimary: true);

/// 兜底端点（真实 IP，来自官方 serverlist）。
///
/// 顺序按 serverlist 返回的先后：前两个通常最稳（icqq 的注释也这么写，
/// 见 `icqq/lib/core/network.js` 的「通常来说只有前两个 ip 比较稳定」）。
const List<Qq8Endpoint> qq8SeedEndpoints = <Qq8Endpoint>[
  Qq8Endpoint('43.137.59.88', 8080),
  Qq8Endpoint('153.3.46.86', 443),
  Qq8Endpoint('112.86.231.155', 80),
  Qq8Endpoint('153.3.244.48', 80),
];

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

  /// 只发不等：响应统一从 [onFrame] 回调走。
  ///
  /// 会话层（`qq8_session.dart`）用这对 API——比 [send] 的一问一答多两种
  /// 情况：**推送**（没有对应请求的帧）与**并发**（多个请求同时在等）。
  /// 单发工具仍用 [send]。
  Future<void> write(Uint8List packet);

  /// 每个解出的帧回调一次（帧 = 去掉 4 字节分帧头后的 payload）。
  ///
  /// 设置后 [send] 的配对逻辑不再生效（两种消费方式互斥，避免同一个帧
  /// 被投递两次）。
  set onFrame(void Function(Uint8List frame)? cb);

  /// 关闭连接。
  Future<void> close();

  /// 是否处于已连接状态。
  bool get isConnected;
}

/// 真实 TCP 传输。
class Qq8TcpTransport implements Qq8Transport {
  final String host;
  final int port;

  /// 建连超时。**主端点**用它；兜底 IP 用它的三分之一（见 [connect]）。
  final Duration connectTimeout;

  /// 默认的单请求超时。
  final Duration timeout;

  /// 主端点失败后依次尝试的备用端点。
  ///
  /// 传 null 表示「按 [host]/[port] 自动决定」：只有指向默认登录服务器时
  /// 才启用 [qq8SeedEndpoints]，其余情况（自测的 loopback、抓包代理、
  /// 自定义主机）一律不启用。
  ///
  /// **这个默认值不是随手写的**：自测用 `Qq8TcpTransport(host: 127.0.0.1)`
  /// 模拟「连不上」，如果那时还去试公网 IP，测试就会真的发起网络请求，
  /// 既慢又不稳定——"连不上时报错"这条断言会变成"连不上时跑去连别处"。
  final List<Qq8Endpoint>? fallbacks;

  /// 可选的建连诊断回调（每次尝试一个端点前调用一次）。
  ///
  /// 用来回答「到底试过哪些地址」——DNS 失败时日志里只有最后一句异常，
  /// 看不出中间试了几个兜底。回调类型刻意用 String 而不是异常对象：
  /// 调用方是日志，它不需要异常的栈。
  void Function(String message)? onConnectAttempt;

  Socket? _socket;
  final Qq8FrameDecoder _decoder = Qq8FrameDecoder();

  /// 待响应的 Completer（串行，最多一个）。
  Completer<Uint8List>? _pending;

  /// 流式消费回调（设置后 [send] 的配对逻辑不再生效）。
  void Function(Uint8List frame)? _onFrame;

  /// 本次连接实际连上的端点；未连接时为 null。
  ///
  /// 排障价值：日志里出现 `:443` 或裸 IP 就说明**走了兜底**，
  /// 也就说明当时 DNS 出了问题。否则「连上了」这件事会掩盖掉网络异常。
  Qq8Endpoint? connectedEndpoint;

  Qq8TcpTransport({
    this.host = qq8DefaultHost,
    this.port = qq8DefaultPort,
    this.connectTimeout = const Duration(seconds: 10),
    this.timeout = qq8DefaultTimeout,
    this.fallbacks,
  });

  /// 本次连接要依次尝试的端点列表（第一个是主端点）。
  List<Qq8Endpoint> get candidates {
    final explicit = fallbacks;
    final List<Qq8Endpoint> extra;
    if (explicit != null) {
      extra = explicit;
    } else if (host == qq8DefaultHost && port == qq8DefaultPort) {
      extra = qq8SeedEndpoints;
    } else {
      extra = const <Qq8Endpoint>[];
    }
    return <Qq8Endpoint>[
      Qq8Endpoint(host, port, isPrimary: true),
      ...extra.where((e) => e.host != host || e.port != port),
    ];
  }

  @override
  bool get isConnected => _socket != null;

  @override
  Future<void> connect() async {
    if (_socket != null) return;

    final list = candidates;
    final errors = <String>[];

    for (var i = 0; i < list.length; i++) {
      final ep = list[i];
      // 主端点等满 connectTimeout；兜底端点只等三分之一。
      // 理由：兜底是「主端点已经失败过一次」之后才上场的，用户此刻已经
      // 等了 10 秒。再让每个备胎各等 10 秒，四个备胎就是 50 秒白屏。
      final timeoutFor = ep.isPrimary
          ? connectTimeout
          : Duration(
              milliseconds: (connectTimeout.inMilliseconds / 3).round(),
            );
      onConnectAttempt?.call('尝试连接 ${ep.key}（超时 ${timeoutFor.inSeconds}s）'
          '${i == 0 ? '' : '，第 $i 个兜底'}');
      try {
        _socket = await Socket.connect(ep.host, ep.port, timeout: timeoutFor);
        connectedEndpoint = ep;
        if (i > 0) {
          onConnectAttempt?.call('主端点失败，已切到兜底 ${ep.key} 连上');
        }
        break;
      } on Object catch (e) {
        errors.add('${ep.key}: $e');
        onConnectAttempt?.call('${ep.key} 失败: $e');
      }
    }

    if (_socket == null) {
      // 把所有尝试都塞进异常消息：只报最后一个会让人以为「只有一个地址挂了」，
      // 而这四种失败往往原因不同（DNS 失败 / 连接被重置 / 超时 / 端口不通）。
      throw Qq8TransportException(
        '连接失败（已尝试 ${list.length} 个端点）\n'
        '${errors.map((e) => '  - $e').join('\n')}',
      );
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
          final cb = _onFrame;
          if (cb != null) {
            cb(f); // 流式消费：由上层按 seq 配对 / 走推送
            continue;
          }
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
  set onFrame(void Function(Uint8List frame)? cb) => _onFrame = cb;

  @override
  Future<void> write(Uint8List packet) async {
    if (_socket == null) await connect();
    try {
      // 与 send 同一约定：包自带 u32 长度头，原样写出。
      _socket!.add(packet);
      await _socket!.flush();
    } on Object catch (e) {
      throw Qq8TransportException('发送失败', e);
    }
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
    connectedEndpoint = null;
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
  void Function(Uint8List frame)? _onFrame;

  Qq8ScriptedTransport(
    this.scriptedResponses, {
    this.splitResponses = false,
  });

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async => _connected = true;

  @override
  set onFrame(void Function(Uint8List frame)? cb) => _onFrame = cb;

  /// 手动投递一个帧（模拟服务端主动推送；测试用）。
  void emit(Uint8List frame) => _onFrame?.call(frame);

  @override
  Future<void> write(Uint8List packet) async {
    if (!_connected) await connect();
    sent.add(packet);
    final cb = _onFrame;
    if (cb == null) return; // 无监听者：留在 sent 里由测试断言
    if (_cursor >= scriptedResponses.length) {
      throw Qq8TransportException('脚本已用尽（第 ${_cursor + 1} 个请求无响应）');
    }
    // 与真实传输一致：回调收到的是"去掉分帧头后的 payload"。
    cb(scriptedResponses[_cursor++]);
  }

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
