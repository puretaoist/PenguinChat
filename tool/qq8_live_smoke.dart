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
/// ## 被要求人机验证时（滑动验证码）
///
/// 密码登录若被要求验证（响应 `type=2`，`0x192` 是验证地址），工具会把
/// 响应下发的**盐（0x104）**存进 `qq8-slider-state.json` 并打印验证地址。
/// **由人**把滑块解掉（解自己账号的验证属正常流程；这里不做任何自动化或
/// 绕过），拿到 ticket 后提交继续（子命令 2，清单 `qq8SliderTlvOrder`）：
///
/// ```bash
/// dart run tool/qq8_live_smoke.dart --send --slider-ticket=<ticket>
/// # 盐默认读 qq8-slider-state.json；也可 --slider-salt=<hex> 显式给
/// ```
///
/// ## 手机号短信登录（--phone / --phone-code，两段）
///
/// 不需要口令：服务端 208 回包给盐/随机数/msalt，19 号下发短信，18 号提交
/// 验证码；通过之后**还要**用本地现生成的 `mpasswd` 当口令再走一次子命令 9
/// 才拿得到票据（官方 `GetStViaSMSVerifyLogin` 同款两步，服务层自动接上）。
///
/// ```bash
/// # 第 1 段：检查手机号 + 下发验证码（材料落 qq8-phone-state.json）
/// dart run tool/qq8_live_smoke.dart --send --phone=13800138000
/// # 第 2 段：提交收到的验证码（码一次性，接着会自动续一次口令登录）
/// dart run tool/qq8_live_smoke.dart --send --phone-code=654321
/// ```
///
/// 真实服务器会按服务端策略发短信（次数上限见响应 `0x182`）；两段都要
/// `--send` + `QQ_LIVE_CONFIRM`，第 2 段还过限流器（提交就是一次登录）。
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
import 'package:qqclient/kernel/crypto/tea.dart';
import 'package:qqclient/kernel/safety/attempt_limiter.dart';
import 'package:qqclient/client_api/qq8_login_service.dart';
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

final Logger _log = Log.get('SMOKE');

/// 真发所需的确认串。
const String kConfirmToken = 'I_UNDERSTAND_THE_RISK';

/// 参考实现 oicq 的密码登录清单（**恰好 25 项**，用于 `--tlv-set=oicq` 实验）。
///
/// 出处：oicq **2.3.1**（2022-06）`lib/core/base-client.ts` 的 `passwordLogin`
/// ——`writeU16(9) + writeU16(25)` 后面那 25 项，逐项照抄。
///
/// 与**旧一代**（`lib/wtlogin/login-password.js`，24 项）的差别有两处，
/// 别抄错世代（两份都在 `analysis/_ref/` 下）：
/// * **去掉了 `0x108`**（ksid）；
/// * **加了 `0x544`**（v=2 结构占位，`t(0x544, 2, 9)`）与 **`0x545`**（QIMEI，
///   取不到时退回 IMEI 字符串）。
///
/// ⚠️ 这是**实验开关**：默认仍走官方清单（`--tlv-set=official`）。
const List<int> kOicqPasswordTlvOrder = <int>[
  0x18, 0x01, 0x106, 0x116, 0x100, 0x107, 0x142, 0x144, 0x145, 0x147,
  0x154, 0x141, 0x08, 0x511, 0x187, 0x188, 0x194, 0x191, 0x202, 0x177,
  0x516, 0x521, 0x525, 0x544, 0x545,
];

/// 本次运行的"全程记录"文件（`<logDir>/qq8-run-<时间戳>.log`）。
///
/// 为什么要它：真机跑的时候用户很可能直接关窗口或 Ctrl-C——那时 ring 日志还
/// 没导出，控制台的内容一关就没了（踩过：扫码失败想知道服务端原话，结果什么
/// 都没留下）。所以 `out`/`errOut` 每行都**同步追加**到这个文件里。
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

