/// OneBotSession 端到端离线自测
///
/// **不需要真实后端、不需要 QQ 账号**：脚本内起一个 mock OneBot 服务，
/// 按 NapCat / Lagrange 两种真实的响应结构，验证「登录 → 会话列表 → 历史
/// 消息 → 收发 → 撤回 → 能力探测」整条链路。
///
/// 这是 Step 4 的验收：第一次证明**客户端真的能聊天**（用假后端）。
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/session_selftest.dart
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qqclient/client_api/objects.dart';
import 'package:qqclient/client_api/segment.dart';
import 'package:qqclient/client_api/session.dart';
import 'package:qqclient/kernel/onebot/backend_profile.dart';
import 'package:qqclient/kernel/onebot/onebot_client.dart';
import 'package:qqclient/kernel/onebot/onebot_session.dart';

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

void checkEq(String name, Object? actual, Object? expected) {
  final ok = jsonEncode(actual) == jsonEncode(expected);
  check(name, ok, ok ? null : '期望 ${jsonEncode(expected)}，实际 ${jsonEncode(actual)}');
}

void section(String t) => stdout.writeln('\n$t');

Future<void> sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

// ---------------------------------------------------------------------------
// mock OneBot 后端
// ---------------------------------------------------------------------------

class MockBackend {
  late HttpServer _server;
  final List<WebSocket> sockets = [];
  final List<Map<String, dynamic>> received = [];

  /// 上报给客户端的 `app_name`，决定客户端选哪张适配表。
  String appName = 'NapCat.Onebot';

  /// 自定义响应；返回 null 表示走默认路由。
  /// OneBot 的 `data` 既可能是对象（`get_login_info`）也可能是数组
  /// （`get_friend_list`），所以这里是 Object 而不是 Map。
  Object? Function(String action, Map<String, dynamic> params)? override;

  int connectCount = 0;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      connectCount++;
      sockets.add(ws);
      ws.listen(
        (data) {
          final msg = (jsonDecode(data as String) as Map).cast<String, dynamic>();
          received.add(msg);
          if (msg['echo'] == null) return;
          final action = msg['action'] as String? ?? '';
          final params = (msg['params'] as Map?)?.cast<String, dynamic>() ?? const {};
          final data2 = override?.call(action, params) ?? _default(action, params);
          ws.add(jsonEncode({
            'status': 'ok',
            'retcode': 0,
            'data': data2,
            'echo': msg['echo'],
          }));
        },
        onDone: () => sockets.remove(ws),
        onError: (_) => sockets.remove(ws),
        cancelOnError: false,
      );
    });
  }

  String get address => 'ws://127.0.0.1:${_server.port}';

  /// 默认路由：按 NapCat 的真实响应结构返回（注意与 Lagrange 的差异）。
  Object _default(String action, Map<String, dynamic> params) {
    switch (action) {
      case 'get_version_info':
        return {
          'app_name': appName,
          'app_version': '4.15.0',
          'protocol_version': '11',
          'runtime_os': 'windows',
        };
      case 'get_login_info':
        return {'user_id': 10001, 'nickname': '我的测试号'};
      case 'get_status':
        return {'online': true, 'good': true};

      // NapCat：好友按分组嵌套
      case 'get_friends_with_category':
        return [
          {
            'categoryId': 0,
            'categoryName': '我的好友',
            'categorySortId': 1,
            'buddyList': [
              {'user_id': 20002, 'nickname': '小明', 'remark': '', 'longNick': 'hi'},
              {'user_id': 20003, 'nickname': '小红', 'remark': '同事', 'longNick': ''},
            ],
          },
        ];
      // Lagrange：好友平铺
      case 'get_friend_list':
        return [
          {'user_id': 20002, 'nickname': '小明', 'remark': ''},
          {'user_id': 20003, 'nickname': '小红', 'remark': '同事'},
        ];

      case 'get_group_list':
        return [
          {'group_id': 12345, 'group_name': '测试群', 'member_count': 42},
        ];

      case 'get_group_msg_history':
      case 'get_friend_msg_history':
        return {
          'messages': [
            {
              'message_id': 103,
              'real_seq': '503',
              'target_id': 12345,
              'message_type': 'group',
              'time': 1700000300,
              'post_type': 'message',
              'group_id': 12345,
              'sender': {'user_id': 20002, 'nickname': '小明'},
              'message': [
                {'type': 'text', 'data': {'text': '最新一条'}},
              ],
              'raw_message': '最新一条',
            },
            {
              'message_id': 102,
              'real_seq': '502',
              'target_id': 12345,
              'message_type': 'group',
              'time': 1700000200,
              'post_type': 'message',
              'group_id': 12345,
              'sender': {'user_id': 10001, 'nickname': '我的测试号'},
              'message': [
                {'type': 'text', 'data': {'text': '我自己发的'}},
              ],
              'raw_message': '我自己发的',
            },
            {
              'message_id': 101,
              'real_seq': '501',
              'target_id': 12345,
              'message_type': 'group',
              'time': 1700000100,
              'post_type': 'message',
              'group_id': 12345,
              'sender': {'user_id': 20003, 'card': '小红群名片', 'nickname': '小红'},
              'message': [
                {'type': 'text', 'data': {'text': '早上好 '}},
                {'type': 'at', 'data': {'qq': '10001'}},
                {'type': 'image', 'data': {'file': 'a.jpg', 'url': 'http://x/a.jpg'}},
              ],
              'raw_message': '早上好 [CQ:at,qq=10001][CQ:image,file=a.jpg]',
            },
          ],
        };

      case 'send_group_msg':
      case 'send_private_msg':
        return {'message_id': 90001};

      case 'delete_msg':
      case 'set_msg_emoji_like':
      case 'mark_group_msg_as_read':
      case 'mark_private_msg_as_read':
      case 'group_poke':
      case 'friend_poke':
        return const {};

      default:
        return const {};
    }
  }

  void push(Map<String, dynamic> event) {
    for (final ws in List.of(sockets)) {
      ws.add(jsonEncode(event));
    }
  }

  Future<bool> waitForClient([int timeoutMs = 3000]) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      if (sockets.isNotEmpty) return true;
      await sleep(20);
    }
    return false;
  }

  /// 等收到指定 action 的请求。
  Future<Map<String, dynamic>?> waitForAction(String action,
      [int timeoutMs = 3000]) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      for (final r in received) {
        if (r['action'] == action) return r;
      }
      await sleep(10);
    }
    return null;
  }

  Future<void> stop() async {
    for (final ws in List.of(sockets)) {
      await ws.close();
    }
    await _server.close(force: true);
  }
}

