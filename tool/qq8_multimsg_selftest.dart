/// 合并转发（MultiMsg）协议离线自测
///
/// **不需要网络、不需要账号**。二进制黄金向量由**独立第二实现**
/// `analysis/scripts/gen_multimsg_vectors.py`（Python 手写 protobuf，不引用 oicq、
/// 不引用 Dart）生成，本文件把 Dart 侧编码结果与它逐字节比对。
///
/// 覆盖：
/// * 节点（群 82 / 私聊 166，含 4/9/14/20 号字段与 `rand2uuid` 的 uint64）；
/// * 转发内容（`{1: nodes, 2: {1: "MultiMsg", 2: {1: nodes}}}`）；
/// * `MultiMsg.ApplyUp` 请求体与应答解析（resid / 上传 key / ip:port / ticket）；
/// * highway 请求体（压缩内容 + 5=2 + 6=上传 key）；
/// * gzip 往返（官方是 gzip 不是裸 deflate）；
/// * "聊天记录"XML 卡片与 Elem 12 的编码（0x01 标志 + 裸 deflate + serviceID=35）；
/// * `u32ToIp` 的高位为 1 情形。
///
/// 运行：
/// ```bash
/// dart run tool/qq8_multimsg_selftest.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/crypto/digest.dart';
import 'package:qqclient/kernel/wlogin8/qq8_multimsg.dart';
import 'package:qqclient/kernel/wlogin8/qq8_msg.dart';
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

void eqStr(String name, String actual, String expected) {
  if (actual == expected) {
    ok(name, '${actual.length} 字符');
  } else {
    bad(name, '实际 $actual\n        期望 $expected');
  }
}

// ---------------------------------------------------------------------------
// 与 Python 生成脚本完全一致的输入
// ---------------------------------------------------------------------------

const int sender = 3499239040;
const int targetGid = 763829581;
const int targetUin = 2089495846;
const int time0 = 1760000000;
const int seq0 = 100;
const int rand0 = 0x11223344;
const String apkVersion = '4.1.0.4050';
const String resid = 'RESID1234567890';

final Uint8List compressed =
    Uint8List.fromList(<int>[0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0x03, ...utf8.encode('FAKE')]);

/// 与 Python 的 `rich()` 一致：`{2: [{1: {1: "..."}}]}`（不带 pbReserver）。
Uint8List rich(String text) =>
    Qq8Pb.encode(<int, Object?>{
      2: <Object?>[Qq8Msg.textElem(text)],
    });

// ---------------------------------------------------------------------------

void testNode() {
  section('一、节点（MultiMsg.Msg）');
  final ng = Qq8MultiMsg.buildNode(
    senderUin: sender,
    target: targetGid,
    dm: false,
    seq: seq0,
    time: time0,
    rand: rand0,
    rich: rich('你好'),
    nickname: '小明',
  );
  eqHex(
    '群节点（82，带 9: {1: 群号, 4: 群名片}）',
    ng,
    '0a3b0880cdc8840d10cdba9cec02185228643080f09dc70638c4e6888981808080014a0e08cdba9cec022206e5b08fe6988ea20108080010c4e68889011a0e0a0c120a0a080a06e4bda0e5a5bd',
  );

  final nd = Qq8MultiMsg.buildNode(
    senderUin: sender,
    target: targetUin,
    dm: true,
    seq: seq0 + 1,
    time: time0 + 1,
    rand: rand0 + 1,
    rich: rich('hi'),
    nickname: '小明',
  );
  eqHex(
    '私聊节点（166，带 4:11 / 14: 昵称）',
    nd,
    '0a360880cdc8840d10a6daace40718a601200b28653081f09dc70638c5e6888981808080017206e5b08fe6988ea20108080010c5e68889011a0a0a0812060a040a026869',
  );

  if (Qq8MultiMsg.rand2uuid(0x11223344) == ((0x1000000 << 32) | 0x11223344)) {
    ok('rand2uuid 高 32 位是 0x1000000', '${Qq8MultiMsg.rand2uuid(1)}');
  } else {
    bad('rand2uuid', '${Qq8MultiMsg.rand2uuid(0x11223344)}');
  }
}

