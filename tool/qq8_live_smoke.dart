/// QQ 登录真机冒烟测试
///
/// ## 默认行为是 **dry-run**
///
/// 不带 `--send` 时**完全不联网**：只把登录包组装出来，打印每一层的尺寸、
/// 26 个 TLV 的编号与长度，以及包头的十六进制。用来在上真机前再核一遍组包。
///
/// ## 真发需要两道确认
///
/// ```bash
/// # Windows PowerShell
/// $env:QQ_LIVE_UIN="10001"
/// $env:QQ_LIVE_PWD="..."
/// $env:QQ_LIVE_CONFIRM="I_UNDERSTAND_THE_RISK"
/// dart run tool/qq8_live_smoke.dart --send
/// ```
///
/// 1. 必须在命令行显式给 `--send`；
/// 2. 必须显式设置 `QQ_LIVE_CONFIRM`。
///
/// 这不是仪式：本工程的安全层（`lib/kernel/safety/`）就是为避免"顺手连生产
/// 环境"而写的，工具层也要遵守同一条纪律。
///
/// ## 只发一次，不重试
///
/// 用 `LoginAttemptLimiter` 做限流（10 分钟 3 次、连续失败递增冷却、
/// 5 次后硬锁 24 小时）。**失败就停**——重试本身是风控特征。
///
/// ## 票据续期（token 登录，低风险形态）
///
/// 登录成功后可以把票据存下来（`--save-token=<path>`），之后用
/// `--token-login` 直接续期——**不需要再发密码**（子命令 11 /
/// `wtlogin.exchange_emp`，清单见 `qq8ExchangeEmpTlvOrder`）。
///
/// ```bash
/// # 1) 密码登录成功后保存票据（文件是明文会话凭据：别进 git、用完即删）
/// dart run tool/qq8_live_smoke.dart --send --save-token=token.json
/// # 2) 之后只用票据续期
/// dart run tool/qq8_live_smoke.dart --send --token-login --token-file=token.json
/// ```
///
/// 续期时 `tgtgt = MD5(d2key)`——与 oicq `login-password.js` 的 token
/// 路径一致（没有密码就没法刷新 cookie，这是官方语义）。
///
/// ## 实验开关（服务端静默丢弃时的排查矩阵）
///
/// | 开关 | 效果 |
/// |---|---|
/// | `--profile=8.2.11` | 换老档案（ssoVer 7，最接近 oicq 实测能通的形态） |
/// | `--tlv-set=oicq` | 密码登录改发 oicq 的 24 项清单（去掉 `0x544` 空体） |
///
/// 两者默认都不开：默认走官方档案 + 官方清单（37 项超集经 guard 后实发）。
///
/// ## 绝不打印凭据
///
/// 口令、`tgtgt`、票据、`d2key`、会话密钥一律不进日志（见 `Redact`）。
/// 响应只打印 `type` 和 TLV 的**编号与长度**，不打印票据内容。
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/qq8_live_smoke.dart
/// ```
library;

import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/infra/log/log_file.dart';
import 'package:qqclient/infra/log/logger.dart';
import 'package:qqclient/kernel/crypto/ecdh.dart';
import 'package:qqclient/kernel/safety/attempt_limiter.dart';
import 'package:qqclient/kernel/wlogin8/qq8_config.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_login.dart';
import 'package:qqclient/kernel/wlogin8/qq8_profiles.dart';
import 'package:qqclient/kernel/wlogin8/qq8_sso.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tlv.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tran.dart';

final Logger _log = Log.get('SMOKE');

/// 真发所需的确认串。
const String kConfirmToken = 'I_UNDERSTAND_THE_RISK';

