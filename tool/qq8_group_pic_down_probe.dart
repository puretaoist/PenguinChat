/// P3 探针：发 WUP `ImgStore.GroupPicDown`（cmd0x388 subcmd=2）取新的 down_para。
///
/// 只读诊断工具：不写任何本地文件、不发消息。需要 QQ_LIVE_CONFIRM 显式确认。
///
/// 用法：
/// ```
/// dart run tool/qq8_group_pic_down_probe.dart --token-file=_token.json \
///     --identity=_identity.json --gid=486045673 --begin=59120 --end=59240
/// ```
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
import 'package:qqclient/kernel/wlogin8/qq8_history.dart';
import 'package:qqclient/kernel/wlogin8/qq8_image.dart';
import 'package:qqclient/kernel/wlogin8/qq8_pb.dart';
import 'package:qqclient/kernel/wlogin8/qq8_profiles.dart';
import 'package:qqclient/kernel/wlogin8/qq8_session.dart';
import 'package:qqclient/kernel/wlogin8/qq8_sso.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tran.dart';

const String kConfirm = 'I_UNDERSTAND_THE_RISK';
const String kCmdGroupPicDown = 'ImgStore.GroupPicDown';
const String kBuildVer = '8.2.11.0153f87a';

final Logger _log = Log.get('PICDOWN');

String _hexStr(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

String _dump(Object? v, [String indent = '    ']) {
  final sb = StringBuffer();
  if (v is Uint8List) {
    final text = v.every((c) => c >= 32 && c < 127) && v.isNotEmpty
        ? String.fromCharCodes(v)
        : null;
    sb.write('bytes(${v.length}) ${_hexStr(v)}'
        '${text == null ? '' : '  ascii="$text"'}');
  } else if (v is int) {
    sb.write('$v');
  } else if (v is List) {
    for (final e in v) {
      sb.write('\n$indent- ${_dump(e, indent)}');
    }
  } else if (v is Map) {
    for (final e in v.entries) {
      sb.write('\n$indent${e.key}: ${_dump(e.value, indent)}');
    }
  } else {
    sb.write('$v');
  }
  return sb.toString();
}

Uint8List _md5OfHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

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
  Log.configure(minLevel: LogLevel.debug, ringCapacity: 2000);
  Log.addSink(FileLogSink(Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}qqclient-logs')));

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
    return _md5OfHex(v.replaceAll(' ', ''));
  }

  final uin = raw['uin'] as int;
  final tgt = hexOf('tgt');
  final d2 = hexOf('d2');
  final d2key = hexOf('d2key');

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

  final profile = qq8ClientProfiles[args['profile'] ?? '8.2.11'] ??
      qq8DefaultProfile;
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
    qimei36: identity?.qimei,
  );
  session.onError = (Object e) => _log.w('收包解析失败', error: e);

  if (Platform.environment['QQ_LIVE_CONFIRM'] != kConfirm) {
    stdout.writeln('干跑：uin=$uin gid=$gid seq=$begin-$end');
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
      Qq8History.buildGroupMsgBody(
          groupCode: gid, beginSeq: begin, endSeq: end),
      timeout: const Duration(seconds: 20),
    );
    final top = Qq8Pb.decode(frame.payload);
    final faces = <Map<String, Object?>>[]; // {seq, fromUin, cf}
    for (final mBytes in (top[6] as List<Object?>?) ?? const <Object?>[]) {
      if (mBytes is! Uint8List) continue;
      final msg = Qq8Pb.decode(mBytes);
      final head = Qq8Pb.decode(Qq8Pb.bytesAt(msg, 1) ?? Uint8List(0));
      final body = Qq8Pb.bytesAt(msg, 3);
      if (body == null) continue;
      final rich = Qq8Pb.bytesAt(Qq8Pb.decode(body), 1);
      if (rich == null) continue;
      final elems = Qq8Pb.decode(rich)[2];
      for (final e in (elems as List<Object?>?) ?? const <Object?>[]) {
        if (e is! Uint8List) continue;
        final em = Qq8Pb.decode(e);
        final cf = Qq8Pb.bytesAt(em, 8); // Elem.custom_face
        if (cf == null) continue;
        faces.add(<String, Object?>{
          'seq': Qq8Pb.intAt(head, 5) ?? 0,
          'fromUin': Qq8Pb.intAt(head, 1) ?? 0,
          'cf': Qq8Pb.decode(cf),
        });
      }
    }
    stdout.writeln('群 $gid seq=$begin-$end 图片元素 ${faces.length} 个');
    for (final f in faces.take(3)) {
      stdout.writeln('\n--- seq=${f['seq']} from=${f['fromUin']} 原始 custom_face 全字段:');
      stdout.writeln(_dump(f['cf']));
    }
    if (faces.isEmpty) return;

    // 对前两张图各试三种 url_flag/url_type 组合
    final variants = <int>[
      Qq8ImageDown.picTypeOriginal,
      Qq8ImageDown.picTypeBig,
      Qq8ImageDown.picTypeThumb,
    ];
    for (final f in faces.take(2)) {
      final cf = f['cf']! as Map<int, List<Object>>;
      final md5hex = _hexStr(Qq8Pb.bytesAt(cf, 13) ?? Uint8List(0));
      final fidStr = Qq8Pb.textAt(cf, 7) ?? '';
      stdout.writeln('\n==== seq=${f['seq']} md5=$md5hex fid=$fidStr');
      for (final picType in variants) {
        final (flag, type) = Qq8ImageDown.urlFlagTypeOf(picType);
        final body = Qq8ImageDown.buildGroupPicDownBody(
          gid: gid,
          uin: uin,
          md5HexList: <String>[md5hex],
          picType: picType,
        );
        stdout.writeln('\n-- picType=$picType（url_flag=$flag url_type=$type）');
        try {
          final rsp = await session.sendUni(Qq8ImageDown.cmdGroupPicDown, body,
              timeout: const Duration(seconds: 20));
          final rt = Qq8Pb.decode(rsp.payload);
          stdout.writeln('   RspBody 原始:');
          stdout.writeln(_dump(rt, '     '));
          final replies = Qq8ImageDown.parseGroupPicDownResponse(rsp.payload);
          for (final r in replies) {
            stdout.writeln('   解析: $r');
            for (final e in <String, Uint8List?>{
              'thumb': r.thumbPara,
              'original': r.originalPara,
              'big': r.bigPara,
              'bigThumb': r.bigThumbPara,
            }.entries) {
              final b = e.value;
              if (b == null) continue;
              stdout.writeln('     ${e.key} = ${_hexStr(b)}'
                  '  ascii="${String.fromCharCodes(b.where((c) => c >= 32 && c < 127))}"');
            }
          }
        } on Object catch (e) {
          stdout.writeln('   失败: $e');
        }
      }
    }
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