// ---------------------------------------------------------------------------

BackendProfileRegistry loadRegistry() {
  final dir = Directory('assets/backends');
  if (!dir.existsSync()) {
    stderr.writeln('找不到 assets/backends/，请在工程根目录运行本脚本');
    exit(2);
  }
  return BackendProfileRegistry.fromJsonStrings(dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .map((f) => f.readAsStringSync()));
}

/// 起 mock 后端 + 会话，跑完自动清理。
Future<void> withSession(
  Future<void> Function(MockBackend backend, OneBotSession session) body, {
  String appName = 'NapCat.Onebot',
  bool connect = true,
}) async {
  final backend = MockBackend()..appName = appName;
  await backend.start();

  final client = OneBotClient(
    config: OneBotConfig(
      address: backend.address,
      callTimeout: const Duration(seconds: 5),
      maxRetries: 0,
    ),
  );
  final session = OneBotSession(client: client, profiles: loadRegistry());

  try {
    if (connect) {
      await session.connect();
      await backend.waitForClient();
    }
    await body(backend, session);
  } finally {
    await session.dispose();
    await backend.stop();
  }
}

// ---------------------------------------------------------------------------
// 1. 握手
// ---------------------------------------------------------------------------

Future<void> testHandshake() async {
  section('1. 握手：探版本 → 选适配表 → 取登录信息');

  await withSession((backend, session) async {
    check('状态为 ready', session.state == SessionState.ready, session.state.name);
    check('登录信息已就绪', session.account != null);
    checkEq('账号 uin', session.account?.uin, '10001');
    checkEq('昵称', session.account?.nickname, '我的测试号');
    checkEq('后端标识', session.backendName, 'NapCat.Onebot');
    checkEq('协议版本透传', session.account?.protocolVersion, '11');

    // 握手顺序：先裸调 get_version_info，再走表
    check('发出了 get_version_info',
        backend.received.any((r) => r['action'] == 'get_version_info'));
    check('发出了 get_login_info',
        backend.received.any((r) => r['action'] == 'get_login_info'));

    // 幂等
    await session.connect();
    check('connect 幂等（不重复握手）',
        backend.received.where((r) => r['action'] == 'get_version_info').length == 1);
  });

  // 未知后端 → 回落兜底表，不应崩溃
  await withSession((backend, session) async {
    check('未知后端仍可用（回落兜底表）', session.state == SessionState.ready);
    checkEq('回落到 NapCat 表', session.backendName, 'NapCat.Onebot');
  }, appName: 'SomeBrandNewBot');
}

