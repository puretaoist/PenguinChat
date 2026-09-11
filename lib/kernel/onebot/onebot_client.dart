/// L2 协议内核：OneBot 11 客户端
///
/// ## 职责
///
/// 维护一条到 OneBot 实现（NapCat / Lagrange.OneBot / LLOneBot）的**正向
/// WebSocket**，并把它封装成「请求—响应」与「事件流」两种语义：
///
///   - 请求：`{action, params, echo}` → `{status, retcode, data, echo}`
///     由 [echo] 关联；见 [OneBotClient.call]
///   - 事件：`{post_type, ...}` 无 `echo`，按 `post_type` 分发；
///     见 [OneBotClient.events]
///
/// ## 不负责
///
///   - 消息段语义与解析 → `segment.dart`
///   - 各后端的字段命名差异 → `backend_profile.dart`
///   - UI 数据对象（Chat / ChatMessage）→ `client_api/`
///
/// ## 设计依据
///
/// 对照实现：
///   - Icalingua++ `icalingua-bridge-oicq/clients/OnebotClient.ts`
///     （echo 关联用 Map + 超时 + 断线批量 reject —— 本文件采用同一思路，
///      改用 Dart 的 Completer，去掉其轮询开销）
///   - Stapxs next `src/renderer/src/function/connect.ts`
///     （心跳看门狗 max(2×interval, interval+5s)、关闭码 1000/1006/1015
///      分级重连 —— 本文件采用同一策略）
///
/// ## 与既有的 `LoopbackTransport` 的关系
///
/// `transport.dart` 是**字节级**抽象（`int command` + `Uint8List body`），
/// 服务于 SSO/MSF 研究线；OneBot 是 JSON RPC，接缝在更上一层（`Session`）。
/// 两者并存，互不依赖。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 连接状态。
enum OneBotState {
  /// 未连接。
  disconnected,

  /// 正在建立连接。
  connecting,

  /// 已连接，可收发。
  connected,

  /// 连接异常，等待重连。
  reconnecting,

  /// 已永久关闭（主动 [OneBotClient.close]）。
  closed,
}

/// 一次 API 调用失败的异常。
class OneBotApiException implements Exception {
  /// 出错的动作名。
  final String action;

  /// OneBot 返回的 `retcode`（本地错误为 null）。
  final int? retcode;

  /// OneBot 返回的 `msg` / `wording`，或本地错误描述。
  final String message;

  const OneBotApiException(this.action, this.message, {this.retcode});

  @override
  String toString() {
    final rc = retcode == null ? '' : ' retcode=$retcode';
    return 'OneBotApiException[$action$rc] $message';
  }
}

// ---------------------------------------------------------------------------
// 事件模型
// ---------------------------------------------------------------------------

/// OneBot 事件基类。
sealed class OneBotEvent {
  const OneBotEvent();

  /// 事件发生时间（Unix 秒），未知为 null。
  int? get time;
}

/// `post_type: message` / `message_sent` —— 收到或自己发出的消息。
class OneBotMessageEvent extends OneBotEvent {
  /// 原始 JSON。
  final Map<String, dynamic> raw;

  /// private / group / …
  final String messageType;

  /// `message` 或 `message_sent`。
  final String postType;

  const OneBotMessageEvent(this.raw, this.messageType, this.postType);

  /// 自己发的（`message_sent`，用于多端同步）。
  bool get isSelfSent => postType == 'message_sent';

  /// 群消息则为群号，私聊为 null。
  int? get groupId => _asInt(raw['group_id']);

  /// 对方 QQ 号（私聊）或发送者 QQ 号（群聊）。
  int? get userId => _asInt(raw['user_id']);

  /// 消息 ID。
  int? get messageId => _asInt(raw['message_id']);

