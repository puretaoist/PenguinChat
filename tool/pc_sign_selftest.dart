// PC 纯 Dart 签名（pc_sign.dart）离线自测：与 Node 跑 sign.js 的固定输入结果逐字节对比。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/kernel/wlogin8/pc/pc_sign.dart';

int _pass = 0, _fail = 0;
void ok(String n) { _pass++; stdout.writeln('  ✓ $n'); }
void bad(String n, String d) { _fail++; stdout.writeln('  ✗ $n\n      → $d'); }
void check(String n, bool c, [String d = '']) => c ? ok(n) : bad(n, d);
void checkEq(String n, Object? a, Object? b) =>
    ('$a' == '$b') ? ok(n) : bad(n, '期望 $b，实际 $a');

void main() {
  stdout.writeln('使用内嵌 blob（pc_sign_blobs.dart）');

  final body = Uint8List.fromList(List<int>.generate(20, (i) => i + 1));
  final rnd = Uint8List.fromList(List<int>.filled(16, 7));

  // Node 侧（sign.js computeSign53644）同输入结果
  const expectSign =
      '9edc6f7aaf7f560cdb0cec6f773cbda0acb0f2ac797eb2d4322f443d5e26cc44995a64c00ec1bfbb42546d7f97e8a29d';
  const expectExtra =
      '121b56315f4c4e585f4e515f332e322e33345f35333634345f47575f42';

  final sw = Stopwatch()..start();
  final r = PcSign.computeSign(body: body, us: 123456, rand16: rnd);
  sw.stop();
  stdout.writeln('耗时 ${sw.elapsedMilliseconds}ms');

  checkEq('extra 一致', r.extraHex, expectExtra);
  checkEq('sign 一致', r.signHex, expectSign);
  check('sign 长度 = 96 hex(48B)', r.signHex.length == 96, '${r.signHex.length}');

  final vf = File('tmp/sign_vectors.json');
  if (vf.existsSync()) {
    stdout.writeln('\n== 多组随机对照（Node vs Dart）==');
    final vecs = jsonDecode(vf.readAsStringSync()) as List;
    var allOk = true;
    for (var idx = 0; idx < vecs.length; idx++) {
      final v = vecs[idx] as Map;
      final bodyU = _hx(v['bodyHex'] as String);
      final randU = _hx(v['randHex'] as String);
      final rr = PcSign.computeSign(
          body: bodyU,
          us: (v['us'] as num).toInt(),
          rand16: randU);
      final ok = rr.signHex == v['sign'] && rr.extraHex == v['extra'];
      if (!ok) allOk = false;
      stdout.writeln('  向量$idx: ${ok ? "OK" : "MISMATCH"}');
    }
    check('${vecs.length} 组随机向量全一致', allOk);
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}

Uint8List _hx(String s) {
  final o = Uint8List(s.length ~/ 2);
  for (var i = 0; i < o.length; i++) {
    o[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return o;
}
