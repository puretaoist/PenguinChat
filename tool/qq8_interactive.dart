/// QQ 登录 **单进程 / 单连接** 交互冒烟工具
///
/// ## 为什么要有这个工具
///
/// `tool/qq8_live_smoke.dart` 是"一次进程一次往返"的形态：密码登录是进程 A、
/// 滑块提交是进程 B，两步之间靠 `--save-session` / `--load-session` 搬
/// ECDH 私钥、sessionId、randomKey、seqId。
///
/// 测下来这个形态**不够**。官方 wlogin 日志里两轮登录都是：
///
/// | 轮次 | type=2 → 提交间隔 | 连接 | 结果 |
/// |---|---|---|---|
/// | 第一轮 | **17 秒** | 同一条 MSF 长连接 | 160 → 短信 → 成功 |
/// | 第二轮 | **7 秒**  | 同一条 | 0（直接成功） |
///
/// 而我们的两次真机跑分别是 **60 秒** 和 **139 秒**，且各自新建 TCP。
/// 官方日志 22 次 `snd_rcv_req_msf` 全在一条连接内；我们只有值被搬过去了，
/// **连接是新的、延迟高一个数量级**。
///
/// 本工具就是补这个差：**同一条 socket** 上完成「密码登录 → 人工解滑块 →
/// 立刻提交」，把 ticket 的存活窗口压到官方量级。
///
/// ## 两道闸门不变
///
/// 默认 dry-run（不联网）；真发必须 `--send` + `QQ_LIVE_CONFIRM`，
/// 且过 `LoginAttemptLimiter`。**失败就停，不重试。**
///
/// ## 用法
///
/// ```bash
/// # dry-run：只验证交互状态机与组包，完全不联网
/// dart run tool/qq8_interactive.dart --uin=10001 --pwd-md5=<32位hex>
///
/// # 真发
/// $env:QQ_LIVE_CONFIRM="I_UNDERSTAND_THE_RISK"
/// dart run tool/qq8_interactive.dart --send --uin=<uin> --pwd-md5=<hex> \
///     --identity=analysis/_ref/official-logs/identity-25091RP04C.json
/// ```
///
/// 真发时会：
/// 1. 连一次 `msfwifi.3g.qq.com:8080`，**保持连接**；
/// 2. 发密码登录包，打印 `0x192` 滑块地址；
/// 3. 停在 stdin 等你把 ticket 粘进来（回车提交）；
/// 4. **同一条 socket** 立刻发滑块提交包；
/// 5. 按响应决定下一步（成功 / 短信 / 失败）。
///
/// 不做任何滑块自动化或绕过：解自己账号的验证属正常流程，ticket 由人给。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:qqclient/infra/log/log_file.dart';
import 'package:qqclient/infra/log/logger.dart';
import 'package:qqclient/kernel/crypto/ecdh.dart';
import 'package:qqclient/kernel/safety/attempt_limiter.dart';
import 'package:qqclient/kernel/wlogin8/qq8_config.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_login.dart';
import 'package:qqclient/kernel/wlogin8/qq8_pow.dart';
import 'package:qqclient/kernel/wlogin8/qq8_profiles.dart';
import 'package:qqclient/kernel/wlogin8/qq8_qimei.dart';
import 'package:qqclient/kernel/wlogin8/qq8_recv.dart';
import 'package:qqclient/kernel/wlogin8/qq8_sso.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tlv.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tran.dart';

final Logger _log = Log.get('QQ8INTERACTIVE');

/// 真发所需的确认串。
const String kConfirmToken = 'I_UNDERSTAND_THE_RISK';

/// 本次运行的"全程记录"文件（`<logDir>/qq8-interactive-<时间戳>.log`）。
///
/// 与 `qq8_live_smoke.dart` 同款：真机跑时用户可能直接关窗口，ring 日志来不及
/// 导出，所以 `out` 每行都同步追加到这个文件。
File? _runLogFile;

/// 控制台 + 运行记录文件双写。
void out(Object? line) {
  stdout.writeln(line);
  final f = _runLogFile;
  if (f == null) return;
  try {
    f.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } on Object {
    // 记录失败不能打断正事
  }
}

