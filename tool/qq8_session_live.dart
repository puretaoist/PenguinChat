/// 会话层真机验证工具：登录成功**之后**的那一段（注册上线 → 校时 → 心跳）。
///
/// ## 与 `qq8_live_smoke.dart` 的分工
///
/// * `qq8_live_smoke.dart`：登录本身（子命令 9 密码 / 11 token / 2 滑验证），
///   成功后用 `--save-token=<path>` 把票据落盘；
/// * 本工具：**读那份票据**起一条会话，验证服务端认不认我们的
///   `StatSvc.register` 与心跳三件套（`Client.CorrectTime` /
///   `Heartbeat.Alive` / `OidbSvc.0x480_9_IMCore`）。
///
/// 端到端验证 = 先跑前者拿到 `type=0`，再跑本工具。
///
/// ## 用法
///
/// ```bash
/// # 1) 干跑：只看要发什么，不联网（不需要确认串）
/// dart run tool/qq8_session_live.dart --token-file=token.json
///
/// # 2) 真发：两道闸门（--send + 环境变量确认）
/// $env:QQ_LIVE_CONFIRM="I_UNDERSTAND_THE_RISK"
/// dart run tool/qq8_session_live.dart --send --token-file=token.json
///
/// # 多跑几轮心跳（默认 1 轮；每轮 = 校时 + Alive + UNI 心跳）
/// dart run tool/qq8_session_live.dart --send --token-file=token.json --rounds=3
///
/// # 结束时正常下线（发 logout 注册）
/// dart run tool/qq8_session_live.dart --send --token-file=token.json --logout
/// ```
///
/// ## 判读口径
///
/// | 输出 | 含义 |
/// |---|---|
/// | `register() = true` | 服务端接受了上线注册（`rsp[9]` 真值）→ **票据有效、会话成立** |
/// | `register() = false` | 包被受理但注册被拒：多半是票据过期/d2 失效，或 body 字段不符 |
/// | `校时 = <ts>` | `Client.CorrectTime` 有响应，前 4 字节是服务端时间 |
/// | `Alive / UNI 心跳` 有响应 | 心跳链路通；UNI 心跳是**业务包**通道，通了说明 d2key 加密的 SSO 层也对 |
/// | 全部超时、无任何响应 | 与登录时"静默不回"同一类症状：包被丢弃（先看登录那一步是否真的 type=0） |
/// | `推送: cmd=…` | 服务端主动下发（如 `MessageSvc.PushNotify`）——**这是会话真的活着的强信号** |
///
/// ## 安全边界
///
/// * 票据是明文会话凭据：`--token-file` 指向的文件**不要进 git**，用完删掉；
///   本工具只打印长度与指纹，不打印内容。
/// * 注册/心跳不消耗登录尝试配额（不写限流器），但**别循环猛跑**：
///   长时间高频心跳同样是风控特征。默认只跑一轮。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:qqclient/infra/log/log_file.dart';
import 'package:qqclient/infra/log/logger.dart';
import 'package:qqclient/kernel/crypto/ecdh.dart';
import 'package:qqclient/kernel/wlogin8/qq8_config.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_profiles.dart';
import 'package:qqclient/kernel/wlogin8/qq8_session.dart';
import 'package:qqclient/kernel/wlogin8/qq8_sso.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tran.dart';

final Logger _log = Log.get('SESSION-LIVE');

/// 真发所需的确认串（与 `qq8_live_smoke.dart` 同一个）。
const String kConfirmToken = 'I_UNDERSTAND_THE_RISK';