/// 同 [out]，但走 stderr（错误信息仍旧打到标准错误）。
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
  );
  Log.configure(minLevel: LogLevel.debug, ringCapacity: 4000);
  Log.addSink(FileLogSink(logDir));
  // 全程双写：控制台关了就靠这个文件
  _runLogFile = File('${logDir.path}${Platform.pathSeparator}'
      'qq8-run-${DateTime.now().millisecondsSinceEpoch}.log');

  out('=' * 70);
  out('QQ 登录冒烟测试');
  out('=' * 70);

  // token 续期模式（--token-login）与密码登录共用后面的收发流水线，
  // 差别只在"组什么 body / 用哪个命令字 / 响应用什么 key 解"。
  final useToken = args.containsKey('token-login');

  // 滑动验证提交模式（--slider-ticket）：密码登录被要求验证（type=2）后，
  // **人工**解出 ticket，用响应里下发的盐（0x104）提交、继续登录。
  final sliderTicket = args['slider-ticket'];
  final useSlider = sliderTicket != null;

  // 验证分支（都读 qq8-slider-state.json 里存下的盐/令牌）：
  //   --send-sms        请求下发短信验证码（子命令 8；需 0x104 + 0x174）
  //   --sms-code=NNNNNN 提交短信验证码（子命令 7；需 0x104 + 0x174）
  //   --device-unlock   设备锁解锁（子命令 20；只需 0x104）
  final useSendSms = args.containsKey('send-sms');
  final smsCode = args['sms-code'];
  final useSubmitSms = smsCode != null;
  final useDeviceUnlock = args.containsKey('device-unlock');
  final verifyBranchCount = [useSlider, useSendSms, useSubmitSms, useDeviceUnlock]
      .where((v) => v)
      .length;
  if (verifyBranchCount > 1) {
    errOut('✗ --slider-ticket / --send-sms / --sms-code / --device-unlock '
        '一次只能用一个');
    exit(2);
  }

  // dry-run 不联网、固定随机源（可复现）；真发走按 uin 派生的设备。
  final deterministic = !args.containsKey('send');

  // 密码登录的 TLV 清单：默认官方（超集 + guard）；`--tlv-set=oicq` 走
  // 参考实现的 24 项清单（实验开关，见 kOicqPasswordTlvOrder 注释）。
  final tlvSet = args['tlv-set'] ?? 'official';
  if (tlvSet != 'official' && tlvSet != 'oicq') {
    errOut('✗ --tlv-set 只支持 official / oicq，收到 "$tlvSet"');
    exit(2);
  }

  if (!args.containsKey('send')) {
    out('模式: **dry-run**（不联网）');
  } else {
    out('模式: **真实发送**');
  }
  out(
    '登录方式: ${_modeLabel(useSlider: useSlider, useSendSms: useSendSms, useSubmitSms: useSubmitSms, useDeviceUnlock: useDeviceUnlock, useToken: useToken, useQrcode: args.containsKey('qrcode'), usePhone: args.containsKey('phone') || args.containsKey('phone-code'))}',
  );
  out('日志目录: ${logDir.path}');
  out('');

  // ---------- 二维码扫码登录（--qrcode）----------
  //
  // 走 L3 服务层（`Qq8LoginService`）而不是本文件里那套低层流程：扫码是三段
  // 往返 + 轮询的长流程，正是服务层存在的意义；这里只是把它接到命令行上。
  if (args.containsKey('qrcode')) {
    final confirm = Platform.environment['QQ_LIVE_CONFIRM'];
    if (!args.containsKey('send') || confirm != kConfirmToken) {
      out('✗ 二维码取码也要真连服务器：加 --send 并设 '
          'QQ_LIVE_CONFIRM="$kConfirmToken"');
      await _finish(logDir, args);
      exitCode = 2;
      return;
    }
    final expectedUin =
        int.tryParse(args['uin'] ?? Platform.environment['QQ_LIVE_UIN'] ?? '') ?? 0;
    final rounds = int.tryParse(args['qrcode-rounds'] ?? '60') ?? 60;

    // 档案：扫码这条以前也**没把 --profile 传进来**（与手机号那条同一个缺口）。
    final qrProfile = _pickProfile(args['profile'] ?? 'default');
    out('  档案: ${qrProfile.describe()}');
    final svc = Qq8LoginService(
      profile: qrProfile,
      tokenStore: FileQq8TokenStore(logDir),
      heartbeatInterval: const Duration(seconds: 270),
    );
    // 扫码这条以前不留原始响应，真机上一失败只能干看着。这里接上诊断钩子：
    // 每条响应落一个 json（frame_hex + share_key + type + 0x146 文案），
    // 与密码那条路同格式，失败后可以直接离线复解。
    svc.onDiagnostic = (tag, frame, parsed) {
      try {
        final dump = <String, Object?>{
          'at': DateTime.now().toIso8601String(),
          'tag': tag,
          'share_key': _plainHex(svc.debugShareKey ?? Uint8List(0)),
          'frame_hex': _plainHex(frame),
          if (parsed != null) 'type': parsed.type,
          if (parsed?.serverMessage != null)
            't146_title': parsed!.serverMessage!.$1,
          if (parsed?.serverMessage != null)
            't146_content': parsed!.serverMessage!.$2,
          if (parsed != null)
            'tlvs': parsed.tlvs.keys
                .map((t) => '0x${t.toRadixString(16)}')
                .toList(),
        };
        final f = File('${logDir.path}${Platform.pathSeparator}'
            'qq8-response-${DateTime.now().millisecondsSinceEpoch}-$tag.json');
        f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(dump));
        out('  （响应已存 ${f.path}）');
      } on Object catch (e) {
        out('  （响应落盘失败：$e）');
      }
    };
    // 扫码这条**也要过同一个限流器**：以前漏了，等于给自己留了个后门
    // （21:17 那次扫码失败就没被记上，账号保护形同虚设）。限流器不能绕过。
    final qrLimiterFile = File(
        '${logDir.parent.path}${Platform.pathSeparator}qqclient-attempts.json');
    final qrLimiter = LoginAttemptLimiter(persistFile: qrLimiterFile);
    await qrLimiter.load();
    final qrStatus = qrLimiter.status();
    out('  限流: ${qrStatus.describe()}');
    if (!qrStatus.allowed) {
      out('  ✗ 被限流器拒绝，本次不扫码');
      await svc.close();
      await _finish(logDir, args);
      exitCode = 3;
      return;
    }
    final qrBegun = await qrLimiter.beginAttempt();
    if (!qrBegun.allowed) {
      out('  ✗ 记录后仍不允许：${qrBegun.describe()}');
      await svc.close();
      await _finish(logDir, args);
      exitCode = 3;
      return;
    }

    out('--- 取二维码 ---');
    try {
      await svc.fetchQrcode(expectedUin: expectedUin);
    } on Object catch (e) {
      await qrLimiter.recordFailure(reasonCode: 'qr:${e.runtimeType}');
      rethrow;
    }
    if (svc.snapshot.stage != Qq8LoginStage.waitingQrScan) {
      out('  ✗ 取码失败: ${svc.snapshot.error}');
      await qrLimiter.recordFailure(reasonCode: 'qr:fetch');
      await svc.close();
      await _finish(logDir, args);
      exitCode = 1;
      return;
    }
    // `0x17` 里是**二维码 PNG 图片字节**（参考实现 `logQrcode` 直接按 PNG 读）。
    // 所以这里不能当字符串打印——存成文件让你打开扫码；万一服务端给的是链接
    // （某些版本可能），那就把文本打出来，并说明需要自己渲染成二维码。
    final qrBytes = svc.snapshot.qrToken ?? Uint8List(0);
    final isPng = qrBytes.length > 8 &&
        qrBytes[0] == 0x89 &&
        qrBytes[1] == 0x50 &&
        qrBytes[2] == 0x4E &&
        qrBytes[3] == 0x47;
    if (isPng) {
      final f = File(
          '${logDir.path}${Platform.pathSeparator}qq8-qrcode.png');
      f.writeAsBytesSync(qrBytes);
      out('  二维码已存成图片（${qrBytes.length} 字节）：');
      out('    ${f.path}');
      out('  打开它，用手机 QQ 扫：');
      out('    start "${f.path}"');
    } else {
      out('  ⚠ 0x17 不是 PNG（${qrBytes.length} 字节），当文本打印：');
      out('    ${utf8.decode(qrBytes, allowMalformed: true)}');
      out('    这需要自己渲染成二维码再扫（工具不内置渲染）。');
    }
    out('  轮询中（每 2 秒一次，最多 $rounds 次）…');

    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      await svc.pollQrcode();
      final s = svc.snapshot;
      out('    [$i] ${s.stage.name} ${s.qrMessage ?? s.error ?? ''}');
      if (s.stage != Qq8LoginStage.waitingQrScan) break;
    }
    final s = svc.snapshot;
    if (s.stage == Qq8LoginStage.online) {
      await qrLimiter.recordSuccess();
      out('  ✓ 扫码登录成功，票据已存到 ${logDir.path}');
    } else {
      await qrLimiter.recordFailure(reasonCode: 'qr:${s.stage.name}');
      out('  ✗ 结束于 ${s.stage.name}: ${s.error ?? s.qrMessage}');
    }
    await svc.close();
    await _finish(logDir, args);
    exitCode = s.stage == Qq8LoginStage.online ? 0 : 1;
    return;
  }

  // ---------- 手机号短信登录（--phone / --phone-code，两段式）----------
  //
  // 也走 L3 服务层（`Qq8LoginService`）：三段子命令（17 检查 / 19 下发 /
  // 18 提交）加上"验证码通过后还要用 mpasswd 续一次口令登录"都是服务层的职责。
  // 两段之间靠 `qq8-phone-state.json` 传材料（盐/随机数/msalt）——
  // 手机号登录在 18 号回包之前**没有 uin**，跨进程重来的代价是"再收一条短信"，
  // 所以必须落盘（与 `qq8-slider-state.json` 同一个思路）。
  final phoneArg = args['phone'];
  final phoneCodeArg = args['phone-code'];
  if (phoneArg != null || phoneCodeArg != null) {
    await _runPhoneLogin(
      args: args,
      logDir: logDir,
      phone: phoneArg,
      code: phoneCodeArg,
    );
    await _finish(logDir, args);
    return;
  }

  // ---------- 离线回放：用 dump 出来的响应验证拆壳（不联网）----------
  //
  // 支持两种输入：
  //   * `.json`（现在真发非成功时自动落的档）：含 frame_hex + share_key
  //     ⇒ 能**完整离线解密**（type / TLV 清单 / 0x146 提示文字）；
  //   * 纯 hex 文本（老格式或真机 dump）：只能拆外层壳。
  if (args.containsKey('unwrap-file')) {
    final path = args['unwrap-file']!;
    final raw = File(path).readAsStringSync();
    String hex;
    Uint8List? savedKey;
    if (path.toLowerCase().endsWith('.json')) {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      hex = (j['frame_hex'] as String? ?? '');
      final k = (j['share_key'] as String? ?? '');
      if (k.isNotEmpty) savedKey = _hex(k);
    } else {
      final lines = raw.split('\n');
      hex = lines
          .skip(lines.first.trim().startsWith('total=') ? 1 : 0)
          .join()
          .replaceAll(' ', '')
          .replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    }
    final frame = _hex(hex);
    out('--- 离线回放拆壳: $path（${frame.length} 字节）---');
    final sso = qq8UnwrapRecv(frame);
    out('  外壳flag=${sso.flag} seq=${sso.seq} cmd=${sso.cmd}');
    out('  负载 ${sso.payload.length} 字节；'
        '负载[0..16)=${_hexOf(sso.payload.take(16).toList())}');
    out('  负载-17 = ${sso.payload.length - 17}'
        '${(sso.payload.length - 17) % 8 == 0 ? '（8 对齐 ✓，可交给内层 ECDH 解密）' : '（✗ 不对齐）'}');
    if (savedKey != null) {
      out('  存档里有会话密钥（${savedKey.length} 字节）→ 完整离线解密：');
      try {
        final r = Qq8LoginResponse.parse(sso.payload, savedKey);
        out('    type = ${r.type}  (${_typeMeaning(r.type)})');
        final tags = r.tlvs.keys.toList()..sort();
        out('    TLV: ${tags.map((t) => '0x${t.toRadixString(16)}:${r.tlvs[t]!.length}B').join(' ')}');
        final m146 = r.serverMessage;
        if (m146 != null) {
          out('    服务端提示: [${m146.$1}] ${m146.$2}');
        }
        final pow546 = r.tlvs[0x546];
        if (pow546 != null && pow546.isNotEmpty) {
          out('    0x546（防刷计算题）字段: ${_describe546(pow546)}');
        }
        // --dump-tlv=0x546：把某个 TLV 的 body 打成纯 hex（做成黄金向量用）
        final wantTag = args['dump-tlv'];
        if (wantTag != null && wantTag.isNotEmpty) {
          final tag = wantTag.toLowerCase().startsWith('0x')
              ? int.parse(wantTag.substring(2), radix: 16)
              : int.parse(wantTag);
          final body = r.tlvs[tag];
          if (body == null) {
            out('    ✗ 响应里没有 0x${tag.toRadixString(16)}');
          } else {
            out('DUMP 0x${tag.toRadixString(16)} ${body.length}B:');
            out(_plainHex(body));
          }
        }
      } on Object catch (e) {
        out('    ✗ 解密失败: $e');
      }
    }
    await _finish(logDir, args);
    return;
  }

  // ---------- 档案 ----------
  final profileName = args['profile'] ?? 'default';
  final profile = _pickProfile(profileName);

  // 本次实际使用的 TLV 清单：token 路径用 exchange_emp 清单；
  // 密码路径默认官方超集，`--tlv-set=oicq` 时换成参考实现的 24 项清单；
  // 滑验证提交按版本条件追加（ssoVer>12 带 0x544；挑战带 0x546 时再带 0x547）。
  final sliderStateFile =
      File('${logDir.path}${Platform.pathSeparator}qq8-slider-state.json');
  final sliderPowHex = useSlider ? _sliderT547FromState(sliderStateFile) : null;
  final sliderOrder =
      qq8SliderTlvOrderFor(profile.apk, hasT547: sliderPowHex != null);
  // oicq 实验集是旧参考的 24 项（无 548）；ssoVer>12 时按维护版补 0x548/0x542。
  List<int> oicqPasswordOrder() => tlvSet == 'oicq' && profile.apk.ssoVer > 12
      ? <int>[...kOicqPasswordTlvOrder, 0x548, 0x542]
      : kOicqPasswordTlvOrder;
  final order = useSlider
      ? sliderOrder
      : (useToken
          ? qq8ExchangeEmpTlvOrder
          : (tlvSet == 'oicq'
              ? oicqPasswordOrder()
              : qq8PasswordTlvOrderFor(profile.apk)));

  out('--- 客户端档案 ---');
  out('  ${profile.describe()}');
  out(
    '  TLV 清单: ${useSlider ? "滑验证提交（${sliderOrder.length} 项：${sliderOrder.map((t) => '0x${t.toRadixString(16)}').join(' ')}）" : (useToken ? "exchange_emp（16 项）" : (tlvSet == "oicq" ? "oicq 24 项（实验）" : "官方超集 ${profile.apk.loginTlvOrder.length} 项"))}',
  );
  if (profile.unverified.isNotEmpty) {
    out('  ⚠ 未核实字段: ${profile.unverified.join(', ')}');
  }
  out('');

  // ---------- 票据文件（token 续期用）----------
  final tokenPath = args['token-file'] ?? args['save-token'];
  _TokenFile? token;
  if (useToken || args.containsKey('token-file')) {
    if (tokenPath == null || tokenPath.isEmpty) {
      errOut('✗ --token-login / --token-file 需要给出文件路径'
          '（--token-file=<path>）');
      exit(2);
    }
    try {
      token = _TokenFile.load(File(tokenPath));
    } on Object catch (e) {
      errOut('✗ 票据文件读取失败: $e');
      exit(2);
    }
    out('--- 票据 ---');
    out('  文件: $tokenPath');
    out('  uin: ${token.uin}（保存于 ${token.savedAt}）');
    out('  tgt ${token.tgt.length} 字节 / d2 ${token.d2.length} 字节'
        ' / d2key ${token.d2key.length} 字节');
    out('');
  }
  if (useToken && token == null) {
    errOut('✗ --token-login 必须配 --token-file=<path>');
    exit(2);
  }
  if (useToken && token!.d2.isEmpty) {
    errOut('✗ 票据文件里没有 d2——token 续期的核心载荷缺失，无法发送');
    exit(2);
  }

  // ---------- 验证分支的盐 / 令牌 ----------
  // 都来自上一条"要求验证"的响应，由本工具存进 qq8-slider-state.json：
  //   type=2          → t104（盐）
  //   160/162/239     → t104 + t174（令牌）+ phone（展示用）
  //   204             → t104
  final stateJson = _readSliderState(
    File('${logDir.path}${Platform.pathSeparator}qq8-slider-state.json'),
  );
  Uint8List sliderSalt = Uint8List(0);
  Uint8List verifyToken = Uint8List(0);
  if (useSlider || useSendSms || useSubmitSms || useDeviceUnlock) {
    final saltHex = args['slider-salt'] ?? stateJson['t104'];
    if (saltHex == null || saltHex.isEmpty) {
      errOut('✗ 缺少盐：用 --slider-salt=<hex>，或先跑一次登录'
          '（拿到"要求验证"的响应时会自动写入 qq8-slider-state.json）');
      exit(2);
    }
    try {
      sliderSalt = _hex(saltHex);
      final tokenHex = stateJson['t174'];
      if (tokenHex != null && tokenHex.isNotEmpty) {
        verifyToken = _hex(tokenHex);
      }
    } on Object catch (e) {
      errOut('✗ 盐/令牌不是合法 hex: $e');
      exit(2);
    }
    final branchName = useSlider
        ? '滑动验证提交'
        : (useSendSms
            ? '请求下发短信'
            : (useSubmitSms ? '提交短信码' : '设备锁解锁'));
    out('--- 验证材料（$branchName）---');
    out('  盐: ${sliderSalt.length} 字节（0x104）');
    if (useSlider) out('  ticket: ${sliderTicket.length} 字符');
    if (useSendSms || useSubmitSms) {
      out('  令牌: ${verifyToken.length} 字节（0x174）'
          '${verifyToken.isEmpty ? '  ⚠ 缺失，这条请求发不出去' : ''}');
      final phone = stateJson['phone'];
      if (phone != null && phone.isNotEmpty) {
        out('  目标手机: $phone（来自上一条响应的 0x178）');
      }
    }
    out('');
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

  // ⚠️ 兜底 10001 只是 dry-run 的组包占位号。真发（--send）时**必须显式给 uin**：
  // 曾经因为没给 uin，真发路径静默用了 10001（测试号）——那等于拿着别人的号
  // 去连生产服务器，浪费一次尝试还会让服务端收到无主登录。
  int? uin = token?.uin;
  if (uin == null) {
    final parsed = int.tryParse(uinStr ?? '');
    if (parsed == null && args.containsKey('send')) {
      errOut('✗ 真发必须显式给出账号：--uin=<号码> 或环境变量 QQ_LIVE_UIN。');
      errOut('  工具不会用兜底的测试号（10001）连生产服务器。');
      exit(2);
    }
    uin = parsed ?? 10001;
  }

  out('--- 账号 ---');
  out('  uin: $uin');
  out(
    '  设备: ${deterministic ? "固定夹具（dry-run 可复现）" : "按 uin 派生（同账号恒定同一套）"}',
  );
  if (useToken) {
    out('  口令: 不需要（本次是 token 续期）');
  } else if (useSlider) {
    out('  口令: 不需要（本次提交人工解出的滑验证 ticket）');
  } else {
    out(
      '  口令: ${passwordMd5 == null ? "未提供（用占位值，仅用于组包验证）" : "已提供"}',
    );
    if (passwordMd5 != null) {
      out('    ${Redact.fingerprint("pwd_md5", passwordMd5)}');
    }
  }
  out('');

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
  // ---------- 会话（ECDH / sessionId / randomKey / seqId）----------
  //
  // 服务端把「密码登录 → 滑块提交」当**同一会话**：oicq 在同一 client 实例
  // 内完成两步，共用 ECDH 对 / sessionId / randomKey。我们用两个独立进程做，
  // 滑块提交被服务端当成"无密码的新登录"→ 回 type=1「账号或密码错误」
  // （2026-09-13 8.2.11 Play 实测：版本门已过，只剩这一步凭证关联）。
  // 因此支持 `--save-session`（密码登录时落盘）与 `--load-session`
  // （滑块提交时恢复），让两步共享同一会话。
  final loadSessionPath = args['load-session'];
  Map<String, dynamic>? loadedSession;
  if (loadSessionPath != null && loadSessionPath.isNotEmpty) {
    try {
      loadedSession =
          jsonDecode(File(loadSessionPath).readAsStringSync())
              as Map<String, dynamic>;
      out('  会话: 从 $loadSessionPath 恢复（ECDH 私钥 / sessionId / randomKey 复用）');
    } on Object catch (e) {
      errOut('✗ --load-session 读取失败: $e');
      exit(2);
    }
  }
  final ecdhPriv = loadedSession != null
      ? _hex(loadedSession['ecdh'] as String)
      : _randomBytes(32);
  final ecdh = Ecdh.exchange(
    Uint8List.fromList(Qq8Config.serverEcdhPublicKey),
    privateKey: ecdhPriv,
  );

  // ---------- QIMEI（0x545）与 0x544 形态：实验开关 ----------
  //
  // 官方密码登录会带 0x545（QIMEI，设备档案里缓存的值）+ 0x544（安全 SDK 的
  // 签名块）。我们发不出真签名，QIMEI 也要靠"取号"HTTPS 才拿得到，所以：
  //   * `--fetch-qimei`  ：真去 snowflake 取号（走 --send 同一道闸门）
  //   * `--qimei=<str>`  ：手工注入已有 QIMEI（不联网）
  //   * `--t544=oicq`    ：0x544 改发参考实现 oicq 的 v==2 结构占位
  final qimeiArg = args['qimei'];
  String? qimei = (qimeiArg != null && qimeiArg.isNotEmpty) ? qimeiArg : null;
  if (qimei != null) {
    out('  QIMEI: 手工注入 ${qimei.length} 字符');
  } else if (args.containsKey('fetch-qimei')) {
    // 取号也是联网（POST 腾讯灯塔）：与真发同一道闸门，**不能绕过确认串**。
    // （这块代码在"真发前两道闸门"之前，所以必须自己再查一次。）
    final qimeiConfirm = Platform.environment['QQ_LIVE_CONFIRM'];
    if (!args.containsKey('send')) {
      out('  ⚠ --fetch-qimei 要联网取号：加 --send（并设确认串）才生效');
    } else if (qimeiConfirm != kConfirmToken) {
      out('  ⚠ --fetch-qimei 未设置 QQ_LIVE_CONFIRM="$kConfirmToken"，本次不取号');
    } else {
      try {
        final r = await Qq8Qimei.fetch(
          device: device,
          apk: profile.apk,
          beaconAppKey: profile.beaconAppKey,
          onLog: out,
        );
        qimei = r.q16;
        out('  QIMEI 取号成功（$r）');
        _log.i('QIMEI: q16=${r.q16} q36=${r.q36} via=${r.endpoint}');
      } on Object catch (e) {
        out('  ✗ 取号失败（不影响其他步骤继续）：$e');
        _log.w('QIMEI 取号失败', error: e);
      }
    }
  }
  final t544Mode = args['t544'] ?? 'official';
  if (t544Mode != 'official' && t544Mode != 'oicq') {
    errOut('✗ --t544 只支持 official / oicq，收到 "$t544Mode"');
    exit(2);
  }
  out('  0x544 形态: ${t544Mode == 'oicq' ? 'oicq v=2 结构占位（实验）' : '官方降级（默认）'}');
  out('  0x545（QIMEI）: ${qimei == null ? '不发（取不到就是官方行为）' : '发'}');

  // 0x548（客户端自构造 PoW）：只在密码首登包携带（维护版 oicq v1.26.25）。
  // 滑块/短信/设备锁/token 各分支的清单里都没有它。
  final isPasswordLogin = !useSlider &&
      !useToken &&
      !useSendSms &&
      !useSubmitSms &&
      !useDeviceUnlock;
  final Uint8List? selfT548 =
      (isPasswordLogin && profile.apk.ssoVer > 12)
          ? qq8BuildClientPow548().body
          : null;
  if (selfT548 != null) {
    out('  0x548（自构造 PoW）: ${selfT548.length} 字节');
  }

  // 会话的 seq / sessionId / randomKey：恢复会话时全取保存值，否则新生成。
  final sessionSeq = loadedSession != null
      ? loadedSession['seqId'] as int
      : (deterministic ? 100 : DateTime.now().millisecondsSinceEpoch & 0x7FFF);
  final sessionId = loadedSession != null
      ? _hex(loadedSession['sessionId'] as String)
      : (deterministic ? _hex('01020304') : _randomBytes(4));
  final randomKey = loadedSession != null
      ? _hex(loadedSession['randomKey'] as String)
      : (deterministic ? _fill(16, 0x0f) : _randomBytes(16));

  final tlvCtx = Qq8TlvContext(
    uin: uin,
    apk: profile.apk,
    device: device,
    passwordMd5: passwordMd5 ?? Uint8List(16),
    seqId: sessionSeq,
    ksid: _ksid(device, profile),
    t104: sliderSalt, // 验证分支要带上一条响应下发的盐；其余场景为空
    t174: verifyToken, // 短信流程（8/7）要回带的二次验证令牌
    tgt: useToken ? token!.tgt : Uint8List(0),
    srmToken: Uint8List(0),
    // 挑战带 0x546 时，提交要回 0x547（本地算出的防刷应答）；没有就不带
    t547: sliderPowHex == null ? null : _hex(sliderPowHex),
    t548: selfT548,
    // 0x544 实验形态：v==2 结构占位（值 = 子命令号）；不改密码/续期/验证各条
    // 请求的子命令号，直接按用途取。
    t544SubCmd: t544Mode == 'oicq'
        ? (useSlider
            ? Qq8SubCmd.slider
            : (useSubmitSms
                ? Qq8SubCmd.submitSms
                : (useSendSms
                    ? Qq8SubCmd.sendSms
                    : (useToken ? Qq8SubCmd.token : Qq8SubCmd.password))))
        : null,
  );

  final body = useSlider
      ? Qq8LoginBody.buildSlider(tlvCtx, ticket: sliderTicket)
      : (useSendSms
          ? Qq8LoginBody.buildSendSms(tlvCtx)
          : (useSubmitSms
              ? Qq8LoginBody.buildSubmitSms(tlvCtx, code: smsCode)
              : (useDeviceUnlock
                  ? Qq8LoginBody.buildDeviceUnlock(tlvCtx)
                  : (useToken
                      ? Qq8LoginBody.buildToken(tlvCtx, d2: token!.d2)
                      : Qq8LoginBody.build(
                          tlvCtx,
                          Qq8SubCmd.password,
                          order,
                          cond: qimei == null
                              ? Qq8LoginConditions(t548: selfT548)
                              : Qq8LoginConditions(
                                  qimei: qimei, t548: selfT548),
                          args: qimei == null
                              ? const <int, List<Object?>>{}
                              : <int, List<Object?>>{
                                  0x545: <Object?>[qimei],
                                })))));

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
    sessionId: sessionId,
    randomKey: randomKey,
    ecdhPublicKey: ecdh.publicKey,
    ecdhShareKey: ecdh.shareKey,
    seqId: sessionSeq,
    sig: tokenSig,
  );

  final oicqPacket = Qq8Sso.buildOicqPacket(ssoCtx, body);
  final loginPacket = Qq8Sso.buildLoginPacket(
    ssoCtx,
    useToken ? qq8ExchangeEmpCmd : qq8LoginCmd,
    oicqPacket,
    Qq8LoginType.login,
  );

  // 保存会话（仅真发）：滑块提交时用 --load-session 恢复同一会话。
  final saveSessionPath = args['save-session'];
  if (saveSessionPath != null && saveSessionPath.isNotEmpty && args.containsKey('send')) {
    File(saveSessionPath).writeAsStringSync(jsonEncode({
      'ecdh': _plainHex(ecdhPriv),
      'sessionId': _plainHex(sessionId),
      'randomKey': _plainHex(randomKey),
      'seqId': sessionSeq,
    }));
    out('  会话已存: $saveSessionPath（下一步滑块提交加 --load-session 恢复）');
  }

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
    out('');
    out('dry-run 结束。要真发请加 --send，并设置 QQ_LIVE_CONFIRM=');
    out('  $kConfirmToken');
    await _finish(logDir, args);
    return;
  }

  // ---------- 真发前的两道闸门 ----------
  out('');
  out('--- 发送前检查 ---');

  final confirm = Platform.environment['QQ_LIVE_CONFIRM'];
  if (confirm != kConfirmToken) {
    out('  ✗ 未设置 QQ_LIVE_CONFIRM');
    out('    本工具拒绝在无显式确认的情况下连生产服务器。');
    out('    确认理解风险后：\$env:QQ_LIVE_CONFIRM="' '$kConfirmToken"');
    await _finish(logDir, args);
    exitCode = 2;
    return;
  }
  out('  ✓ 显式确认已给出');

  if (!useToken && !useSlider && passwordMd5 == null) {
    out('  ✗ 未提供口令，无法真发（设 QQ_LIVE_PWD 或 --pwd-md5）');
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
  out('  限流: ${status.describe()}');
  if (!status.allowed) {
    out('  ✗ 被限流器拒绝，本次不发');
    await _finish(logDir, args);
    exitCode = 3;
    return;
  }

  final begun = await limiter.beginAttempt();
  if (!begun.allowed) {
    out('  ✗ 记录后仍不允许：${begun.describe()}');
    await _finish(logDir, args);
    exitCode = 3;
    return;
  }

  // ---------- 真发 ----------
  out('');
  out('--- 连接 ---');
  final tran = Qq8TcpTransport();
  out('  目标: ${tran.host}:${tran.port}');
  _log.i('连接 ${tran.host}:${tran.port}');

  Qq8LoginResponse? resp;
  Object? failure;
  Uint8List? rawResponse;
  try {
    await tran.connect();
    out('  已连接');
    _log.i('已连接');

    out('--- 发送登录请求（${loginPacket.length} 字节）---');
    final frame = await tran.send(loginPacket);
    rawResponse = frame;
    out('  收到响应 ${frame.length} 字节');
    _log.i('收到响应 ${frame.length} 字节');

    // 拆两层壳（外壳 + SSO 头）后再交给内层解析——实现与出处见
    // `lib/kernel/wlogin8/qq8_recv.dart` 头部。
    final sso = qq8UnwrapRecv(frame, d2key: useToken ? token?.d2key : null);
    out('  SSO: seq=${sso.seq} cmd=${sso.cmd} '
        '外壳flag=${sso.flag} 负载=${sso.payload.length} 字节');
    resp = Qq8LoginResponse.parse(sso.payload, ecdh.shareKey);
  } on Object catch (e, st) {
    failure = e;
    _log.e('登录失败', error: e, stack: st);
    out('  ✗ 失败: $e');
    // 解析失败时把响应结构摊开——下一次尝试就能靠数据定位，不靠猜。
    if (rawResponse != null) _diagnoseResponse(rawResponse, ecdh.shareKey, logDir);
  } finally {
    await tran.close();
  }

  if (failure != null) {
    await limiter.recordFailure(reasonCode: failure.runtimeType.toString());
    out('');
    out('已记录一次失败。**不要马上重试**——重试本身是风控特征。');
    await _finish(logDir, args);
    exitCode = 1;
    return;
  }

  // ---------- 判读 ----------
  out('');
  out('--- 响应判读 ---');
  final r = resp!;
  out('  type = ${r.type}  (${_typeMeaning(r.type)})');
  if (r.needsSlider) {
    out('  滑动验证地址: ${r.sliderUrl}');
    final pow546 = r.tlvs[0x546];
    String? t547Hex;
    if (pow546 != null && pow546.isNotEmpty) {
      final ans = qq8SolvePow(pow546);
      if (ans == null) {
        final ch = parseQq8Pow(pow546);
        final why = ch.typ == 2
            ? 'typ=2 预像搜索超出迭代上限（服务端这次挑的目标太远）'
                '——提交时不会带 0x547'
            : '题型/哈希不认识或超迭代上限——提交时不会带 0x547';
        out('  ⚠ 响应带 0x546（${pow546.length} 字节，'
            'a=${ch.a} typ=${ch.typ} c=${ch.c} e=${ch.e}）：$why');
      } else {
        t547Hex = _plainHex(ans.body);
        out('  ✓ 已解出 0x547 防刷应答（${ans.body.length} 字节，'
            '${ans.iterations} 次迭代 / ${ans.elapsedMs}ms）');
        _log.i('0x547 解出: ${ans.iterations} 次迭代 / ${ans.elapsedMs}ms');
      }
    }
    final salt = r.tlvs[0x104];
    if (salt != null && salt.isNotEmpty) {
      final stateFile = File(
          '${logDir.path}${Platform.pathSeparator}qq8-slider-state.json');
      final state = <String, Object?>{
        't104': _plainHex(salt),
        'url': r.sliderUrl,
        'at': DateTime.now().toIso8601String(),
      };
      if (t547Hex != null) state['t547'] = t547Hex;
      _saveSliderState(
        stateFile,
        state.map((k, v) => MapEntry(k, '$v')),
      );
      out('  盐（0x104，${salt.length} 字节）已存: ${stateFile.path}');
      out('  **人工**解完滑块后（解自己账号的验证，不做任何自动化）：');
      out('    dart run tool/qq8_live_smoke.dart --send '
          '--slider-ticket=<ticket>');
    } else {
      out('  ⚠ 响应里没有 0x104（盐），无法构造后续的提交请求');
    }
  }

  // ---------- 短信码验证（160/162/239）----------
  //
  // 与滑块的区别：验证材料里多一个 0x174（令牌，必须回带），手机号在 0x178。
  // 参考实现在 0x204/0x174 都不在时认为"已自动下发短信"，且不重发。
  if (r.needsSmsVerify) {
    final phone = r.verifyPhone;
    final token = r.verifyToken;
    final salt = r.tlvs[0x104];
    final autoSent = r.tlvs[0x204] == null && token == null;
    out('  短信验证：'
        '${phone == null ? '响应里没有可读的手机号（0x178）' : '目标手机 $phone'}'
        '${autoSent ? '（参考实现视为"已自动下发短信"）' : ''}');
    if (salt != null && token != null && salt.isNotEmpty && token.isNotEmpty) {
      final stateFile = File(
          '${logDir.path}${Platform.pathSeparator}qq8-slider-state.json');
      final patch = <String, String>{
        't104': _plainHex(salt),
        't174': _plainHex(token),
        'at': DateTime.now().toIso8601String(),
      };
      if (phone != null) patch['phone'] = phone;
      _saveSliderState(stateFile, patch);
      out('  盐+令牌已存: ${stateFile.path}');
      out('  下一步（不需要口令）：');
      if (!autoSent) {
        out('    dart run tool/qq8_live_smoke.dart --send --send-sms'
            '        # 请求下发短信码');
      }
      out('    dart run tool/qq8_live_smoke.dart --send '
          '--sms-code=<收到的6位码>');
    } else {
      out('  ⚠ 缺 0x104 或 0x174，短信流程无法继续（不猜）');
    }
  }

  // ---------- 设备锁（204）----------
  if (r.needsDeviceLock) {
    final salt = r.tlvs[0x104];
    final hint = r.deviceLockHint;
    if (hint != null) out('  设备锁提示: $hint');
    if (salt != null && salt.isNotEmpty) {
      final stateFile = File(
          '${logDir.path}${Platform.pathSeparator}qq8-slider-state.json');
      _saveSliderState(stateFile, <String, String>{
        't104': _plainHex(salt),
        'at': DateTime.now().toIso8601String(),
      });
      out('  盐已存: ${stateFile.path}');
      out('  下一步（参考实现是收到 204 就自动发，这里保持显式）：');
      out('    dart run tool/qq8_live_smoke.dart --send --device-unlock');
    } else {
      out('  ⚠ 响应里没有 0x104（盐），无法解锁');
    }
  }
  out('  TLV 列表（只列编号与长度，不打印内容）:');
  final tags = r.tlvs.keys.toList()..sort();
  for (final t in tags) {
    out(
      '    0x${t.toRadixString(16).padLeft(4, '0')}  ${r.tlvs[t]!.length} 字节',
    );
  }
  out('  明文长度: ${r.plain.length}');

  // 排查要用的结构落盘：TLV 清单进日志（导出报告里就有，不用再抄屏幕）；
  // 非成功时把**响应帧 + 本次会话密钥**一起存成 json——有了密钥才能离线把
  // 内层解开（type / TLV 清单 / 0x146 提示），否则下一次只能重发重问。
  // 成功帧含票据材料、密钥也还有效期，不落盘。
  _log.i('TLV 清单: '
      '${tags.map((t) => '0x${t.toRadixString(16)}:${r.tlvs[t]!.length}B').join(' ')}');
  final m146 = r.serverMessage;
  if (m146 != null) {
    out('  服务端提示: [${m146.$1}] ${m146.$2}');
    _log.i('0x146 服务端提示: [${m146.$1}] ${m146.$2}');
  }
  if (!r.isSuccess && rawResponse != null) {
    final f = File('${logDir.path}${Platform.pathSeparator}'
        'qq8-response-${DateTime.now().millisecondsSinceEpoch}.json');
    f.writeAsStringSync(jsonEncode(<String, Object?>{
      'at': DateTime.now().toIso8601String(),
      'type': r.type,
      'share_key': _plainHex(ecdh.shareKey),
      'frame_hex': _plainHex(rawResponse),
      if (m146 != null) 't146_title': m146.$1,
      if (m146 != null) 't146_content': m146.$2,
    }));
    out('  原始响应+会话密钥已存: ${f.path}');
    _log.i('原始响应+会话密钥已存 ${f.path}（${rawResponse.length} 字节）');
  }

  if (r.isSuccess) {
    await limiter.recordSuccess();
    out('');
    out('  ✓ type=0：登录被接受');
    if (r.t119 != null) {
      out('  票据块 0x119 长度 ${r.t119!.length}');
      try {
        final sig = Qq8SigBundle.parse(r.t119!, device.tgtgt);
        out('    票据解出:');
        out('      tgt      ${sig.tgt?.length ?? 0} 字节');
        out('      d2       ${sig.d2?.length ?? 0} 字节');
        out('      d2key    ${sig.d2key?.length ?? 0} 字节');
        out('      sig_key  ${sig.sigKey?.length ?? 0} 字节');
        out('      ticket   ${sig.ticketKey?.length ?? 0} 字节');
        out('      srm      ${sig.srmToken?.length ?? 0} 字节');

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
          out('  票据已保存: $savePath');
          out('  （明文会话凭据：别进 git，用完即删）');
        }
      } on Object catch (e) {
        out('    ✗ 0x119 解析失败: $e');
      }
    }
  } else {
    // 「要求验证」是流程中间态（接着要提交 ticket 或走设备锁流程），
    // 不计入连败；其余非成功码才算失败。
    final rc = 'type=${r.type}';
    if (LoginAttemptLimiter.isProgressCode(rc)) {
      await limiter.recordProgress(reasonCode: rc);
      out('');
      out('  ↻ 要求验证（$rc）：按提示人工完成验证后，'
          '用 --slider-ticket 继续；这一步**不计入失败次数**。');
    } else {
      await limiter.recordFailure(reasonCode: rc);
      out('');
      out('  ⚠ 非成功码。已记录失败。');
    }
  }

  await _finish(logDir, args);
  exitCode = r.isSuccess ? 0 : 1;
}

