/// OneBot 客户端离线自测
///
/// **不需要真实后端、不需要 QQ 账号**：脚本内起一个本地 mock WebSocket
/// 服务，覆盖以下路径：
///
///   1. 建连与 `echo` 关联
///   2. 并发调用不串号
///   3. 错误码 → 异常（含 retcode）
///   4. 调用超时
///   5. 断线时挂起请求被批量拒绝
///   6. 四类事件分发（message / notice / request / meta_event）
///   7. 未知 `post_type` 保留为 UnknownEvent
///   8. `meta_event.heartbeat` 自动调整看门狗阈值
///   9. 心跳超时 → 强制重连
///  10. 关闭码 1000 → 不重连
///  11. 关闭码 1006 → 自动重连
///  12. token 走查询参数 / 走 Authorization 头
///  13. 消息段解析辅助方法
///  14. `message_sent`（自己发的）标记
///
/// 运行：
/// ```bash
/// dart run tool/onebot_selftest.dart
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qqclient/kernel/onebot/onebot_client.dart';

// ---------------------------------------------------------------------------
// 断言工具
// ---------------------------------------------------------------------------

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  \u2713 $name');
  } else {
    _failed++;
    stdout.writeln('  \u2717 $name${detail == null ? '' : '  → $detail'}');
  }
}

void section(String title) => stdout.writeln('\n$title');

/// 等待某个事件出现，超时返回 null。
Future<T?> waitFor<T extends OneBotEvent>(
  Stream<OneBotEvent> stream,
  Duration timeout,
) async {
  try {
    return await stream
        .where((e) => e is T)
        .cast<T>()
        .first
        .timeout(timeout);
  } on TimeoutException {
    return null;
  }
}

Future<void> sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

/// 轮询等待某个条件成立。
///
/// ## 为什么必须用它，不能连用两次 `waitFor`
///
/// [waitFor] 的实现是 `stream.where(...).first`——**先订阅、再等下一个匹配事件**。
/// 如果两条事件在两次订阅之间都到达了，第二条就被永久漏掉。
///
/// 这类竞态在本机大概率不复现，在 CI 上却是必然的 flake：
/// 本地实测 15 次挂 1 次，而 CI 上第一次就撞上了。
///
/// 正确做法是**先订阅收集，再等条件**——条件是对已收到的集合求值，
/// 与到达时机无关。
Future<bool> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
  int stepMs = 5,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await sleep(stepMs);
  }
  return condition();
}

// ---------------------------------------------------------------------------
// mock OneBot 服务
// ---------------------------------------------------------------------------

class MockOneBot {
  late HttpServer _server;
  final List<WebSocket> sockets = [];
  final List<Map<String, dynamic>> received = [];
  final List<Uri> handshakeUris = [];
  final List<String?> authHeaders = [];

  /// 收到请求时的处理钩子；返回 false 表示测试自行接管（不自动回包）。
  bool Function(WebSocket ws, Map<String, dynamic> req)? onRequest;

  int connectCount = 0;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      handshakeUris.add(req.uri);
      authHeaders.add(req.headers.value('authorization'));
      final ws = await WebSocketTransformer.upgrade(req);
      connectCount++;
      sockets.add(ws);
      ws.listen(
        (data) => _handle(ws, data),
        onDone: () => sockets.remove(ws),
        onError: (_) => sockets.remove(ws),
        cancelOnError: false,
      );
    });
  }

  int get port => _server.port;
  String get address => 'ws://127.0.0.1:$port';

  void _handle(WebSocket ws, dynamic data) {
    final req = (jsonDecode(data as String) as Map).cast<String, dynamic>();
    received.add(req);
    final handled = onRequest?.call(ws, req);
    if (handled == false) return;
    reply(ws, req, {'ok': true});
  }

  /// 正常回包。
  void reply(WebSocket ws, Map<String, dynamic> req, Map<String, dynamic> data) {
    ws.add(jsonEncode({
      'status': 'ok',
      'retcode': 0,
      'data': data,
      'echo': req['echo'],
    }));
  }

  /// 回一个失败包。
  void replyError(WebSocket ws, Map<String, dynamic> req, int retcode, String msg) {
    ws.add(jsonEncode({
      'status': 'failed',
      'retcode': retcode,
      'msg': msg,
      'wording': msg,
      'data': null,
      'echo': req['echo'],
    }));
  }

  /// 推送一个事件（无 echo）。
  void push(Map<String, dynamic> event) {
    for (final ws in List.of(sockets)) {
      ws.add(jsonEncode(event));
    }
  }

  /// 等客户端连上来。
  Future<bool> waitForClient([int timeoutMs = 3000]) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      if (sockets.isNotEmpty) return true;
      await sleep(20);
    }
    return false;
  }

  /// 等收到第 n 个请求。
  Future<Map<String, dynamic>?> waitForRequest(int n, [int timeoutMs = 3000]) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      if (received.length >= n) return received[n - 1];
      await sleep(10);
    }
    return null;
  }

  /// 关掉当前所有连接，模拟对端**正常**关闭（关闭码 1000）。
  ///
  /// 传 [code] 可模拟异常关闭（如 1006），用于验证客户端的分级重连策略。
  Future<void> dropAll([int code = 1000]) async {
    for (final ws in List.of(sockets)) {
      await ws.close(code, 'mock close');
    }
    sockets.clear();
  }

  Future<void> stop() async {
    for (final ws in List.of(sockets)) {
      await ws.close();
    }
    await _server.close(force: true);
  }
}