Future<void> main(List<String> argv) async {
  final args = _parseArgs(argv);

  final logDir = Directory(
    args['logdir'] ??
        '${Directory.systemTemp.path}${Platform.pathSeparator}qqclient-logs',
  );
  Log.configure(minLevel: LogLevel.debug, ringCapacity: 4000);
  Log.addSink(FileLogSink(logDir));

  stdout.writeln('=' * 70);
  stdout.writeln('QQ 会话层真机验证（注册 + 心跳）');
  stdout.writeln('=' * 70);

  // ---------- 票据 ----------
  final tokenPath = args['token-file'];
  if (tokenPath == null || tokenPath.isEmpty) {
    stderr.writeln('✗ 需要 --token-file=<path>（由 qq8_live_smoke.dart '
        '--save-token 产出）');
    exitCode = 2;
    return;
  }
  final _Token token;
  try {
    token = _Token.load(File(tokenPath));
  } on Object catch (e) {
    stderr.writeln('✗ 票据文件读取失败: $e');
    exitCode = 2;
    return;
  }

  final uinArg = args['uin'] ?? Platform.environment['QQ_LIVE_UIN'];
  final uin = (uinArg != null && uinArg.isNotEmpty)
      ? int.parse(uinArg)
      : token.uin;

  if (token.d2.isEmpty || token.d2key.isEmpty) {
    stderr.writeln('✗ 票据里没有 d2/d2key，无法上线'
        '（登录那一步是否真的拿到 type=0？）');
    exitCode = 2;
    return;
  }

  // ---------- 档案与会话材料 ----------
  final profileName = args['profile'] ?? 'default';
  final profile = profileName == 'default'
      ? qq8DefaultProfile
      : (qq8ClientProfiles[profileName] ?? qq8DefaultProfile);

  // 设备必须与登录时**同一套**（同 uin 派生），否则"同一账号同一设备"的前提破了。
  // tgtgt 走 token 路径的约定值 MD5(d2key)。
  final device = Qq8Device.generate(uin).withTgtgt(md5Bytes(token.d2key));
  final ecdh = Ecdh.exchange(
    Uint8List.fromList(Qq8Config.serverEcdhPublicKey),
  );
  final sessionId = _randomBytes(4);
  final randomKey = _randomBytes(16);
  final rounds = int.tryParse(args['rounds'] ?? '1') ?? 1;
  final logout = args.containsKey('logout');
  final live = args.containsKey('send');

  stdout.writeln('--- 会话参数 ---');
  stdout.writeln('  ${profile.describe()}');
  stdout.writeln('  uin: $uin');
  stdout.writeln('  票据: ${token.savedAt}'
      '（tgt ${token.tgt.length}B / d2 ${token.d2.length}B / '
      'd2key ${token.d2key.length}B）');
  stdout.writeln('  设备: ${device.brand} ${device.model}  '
      'imei=${device.imei}  ${Redact.fingerprint('guid', device.guid)}');
  stdout.writeln('  ECDH 公钥: ${ecdh.publicKey.length} 字节  '
      '${Redact.fingerprint('share_key', ecdh.shareKey)}');
  stdout.writeln('  心跳轮数: $rounds    结束下线: $logout');
  stdout.writeln('  模式: ${live ? '**真实发送**' : '**干跑（不联网）**'}');
  stdout.writeln('');

  if (!live) {
    stdout.writeln('干跑结束：以上就是一次会话要用的全部材料。');
    stdout.writeln('真发前需要：');
    stdout.writeln('  1) 加 --send');
    stdout.writeln('  2) 设环境变量 QQ_LIVE_CONFIRM="$kConfirmToken"');
    await _finish(logDir, args);
    return;
  }

  // ---------- 真发闸门 ----------
  if (Platform.environment['QQ_LIVE_CONFIRM'] != kConfirmToken) {
    stdout.writeln('✗ 未设置 QQ_LIVE_CONFIRM');
    stdout.writeln('  本工具拒绝在无显式确认的情况下连生产服务器。');
    stdout.writeln('  确认理解风险后：\$env:QQ_LIVE_CONFIRM="$kConfirmToken"');
    await _finish(logDir, args);
    exitCode = 2;
    return;
  }
  stdout.writeln('✓ 显式确认已给出');

  final transport = Qq8TcpTransport();
  final session = Qq8Session(
    transport: transport,
    profile: profile,
    uin: uin,
    device: device,
    sessionId: sessionId,
    ecdhPublicKey: ecdh.publicKey,
    ecdhShareKey: ecdh.shareKey,
    sig: Qq8SigInfo(
      tgt: token.tgt,
      d2: token.d2,
      d2key: token.d2key,
      sigKey: token.sigKey,
      ticketKey: token.ticketKey,
      srmToken: token.srmToken,
    ),
    randomKey: randomKey,
  );

  var parseErrors = 0;
  var offline = false;
  session.onError = (Object e) {
    parseErrors++;
    stdout.writeln('  ⚠ 收包解析失败: $e');
    _log.w('收包解析失败', error: e);
  };
  session.onOffline = () {
    offline = true;
    stdout.writeln('  ⚠ 心跳连失败两次 → 视为掉线');
  };

  final pushSub = session.pushes.listen((r) {
    stdout.writeln('  ← 推送: cmd=${r.cmd} seq=${r.seq} '
        'payload=${r.payload.length} 字节');
    _log.i('推送 cmd=${r.cmd} seq=${r.seq} len=${r.payload.length}');
  });

  var failed = false;
  try {
    stdout.writeln('');
    stdout.writeln('--- 连接 ${transport.host}:${transport.port} ---');
    await session.start();
    stdout.writeln('  已连接并开始收包');

    // 1) 上线注册
    stdout.writeln('');
    stdout.writeln('--- 1. StatSvc.register（上线注册）---');
    final registered = await session.register();
    stdout.writeln('  register() = $registered');
    _log.i('register=$registered');
    if (!registered) {
      stdout.writeln('  ✗ 注册未被接受：票据可能已失效，或 body 字段与服务端预期不符');
      failed = true;
    }

    // 2) 校时
    stdout.writeln('');
    stdout.writeln('--- 2. Client.CorrectTime（校时）---');
    try {
      final ts = await session.correctTime();
      stdout.writeln('  服务端时间 = $ts'
          '（本地 ${DateTime.now().millisecondsSinceEpoch ~/ 1000}，'
          '时差 ${session.timeDiffSeconds}s）');
    } on Object catch (e) {
      stdout.writeln('  ⚠ 校时失败（不致命）: $e');
    }

    // 3) 心跳
    stdout.writeln('');
    stdout.writeln('--- 3. 心跳三件套（$rounds 轮）---');
    for (var i = 1; i <= rounds && !offline; i++) {
      stdout.writeln('  第 $i 轮:');
      try {
        final alive = await session.heartbeatAlive();
        stdout.writeln('    Heartbeat.Alive → 响应 ${alive.payload.length} 字节');
      } on Object catch (e) {
        stdout.writeln('    ✗ Heartbeat.Alive 失败: $e');
        failed = true;
      }
      try {
        final uni = await session.uniHeartbeat();
        stdout.writeln('    OidbSvc.0x480_9_IMCore → cmd=${uni.cmd} '
            'payload=${uni.payload.length} 字节');
      } on Object catch (e) {
        stdout.writeln('    ✗ UNI 心跳失败: $e');
        failed = true;
      }
      stdout.writeln('    isOnline=${session.isOnline}');
      if (i < rounds) await Future<void>.delayed(const Duration(seconds: 3));
    }

    // 4) 可选下线
    if (logout) {
      stdout.writeln('');
      stdout.writeln('--- 4. 注销下线 ---');
      try {
        final ok = await session.register(logout: true);
        stdout.writeln('  logout register() = $ok');
      } on Object catch (e) {
        stdout.writeln('  ⚠ 注销失败（不影响本次验证结论）: $e');
      }
    }
  } on Object catch (e, st) {
    failed = true;
    stdout.writeln('');
    stdout.writeln('✗ 会话流程异常: $e');
    _log.e('会话流程异常', error: e, stack: st);
  } finally {
    await pushSub.cancel();
    await session.close();
  }

  stdout.writeln('');
  stdout.writeln('--- 汇总 ---');
  stdout.writeln('  收包解析失败次数: $parseErrors');
  stdout.writeln('  掉线标记: $offline');
  stdout.writeln('  结论: ${failed ? '✗ 有失败项（见上）' : '✓ 注册与心跳全通'}');
  stdout.writeln('  日志目录: ${logDir.path}');

  await _finish(logDir, args);
  exitCode = failed ? 1 : 0;
}

