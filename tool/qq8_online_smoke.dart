/// 真机端到端冒烟：token 续期 → 上线注册 → 心跳 → 校时 → 等推送。
///
/// 与 `qq8_live_smoke.dart` 的区别：后者**一次进程只发一包、发完就关**，
/// 用于逐包对账；本工具**同一条 TCP 连接上跑完整上线流程**，用于验证
/// 「登录成功之后的东西」（注册 / 心跳 / UNI 包 / 推送）是否真的通。
///
/// ## 用法
///
/// ```bash
/// QQ_LIVE_CONFIRM=I_UNDERSTAND_THE_RISK dart run tool/qq8_online_smoke.dart --send \
///   --token-file=analysis/_ref/official-logs/qq8211/token-new.json \
///   --uin=2089495846 --profile=8.2.11 \
///   --identity=analysis/_ref/official-logs/identity-25091RP04C.json \
///   --pd2=analysis/_ref/official-logs/qq8211/pd2.dat
/// ```
///
/// 加 `--send` 才真发；不加是 dry-run（只打印将要发的结构，不连网）。
///
/// ## 步骤与判据
///
/// | 步 | 动作 | 成功判据 |
/// |---|---|---|
/// | 1 | `wtlogin.exchange_emp`（子命令 11） | 响应 `type=0` 且解出 tgt/d2/d2key |
/// | 2 | `StatSvc.register`（登录层 type=1） | 响应 `SvcRespRegister.cReplyCode == 0` |
/// | 3 | `Heartbeat.Alive`（type=0 空 body） | 收到任意响应 |
/// | 4 | `Client.CorrectTime`（type=0 4 零字节） | 响应 ≥ 4 字节，解出服务端时间 |
/// | 5 | `OidbSvc.0x480_9_IMCore`（UNI 包） | 收到任意响应 |
/// | 6 | 等 10 秒看推送 | 打印收到的所有推送命令字 |
///
/// 前 5 步都过 = 协议链完整可用（不只是"登录被执行了"）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:qqclient/kernel/crypto/ecdh.dart';
import 'package:qqclient/kernel/wlogin8/qq8_config.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_history.dart';
import 'package:qqclient/kernel/wlogin8/qq8_list.dart';
import 'package:qqclient/kernel/wlogin8/qq8_login.dart';
import 'package:qqclient/kernel/wlogin8/qq8_msg.dart';
import 'package:qqclient/kernel/wlogin8/qq8_profiles.dart';
import 'package:qqclient/kernel/wlogin8/qq8_protocol_det.dart';
import 'package:qqclient/kernel/wlogin8/qq8_session.dart';
import 'package:qqclient/kernel/wlogin8/qq8_sso.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tlv.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tran.dart';

void out(String s) => stdout.writeln(s);
void errOut(String s) => stderr.writeln(s);

/// `ksid`：官方 `util.get_ksid` -> `string_to_buf`（十六进制串两字符一字节）。
/// 共用 `lib/kernel/wlogin8/qq8_sso.dart` 的 [qq8KsidBytes]。
Uint8List _ksid(Qq8Device d) => qq8KsidBytes(d.ksid);

