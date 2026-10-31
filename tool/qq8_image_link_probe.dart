/// P2 直链刷新实验：重新拉一段群历史，逐条打印图片元素的直链形态。
///
/// 目的：回答「重新拉历史能不能拿到新的 rkey / 新的直链」。做法是拿本地
/// 已落盘的图片消息（url 早已 404）对应的 seq 区间，向服务端**重新要一次**，
/// 把回来的 `Qq8ImageElem.url` 打出来，与本地存的 url 对比：
///
/// * 服务端换发了新 rkey ⇒ url 字符串不同、且新 url 能 200（刷新可行）
/// * 回来的还是一模一样的 md5 兜底 url ⇒ 服务端不给新直链（只能走富媒体下载）
///
/// ## 用法
/// ```
/// dart run tool/qq8_image_link_probe.dart --token-file=_token.json \
///     --identity=_identity.json --gid=486045673 --begin=59120 --end=59240
/// ```
///
/// 需要 `QQ_LIVE_CONFIRM` 显式确认（与 qq8_session_live 同一把钥匙）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:qqclient/infra/log/log_file.dart';
import 'package:qqclient/infra/log/logger.dart';
import 'package:qqclient/kernel/crypto/ecdh.dart';
import 'package:qqclient/kernel/wlogin8/qq8_config.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_elem.dart';
import 'package:qqclient/kernel/wlogin8/qq8_history.dart';
import 'package:qqclient/kernel/wlogin8/qq8_profiles.dart';
import 'package:qqclient/kernel/wlogin8/qq8_session.dart';
import 'package:qqclient/kernel/wlogin8/qq8_sso.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tran.dart';

const String kConfirm = 'I_UNDERSTAND_THE_RISK';

final Logger _log = Log.get('IMG-PROBE');