/// 建 mock 服务 + 客户端，跑完 [body] 后自动清理。
Future<void> withClient(
  Future<void> Function(MockOneBot server, OneBotClient client) body, {
  OneBotConfig Function(String address)? configOf,
  bool connect = true,
}) async {
  final server = MockOneBot();
  await server.start();
  final client = OneBotClient(
    config: (configOf ?? (a) => OneBotConfig(address: a))(server.address),
  );
  try {
    if (connect) {
      await client.connect();
      await server.waitForClient();
    }
    await body(server, client);
  } finally {
    await client.close();
    await server.stop();
  }
}

// ---------------------------------------------------------------------------
// 各测试组
// ---------------------------------------------------------------------------

Future<void> testEchoCorrelation() async {
  section('1. 建连与 echo 关联');
  await withClient((server, client) async {
    check('连接后状态为 connected', client.isConnected);

    // 关掉自动回包，本组测试自己按捕获到的 echo 回，才能验证关联逻辑
    server.onRequest = (ws, req) => false;

    final pending = client.call('get_login_info');
    final req = await server.waitForRequest(1);
    if (req == null) {
      check('请求已发出', false);
      return;
    }
    check('请求动作正确', req['action'] == 'get_login_info');
    check('请求带 echo', req['echo'] is String && (req['echo'] as String).isNotEmpty);

    server.reply(server.sockets.first, req, {'user_id': 10001, 'nickname': '测试号'});

    final resp = (await pending) as Map<String, dynamic>;
    check('回包能被 echo 关联到调用者', resp['user_id'] == 10001);
    check('回包内容完整', resp['nickname'] == '测试号');
    check('挂起表已清空', client.pendingCalls == 0);
  });
}

Future<void> testConcurrentCalls() async {
  section('2. 并发调用不串号');
  await withClient((server, client) async {
    server.onRequest = (ws, req) => false; // 手动控制回包顺序

    final futures = <Future<Map<String, dynamic>>>[
      client.callMap('get_group_info', {'group_id': 111}),
      client.callMap('get_group_info', {'group_id': 222}),
    ];

    final req1 = await server.waitForRequest(1);
    final req2 = await server.waitForRequest(2);
    if (req1 == null || req2 == null) {
      check('两个请求都发出', false, 'req1=$req1 req2=$req2');
      return;
    }
    check('两个请求都发出', true);
    check('两次调用的 echo 互不相同', req1['echo'] != req2['echo']);

    // 逆序响应：先回第二个，再回第一个
    server.reply(server.sockets.first, req2, {'group_id': 222});
    await sleep(30);
    final second = await futures[1];
    check('先回来的那个归属正确', second['group_id'] == 222);

    server.reply(server.sockets.first, req1, {'group_id': 111});
    final first = await futures[0];
    check('后回来的那个没有被串号', first['group_id'] == 111);
    check('挂起表已清空', client.pendingCalls == 0);
  });
}

