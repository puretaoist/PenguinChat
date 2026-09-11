/// L3 客户端 API 层：把 [Session] 与 [ChatStore] 接给 UI 的 Riverpod 接线
///
/// ## 为什么这里用 `package:riverpod` 而不是 `flutter_riverpod`
///
/// `AGENTS.md` §1.1 把「`lib/client_api/` 是纯 Dart、不得 import Flutter」
/// 定为硬性纪律，而 `flutter_riverpod` 会拉进 Flutter。两者不是两套状态管理：
/// `flutter_riverpod` = `riverpod` + Flutter 绑定，provider 对象是同一批，
/// L4 用 `ProviderScope` / `ConsumerWidget` 就能消费本文件定义的 provider。
///
/// ## 职责
///
/// - [connectionConfigProvider]：地址/令牌，落盘在 `<dataDir>/connection.json`
/// - [connectionControllerProvider]：拥有 Session 与 ChatStore 的生命周期，
///   连接必须先过 [SafetyGate]（本层不自己判断风险，见 `SAFETY.md`）
/// - [chatsProvider] / [messagesProvider]：UI 直接 watch 的数据
///
/// 平台相关的东西（数据目录、适配表、闸门实例）由 `main.dart` 通过
/// `ProviderScope.overrides` 注入——L3 不碰 `path_provider` / `rootBundle`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../infra/log/logger.dart';
import '../kernel/onebot/backend_profile.dart';
import '../kernel/onebot/onebot_client.dart';
import '../kernel/onebot/onebot_session.dart';
import '../kernel/safety/safety_gate.dart';
import 'chat_store.dart';
import 'objects.dart';
import 'session.dart';

final _log = Log.get('Providers');

/// NapCat 默认的 WebSocket 端口（OneBot 11 约定）。
const String kDefaultOneBotAddress = 'ws://127.0.0.1:3001';

/// 地址是否指向本机。
///
/// 闸门判定与连接页的提示都走这一个函数：两处各写一套规则迟早会漂移，
/// 而"哪边算本机"直接决定要不要走风险确认，不能有两份答案。
bool isLoopbackAddress(String address) {
  final uri = Uri.tryParse(address.trim());
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  return host == '127.0.0.1' ||
      host == 'localhost' ||
      host == '::1' ||
      host == '[::1]' ||
      host == '0.0.0.0';
}

// ---------------------------------------------------------------------------
// 平台注入点
// ---------------------------------------------------------------------------

/// 应用私有数据目录。**必须**由 `main.dart` override。
final dataDirProvider = Provider<Directory>(
  (ref) => throw UnimplementedError(
      'dataDirProvider 未注入：请在 ProviderScope.overrides 里提供应用私有目录'),
);

/// 后端适配表。**必须**由 `main.dart` override（L4 从 asset bundle 读 JSON）。
final backendRegistryProvider = Provider<BackendProfileRegistry>(
  (ref) => throw UnimplementedError(
      'backendRegistryProvider 未注入：请在 main.dart 里从 assets/backends/ 加载'),
);

/// 安全闸门。默认无持久化；`main.dart` 应注入带 persistFile 且已 load 的实例。
final safetyGateProvider = Provider<SafetyGate>((ref) => SafetyGate());

// ---------------------------------------------------------------------------
// 连接配置
// ---------------------------------------------------------------------------

/// 连接配置（可持久化的那部分）。
class ConnectionConfig {
  final String address;

  /// 访问令牌；空串表示后端未开鉴权。
  final String accessToken;

  /// true 走 `Authorization: Bearer`，false 走 `?access_token=`。
  final bool tokenInHeader;

  const ConnectionConfig({
    this.address = kDefaultOneBotAddress,
    this.accessToken = '',
    this.tokenInHeader = false,
  });

  bool get hasToken => accessToken.isNotEmpty;