/// 参考实现 oicq 的密码登录清单（**24 项**，用于 `--tlv-set=oicq` 实验）。
///
/// 出处：oicq `lib/wtlogin/login-password.js` 的 `passwordLogin`，长期实测
/// 可通。与官方清单的差别正是我们多发的两个降级 TLV：
/// `0x544`（安全 SDK 空体）与 `0x545`（QIMEI，已按官方 guard 滤掉）——
/// 即官方清单 37 项里首登实际发出的 26 项中，减去这两个 = 本清单 24 项。
///
/// ⚠️ 这是**实验开关**：默认仍走官方清单（`--tlv-set=official`）。
/// 只在官方清单被服务端静默丢弃、需要排查"是不是这两个 TLV 惹的"时才用。
const List<int> kOicqPasswordTlvOrder = <int>[
  0x18, 0x01, 0x106, 0x116, 0x100, 0x107, 0x108, 0x142,
  0x144, 0x145, 0x147, 0x154, 0x141, 0x08, 0x511, 0x187,
  0x188, 0x194, 0x191, 0x202, 0x177, 0x516, 0x521, 0x525,
];

Future<void> main(List<String> argv) async {
  final args = _parseArgs(argv);

  // ---------- 日志 ----------
  final logDir = Directory(
    args['logdir'] ??
        '${Directory.systemTemp.path}${Platform.pathSeparator}qqclient-logs',
  );
  Log.configure(minLevel: LogLevel.debug, ringCapacity: 4000);
  Log.addSink(FileLogSink(logDir));

  stdout.writeln('=' * 70);
  stdout.writeln('QQ 登录冒烟测试');
  stdout.writeln('=' * 70);

  // token 续期模式（--token-login）与密码登录共用后面的收发流水线，
  // 差别只在"组什么 body / 用哪个命令字 / 响应用什么 key 解"。
  final useToken = args.containsKey('token-login');

  // dry-run 不联网、固定随机源（可复现）；真发走按 uin 派生的设备。
  final deterministic = !args.containsKey('send');

  // 密码登录的 TLV 清单：默认官方（超集 + guard）；`--tlv-set=oicq` 走
  // 参考实现的 24 项清单（实验开关，见 kOicqPasswordTlvOrder 注释）。
  final tlvSet = args['tlv-set'] ?? 'official';
  if (tlvSet != 'official' && tlvSet != 'oicq') {
    stderr.writeln('✗ --tlv-set 只支持 official / oicq，收到 "$tlvSet"');
    exit(2);
  }

  if (!args.containsKey('send')) {
    stdout.writeln('模式: **dry-run**（不联网）');
  } else {
    stdout.writeln('模式: **真实发送**');
  }
  stdout.writeln('登录方式: ${useToken ? "token 续期（子命令 11）" : "密码登录（子命令 9）"}');
  stdout.writeln('日志目录: ${logDir.path}');
  stdout.writeln('');

  // ---------- 档案 ----------
  final profileName = args['profile'] ?? 'default';
  final profile = _pickProfile(profileName);

  // 本次实际使用的 TLV 清单：token 路径用 exchange_emp 清单；
  // 密码路径默认官方超集，`--tlv-set=oicq` 时换成参考实现的 24 项清单。
  final order = useToken
      ? qq8ExchangeEmpTlvOrder
      : (tlvSet == 'oicq' ? kOicqPasswordTlvOrder : profile.apk.loginTlvOrder);

  stdout.writeln('--- 客户端档案 ---');
  stdout.writeln('  ${profile.describe()}');
  stdout.writeln(
    '  TLV 清单: ${useToken ? "exchange_emp（16 项）" : (tlvSet == "oicq" ? "oicq 24 项（实验）" : "官方超集 ${profile.apk.loginTlvOrder.length} 项")}',
  );
  if (profile.unverified.isNotEmpty) {
    stdout.writeln('  ⚠ 未核实字段: ${profile.unverified.join(', ')}');
  }
  stdout.writeln('');

  // ---------- 票据文件（token 续期用）----------
  final tokenPath = args['token-file'] ?? args['save-token'];
  _TokenFile? token;
  if (useToken || args.containsKey('token-file')) {
    if (tokenPath == null || tokenPath.isEmpty) {
      stderr.writeln('✗ --token-login / --token-file 需要给出文件路径'
          '（--token-file=<path>）');
      exit(2);
    }
    try {
      token = _TokenFile.load(File(tokenPath));
    } on Object catch (e) {
      stderr.writeln('✗ 票据文件读取失败: $e');
      exit(2);
    }
    stdout.writeln('--- 票据 ---');
    stdout.writeln('  文件: $tokenPath');
    stdout.writeln('  uin: ${token.uin}（保存于 ${token.savedAt}）');
    stdout.writeln('  tgt ${token.tgt.length} 字节 / d2 ${token.d2.length} 字节'
        ' / d2key ${token.d2key.length} 字节');
    stdout.writeln('');
  }
  if (useToken && token == null) {
    stderr.writeln('✗ --token-login 必须配 --token-file=<path>');
    exit(2);
  }
  if (useToken && token!.d2.isEmpty) {
    stderr.writeln('✗ 票据文件里没有 d2——token 续期的核心载荷缺失，无法发送');
    exit(2);
  }

  // ---------- 账号 ----------
  final uinStr = args['uin'] ?? Platform.environment['QQ_LIVE_UIN'];
  Uint8List? passwordMd5;
  if (args['pwd-md5'] != null) {
    passwordMd5 = _hex(args['pwd-md5']!);
  } else {
    final pwd = args['pwd'] ?? Platform.environment['QQ_LIVE_PWD'];
    if (pwd != null && pwd.isNotEmpty) {
      passwordMd5 = md5Bytes(Uint8List.fromList(utf8.encode(pwd)));
    }
  }

  final uin = token?.uin ?? int.tryParse(uinStr ?? '') ?? 10001;

  stdout.writeln('--- 账号 ---');
  stdout.writeln('  uin: $uin');
  stdout.writeln(
    '  设备: ${deterministic ? "固定夹具（dry-run 可复现）" : "按 uin 派生（同账号恒定同一套）"}',
  );
  if (useToken) {
    stdout.writeln('  口令: 不需要（本次是 token 续期）');
  } else {
    stdout.writeln(
      '  口令: ${passwordMd5 == null ? "未提供（用占位值，仅用于组包验证）" : "已提供"}',
    );
    if (passwordMd5 != null) {
      stdout.writeln('    ${Redact.fingerprint("pwd_md5", passwordMd5)}');
    }
  }
  stdout.writeln('');

  // ---------- 组包 ----------
  // 设备身份：真发用 `Qq8Device.generate(uin)`——同一账号恒定同一套
  // imei/guid/mac，避免"设备频繁变化"这个风控信号（oicq 用
  // device-<uin>.json 持久化也是同一个思路）。dry-run 用固定夹具。
  var device = deterministic
      ? _buildDevice(deterministic: true)
      : Qq8Device.generate(uin);
  // token 续期时 tgtgt = MD5(d2key)：没有密码就没法用 t106 派生新的
  // tgtgt，只能沿用这个约定值（oicq `login-password.js` 的 token 分支同款）。
  if (useToken) {
    device = device.withTgtgt(md5Bytes(token!.d2key));
  }
  final ecdh = Ecdh.exchange(
    Uint8List.fromList(Qq8Config.serverEcdhPublicKey),
  );

  final tlvCtx = Qq8TlvContext(
    uin: uin,
    apk: profile.apk,
    device: device,
    passwordMd5: passwordMd5 ?? Uint8List(16),
    seqId: deterministic ? 100 : DateTime.now().millisecondsSinceEpoch & 0x7FFF,
    ksid: _ksid(device, profile),
    t104: Uint8List(0), // 首登无缓存盐 → 0x104 会被 guard 滤掉
    t174: Uint8List(0),
    tgt: useToken ? token!.tgt : Uint8List(0),
    srmToken: Uint8List(0),
  );

  final body = useToken
      ? Qq8LoginBody.buildToken(tlvCtx, d2: token!.d2)
      : Qq8LoginBody.build(tlvCtx, Qq8SubCmd.password, order);

  // token 续期的票据要贯穿三层：SSO 信封的 tgt/d2（sig）、body 的 0x143（d2）。
  Qq8SigInfo? tokenSig;
  if (useToken) {
    final t = token!;
    tokenSig = Qq8SigInfo(
      tgt: t.tgt,
      d2: t.d2,
      d2key: t.d2key,
      sigKey: t.sigKey,
      ticketKey: t.ticketKey,
      srmToken: t.srmToken,
    );
  }

  final ssoCtx = Qq8SsoContext(
    uin: uin,
    apk: profile.apk,
    device: device,
    sessionId: deterministic
        ? _hex('01020304')
        : _randomBytes(4),
    randomKey: deterministic ? _fill(16, 0x0f) : _randomBytes(16),
    ecdhPublicKey: ecdh.publicKey,
    ecdhShareKey: ecdh.shareKey,
    seqId: tlvCtx.seqId,
    sig: tokenSig,
  );

  final oicqPacket = Qq8Sso.buildOicqPacket(ssoCtx, body);
  final loginPacket = Qq8Sso.buildLoginPacket(
    ssoCtx,
    useToken ? qq8ExchangeEmpCmd : qq8LoginCmd,
    oicqPacket,
    Qq8LoginType.login,
  );

  // ---------- 打印结构 ----------
  _printPacketReport(
    body: body,
    oicqPacket: oicqPacket,
    loginPacket: loginPacket,
    profile: profile,
    order: order,
    shareKey: ecdh.shareKey,
  );

  if (!args.containsKey('send')) {
    stdout.writeln('');
    stdout.writeln('dry-run 结束。要真发请加 --send，并设置 QQ_LIVE_CONFIRM=');
    stdout.writeln('  $kConfirmToken');
    await _finish(logDir, args);
    return;
  }

  // ---------- 真发前的两道闸门 ----------
  stdout.writeln('');
  stdout.writeln('--- 发送前检查 ---');

  final confirm = Platform.environment['QQ_LIVE_CONFIRM'];
  if (confirm != kConfirmToken) {
    stdout.writeln('  ✗ 未设置 QQ_LIVE_CONFIRM');
    stdout.writeln('    本工具拒绝在无显式确认的情况下连生产服务器。');
    stdout.writeln('    确认理解风险后：\$env:QQ_LIVE_CONFIRM="' '$kConfirmToken"');
    await _finish(logDir, args);
    exitCode = 2;
    return;
  }
  stdout.writeln('  ✓ 显式确认已给出');

  if (!useToken && passwordMd5 == null) {
    stdout.writeln('  ✗ 未提供口令，无法真发（设 QQ_LIVE_PWD 或 --pwd-md5）');
    await _finish(logDir, args);
    exitCode = 2;
    return;
  }

  // 限流器（持久化到日志目录旁边）
  final limiterFile =
      File('${logDir.parent.path}${Platform.pathSeparator}qqclient-attempts.json');
  final limiter = LoginAttemptLimiter(persistFile: limiterFile);
  await limiter.load();
  final status = limiter.status();
  stdout.writeln('  限流: ${status.describe()}');
  if (!status.allowed) {
    stdout.writeln('  ✗ 被限流器拒绝，本次不发');
    await _finish(logDir, args);
    exitCode = 3;
    return;
  }

  final begun = await limiter.beginAttempt();
  if (!begun.allowed) {
    stdout.writeln('  ✗ 记录后仍不允许：${begun.describe()}');
    await _finish(logDir, args);
    exitCode = 3;
    return;
  }

  // ---------- 真发 ----------
  stdout.writeln('');
  stdout.writeln('--- 连接 ---');
  final tran = Qq8TcpTransport();
  stdout.writeln('  目标: ${tran.host}:${tran.port}');
  _log.i('连接 ${tran.host}:${tran.port}');

  Qq8LoginResponse? resp;
  Object? failure;
  try {
    await tran.connect();
    stdout.writeln('  已连接');
    _log.i('已连接');

    stdout.writeln('--- 发送登录请求（${loginPacket.length} 字节）---');
    final payload = await tran.send(loginPacket);
    stdout.writeln('  收到响应 ${payload.length} 字节');
    _log.i('收到响应 ${payload.length} 字节');

    resp = Qq8LoginResponse.parse(payload, ecdh.shareKey);
  } on Object catch (e, st) {
    failure = e;
    _log.e('登录失败', error: e, stack: st);
    stdout.writeln('  ✗ 失败: $e');
  } finally {
    await tran.close();
  }

  if (failure != null) {
    await limiter.recordFailure(reasonCode: failure.runtimeType.toString());
    stdout.writeln('');
    stdout.writeln('已记录一次失败。**不要马上重试**——重试本身是风控特征。');
    await _finish(logDir, args);
    exitCode = 1;
    return;
  }

  // ---------- 判读 ----------
  stdout.writeln('');
  stdout.writeln('--- 响应判读 ---');
  final r = resp!;
  stdout.writeln('  type = ${r.type}  (${_typeMeaning(r.type)})');
  if (r.needsSlider) {
    stdout.writeln('  滑动验证地址: ${r.sliderUrl}');
  }
  stdout.writeln('  TLV 列表（只列编号与长度，不打印内容）:');
  final tags = r.tlvs.keys.toList()..sort();
  for (final t in tags) {
    stdout.writeln(
      '    0x${t.toRadixString(16).padLeft(4, '0')}  ${r.tlvs[t]!.length} 字节',
    );
  }
  stdout.writeln('  明文长度: ${r.plain.length}');

  if (r.isSuccess) {
    await limiter.recordSuccess();
    stdout.writeln('');
    stdout.writeln('  ✓ type=0：登录被接受');
    if (r.t119 != null) {
      stdout.writeln('  票据块 0x119 长度 ${r.t119!.length}');
      try {
        final sig = Qq8SigBundle.parse(r.t119!, device.tgtgt);
        stdout.writeln('    票据解出:');
        stdout.writeln('      tgt      ${sig.tgt?.length ?? 0} 字节');
        stdout.writeln('      d2       ${sig.d2?.length ?? 0} 字节');
        stdout.writeln('      d2key    ${sig.d2key?.length ?? 0} 字节');
        stdout.writeln('      sig_key  ${sig.sigKey?.length ?? 0} 字节');
        stdout.writeln('      ticket   ${sig.ticketKey?.length ?? 0} 字节');
        stdout.writeln('      srm      ${sig.srmToken?.length ?? 0} 字节');

        final savePath = args['save-token'];
        if (savePath != null && savePath.isNotEmpty) {
          _TokenFile(
            uin: uin,
            savedAt: DateTime.now().toIso8601String(),
            tgt: sig.tgt ?? Uint8List(0),
            d2: sig.d2 ?? Uint8List(0),
            d2key: sig.d2key ?? Uint8List(0),
            sigKey: sig.sigKey ?? Uint8List(0),
            ticketKey: sig.ticketKey ?? Uint8List(0),
            srmToken: sig.srmToken ?? Uint8List(0),
          ).save(File(savePath));
          stdout.writeln('  票据已保存: $savePath');
          stdout.writeln('  （明文会话凭据：别进 git，用完即删）');
        }
      } on Object catch (e) {
        stdout.writeln('    ✗ 0x119 解析失败: $e');
      }
    }
  } else {
    await limiter.recordFailure(reasonCode: 'type=${r.type}');
    stdout.writeln('');
    stdout.writeln('  ⚠ 非成功码。已记录失败。');
  }

  await _finish(logDir, args);
  exitCode = r.isSuccess ? 0 : 1;
}

