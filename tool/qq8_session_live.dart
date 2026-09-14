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
///
/// # 上线后发一条消息（文本）
/// dart run tool/qq8_session_live.dart --send --token-file=token.json \
///     --to-uin=22222 --text="你好"
///
/// # 上线后发一张本地图片（**图片上传链路的真机入口**：四步全走）
/// dart run tool/qq8_session_live.dart --send --token-file=token.json \
///     --to-uin=22222 --image=C:\图片\cat.png
/// # 干跑也能先验"探图 + 组申请包"（不发）：去掉 --send 即可
/// ```
///
/// 发图的四步（输出里每步都有编号，卡在哪一步一眼能看到）：
/// ① 探图（md5/宽高/类型）→ ② `OffPicUp`/`GroupPicUp` 申请（拿 fid/ticket/
/// 图床地址）→ ③ highway `PicUp.DataUp` 传数据（服务端已有同 md5 的图会跳过）
/// → ④ fid 回填元素后 `PbSendMsg`。字段号出处与证据等级见
/// `lib/kernel/wlogin8/qq8_image.dart` 头注。
///
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

import 'package:qqclient/infra/coder.dart';
import 'package:qqclient/infra/log/log_file.dart';
import 'package:qqclient/infra/log/logger.dart';
import 'package:qqclient/kernel/crypto/ecdh.dart';
import 'package:qqclient/kernel/wlogin8/qq8_config.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_elem.dart';
import 'package:qqclient/kernel/wlogin8/qq8_image.dart';
import 'package:qqclient/kernel/wlogin8/qq8_msg.dart';
import 'package:qqclient/kernel/wlogin8/qq8_profiles.dart';
import 'package:qqclient/kernel/wlogin8/qq8_push.dart';
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
    // 要发图时**本地能先验的部分**在这里验掉（探图 + 组申请包 + 印字段），
    // 免得真机跑完注册/心跳才发现图路径写错或格式不支持。
    final dryImage = args['image'];
    final dryTo = int.tryParse(args['to-uin'] ?? '') ??
        int.tryParse(args['to-group'] ?? '');
    if (dryImage != null && dryImage.isNotEmpty && dryTo != null) {
      stdout.writeln('');
      stdout.writeln('--- 干跑：图片那一步（只探图 + 组包，不发）---');
      try {
        final info = await Qq8ImageProbe.probeFile(dryImage);
        stdout.writeln('  ① 探图: $info');
        final dm = args['to-uin'] != null;
        final body = dm
            ? Qq8ImageUp.buildOffPicUpBody(
                uin: uin,
                uid: dryTo,
                images: <Qq8ImageInfo>[info],
                apkVersion: profile.versionCode,
              )
            : Qq8ImageUp.buildGroupPicUpBody(
                gid: dryTo,
                uin: uin,
                images: <Qq8ImageInfo>[info],
                apkVersion: profile.versionCode,
              );
        stdout.writeln('  ② ${dm ? 'OffPicUp' : 'GroupPicUp'} 申请包: '
            '${body.length} 字节（真发时连图床要等回执才知道 ip/port/ticket）');
      } on Object catch (e) {
        stdout.writeln('  ✗ 探图/组包失败: $e');
        exitCode = 2;
      }
    }
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
    _dumpPush(r.cmd, r.payload);
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

    // 3.5) 可选：发一条消息（文本 / 图片）。给 `--to-uin` 或 `--to-group` 才做。
    //
    // 这是**图片上传链路的真机入口**：探图 → PicUp 申请（拿 fid/ticket/图床）
    // → highway 传数据 → 元素回填 → PbSendMsg。每一步的数字都打出来，
    // 失败时能直接看出卡在哪一步（而不是"发了没反应"）。
    final toUin = int.tryParse(args['to-uin'] ?? '');
    final toGroup = int.tryParse(args['to-group'] ?? '');
    final imagePath = args['image'];
    final textArg = args['text'];
    if (toUin != null || toGroup != null) {
      stdout.writeln('');
      stdout.writeln('--- 3.5 发消息（${toUin != null ? '私聊 $toUin' : '群 $toGroup'}）---');
      try {
        if (imagePath != null && imagePath.isNotEmpty) {
          await _sendImage(
            session: session,
            profile: profile,
            imagePath: imagePath,
            uid: toUin,
            gid: toGroup,
          );
        } else {
          await _sendText(
            session: session,
            text: textArg ?? '你好',
            uid: toUin,
            gid: toGroup,
          );
        }
      } on Object catch (e, st) {
        failed = true;
        stdout.writeln('  ✗ 发送失败: $e');
        _log.e('发送失败', error: e, stack: st);
      }
    } else if (imagePath != null || textArg != null) {
      stdout.writeln('');
      stdout.writeln('  ⚠ 给了 --image/--text 但没给 --to-uin / --to-group，'
          '不知道发给谁，跳过');
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
// 发消息（文本 / 图片）
// ---------------------------------------------------------------------------

int _randomU32() {
  final r = Random.secure();
  return ((r.nextInt(1 << 16) << 16) | r.nextInt(1 << 16)) & 0xFFFFFFFF;
}

/// 发一条纯文本（私聊/群）。走的是与 App 同一条 [Qq8Msg] 组包 + `PbSendMsg`。
Future<void> _sendText({
  required Qq8Session session,
  required String text,
  int? uid,
  int? gid,
}) async {
  final elems = <Uint8List>[Qq8Msg.textElem(text)];
  if (uid != null) {
    final seq = session.nextSeq();
    final rand = _randomU32();
    final body = Qq8Msg.buildC2cTextBody(
      uid: uid,
      elems: elems,
      seq: seq,
      rand: rand,
      syncCookieSeed: _randomU32(),
      nowSeconds:
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + session.timeDiffSeconds,
      syncR5: _randomU32(),
      syncR9: _randomU32(),
      syncR11: _randomU32(),
    );
    final rsp = await session.sendUni(Qq8Msg.sendCmd, body, seq: seq);
    final r = Qq8Msg.parseSendResponse(rsp.payload, seq: seq, rand: rand);
    stdout.writeln('  私聊文本 → code=${r.code} seq=${r.seq} '
        'time=${r.time} ${r.ok ? '✓ 已发送' : '✗ ${r.message}'}');
    _log.i('私聊发送 uid=$uid code=${r.code}');
    return;
  }
  final rand16 = _randomU32() & 0xFFFF;
  final rand32 = _randomU32();
  final body = Qq8Msg.buildGroupTextBody(
    gid: gid!,
    elems: elems,
    rand16: rand16,
    rand32: rand32,
  );
  final rsp = await session.sendUni(Qq8Msg.sendCmd, body);
  final r = Qq8Msg.parseSendResponse(rsp.payload, seq: 0, rand: rand32);
  stdout.writeln('  群文本 → code=${r.code} ${r.ok ? '✓ 已发送' : '✗ ${r.message}'}');
  _log.i('群发送 gid=$gid code=${r.code}');
}

/// 发一张本地图片：**四步链路**，每步的数字都打出来（卡在哪一步一眼能看到）。
Future<void> _sendImage({
  required Qq8Session session,
  required Qq8ClientProfile profile,
  required String imagePath,
  int? uid,
  int? gid,
}) async {
  final dm = uid != null;
  final info = await Qq8ImageProbe.probeFile(imagePath);
  stdout.writeln('  ① 探图: $info');
  stdout.writeln('     fileParam = ${info.fileParam}');

  final body = dm
      ? Qq8ImageUp.buildOffPicUpBody(
          uin: session.uin,
          uid: uid,
          images: <Qq8ImageInfo>[info],
          apkVersion: profile.versionCode,
        )
      : Qq8ImageUp.buildGroupPicUpBody(
          gid: gid!,
          uin: session.uin,
          images: <Qq8ImageInfo>[info],
          apkVersion: profile.versionCode,
        );
  final rsp = await session.sendUni(
    dm ? Qq8ImageUp.cmdOffPicUp : Qq8ImageUp.cmdGroupPicUp,
    body,
  );
  stdout.writeln('  ② ${dm ? 'OffPicUp' : 'GroupPicUp'} 申请: '
      '响应 ${rsp.payload.length} 字节');
  final replies = dm
      ? Qq8ImageUp.parseOffPicUpResponse(rsp.payload)
      : Qq8ImageUp.parseGroupPicUpResponse(rsp.payload);
  if (replies.isEmpty) {
    stdout.writeln('     ✗ 没有回执——字段号可能对不上（见 qq8_image.dart 头注）');
    return;
  }
  final reply = replies.first;
  stdout.writeln('     回执: $reply');
  if (!reply.ok) {
    stdout.writeln('     ✗ 被拒：code=${reply.code} ${reply.message}');
    return;
  }

  if (reply.alreadyExists) {
    stdout.writeln('  ③ 服务端已有这张图（md5 命中）→ 跳过 highway 上传');
  } else {
    stdout.writeln('  ③ highway 上传 → ${reply.host}:${reply.port} '
        '（ticket ${reply.ticket.length} 字节，${info.size} 字节数据）');
    await Qq8Highway.upload(
      host: reply.host!,
      port: reply.port!,
      uin: '${session.uin}',
      appid: profile.apk.subid,
      buCmdId: dm ? Qq8Highway.cmdIdDmImage : Qq8Highway.cmdIdGroupImage,
      ticket: reply.ticket,
      fileMd5: info.md5,
      data: await File(imagePath).readAsBytes(),
      timeout: const Duration(seconds: 120),
      onProgress: (p) {
        if (p >= 1.0) stdout.writeln('     上传完成 100%');
      },
    );
  }

  final elem = dm
      ? Qq8ImageElems.dm(info: info, fid: reply.fid)
      : Qq8ImageElems.group(info: info, fid: reply.fid);
  if (dm) {
    final seq = session.nextSeq();
    final rand = _randomU32();
    final msgBody = Qq8Msg.buildC2cTextBody(
      uid: uid,
      elems: <Uint8List>[elem],
      seq: seq,
      rand: rand,
      syncCookieSeed: _randomU32(),
      nowSeconds:
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + session.timeDiffSeconds,
      syncR5: _randomU32(),
      syncR9: _randomU32(),
      syncR11: _randomU32(),
    );
    final sent = await session.sendUni(Qq8Msg.sendCmd, msgBody, seq: seq);
    final r = Qq8Msg.parseSendResponse(sent.payload, seq: seq, rand: rand);
    stdout.writeln('  ④ 图片消息（fid=${reply.fid}）→ code=${r.code} '
        '${r.ok ? '✓ 已发送' : '✗ ${r.message}'}');
    _log.i('私聊图片 uid=$uid fid=${reply.fid} code=${r.code}');
    return;
  }
  final rand16 = _randomU32() & 0xFFFF;
  final rand32 = _randomU32();
  final msgBody = Qq8Msg.buildGroupTextBody(
    gid: gid!,
    elems: <Uint8List>[elem],
    rand16: rand16,
    rand32: rand32,
  );
  final sent = await session.sendUni(Qq8Msg.sendCmd, msgBody);
  final r = Qq8Msg.parseSendResponse(sent.payload, seq: 0, rand: rand32);
  stdout.writeln('  ④ 群图片消息（fid=${reply.fid}）→ code=${r.code} '
      '${r.ok ? '✓ 已发送' : '✗ ${r.message}'}');
  _log.i('群图片 gid=$gid fid=${reply.fid} code=${r.code}');
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

/// 把推送解析成人能看的几行——**真机验证就靠这段输出**：
/// 收到语音/视频/图片时，字段号对不对、直链长什么样，这里全能看出来。
///
/// 认不出的元素会把原始 payload 的前 64 字节按十六进制打出来（带偏移），
/// 方便贴回来对照字段号。
void _dumpPush(String cmd, Uint8List payload) {
  Qq8PushEvent ev;
  try {
    ev = qq8ParsePush(cmd, payload);
  } on Object catch (e) {
    stdout.writeln('    （解析失败：$e）');
    return;
  }

  switch (ev) {
    case Qq8MessagePush(:final message, :final needsAck):
      stdout.writeln('    → 收到消息 kind=${message.kind.name} '
          'from=${message.fromUin}'
          '${message.groupCode == null ? '' : ' gid=${message.groupCode}'} '
          'seq=${message.seq} rand=${message.rand} t=${message.time}'
          '${needsAck ? ' needsAck' : ''}');
      stdout.writeln('      文本: ${message.text}');
      stdout.writeln('      元素: ${message.elemKinds.join('/')}');
      for (final e in message.elems) {
        final line = switch (e) {
          Qq8TextElem(:final text) => '文本(${text.length} 字)',
          Qq8AtElem(:final target, :final name) =>
            '@$target${name == null ? '' : '($name)'}',
          Qq8FaceElem(:final id, :final isBig) =>
            '表情 id=$id${isBig ? ' 大' : ''}',
          Qq8ImageElem(
            :final file,
            :final url,
            :final width,
            :final height,
            :final flash
          ) =>
            '图片 ${width}x$height${flash ? ' 闪照' : ''} file=$file url=${url ?? '(无)'}',
          Qq8VoiceElem(:final seconds, :final size, :final url, :final md5) =>
            '语音 ${seconds}s ${size}B md5=${md5 ?? '(无)'} url=${url ?? '(无)'}',
          Qq8VideoElem(
            :final name,
            :final seconds,
            :final size,
            :final fileId
          ) =>
            '视频 ${name ?? ''} ${seconds}s ${size}B fid=${fileId ?? '(无)'}',
          Qq8FileElem(:final name, :final size, :final fileId) =>
            '文件 ${name ?? ''} ${size}B fid=${fileId ?? '(无)'}',
          Qq8CardElem(:final kind, :final raw, :final summary) =>
            '卡片 $kind 摘要=$summary 原文=${raw.length} 字符',
          Qq8ReplyElem(:final seq, :final preview) => '引用 seq=$seq 「$preview」',
          Qq8PokeElem(:final id) => '戳一戳 id=${id ?? '(无)'}',
          Qq8UnsupportedElem(:final name, :final field) =>
            '**认不出** name=$name field=$field',
        };
        stdout.writeln('      - $line');
      }
      // 有认不出的元素时，把原始 payload 头部打出来（贴回来就能对照字段号）
      if (message.elems.any((e) => e is Qq8UnsupportedElem)) {
        final head = payload.length <= 64 ? payload : payload.sublist(0, 64);
        stdout.writeln('      payload 前 ${head.length} 字节：');
        stdout.writeln(hexdump(head, prefix: '        '));
      }
    case Qq8KickPush(:final hint):
      stdout.writeln('    → 被踢下线：$hint');
    case Qq8NotifyPush(:final notifyType):
      stdout.writeln('    → 有新消息通知 type=$notifyType'
          '（33/38/85/141/166/167/208/529 会触发一次 PbGetMsg 拉取）');
    case Qq8UnknownPush(:final note, :final payloadLength):
      stdout.writeln('    → 未处理的推送（$payloadLength 字节）${note ?? ''}');
      final head = payload.length <= 64 ? payload : payload.sublist(0, 64);
      stdout.writeln(hexdump(head, prefix: '        '));
  }
}