void testContent() {
  section('二、转发内容（未压缩）');
  final ng = Qq8MultiMsg.buildNode(
    senderUin: sender,
    target: targetGid,
    dm: false,
    seq: seq0,
    time: time0,
    rand: rand0,
    rich: rich('你好'),
    nickname: '小明',
  );
  final nd = Qq8MultiMsg.buildNode(
    senderUin: sender,
    target: targetUin,
    dm: true,
    seq: seq0 + 1,
    time: time0 + 1,
    rand: rand0 + 1,
    rich: rich('hi'),
    nickname: '小明',
  );
  final ct = Qq8MultiMsg.buildContent(<Uint8List>[ng, nd]);
  eqHex(
    'content（1: nodes 重复 + 2: {1: "MultiMsg", 2: {1: nodes}}）',
    ct,
    '0a4d0a3b0880cdc8840d10cdba9cec02185228643080f09dc70638c4e6888981808080014a0e08cdba9cec022206e5b08fe6988ea20108080010c4e68889011a0e0a0c120a0a080a06e4bda0e5a5bd0a440a360880cdc8840d10a6daace40718a601200b28653081f09dc70638c5e6888981808080017206e5b08fe6988ea20108080010c5e68889011a0a0a0812060a040a02686912a2010a084d756c74694d73671295010a4d0a3b0880cdc8840d10cdba9cec02185228643080f09dc70638c4e6888981808080014a0e08cdba9cec022206e5b08fe6988ea20108080010c4e68889011a0e0a0c120a0a080a06e4bda0e5a5bd0a440a360880cdc8840d10a6daace40718a601200b28653081f09dc70638c5e6888981808080017206e5b08fe6988ea20108080010c5e68889011a0a0a0812060a040a026869',
  );

  final gz = Qq8MultiMsg.gzipContent(ct);
  final back = Uint8List.fromList(gzip.decode(gz));
  if (back.length == ct.length && toHex(back) == toHex(ct)) {
    ok('gzip 往返一致', '${gz.length} B 压缩');
  } else {
    bad('gzip 往返', '解出 ${back.length} B，原文 ${ct.length} B');
  }
}

void testApplyUp() {
  section('三、MultiMsg.ApplyUp 请求与应答');
  final body = Qq8MultiMsg.buildApplyUpBody(
    target: targetGid,
    size: compressed.length,
    md5: md5Bytes(compressed),
    apkVersion: apkVersion,
  );
  eqHex(
    'ApplyUp 请求体（5=版本 6=条目 8=1）',
    body,
    '08011005180920032a0a342e312e302e34303530321e08cdba9cec02100e1a10a0d3947acf922f0cef336bd77b0ca7c5200328004001',
  );

  final rspBytes = hex(
    '122c0800120f5245534944313233343536373839301a0401020304209482a0850c28903f52084041424344454647',
  );
  final t = Qq8MultiMsg.parseApplyUp(rspBytes);
  if (t == null) {
    bad('解析 ApplyUp 应答', '返回 null');
  } else if (!t.ok) {
    bad('解析 ApplyUp 应答', 'ok=false code=${t.code}');
  } else {
    final details = <String>[
      if (t.resid != resid) 'resid=${t.resid}',
      if (t.host != '192.168.1.20') 'host=${t.host}',
      if (t.port != 8080) 'port=${t.port}',
      if (toHex(t.uploadKey) != '01020304') 'key=${toHex(t.uploadKey)}',
      if (toHex(t.ticket) != '4041424344454647') 'ticket=${toHex(t.ticket)}',
    ];
    if (details.isEmpty) {
      ok('解析 ApplyUp 应答（resid/ip:port/key/ticket）', '${t.host}:${t.port}');
    } else {
      bad('解析 ApplyUp 应答', details.join(' / '));
    }
  }

  final ub = Qq8MultiMsg.buildUploadBody(
    target: targetGid,
    compressed: compressed,
    uploadKey: hex('01020304'),
  );
  eqHex(
    'highway 请求体（4: {2: 目标, 4: 压缩内容, 5: 2, 6: key}）',
    ub,
    '080110051809221e10cdba9cec02220e1f8b080000000000000346414b452802320401020304',
  );

  final empty = Qq8MultiMsg.parseApplyUp(Qq8Pb.encode(<int, Object?>{1: 1}));
  if (empty == null) {
    ok('解析 ApplyUp 应答：没有 2 号字段时返回 null', '不瞎猜');
  } else {
    bad('解析 ApplyUp 应答：没有 2 号字段时返回 null', '实际 $empty');
  }
}