// ---------------------------------------------------------------------------
// 打印
// ---------------------------------------------------------------------------

void _printPacketReport({
  required Uint8List body,
  required Uint8List oicqPacket,
  required Uint8List loginPacket,
  required Qq8ClientProfile profile,
  required List<int> order,
  required Uint8List shareKey,
}) {
  stdout.writeln('--- 登录 body ---');
  final subCmd = (body[0] << 8) | body[1];
  final count = (body[2] << 8) | body[3];
  stdout.writeln('  子命令 = $subCmd (${_subCmdName(subCmd)})');
  stdout.writeln('  TLV 个数 = $count');
  stdout.writeln('  body 总长 = ${body.length}');

  final tlvs = qq8ReadTlv(body, offset: 4);
  stdout.writeln('  TLV 明细:');
  for (final entry in tlvs.entries) {
    final tag = entry.key;
    final len = entry.value.length;
    final skip = _skippedNote(tag, profile);
    stdout.writeln(
      '    0x${tag.toRadixString(16).padLeft(4, '0')}  '
      '${len.toString().padLeft(5)} 字节$skip',
    );
  }
  stdout.writeln('  （顺序表 ${order.length} 项，'
      '被 guard 滤掉 ${order.length - count} 项）');

  stdout.writeln('');
  stdout.writeln('--- 三层信封尺寸 ---');
  stdout.writeln('  body        ${body.length}');
  stdout.writeln('  OICQ 信封    ${oicqPacket.length}  (前置随机密钥 + ECDH 公钥 + TEA(body))');
  stdout.writeln('  登录信封     ${loginPacket.length}');
  final declared = (loginPacket[0] << 24) |
      (loginPacket[1] << 16) |
      (loginPacket[2] << 8) |
      loginPacket[3];
  stdout.writeln('  首 4 字节声明的总长 = $declared  '
      '${declared == loginPacket.length ? "✓ 与实体一致" : "✗ 不一致！"}');

  stdout.writeln('');
  stdout.writeln('--- 包头（前 48 字节）---');
  stdout.writeln('  ${_hexOf(loginPacket.take(48).toList())}');
  stdout.writeln('  说明: 前 4 字节为长度，其后是 0x0A / type / d2 / uin …');
  stdout.writeln('  ECDH 共享密钥 ${Redact.fingerprint("share_key", shareKey)}');
}

