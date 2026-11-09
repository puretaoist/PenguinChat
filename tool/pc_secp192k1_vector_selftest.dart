// 自动生成：secp192k1 标准对照（由 Python 写入，不要手抄）。
import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/kernel/wlogin8/pc/pc_qr_tlv.dart';

int _pass = 0;
int _fail = 0;
void ok(String n) { _pass++; stdout.writeln('  ok  ' + n); }
void bad(String n, String d) { _fail++; stdout.writeln('  BAD ' + n + '  -> ' + d); }
void check(String n, bool c, [String d = '']) => c ? ok(n) : bad(n, d);

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) { if (a[i] != b[i]) return false; }
  return true;
}

void main() {
  final secret = _hex('0102030405060708090a0b0c0d0e0f101112131415161718');
  final r = PcSecp192k1.debugExchangeWithSecret(secret);
  final expPub = _hex('024f66169b52c55aaef02abf5d5ab1be9228fb139fe7449b2f');
  final expShare = _hex('381fd75ada8fd0e98546e164d9b32230');
  check('压缩公钥与标准一致 (25B)', _eq(r.publicKeyCompressed, expPub));
  check('shareKey 与标准一致 (16B)', _eq(r.shareKey, expShare));
  stdout.writeln('通过 ' + _pass.toString() + ' 项，失败 ' + _fail.toString() + ' 项');
  exit(_fail == 0 ? 0 : 1);
}
