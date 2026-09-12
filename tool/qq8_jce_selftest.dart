/// JCE 编解码离线自测
///
/// 黄金向量由 `../analysis/scripts/gen_jce_vectors.cjs` 生成
/// （参考实现 js 时代 oicq 的 `lib/algo/jce`，可重跑）；规则已与官方 8.9.50
/// `com.qq.taf.jce.JceOutputStream` / `com.qq.taf.RequestPacket` 逐条对照
/// （见 `qq8_jce.dart` 头部表格）。
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/qq8_jce_selftest.dart
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/wlogin8/qq8_jce.dart';

import 'qq8_jce_diff_vectors.dart';

int _pass = 0;
int _fail = 0;

void ok(String name, [String? note]) {
  _pass++;
  stdout.writeln('  \u2713 $name${note == null ? '' : '   ($note)'}');
}

void bad(String name, String detail) {
  _fail++;
  stdout.writeln('  \u2717 $name\n      → $detail');
}

void section(String t) => stdout.writeln('\n$t');

void checkEq(String name, Object? actual, Object? expected) {
  final okv = '$actual' == '$expected';
  if (okv) {
    ok(name);
  } else {
    bad(name, '期望 $expected，实际 $actual');
  }
}

Uint8List hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String toHex(List<int> b) =>
    b.map((x) => (x & 0xff).toRadixString(16).padLeft(2, '0')).join();

// GENERATED-VECTORS-BEGIN（gen_jce_vectors.cjs 产出）
const String _goldenStruct =
    '0a1c200130ff4100c8520001117063000000012a05f200760568656c6c6f8700'
        '00012c7878787878787878787878787878787878787878787878787878787878'
        '7878787878787878787878787878787878787878787878787878787878787878'
        '7878787878787878787878787878787878787878787878787878787878787878'
        '7878787878787878787878787878787878787878787878787878787878787878'
        '7878787878787878787878787878787878787878787878787878787878787878'
        '7878787878787878787878787878787878787878787878787878787878787878'
        '7878787878787878787878787878787878787878787878787878787878787878'
        '7878787878787878787878787878787878787878787878787878787878787878'
        '7878787878787878787878787878787878787878787878787878787878787878'
        '7878787878787878787878787878789d000003010203a9000300010601610d00'
        '000109b8000206013016047a65726f0601311002d5400c0000000000000b';

const String _goldenWrapper =
    '10032c3c4c560b5075736853657276696365660e537663526571526567697374'
        '65727d00010196080001060e53766352657152656769737465721d0001017e0a'
        '1c200130ff4100c8520001117063000000012a05f200760568656c6c6f870000'
        '012c787878787878787878787878787878787878787878787878787878787878'
        '7878787878787878787878787878787878787878787878787878787878787878'
        '7878787878787878787878787878787878787878787878787878787878787878'
        '7878787878787878787878787878787878787878787878787878787878787878'
        '7878787878787878787878787878787878787878787878787878787878787878'
        '7878787878787878787878787878787878787878787878787878787878787878'
        '7878787878787878787878787878787878787878787878787878787878787878'
        '7878787878787878787878787878787878787878787878787878787878787878'
        '7878787878787878787878787878787878787878787878787878787878787878'
        '78787878787878787878787878789d000003010203a9000300010601610d0000'
        '0109b8000206013016047a65726f0601311002d5400c0000000000000b8c980c'
        'a80c';
// GENERATED-VECTORS-END

/// 夹具：与生成脚本里的 `fields` 逐字段一致。
Map<int, Object?> _fields() => <int, Object?>{
      1: 0, // ZERO
      2: 1, // INT8
      3: -1, // INT8 负
      4: 200, // INT16
      5: 70000, // INT32
      6: 5000000000, // INT64
      7: 'hello', // STRING1
      8: List<String>.filled(300, 'x').join(), // STRING4
      9: Uint8List.fromList(<int>[1, 2, 3]), // SIMPLE_LIST
      10: <Object?>[1, 'a', Uint8List.fromList(<int>[9])], // LIST
      11: <Object?, Object?>{'0': 'zero', '1': 2}, // MAP
      12: null, // 跳过
      13: 3.5, // DOUBLE
    };