Future<void> testListData() async {
  section('2b. data 为数组的响应（回归用例）');

  await withClient((server, client) async {
    // OneBot 规范允许 data 是数组：get_friend_list / get_group_list 都是。
    // 早期实现把 data 强转 Map，会在这类 API 上直接抛类型错误。
    server.onRequest = (ws, req) {
      if (req['action'] == 'get_friend_list') {
        ws.add(jsonEncode({
          'status': 'ok',
          'retcode': 0,
          'data': [
            {'user_id': 1, 'nickname': 'a'},
            {'user_id': 2, 'nickname': 'b'},
          ],
          'echo': req['echo'],
        }));
        return false;
      }
      return true;
    };

    final data = await client.call('get_friend_list');
    check('数组型 data 原样返回（不被强转）', data is List, '实际 ${data.runtimeType}');
    check('数组内容可用', data is List && data.length == 2);
    check('数组元素是 Map',
        data is List && data.isNotEmpty && data.first is Map);

    // callMap 是"要求对象"的便捷方法，对数组应显式报错而不是静默
    var threw = false;
    try {
      await client.callMap('get_friend_list');
    } on OneBotApiException {
      threw = true;
    }
    check('callMap 对数组型 data 显式报错', threw);

    // data 为 null 时 callMap 返回空对象
    server.onRequest = (ws, req) {
      ws.add(jsonEncode({'status': 'ok', 'retcode': 0, 'data': null, 'echo': req['echo']}));
      return false;
    };
    final empty = await client.callMap('whatever');
    check('data 为 null 时 callMap 返回空对象', empty.isEmpty);

    final raw = await client.call('whatever');
    check('data 为 null 时 call 返回 null', raw == null);
  });
}

Future<void> testErrorAndTimeout() async {
  section('3-4. 错误码与超时');
  await withClient((server, client) async {
    server.onRequest = (ws, req) {
      if (req['action'] == 'boom') {
        server.replyError(ws, req, 102, '操作失败');
        return false;
      }
      if (req['action'] == 'silent') return false; // 永不回包 → 触发超时
      return true;
    };

    Object? caught;
    try {
      await client.call('boom');
    } on OneBotApiException catch (e) {
      caught = e;
    }
    check('失败包抛出 OneBotApiException', caught is OneBotApiException);
    check('异常携带 retcode', caught is OneBotApiException && caught.retcode == 102);
    check('异常携带原因', caught is OneBotApiException && caught.message.contains('操作失败'));

    Object? timeoutCaught;
    try {
      await client.call('silent');
    } on OneBotApiException catch (e) {
      timeoutCaught = e;
    }
    check('超时抛出 OneBotApiException', timeoutCaught is OneBotApiException);
    check('超时后挂起表清空', client.pendingCalls == 0);

    // tryCall 不抛异常
    final nullResult = await client.tryCall('silent');
    check('tryCall 把失败吞成 null', nullResult == null);
  }, configOf: (a) => OneBotConfig(
        address: a,
        callTimeout: const Duration(milliseconds: 300),
      ));
}

Future<void> testPendingRejectedOnDisconnect() async {
  section('5. 断线时挂起请求被批量拒绝');
  await withClient((server, client) async {
    server.onRequest = (ws, req) => false; // 永不回包，制造挂起

    final pending = client.call('never');
    // ⚠️ 必须在挂起之后**立刻**挂上错误监听。
    // 如果它先以错误完成而我们还没 await，Dart 会把「未处理的异步错误」
    // 抛到根 zone，直接把进程打挂（表现为自带测莫名退出）。
    final guarded =
        pending.then<Object?>((v) => v).catchError((Object e) => e);

    final req = await server.waitForRequest(1);
    check('请求已挂起', req != null && client.pendingCalls == 1);

    // 主动断开连接，挂起请求应被**立刻**拒绝，而不是等 10 秒超时
    final sw = Stopwatch()..start();
    await server.dropAll();
    final caught = await guarded;
    sw.stop();

    check('挂起请求被拒绝（未永久挂起）', caught is OneBotApiException,
        'caught=$caught pending=${client.pendingCalls}');
    check('拒绝是断线触发的，没有干等超时', sw.elapsedMilliseconds < 3000,
        '${sw.elapsedMilliseconds}ms');
  }, configOf: (a) => OneBotConfig(
        address: a,
        callTimeout: const Duration(seconds: 10),
        maxRetries: 0,
      ));
}

