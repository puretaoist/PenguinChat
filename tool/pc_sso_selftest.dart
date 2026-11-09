// PC SSO（Protocol 12）离线自测。
//
// 验证三件能离线证明的事：
//   1. buildRequest12 的外层结构（protocol/encryptType/uin）正确，TEA 块能解回 sso
//   2. sso 内层字段（sequence/subAppId/command/guid/version/payload）逐项正确
//   3. parseResponse 能正确解析响应（普通 + gzip 压缩 payload）
//
// 不能离线证明：服务端是否接受（需真机）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/infra/coder.dart';
import 'package:penguinchat/kernel/crypto/tea.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_proto.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_sso.dart';

int _pass = 0;
int _fail = 0;

void ok(String n) {
  _pass++;
  stdout.writeln('  ✓ $n');
}

void bad(String n, String d) {
  _fail++;
  stdout.writeln('  ✗ $n\n      → $d');
}

void check(String n, bool c, [String d = '']) => c ? ok(n) : bad(n, d);

void checkEq(String n, Object? a, Object? b) =>
    ('$a' == '$b') ? ok(n) : bad(n, '期望 $b，实际 $a');

void section(String t) => stdout.writeln('\n$t');

Uint8List _withLen(List<int> d) =>
    (ByteWriter()..u32(d.length + 4)..raw(d)).build();

Uint8List _bareLen(List<int> d) =>
    (ByteWriter()..u32(d.length)..raw(d)).build();

Uint8List _readWithLen(ByteReader r) => r.read(r.readUint32() - 4);

void main() {
  final guid = Uint8List.fromList(List<int>.generate(16, (i) => 0x11 + i));
  const command = 'trpc.login.ecdh.EcdhService.SsoKeyExchange';

  section('1. buildRequest12：外层结构');
  {
    final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
    final pkt = PcSso.buildRequest12(
      uin: 10001,
      sequence: 0x12345,
      subAppId: 537064117,
      currentVersion: '9.9.9-39038',
      command: command,
      payload: payload,
      guid: guid,
    );

    final outerLen = ByteReader(pkt).readUint32();
    // 长度含自身：长度字段值 == 整个包长
    checkEq('外层长度字段 = 包长（含自身）', outerLen, pkt.length);

    final r = ByteReader(pkt);
    r.readUint32(); // 外层长度
    checkEq('protocol = 12', r.readUint32(), 12);
    checkEq('encryptType = 2（WithEmptyKey）', r.readUint8(), 2);
    final d2 = _readWithLen(r);
    checkEq('d2 为空', d2.length, 0);
    checkEq('保留字节 = 0', r.readUint8(), 0);
    final uin = utf8.decode(_readWithLen(r));
    checkEq('uin = 10001', uin, '10001');
    final teaBlock = r.readRest();

    // 解密 TEA 块
    final sso = qqTeaDecrypt(teaBlock, Uint8List(16));
    final s = ByteReader(sso);
    final innerLen = s.readUint32();
    check('sso 内层长度字段合理', innerLen > 4 && innerLen <= sso.length);

    section('2. sso 内层字段');
    checkEq('sequence', s.readUint32(), 0x12345);
    checkEq('subAppId', s.readUint32(), 537064117);
    checkEq('locale = 2052', s.readUint32(), 2052);
    final fixed = s.read(12);
    check('固定12字节首字节=0x02', fixed[0] == 0x02,
        fixed[0].toRadixString(16));
    checkEq('a2 为空', _readWithLen(s).length, 0);
    checkEq('command', utf8.decode(_readWithLen(s)), command);
    checkEq('unknown 为空', _readWithLen(s).length, 0);
    final guidHex = utf8.decode(_readWithLen(s));
    check('guid 是 32 位大写 hex', guidHex.length == 32 && guidHex == guidHex.toUpperCase(),
        guidHex);
    checkEq('unknown2 为空', _readWithLen(s).length, 0);
    final verLen = s.readUint16();
    final ver = utf8.decode(s.read(verLen - 2));
    checkEq('version', ver, '9.9.9-39038');
    final reserved = _readWithLen(s);
    check('ssoReserved 非空（自动生成 trace）', reserved.isNotEmpty,
        '${reserved.length}B');
    // 解析 reserved：字段 15 = trace（55 字符）
    final rp = PbReader(reserved);
    String? trace;
    int? msgType;
    while (!rp.atEnd) {
      final (f, w) = rp.readTag();
      if (f == 15) {
        trace = rp.readString();
      } else if (f == 21) {
        msgType = rp.readVarint();
      } else {
        rp.skip(w);
      }
    }
    check('trace 是 55 字符', trace != null && trace.length == 55, '$trace');
    checkEq('msgType = 32', msgType, 32);
    // 内层结束后是 withLength(payload)
    check('payload 还原', _bytesEq(_readWithLen(s), payload));
  }

  section('3. parseResponse：普通响应');
  {
    const payload = 'hello-response';
    final resp = _buildResponse(
      seq: 0x12345,
      retCode: 0,
      command: command,
      payload: utf8.encode(payload),
      compressed: false,
    );
    final parsed = PcSso.parseResponse(resp);
    checkEq('retCode = 0', parsed.retCode, 0);
    checkEq('sequence', parsed.sequence, 0x12345);
    checkEq('command', parsed.command, command);
    checkEq('payload', utf8.decode(parsed.payload), payload);
    check('ok = true', parsed.ok);
  }

  section('4. parseResponse：gzip 压缩 payload');
  {
    const payload = 'compressed-payload-内容';
    final resp = _buildResponse(
      seq: 7,
      retCode: 0,
      command: command,
      payload: utf8.encode(payload),
      compressed: true,
    );
    final parsed = PcSso.parseResponse(resp);
    checkEq('gzip 解压后 payload 正确', utf8.decode(parsed.payload), payload);
  }

  section('5. parseResponse：非零 retCode 带 extra');
  {
    final resp = _buildResponse(
      seq: 9,
      retCode: -10003,
      command: command,
      payload: Uint8List(0),
      extra: '登录已失效',
      compressed: false,
    );
    final parsed = PcSso.parseResponse(resp);
    checkEq('retCode = -10003', parsed.retCode, -10003);
    checkEq('extra', parsed.extra, '登录已失效');
    check('ok = false', !parsed.ok);
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}

bool _bytesEq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 构造一个 Protocol 12 响应包（WithEmptyKey 加密）。
Uint8List _buildResponse({
  required int seq,
  required int retCode,
  required String command,
  required Uint8List payload,
  String extra = '',
  required bool compressed,
}) {
  final body = ByteWriter()
    ..u32(0) // headLen
    ..u32(seq)
    ..u32(retCode & 0xFFFFFFFF) // retCode（负数按补码）
    ..raw(_withLen(utf8.encode(extra)))
    ..raw(_withLen(utf8.encode(command)))
    ..raw(_withLen(Uint8List(0))) // messageCookie
    ..u32(compressed ? 1 : 0)
    ..raw(_bareLen(Uint8List(0))) // reserved（裸长度）
    ..raw(_withLen(compressed ? Uint8List.fromList(gzip.encode(payload)) : payload));
  final plain = body.build();
  final enc = qqTeaEncrypt(plain, Uint8List(16));

  final outer = ByteWriter()
    ..u32(12) // protocol
    ..u8(2) // authFlag = WithEmptyKey
    ..u8(0) // dummy
    ..raw(_withLen(utf8.encode('10001'))) // uin
    ..raw(enc);
  return outer.build();
}