// ---------------------------------------------------------------------------
// 手机号短信登录（两段式）
// ---------------------------------------------------------------------------

/// 手机号短信验证登录：第 1 段 `--phone=`（检查 17 + 下发 19），
/// 第 2 段 `--phone-code=`（提交 18，通过后自动用 mpasswd 续一次子命令 9）。
///
/// 两段之间只有"人去看短信"这一步，材料经 `qq8-phone-state.json` 传递。
Future<void> _runPhoneLogin({
  required Map<String, String> args,
  required Directory logDir,
  required String? phone,
  required String? code,
}) async {
  final confirm = Platform.environment['QQ_LIVE_CONFIRM'];
  final wantSend = args.containsKey('send');
  final stateFile =
      File('${logDir.path}${Platform.pathSeparator}qq8-phone-state.json');

  if (phone != null && code != null) {
    out('✗ --phone 与 --phone-code 是两段，不能同时给');
    exitCode = 2;
    return;
  }
  if (wantSend && confirm != kConfirmToken) {
    out('✗ 真连服务器需要 QQ_LIVE_CONFIRM="$kConfirmToken"');
    exitCode = 2;
    return;
  }

  // 档案：手机号这条以前**没把 --profile 传进来**（只能吃默认 8.9.50）——
  // 服务器提示过"请升级至最新版本"，没这个开关就做不了版本对照实验。
  final phoneProfile = _pickProfile(args['profile'] ?? 'default');
  final svc = Qq8LoginService(
    profile: phoneProfile,
    tokenStore: FileQq8TokenStore(logDir),
    heartbeatInterval: const Duration(seconds: 270),
  );
  // 与扫码那条同一个诊断钩子：每条响应落一个 json（frame_hex + share_key +
  // type + 0x146 文案），失败后能离线复解，不用重发重问。
  svc.onDiagnostic = (tag, frame, parsed) {
    try {
      final dump = <String, Object?>{
        'at': DateTime.now().toIso8601String(),
        'tag': 'sms-$tag',
        'share_key': _plainHex(svc.debugShareKey ?? Uint8List(0)),
        'frame_hex': _plainHex(frame),
        if (parsed != null) 'type': parsed.type,
        if (parsed?.serverMessage != null) 't146_title': parsed!.serverMessage!.$1,
        if (parsed?.serverMessage != null)
          't146_content': parsed!.serverMessage!.$2,
        if (parsed != null)
          'tlvs':
              parsed.tlvs.keys.map((t) => '0x${t.toRadixString(16)}').toList(),
      };
      final f = File('${logDir.path}${Platform.pathSeparator}'
          'qq8-response-${DateTime.now().millisecondsSinceEpoch}-$tag.json');
      f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(dump));
      out('  （响应已存 ${f.path}）');
    } on Object catch (e) {
      out('  （响应落盘失败：$e）');
    }
  };

  try {
    if (phone != null) {
      await _phoneLoginStep1(
        svc: svc,
        args: args,
        logDir: logDir,
        profile: phoneProfile,
        phone: phone,
        stateFile: stateFile,
        wantSend: wantSend,
      );
    } else {
      await _phoneLoginStep2(
        svc: svc,
        args: args,
        logDir: logDir,
        code: code!,
        stateFile: stateFile,
        wantSend: wantSend,
      );
    }
  } finally {
    await svc.close();
  }
}