String _skippedNote(int tag, Qq8ClientProfile p) {
  switch (tag) {
    case 0x544:
      return '  (安全 SDK 降级 body)';
    case 0x553:
      return '  (fekit attach 降级 body)';
    default:
      return '';
  }
}

String _subCmdName(int v) => switch (v) {
      Qq8SubCmd.password => '密码登录',
      Qq8SubCmd.slider => '滑动验证',
      Qq8SubCmd.submitSms => '提交短信验证码',
      Qq8SubCmd.sendSms => '请求下发短信',
      Qq8SubCmd.token => 'token 登录',
      Qq8SubCmd.device => '设备锁',
      _ => '未知',
    };

String _typeMeaning(int t) => switch (t) {
      Qq8LoginResultType.success => '成功',
      Qq8LoginResultType.slider => '需要滑动验证码',
      Qq8LoginResultType.deviceLock => '设备锁 / 二次验证',
      1 => '失败',
      3 => '失败',
      4 => '失败',
      40 => '密码错误',
      _ => '其它/失败',
    };

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

Map<String, String> _parseArgs(List<String> argv) {
  final out = <String, String>{};
  for (final a in argv) {
    if (!a.startsWith('--')) continue;
    final body = a.substring(2);
    final eq = body.indexOf('=');
    if (eq >= 0) {
      out[body.substring(0, eq)] = body.substring(eq + 1);
    } else {
      out[body] = '';
    }
  }
  return out;
}