// ---------------------------------------------------------------------------

/// 票据文件（与 `qq8_live_smoke.dart --save-token` 的格式一致）。
class _Token {
  final int uin;
  final String savedAt;
  final Uint8List tgt;
  final Uint8List d2;
  final Uint8List d2key;
  final Uint8List sigKey;
  final Uint8List ticketKey;
  final Uint8List srmToken;

  const _Token({
    required this.uin,
    required this.savedAt,
    required this.tgt,
    required this.d2,
    required this.d2key,
    required this.sigKey,
    required this.ticketKey,
    required this.srmToken,
  });

  static _Token load(File f) {
    if (!f.existsSync()) {
      throw FormatException('文件不存在: ${f.path}');
    }
    final Object? raw = jsonDecode(f.readAsStringSync());
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('不是 JSON 对象');
    }
    final Object? uin = raw['uin'];
    if (uin is! int) {
      throw const FormatException('缺少 uin');
    }
    Uint8List hexField(String key) {
      final Object? v = raw[key];
      if (v is! String || v.isEmpty) return Uint8List(0);
      return _hex(v);
    }

    return _Token(
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
}

Uint8List _hex(String s) {
  final clean = s.replaceAll(' ', '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(n, (_) => r.nextInt(256), growable: false),
  );
}

Map<String, String> _parseArgs(List<String> argv) {
  final out = <String, String>{};
  for (final a in argv) {
    if (!a.startsWith('--')) continue;
    final eq = a.indexOf('=');
    if (eq < 0) {
      out[a.substring(2)] = '';
    } else {
      out[a.substring(2, eq)] = a.substring(eq + 1);
    }
  }
  return out;
}

Future<void> _finish(Directory logDir, Map<String, String> args) async {
  await Log.flush();
  if (args.containsKey('export-log')) {
    final f = await LogExporter.exportToDirectory(
      logDir,
      metadata: <String, Object?>{
        'tool': 'qq8_session_live',
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
    stdout.writeln('（日志: ${logDir.path}；加 --export-log 可导出日志报告）');
  }
}