Future<void> testEventDispatch() async {
  section('6-7. 事件分发');
  await withClient((server, client) async {
    final seen = <String>[];
    final sub = client.events.listen((e) {
      seen.add(e.runtimeType.toString());
    });

    server.push({
      'post_type': 'message',
      'message_type': 'group',
      'group_id': 12345,
      'user_id': 10001,
      'message_id': 99,
      'time': 1700000000,
      'raw_message': 'hello',
      'sender': {'nickname': '小明', 'user_id': 10001},
      'message': [
        {'type': 'text', 'data': {'text': 'hello'}},
        {'type': 'image', 'data': {'file': 'a.jpg'}},
      ],
    });
    server.push({
      'post_type': 'notice',
      'notice_type': 'group_recall',
      'group_id': 12345,
      'user_id': 10001,
      'operator_id': 10001,
      'message_id': 99,
      'time': 1700000001,
    });
    server.push({
      'post_type': 'request',
      'request_type': 'friend',
      'user_id': 20002,
      'flag': 'flag-abc',
      'time': 1700000002,
    });
    server.push({
      'post_type': 'meta_event',
      'meta_event_type': 'heartbeat',
      'interval': 5000,
      'time': 1700000003,
      'status': {'online': true, 'good': true},
    });
    server.push({'post_type': 'totally_new_thing', 'foo': 1});

    await sleep(250);
    await sub.cancel();

    check('message 事件被分发', seen.contains('OneBotMessageEvent'));
    check('notice 事件被分发', seen.contains('OneBotNoticeEvent'));
    check('request 事件被分发', seen.contains('OneBotRequestEvent'));
    check('meta_event 被分发', seen.contains('OneBotMetaEvent'));
    check('未知 post_type 落到 UnknownEvent', seen.contains('OneBotUnknownEvent'));
  });
}

Future<void> testMessageEventParsing() async {
  section('13-14. 消息事件字段解析');
  await withClient((server, client) async {
    // 先订阅收集，再推事件。**不能**用两次 waitFor：
    // 两条事件背靠背到达时，第二次订阅会错过已经过去的那个。
    final got = <OneBotMessageEvent>[];
    final sub = client.events
        .where((e) => e is OneBotMessageEvent)
        .cast<OneBotMessageEvent>()
        .listen(got.add);
    try {
      server.push({
        'post_type': 'message',
        'message_type': 'group',
        'group_id': 555,
        'user_id': 666,
        'message_id': 777,
        'time': 1700000000,
        'raw_message': '[CQ:image,file=a.jpg]',
        'sender': {'nickname': '小红'},
        'message': [
          {'type': 'text', 'data': {'text': 'hi'}},
          {'type': 'image', 'data': {'file': 'a.jpg'}},
        ],
      });
      server.push({
        'post_type': 'message_sent',
        'message_type': 'private',
        'user_id': 888,
        'message_id': 999,
        'time': 1700000001,
        'message': [
          {'type': 'text', 'data': {'text': '我发的'}},
        ],
      });

      await waitUntil(
        () =>
            got.any((e) => !e.isSelfSent) && got.any((e) => e.isSelfSent),
        timeout: const Duration(seconds: 3),
      );

      final group = got.where((e) => !e.isSelfSent).firstOrNull;
      final self = got.where((e) => e.isSelfSent).firstOrNull;

      check('两类事件都收到', group != null && self != null,
          '收到 ${got.length} 条');
      check('群消息 groupId 正确', group?.groupId == 555);
      check('群消息 userId 正确', group?.userId == 666);
      check('群消息段数组长度正确', group?.segments.length == 2);
      check('段类型解析正确', group?.segments[1]['type'] == 'image');
      check('raw_message 可用作搜索摘要',
          group?.rawMessage.contains('a.jpg') == true);
      check('sender 可提取昵称', group?.sender['nickname'] == '小红');
      check('message_sent 被标记为自己发的', self?.isSelfSent == true);
      check('message_sent 的 messageType 正确', self?.messageType == 'private');
    } finally {
      await sub.cancel();
    }
  });
}