void testEncodeStruct() {
  section('1. 结构体编码（对照黄金向量）');

  final bytes = Qq8Jce.encodeStruct(_fields());
  checkEq('长度 382', bytes.length, 382);
  checkEq('逐字节一致', toHex(bytes), _goldenStruct);
}

void testEncodeWrapper() {
  section('2. WUP 包装（RequestPacket 十字段）');

  final wrapper = Qq8Jce.encodeWrapper(
    service: 'PushService',
    method: 'SvcReqRegister',
    attributes: <String, Uint8List>{
      'SvcReqRegister': Qq8Jce.encodeStruct(_fields()),
    },
  );
  checkEq('长度 450', wrapper.length, 450);
  checkEq('逐字节一致', toHex(wrapper), _goldenWrapper);
}

void testDecode() {
  section('3. 解码 + 往返');

  final decoded = Qq8Jce.decode(hex(_goldenStruct))[0] as Map<int, Object?>;
  checkEq('字段 1（ZERO）', decoded[1], 0);
  checkEq('字段 2（INT8）', decoded[2], 1);
  checkEq('字段 3（INT8 负）', decoded[3], -1);
  checkEq('字段 4（INT16）', decoded[4], 200);
  checkEq('字段 5（INT32）', decoded[5], 70000);
  checkEq('字段 6（INT64）', decoded[6], 5000000000);
  checkEq('字段 7（STRING1）', decoded[7], 'hello');
  checkEq('字段 8（STRING4）长度', (decoded[8] as String).length, 300);
  checkEq('字段 9（SIMPLE_LIST）', toHex(decoded[9] as Uint8List), '010203');
  final list = decoded[10] as List;
  checkEq('字段 10（LIST）',
      '${list[0]},${list[1]},${toHex(list[2] as Uint8List)}', '1,a,09');
  final map = decoded[11] as Map;
  checkEq('字段 11（MAP）', "${map['0']},${map['1']}", "zero,2");
  checkEq('字段 12（null 跳过）不在结果里', decoded.containsKey(12), false);
  checkEq('字段 13（DOUBLE）', decoded[13], 3.5);

  checkEq('解码结果再编码逐字节还原', toHex(Qq8Jce.encodeStruct(decoded)),
      _goldenStruct);

  final fromWrapper = Qq8Jce.decodeWrapper(hex(_goldenWrapper));
  checkEq('decodeWrapper 取到字段 7', fromWrapper[7], 'hello');
  checkEq('decodeWrapper 取到字段 13', fromWrapper[13], 3.5);
}

// ---------------------------------------------------------------------------
// 4. 差分用例（参考实现生成，覆盖边界与组合）
// ---------------------------------------------------------------------------

void testDiffVectors() {
  section('4. 差分用例（${kQq8JceDiffVectors.length} 条，逐条比对）');

  for (final v in kQq8JceDiffVectors) {
    final bytes = Qq8Jce.encodeStruct(v.fields);
    if (toHex(bytes) != v.hex) {
      bad('编码 ${v.name}', '期望 ${v.hex}\n        实际 ${toHex(bytes)}');
      continue;
    }
    ok('编码 ${v.name}', '${bytes.length} 字节');

    final decoded = Qq8Jce.decode(bytes)[0] as Map<int, Object?>;
    if (toHex(Qq8Jce.encodeStruct(decoded)) != v.hex) {
      bad('往返 ${v.name}', '解码后再编码不一致');
    } else {
      ok('往返 ${v.name}');
    }
  }
}

void main() {
  stdout.writeln('JCE 编解码离线自测');
  stdout.writeln('=' * 62);
  stdout.writeln('黄金向量来自 oicq js 时代 lib/algo/jce（可重跑）；');
  stdout.writeln('规则与官方 JceOutputStream / RequestPacket 逐条对照过。');

  testEncodeStruct();
  testEncodeWrapper();
  testDecode();
  testDiffVectors();

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