  /// 消息段数组（array 格式）。
  List<Map<String, dynamic>> get segments =>
      (raw['message'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();

  /// CQ 码格式原文。
  String get rawMessage => (raw['raw_message'] as String?) ?? '';

  /// 发送者信息。
  Map<String, dynamic> get sender =>
      (raw['sender'] as Map?)?.cast<String, dynamic>() ?? const {};

  @override
  int? get time => _asInt(raw['time']);
}

/// `post_type: notice` —— 通知（撤回、戳一戳、成员变动、禁言…）。
class OneBotNoticeEvent extends OneBotEvent {
  /// 原始 JSON。
  final Map<String, dynamic> raw;

  /// `notice_type`，如 `group_recall` / `friend_recall` / `notify`。
  final String noticeType;

  /// `sub_type`，如 `poke` / `ban` / `title`，可能为空。
  final String subType;

  const OneBotNoticeEvent(this.raw, this.noticeType, this.subType);

  /// 群号（群相关通知才有）。
  int? get groupId => _asInt(raw['group_id']);

  /// 相关 QQ 号。
  int? get userId => _asInt(raw['user_id']);

  /// 操作者 QQ 号。
  int? get operatorId => _asInt(raw['operator_id']);

  /// 相关消息 ID（撤回类通知）。
  int? get messageId => _asInt(raw['message_id']);

  @override
  int? get time => _asInt(raw['time']);
}

/// `post_type: request` —— 好友申请 / 群邀请。
class OneBotRequestEvent extends OneBotEvent {
  /// 原始 JSON。
  final Map<String, dynamic> raw;

  /// `request_type`：`friend` 或 `group`。
  final String requestType;

  const OneBotRequestEvent(this.raw, this.requestType);

  /// 用于回应该请求的 flag。
  String get flag => (raw['flag'] as String?) ?? '';

  /// 申请者 / 邀请者 QQ 号。
  int? get userId => _asInt(raw['user_id']);

  /// 群号（群请求才有）。
  int? get groupId => _asInt(raw['group_id']);

  @override
  int? get time => _asInt(raw['time']);
}

/// `post_type: meta_event` —— 生命周期与心跳。
class OneBotMetaEvent extends OneBotEvent {
  /// 原始 JSON。
  final Map<String, dynamic> raw;

  /// `meta_event_type`：`lifecycle` 或 `heartbeat`。
  final String metaEventType;

  const OneBotMetaEvent(this.raw, this.metaEventType);

  /// 心跳间隔（毫秒），仅 heartbeat 事件有。
  ///
  /// 用于驱动 [OneBotClient] 的看门狗：官方建议以 `2 × interval` 为阈值。
  int? get intervalMs => _asInt(raw['interval']);

  /// `lifecycle` 时表示是否已连接。
  bool get isOnline =>
      ((raw['status'] as Map?)?['online'] as bool?) ?? metaEventType == 'heartbeat';

  @override
  int? get time => _asInt(raw['time']);
}

/// 无法归类的推送（含 OneBot 扩展事件），保留原始数据不丢信息。
class OneBotUnknownEvent extends OneBotEvent {
  /// 原始 JSON。
  final Map<String, dynamic> raw;

  const OneBotUnknownEvent(this.raw);

  @override
  int? get time => _asInt(raw['time']);
}

/// 连接状态变化。
class OneBotStateChanged extends OneBotEvent {
  /// 新状态。
  final OneBotState state;

  /// 变化原因，用于日志与重连判定。
  final String? reason;

  const OneBotStateChanged(this.state, {this.reason});

  @override
  int? get time => null;
}

/// 传输层错误（不致命，连接可能仍在）。
class OneBotTransportError extends OneBotEvent {
  /// 异常对象。
  final Object error;

  /// 堆栈。
  final StackTrace? stackTrace;

  const OneBotTransportError(this.error, [this.stackTrace]);

  @override
  int? get time => null;
}

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

/// WebSocket 建连函数，可在测试中替换为 mock 实现。
typedef OneBotSocketFactory = Future<WebSocket> Function(
  Uri uri, {
  Map<String, dynamic>? headers,
});

/// 连接与重试参数。
class OneBotConfig {
  /// OneBot 服务地址，例如 `ws://127.0.0.1:3001`。
  final String address;

  /// 访问令牌，null 表示后端未开启鉴权。
  final String? accessToken;

  /// true 时用 `Authorization: Bearer <token>`，false 时用 `?access_token=`。
  ///
  /// OneBot 11 规范两种都允许，但各实现支持度不同：NapCat 与 go-cqhttp 两者都支持，
  /// 参考实现（Icalingua / Stapxs）默认走查询参数，因此此处默认 false。
  final bool tokenInHeader;

  /// 单次 API 调用超时。
  final Duration callTimeout;

  /// 建连超时。
  final Duration connectTimeout;

  /// 连续重连次数上限，超过后转入 [OneBotState.disconnected] 停止自动重试。
  final int maxRetries;

  /// 重连退避基数，实际延迟为 `base * 2^n`（上限 [maxRetryDelay]）。
  final Duration retryBaseDelay;

  /// 重连延迟上限。
  final Duration maxRetryDelay;

  /// 心跳看门狗：在该时长内未收到任何 `meta_event` 即判定假死并重连。
  final Duration heartbeatTimeout;

  /// 收到 TLS 错误（关闭码 1015）时是否降级为明文 `ws://` 重试。
  ///
  /// 仅在连 `127.0.0.1` 这类本机地址时有意义；连公网后端应保持 false。
  final bool allowPlaintextFallback;

  const OneBotConfig({
    required this.address,
    this.accessToken,
    this.tokenInHeader = false,
    this.callTimeout = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 10),
    this.maxRetries = 5,
    this.retryBaseDelay = const Duration(milliseconds: 1500),
    this.maxRetryDelay = const Duration(seconds: 30),
    this.heartbeatTimeout = const Duration(seconds: 30),
    this.allowPlaintextFallback = false,
  });

  /// 把 token 按 [tokenInHeader] 的约定并入 [uri]。
  Uri resolveUri([String? addressOverride]) {
    final raw = addressOverride ?? address;
    final uri = Uri.parse(raw);
    if (accessToken == null || accessToken!.isEmpty || tokenInHeader) {
      return uri;
    }
    return uri.replace(
      queryParameters: {...uri.queryParameters, 'access_token': accessToken!},
    );
  }

  /// 随 token 一起使用的请求头。
  Map<String, dynamic>? get headers {
    if (accessToken == null || accessToken!.isEmpty || !tokenInHeader) {
      return null;
    }
    return {'Authorization': 'Bearer ${accessToken!}'};
  }
}

// ---------------------------------------------------------------------------
// 客户端
// ---------------------------------------------------------------------------

/// OneBot 11 正向 WebSocket 客户端。
///
/// 线程模型：单 [WebSocket]，所有请求共用一个连接，由 `echo` 关联响应。
/// 并发调用 [call] 是安全的。
class OneBotClient {
  /// 连接与重试参数。
  final OneBotConfig config;