void testXml() {
  section('四、"聊天记录"XML 卡片与 Elem 12');
  final xml = Qq8MultiMsg.buildXmlCard(
    resid: resid,
    total: 2,
    fileSize: compressed.length,
    previews: <String>['小明: 你好', '小明: hi'],
  );
  const expected = '<?xml version="1.0" encoding="utf-8"?>\n'
      '<msg brief="[聊天记录]" m_fileName="MULTIMSG" action="viewMultiMsg" tSum="2" '
      'flag="3" m_resid="RESID1234567890" serviceID="35" m_fileSize="14">'
      '<item layout="1"><title color="#000000" size="34">转发的聊天记录</title>'
      '<title color="#777777" size="26">小明: 你好</title>'
      '<title color="#777777" size="26">小明: hi</title>'
      '<hr></hr><summary color="#808080" size="26">查看2条转发消息</summary></item>'
      '<source name="聊天记录"></source></msg>';
  eqStr('卡片模板', xml, expected);

  final elem = Qq8MultiMsg.buildXmlElem(xml);
  final top = Qq8Pb.decode(elem);
  final inner = Qq8Pb.bytesAt(top, 12);
  if (inner == null) {
    bad('Elem 12 外层', '没有 12 号字段');
    return;
  }
  final m = Qq8Pb.decode(inner);
  final data = Qq8Pb.bytesAt(m, 1);
  final sid = Qq8Pb.intAt(m, 2);
  if (data == null || sid != 35) {
    bad('Elem 12 内层', 'data=null? ${data == null} serviceID=$sid');
    return;
  }
  if (data[0] != 0x01) {
    bad('Elem 12 首字节（0x01 压缩标志）', '${data[0]}');
    return;
  }
  final plain = Uint8List.fromList(
      ZLibDecoder(raw: true).convert(Uint8List.sublistView(data, 1)));
  if (utf8.decode(plain) != xml) {
    bad('Elem 12 裸 deflate 还原', '长度 ${plain.length}');
    return;
  }
  ok('Elem 12（0x01 + 裸 deflate + serviceID=35）', '${elem.length} B');

  final escaped = Qq8MultiMsg.buildXmlCard(
    resid: 'R&D',
    total: 1,
    fileSize: 1,
    previews: <String>['a<b>'],
  );
  if (escaped.contains('m_resid="R&amp;D"') && escaped.contains('a&lt;b&gt;')) {
    ok('XML 转义（& < > "）');
  } else {
    bad('XML 转义', escaped);
  }
}

void testU32ToIp() {
  section('五、u32ToIp');
  final cases = <int, String>{
    0xC0A80114: '192.168.1.20',
    0x7F000001: '127.0.0.1',
    0: '0.0.0.0',
    -1: '255.255.255.255',
  };
  for (final e in cases.entries) {
    final got = Qq8MultiMsg.u32ToIp(e.key);
    if (got == e.value) {
      ok('u32ToIp(${e.key})', got);
    } else {
      bad('u32ToIp(${e.key})', '实际 $got 期望 ${e.value}');
    }
  }
}

void main() {
  stdout.writeln('合并转发（MultiMsg）协议离线自测');
  stdout.writeln('=' * 66);
  stdout.writeln('黄金向量由 analysis/scripts/gen_multimsg_vectors.py（独立 Python 实现）生成。');

  testNode();
  testContent();
  testApplyUp();
  testXml();
  testU32ToIp();

  stdout.writeln('\n${'=' * 66}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