Qq8ClientProfile _pickProfile(String name) {
  if (name == 'default') return qq8DefaultProfile;
  final p = qq8ClientProfiles[name];
  if (p == null) {
    stderr.writeln('未知档案 "$name"，可选: ${qq8ClientProfiles.keys.join(", ")}');
    exit(2);
  }
  return p;
}

Qq8Device _buildDevice({required bool deterministic}) {
  final mac = deterministic ? '00:50:56:C0:00:08' : _randomMac();
  return Qq8Device(
    product: 'piano',
    device: 'piano',
    board: 'piano',
    brand: 'Xiaomi',
    model: '25091RP04C',
    bootloader: 'unknown',
    fingerprint: 'Xiaomi/piano/piano:16/BP2A/eng:user/release-keys',
    bootId: deterministic
        ? '11111111-2222-3333-4444-555555555555'
        : _randomUuid(),
    procVersion: 'Linux version 5.15.0',
    baseband: '',
    sim: 'T-Mobile',
    apn: 'wifi',
    osType: 'android',
    macAddress: mac,
    ipAddress: '10.0.0.1',
    wifiBssid: mac,
    wifiSsid: 'TP-LINK-2711',
    imei: deterministic ? '860000000000001' : _randomImei(),
    androidId: deterministic ? 'ABCDEF1234567890' : _randomHex(16),
    version: const Qq8AndroidVersion(
      release: '16',
      codename: 'REL',
      incremental: 'BP2A.250605.031.A3',
      sdk: 36,
    ),
    imsi: deterministic ? _fill(16, 0x22) : _randomBytes(16),
    tgtgt: deterministic
        ? _hex('ffeeddccbbaa99887766554433221100')
        : _randomBytes(16),
    guid: deterministic ? _hex('00112233445566778899aabbccddeeff') : _randomBytes(16),
  );
}

