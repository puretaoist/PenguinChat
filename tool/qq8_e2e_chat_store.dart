/// 端到端验证：把 ChatStore 挂在协议线（wlogin8）上，在**真服务器**上跑
///
/// 这个工具存在的唯一理由：三处真机修复（群消息收不到 / 群里发表情出现重复气泡 /
/// 断线不自愈）的单元级回归都在（tool/chat_store_selftest.dart 第 4b 节、
/// tool/qq8_session_adapter_selftest.dart、tool/qq8_login_service_selftest.dart 第 8 节），
/// 但从来没有一次「从登录到 ChatStore 的完整链路」在真服上被观测过。
///
/// ## 用法
///
/// QQ_LIVE_CONFIRM=I_UNDERSTAND_THE_RISK dart run tool/qq8_e2e_chat_store.dart \
///   --uin=2089495846 \
///   --token-file=C:/Users/Administrator/AppData/Local/Temp/e_tk_4.json \
///   --identity=../analysis/_ref/official-logs/identity-25091RP04C.json \
///   --gid=486045673 --send --text=/开枪 --heal
///
/// 参数：
///   --uin          必填，票据里那个号
///   --token-file   必填，tool/extract_tk_file.py 产出的 json
///   --identity     可选，真机身份 json（不给我就用 uin 派生身份，多半过不了）
///   --profile      可选，默认 8.2.11
///   --gid          可选，要验证的群号；不给就只做私聊/列表部分
///   --chat         可选，直接指定会话 ID（group_123 / private_456）
///   --send         可选，往会话里发一条表情（需要 QQ_LIVE_CONFIRM）
///   --text         可选，默认 /开枪
///   --heal         可选，主动掐掉传输层验断线自愈
///   --watch=N      可选，最后保持在线 N 秒，打印新到消息（给另一个号发言用）
///
/// ## 每一步对应哪处 fix
///
/// | 步骤 | 观测点 | 对应 fix |
/// |---|---|---|
/// | 2 列表 | ChatStore.chats 里有群 | 群入口存在 |
/// | 3 补种 | 服务端直取群历史拿到真消息 | 群历史链路 |
/// | 4 打开 | messagesOf(group_x) 非空 | 群消息能进 ChatStore |
/// | 5 发情 | 发完同文本只剩一条、ID 换成服务端 ID | 表情重复气泡 |
/// | 6 自愈 | 掐线后自动回到 ready 并继续能拉消息 | 断线不自愈 |
/// | 7 守望 | 另一个号发言能在 N 秒内出现 | 群消息轮询 |
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/client_api/chat_store.dart';
import 'package:qqclient/client_api/objects.dart';
import 'package:qqclient/client_api/qq8_login_service.dart';
import 'package:qqclient/client_api/qq8_session_adapter.dart';
import 'package:qqclient/client_api/segment.dart';
import 'package:qqclient/client_api/session.dart';
import 'package:qqclient/infra/log/log_file.dart';
import 'package:qqclient/infra/log/logger.dart';
import 'package:qqclient/kernel/safety/environment_probe.dart';
import 'package:qqclient/kernel/safety/safety_gate.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_profiles.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tran.dart';

const String kConfirmToken = 'I_UNDERSTAND_THE_RISK';

void out(String s) => stdout.writeln(s);
void errOut(String s) => stderr.writeln(s);

int _failed = 0;
int _passed = 0;

void check(String name, bool ok, [String? detail]) {
  final tail = detail == null ? '' : '（$detail）';
  if (ok) {
    _passed++;
    out('  ✓ $name$tail');
  } else {
    _failed++;
    out('  ✗ $name$tail');
  }
}

/// 内存票据存储：进来什么给什么，服务端轮换后的新票留在内存里。
class _MemTokenStore implements Qq8TokenStore {
  _MemTokenStore(this.data);
  Qq8TokenData? data;
  int saved = 0;

  @override
  Future<Qq8TokenData?> load(int uin) async => data;

  @override
  Future<void> save(Qq8TokenData d) async {
    data = d;
    saved++;
  }

  @override
  Future<void> clear(int uin) async {
    data = null;
  }

  @override
  Future<List<int>> listUins() async =>
      data == null ? const <int>[] : <int>[data!.uin];

  @override
  Future<DateTime?> lastModified(int uin) async => null;
}

