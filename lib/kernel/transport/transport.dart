/// L2 协议内核：传输层抽象
///
/// ## 为什么先做抽象
///
/// QQ 的业务报文并非「一问一答一连接」，而是**全部复用一条长连接**（MSF，
/// Mobile Socket Framework）：客户端与 SSO 网关建立单条 TCP 后，所有 SSO 命令
/// 以带序号（seq）的帧复用其上，响应按 seq 回填。
/// 因此传输层的正确抽象不是 `connect/send/close`，而是：
///
///   - 维护一条长连接
///   - 提供 **[command] + [body] -> [response]** 的异步请求语义（由 seq 匹配）
///   - 连接断开时通知上层（自动重连由会话层决定）
///
/// ## 本文件与实现的关系
///
/// 本文件只定义接口与事件模型（架构确定部分）。
/// 具体帧格式（head/tail 标记、长度字段位置、加密方式）需以反编译结果为准，
/// 见 [MsfFrameCodec] 的说明——在拿到 `oicq.wlogin_sdk.request.oicq_request`
/// 的反编译结果前，不臆测字节布局。
///
/// 已有实现：
///   - [LoopbackTransport]：内存回环，供 UI 开发与集成测试使用
///   - `MsfTransport`：真实 TCP 长连接（待帧格式确认后实现）
library;

import 'dart:async';
import 'dart:typed_data';

/// 传输层状态。
enum TransportState {
  /// 未连接
  disconnected,

  /// 正在建立连接
  connecting,

  /// 已连接，可收发
  connected,

  /// 连接异常，等待重连
  reconnecting,

  /// 已永久关闭（主动 close）
  closed,
}

/// 传输层事件。
sealed class TransportEvent {
  const TransportEvent();
}

/// 状态变化。
class TransportStateChanged extends TransportEvent {
  final TransportState state;
  final String? reason;
  const TransportStateChanged(this.state, {this.reason});
}

/// 收到一条主动下推（服务端 push，非响应）。
class TransportPush extends TransportEvent {
  final int command;
  final Uint8List body;
  const TransportPush(this.command, this.body);
}

/// 传输层错误。
class TransportError extends TransportEvent {
  final Object error;
  final StackTrace? stackTrace;
  const TransportError(this.error, [this.stackTrace]);
}

/// 一次请求失败的异常。
class TransportException implements Exception {
  final String message;
  final int? command;
  final int? resultCode;
  const TransportException(this.message, {this.command, this.resultCode});

  @override
  String toString() {
    final cmd = command == null ? '' : ' cmd=0x${command!.toRadixString(16)}';
    final rc = resultCode == null ? '' : ' rc=$resultCode';
    return 'TransportException[$message$cmd$rc]';
  }
}

/// 长连接传输层接口。
///
/// 实现需保证：
///   - [send] 的并发调用安全（内部按 seq 匹配响应）
///   - [send] 在连接断开时以 [TransportException] 失败，而非永久挂起
///   - [close] 后所有未完成请求立即失败
abstract class Transport {
  /// 当前状态
  TransportState get state;

  /// 事件流（状态变化 / 服务端推送 / 错误）
  Stream<TransportEvent> get events;

  /// 建立连接。幂等——已连接时直接返回。
  Future<void> connect();

  /// 发送请求并等待响应。
  ///
  /// [command] 为 SSO 命令字编号或 trpc 序号；[body] 为业务载荷。
  /// 超时抛 [TransportException]。
  Future<Uint8List> send(
    int command,
    Uint8List body, {
    Duration timeout = const Duration(seconds: 30),
  });

  /// 关闭连接并释放资源。
  Future<void> close();
}

/// MSF 帧编解码。
///
/// ⚠️ 尚未实现——**故意留空**。
///
/// 真实帧格式包含 head 标记、长度字段、序号、命令字与尾部校验，
/// 各字段的偏移与宽度必须从反编译结果确认后才能落地。
/// 猜测一个「看起来合理」的布局会让后续调试付出更大代价，
/// 因此这里只登记契约，不填猜测值。
///
/// 待确认的信息（拿到 `oicq_request` 反编译结果后逐项填入）：
///   1. 帧首标记字节值
///   2. 长度字段是「包含自身」还是「仅载荷」
///   3. seq 是递增计数器还是随机起始
///   4. 命令字宽度（u16 SSO vs trpc 字符串）
///   5. 是否对载荷做 TEA/ECDH 二次加密，以及在帧的哪一层
abstract class MsfFrameCodec {
  /// 把逻辑帧编码成字节。
  Uint8List encodeFrame(int seq, int command, Uint8List body);

  /// 从缓冲区尝试解出一帧；不足一帧返回 null。
  ({int seq, int command, Uint8List body})? tryDecodeFrame(Uint8List buffer);
}

/// 内存回环传输：不碰网络，用于 UI 开发与集成测试。
///
/// 行为特征：
///   - [connect] 立即成功
///   - [send] 由注册的 [handler] 生成响应；未注册的命令返回空响应
///   - 可模拟延迟、错误与主动推送
///
/// 价值：让 UI 与上层逻辑在没有真机、没有服务端的情况下可完整跑通。
class LoopbackTransport implements Transport {
  final _events = StreamController<TransportEvent>.broadcast();
  TransportState _state = TransportState.disconnected;

  /// 命令 -> 响应生成函数
  final Map<int, Uint8List Function(Uint8List body)> _handlers = {};

  /// 人为注入的延迟，用于测试 loading 态
  Duration latency;

  /// 设为非 null 时，[send] 直接抛出该异常（用于测试失败路径）
  TransportException? failWith;

  /// 记录所有已发送的请求，便于断言
  final List<({int command, Uint8List body})> sent = [];

  LoopbackTransport({this.latency = Duration.zero});

  /// 注册某个命令的响应生成器。
  void on(int command, Uint8List Function(Uint8List body) handler) {
    _handlers[command] = handler;
  }

  /// 模拟服务端主动推送。
  void push(int command, Uint8List body) {
    _events.add(TransportPush(command, body));
  }

  @override
  TransportState get state => _state;

  @override
  Stream<TransportEvent> get events => _events.stream;

  void _setState(TransportState s, [String? reason]) {
    _state = s;
    _events.add(TransportStateChanged(s, reason: reason));
  }

  @override
  Future<void> connect() async {
    if (_state == TransportState.connected) return;
    _setState(TransportState.connecting);
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    _setState(TransportState.connected);
  }

  @override
  Future<Uint8List> send(
    int command,
    Uint8List body, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_state != TransportState.connected) {
      throw TransportException('未连接', command: command);
    }
    sent.add((command: command, body: body));
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (failWith != null) throw failWith!;
    final h = _handlers[command];
    if (h == null) return Uint8List(0);
    return h(body);
  }

  @override
  Future<void> close() async {
    _setState(TransportState.closed);
    await _events.close();
  }
}
