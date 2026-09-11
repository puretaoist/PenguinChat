/// QQ 8.2.11 协议内核离线自测
///
/// **不需要网络、不需要 QQ 账号**：用 Node `createECDH`（与 oicq 同一个 API）
/// 生成的黄金向量做交叉验证，确保 Dart 实现与参考实现在字节级一致。
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/qq8_selftest.dart
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/crypto/ecdh.dart';
import 'package:qqclient/kernel/wlogin8/qq8_config.dart';

// ---------------------------------------------------------------------------

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  \u2713 $name');
  } else {
    _failed++;
    stdout.writeln('  \u2717 $name${detail == null ? '' : '  → $detail'}');
  }
}

void checkEq(String name, Object? actual, Object? expected) {
  final ok = '$actual' == '$expected';
  check(name, ok, ok ? null : '期望 $expected，实际 $actual');
}

void section(String t) => stdout.writeln('\n$t');

Uint8List hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String toHex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

// ---------------------------------------------------------------------------
// 黄金向量：由 Node createECDH + createHash('md5') 生成
// （生成脚本见工作区 gen_ecdh_vectors.cjs）
// ---------------------------------------------------------------------------

const _goldenPrivHex =
    '2b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfe';
const _goldenPubHex =
    '04e48813e656219b4090c282a020f40e07b4e1efd60a3dd17492a1667c5758ee'
    '5b760f9b9b1c840b4f4f63ab4043c0537ca29b3512c32e50e56f5e4e8d42d0d31e';
const _goldenSecretHex =
    'cea22fb1c18e252f61878aa9d7ef319f90ead0b8b422a00d28564f8f402aa157';
const _goldenShareKeyHex = 'f3df7dfb6d55b17975d908d8228dee11';

// ---------------------------------------------------------------------------
// 1. 配置表自洽
// ---------------------------------------------------------------------------

void testConfig() {
  section('1. QQ 8.2.11 参数表自洽');

  checkEq('版本名', Qq8Config.versionName, '8.2.11');
  checkEq('完整版本号', Qq8Config.appVersion, '8.2.11.4530');
  checkEq('versionCode', Qq8Config.versionCode, 1380);
  checkEq('qua', Qq8Config.qua, 'V1_AND_SQ_8.2.11_1380_GM_D');
  checkEq('包名', Qq8Config.packageName, 'com.tencent.mobileqq');

  check('qua 中嵌有 versionCode',
      Qq8Config.qua.contains('_${Qq8Config.versionCode}_'));
  check('qua 标识 Play 渠道（GM）', Qq8Config.qua.endsWith('_GM_D'));
  check('fullVersion 以渠道结尾',
      Qq8Config.fullVersion.endsWith('.${Qq8Config.channel}'));
  check('fullVersion 以 appVersion 开头',
      Qq8Config.fullVersion.startsWith(Qq8Config.appVersion));

  // sign 的两种表示必须一致
  checkEq('appSignBytes 与 appSignHex 一致',
      toHex(Uint8List.fromList(Qq8Config.appSignBytes)), Qq8Config.appSignHex);
  checkEq('appSign 为 16 字节', Qq8Config.appSignBytes.length, 16);

  // subSigMap 与参考实现硬编码的 0x10400 必须相等
  checkEq('subSigMap == 0x10400（oicq 硬编码值）', Qq8Config.subSigMap, 0x10400);

  // 服务端公钥必须是合法的未压缩点
  checkEq('服务端公钥 65 字节', Qq8Config.serverEcdhPublicKey.length, 65);
  checkEq('服务端公钥首字节 0x04', Qq8Config.serverEcdhPublicKey[0], 0x04);

  check('describe() 可用', Qq8Config.describe().contains('8.2.11'));
}

// ---------------------------------------------------------------------------
// 2. ECDH 与参考实现逐字节一致
// ---------------------------------------------------------------------------