Future<void> testHeartbeat() async {
  section('8-9. 心跳看门狗');
  await withClient((server, client) async {
    // 8: heartbeat 上报 interval 后，看门狗阈值应被调整（不早于 2×interval）
    server.push({
      'post_type': 'meta_event',
      'meta_event_type': 'heartbeat',
      'interval': 1000,
      'time': 1700000000,
    });
    await sleep(100);
    check('收到心跳后连接仍在', client.isConnected);

    // 9: 之后不再有任何数据，看门狗应在 max(2s, 6s)=6s 后判定假死
    //    为节省测试时间改用 200ms interval → 阈值 max(400ms, 5.2s) = 5.2s
    server.push({
      'post_type': 'meta_event',
      'meta_event_type': 'heartbeat',
      'interval': 200,
      'time': 1700000001,
    });
    // 用显式可空变量 + try/catch，避免 catchError 的返回类型契约问题
    OneBotStateChanged? evt;
    try {
      evt = await client.events
          .where((e) => e is OneBotStateChanged && e.state != OneBotState.connected)
          .cast<OneBotStateChanged>()
          .first
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      evt = null;
    }
    check('无数据后看门狗触发重连', evt != null, 'event=$evt');
  }, configOf: (a) => OneBotConfig(
        address: a,
        heartbeatTimeout: const Duration(seconds: 30),
        maxRetries: 1,
        retryBaseDelay: const Duration(milliseconds: 100),
      ));
}

Future<void> testCloseCodePolicy() async {
  section('10-11. 关闭码分级');
  // 1000 正常关闭 → 不重连
  await withClient((server, client) async {
    final before = server.connectCount;
    await server.dropAll();
    await sleep(400);
    check('关闭码 1000 不触发重连',
        server.connectCount == before || client.state == OneBotState.disconnected,
        'connectCount=$before→${server.connectCount} state=${client.state.name}');
  }, configOf: (a) => OneBotConfig(
        address: a,
        maxRetries: 3,
        retryBaseDelay: const Duration(milliseconds: 50),
      ));

  // 异常关闭 → 自动重连（用 forceReconnect 模拟 1006 路径）
  await withClient((server, client) async {
    final before = server.connectCount;
    client.forceReconnect('测试异常断线');
    // 等条件而不是等固定时长：CI 机器比本机慢，600ms 里重连未必来得及完成，
    // 固定 sleep 会变成只在 CI 上挂的 flake。
    final ok = await waitUntil(
      () => server.connectCount > before,
      timeout: const Duration(seconds: 5),
    );
    check('异常断线后自动重连', ok, 'connectCount=$before→${server.connectCount}');
  }, configOf: (a) => OneBotConfig(
        address: a,
        maxRetries: 3,
        retryBaseDelay: const Duration(milliseconds: 50),
      ));
}

Future<void> testAuth() async {
  section('12. 鉴权参数位置');
  // 查询参数（默认）
  await withClient((server, client) async {
    await client.call('get_status');
    check('token 默认拼进查询参数',
        server.handshakeUris.first.queryParameters['access_token'] == 'secret-token');
  }, configOf: (a) => OneBotConfig(address: a, accessToken: 'secret-token'));

  // Authorization 头
  await withClient((server, client) async {
    await client.call('get_status');
    check('tokenInHeader=true 时走 Authorization 头',
        server.authHeaders.first == 'Bearer secret-token');
    check('此时不再重复拼查询参数',
        server.handshakeUris.first.queryParameters['access_token'] == null);
  }, configOf: (a) => OneBotConfig(
        address: a,
        accessToken: 'secret-token',
        tokenInHeader: true,
      ));

  // 无 token
  await withClient((server, client) async {
    check('无 token 时不带参数也不带头',
        server.handshakeUris.first.queryParameters.isEmpty &&
            server.authHeaders.first == null);
  });
}

Future<void> testNotConnectedFastFail() async {
  section('附. 未连接时快速失败');
  final server = MockOneBot();
  await server.start();
  final client = OneBotClient(config: OneBotConfig(address: server.address));
  try {
    Object? caught;
    try {
      await client.call('get_login_info');
    } on OneBotApiException catch (e) {
      caught = e;
    }
    check('未连接调用立即失败而非挂起',
        caught is OneBotApiException && client.pendingCalls == 0);
  } finally {
    client.dispose();
    await server.stop();
  }
}

// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('OneBot 客户端离线自测（mock WebSocket 服务）');
  stdout.writeln('=' * 56);

  await testEchoCorrelation();
  await testConcurrentCalls();
  await testListData();
  await testErrorAndTimeout();
  await testPendingRejectedOnDisconnect();
  await testEventDispatch();
  await testMessageEventParsing();
  await testHeartbeat();
  await testCloseCodePolicy();
  await testAuth();
  await testNotConnectedFastFail();

  stdout.writeln('\n${'=' * 56}');
  stdout.writeln('通过 $_passed 项，失败 $_failed 项');
  exitCode = _failed == 0 ? 0 : 1;
  exit(_failed == 0 ? 0 : 1);
}