  /// 日志回调；null 表示不输出。
  final void Function(String level, String message, [Object? detail])? onLog;

  final _events = StreamController<OneBotEvent>.broadcast();

  /// 挂起请求表：echo → 完成器。
  ///
  /// 值是 `Object?` 而不是 `Map`：OneBot 的响应 `data` 可能是对象
  /// （`get_login_info`）也可能是**数组**（`get_friend_list`、
  /// `get_group_list`），也有可能是 null。把它窄化成 Map 会在列表类
  /// API 上直接抛类型错误。
  final _pending = <String, Completer<Object?>>{};

  OneBotSocketFactory _socketFactory;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _sub;
  Timer? _heartbeatTimer;
  Timer? _retryTimer;

  OneBotState _state = OneBotState.disconnected;
  int _echoSeq = 0;
  int _retryCount = 0;
  bool _closedByUser = false;
  bool _connectInFlight = false;

  /// 当前连接地址（可能因降级重试而改变）。
  String _effectiveAddress;

  OneBotClient({
    required this.config,
    this.onLog,
    OneBotSocketFactory? socketFactory,
  })  : _effectiveAddress = config.address,
        _socketFactory = socketFactory ?? _defaultSocketFactory;

  /// 默认建连实现。
  static Future<WebSocket> _defaultSocketFactory(
    Uri uri, {
    Map<String, dynamic>? headers,
  }) =>
      WebSocket.connect(
        uri.toString(),
        headers: headers,
      ).timeout(const Duration(seconds: 15));

  /// 事件流（连接状态 / 四类 OneBot 事件 / 传输错误）。
  Stream<OneBotEvent> get events => _events.stream;

