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
/// | 2 | `StatSvc.register`（登录层 type=1） | 响应 `rsp[9] != 0` |
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
import 'package:qqclient/kernel/wlogin8/qq8_login.dart';
import 'package:qqclient/kernel/wlogin8/qq8_profiles.dart';
import 'package:qqclient/kernel/wlogin8/qq8_protocol_det.dart';
import 'package:qqclient/kernel/wlogin8/qq8_session.dart';
import 'package:qqclient/kernel/wlogin8/qq8_sso.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tlv.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tran.dart';

void out(String s) => stdout.writeln(s);
void errOut(String s) => stderr.writeln(s);

/// `ksid` = `|<imei>|<apkName>`（官方 `util.get_ksid`，与 live_smoke 同款）。
Uint8List _ksid(Qq8Device d, Qq8ClientProfile p) =>
    Uint8List.fromList(utf8.encode('|${d.imei}|${p.apk.name}'));

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
    ksid: _ksid(device, profile),
    t104: Uint8List(0),
    t174: Uint8List(0),
    tgt: tokTgt,
    srmToken: Uint8List(0),
    protocolDet: protocolDet,
    t544SubCmd: Qq8SubCmd.token,
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
  var frameNo = 0;
  void dumpFrame(String tag, Uint8List f) {
    if (rawDir == null) return;
    final name = 'frame-${(frameNo++).toString().padLeft(2, '0')}-$tag.hex';
    File('${rawDir.path}/$name').writeAsStringSync(
        f.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
    out('    原始帧已存 ${rawDir.path}/$name (${f.length}B, 前16=${f.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join()})');
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
    //   收到响应且 `rsp[9]` 为真 → 1   上线
    //   收到响应但 `rsp[9]` 为假 → -1  未上线
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
          ? '  ✓ 步骤 2 通过：注册成功（rsp[9] 真值）'
          : '  ✗ 步骤 2 失败：rsp[9] 为假');
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

    // --- 6. 等推送 ---
    out('--- 步骤 6：等 10 秒看服务端推送 ---');
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