/// 第 1 段：检查手机号（17）+ 下发验证码（19），材料落 [stateFile]。
Future<void> _phoneLoginStep1({
  required Qq8LoginService svc,
  required Map<String, String> args,
  required Directory logDir,
  required Qq8ClientProfile profile,
  required String phone,
  required File stateFile,
  required bool wantSend,
}) async {
  out('--- 手机号短信登录（第 1 段：检查 + 下发验证码）---');
  out('  手机号: $phone');
  out('  档案: ${profile.describe()}');
  out('  说明: 17 只检查"这个号能不能短信登录"并下发盐/随机数/msalt；'
      '19 才真的发短信。');

  if (!wantSend) {
    // dry-run：只有 17 能离线组（19 要回带上一步服务端给的盐）
    final device = _buildDevice(deterministic: true);
    final ecdh =
        Ecdh.exchange(Uint8List.fromList(Qq8Config.serverEcdhPublicKey));
    final ctx = Qq8TlvContext(
      uin: 0,
      apk: profile.apk,
      device: device,
      passwordMd5: Uint8List(16),
      seqId: 100,
      ksid: _ksid(device, profile),
      t104: Uint8List(0),
      t174: Uint8List(0),
      tgt: Uint8List(0),
      srmToken: Uint8List(0),
    );
    final body = Qq8LoginBody.buildSmsLoginCheck(ctx, phone: phone);
    final ssoCtx = Qq8SsoContext(
      uin: 0,
      apk: profile.apk,
      device: device,
      sessionId: _hex('01020304'),
      randomKey: _fill(16, 0x0f),
      ecdhPublicKey: ecdh.publicKey,
      ecdhShareKey: ecdh.shareKey,
      seqId: ctx.seqId,
    );
    final oicqPacket = Qq8Sso.buildOicqPacket(ssoCtx, body);
    final loginPacket =
        Qq8Sso.buildLoginPacket(ssoCtx, qq8LoginCmd, oicqPacket, Qq8LoginType.login);
    _printPacketReport(
      body: body,
      oicqPacket: oicqPacket,
      loginPacket: loginPacket,
      profile: profile,
      order: Qq8SmsLoginTlvOrder.check,
      shareKey: ecdh.shareKey,
    );
    out('');
    out('dry-run 结束（19 下发要回带上一步服务端给的盐，离线组不出来）。');
    out('真发第 1 段：');
    out('  \$env:QQ_LIVE_CONFIRM="$kConfirmToken"');
    out('  dart run tool/qq8_live_smoke.dart --send --phone=$phone');
    exitCode = 0;
    return;
  }

  // 第 1 段也要看限流器：**检查状态**（锁着就不发），但**不消耗**尝试次数——
  // 这一步只是"检查手机号 + 发短信"，不是一次登录尝试（真正算尝试的是第 2 段）。
  // 少了这道检查等于给"锁定期内照样连服务器"留后门，与扫码那条同一个纪律。
  final limiterFile =
      File('${logDir.parent.path}${Platform.pathSeparator}qqclient-attempts.json');
  final step1Limiter = LoginAttemptLimiter(persistFile: limiterFile);
  await step1Limiter.load();
  final step1Status = step1Limiter.status();
  out('  限流: ${step1Status.describe()}');
  if (!step1Status.allowed) {
    out('  ✗ 被限流器拒绝，本次不发（第 1 段不消耗次数，但也不能在锁定期绕过去）');
    exitCode = 3;
    return;
  }

  await svc.loginWithPhone(phone: phone);
  var s = svc.snapshot;
  if (s.stage != Qq8LoginStage.needsSmsCode) {
    out('  ✗ 检查未通过（${s.stage.name}）: ${s.error ?? ''}');
    // 服务端**明确拒绝**（如 type=243"当前登录存在不安全的情况"）也是"别再来"
    // 的信号：计入失败，攒到 5 次照样硬锁——否则锁定期里反复点没人管。
    await step1Limiter.recordFailure(reasonCode: 'sms-check');
    out('  （已计入限流器失败计数，别连续重试）');
    exitCode = 1;
    return;
  }
  final limits = svc.smsLoginLimits;
  out('  ✓ 检查通过（type=208）'
      '${s.phone == null ? '' : '，提示号 ${s.phone}'}'
      '${limits == null ? '' : '（次数上限 ${limits.msgCnt} / 有效期 ${limits.timeLimit}s）'}');

  await svc.refreshSmsLoginCode();
  s = svc.snapshot;
  if (s.stage != Qq8LoginStage.needsSmsCode) {
    out('  ✗ 下发验证码未通过（${s.stage.name}）: ${s.error ?? ''}');
    exitCode = 1;
    return;
  }
  final st = svc.smsLoginState;
  if (st == null) {
    out('  ✗ 服务端没给全材料（盐/随机数），无法进入第 2 段');
    exitCode = 1;
    return;
  }
  stateFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(st.toJson()));
  out('  ✓ 验证码已下发（type=232）'
      '${st.hintPhone == null ? '' : '，目标 ${st.hintPhone}'}');
  out('  中间材料已存: ${stateFile.path}'
      '（盐 ${st.salt.length}B / 随机数 ${st.random.length}B / msalt=${st.msalt}）');
  out('');
  out('收到短信后跑第 2 段（码是一次性的，只有一次机会）：');
  out('  dart run tool/qq8_live_smoke.dart --send --phone-code=<验证码>');
  exitCode = 0;
}