Uint8List _ksid(Qq8Device d, Qq8ClientProfile p) =>
    Uint8List.fromList(utf8.encode('|${d.imei}|${p.apk.name}'));

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(n, (_) => r.nextInt(256), growable: false),
  );
}

Uint8List _fill(int n, int v) =>
    Uint8List.fromList(List<int>.filled(n, v, growable: false));

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hexOf(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join(' ');

String _randomHex(int n) =>
    List<int>.generate(n, (_) => Random.secure().nextInt(16))
        .map((v) => v.toRadixString(16))
        .join();

String _randomMac() {
  final r = Random.secure();
  return List<int>.generate(6, (_) => r.nextInt(256))
      .map((v) => v.toRadixString(16).padLeft(2, '0'))
      .join(':');
}

String _randomImei() {
  final r = Random.secure();
  return '86${List<int>.generate(13, (_) => r.nextInt(10)).join()}';
}

String _randomUuid() {
  final h = _randomHex(32);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
      '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// 票据文件（明文 JSON、hex 编码）——**只在显式给出路径时读写**。
///
/// 里面是会话凭据（tgt / d2 / d2key / …），不是口令；即便如此也别进 git。
/// 字段名与 [Qq8SigBundle] 对应，`uin` 用于校验是同一个号。
class _TokenFile {
  final int uin;
  final String savedAt;
  final Uint8List tgt;
  final Uint8List d2;
  final Uint8List d2key;
  final Uint8List sigKey;
  final Uint8List ticketKey;
  final Uint8List srmToken;

  const _TokenFile({
    required this.uin,
    required this.savedAt,
    required this.tgt,
    required this.d2,
    required this.d2key,
    required this.sigKey,
    required this.ticketKey,
    required this.srmToken,
  });

  static _TokenFile load(File f) {
    if (!f.existsSync()) {
      throw FormatException('文件不存在: ${f.path}');
    }
    final Object? raw = jsonDecode(f.readAsStringSync());
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('不是 JSON 对象');
    }
    final uin = raw['uin'];
    if (uin is! int) {
      throw const FormatException('缺少 uin');
    }
    Uint8List hexField(String key) {
      final v = raw[key];
      if (v is! String || v.isEmpty) return Uint8List(0);
      return _hex(v);
    }

    return _TokenFile(
      uin: uin,
      savedAt: '${raw['saved_at'] ?? '?'}',
      tgt: hexField('tgt'),
      d2: hexField('d2'),
      d2key: hexField('d2key'),
      sigKey: hexField('sig_key'),
      ticketKey: hexField('ticket_key'),
      srmToken: hexField('srm_token'),
    );
  }

  void save(File f) {
    const encoder = JsonEncoder.withIndent('  ');
    f.writeAsStringSync(encoder.convert(<String, Object?>{
      'uin': uin,
      'saved_at': savedAt,
      'tgt': _plainHex(tgt),
      'd2': _plainHex(d2),
      'd2key': _plainHex(d2key),
      'sig_key': _plainHex(sigKey),
      'ticket_key': _plainHex(ticketKey),
      'srm_token': _plainHex(srmToken),
    }));
  }
}

/// 无分隔符的小写 hex（票据文件用）。
String _plainHex(List<int> b) =>
    b.map((v) => (v & 0xff).toRadixString(16).padLeft(2, '0')).join();

Future<void> _finish(Directory logDir, Map<String, String> args) async {
  await Log.flush();
  if (args.containsKey('export-log')) {
    final f = await LogExporter.exportToDirectory(
      logDir,
      metadata: <String, Object?>{
        'tool': 'qq8_live_smoke',
        'dart': Platform.version.split(' ').first,
        'os': Platform.operatingSystem,
        'mode': args.containsKey('send') ? 'send' : 'dry-run',
        'profile': args['profile'] ?? 'default',
      },
      logDirectory: logDir,
    );
    stdout.writeln('');
    stdout.writeln('日志已导出: ${f.path}');
  } else {
    stdout.writeln('');
    stdout.writeln('（加 --export-log 可导出日志报告）');
  }
}
