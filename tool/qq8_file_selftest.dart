/// 离线文件（OfflineFilleHandleSvr）协议离线自测
///
/// **不需要网络、不需要账号**。所有黄金向量由**独立第二实现**
/// `analysis/scripts/gen_file_vectors.py`（Python 手写 protobuf，不依赖
/// oicq、不引用 Dart 代码）生成，本文件把 Dart 侧编码结果与它逐字节比对。
///
/// 覆盖：
/// * 1700 申请上传体 / 800 上传完成 / 400 撤回 / 700 转发 / 1200 取链接；
/// * highway 的 ext（含"把 1700 完整响应塞进 100.100.700"这条硬要求）；
/// * 发消息体（路由字段 15 + `msg_content` 里套 `NotOnlineFile`）；
/// * HTTP 帧外层（STX / 头长 / 块长 / 头里 3=ext、4=时间戳 / ETX）；
/// * 各回执的解析（含"url 是相对路径时拼 host:port"）。
///
/// 运行：
/// ```bash
/// dart run tool/qq8_file_selftest.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/crypto/digest.dart';
import 'package:qqclient/kernel/wlogin8/qq8_file.dart';
import 'package:qqclient/kernel/wlogin8/qq8_pb.dart';

int _pass = 0;
int _fail = 0;

void ok(String name, [String? note]) {
  _pass++;
  stdout.writeln('  \u2713 $name${note == null ? '' : '   ($note)'}');
}

void bad(String name, String detail) {
  _fail++;
  stdout.writeln('  \u2717 $name\n      \u2192 $detail');
}

void section(String t) => stdout.writeln('\n$t');

Uint8List hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String toHex(List<int> b) =>
    b.map((x) => (x & 0xff).toRadixString(16).padLeft(2, '0')).join();

void eqHex(String name, Uint8List actual, String expectedHex) {
  final got = toHex(actual);
  if (got == expectedHex) {
    ok(name, '${actual.length} B');
  } else {
    bad(name, '实际 $got\n        期望 $expectedHex');
  }
}

// ---------------------------------------------------------------------------
// 与 Python 生成脚本完全一致的输入
// ---------------------------------------------------------------------------

const int uin = 3499239040;
const int peer = 2089495846;
const String fileName = '测试.bin';
const int fileSize = 12345;
const String fid = 'a1b2c3d4e5f6';
const int subid = 537298353;
const int nowSeconds = 1760000000;

final Uint8List fileMd5 = Uint8List.fromList(List<int>.generate(16, (i) => i));
final Uint8List fileSha1 = Uint8List.fromList(List<int>.generate(20, (i) => i));
final Uint8List ticketBytes =
    Uint8List.fromList(List<int>.generate(16, (i) => 0x40 + i));

final Qq8FileInfo info = Qq8FileInfo(
  name: fileName,
  size: fileSize,
  md5: fileMd5,
  sha1: fileSha1,
);

// ---------------------------------------------------------------------------