  ConnectionConfig copyWith({
    String? address,
    String? accessToken,
    bool? tokenInHeader,
  }) =>
      ConnectionConfig(
        address: address ?? this.address,
        accessToken: accessToken ?? this.accessToken,
        tokenInHeader: tokenInHeader ?? this.tokenInHeader,
      );

  /// 转成内核要的配置。超时与重连策略用内核默认值，UI 不暴露。
  OneBotConfig toOneBotConfig() => OneBotConfig(
        address: address,
        accessToken: hasToken ? accessToken : null,
        tokenInHeader: tokenInHeader,
      );

  Map<String, dynamic> toJson() => {
        'address': address,
        if (hasToken) 'token': accessToken,
        if (tokenInHeader) 'tokenInHeader': true,
      };

  static ConnectionConfig fromJson(Map<String, dynamic> j) => ConnectionConfig(
        address: (j['address'] as String?) ?? kDefaultOneBotAddress,
        accessToken: (j['token'] as String?) ?? '',
        tokenInHeader: j['tokenInHeader'] == true,
      );
}

/// 连接配置的读写。落盘选 `<dataDir>/connection.json` 而不是
/// `shared_preferences`：这里是 L3，必须保持纯 Dart 与可离线自测
/// （`shared_preferences` 依赖平台通道）。
class ConnectionConfigNotifier extends StateNotifier<ConnectionConfig> {
  ConnectionConfigNotifier(this._file) : super(const ConnectionConfig());

  final File _file;

  /// 从磁盘读回上次的配置。**不抛异常**：配置文件坏了大不了用默认值，
  /// 不该拦住启动（调用方通常不 await 它）。
  Future<void> load() async {
    try {
      if (!_file.existsSync()) return;
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is Map) {
        state = ConnectionConfig.fromJson(decoded.cast<String, dynamic>());
      }
    } catch (e) {
      _log.w('连接配置读取失败，用默认值', error: e);
    }
  }

  Future<void> update({
    String? address,
    String? accessToken,
    bool? tokenInHeader,
  }) async {
    state = state.copyWith(
      address: address?.trim(),
      accessToken: accessToken,
      tokenInHeader: tokenInHeader,
    );
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode(state.toJson()));
    } catch (e) {
      _log.w('连接配置写入失败', error: e);
    }
  }
}

final connectionConfigProvider =
    StateNotifierProvider<ConnectionConfigNotifier, ConnectionConfig>((ref) {
  final notifier = ConnectionConfigNotifier(
    File('${ref.watch(dataDirProvider).path}${Platform.pathSeparator}connection.json'),
  );
  // load() 内部已吞掉所有异常，这里不 await 不会产生未处理的异步错误
  unawaited(notifier.load());
  return notifier;
});

// ---------------------------------------------------------------------------
// 连接状态
// ---------------------------------------------------------------------------

/// 连接状态。`error` 放的是**错误原文**——OneBot 的排障全靠这句，不要替换成
/// 「连接失败」这类概括话术。
class ConnectionStatus {
  final SessionState sessionState;
  final AccountInfo? account;
  final String? backendName;
  final String? address;
  final String? error;
  final bool busy;

  const ConnectionStatus({
    this.sessionState = SessionState.disconnected,
    this.account,
    this.backendName,
    this.address,
    this.error,
    this.busy = false,
  });

  bool get isConnected => sessionState == SessionState.ready;

  String get stateLabel => switch (sessionState) {
        SessionState.disconnected => '未连接',
        SessionState.connecting => '连接中…',
        SessionState.ready => '已连接',
        SessionState.reconnecting => '重连中…',
        SessionState.closed => '已关闭',
      };

  @override
  String toString() => 'ConnectionStatus(${sessionState.name}'
      '${address == null ? '' : ', $address'}${error == null ? '' : ', error=$error'})';
}

/// 拥有 Session 与 ChatStore 的生命周期，并保证连接先过 [SafetyGate]。
class ConnectionController extends StateNotifier<ConnectionStatus> {
  ConnectionController({
    required this.dataDir,
    required this.profiles,
    required this.gate,
  }) : super(const ConnectionStatus());