  /// 当前状态。
  OneBotState get state => _state;

  /// 是否已连接。
  bool get isConnected => _state == OneBotState.connected;

  /// 尚未收到响应的请求数（诊断用）。
  int get pendingCalls => _pending.length;

  /// 供测试替换建连实现（例如指向 mock server）。
  void setSocketFactory(OneBotSocketFactory factory) {
    _socketFactory = factory;
  }

  // -- 生命周期 --------------------------------------------------------------

  /// 建立连接。已连接时直接返回（幂等）。
  Future<void> connect() async {
    if (_state == OneBotState.connected || _connectInFlight) return;
    _closedByUser = false;
    _connectInFlight = true;
    try {
      await _openSocket();
    } finally {
      _connectInFlight = false;
    }
  }

  Future<void> _openSocket() async {
    _setState(
      _retryCount == 0 ? OneBotState.connecting : OneBotState.reconnecting,
      reason: 'retry=$_retryCount',
    );

    final uri = config.resolveUri(_effectiveAddress);
    try {
      final socket = await _socketFactory(uri, headers: config.headers);
      if (_closedByUser) {
        await socket.close();
        return;
      }
      _socket = socket;
      _sub = socket.listen(
        _onFrame,
        onError: (Object e, StackTrace st) {
          _emit(OneBotTransportError(e, st));
        },
        onDone: () => _onSocketClosed(socket.closeCode, socket.closeReason),
        cancelOnError: false,
      );
      _retryCount = 0;
      _setState(OneBotState.connected);
      // 建连成功先起一个保守的看门狗，收到 heartbeat 后用真实 interval 重设。
      _armHeartbeat(config.heartbeatTimeout);
      _log('info', '已连接 ${_redacted(uri)}');
    } on Object catch (e, st) {
      _emit(OneBotTransportError(e, st));
      _log('error', '建连失败 ${_redacted(uri)}', e);
      _scheduleRetry(reason: 'connect-failed');
    }
  }