void testGolden() {
  section('一、请求体逐字节比对（独立 Python 实现生成）');

  final apply = Qq8File.buildApplyUploadBody(
    uin: uin,
    peerUin: peer,
    file: info,
  );
  eqHex(
    '1700 申请上传体',
    apply,
    '08a40d10069a01bb015080cdc8840da001a6daace407f001b960c2020ae6b58be8af952e62696e'
        '920310000102030405060708090a0b0c0d0e0f'
        'e20314000102030405060708090a0b0c0d0e0f10111213'
        'b204542f73746f726167652f656d756c617465642f302f416e64726f69642f646174612f636f6d'
        '2e74656e63656e742e6d6f62696c6571712f54656e63656e742f515166696c655f726563762f'
        'e6b58be8af952e62696e800500d00500a00600f20610000102030405060708090a0b0c0d0e0f'
        'a80603b00668c00c01',
  );

  final ext = Qq8File.buildHighwayExt(
    uin: uin,
    peerUin: peer,
    applyUploadResponse: apply,
    file: info,
    fid: fid,
    ticket: ticketBytes,
    subid: subid,
  );
  eqHex(
    'highway ext（100.100.700 原样回塞 1700 响应）',
    ext,
    '08641002'
        'a2068103a206e4010803a00680cdc8840dc00ca6daace407801900'
        'e22bcd0108a40d10069a01bb015080cdc8840da001a6daace407f001b960c2020ae6b58be8af95'
        '2e62696e920310000102030405060708090a0b0c0d0e0fe20314000102030405060708090a0b0c'
        '0d0e0f10111213b204542f73746f726167652f656d756c617465642f302f416e64726f69642f64'
        '6174612f636f6d2e74656e63656e742e6d6f62696c6571712f54656e63656e742f515166696c65'
        '5f726563762fe6b58be8af952e62696e800500d00500a00600f2061000010203040506070809'
        '0a0b0c0d0e0fa80603b00668c00c01'
        'c20c63a006b960c20c10000102030405060708090a0b0c0d0e0fe21214000102030405060708'
        '090a0b0c0d0e0f10111213821910000102030405060708090a0b0c0d0e0fc2250c6131623263'
        '33643465356636e22b10404142434445464748494a4b4c4d4e4f'
        'e21220a00602c20c09353337323938333533e012028219086439323631356335c0250482190d'
        'a2060ae6b58be8af952e62696ec00c01',
  );

  eqHex(
    '800 上传完成体',
    Qq8File.buildUploadSuccBody(uin: uin, peerUin: peer, fid: fid),
    '08a0061007521c5080cdc8840da001a6daace407f2010c613162326333643465356636a80603b00668',
  );
  eqHex(
    '400 撤回体',
    Qq8File.buildRecallBody(uin: uin, fid: fid),
    '089003100032140880cdc8840d120c613162326333643465356636a80603b00668c00c01',
  );
  eqHex(
    '700 转发体',
    Qq8File.buildForwardBody(uin: uin, peerUin: peer, fid: fid),
    '08bc0510004a1c5080cdc8840da001a6daace407f2010c613162326333643465356636a80603b00668c00c01',
  );
  eqHex(
    '1200 取下载链接体',
    Qq8File.buildApplyDownloadBody(uin: uin, fid: fid),
    '08b00972185080cdc8840da2010c613162326333643465356636f00102a80603b00668fae9300408d8c005',
  );

  final msg = Qq8FileMsg.buildC2cBody(
    uid: peer,
    seq: 100,
    rand: 0x11223344,
    fid: fid,
    md5: fileMd5,
    name: fileName,
    size: fileSize,
    syncCookieSeed: 0x55667788,
    nowSeconds: nowSeconds,
    syncR5: 11,
    syncR9: 22,
    syncR11: 33,
  );
  eqHex(
    '私聊文件消息体（路由 15 + msg_content）',
    msg,
    '0a0a7a0808a6daace407100412060801100018001a3712350a3308001a0c61316232633364346535'
        '66362210000102030405060708090a0b0c0d0e0f2a0ae6b58be8af952e62696e30b960480120'
        '6428c4e688890132290880f09dc7061080f09dc7061888ef99ab0520f790e6d40a280b48165821'
        '6088016880f09dc7067000',
  );
  final msgTicket = Qq8FileMsg.buildC2cBody(
    uid: peer,
    seq: 100,
    rand: 0x11223344,
    fid: fid,
    md5: fileMd5,
    name: fileName,
    size: fileSize,
    ticket: ticketBytes,
    syncCookieSeed: 0x55667788,
    nowSeconds: nowSeconds,
    syncR5: 11,
    syncR9: 22,
    syncR11: 33,
  );
  eqHex(
    '私聊文件消息体（转发形态，多 57:ticket）',
    msgTicket,
    '0a0a7a0808a6daace407100412060801100018001a4a12480a4608001a0c61316232633364346535'
        '66362210000102030405060708090a0b0c0d0e0f2a0ae6b58be8af952e62696e30b9604801ca'
        '0310404142434445464748494a4b4c4d4e4f206428c4e688890132290880f09dc7061080f09d'
        'c7061888ef99ab0520f790e6d40a280b481658216088016880f09dc7067000',
  );
}