/// 可掐断的传输层：dead=true 之后所有请求立刻失败，用来逼心跳走失败分支。
class _FlakyTransport implements Qq8Transport {
  _FlakyTransport(this.inner);
  final Qq8Transport inner;
  bool dead = false;

  @override
  Future<void> connect() async {
    if (dead) throw Qq8TransportException('传输层已被手动掐断');
    await inner.connect();
  }

  @override
  Future<Uint8List> send(Uint8List payload, {Duration? timeout}) async {
    if (dead) throw Qq8TransportException('传输层已被手动掐断');
    return inner.send(payload, timeout: timeout);
  }

  @override
  Future<void> write(Uint8List packet) async {
    if (dead) throw Qq8TransportException('传输层已被手动掐断');
    return inner.write(packet);
  }

  @override
  set onFrame(void Function(Uint8List frame)? cb) => inner.onFrame = cb;

  @override
  set onDisconnected(void Function(Object error)? cb) =>
      inner.onDisconnected = cb;

  @override
  Future<void> close() async {
    dead = true;
    await inner.close();
  }

  @override
  bool get isConnected => !dead && inner.isConnected;
}

Future<void> main(List<String> argv) async {
  final args = <String, String>{};
  for (final a in argv) {
    if (!a.startsWith('--')) continue;
    final i = a.indexOf('=');
    if (i < 0) {
      args[a.substring(2)] = 'true';
    } else {
      args[a.substring(2, i)] = a.substring(i + 1);
    }
  }

  final uin = int.tryParse(args['uin'] ?? '');
  final tokenPath = args['token-file'];
  if (uin == null) {
    errOut('✗ 必须给 --uin=<uin>');
    exit(2);
  }
  if (tokenPath == null || tokenPath.isEmpty) {
    errOut('✗ 必须给 --token-file=<path>（由 extract_tk_file.py 生成）');
    exit(2);
  }
  final wantSend = args.containsKey('send');
  if (wantSend && Platform.environment['QQ_LIVE_CONFIRM'] != kConfirmToken) {
    errOut('✗ --send 会真的往会话里发消息，必须显式确认：'
        'QQ_LIVE_CONFIRM="$kConfirmToken"');
    exit(2);
  }

  final gid = int.tryParse(args['gid'] ?? '');
  final chatArg = args['chat'];
  final text = args['text'] ?? '/开枪';
  final watchSeconds = int.tryParse(args['watch'] ?? '') ?? 0;
  final heal = args.containsKey('heal');
  // 每次 token 续期服务端都会换票据，旧票随即失效。不把新票存下来，
  // 下一轮实验就得重新从 tk_file 提一张——而 tk_file 是静态的，用一次少一张。
  final saveTokenPath = args['save-token'];

  final profile =
      qq8ClientProfiles[args['profile'] ?? '8.2.11'] ?? qq8DefaultProfile;

  // ---- 票据 ----
  final tf = File(tokenPath);
  if (!tf.existsSync()) {
    errOut('✗ 票据文件不存在：$tokenPath');
    exit(2);
  }
  final tokenJson = jsonDecode(tf.readAsStringSync()) as Map<String, dynamic>;
  final token = Qq8TokenData.fromJson(tokenJson);
  if (!token.usable) {
    errOut('✗ 票据不可用（d2/d2key 为空），这份 tk_file 里没有续期凭据');
    exit(2);
  }

  // ---- 身份 ----
  Qq8DeviceIdentity? identity;
  final identityPath = args['identity'];
  if (identityPath != null && identityPath.isNotEmpty) {
    final f = File(identityPath);
    if (!f.existsSync()) {
      errOut('✗ --identity 文件不存在：$identityPath');
      exit(2);
    }
    identity = Qq8DeviceIdentity.fromJson(
        Map<String, Object?>.from(jsonDecode(f.readAsStringSync()) as Map));
    if (identity == null) {
      errOut('✗ --identity 缺少必需项 android_id / mac');
      exit(2);
    }
  }

  final tmp = Directory.systemTemp.createTempSync('qq8e2e-');
  Log.configure(minLevel: LogLevel.info, ringCapacity: 4000);
  Log.addSink(FileLogSink(tmp));

  out('=' * 70);
  out('QQ8 端到端：ChatStore × 协议线 × 真服务器');
  out('  uin: $uin');
  out('  档案: ${profile.describe()}');
  out('  票据 tgt: ${token.tgt.length}B d2: ${token.d2.length}B '
      'd2key: ${token.d2key.length}B');
  final identityText =
      identity == null ? '按 uin 派生（多半过不了）' : '$identity';
  out('  身份: $identityText');
  out('  工作目录: ${tmp.path}');
  out('=' * 70);

  // ---- 安全闸门 ----
  final gate = SafetyGate();
  final gateErr = await gate.enableRealServer(
    <String>[
      '同意封禁与限制登录风险',
      '同意设备指纹（Qimei）相关风险',
      '不伪造、不绕过任何验证',
      '使用专门注册的测试账号',
      '不隐藏 native / libfekit 特征，用干净设备测',
    ],
    environment: EnvironmentReport(
      findings: const <EnvFinding>[],
      probedAt: DateTime.now(),
    ),
  );
  if (gateErr != null) {
    errOut('✗ 安全闸门打不开：$gateErr');
    exit(2);
  }

  // ---- 传输层：工具自己建，才掐得断 ----
  _FlakyTransport? active;
  Qq8Transport builder() {
    final t = _FlakyTransport(Qq8TcpTransport());
    active = t;
    return t;
  }

  final store = _MemTokenStore(token);
  final svc = Qq8LoginService(
    profile: profile,
    tokenStore: store,
    transportBuilder: builder,
    deviceBuilder:
        identity == null ? null : (int u) => Qq8Device.fromIdentity(identity!),
    qimei: identity?.qimei,
    gate: gate,
    heartbeatInterval: const Duration(seconds: 5),
    pullInterval: const Duration(seconds: 5),
    startupPullDelay: const Duration(seconds: 1),
  );

  final adapter = Qq8SessionAdapter(
    service: svc,
    uin: uin,
    label: 'wlogin8-e2e',
    onLog: (level, msg, [detail]) => out('    [adapter/$level] $msg'),
  );

  final states = <SessionState>[];
  final stateSub = adapter.events.listen((e) {
    if (e is SessionStateChanged) states.add(e.state);
  });

  final chats = ChatStore(session: adapter, dataDir: tmp);
  await chats.bootstrap();

  try {
    out('');
    out('--- 1. 登录并上线（token 续期）---');
    try {
      await adapter.connect();
    } on SessionException catch (e) {
      out('  ✗ 登录失败：${e.message}');
      out('  快照：stage=${svc.snapshot.stage.name} '
          'type=${svc.snapshot.resultType} err=${svc.snapshot.error}');
      _failed++;
      return;
    }
    check('登录并上线', adapter.state == SessionState.ready,
        'snapshot=${svc.snapshot.stage.name}');
    check('票据被服务端轮换（说明续期真的生效了）', store.saved > 0,
        'save 次数 ${store.saved}');
    if (saveTokenPath != null && saveTokenPath.isNotEmpty && store.data != null) {
      File(saveTokenPath)
          .writeAsStringSync(jsonEncode(store.data!.toJson()));
      out('  轮换后的新票已存到 $saveTokenPath（下一轮用它，别再用旧票）');
    }

    out('');
    out('--- 2. 会话列表（list_chats）---');
    await chats.refreshChats();
    final all = chats.chats;
    final groupChats = all.where((c) => c.isGroup).toList();
    final privateChats = all.where((c) => !c.isGroup).toList();
    out('  会话：${all.length} 个（群 ${groupChats.length} / '
        '好友 ${privateChats.length}）');
    check('会话列表非空（好友链路真的通了）', all.isNotEmpty, '${all.length} 个');
    check('里面至少有一个群', groupChats.isNotEmpty,
        groupChats.take(3).map((c) => c.title).join('、'));

    String? chatId = chatArg;
    if (chatId == null && gid != null) chatId = 'group_$gid';
    if (chatId == null && privateChats.isNotEmpty) {
      chatId = privateChats.first.id;
    }
    if (chatId == null) {
      out('  ✗ 没有任何可打开的会话，后面无从验证');
      _failed++;
      return;
    }
    final titles = all.where((c) => c.id == chatId).map((c) => c.title).toList();
    out('  目标会话：$chatId（${titles.isEmpty ? '未在列表里' : titles.first}）');

    final targetGid = gid ??
        int.tryParse(chatId.startsWith('group_') ? chatId.substring(6) : '');

    if (targetGid != null && targetGid > 0) {
      out('');
      out('--- 3. 群游标铺底 + 服务端直取群历史 ---');
      // primeGroups 是 refreshChats 里 fire-and-forget 发出去的，回来得晚；
      // 直接读会读到 null（第一次跑就是这么误判成「铺底失败」的）。
      var cursor = svc.debugGroupCursor(targetGid);
      if (cursor == null || cursor <= 0) {
        out('  游标还没铺好，显式补一次 primeGroups…');
        await svc.primeGroups(<int>[targetGid]);
        cursor = svc.debugGroupCursor(targetGid);
      }
      var waitedCursor = 0;
      while ((cursor == null || cursor <= 0) && waitedCursor < 10) {
        await Future<void>.delayed(const Duration(seconds: 1));
        waitedCursor++;
        cursor = svc.debugGroupCursor(targetGid);
      }
      out('  群 $targetGid 的游标：$cursor（额外等了 $waitedCursor 秒）');
      check('群游标已铺底（PbUnReadMsgSeq 拿到了水位）',
          cursor != null && cursor > 0, 'cursor=$cursor');

      if (cursor != null && cursor > 0) {
        final begin = cursor - 9 < 1 ? 1 : cursor - 9;
        final page = await svc.fetchGroupHistory(
          groupCode: targetGid,
          beginSeq: begin,
          endSeq: cursor,
        );
        out('  result=${page.result} 条数=${page.messages.length} '
            '区间=${page.returnBeginSeq}..${page.returnEndSeq}');
        for (final m in page.messages.take(5)) {
          out('    seq=${m.seq} ${m.fromUin}: ${m.brief()}');
        }
        check('服务端直取群历史拿到真消息', page.messages.isNotEmpty,
            'result=${page.result}');
      }

      out('');
      out('--- 4. 群消息进 ChatStore（推送/轮询路径）---');
      // 群历史「接口」通了不等于「界面能看到」：ChatStore 里的消息来自
      // Qq8LoginService 的群轮询推送（_emitGroupPage → Qq8MessagePush）。
      // 这里等它自己到，等不到就是轮询真的没工作。
      var waitedPush = 0;
      while (chats.messagesOf(chatId).isEmpty && waitedPush < 40) {
        await Future<void>.delayed(const Duration(seconds: 1));
        waitedPush++;
      }
      final pushed = chats.messagesOf(chatId);
      out('  等了 $waitedPush 秒，ChatStore 里 ${pushed.length} 条');
      for (final m in pushed.take(5)) {
        final who = m.outgoing ? '我' : m.senderName;
        out('    $who: ${m.text}');
      }
      check('群消息经轮询进了 ChatStore（群消息收不到那处 fix）',
          pushed.isNotEmpty, '${pushed.length} 条');

      out('');
      out('--- 4b. 打开会话后翻历史（fetch_history 路径）---');
      await chats.openChat(chatId);
      out('  openChat 后 ${chats.messagesOf(chatId).length} 条');
      final beforeMore = chats.messagesOf(chatId).length;
      try {
        await chats.loadMore(chatId);
        await Future<void>.delayed(const Duration(seconds: 2));
      } on Object catch (e) {
        out('  loadMore 抛错：$e');
      }
      final afterMore = chats.messagesOf(chatId).length;
      out('  loadMore 后 $beforeMore → $afterMore 条');
      check('会话打开后有消息', chats.messagesOf(chatId).isNotEmpty,
          '$afterMore 条');
      check('loadMore 没有把消息弄丢', afterMore >= beforeMore,
          '$beforeMore → $afterMore');
    }

    if (wantSend) {
      out('');
      out('--- 5. 发消息（表情重复气泡那处 fix）---');
      // 群轮询一直在往里塞新消息，所以计数只能比「同文本条目」，
      // 不能比总数（第一次跑就是拿总数比的，被同时到达的 19 条打成失败）。
      final before = chats.messagesOf(chatId).length;
      out('  发送前 $before 条；文本：$text');
      await chats.send(chatId, <Segment>[TextSegment(text)]);
      final local = chats.messagesOf(chatId).last;
      out('  乐观插入：id=${local.id} state=${local.sendState.name}');
      check('乐观插入立刻可见（+1 条）',
          chats.messagesOf(chatId).length >= before + 1,
          '$before → ${chats.messagesOf(chatId).length}');
      check('发送没有失败', local.sendState != MessageSendState.failed,
          local.sendState.name);

      var echoed = !local.id.startsWith('local:');
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!echoed && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final mine = chats
            .messagesOf(chatId)
            .where((m) => m.text == local.text)
            .toList();
        if (mine.length == 1 && !mine.single.id.startsWith('local:')) {
          echoed = true;
        }
      }
      final sameText = chats
          .messagesOf(chatId)
          .where((m) => m.text == local.text)
          .toList();
      out('  发送后同文本条目：${sameText.length} 条，'
          'ID：${sameText.map((m) => m.id).join(', ')}');
      check('没有产生重复气泡（同一条消息只有一条记录）', sameText.length == 1,
          '${sameText.length} 条');
      final echoDetail = echoed ? sameText.first.id : '仍是 ${local.id}';
      check('回显把本地 ID 换成了服务端 ID', echoed, echoDetail);
      check('消息没有丢（总数没变少）',
          chats.messagesOf(chatId).length >= before + 1,
          '$before → ${chats.messagesOf(chatId).length}');
    }

    if (heal) {
      out('');
      out('--- 6. 断线自愈（主动掐传输层）---');
      final t = active;
      if (t == null) {
        check('断线自愈', false, '还没有可用传输层');
      } else {
        states.clear();
        out('  掐断当前连接（心跳间隔 5s，最多要等两轮才判失败）…');
        t.dead = true;
        // 先等「真的掉了」。第一次跑漏了这一步，状态一直是 ready，
        // 循环进去立刻就 break，于是「自愈成功」是假阳性。
        final dropDeadline = DateTime.now().add(const Duration(seconds: 40));
        while (DateTime.now().isBefore(dropDeadline)) {
          if (adapter.state != SessionState.ready) break;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        final dropped = adapter.state != SessionState.ready;
        out('  现在的状态：${adapter.state.name}');
        check('掐线被发现（不再是 ready）', dropped, adapter.state.name);

        final backDeadline = DateTime.now().add(const Duration(seconds: 90));
        var back = false;
        while (DateTime.now().isBefore(backDeadline)) {
          if (adapter.state == SessionState.ready) {
            back = true;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        final trace = states.map((s) => s.name).join(' → ');
        out('  状态轨迹：$trace');
        check(
            '轨迹里出现过断开',
            states.contains(SessionState.disconnected) ||
                states.contains(SessionState.reconnecting),
            trace.isEmpty ? '（没有任何状态变化）' : trace);
        check('自动恢复到 ready（断线不自愈那处 fix）', back,
            adapter.state.name);
        check('恢复后换了一条新连接',
            back && active != null && !identical(active, t));
        if (back) {
          await Future<void>.delayed(const Duration(seconds: 2));
          try {
            final page = await svc.pullMessages();
            check('恢复后仍能拉消息', page.result == 0,
                'result=${page.result} 块=${page.blocks.length} '
                '消息=${page.messages.length}');
          } on Object catch (e) {
            check('恢复后仍能拉消息', false, '$e');
          }
        }
      }
    }

    if (watchSeconds > 0) {
      out('');
      out('--- 7. 守望 $watchSeconds 秒（现在用另一个号往这个会话发消息）---');
      final seen = chats.messagesOf(chatId).map((m) => m.id).toSet();
      final end = DateTime.now().add(Duration(seconds: watchSeconds));
      var arrived = 0;
      while (DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(seconds: 1));
        for (final m in chats.messagesOf(chatId)) {
          if (seen.add(m.id)) {
            arrived++;
            out('  ← 新消息 ${m.senderName}: ${m.text}（${m.id}）');
          }
        }
      }
      check('守望期间收到了新消息（轮询链路）', arrived > 0, '$arrived 条');
    }
  } finally {
    out('');
    out('--- 汇总 ---');
    out('  通过 $_passed / 共 ${_passed + _failed}');
    final logs = tmp.path;
    await stateSub.cancel();
    await chats.dispose();
    await adapter.dispose();
    await svc.close();
    await Log.flush();
    out('  日志目录：$logs');
    exitCode = _failed == 0 ? 0 : 1;
  }
}