  /// 供日志使用的脱敏 URI。
  ///
  /// `resolveUri` 会把 access_token 拼进查询串，直接插值等于把凭据写进日志
  /// （AGENTS.md §1.5）。令牌只以查询参数的形态出现，替换其值即可。
  static String _redacted(Uri uri) {
    final params = uri.queryParameters;
    if (!params.containsKey('access_token')) return '$uri';
    return '${uri.replace(
      queryParameters: {...params, 'access_token': '***'},
    )}';
  }

  /// 主动关闭。之后不再自动重连。
  Future<void> close() async {
    _closedByUser = true;
    _heartbeatTimer?.cancel();
    _retryTimer?.cancel();
    _rejectAll(OneBotApiException('*', '连接已关闭'));
    await _sub?.cancel();
    _sub = null;
    await _socket?.close(1000, 'client closing');
    _socket = null;
    _setState(OneBotState.closed);
    _log('info', '已关闭');
  }

  void _onSocketClosed(int? code, String? reason) {
    _socket = null;
    _heartbeatTimer?.cancel();
    _rejectAll(
      OneBotApiException('*', '连接断开${reason == null || reason.isEmpty ? '' : ': $reason'}'),
    );
    if (_closedByUser) {
      _setState(OneBotState.closed);
      return;
    }
    final c = code ?? 1006;
    _log('warn', '连接关闭 code=$c reason=$reason');

    // 关闭码分级：参考 Stapxs connect.ts 的策略
    switch (c) {
      case 1000: // 正常关闭 —— 不重连
        _setState(OneBotState.disconnected, reason: 'normal-close');
        return;
      case 1015: // TLS 错误 —— 可选降级为明文 ws://
        if (config.allowPlaintextFallback && _effectiveAddress.startsWith('wss://')) {
          _effectiveAddress = 'ws://${_effectiveAddress.substring('wss://'.length)}';
          _log('warn', 'TLS 失败，降级为 $_effectiveAddress');
          _retryCount = 0;
        }
        _scheduleRetry(reason: 'tls-error');
        return;
      default:
        _scheduleRetry(reason: 'close-$c');
    }
  }

  void _scheduleRetry({required String reason}) {
    if (_closedByUser) return;
    if (_retryCount >= config.maxRetries) {
      _setState(OneBotState.disconnected, reason: 'retry-exhausted');
      _log('error', '重连次数用尽（${config.maxRetries}），停止自动重试');
      return;
    }
    final delayMs = (config.retryBaseDelay.inMilliseconds * (1 << _retryCount))
        .clamp(0, config.maxRetryDelay.inMilliseconds);
    _retryCount++;
    _setState(OneBotState.reconnecting, reason: reason);
    _log('info', '${delayMs}ms 后第 $_retryCount 次重连');
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(milliseconds: delayMs), () {
      if (_closedByUser) return;
      unawaited(connect());
    });
  }

  /// 强制断开并按重连策略恢复。
  ///
  /// 同一 [reason] 在超时已被处理过时不会重复触发（防抖，参考 Stapxs
  /// `Connector.forceDisconnect` 的 `metaEventTimeoutTriggered` 守卫）。
  void forceReconnect(String reason) {
    if (_closedByUser) return;
    _log('warn', '强制重连：$reason');
    _heartbeatTimer?.cancel();
    final socket = _socket;
    _socket = null;
    unawaited(_sub?.cancel());
    _sub = null;
    unawaited(socket?.close(4000, reason));
    _onSocketClosed(1006, reason);
  }

  // -- 请求 ----------------------------------------------------------------

  /// 调用一个 OneBot API，返回响应里的 `data` 字段。
  ///
  /// 返回类型是 `Object?` 而不是 `Map`，因为 OneBot 规范允许 `data` 是
  /// 对象、数组或 null：
  ///   - `get_login_info` → `{user_id, nickname}`
  ///   - `get_friend_list` → `[{...}, {...}]`
  /// 需要对象形状时用 [callMap]。
  ///
  /// 失败抛 [OneBotApiException]：
  ///   - 未连接 → 立即失败，不会挂起
  ///   - 超时 → 超时后失败并从挂起表移除
  ///   - 连接断开 → 所有挂起请求被批量拒绝
  Future<Object?> call(
    String action, [
    Map<String, dynamic> params = const {},
  ]) {
    final socket = _socket;
    if (socket == null || _state != OneBotState.connected) {
      return Future.error(
        OneBotApiException(action, '未连接（当前状态 ${_state.name}）'),
      );
    }

    final echo = '${DateTime.now().microsecondsSinceEpoch}-${_echoSeq++}';
    final completer = Completer<Object?>();
    _pending[echo] = completer;

    Timer(config.callTimeout, () {
      final p = _pending.remove(echo);
      if (p != null && !p.isCompleted) {
        p.completeError(OneBotApiException(action, '请求超时'));
      }
    });

    try {
      socket.add(jsonEncode({'action': action, 'params': params, 'echo': echo}));
    } on Object catch (e) {
      _pending.remove(echo);
      return Future.error(OneBotApiException(action, '发送失败: $e'));
    }
    return completer.future;
  }

  /// 与 [call] 相同，但要求 `data` 是对象；null 视为空对象。
  ///
  /// OneBot 里绝大多数 API 返回对象，用这个可以省掉调用点的类型断言。
  Future<Map<String, dynamic>> callMap(
    String action, [
    Map<String, dynamic> params = const {},
  ]) async {
    final data = await call(action, params);
    if (data == null) return const {};
    if (data is Map) return data.cast<String, dynamic>();
    throw OneBotApiException(
      action,
      '响应 data 不是对象（实际 ${data.runtimeType}），该 API 应使用 call()',
    );
  }

  /// 与 [call] 相同，但后端未实现该 action 时返回 null 而不是抛异常。
  ///
  /// 各 OneBot 实现的 API 覆盖不同（例如 `set_group_name` 只有 Lagrange 有），
  /// 上层做能力探测时用这个方法避免到处 try/catch。
  Future<Object?> tryCall(
    String action, [
    Map<String, dynamic> params = const {},
  ]) async {
    try {
      return await call(action, params);
    } on OneBotApiException catch (e) {
      _log('debug', 'API 不可用或被拒绝: $action', e);
      return null;
    }
  }

  // -- 内部 ----------------------------------------------------------------

  void _onFrame(dynamic frame) {
    if (frame is! String) return;
    Map<String, dynamic> data;
    try {
      data = (jsonDecode(frame) as Map).cast<String, dynamic>();
    } on Object catch (e) {
      _emit(OneBotTransportError(FormatException('非法 JSON 帧: $e')));
      return;
    }
    _armHeartbeat(config.heartbeatTimeout); // 任何帧都说明连接活着

    final echo = data['echo'];
    if (echo != null) {
      _completeCall(echo.toString(), data);
    } else {
      _dispatch(data);
    }
  }

  void _completeCall(String echo, Map<String, dynamic> data) {
    final pending = _pending.remove(echo);
    if (pending == null || pending.isCompleted) return; // 超时后迟到，忽略

    final status = data['status'];
    final retcode = _asInt(data['retcode']);
    final ok = status == 'ok' || retcode == 0 || retcode == 1; // 1 = 异步已受理
    if (ok) {
      // 原样透传：data 可能是对象、数组或 null，由上层按 API 决定怎么解释
      pending.complete(data['data']);
    } else {
      final msg = [data['msg'], data['wording']]
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .join(' / ');
      pending.completeError(
        OneBotApiException('echo:$echo', msg.isEmpty ? '未知错误' : msg, retcode: retcode),
      );
    }
  }

  void _dispatch(Map<String, dynamic> data) {
    final post = (data['post_type'] as String?) ?? '';
    switch (post) {
      case 'message':
      case 'message_sent':
        _emit(OneBotMessageEvent(
          data,
          (data['message_type'] as String?) ?? 'private',
          post,
        ));
      case 'notice':
        _emit(OneBotNoticeEvent(
          data,
          (data['notice_type'] as String?) ?? '',
          (data['sub_type'] as String?) ?? '',
        ));
      case 'request':
        _emit(OneBotRequestEvent(
          data,
          (data['request_type'] as String?) ?? '',
        ));
      case 'meta_event':
        final meta = OneBotMetaEvent(
          data,
          (data['meta_event_type'] as String?) ?? '',
        );
        // 心跳自带上报间隔：据此收紧看门狗，避免用保守默认值拖长假死检测。
        final interval = meta.intervalMs;
        if (interval != null) applyHeartbeatInterval(interval);
        _emit(meta);
      default:
        _emit(OneBotUnknownEvent(data));
    }
  }

  void _armHeartbeat(Duration timeout) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer(timeout, () {
      forceReconnect('心跳包超时（${timeout.inSeconds}s 未收到任何数据）');
    });
  }

  /// 根据 heartbeat 事件上报的 interval 调整看门狗阈值。
  ///
  /// 阈值取 `max(2 × interval, interval + 5s)`：前者容忍丢一个心跳，
  /// 后者保证 interval 很小时仍有余量（沿用 Stapxs 的策略）。
  void applyHeartbeatInterval(int intervalMs) {
    if (intervalMs <= 0) return;
    final base = Duration(milliseconds: intervalMs);
    final doubled = base * 2;
    final padded = base + const Duration(seconds: 5);
    _armHeartbeat(doubled > padded ? doubled : padded);
  }

  void _rejectAll(Object error) {
    final pending = List.of(_pending.entries);
    _pending.clear();
    for (final e in pending) {
      if (!e.value.isCompleted) e.value.completeError(error);
    }
  }

  void _setState(OneBotState s, {String? reason}) {
    if (_state == s && reason == null) return;
    _state = s;
    _emit(OneBotStateChanged(s, reason: reason));
  }

  void _emit(OneBotEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _log(String level, String message, [Object? detail]) {
    onLog?.call(level, message, detail);
  }

  /// 释放资源。与 [close] 的区别：不等待 socket 关闭完成。
  void dispose() {
    _heartbeatTimer?.cancel();
    _retryTimer?.cancel();
    _rejectAll(OneBotApiException('*', '客户端已释放'));
    unawaited(_sub?.cancel());
    unawaited(_socket?.close());
    unawaited(_events.close());
  }
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

/// 宽松地把 JSON 里的数字取成 int（部分实现会返回字符串）。
int? _asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}