void testParse() {
  section('二、回执解析（黄金样本由独立实现生成）');

  final up = Qq8File.parseApplyUpload(hex(
      '9a012a5000a20100d2050c613162326333643465356636f00600e20d10404142434445464748494a4b4c4d4e4f'));
  if (up.code == 0 && up.fid == fid && !up.alreadyExists && up.ticket.length == 16) {
    ok('1700 回执 → fid/ticket/已存在位', 'fid=${up.fid}');
  } else {
    bad('1700 回执解析', 'code=${up.code} fid=${up.fid} exists=${up.alreadyExists} '
        'ticket=${up.ticket.length}B');
  }

  final upExists = Qq8File.parseApplyUpload(Qq8Pb.encode(<int, Object?>{
    19: <int, Object?>{10: 0, 90: fid, 110: 1, 220: ticketBytes},
  }));
  if (upExists.alreadyExists && upExists.ok) {
    ok('1700 回执 → 服务端已有同 md5（110≠0）');
  } else {
    bad('1700 已存在位', 'exists=${upExists.alreadyExists}');
  }

  if (Qq8File.parseUploadSucc(hex('52020800')) &&
      Qq8File.parseRecall(hex('32020800'))) {
    ok('800 / 400 回执 → 成功码');
  } else {
    bad('800/400 回执', '解析结果不是成功');
  }

  final fwd = Qq8File.parseForward(
      hex('4a2150009203096e6577666964303031e20310404142434445464748494a4b4c4d4e4f'));
  if (fwd.ok && fwd.newFid == 'newfid001' && fwd.ticket.length == 16) {
    ok('700 回执 → 新 fid + ticket', fwd.newFid);
  } else {
    bad('700 回执', 'ok=${fwd.ok} newFid=${fwd.newFid} ticket=${fwd.ticket.length}');
  }

  final link = Qq8File.parseApplyDownload(hex(
      '725b5000f20123f201093132372e302e302e31c002903f9203102f66746e5f68616e646c65722f616263'
      'c2023018b960320c6131623263336434653566363a0ae6b58be8af952e62696ea20610000102030405'
      '060708090a0b0c0d0e0f'));
  if (link.url == 'http://127.0.0.1:8080/ftn_handler/abc' &&
      link.name == fileName &&
      link.size == fileSize &&
      link.md5Hex == toHex(fileMd5)) {
    ok('1200 回执 → 相对 url 拼成绝对直链', link.url);
  } else {
    bad('1200 回执', 'url=${link.url} name=${link.name} size=${link.size} md5=${link.md5Hex}');
  }

  // 失败码必须抛，而不是给出半截结果
  try {
    Qq8File.parseApplyDownload(Qq8Pb.encode(<int, Object?>{
      14: <int, Object?>{10: 7, 20: '文件不存在'},
    }));
    bad('1200 失败码', '应该抛 Qq8FileException，却正常返回');
  } on Qq8FileException catch (e) {
    if ('$e'.contains('7')) {
      ok('1200 失败码 → 抛异常并带码', '$e');
    } else {
      bad('1200 失败码文案', '$e');
    }
  }
}

void testHttpFrame() {
  section('三、highway HTTP 帧外层结构');

  final chunk = Uint8List.fromList(List<int>.generate(1000, (i) => i & 0xFF));
  final frame = Qq8File.buildHttpFrame(
    seq: 3,
    uin: '$uin',
    subid: subid,
    cmdId: Qq8File.cmdIdOfflineFile,
    ticket: ticketBytes,
    fileMd5: fileMd5,
    fileSize: 5000,
    offset: 1000,
    chunk: chunk,
    ext: Uint8List.fromList(<int>[0xDE, 0xAD]),
    nowMs: 1760000000123,
  );

  void check(String name, bool cond, String detail) {
    if (cond) {
      ok(name);
    } else {
      bad(name, detail);
    }
  }

  final headLen = (frame[1] << 24) | (frame[2] << 16) | (frame[3] << 8) | frame[4];
  final bodyLen = (frame[5] << 24) | (frame[6] << 16) | (frame[7] << 8) | frame[8];
  check('首字节 STX=40', frame[0] == 40, '实际 ${frame[0]}');
  check('末字节 ETX=41', frame.last == 41, '实际 ${frame.last}');
  check('总长 = 9 + 头长 + 块长 + 1',
      frame.length == 9 + headLen + bodyLen + 1,
      '${frame.length} vs ${9 + headLen + bodyLen + 1}');
  check('块长 = 数据长度', bodyLen == chunk.length, '$bodyLen vs ${chunk.length}');

  final head = Qq8Pb.decode(Uint8List.sublistView(frame, 9, 9 + headLen));
  final base = Qq8Pb.bytesAt(head, 1);
  final seg = Qq8Pb.bytesAt(head, 2);
  final baseM = base == null ? <int, List<Object>>{} : Qq8Pb.decode(base);
  final segM = seg == null ? <int, List<Object>>{} : Qq8Pb.decode(seg);
  check('头里 1=基础头 / 2=分段头 / 3=ext / 4=时间戳',
      base != null && seg != null && Qq8Pb.bytesAt(head, 3) != null &&
          (Qq8Pb.intAt(head, 4) ?? 0) == 1760000000123,
      'head keys=${head.keys.toList()}');
  check('基础头 command=PicUp.DataUp / 业务号=69',
      utf8.decode(Qq8Pb.bytesAt(baseM, 3) ?? <int>[]) == 'PicUp.DataUp' &&
          Qq8Pb.intAt(baseM, 8) == 69,
      'cmd=${Qq8Pb.bytesAt(baseM, 3)} id=${Qq8Pb.intAt(baseM, 8)}');
  check('分段头 3=偏移 / 4=长度 / 9=整文件 md5 / 6=ticket',
      Qq8Pb.intAt(segM, 3) == 1000 &&
          Qq8Pb.intAt(segM, 4) == 1000 &&
          toHex(Qq8Pb.bytesAt(segM, 9)!) == toHex(fileMd5) &&
          toHex(Qq8Pb.bytesAt(segM, 6)!) == toHex(ticketBytes),
      'offset=${Qq8Pb.intAt(segM, 3)} len=${Qq8Pb.intAt(segM, 4)}');
  // 每片的 md5 必须是**这一片**的，不是整文件的
  check('分段头 8=本片 md5（≠ 整文件 md5）',
      toHex(Qq8Pb.bytesAt(segM, 8)!) == toHex(md5Bytes(chunk)) &&
          toHex(Qq8Pb.bytesAt(segM, 8)!) != toHex(fileMd5),
      toHex(Qq8Pb.bytesAt(segM, 8) ?? <int>[]));
}