/// 同 [out]，但走 stderr。
void errOut(Object? line) {
  stderr.writeln(line);
  final f = _runLogFile;
  if (f == null) return;
  try {
    f.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } on Object {
    // 同上
  }
}

Future<void> main(List<String> argv) async {
  final args = _parseArgs(argv);

  // ---------- 日志 ----------
  final logDir = Directory(
    args['logdir'] ??
        '${Directory.systemTemp.path}${Platform.pathSeparator}qqclient-logs',
  )..createSync(recursive: true);
  Log.configure(minLevel: LogLevel.debug, ringCapacity: 4000);
  Log.addSink(FileLogSink(logDir));
  _runLogFile = File('${logDir.path}${Platform.pathSeparator}'
      'qq8-interactive-${DateTime.now().millisecondsSinceEpoch}.log');

  try {
    await _run(args);
  } on Object catch (e, st) {
    errOut('✗ 未捕获异常: $e');
    errOut(st);
    _log.e('未捕获异常', error: e, stack: st);
    exitCode = 1;
  } finally {
    await Log.flush();
    // ServerSocket / socket 句柄会让事件循环活着，必须显式退出。
    exit(exitCode);
  }
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> _run(Map<String, String> args) async {
  // ---- 离线口令探针（零风险，不联网、不限流）----
  //
  // 为什么要它：历次真跑的日志只留下打码后的指纹（前 4 字节）。要判断
  // "现在输入的这串是不是当年那串"，唯一办法就是拿候选口令本地算一遍再比。
  // MD5 不可逆，但可以正着试——而且完全不碰服务器。
  final probe = args['pwd-probe'];
  if (probe != null) {
    final h = md5Bytes(Uint8List.fromList(utf8.encode(probe)));
    final hex = h.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    out('  明文长度: ${utf8.encode(probe).length} 字节');
    out('  MD5: $hex');
    out('  指纹: head=${hex.substring(0, 8)}…');
    // 历史日志里出现过的两个指纹，附各自的结局
    const known = <String, String>{
      '00d08ed0': '09-13 全部 + 10-16（派生设备）→ type=2；'
          '今天以真机身份发 → type=1，之后每次滑块提交回 type=1 或 237',
      '28ade243': '09-19 五次真机身份发 → 全部 type=2',
    };
    final hit = known[hex.substring(0, 8)];
    if (hit != null) {
      out('  ➜ 匹配历史指纹 ${hex.substring(0, 8)}：$hit');
    } else {
      out('  ➜ 与历史两个指纹都不匹配（既不是 00d08ed0 也不是 28ade243）');
    }
    return;
  }

  final send = args.containsKey('send');
  final confirm = Platform.environment['QQ_LIVE_CONFIRM'];
  final profile = _pickProfile(args['profile'] ?? 'default');
  var uin =
      int.tryParse(args['uin'] ?? Platform.environment['QQ_LIVE_UIN'] ?? '') ??
          0;
  final deterministic = !send;

  out('=' * 72);
  out('QQ8 单进程 / 单连接交互冒烟');
  out('=' * 72);
  out('  模式: ${send ? '**真实发送**' : '**dry-run**（不联网）'}');
  out('  档案: ${profile.label}  code=${profile.versionCode}  '
      'ssoVer=${profile.apk.ssoVer}  tlv=${profile.apk.loginTlvOrder.length}项');

  // ---- 口令 ----
  Uint8List? passwordMd5;
  final pwdMd5Hex = args['pwd-md5'];
  if (pwdMd5Hex != null && pwdMd5Hex.isNotEmpty) {
    passwordMd5 = _hex(pwdMd5Hex);
    if (passwordMd5.length != 16) {
      errOut('✗ --pwd-md5 必须是 16 字节（32 位 hex）');
      exitCode = 2;
      return;
    }
  } else {
    final pwd = args['pwd'] ?? Platform.environment['QQ_LIVE_PWD'];
    if (pwd != null && pwd.isNotEmpty) {
      passwordMd5 = md5Bytes(Uint8List.fromList(utf8.encode(pwd)));
    }
  }
  if (send && (uin == 0 || passwordMd5 == null)) {
    errOut('✗ 真发必须给 --uin 与口令（--pwd / --pwd-md5 / QQ_LIVE_PWD）');
    exitCode = 2;
    return;
  }
  if (!send) {
    uin = uin == 0 ? 10001 : uin;
    passwordMd5 ??= Uint8List(16);
  }
  out('  uin: $uin');
  if (passwordMd5 != null) {
    // 与 live_smoke 同款：只留长度 + 前 4 字节，够跨次比对、不泄漏口令。
    // 历次被服务端接受（type=2）的指纹：00d08ed0… / 28ade243…
    out('  口令: 已提供');
    out('    ${Redact.fingerprint('pwd_md5', passwordMd5)}');
  }

  if (send && confirm != kConfirmToken) {
    errOut('✗ 真发需要 QQ_LIVE_CONFIRM=$kConfirmToken'
        '（当前: ${confirm == null ? '未设置' : '不匹配'}）');
    exitCode = 2;
    return;
  }

  // ---- 设备身份 ----
  Qq8DeviceIdentity? identity;
  final identityPath = args['identity'];
  if (identityPath != null && identityPath.isNotEmpty) {
    final f = File(identityPath);
    if (!f.existsSync()) {
      errOut('✗ --identity 文件不存在: $identityPath');
      exitCode = 2;
      return;
    }
    final decoded = jsonDecode(f.readAsStringSync());
    if (decoded is! Map) {
      errOut('✗ --identity 不是 JSON 对象');
      exitCode = 2;
      return;
    }
    identity = Qq8DeviceIdentity.fromJson(Map<String, Object?>.from(decoded));
    if (identity == null) {
      errOut('✗ --identity 缺少 android_id / mac');
      exitCode = 2;
      return;
    }
    out('  身份注入: $identity');
  } else {
    out('  设备: 按 uin 派生（合成设备；风控会当新设备）');
  }
  final device =
      identity != null ? Qq8Device.fromIdentity(identity) : Qq8Device.generate(uin);

  // ---- QIMEI ----
  String? qimei;
  final qimeiArg = args['qimei'];
  if (qimeiArg != null && qimeiArg.isNotEmpty) {
    qimei = qimeiArg;
    out('  QIMEI: 命令行注入 ${qimei.length} 字符');
  } else if (identity?.qimei != null && identity!.qimei!.isNotEmpty) {
    qimei = identity.qimei;
    out('  QIMEI: 身份文件注入 ${qimei!.length} 字符');
  } else if (args.containsKey('fetch-qimei')) {
    if (!send) {
      out('  QIMEI: dry-run 不联网取号');
    } else {
      try {
        final r = await Qq8Qimei.fetch(
          device: device,
          apk: profile.apk,
          beaconAppKey: profile.beaconAppKey,
        );
        qimei = r.q16;
        out('  QIMEI: 取号成功 q16=$qimei（${r.endpoint}）');
      } on Object catch (e) {
        out('  QIMEI: 取号失败（不阻断登录）: $e');
      }
    }
  } else {
    out('  QIMEI: 未提供（0x545 整条不发 = 官方降级行为）');
  }

  // ---- 滑块 TLV 形态 ----
  final formName = args['slider-form'] ?? 'websig';
  final Qq8SliderTicketForm sliderForm;
  switch (formName) {
    case 'websig':
      sliderForm = Qq8SliderTicketForm.websig;
    case 'picture':
      sliderForm = Qq8SliderTicketForm.picture;
    default:
      errOut('✗ --slider-form 只能是 websig / picture');
      exitCode = 2;
      return;
  }

  // ⚠️ 默认必须与 live_smoke 一致（'official'）。
  //
  // 历史真机跑里，凡是 0x544 = 4 字节官方降级体的，服务端都回 type=2
  // （密码正确、要滑块）；改成 39 字节 oicq 真签名后回 type=1。
  // 官方降级体是"官方自己在安全 SDK 不可用时会发的东西"，服务端认得；
  // 我们本地算出来的签名则可能与该设备在服务端的既有记录对不上。
  final t544Mode = args['t544'] ?? 'official';
  if (t544Mode != 'official' && t544Mode != 'oicq' && t544Mode != 'oicq-salt') {
    errOut('✗ --t544 只支持 official / oicq / oicq-salt');
    exitCode = 2;
    return;
  }

  out('  0x544 形态: $t544Mode'
      '${t544Mode == 'official' ? '（4 字节官方降级体）' : '（39 字节纯算法签名）'}');

  // ---- 会话（只建一次，全程复用）----
  final ecdh = Ecdh.exchange(
    Uint8List.fromList(Qq8Config.serverEcdhPublicKey),
    privateKey: deterministic ? _fill(32, 0x11) : _randomBytes(32),
  );
  final sessionSeq = deterministic
      ? 100
      : (DateTime.now().millisecondsSinceEpoch & 0x7FFF);
  final sessionId = deterministic ? _hex('01020304') : _randomBytes(4);
  final randomKey = deterministic ? _fill(16, 0x0f) : _randomBytes(16);
  out('  会话: seq=$sessionSeq sessionId=${_hexOf(sessionId)} '
      'randomKey=${_hexOf(randomKey)}');
  out('  ${Redact.fingerprint('share_key', ecdh.shareKey)}');

  // ---- 组包 ----
  final selfT548 = profile.apk.ssoVer > 12
      ? qq8BuildClientPow548().body
      : null;

  Qq8TlvContext ctxFor({
    required Uint8List t104,
    Uint8List? t547,
    required int subCmd,
  }) =>
      Qq8TlvContext(
        uin: uin,
        apk: profile.apk,
        device: device,
        passwordMd5: passwordMd5!,
        seqId: sessionSeq,
        ksid: _ksid(device, profile),
        t104: t104,
        t174: Uint8List(0),
        tgt: Uint8List(0),
        srmToken: Uint8List(0),
        t547: t547,
        t548: selfT548,
        t544Mode: switch (t544Mode) {
          'oicq' => Qq8T544Mode.oicq,
          'oicq-salt' => Qq8T544Mode.officialSalt,
          _ => Qq8T544Mode.officialDegraded,
        },
        t544SubCmd: subCmd,
        t544Curr: deterministic ? 1700000000000 : null,
      );

  final loginCtx = ctxFor(t104: Uint8List(0), subCmd: Qq8SubCmd.password);
  final loginBody = Qq8LoginBody.build(
    loginCtx,
    Qq8SubCmd.password,
    qq8PasswordTlvOrderFor(profile.apk),
    cond: Qq8LoginConditions(qimei: qimei, t548: selfT548),
    args: qimei == null
        ? const <int, List<Object?>>{}
        : <int, List<Object?>>{
            0x545: <Object?>[qimei],
          },
  );

  final ssoCtx = Qq8SsoContext(
    uin: uin,
    apk: profile.apk,
    device: device,
    sessionId: sessionId,
    randomKey: randomKey,
    ecdhPublicKey: ecdh.publicKey,
    ecdhShareKey: ecdh.shareKey,
    seqId: sessionSeq,
    sig: null,
  );
  final loginPkt = Qq8Sso.buildLoginPacket(
    ssoCtx,
    qq8LoginCmd,
    Qq8Sso.buildOicqPacket(ssoCtx, loginBody),
    Qq8LoginType.login,
  );

  out('');
  out('--- 密码登录包 ---');
  out('  子命令=${Qq8SubCmd.password}  body=${loginBody.length}  '
      '登录信封=${loginPkt.length}');
  out('  首 4 字节声明长度=${_u32(loginPkt)}'
      '（${_u32(loginPkt) == loginPkt.length ? '自洽 ✓' : '不一致 ✗'}）');
  _printTlvs(loginBody);

  // ---- dry-run：夹具 ticket 走一遍状态机 ----
  if (!send) {
    final fakeSalt = _fill(44, 0x33);
    const fakeTicket = 't0dummy-TICKET-for-dry-run-0123456789';
    final slCtx = ctxFor(t104: fakeSalt, subCmd: Qq8SubCmd.slider);
    final slBody = Qq8LoginBody.buildSlider(
      slCtx,
      ticket: fakeTicket,
      form: sliderForm,
      pictureSign: Uint8List(0),
    );
    final slPkt = Qq8Sso.buildLoginPacket(
      ssoCtx,
      qq8LoginCmd,
      Qq8Sso.buildOicqPacket(ssoCtx, slBody),
      Qq8LoginType.login,
    );
    out('');
    out('--- 滑块提交包（dry-run 夹具 ticket，非真实）---');
    out('  形态=$formName  首项 TLV='
        '${formName == 'picture' ? '0x02（n.K=false → CheckPictureAndGetSt）' : '0x193（n.K=true → CheckWebsigAndGetSt）'}');
    out('  body=${slBody.length}  登录信封=${slPkt.length}');
    out('  首 4 字节声明长度=${_u32(slPkt)}'
        '（${_u32(slPkt) == slPkt.length ? '自洽 ✓' : '不一致 ✗'}）');
    _printTlvs(slBody);

    // 关键：dry-run 证明"两步共用同一会话"（本工具与 live_smoke 的区别）
    final slBody2 = Qq8LoginBody.buildSlider(
      ctxFor(t104: fakeSalt, subCmd: Qq8SubCmd.slider),
      ticket: fakeTicket,
      form: sliderForm,
      pictureSign: Uint8List(0),
    );
    final sameA = _hexOf(loginCtx.ksid) == _hexOf(slCtx.ksid);
    out('');
    out('--- 会话复用自检 ---');
    out('  share_key 唯一（两步同用）: ${_hexOf(ecdh.shareKey).length * 4} bit');
    out('  seq/sessionId/randomKey 全程不变: $sessionSeq / '
        '${_hexOf(sessionId)} / ${_hexOf(randomKey)}');
    out('  ksid 一致: ${sameA ? '是 ✓' : '否 ✗'}');
    // 0x548（ClientPow）与 0x553（fekit）内含随机/时间成分，8.9.50+ 必定不可复现；
    // 8.2.11 的清单里没有它们，所以只有 8.2.11 应当逐字节相同。
    final reproducible = _hexOf(slBody) == _hexOf(slBody2);
    final expectReproducible = profile.apk.ssoVer <= 12;
    out('  同一输入组包可复现: $reproducible'
        '（档案期望: ${expectReproducible ? "是" : "否（0x548/0x553 含随机）"} '
        '${reproducible == expectReproducible ? "✓" : "✗"}）');
    out('');
    out('dry-run 结束。要真发请加 --send 并设置 QQ_LIVE_CONFIRM。');
    return;
  }

  // ---- 限流 ----
  final limiter = LoginAttemptLimiter(
    persistFile: File('${Directory.systemTemp.path}${Platform.pathSeparator}'
        'qqclient-logs${Platform.pathSeparator}qqclient-attempts.json'),
  );
  await limiter.load();
  final status = limiter.status();
  out('  限流: ${status.describe()}');
  if (!status.allowed) {
    errOut('✗ 被限流器拒绝');
    exitCode = 3;
    return;
  }
  final begun = await limiter.beginAttempt();
  if (!begun.allowed) {
    errOut('✗ 记录后仍不允许: ${begun.describe()}');
    exitCode = 3;
    return;
  }

  // ---- 真发：一条连接走两步 ----
  final tran = Qq8TcpTransport();
  out('');
  out('--- 连接 ${tran.host}:${tran.port}（全程只连这一次）---');
  try {
    await tran.connect();
    out('  已连接 ✓');

    // 第一步：密码登录
    out('');
    out('--- [1/2] 密码登录（${loginPkt.length} 字节）---');
    final t1 = DateTime.now();
    final frame1 = await tran.send(loginPkt);
    final sso1 = qq8UnwrapRecv(frame1);
    final r1 = Qq8LoginResponse.parse(sso1.payload, ecdh.shareKey);
    out('  响应 ${frame1.length} 字节 / '
        '${DateTime.now().difference(t1).inMilliseconds}ms');
    out('  type = ${r1.type}  (${_typeMeaning(r1.type)})');
    final m1 = r1.serverMessage;
    if (m1 != null) out('  服务端提示: [${m1.$1}] ${m1.$2}');

    if (!r1.needsSlider) {
      out('  ✗ 没有要求滑动验证（type=${r1.type}），本工具无事可做。');
      _printResponseTlvs(r1);
      await limiter.recordFailure(reasonCode: 'type=${r1.type}');
      return;
    }

    final salt = r1.tlvs[0x104];
    out('  滑动验证地址: ${r1.sliderUrl}');
    if (salt == null || salt.isEmpty) {
      out('  ✗ 响应没有 0x104（盐），无法提交。');
      return;
    }
    out('  盐（0x104）: ${salt.length} 字节');

    // 0x546 → 0x547（有挑战就本地解，没有就不带，对齐官方）
    Uint8List? t547;
    final pow546 = r1.tlvs[0x546];
    if (pow546 != null && pow546.isNotEmpty) {
      final ans = qq8SolvePow(pow546);
      if (ans != null) {
        t547 = ans.body;
        out('  ✓ 解出 0x547（${ans.body.length} 字节 / ${ans.iterations} 次迭代）');
      } else {
        out('  ⚠ 0x546 存在但解不出，提交不带 0x547');
      }
    } else {
      out('  无 0x546 挑战（不带 0x547，对齐官方）');
    }

    // 第二步：等人工 ticket，同一条 socket 立刻发。
    //
    // ⚠️ 这一步的**耗时**就是本次实验的自变量：
    //   官方两轮是 17.6s / 7.2s（同一条 MSF 长连接内）；
    //   我们历史两次独立进程是 60s / 139s。
    // 连接在等待期间保持打开（服务端若先关掉，下一步 send 会报"连接被对端关闭"，
    // 那本身就是一个有价值的观测——说明 ticket 有服务端侧的会话窗口）。
    final gapStart = DateTime.now();
    out('');
    out('--- [2/2] 等 ticket（⚠ 连接保持中，请尽快）---');
    out('  把滑块解掉后，把 ticket 粘到这里回车（直接回车 = 中止）：');
    stdout.write('  ticket> ');
    final ticket = stdin.readLineSync(encoding: utf8);
    final gapMs = DateTime.now().difference(gapStart).inMilliseconds;
    out('  等待耗时: ${(gapMs / 1000).toStringAsFixed(1)}s'
        '（官方基准 17.6s / 7.2s）');
    if (ticket == null || ticket.trim().isEmpty) {
      out('  已中止（未提交，连接关闭）');
      return;
    }
    final cleaned = ticket.trim();
    out('  ticket: ${cleaned.length} 字符');
    out('  连接状态: ${tran.isConnected ? "仍开着 ✓" : "已被对端关闭 ✗"}');

    final slBody = Qq8LoginBody.buildSlider(
      ctxFor(t104: salt, t547: t547, subCmd: Qq8SubCmd.slider),
      ticket: cleaned,
      form: sliderForm,
      pictureSign: Uint8List(0),
    );
    final slPkt = Qq8Sso.buildLoginPacket(
      ssoCtx,
      qq8LoginCmd,
      Qq8Sso.buildOicqPacket(ssoCtx, slBody),
      Qq8LoginType.login,
    );
    out('  提交包: body=${slBody.length} 信封=${slPkt.length}'
        '（首 4 字节 ${_u32(slPkt)}）');
    _printTlvs(slBody);

    final t2 = DateTime.now();
    final frame2 = await tran.send(slPkt);
    final sso2 = qq8UnwrapRecv(frame2);
    final r2 = Qq8LoginResponse.parse(sso2.payload, ecdh.shareKey);
    out('  响应 ${frame2.length} 字节 / '
        '${DateTime.now().difference(t2).inMilliseconds}ms');
    out('  type = ${r2.type}  (${_typeMeaning(r2.type)})');
    _printResponseTlvs(r2);
    final m2 = r2.serverMessage;
    if (m2 != null) out('  服务端提示: [${m2.$1}] ${m2.$2}');

    if (r2.isSuccess) {
      out('');
      out('  ✅ 登录成功（滑块这一步通过）');
      await limiter.recordProgress(reasonCode: 'success');
    } else if (r2.needsSmsVerify) {
      out('');
      out('  ➜ 进入短信验证（type=${r2.type}）—— 官方同路径的下一步就是短信');
      await limiter.recordProgress(reasonCode: 'type=${r2.type}');
    } else {
      await limiter.recordFailure(reasonCode: 'type=${r2.type}');
      out('');
      out('  已记一次失败。**不要马上重试**（限流器 ${limiter.status().describe()}）。');
      exitCode = 1;
    }
  } finally {
    await tran.close();
  }
}

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

void _printTlvs(Uint8List body) {
  // body = u16 子命令 ‖ u16 个数 ‖ TLV…
  if (body.length < 4) return;
  final sub = (body[0] << 8) | body[1];
  final n = (body[2] << 8) | body[3];
  final tags = <int>[];
  var i = 4;
  while (i + 4 <= body.length) {
    final tag = (body[i] << 8) | body[i + 1];
    final len = (body[i + 2] << 8) | body[i + 3];
    tags.add(tag);
    i += 4 + len;
  }
  out('  子命令=$sub  声明 TLV 个数=$n  实际解析=${tags.length}'
      '${n == tags.length ? ' ✓' : ' ✗'}');
  // 带长度打印：跨次真跑对比时，长度比编号更能定位差异（0x106/0x144 等
  // 由口令派生的 TLV 一旦长度不对就能立刻看出来）。
  for (final t in tags) {
    final off = _tlvOffset(body, t);
    final len = off == null ? -1 : (body[off + 2] << 8) | body[off + 3];
    out('    0x${t.toRadixString(16).padLeft(4, '0')}'
        '${len.toString().padLeft(7)} 字节');
  }
}

/// 打印**响应**里的 TLV（用解析好的 map，不猜明文头布局）。
///
/// 响应明文头是 `u16 ?` + `u8 type` + `u16 ?`，与请求体的
/// `u16 子命令` + `u16 个数` 不同构——早期版本这里直接拿 `plain` 当请求体解析，
/// 打出了 `声明 TLV 个数=256 / 0x0201` 这种垃圾。
void _printResponseTlvs(Qq8LoginResponse r) {
  final tags = r.tlvs.keys.toList()..sort();
  out('  响应 TLV (${tags.length} 项): '
      '${tags.map((t) => '0x${t.toRadixString(16).padLeft(4, '0')}'
          '(${r.tlvs[t]!.length}B)').join(' ')}');
}