  /// 应用私有数据目录（ChatStore 的落盘位置）。
  final Directory dataDir;

  /// 后端适配表。
  final BackendProfileRegistry profiles;

  /// 安全闸门。连接前必须过它。
  final SafetyGate gate;

  OneBotSession? _session;
  ChatStore? _store;
  StreamSubscription<SessionEvent>? _sub;

  /// 当前会话；未连接时为 null。
  Session? get session => _session;

  /// 当前数据层；未连接时为 null。
  ChatStore? get store => _store;

  /// 连接。任何失败都把**错误原文**放进 [ConnectionStatus.error] 并保持可用状态。
  Future<void> connect(ConnectionConfig config) async {
    if (state.busy) return;

    final rejected = await _passGate(config.address);
    if (rejected != null) {
      state = ConnectionStatus(address: config.address, error: rejected);
      return;
    }

    state = ConnectionStatus(
      sessionState: SessionState.connecting,
      address: config.address,
      busy: true,
    );

    try {
      await _teardown();

      final session = OneBotSession(
        client: OneBotClient(
          config: config.toOneBotConfig(),
          onLog: (level, message, [detail]) =>
              _log.i('[onebot/$level] $message${detail == null ? '' : ' · $detail'}'),
        ),
        profiles: profiles,
        onLog: (level, message, [detail]) =>
            _log.i('[session/$level] $message${detail == null ? '' : ' · $detail'}'),
      );
      _session = session;
      _sub = session.events.listen(
        _onEvent,
        onError: (Object e, StackTrace s) => _log.e('会话事件流错误', error: e, stack: s),
        cancelOnError: false,
      );

      await session.connect();

      final store = ChatStore(session: session, dataDir: dataDir);
      await store.bootstrap();
      _store = store;

      state = ConnectionStatus(
        sessionState: session.state,
        account: session.account,
        backendName: session.backendName,
        address: config.address,
      );
      _log.i('已连接后端 ${session.backendName}，账号=${session.account?.uin}');
    } catch (e) {
      // SocketException / WebSocketException / SessionException 都在这里落地：
      // 原文即排障线索，不做归纳。
      await _teardown();
      state = ConnectionStatus(address: config.address, error: '$e');
      _log.w('连接失败：$e');
    }
  }

  /// 主动断开。连接配置保留，方便重连。
  Future<void> disconnect() async {
    final address = state.address;
    await _teardown();
    state = ConnectionStatus(sessionState: SessionState.closed, address: address);
  }

  /// 供 provider 释放时调用：异步清理，且**绝不抛异常**
  /// （`ref.onDispose` 不会 await 它，抛出去就是未处理的异步错误）。
  Future<void> shutdown() async {
    try {
      await _teardown();
    } catch (e) {
      _log.w('释放连接时出错', error: e);
    }
  }

  /// 连接前的闸门检查。返回值是**拒绝原因**（null 表示放行）。
  ///
  /// 判定标准只看地址是不是本机，不自己发明风险等级：
  ///   - 本机（回环）→ 切到 [ConnectionMode.loopback]，与离线同级，无需同意
  ///   - 非本机 → 账号实际由远端进程驱动，必须已开启 [ConnectionMode.realServer]
  ///     且有当前版本的知情同意
  Future<String?> _passGate(String address) async {
    final uri = Uri.tryParse(address.trim());
    if (uri == null || !uri.hasAuthority || (uri.scheme != 'ws' && uri.scheme != 'wss')) {
      return '地址格式不对：需要 ws:// 或 wss:// 开头，例如 $kDefaultOneBotAddress';
    }
    if (isLoopbackAddress(address)) {
      await gate.setSafeMode(ConnectionMode.loopback);
      return null;
    }
    if (!gate.isRealServer) {
      return '要连非本机地址 ${uri.host}，需要先在「风险确认」里开启真实服务器模式：\n'
          '先做环境检测，再逐条确认 ${kRiskPoints.length} 项风险。';
    }
    if (!gate.hasValidConsent) {
      return '知情同意已失效（声明已更新到 $kConsentVersion），需要重新逐条确认。';
    }
    return null;
  }