/// 第 2 段：提交验证码（18）→ 成功后服务层自动用 mpasswd 续一次口令登录（9）。
///
/// 提交 = 一次真正的登录尝试，所以**过限流器**（与密码/扫码同一条纪律）。
Future<void> _phoneLoginStep2({
  required Qq8LoginService svc,
  required Map<String, String> args,
  required Directory logDir,
  required String code,
  required File stateFile,
  required bool wantSend,
}) async {
  out('--- 手机号短信登录（第 2 段：提交验证码）---');

  if (!stateFile.existsSync()) {
    out('✗ 没有中间材料文件: ${stateFile.path}');
    out('  先跑第 1 段：dart run tool/qq8_live_smoke.dart --send --phone=<手机号>');
    exitCode = 2;
    return;
  }
  Qq8SmsLoginState? st;
  try {
    final raw = jsonDecode(stateFile.readAsStringSync());
    if (raw is Map) {
      st = Qq8SmsLoginState.fromJson(raw.map((k, v) => MapEntry('$k', v)));
    }
  } on Object catch (e) {
    out('✗ 中间材料文件读不出来: $e');
  }
  if (st == null) {
    out('✗ 中间材料不完整（缺手机号/盐/随机数），重新跑第 1 段');
    exitCode = 2;
    return;
  }
  out('  手机号: ${st.phone}'
      '${st.hintPhone == null ? '' : '（服务端提示 ${st.hintPhone}）'}');

  if (!wantSend) {
    out('dry-run：第 2 段要真提交验证码（码一次性，dry-run 不发）。');
    out('真发：dart run tool/qq8_live_smoke.dart --send --phone-code=<验证码>');
    return;
  }

  final limiterFile =
      File('${logDir.parent.path}${Platform.pathSeparator}qqclient-attempts.json');
  final limiter = LoginAttemptLimiter(persistFile: limiterFile);
  await limiter.load();
  final status = limiter.status();
  out('  限流: ${status.describe()}');
  if (!status.allowed) {
    out('  ✗ 被限流器拒绝，本次不发');
    exitCode = 3;
    return;
  }
  final begun = await limiter.beginAttempt();
  if (!begun.allowed) {
    out('  ✗ 记录后仍不允许：${begun.describe()}');
    exitCode = 3;
    return;
  }

  svc.resumeSmsLogin(st);
  await svc.submitSmsLoginCode(code);
  final s = svc.snapshot;
  if (s.stage == Qq8LoginStage.online) {
    await limiter.recordSuccess();
    out('  ✓ 验证码通过，并且 mpasswd 续登录成功 ⇒ 已上线 uin=${s.uin}');
    out('  票据已存到 ${logDir.path}（明文会话凭据：别进 git，用完即删）');
    exitCode = 0;
    return;
  }

  await limiter.recordFailure(reasonCode: 'sms:${s.stage.name}');
  out('  ✗ 结束于 ${s.stage.name}: ${s.error ?? ''}');
  if (s.needsHumanAction) {
    out('  ↻ 这是"还要求别的验证"的中间态，按提示继续。');
  }
  out('  验证码是一次性的：已用掉就重新跑第 1 段。');
  exitCode = 1;
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
  out('--- 登录 body ---');
  final subCmd = (body[0] << 8) | body[1];
  final count = (body[2] << 8) | body[3];
  out('  子命令 = $subCmd (${_subCmdName(subCmd)})');
  out('  TLV 个数 = $count');
  out('  body 总长 = ${body.length}');

  final tlvs = qq8ReadTlv(body, offset: 4);
  out('  TLV 明细:');
  for (final entry in tlvs.entries) {
    final tag = entry.key;
    final len = entry.value.length;
    final skip = _skippedNote(tag, profile);
    out(
      '    0x${tag.toRadixString(16).padLeft(4, '0')}  '
      '${len.toString().padLeft(5)} 字节$skip',
    );
  }
  out('  （顺序表 ${order.length} 项，'
      '被 guard 滤掉 ${order.length - count} 项）');

  out('');
  out('--- 三层信封尺寸 ---');
  out('  body        ${body.length}');
  out('  OICQ 信封    ${oicqPacket.length}  (前置随机密钥 + ECDH 公钥 + TEA(body))');
  out('  登录信封     ${loginPacket.length}');
  final declared = (loginPacket[0] << 24) |
      (loginPacket[1] << 16) |
      (loginPacket[2] << 8) |
      loginPacket[3];
  out('  首 4 字节声明的总长 = $declared  '
      '${declared == loginPacket.length ? "✓ 与实体一致" : "✗ 不一致！"}');

  out('');
  out('--- 包头（前 48 字节）---');
  out('  ${_hexOf(loginPacket.take(48).toList())}');
  out('  说明: 前 4 字节为长度，其后是 0x0A / type / d2 / uin …');
  out('  ECDH 共享密钥 ${Redact.fingerprint("share_key", shareKey)}');
}

