// PC SSO Protocol 13（Simple）离线自测。
//
// Protocol 13 目前只用于长连接心跳 `Heartbeat.Alive`（RequestType.Simple）。
// 验证：外层结构（protocol=13/encryptType/sequence/uin）、sso 内层
// （command ‖ i32(4) ‖ ssoReserved）、payload 还原、parseResponse 可解。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/infra/coder.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_proto.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_sso.dart';

int _pass = 0;
int _fail = 0;
void ok(String n) { _pass++; stdout.writeln('  ✓ $n'); }
void bad(String n, String d) { _fail++; stdout.writeln('  ✗ $n\n      → $d'); }
void check(String n, bool c, [String d = '']) => c ? ok(n) : bad(n, d);
void checkEq(String n, Object? a, Object? b) =>
    ('$a' == '$b') ? ok(n) : bad(n, '期望 $b，实际 $a');
void section(String t) => stdout.writeln('\n$t');

Uint8List _withLen(List<int> d) =>
    (ByteWriter()..u32(d.length + 4)..raw(d)).build();
Uint8List _readWithLen(ByteReader r) => r.read(r.readUint32() - 4);

void main() {
  const command = 'Heartbeat.Alive';
  final payload = Uint8List.fromList([0, 0, 0, 4]);

  section('1. buildRequest13：外层结构');
  final pkt = PcSso.buildRequest13(
    uin: 10001,
    sequence: 0x22222,
    command: command,
    payload: payload,
  );
  {
    final outerLen = ByteReader(pkt).readUint32();
    checkEq('外层长度 = 包长（含自身）', outerLen, pkt.length);

    final r = ByteReader(pkt);
    r.readUint32();
    checkEq('protocol = 13', r.readUint32(), 13);
    checkEq('encryptType = 0（None，Alive 默认）', r.readUint8(), 0);
    checkEq('sequence = 0x22222', r.readUint32(), 0x22222);
    checkEq('保留字节 = 0', r.readUint8(), 0);
    checkEq('uin = 10001', utf8.decode(_readWithLen(r)), '10001');
    final enc = r.readRest();

    section('2. sso 内层（encryptType=None → 明文）');
    final s = ByteReader(enc);
    final innerLen = s.readUint32();
    final inner = s.read(innerLen - 4);
    checkEq('payload 还原', utf8.decode(_readWithLen(s)), String.fromCharCodes(payload));

    final si = ByteReader(inner);
    checkEq('command', utf8.decode(_readWithLen(si)), command);
    checkEq('i32(4) 占位', si.readUint32(), 4);
    final reserved = _readWithLen(si);
    check('ssoReserved 非空', reserved.isNotEmpty, '${reserved.length}B');

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
    check('trace 55 字符', trace != null && trace.length == 55, '$trace');
    checkEq('msgType = 32', msgType, 32);
  }

  section('3. parseResponse 能解 protocol13 响应');
  {
    // 构造一个 protocol 13 响应（外层同 12：protocol/authFlag/dummy/uin/密文）
    final body = ByteWriter()
      ..u32(0) // headLen
      ..u32(0x22222) // sequence
      ..u32(0) // retCode
      ..raw(_withLen(Uint8List(0))) // extra
      ..raw(_withLen(utf8.encode(command))) // command
      ..raw(_withLen(Uint8List(0))) // cookie
      ..u32(0) // isCompressed
      ..raw((ByteWriter()..u32(0)).build()) // reserved（裸长度）
      ..raw(_withLen(utf8.encode('ok'))); // payload
    final outer = ByteWriter()
      ..u32(13)
      ..u8(0) // authFlag None
      ..u8(0)
      ..raw(_withLen(utf8.encode('10001')))
      ..raw(body.build());
    final parsed = PcSso.parseResponse(outer.build());
    checkEq('retCode=0', parsed.retCode, 0);
    checkEq('command', parsed.command, command);
    checkEq('payload', utf8.decode(parsed.payload), 'ok');
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