/// 在请求体里找某个 tag 的偏移（返回 tag 起始位置）。
int? _tlvOffset(Uint8List body, int want) {
  var i = 4;
  while (i + 4 <= body.length) {
    final tag = (body[i] << 8) | body[i + 1];
    final len = (body[i + 2] << 8) | body[i + 3];
    if (tag == want) return i;
    i += 4 + len;
  }
  return null;
}

int _u32(Uint8List b) => (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];

Map<String, String> _parseArgs(List<String> argv) {
  final m = <String, String>{};
  for (final a in argv) {
    if (!a.startsWith('--')) continue;
    final eq = a.indexOf('=');
    if (eq < 0) {
      m[a.substring(2)] = '';
    } else {
      m[a.substring(2, eq)] = a.substring(eq + 1);
    }
  }
  return m;
}

Qq8ClientProfile _pickProfile(String name) {
  if (name == 'default') return qq8DefaultProfile;
  final p = qq8ClientProfiles[name];
  if (p == null) {
    errOut('✗ 未知档案 "$name"，可选: ${qq8ClientProfiles.keys.join(", ")}');
    exit(2);
  }
  return p;
}

Uint8List _ksid(Qq8Device d, Qq8ClientProfile p) =>
    Uint8List.fromList(utf8.encode('|${d.imei}|${p.apk.name}'));

Uint8List _randomBytes(int n) {
  final r = math.Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

Uint8List _fill(int n, int v) => Uint8List(n)..fillRange(0, n, v);

Uint8List _hex(String s) {
  final clean = s.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (clean.length.isOdd) {
    throw FormatException('hex 长度必须是偶数: ${clean.length}');
  }
  return Uint8List.fromList(List<int>.generate(clean.length ~/ 2,
      (i) => int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16)));
}

String _hexOf(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

String _typeMeaning(int t) => switch (t) {
      0 => '成功',
      1 => '账号或密码错误',
      2 => '需要滑动验证码',
      15 => 'token 失效',
      16 => 'token 失效',
      40 => '账号冻结',
      45 => '禁止登录（版本门/风控）',
      160 => '需要短信验证',
      162 => '短信次数过多',
      163 => '短信码错误',
      204 => '设备锁',
      237 => 'ticket 错误（安全提醒）',
      239 => '需要短信验证',
      _ => '其它/失败',
    };