Uint8List _fromHex(String? s) {
  if (s == null || s.isEmpty) return Uint8List(0);
  final r = Uint8List(s.length ~/ 2);
  for (var i = 0; i < r.length; i++) {
    r[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return r;
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

  final send = args.containsKey('send');
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

  final profile =
      qq8ClientProfiles[args['profile'] ?? '8.2.11'] ?? qq8DefaultProfile;
  out('=' * 70);
  out('QQ 上线冒烟（token → register → heartbeat）');
  out('=' * 70);
  out('模式: ${send ? '**真发**' : 'dry-run（不联网）'}');
  out('档案: ${profile.describe()}');

  // ---------- 票据 ----------
  final tf = File(tokenPath);
  if (!tf.existsSync()) {
    errOut('✗ 票据文件不存在: $tokenPath');
    exit(2);
  }
  final tj = jsonDecode(tf.readAsStringSync()) as Map<String, dynamic>;
  final tokTgt = _fromHex(tj['tgt'] as String?);
  final tokD2 = _fromHex(tj['d2'] as String?);
  final tokD2Key = _fromHex(tj['d2key'] as String?);
  out('--- 票据 ---');
  out('  tgt ${tokTgt.length}B / d2 ${tokD2.length}B / d2key ${tokD2Key.length}B');
  if (tokTgt.isEmpty || tokD2.isEmpty || tokD2Key.isEmpty) {
    errOut('✗ 票据不完整');
    exit(2);
  }

  // ---------- 身份 ----------
  final identityPath = args['identity'];
  Qq8DeviceIdentity? identity;
  if (identityPath != null && identityPath.isNotEmpty) {
    final f = File(identityPath);
    if (f.existsSync()) {
      identity = Qq8DeviceIdentity.fromJson(
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
      );
      out('  身份: androidId=${identity?.androidId} guid=${identity?.guidHex ?? '派生'}');
    }
  }
  // token 续期的 tgtgt 必须是 MD5(d2key)（官方语义，见 qq8_device.dart）
  final base = identity != null
      ? Qq8Device.fromIdentity(identity)
      : Qq8Device.generate(uin);
  final device = base.withTgtgt(md5Bytes(tokD2Key));

  // ---------- ProtocolDet ----------
  Uint8List? protocolDet;
  final pd2 = args['pd2'];
  if (pd2 != null && pd2.isNotEmpty) {
    final f = File(pd2);
    if (f.existsSync()) {
      final entries = Qq8ProtocolDet.decodeFile(f.readAsBytesSync());
      protocolDet = Qq8ProtocolDet.encode(entries);
      out('  ProtocolDet: ${entries.length} 条 → ${protocolDet.length} 字节');
    }
  }

  // ---------- ECDH / 会话随机量 ----------
  final ecdh = Ecdh.exchange(Uint8List.fromList(Qq8Config.serverEcdhPublicKey));
  final sessionId = _randomBytes(4);
  final randomKey = _randomBytes(16);

  final ctx = Qq8TlvContext(
    uin: uin,
    apk: profile.apk,
    device: device,
    passwordMd5: Uint8List(0),
    seqId: 1,
    ksid: _ksid(device),
    t104: Uint8List(0),
    t174: Uint8List(0),
    tgt: tokTgt,
    srmToken: Uint8List(0),
    protocolDet: protocolDet,
    // 0x544 的 i3 官方取 m.java 的 this.u = 10（帧头另写 11），别混用
    t544SubCmd: Qq8SubCmd.tokenControl,
  );

  final body = Qq8LoginBody.buildToken(ctx, d2: tokD2);
  final tlvCount = (body[2] << 8) | body[3];
  out('--- 步骤 1：wtlogin.exchange_emp ---');
  out('  body ${body.length} 字节 / TLV 个数 $tlvCount');

  if (!send) {
    out('');
    out('dry-run 结束。真发请加 --send 并设置 '
        'QQ_LIVE_CONFIRM=I_UNDERSTAND_THE_RISK');
    return;
  }
  if (Platform.environment['QQ_LIVE_CONFIRM'] != 'I_UNDERSTAND_THE_RISK') {
    errOut('✗ 真发必须显式确认：QQ_LIVE_CONFIRM=I_UNDERSTAND_THE_RISK');
    exit(2);
  }

  // ---------- 连接 ----------
  final tran = Qq8TcpTransport();
  final session = Qq8Session(
    transport: tran,
    profile: profile,
    uin: uin,
    device: device,
    sessionId: sessionId,
    ecdhPublicKey: ecdh.publicKey,
    ecdhShareKey: ecdh.shareKey,
    sig: Qq8SigInfo(tgt: tokTgt, d2: tokD2, d2key: tokD2Key),
    randomKey: randomKey,
  );
  final pushes = <String>[];
  session.pushes.listen((p) {
    pushes.add('${p.cmd} seq=${p.seq} (${p.payload.length}B)');
    out('    [推送] ${p.cmd} seq=${p.seq} ${p.payload.length}B '
        '前16=${p.payload.take(16).toList()}');
  });
  // 关键诊断：解析失败时 Qq8Session 只回调 onError，不回调就会完全静默。
  session.onError = (e) => out('  ⚠ 收包解析失败: $e');
  final rawLog = <String>[];
  session.onRawFrame = (f) {
    rawLog.add(f.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
    final magic = (f[0] << 24) | (f[1] << 16) | (f[2] << 8) | f[3];
    out('    [原始帧] ${f.length}B magic=0x${magic.toRadixString(16)} '
        'flag=${f.length > 4 ? f[4] : -1} '
        '前12=${f.take(12).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
  };
  // 保留原始帧（诊断用）：-raw 时把每帧写进 log 目录
  final rawDir = args.containsKey('raw')
      ? (Directory(args['raw'] ?? '.')..createSync(recursive: true))
      : null;
  if (rawDir != null) {
    out('  原始帧目录: ${rawDir.path}');
  }
  var failed = 0;
  try {
    await session.start();
    out('  已连接 ${tran.host}:${tran.port}');

    // --- 1. token 登录（走 session 的配对通道，seq 自增）---
    final r1 = await session.sendLoginLayer(
      qq8ExchangeEmpCmd,
      body,
      type: Qq8LoginType.login,
      timeout: const Duration(seconds: 20),
    );
    final parsed = Qq8LoginResponse.parse(r1.payload, ecdh.shareKey);
    out('  响应 cmd=${r1.cmd} type=${parsed.type} 明文 ${parsed.plain.length}B');
    if (parsed.type != Qq8LoginResultType.success || parsed.t119 == null) {
      errOut('✗ 步骤 1 失败：type=${parsed.type} t119=${parsed.t119?.length}');
      exit(3);
    }
    final bundle = Qq8SigBundle.parse(parsed.t119!, device.tgtgt);
    session.updateSig(bundle);
    String hx(Uint8List? b) => b == null ? '无' : b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    out('    新 d2key = ${hx(bundle.d2key)}  新 d2 = ${hx(bundle.d2)}');
    out('  ✓ 步骤 1 通过：tgt ${bundle.tgt?.length ?? 0}B / '
        'd2 ${bundle.d2?.length ?? 0}B / d2key ${bundle.d2key?.length ?? 0}B');

    // --- 2. 上线注册 ---
    //
    // 判据按参考实现分三态（icqq `base-client.js:1466-1495`）：
    //   收到响应且 cReplyCode == 0 → 1   上线
    //   收到响应但 cReplyCode 非 0 → -1  未上线
    //   等待响应超时（catch）    → -2  **不判失败**：调用方
    //                                 `else if (err === -2) return BUF0;`
    //                                 直接继续后面的上线流程。
    // 2026-10-22 真机实测：本条命令服务端不回 ack（同一条连接上只收到
    // ConfigPushSvc.PushReq 推送），与 icqq 遇到的是同一现象，故超时记为
    // 「已发出、无 ack」并继续，不算失败。
    out('--- 步骤 2：StatSvc.register ---');
    try {
      final ok = await session.register();
      out(ok
          ? '  ✓ 步骤 2 通过：注册成功（cReplyCode == 0）'
          : '  ✗ 步骤 2 失败：cReplyCode 非 0');
      if (!ok) failed++;
    } on Object catch (e) {
      if (e.toString().contains('等待响应超时')) {
        out('  ~ 步骤 2 已发出、无 ack（等价 icqq register 返回 -2，不判失败）：$e');
      } else {
        out('  ✗ 步骤 2 失败: $e');
        failed++;
      }
    }

    // --- 3. Heartbeat.Alive ---
    out('--- 步骤 3：Heartbeat.Alive ---');
    try {
      final hb = await session.heartbeatAlive();
      out('  ✓ 步骤 3 通过：${hb.cmd} 响应 ${hb.payload.length}B');
    } on Object catch (e) {
      out('  ✗ 步骤 3 失败: $e');
      failed++;
    }

    // --- 4. Client.CorrectTime ---
    out('--- 步骤 4：Client.CorrectTime ---');
    try {
      final ts = await session.correctTime();
      out('  ✓ 步骤 4 通过：服务端时间 $ts，时间差 ${session.timeDiffSeconds}s');
    } on Object catch (e) {
      out('  ✗ 步骤 4 失败: $e');
      failed++;
    }

    // --- 5. UNI 心跳 ---
    out('--- 步骤 5：OidbSvc.0x480_9_IMCore ---');
    try {
      final u = await session.uniHeartbeat();
      out('  ✓ 步骤 5 通过：${u.cmd} 响应 ${u.payload.length}B');
    } on Object catch (e) {
      out('  ✗ 步骤 5 失败: $e');
      failed++;
    }

    // --- 6. 拉好友列表（业务层第一枪）---
    //
    // 走 UNI 包（magic=0x0B），命令 `friendlist.getFriendGroupList`，
    // 请求体是 JCE 编码的 `GetFriendListReq`（见 [Qq8List.buildFriendListBody]）。
    // 成功判据：JCE 解出 `result == 0` 且 `total >= 0`——**能解出结构本身就
    // 说明业务层可用**（TLV/SSO/UNI 封装、密钥、session 全部正确）。
    out('--- 步骤 6：拉好友列表（friendlist.getFriendGroupList）---');
    try {
      final flBody = Qq8List.buildFriendListBody(uin: uin, count: 150);
      final flRsp = await session.sendUni(
        Qq8List.cmdFriendList,
        flBody,
        timeout: const Duration(seconds: 15),
      );
      final page = Qq8List.parseFriendList(flRsp.payload);
      out('  响应 ${flRsp.payload.length}B  result=${page.result}  total=${page.total}  '
          '分组 ${page.classes.length}  好友 ${page.friends.length}');
      for (final c in page.classes.take(10)) {
        out('    分组 ${c.id}: ${c.name}');
      }
      for (final f in page.friends.take(10)) {
        out('    好友 ${f.uin}  昵称="${f.nick}"  备注="${f.remark}"');
      }
      if (page.friends.length > 10) {
        out('    …（共 ${page.friends.length} 个，只打印前 10）');
      }
      if (page.ok) {
        out('  ✓ 步骤 6 通过：JCE 业务包完整解出（result=0）');
      } else {
        out('  ✗ 步骤 6 失败：result=${page.result}');
        failed++;
      }
    } on Object catch (e) {
      out('  ✗ 步骤 6 失败: $e');
      failed++;
    }

    // --- 7. 发一条真实消息（可选，--send-to=<uin>）---
    //
    // 这是「能不能聊天」的唯一硬证据：请求体 `MessageSvc.PbSendMsg`，
    // 成功判据 `rsp[1] == 0 && rsp[14] != 0`（icqq `friend.js:230`）。
    final sendTo = int.tryParse(args['send-to'] ?? '');
    if (sendTo != null) {
      out('--- 步骤 7：发消息给 $sendTo（MessageSvc.PbSendMsg）---');
      try {
        // seq 必须与包序号一致：先预取，再把它塞进 body，最后用同一个值发。
        final mseq = session.nextSeq();
        final rand = _randomBytes(4);
        final randInt =
            (rand[0] << 24) | (rand[1] << 16) | (rand[2] << 8) | rand[3];
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final sessSeed = (session.sessionId[0] << 24) |
            (session.sessionId[1] << 16) |
            (session.sessionId[2] << 8) |
            session.sessionId[3];
        final text = args['text'] ?? '协议栈自测消息，请忽略';
        final msgBody = Qq8Msg.buildC2cTextBody(
          uid: sendTo,
          elems: <Uint8List>[Qq8Msg.textElem(text)],
          seq: mseq,
          rand: randInt,
          syncCookieSeed: sessSeed,
          nowSeconds: nowSec,
          syncR5: _randomInt(),
          syncR9: _randomInt(),
          syncR11: _randomInt(),
        );
        final msgRsp = await session.sendUni(
          Qq8Msg.sendCmd,
          msgBody,
          seq: mseq,
          timeout: const Duration(seconds: 20),
        );
        final res = Qq8Msg.parseSendResponse(
          msgRsp.payload,
          seq: mseq,
          rand: randInt,
        );
        out('  响应 ${msgRsp.payload.length}B  code=${res.code}  '
            'serverMsgId=${res.serverMsgId}  time=${res.time}  '
            'msg="${res.message}"');
        out('  原始响应 hex = ${_hex(msgRsp.payload)}');
        if (res.ok) {
          out('  ✓ 步骤 7 通过：消息已被服务端收下（seq=$mseq rand=$randInt '
              'serverMsgId=${res.serverMsgId}）');
        } else {
          out('  ✗ 步骤 7 失败：code=${res.code} ${res.message}');
          failed++;
        }
      } on Object catch (e) {
        out('  ✗ 步骤 7 失败: $e');
        failed++;
      }
    } else {
      out('--- 步骤 7：跳过发消息（未给 --send-to=<uin>）---');
    }

    // --- 7.5. 群历史（可选，--group=GID:FROM:TO）---
    //
    // 这是「群消息到底能不能拉」的判据。真机长期拿到 result=103/104 且
    // 条数=0，但每次请求的都是「上一条已知消息之后」的区间——那里本来
    // 就没有新消息。用 `--group=<群号>:<起>:<止>` 指定一个**确认有消息**
    // 的区间，才能区分「组包错」和「没新消息」。
    final groupSpec = args['group'];
    if (groupSpec != null) {
      out('--- 步骤 7.5：群历史（MessageSvc.PbGetGroupMsg）$groupSpec ---');
      try {
        final parts = groupSpec.split(':');
        final gid = int.parse(parts[0]);
        final from = parts.length > 1 ? int.parse(parts[1]) : 1;
        final to = parts.length > 2 ? int.parse(parts[2]) : from + 19;
        final body = Qq8History.buildGroupMsgBody(
          groupCode: gid,
          beginSeq: from,
          endSeq: to,
        );
        out('  请求 gid=$gid begin=$from end=$to  body=${body.length}B');
        final r = await session.sendUni(
          Qq8History.cmdGetGroupMsg,
          body,
          timeout: const Duration(seconds: 15),
        );
        final page = Qq8History.parseGroupMsg(r.payload);
        out('  响应 ${r.payload.length}B  result=${page.result}  '
            'returnBegin=${page.returnBeginSeq}  returnEnd=${page.returnEndSeq}  '
            '条数=${page.messages.length}  errmsg=${page.errmsg ?? ''}');
        for (final m in page.messages.take(5)) {
          out('    seq=${m.seq} 发送者=${m.fromUin} 文本=${m.text}');
        }
        if (page.messages.isNotEmpty) {
          out('  ✓ 步骤 7.5 通过：群里能拉到真实消息');
        } else {
          out('  ✗ 步骤 7.5 失败：result=${page.result} 条数=0');
          failed++;
        }
      } on Object catch (e) {
        out('  ✗ 步骤 7.5 失败: $e');
        failed++;
      }
    } else {
      out('--- 步骤 7.5：跳过群历史（未给 --group=GID:FROM:TO）---');
    }

    // --- 8. 等推送 ---
    out('--- 步骤 8：等 10 秒看服务端推送 ---');
    await Future<void>.delayed(const Duration(seconds: 10));
    if (pushes.isEmpty) {
      out('  （10 秒内无推送）');
    } else {
      out('  收到 ${pushes.length} 条推送:');
      for (final p in pushes.take(20)) {
        out('    $p');
      }
    }

    if (rawLog.isNotEmpty) {
      final rf = File('${Directory.systemTemp.path}/qq8-rawframes.txt');
      final nl = String.fromCharCode(10);
      rf.writeAsStringSync(rawLog.join(nl));
      out('  原始帧已存 ${rf.path}（${rawLog.length} 帧）');
    }

    out('');
    out('=' * 70);
    out(failed == 0 ? '✓ 全部步骤通过' : '✗ $failed 个步骤失败');
    out('=' * 70);
  } finally {
    tran.close();
  }
  if (failed != 0) exit(4);
}

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

int _randomInt() {
  final b = _randomBytes(4);
  return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
}

/// 字节转小写 hex（调试输出用）。
String _hex(List<int> b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write((x & 0xff).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