// ---------------------------------------------------------------------------
// 2. 会话列表
// ---------------------------------------------------------------------------

Future<void> testChatList() async {
  section('2. 会话列表');

  await withSession((backend, session) async {
    final chats = await session.listChats();
    check('拉到 3 个会话（2 好友 + 1 群）', chats.length == 3, 'len=${chats.length}');

    final private = chats.where((c) => !c.isGroup).toList();
    final groups = chats.where((c) => c.isGroup).toList();

    check('2 个私聊', private.length == 2);
    check('1 个群', groups.length == 1);

    checkEq('私聊复合 ID', private[0].id, 'private_20002');
    checkEq('私聊裸 ID', private[0].rawId, 20002);
    checkEq('无备注时用昵称', private[0].title, '小明');
    checkEq('有备注时优先备注', private[1].title, '同事');

    checkEq('群复合 ID', groups[0].id, 'group_12345');
    checkEq('群名', groups[0].title, '测试群');
    checkEq('群成员数', groups[0].memberCount, 42);
    check('群类型正确', groups[0].type == ChatType.group);
  });

  // 换成 Lagrange：好友来自另一个 action、另一套字段名
  await withSession((backend, session) async {
    final chats = await session.listChats();
    final private = chats.where((c) => !c.isGroup).toList();
    check('Lagrange 也能拉到 2 个好友', private.length == 2, 'len=${private.length}');
    checkEq('Lagrange 好友昵称正确', private[0].title, '小明');
    check('Lagrange 走的是 get_friend_list',
        backend.received.any((r) => r['action'] == 'get_friend_list'));

    // 这是能力差异的直接体现
    check('Lagrange 不支持已读上报', !session.supports('set_message_read'));
    check('NapCat 特有的设置群名，Lagrange 支持', session.supports('set_group_name'));
  }, appName: 'Lagrange.OneBot');
}

// ---------------------------------------------------------------------------
// 3. 历史消息
// ---------------------------------------------------------------------------

Future<void> testHistory() async {
  section('3. 历史消息');

  await withSession((backend, session) async {
    final page = await session.fetchHistory('group_12345', count: 3);
    check('拉到 3 条', page.messages.length == 3, 'len=${page.messages.length}');

    // 按时间倒序（最新在前），不依赖后端返回顺序
    check('按时间倒序排列',
        page.messages[0].time.isAfter(page.messages[1].time) &&
            page.messages[1].time.isAfter(page.messages[2].time));

    final newest = page.messages[0];
    checkEq('最新一条文本', newest.text, '最新一条');
    checkEq('所属会话', newest.chatId, 'group_12345');
    checkEq('发送者昵称', newest.senderName, '小明');
    check('不是自己发的', !newest.outgoing);

    // 自己发的：靠 selfId 判定
    check('自己发的被标记 outgoing', page.messages[1].outgoing);

    // 第三老的：多段 + 群名片 + @我
    final old = page.messages[2];
    checkEq('群名片优先于昵称', old.senderName, '小红群名片');
    check('多段消息解析正确', old.segments.length == 3, 'len=${old.segments.length}');
    check('@我 被判定', old.atMe);
    check('含图片段 → 标记含媒体', old.hasMedia);
    checkEq('纯文本摘要', old.text, '早上好 @10001[图片]');

    // 分页游标
    check('返回条数 == 请求数 → 给出续页游标', page.hasMore);
    checkEq('游标带 message_id', page.next?.messageId, '101');
    checkEq('游标带群序号（来自适配表的 seq 字段）', page.next?.seq, 501);

    // 请求参数正确
    final req = await backend.waitForAction('get_group_msg_history');
    checkEq('历史请求带 group_id',
        (req?['params'] as Map?)?['group_id'], 12345);
    checkEq('历史请求带 count', (req?['params'] as Map?)?['count'], 3);

    // 私聊走 private_action
    await session.fetchHistory('private_20002', count: 2);
    check('私聊历史走 get_friend_msg_history',
        backend.received.any((r) => r['action'] == 'get_friend_msg_history'));
  });
}

// ---------------------------------------------------------------------------
// 4. 发送消息
// ---------------------------------------------------------------------------