void testEcdhGolden() {
  section('2. ECDH 黄金向量（对照 Node createECDH）');

  final result = Ecdh.exchange(
    Uint8List.fromList(Qq8Config.serverEcdhPublicKey),
    privateKey: hex(_goldenPrivHex),
  );

  checkEq('公钥与参考实现一致（65 字节未压缩点）',
      toHex(result.publicKey), _goldenPubHex);
  checkEq('公钥长度', result.publicKey.length, 65);

  checkEq('共享密钥为 16 字节', result.shareKey.length, 16);
  checkEq('share_key = MD5(ECDH(...)[0..16)) 与参考一致',
      toHex(result.shareKey), _goldenShareKeyHex);

  // 把种子单独验一遍，确认是「截断再 MD5」而不是「MD5 再截断」
  checkEq('MD5("") 标准向量', toHex(md5Bytes(Uint8List(0))),
      'd41d8cd98f00b204e9800998ecf8427e');
  checkEq('MD5("abc") 标准向量',
      toHex(md5Bytes(Uint8List.fromList('abc'.codeUnits))),
      '900150983cd24fb0d6963f7d28e17f72');

  final seed = hex(_goldenSecretHex.substring(0, 32));
  checkEq('对共享秘密前 16 字节取 MD5', toHex(md5Bytes(seed)),
      _goldenShareKeyHex);
}

// ---------------------------------------------------------------------------
// 3. ECDH 自洽性
// ---------------------------------------------------------------------------

void testEcdhProperties() {
  section('3. ECDH 自洽性');

  // 两次用同一个私钥，结果必须完全可复现
  final a = Ecdh.exchange(
      Uint8List.fromList(Qq8Config.serverEcdhPublicKey),
      privateKey: hex(_goldenPrivHex));
  final b = Ecdh.exchange(
      Uint8List.fromList(Qq8Config.serverEcdhPublicKey),
      privateKey: hex(_goldenPrivHex));
  check('相同私钥结果可复现', toHex(a.shareKey) == toHex(b.shareKey));

  // 随机生成：公钥格式正确、共享密钥长度正确、两次不同
  final r1 = Ecdh.exchange(Uint8List.fromList(Qq8Config.serverEcdhPublicKey));
  final r2 = Ecdh.exchange(Uint8List.fromList(Qq8Config.serverEcdhPublicKey));
  checkEq('随机公钥 65 字节', r1.publicKey.length, 65);
  checkEq('随机公钥首字节 0x04', r1.publicKey[0], 0x04);
  checkEq('随机共享密钥 16 字节', r1.shareKey.length, 16);
  check('两次随机结果不同', toHex(r1.shareKey) != toHex(r2.shareKey));

  // 非法输入必须显式报错，而不是静默算出错的结果
  var threw = false;
  try {
    Ecdh.exchange(Uint8List(64));
  } on ArgumentError {
    threw = true;
  }
  check('长度错误的服务端公钥抛 ArgumentError', threw);

  threw = false;
  try {
    Ecdh.exchange(Uint8List.fromList(Qq8Config.serverEcdhPublicKey),
        privateKey: Uint8List(31));
  } on ArgumentError {
    threw = true;
  }
  check('长度错误的私钥抛 ArgumentError', threw);

  // 首字节不是 0x04 的压缩点形式应被拒绝
  threw = false;
  try {
    final bad = Uint8List.fromList(Qq8Config.serverEcdhPublicKey);
    bad[0] = 0x02;
    Ecdh.exchange(bad);
  } on ArgumentError {
    threw = true;
  }
  check('压缩点形式被拒绝（只接受未压缩）', threw);
}

// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('QQ 8.2.11 协议内核离线自测');
  stdout.writeln('=' * 62);

  testConfig();
  testEcdhGolden();
  testEcdhProperties();

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_passed 项，失败 $_failed 项');
  exit(_failed == 0 ? 0 : 1);
}