  void _onEvent(SessionEvent event) {
    if (!mounted) return;
    final session = _session;
    if (session == null) return;
    // 只跟踪状态与错误；消息类事件由 ChatStore 消费，UI 若要展示通知/申请
    // 直接订阅 Session.events，不必经过这里。
    if (event is SessionStateChanged) {
      state = ConnectionStatus(
        sessionState: event.state,
        account: session.account,
        backendName: session.backendName,
        address: state.address,
        error: event.reason == null ? null : '${event.state.name}: ${event.reason}',
      );
    } else if (event is SessionFailure) {
      state = ConnectionStatus(
        sessionState: session.state,
        account: session.account,
        backendName: session.backendName,
        address: state.address,
        error: '${event.error}',
      );
    }
  }

  Future<void> _teardown() async {
    await _sub?.cancel();
    _sub = null;

    final store = _store;
    final session = _session;
    _store = null;
    _session = null;
    

    if (store != null) await store.dispose();
    if (session != null) {
      try {
        // OneBotSession.dispose 内部会连 client 一起释放，这里不重复关
        await session.dispose();
      } catch (e) {
        _log.w('释放会话失败', error: e);
      }
    }
  }
}

final connectionControllerProvider =
    StateNotifierProvider<ConnectionController, ConnectionStatus>((ref) {
  final controller = ConnectionController(
    dataDir: ref.watch(dataDirProvider),
    profiles: ref.watch(backendRegistryProvider),
    gate: ref.watch(safetyGateProvider),
  );
  // 热重载 / 退出时必须把 WS 连接与 ChatStore 一起收掉，否则连接会漏。
  // StateNotifier.dispose 是同步的，所以异步清理挂在这里（内部不抛异常）。
  ref.onDispose(controller.shutdown);
  return controller;
});

// ---------------------------------------------------------------------------
// UI 消费的数据
// ---------------------------------------------------------------------------

/// 当前会话实例；连接成功后才非 null。
final sessionProvider = Provider<Session?>((ref) {
  ref.watch(connectionControllerProvider); // 状态变化时重新求值
  return ref.read(connectionControllerProvider.notifier).session;
});

/// 数据层实例；连接成功后才非 null。
final chatStoreProvider = Provider<ChatStore?>((ref) {
  ref.watch(connectionControllerProvider);
  return ref.read(connectionControllerProvider.notifier).store;
});

/// 当前账号信息。
final accountProvider = Provider<AccountInfo?>(
  (ref) => ref.watch(sessionProvider)?.account,
);

/// 会话列表（UI 直接 watch 这个）。
final chatsProvider = StreamProvider<List<Chat>>((ref) async* {
  final store = ref.watch(chatStoreProvider);
  if (store == null) {
    yield const <Chat>[];
    return;
  }
  yield store.chats;
  yield* store.changes
      .where((c) => c.kind == ChatStoreChangeKind.chats)
      .map((_) => store.chats);
});

/// 某个会话的消息（时间正序）。
///
/// `autoDispose`：[ChatStore.changes] 是广播流，每个 family 实例都会挂一个
/// 订阅。不 autoDispose 的话，用户这辈子点开过的每个会话都会永久留着一条
/// 订阅（每次事件还要跑一遍 where/map）。离开页面就该还回去。
final messagesProvider =
    StreamProvider.autoDispose.family<List<ChatMessage>, String>((ref, chatId) async* {
  final store = ref.watch(chatStoreProvider);
  if (store == null) {
    yield const <ChatMessage>[];
    return;
  }
  yield store.messagesOf(chatId);
  yield* store.changes
      .where((c) =>
          c.kind == ChatStoreChangeKind.messages &&
          (c.chatId == null || c.chatId == chatId))
      .map((_) => store.messagesOf(chatId));
});