String _skippedNote(int tag, Qq8ClientProfile p) {
  switch (tag) {
    case 0x544:
      // 两种形态见 `--t544`：官方降级（4/空 body）或 oicq 的 v=2 结构（42 字节）。
      return '  (形态见 --t544)';
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
      17 => '手机号短信：检查',
      19 => '手机号短信：下发/刷新验证码',
      18 => '手机号短信：提交验证码',
      _ => '未知',
    };

String _modeLabel({
  required bool useSlider,
  required bool useSendSms,
  required bool useSubmitSms,
  required bool useDeviceUnlock,
  required bool useToken,
  bool useQrcode = false,
  bool usePhone = false,
}) {
  if (useQrcode) return '二维码扫码登录（code2d）';
  if (usePhone) return '手机号短信登录（子命令 17/19/18 + 9）';
  if (useSlider) return '滑动验证提交（子命令 2）';
  if (useSendSms) return '请求下发短信码（子命令 8）';
  if (useSubmitSms) return '提交短信码（子命令 7）';
  if (useDeviceUnlock) return '设备锁解锁（子命令 20）';
  if (useToken) return 'token 续期（子命令 11）';
  return '密码登录（子命令 9）';
}

String _typeMeaning(int t) => switch (t) {
      Qq8LoginResultType.success => '成功',
      Qq8LoginResultType.slider => '需要滑动验证码',
      Qq8LoginResultType.deviceLock => '设备锁 / 二次验证',
      Qq8LoginResultType.smsLoginCheck =>
        '手机号短信登录：检查通过（盐/随机数/msalt 已下发）',
      Qq8LoginResultType.smsLoginRefresh => '手机号短信登录：验证码已下发',
      Qq8LoginResultType.smsVerify1 ||
      Qq8LoginResultType.smsVerify2 ||
      Qq8LoginResultType.smsVerify3 =>
        '需要短信验证码（子命令 8 下发 / 7 提交）',
      1 => '失败',
      3 => '失败',
      4 => '失败',
      6 => '服务连接中 / 稍后重试',
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
    errOut('未知档案 "$name"，可选: ${qq8ClientProfiles.keys.join(", ")}');
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

/// 拆 `0x546`（防刷计算题）的字段，供实现 PoW 前核对真实结构。
///
/// 结构照参考实现 `calcPoW` 的读法：
/// `u8 a ‖ u8 typ ‖ u8 c ‖ u8 ok ‖ u16 e ‖ u16 f ‖ tlv16 src ‖ tlv16 tgt ‖ tlv16 cpy`。
String _describe546(Uint8List b) {
  if (b.length < 12) return '太短（${b.length} 字节）';
  var p = 0;
  final a = b[p++], typ = b[p++], c = b[p++], ok = b[p++];
  final e = (b[p] << 8) | b[p + 1];
  p += 2;
  final f = (b[p] << 8) | b[p + 1];
  p += 2;
  String next() {
    if (p + 2 > b.length) return '<越界>';
    final len = (b[p] << 8) | b[p + 1];
    p += 2;
    final end = p + len > b.length ? b.length : p + len;
    final seg = b.sublist(p, end);
    p = end;
    final head = seg.take(8).map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final tail = seg.length > 8
        ? seg.skip(seg.length - 4).map((v) => v.toRadixString(16).padLeft(2, '0')).join()
        : '';
    return '${seg.length}B($head…$tail)';
  }

  return 'a=$a typ=$typ c=$c ok=$ok e=$e f=$f '
      'src=${next()} tgt=${next()} cpy=${next()}（总 ${b.length}B）';
}


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

/// 解析失败时的结构诊断：**不猜结构，只穷举 + 用 TEA 完整性校验当裁判**。
///
/// 参考模型（oicq js/ts 的 `packetListener` + `parseSSO` + `decodeLoginResponse`，
/// 以及官方 8.9.50 `oicq_request.d()`）都假定响应是
/// `[16 字节头][密文][1 字节尾]`、密文长度 8 对齐、密钥按头部某标志选。
/// 一旦实际长度对不上，就把这段字节摊开：先看长度与首字节，再穷举"头/尾"
/// 偏移逐个尝试解密（TEA 的填充校验能让错误的组合直接抛错），并把原始
/// 字节落到日志目录，供离线复核。
void _diagnoseResponse(Uint8List p, Uint8List shareKey, Directory logDir) {
  out('--- 响应结构诊断（离线）---');
  final n17 = p.length - 17;
  out('  长度 ${p.length}；len-17 = $n17'
      '${n17 % 8 == 0 ? '（8 对齐 ✓）' : '（不是 8 的倍数 → 16 头/1 尾 模型不符）'}');
  out('  前 32 字节: ${_hexOf(p.take(32).toList())}');
  if (p.isNotEmpty && p[0] == 0x02) {
    out('  首字节 0x02 —— 疑似 OICQ 信封形'
        '（u16@1 = ${(p[1] << 8) | p[2]}）');
  }

  final hits = <String>[];
  for (final header in <int>[0, 4, 8, 12, 16, 20]) {
    for (final tail in <int>[0, 1, 4]) {
      final n = p.length - header - tail;
      if (n < 16 || n % 8 != 0) continue;
      final ct = Uint8List.sublistView(p, header, p.length - tail);
      for (final e in <String, Uint8List>{
        'share_key': shareKey,
        'BUF16': Uint8List(16),
      }.entries) {
        try {
          final pt = qqTeaDecrypt(ct, e.value);
          final head = _hexOf(pt.take(8).toList());
          hits.add('头 $header / 尾 $tail / ${e.key} → 明文 ${pt.length} 字节，'
              '开头 $head');
        } on Object {
          // 密钥不对或本就不是密文：换下一组
        }
      }
    }
  }
  if (hits.isEmpty) {
    out('  没有"头/尾偏移 + share_key/BUF16"能通过 TEA 校验的组合');
  } else {
    for (final h in hits) {
      out('  ✓ $h');
    }
  }

  final f = File('${logDir.path}${Platform.pathSeparator}'
      'qq8-response-${DateTime.now().millisecondsSinceEpoch}.hex');
  f.writeAsStringSync('total=${p.length}\n${_plainHex(p)}\n');
  out('  原始响应已落盘: ${f.path}');
}

/// 读整个验证状态文件（`t104` / `t174` / `url` / `phone` / `t547`）。
///
/// 文件不存在或损坏时返回空表——调用方按"缺哪项报哪项"处理，不静默猜。
Map<String, String> _readSliderState(File f) {
  if (!f.existsSync()) return <String, String>{};
  try {
    final raw = jsonDecode(f.readAsStringSync());
    if (raw is Map<String, dynamic>) {
      final out = <String, String>{};
      for (final e in raw.entries) {
        final v = e.value;
        if (v is String && v.isNotEmpty) out[e.key] = v;
      }
      return out;
    }
  } on Object {
    // 损坏当作没有：--slider-salt 仍是显式入口
  }
  return <String, String>{};
}

/// 合并写入验证状态文件（保留已有键，只更新给定键）。
void _saveSliderState(File f, Map<String, String> patch) {
  final cur = _readSliderState(f);
  cur.addAll(patch);
  f.writeAsStringSync(jsonEncode(cur));
}


/// 从状态文件里读 **0x547 防刷应答**（hex）；没有就返回 null。
///
/// 它由"密码登录拿到 type=2"那一步当场算出并写入（挑战带 `0x546` 时才有），
/// 提交时必须原样回带——少了它服务端会以 `type=6 / 服务连接中` 之类拒掉。
String? _sliderT547FromState(File f) {
  if (!f.existsSync()) return null;
  try {
    final raw = jsonDecode(f.readAsStringSync());
    if (raw is Map<String, dynamic>) {
      final v = raw['t547'];
      if (v is String && v.isNotEmpty) return v;
    }
  } on Object {
    // 同上：坏了当作没有
  }
  return null;
}

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
    out('');
    out('日志已导出: ${f.path}');
  } else {
    out('');
    out('（加 --export-log 可导出日志报告）');
  }
}