void testBigdataChannel() {
  section('五、bigdata 上传通道（地址来源）');

  eqHex(
    'HttpConn.0x6ff_501 请求体',
    Qq8File.buildBigdataChannelBody(uin: uin),
    '8a50100880cdc8840d10001810200130033805',
  );

  final rsp = hex('8a50210a10404142434445464748494a4b4c4d4e4f'
      '1a0d080a120910818080f80718903f');
  final ch = Qq8File.parseBigdataChannel(rsp);
  if (ch != null &&
      ch.host == '127.0.0.1' &&
      ch.port == 8080 &&
      toHex(ch.ticket) == toHex(ticketBytes)) {
    ok('通道响应 → ticket + ip:port', '${ch.host}:${ch.port}');
  } else {
    bad('通道响应解析', '$ch');
  }

  // 高位为 1 的 ip 在 Dart 里是负数（0xC0A80114 = -1062731756）
  final cases = <int, String>{
    0x7F000001: '127.0.0.1',
    0xC0A80114: '192.168.1.20',
    0x0A000001: '10.0.0.1',
    0: '0.0.0.0',
  };
  final wrong = <String>[];
  cases.forEach((k, v) {
    final got = Qq8File.u32ToIp(k);
    if (got != v) wrong.add('$k → $got（期望 $v）');
  });
  if (wrong.isEmpty) {
    ok('u32ToIp（含有符号负数）', '4 组');
  } else {
    bad('u32ToIp', wrong.join('；'));
  }

  // 解析不出通道时必须是 null（调用方据此抛"没有上传通道"），不能瞎猜
  if (Qq8File.parseBigdataChannel(hex('8a50020a00')) == null) {
    ok('没有 3 号字段时返回 null');
  } else {
    bad('没有 3 号字段', '应该返回 null');
  }
}

void testDigest() {
  section('四、摘要（filesha 是 SHA-1）');

  final abc = Uint8List.fromList(utf8.encode('abc'));
  if (toHex(md5Bytes(abc)) == '900150983cd24fb0d6963f7d28e17f72') {
    ok('md5("abc")');
  } else {
    bad('md5("abc")', toHex(md5Bytes(abc)));
  }
  if (toHex(sha1Bytes(abc)) == 'a9993e364706816aba3e25717850c26c9cd0d89d') {
    ok('sha1("abc")');
  } else {
    bad('sha1("abc")', toHex(sha1Bytes(abc)));
  }
  final i2 = Qq8FileInfo.of('', abc);
  if (i2.name == 'file${toHex(md5Bytes(abc))}' && i2.size == 3) {
    ok('Qq8FileInfo.of 留空文件名时用 md5 命名', i2.name);
  } else {
    bad('Qq8FileInfo.of 命名', '${i2.name} / ${i2.size}');
  }
}

void main() {
  stdout.writeln('离线文件（OfflineFilleHandleSvr）协议离线自测');
  stdout.writeln('=' * 66);
  stdout.writeln('黄金向量由 analysis/scripts/gen_file_vectors.py（独立 Python 实现）生成。');

  testGolden();
  testParse();
  testHttpFrame();
  testDigest();
  testBigdataChannel();

  stdout.writeln('\n${'=' * 66}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