Future<void> testSend() async {
  section('4. 发送消息');

  await withSession((backend, session) async {
    final id = await session.sendMessage('group_12345', const [
      TextSegment('你好 '),
      AtSegment('20002', name: '小明'),
      ImageSegment('local.jpg'),
    ]);

    checkEq('返回 message_id', id, '90001');

    final req = await backend.waitForAction('send_group_msg');
    check('走 send_group_msg', req != null);
    checkEq('带 group_id', (req?['params'] as Map?)?['group_id'], 12345);

    final message = ((req!['params'] as Map)['message'] as List).cast<Map>();
    checkEq('发出了 3 段', message.length, 3);
    checkEq('段 0 是 text', message[0]['type'], 'text');
    checkEq('段 0 内容', (message[0]['data'] as Map)['text'], '你好 ');
    checkEq('段 1 是 at', message[1]['type'], 'at');
    checkEq('段 1 目标', (message[1]['data'] as Map)['qq'], '20002');
    checkEq('段 2 是 image', message[2]['type'], 'image');

    // 私聊
    await session.sendMessage('private_20002', const [TextSegment('在吗')]);
    check('私聊走 send_private_msg',
        backend.received.any((r) => r['action'] == 'send_private_msg'));

    // 空消息应被拒绝
    var threw = false;
    try {
      await session.sendMessage('group_12345', const []);
    } on SessionException {
      threw = true;
    }
    check('空消息被拒绝', threw);

    // 非法会话 ID
    threw = false;
    try {
      await session.sendMessage('garbage', const [TextSegment('x')]);
    } on SessionException {
      threw = true;
    }
    check('非法会话 ID 被拒绝', threw);
  });
}

// ---------------------------------------------------------------------------
// 5. 收消息事件
// ---------------------------------------------------------------------------

Future<void> testIncomingEvents() async {
  section('5. 收消息 / 多端同步 / 撤回');

  await withSession((backend, session) async {
    final events = <SessionEvent>[];
    final sub = session.events.listen(events.add);

    // 对方发来的群消息
    backend.push({
      'post_type': 'message',
      'message_type': 'group',
      'self_id': 10001,
      'group_id': 12345,
      'user_id': 20002,
      'message_id': 200,
      'time': 1700001000,
      'sender': {'user_id': 20002, 'nickname': '小明'},
      'message': [
        {'type': 'text', 'data': {'text': '在吗'}},
        {'type': 'reply', 'data': {'id': '101', 'text': '早上好'}},
      ],
      'raw_message': '在吗',
    });

    // 自己在别的客户端发的（多端同步）
    backend.push({
      'post_type': 'message_sent',
      'message_type': 'group',
      'self_id': 10001,
      'group_id': 12345,
      'user_id': 10001,
      'message_id': 201,
      'time': 1700001001,
      'sender': {'user_id': 10001, 'nickname': '我的测试号'},
      'message': [
        {'type': 'text', 'data': {'text': '在的'}},
      ],
      'raw_message': '在的',
    });

    // 撤回通知
    backend.push({
      'post_type': 'notice',
      'notice_type': 'group_recall',
      'self_id': 10001,
      'group_id': 12345,
      'user_id': 20002,
      'operator_id': 20002,
      'message_id': 200,
      'time': 1700001002,
    });

    // 戳一戳
    backend.push({
      'post_type': 'notice',
      'notice_type': 'notify',
      'sub_type': 'poke',
      'self_id': 10001,
      'group_id': 12345,
      'user_id': 20002,
      'target_id': 10001,
      'time': 1700001003,
    });

    // 成员入群
    backend.push({
      'post_type': 'notice',
      'notice_type': 'group_increase',
      'self_id': 10001,
      'group_id': 12345,
      'user_id': 20009,
      'operator_id': 20002,
      'time': 1700001004,
    });

    // 好友申请
    backend.push({
      'post_type': 'request',
      'request_type': 'friend',
      'self_id': 10001,
      'user_id': 20010,
      'flag': 'flag-xyz',
      'comment': '我是隔壁老王',
      'time': 1700001005,
    });

    await sleep(300);
    await sub.cancel();

    final messages = events.whereType<SessionMessage>().toList();
    check('收到 2 条消息事件', messages.length == 2, 'len=${messages.length}');

    final incoming = messages.firstWhere((m) => !m.isEcho).message;
    checkEq('对方消息文本', incoming.text, '在吗');
    checkEq('会话 ID 正确', incoming.chatId, 'group_12345');
    checkEq('发送者 ID', incoming.senderId, '20002');
    check('对方消息 non-outgoing', !incoming.outgoing);
    checkEq('回复引用被提取', incoming.replyToId, '101');
    checkEq('回复摘要被提取', incoming.replyPreview, '早上好');

    final echo = messages.firstWhere((m) => m.isEcho).message;
    check('多端同步被标记为 outgoing', echo.outgoing);
    checkEq('同步消息文本', echo.text, '在的');

    final recalls = events.whereType<SessionMessageRecalled>().toList();
    check('收到撤回事件', recalls.length == 1);
    checkEq('撤回会话', recalls.first.chatId, 'group_12345');
    checkEq('撤回消息 ID', recalls.first.messageId, '200');
    checkEq('撤回操作者', recalls.first.operatorId, '20002');

    final notices = events.whereType<SessionNotice>().toList();
    check('戳一戳归一化为 poke',
        notices.any((n) => n.kind == 'poke' && n.chatId == 'group_12345'));
    check('入群归一化为 member_increase',
        notices.any((n) => n.kind == 'member_increase' && n.userId == '20009'));

    final requests = events.whereType<SessionRequest>().toList();
    check('收到好友申请', requests.length == 1);
    checkEq('申请类型', requests.first.kind, 'friend');
    checkEq('申请 flag', requests.first.flag, 'flag-xyz');
    checkEq('申请人', requests.first.userId, '20010');
  });
}