Future<void> main(List<String> argv) async {
  final args = <String, String>{};
  for (final a in argv) {
    if (!a.startsWith('--')) continue;
    final i = a.indexOf('=');
    if (i < 0) {
      args[a.substring(2)] = '';
    } else {
      args[a.substring(2, i)] = a.substring(i + 1);
    }
  }
  final logDir = Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}qqclient-logs',
  );
  Log.configure(minLevel: LogLevel.debug, ringCapacity: 2000);
  Log.addSink(FileLogSink(logDir));

  final tokenPath = args['token-file'];
  if (tokenPath == null || tokenPath.isEmpty) {
    stderr.writeln('需要 --token-file=<path>');
    exitCode = 2;
    return;
  }
  final raw = jsonDecode(File(tokenPath).readAsStringSync());
  if (raw is! Map<String, dynamic>) {
    stderr.writeln('票据不是 JSON 对象');
    exitCode = 2;
    return;
  }
  Uint8List hexOf(String k) {
    final v = raw[k];
    if (v is! String || v.isEmpty) return Uint8List(0);
    final s = v.replaceAll(' ', '');
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  final uin = raw['uin'] as int;
  final tgt = hexOf('tgt');
  final d2 = hexOf('d2');
  final d2key = hexOf('d2key');
  if (d2.isEmpty || d2key.isEmpty) {
    stderr.writeln('票据没有 d2/d2key');
    exitCode = 2;
    return;
  }

  Qq8DeviceIdentity? identity;
  final identityPath = args['identity'];
  if (identityPath != null && identityPath.isNotEmpty) {
    final dec = jsonDecode(File(identityPath).readAsStringSync());
    if (dec is Map) {
      identity = Qq8DeviceIdentity.fromJson(Map<String, Object?>.from(dec));
    }
  }
  final device = (identity != null
          ? Qq8Device.fromIdentity(identity)
          : Qq8Device.generate(uin))
      .withTgtgt(md5Bytes(d2key));
  final qimei36 = identity?.qimei;
  final ecdh = Ecdh.exchange(Uint8List.fromList(Qq8Config.serverEcdhPublicKey));
  final rnd = Random.secure();
  Uint8List rb(int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => rnd.nextInt(256)));

  final gid = int.parse(args['gid'] ?? '0');
  final begin = int.parse(args['begin'] ?? '0');
  final end = int.parse(args['end'] ?? '0');
  if (gid == 0 || begin == 0 || end < begin) {
    stderr.writeln('需要 --gid --begin --end（end>=begin）');
    exitCode = 2;
    return;
  }

  final localUrlByMd5 = <String, String>{};
  final cmp = args['compare'];
  if (cmp != null && cmp.isNotEmpty && File(cmp).existsSync()) {
    for (final line in File(cmp).readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final Object? m;
      try {
        m = jsonDecode(line);
      } on Object {
        continue;
      }
      if (m is! Map) continue;
      final segs = m['segments'];
      if (segs is! List) continue;
      for (final s in segs) {
        if (s is! Map || s['type'] != 'image') continue;
        final d = s['data'];
        if (d is! Map) continue;
        final file = '${d['file'] ?? ''}';
        final url = '${d['url'] ?? ''}';
        final base = file.split('-').first.toLowerCase(); final md5 = base.length > 32 ? base.substring(0, 32) : base;
        if (md5.isNotEmpty) localUrlByMd5[md5] = url;
      }
    }
    stdout.writeln('本地对比样本: ${localUrlByMd5.length} 张');
  }

  final profileName = args['profile'] ?? '8.2.11';
  final profile = qq8ClientProfiles[profileName] ?? qq8DefaultProfile;
  final session = Qq8Session(
    transport: Qq8TcpTransport(),
    profile: profile,
    uin: uin,
    device: device,
    sessionId: rb(4),
    ecdhPublicKey: ecdh.publicKey,
    ecdhShareKey: ecdh.shareKey,
    sig: Qq8SigInfo(
      tgt: tgt,
      d2: d2,
      d2key: d2key,
      sigKey: hexOf('sig_key'),
      ticketKey: hexOf('ticket_key'),
      srmToken: hexOf('srm_token'),
    ),
    randomKey: rb(16),
    qimei36: qimei36,
  );
  session.onError = (Object e) => _log.w('收包解析失败', error: e);

  if (Platform.environment['QQ_LIVE_CONFIRM'] != kConfirm) {
    stdout.writeln('干跑：uin=$uin gid=$gid seq=$begin-$end 档案=${profile.describe()}');
    stdout.writeln('真跑需要 QQ_LIVE_CONFIRM=$kConfirm');
    return;
  }

  try {
    await session.start();
    var ok = false;
    try {
      ok = await session.register();
    } on Object catch (e) {
      stdout.writeln('register 无 ack（可继续）: $e');
    }
    stdout.writeln('register=$ok');
    final frame = await session.sendUni(
      Qq8History.cmdGetGroupMsg,
      Qq8History.buildGroupMsgBody(groupCode: gid, beginSeq: begin, endSeq: end),
      timeout: const Duration(seconds: 20),
    );
    final page = Qq8History.parseGroupMsg(frame.payload);
    stdout.writeln('群历史 gid=$gid seq=$begin-$end result=${page.result} '
        '条数=${page.messages.length}');
    var imgs = 0;
    for (final m in page.messages) {
      for (final e in m.elems) {
        if (e is! Qq8ImageElem) continue;
        imgs++;
        final md5 = (e.md5 ?? '').toLowerCase();
        final localUrl = localUrlByMd5[md5];
        final same = localUrl != null && localUrl == (e.url ?? '');
        stdout.writeln('');
        stdout.writeln('seq=${m.seq} t=${m.time} from=${m.fromUin}');
        stdout.writeln('  file=${e.file}');
        stdout.writeln('  md5=$md5');
        stdout.writeln('  url=${e.url}');
        if (localUrl != null) {
          stdout.writeln('  本地url=$localUrl');
          stdout.writeln('  相同=$same');
        }
      }
    }
    stdout.writeln('');
    stdout.writeln('图片元素共 $imgs 个');
  } on Object catch (e, st) {
    stderr.writeln('失败: $e');
    stderr.writeln(st);
    exitCode = 1;
  } finally {
    try {
      await session.close();
    } on Object {/* 关了就好 */}
  }
}