// ---------------------------------------------------------------------------
// 6. 撤回 / 已读 / 戳一戳
// ---------------------------------------------------------------------------

Future<void> testActions() async {
  section('6. 撤回 / 已读 / 戳一戳');

  await withSession((backend, session) async {
    await session.recall('group_12345', '200');
    final req = await backend.waitForAction('delete_msg');
    check('撤回走 delete_msg', req != null);
    checkEq('撤回参数为数字型 message_id',
        (req?['params'] as Map?)?['message_id'], 200);

    await session.markRead('group_12345', '200');
    check('已读走 mark_group_msg_as_read',
        backend.received.any((r) => r['action'] == 'mark_group_msg_as_read'));

    await session.sendPoke('group_12345', '20002');
    final poke = await backend.waitForAction('group_poke');
    check('群戳走 group_poke', poke != null);
    checkEq('戳一戳目标', (poke?['params'] as Map?)?['user_id'], 20002);

    await session.sendPoke('private_20002', '20002');
    check('私聊戳走 friend_poke',
        backend.received.any((r) => r['action'] == 'friend_poke'));

    // 非数字消息 ID 应被拒绝
    var threw = false;
    try {
      await session.recall('group_12345', 'not-a-number');
    } on SessionException {
      threw = true;
    }
    check('非法 message_id 被拒绝', threw);
  });

  // Lagrange：没有已读上报 → 显式失败且能力探测可提前发现
  await withSession((backend, session) async {
    check('能力探测：不支持 set_message_read',
        !session.supports('set_message_read'));

    var threw = false;
    try {
      await session.markRead('group_12345', '200');
    } on SessionException {
      threw = true;
    }
    check('不支持时 markRead 显式失败而非静默', threw);
    check('未发出已读请求',
        !backend.received.any((r) => (r['action'] as String).contains('as_read')));

    // 撤回仍可用
    await session.recall('group_12345', '200');
    check('Lagrange 撤回可用', backend.received.any((r) => r['action'] == 'delete_msg'));
  }, appName: 'Lagrange.OneBot');
}

// ---------------------------------------------------------------------------
// 7. 未就绪时的行为
// ---------------------------------------------------------------------------

Future<void> testNotReady() async {
  section('7. 未就绪时快速失败');

  await withSession((backend, session) async {
    check('未 connect 时状态为 disconnected',
        session.state == SessionState.disconnected);

    for (final op in <String, Future<void> Function()>{
      'listChats': () => session.listChats(),
      'fetchHistory': () => session.fetchHistory('group_1'),
      'sendMessage': () => session.sendMessage('group_1', const [TextSegment('x')]),
      'recall': () => session.recall('group_1', '1'),
      'sendPoke': () => session.sendPoke('group_1', '1'),
    }.entries) {
      var threw = false;
      try {
        await op.value();
      } on SessionException {
        threw = true;
      }
      check('未就绪时 ${op.key} 抛 SessionException', threw);
    }
  }, connect: false);
}

// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('OneBotSession 端到端离线自测（mock OneBot 后端）');
  stdout.writeln('=' * 64);

  await testHandshake();
  await testChatList();
  await testHistory();
  await testSend();
  await testIncomingEvents();
  await testActions();
  await testNotReady();

  stdout.writeln('\n${'=' * 64}');
  stdout.writeln('通过 $_passed 项，失败 $_failed 项');
  exit(_failed == 0 ? 0 : 1);
}
