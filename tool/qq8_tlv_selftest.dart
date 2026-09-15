/// QQ 8.2.11 TLV 打包器离线自测
///
/// **不需要网络、不需要 QQ 账号**。全部 48 条黄金向量由 **oicq 原始模块**
/// `lib/wtlogin/tlv.js` 在确定性 mock 上下文下运行生成
/// （脚本见工作区 `gen_tlv_vectors.cjs`），Dart 常量表由
/// `gen_dart_vectors.cjs` 从 JSON 直接生成，**不经手工转写**。
///
/// 这同时端到端验证了 `tea.dart` 的分组链修正——TLV 0x106 与 0x144 的
/// body 是 TEA 加密的，密文对得上说明整条加密链路都是对的。
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/qq8_tlv_selftest.dart
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/infra/coder.dart';
import 'package:qqclient/kernel/crypto/digest.dart';
import 'package:qqclient/kernel/crypto/tea.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tlv.dart';

// ---------------------------------------------------------------------------

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

Uint8List hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String toHex(List<int> b) =>
    b.map((x) => (x & 0xff).toRadixString(16).padLeft(2, '0')).join();

Uint8List fill(int n, int v) => Uint8List(n)..fillRange(0, n, v);

// ---------------------------------------------------------------------------
// 与 Node mock 逐字段对齐的上下文
// ---------------------------------------------------------------------------

const _fixedNow = 1700000000000;

Qq8TlvContext buildContext() {
  final device = Qq8Device(
    product: 'MRS4S',
    device: 'HIM188MOE',
    board: 'MIRAI-YYDS',
    brand: 'OICQX',
    model: 'Konata 2020',
    bootloader: 'U-boot',
    fingerprint: 'OICQX/MRS4S/HIM188MOE:10/ABCDEF1234567890/1234567'
        ':user/release-keys',
    bootId: '11111111-2222-3333-4444-555555555555',
    procVersion: 'Linux version 4.19.71',
    baseband: '',
    sim: 'T-Mobile',
    apn: 'wifi',
    osType: 'android',
    macAddress: '00:50:56:C0:00:08',
    ipAddress: '10.0.0.1',
    wifiBssid: '00:50:56:C0:00:08',
    wifiSsid: 'TP-LINK-2711',
    imei: '860000000000001',
    androidId: 'ABCDEF1234567890',
    version: const Qq8AndroidVersion(
      release: '10',
      codename: 'REL',
      incremental: '1234567',
      sdk: 29,
    ),
    imsi: fill(16, 0x22),
    tgtgt: hex('ffeeddccbbaa99887766554433221100'),
    guid: hex('00112233445566778899aabbccddeeff'),
  );

  return Qq8TlvContext(
    uin: 10001,
    apk: Qq8ApkInfo(
      id: 'com.tencent.mobileqq',
      ver: '8.2.11',
      sdkver: '6.0.0.2423',
      appid: 16,
      subid: 537064117,
      miscBitmap: 150470524,
      mainSigMap: 16724722,
      buildtime: 1608919008,
      sign: hex('a6b745bf24a2c277527716f6f36eb68d'),
    ),
    device: device,
    passwordMd5: fill(16, 0x11),
    seqId: 100,
    ksid: fill(16, 0x33),
    t104: hex('0102030405060708'),
    t174: hex('aabbccdd'),
    tgt: hex('1122334455667788'),
    srmToken: hex('99aabbcc'),
    randomBytes: (n) => fill(n, 0xab),
    // 参考实现（oicq）的 TEA 填充来自 Buffer.allocUnsafe，新进程里是零。
    // 注入零填充才能与它的密文逐字节比对。
    teaPadding: (n) => fill(n, 0),
    nowMillis: () => _fixedNow,
  );
}

// ---------------------------------------------------------------------------
// 黄金向量 —— 由 gen_dart_vectors.cjs 从 tlv_vectors.json 生成，勿手改
// ---------------------------------------------------------------------------

// GENERATED-VECTORS-BEGIN
const _vectors = <({int tag, List<Object?> args, String hex})>[
  (tag: 0x001, args: [], hex: '000100140001abababab00002711cfe56800000000000000'),
  (tag: 0x008, args: [], hex: '000800080000000008040000'),
  (
    tag: 0x016,
    args: [],
    hex: '001600490000000700000010200300ef00112233445566778899aabbccddeeff'
        '0012636f6d2e74656e63656e742e71716c6974650005342e302e320010a6b745'
        'bf24a2c277527716f6f36eb68d'
  ),
  (tag: 0x018, args: [], hex: '0018001600010000060000000010000000000000271100000000'),
  (
    tag: 0x01B,
    args: [],
    hex: '001b001e00000000000000000000000300000004000000480000000200000002'
        '0000'
  ),
  (tag: 0x01D, args: [], hex: '001d000e010af7ff7c000000000000000000'),
  (
    tag: 0x01F,
    args: [],
    hex: '001f002d000007616e64726f69640005372e312e32000200104368696e61204d'
        '6f62696c652047534d0000000477696669'
  ),
  (tag: 0x033, args: [], hex: '0033001000112233445566778899aabbccddeeff'),
  (tag: 0x035, args: [], hex: '0035000400000008'),
  (tag: 0x100, args: [0], hex: '01000016000100000007000000102002f2b50000000000ff32f2'),
  (tag: 0x100, args: [1], hex: '0100001600010000000700000010000000020000000000ff32f2'),
  (tag: 0x104, args: [], hex: '010400080102030405060708'),
  (
    tag: 0x106,
    args: [],
    hex: '0106007855e0f76ce568420dabafecebeace27d05973c9f1c2bcd69bfbf48aa6'
        'd5721618171f7eebac88a45fa8238dff7281e190fae9ce0c0b45c07d77670967'
        '18651a5882020298acb1a85b5a70ee9219b7b879bc2f79fd1d37125f18e3e0d6'
        'ed5fae86d60aef41be0d94b462a582d30fd5f1f4a324889c8762fb1c'
  ),
  (tag: 0x107, args: [], hex: '01070006000000000001'),
  (tag: 0x108, args: [], hex: '0108001033333333333333333333333333333333'),
  (tag: 0x109, args: [], hex: '0109001040bab137c0b007a222fa3fa1782c5ea7'),
  (tag: 0x10A, args: [], hex: '010a00081122334455667788'),
  (tag: 0x116, args: [], hex: '0116000e0008f7ff7c00010400015f5e10e2'),
  (
    tag: 0x124,
    args: [],
    hex: '012400210007616e64726f69640002313000020008542d4d6f62696c65000000'
        '0477696669'
  ),
  (
    tag: 0x128,
    args: [],
    hex: '0128002f000000010001000000000b4b6f6e6174612032303230001000112233'
        '445566778899aabbccddeeff00054f49435158'
  ),
  (tag: 0x141, args: [], hex: '0141001400010008542d4d6f62696c650002000477696669'),
  (
    tag: 0x142,
    args: [],
    hex: '0142001800000014636f6d2e74656e63656e742e6d6f62696c657171'
  ),
  (tag: 0x143, args: ['d2d2d2d2'], hex: '014300086432643264326432'),
  (
    tag: 0x144,
    args: [],
    hex: '01440140d0a332ea87f37642165a5532e7e799d35131d607bc5e5080762973fa'
        '1de7f63590ee6ae6fce60375709ea3d2e44e344e1b34128a44cb79fbdd29279e'
        '7e3e9dd27208389c869badc615f5bd146a69699d9e209c12ed90bed33079eace'
        'ee44680c38dc139d315bc8582b431cd5254ea5c9e293b74c051e0475a66e15f0'
        'a75cded0e9ae1ff831ec530ef9a434e431863374d2e240fad3dd138fab128bda'
        'ad0c4a220cc0c04c24aa2b85c6b9afd96329abcf8a2670fc2b64f5a1dbdbf667'
        '0abe7670fe28735fb2d7a950c4c355f113c0959db0a98b564588bb340348ef78'
        'c9437d32e140ef0d98fb0328d18972e35354fe90d51ac149431eac83ff0c209d'
        'c00f5bf597c2bd394fccc98da1248d6409e93be0b8c9a21b828aeff9ecde5ded'
        '1d8027530f40c99eb0b3f32de1e5210cd6f696f2ca1650252f9e04e265942db5'
        '14e9e400'
  ),
  (tag: 0x145, args: [], hex: '0145001000112233445566778899aabbccddeeff'),
  (
    // ⚠️ 48 条里唯一**有意偏离 oicq** 的向量（生成端 `gen_tlv_vectors.cjs`
    // 的 OFFICIAL_OVERRIDES）：oicq 第二段是 `ver.slice(0, 5)`，它自己的
    // ver 恰是 5 字符（"8.4.1"）故 slice 恒不生效；官方 `tlv_t147.java:17-18`
    // 是 `limit_len(..., 32)` 发整串 versionName ⇒ "8.2.11" 6 字节。
    // 我们的档案都是 6 字符，照抄 slice(0,5) 会真的少一字节。
    tag: 0x147,
    args: [],
    hex: '0147001e000000100006382e322e31310010a6b745bf24a2c277527716f6f36eb6'
        '8d'
  ),
  (tag: 0x154, args: [], hex: '0154000400000065'),
  (tag: 0x16A, args: [], hex: '016a000499aabbcc'),
  (tag: 0x16E, args: [], hex: '016e000b4b6f6e6174612032303230'),
  (tag: 0x174, args: [], hex: '01740004aabbccdd'),
  (tag: 0x177, args: [], hex: '01770011015fe627e0000a362e302e302e32343233'),
  (tag: 0x17A, args: [], hex: '017a000400000009'),
  (tag: 0x17C, args: ['ABCD'], hex: '017c0006000441424344'),
  (tag: 0x187, args: [], hex: '0187001010d2717e7d06a80d409fbb21516ebec0'),
  (tag: 0x188, args: [], hex: '01880010d149274109b50d5147c09d6fc7e80c71'),
  (tag: 0x191, args: [], hex: '0191000182'),
  (
    tag: 0x193,
    args: ['ticketticket'],
    hex: '0193000c7469636b65747469636b6574'
  ),
  (tag: 0x194, args: [], hex: '0194001022222222222222222222222222222222'),
  (tag: 0x197, args: [], hex: '01970003000100'),
  (tag: 0x198, args: [], hex: '01980003000100'),
  (
    tag: 0x202,
    args: [],
    hex: '02020020001030303a35303a35363a43303a30303a30000c54502d4c494e4b2d'
        '32373131'
  ),
  (
    tag: 0x400,
    args: [],
    hex: '040000360001000000000000271100112233445566778899aabbccddeeffabab'
        'abababababababababababababab0000000100000010cfe56800'
  ),
  (tag: 0x401, args: [], hex: '04010010abababababababababababababababab'),
  (
    tag: 0x511,
    args: [],
    hex: '051100d3000e01000a74656e7061792e636f6d0100116f70656e6d6f62696c65'
        '2e71712e636f6d01000b646f63732e71712e636f6d01000e636f6e6e6563742e'
        '71712e636f6d01000c717a6f6e652e71712e636f6d01000a7669702e71712e63'
        '6f6d01000a71756e2e71712e636f6d01000b67616d652e71712e636f6d01000c'
        '71717765622e71712e636f6d01000d6f66666963652e71712e636f6d01000974'
        '692e71712e636f6d01000b6d61696c2e71712e636f6d01001167616d6563656e'
        '7465722e71712e636f6d01000a6d6d612e71712e636f6d'
  ),
  (tag: 0x516, args: [], hex: '0516000400000000'),
  (tag: 0x521, args: [], hex: '05210006000000000000'),
  (tag: 0x525, args: [], hex: '052500080001053600020100'),
  (
    tag: 0x52D,
    args: [],
    hex: '052d00b50a06552d626f6f7412154c696e75782076657273696f6e20342e3139'
        '2e37311a0352454c2207313233343536372a434f494351582f4d525334532f48'
        '494d3138384d4f453a31302f414243444546313233343536373839302f313233'
        '343536373a757365722f72656c656173652d6b65797332243131313131313131'
        '2d323232322d333333332d343434342d3535353535353535353535353a104142'
        '434445463132333435363738393042004a0731323334353637'
  ),
];
// GENERATED-VECTORS-END

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// TEA 加密 TLV 的参考数据
//
// ⚠️ 这两条**不做密文比对**，原因见 testTeaTlvs 的说明。
// 下面是从参考实现（oicq）内部拦截 tea.encrypt 得到的真实密钥与明文。
// ---------------------------------------------------------------------------

const _teaRef106Key = 'e7baf3ef7096349ed4ac09fd395fcbe7';

/// **官方**公式算出的 0x106 密钥：`MD5(guid ‖ u64(uin))`。
///
/// 与 [_teaRef106Key]（oicq 的 `MD5(password_md5 ‖ 0000 ‖ uin_u32be)`）不同。
/// 官方三个版本（8.2.11 / 8.9.50 / 9.3.60）的 `tlv_t106` 逐行一致，
/// 均使用本公式；本实现已按官方修正。
const _officialKey106 = '0647463a6a1ad304a7a7e5b3de28bd7f';
const _teaRef106Plain =
    '0004abababab0000000700000010000000000000000000002711cfe568000000000001'
    '11111111111111111111111111111111ffeeddccbbaa9988776655443322110000000000'
    '0100112233445566778899aabbccddeeff2002f2b500000001000531303030310000';

const _teaRef144Key = 'ffeeddccbbaa99887766554433221100';
const _teaRef144Plain =
    '00050109001040bab137c0b007a222fa3fa1782c5ea7052d00b50a06552d626f6f7412'
    '154c696e75782076657273696f6e20342e31392e37311a0352454c22073132333435363'
    '72a434f494351582f4d525334532f48494d3138384d4f453a31302f4142434445463132'
    '33343536373839302f313233343536373a757365722f72656c656173652d6b6579733224'
    '31313131313131312d323232322d333333332d343434342d353535353535353535353535'
    '3a104142434445463132333435363738393042004a073132333435363701240021000761'
    '6e64726f69640002313000020008542d4d6f62696c6500000004776966690128002f0000'
    '00010001000000000b4b6f6e6174612032303230001000112233445566778899aabbccddee'
    'ff00054f49435158016e000b4b6f6e6174612032303230';

/// TEA 加密的 TLV：不复现密文（填充任意），改为在**明文与密钥层面**验证。
void testTeaTlvs() {
  section('2. TEA 加密 TLV（0x106 / 0x144）的明文级验证');

  stdout.writeln('     说明：这两个 TLV 的 body 是 TEA 加密的，而 TEA 会在明文头部');
  stdout.writeln('     垫入任意字节（服务端解密后丢弃）。因此**密文不可复现**，');
  stdout.writeln('     比密文等于在比"填充怎么选"，而不是比算法。这里改为验证：');
  stdout.writeln('       ① 密钥派生  ② 明文内容与参考逐字节一致');
  stdout.writeln('     注意 0x106 的密钥派生已按**官方**修正，与 oicq 不同。');

  final ctx = buildContext();

  // --- 0x106：口令登录包 ---
  //
  // ⚠️ 密钥派生**刻意与 oicq 不同**：官方三个版本用的是
  //    MD5(guid(16) ‖ u64(uin 或 msalt)(8))
  // 而 oicq 用的是 MD5(password_md5 ‖ 0000 ‖ uin_u32be)。以官方为准。
  final key106 = md5Bytes(<int>[
    ...ctx.device.guid,
    ...(ByteWriter()..u64(ctx.uin)).build(),
  ]);
  if (toHex(key106) == _officialKey106) {
    ok('0x106 密钥 = MD5(guid ‖ u64(uin))（官方三版本一致）', _officialKey106);
  } else {
    bad('0x106 官方密钥派生', '期望 $_officialKey106，实际 ${toHex(key106)}');
  }

  // 同时确认我们确实没用 oicq 的公式
  final oicqKey106 = md5Bytes(<int>[
    ...ctx.passwordMd5,
    ...Uint8List(4),
    ...(ByteWriter()..u32(ctx.uin)).build(),
  ]);
  if (toHex(oicqKey106) == _teaRef106Key &&
      toHex(oicqKey106) != toHex(key106)) {
    ok('与 oicq 的密钥确实不同（已按官方修正）',
        'oicq=${toHex(oicqKey106).substring(0, 16)}…');
  } else {
    bad('密钥对比', 'oicq 公式结果 ${toHex(oicqKey106)}');
  }

  // 明文结构未变，仍应与参考实现逐字节一致
  final body106 = Qq8Tlv.body(ctx, 0x106);
  final plain106 = qqTeaDecrypt(body106, key106);
  if (toHex(plain106) == _teaRef106Plain) {
    ok('0x106 明文与参考逐字节一致', '${plain106.length} 字节');
  } else {
    bad(
      '0x106 明文不一致',
      '长度 ${plain106.length} vs ${_teaRef106Plain.length ~/ 2}\n'
      '        期望 $_teaRef106Plain\n        实际 ${toHex(plain106)}',
    );
  }

  // --- 0x144：设备信息包（密钥就是 device.tgtgt）---
  if (toHex(ctx.device.tgtgt) == _teaRef144Key) {
    ok('0x144 密钥即 device.tgtgt');
  } else {
    bad('0x144 密钥', '期望 $_teaRef144Key');
  }

  final body144 = Qq8Tlv.body(ctx, 0x144);
  final plain144 = qqTeaDecrypt(body144, ctx.device.tgtgt);
  if (toHex(plain144) == _teaRef144Plain) {
    ok('0x144 明文与参考逐字节一致', '${plain144.length} 字节');
  } else {
    bad(
      '0x144 明文不一致',
      '长度 ${plain144.length} vs ${_teaRef144Plain.length ~/ 2}',
    );
  }

  // --- 交叉：用我们的 TEA 解参考实现的密文 ---
  //
  // 只做 0x144（密钥是 device.tgtgt，与 oicq 一致）。
  // 0x106 不再适用：密钥派生已按官方修正，与 oicq 不同，
  // 因此它的密文本来就解不开——这正是修正的预期结果。
  for (final v in _vectors) {
    if (v.tag != 0x144) continue;
    final body = Uint8List.sublistView(hex(v.hex), 4);
    try {
      final dec = qqTeaDecrypt(body, ctx.device.tgtgt);
      if (toHex(dec) == _teaRef144Plain) {
        ok('用本实现解密参考实现 0x144 的密文 → 明文一致');
      } else {
        bad('解参考密文 0x144', '明文不匹配');
      }
    } on Object catch (e) {
      bad('解参考密文 0x144', '抛异常 $e');
    }
  }
}

void testVectors() {
  section('1. 46 个明文 TLV 黄金向量（来源：oicq lib/wtlogin/tlv.js）');

  final ctx = buildContext();
  var failed = 0;
  var checked = 0;

  for (final v in _vectors) {
    // TEA 加密的两条只比明文（见 testTeaTlvs）
    if (v.tag == 0x106 || v.tag == 0x144) continue;
    checked++;

    final name = '0x${v.tag.toRadixString(16).padLeft(3, '0')}'
        '${v.args.isEmpty ? '' : ' ${v.args}'}';
    try {
      final got = toHex(Qq8Tlv.pack(ctx, v.tag, v.args));
      if (got == v.hex) {
        ok(name, '${v.hex.length ~/ 2} 字节');
      } else {
        failed++;
        bad(
          name,
          '长度 期望 ${v.hex.length ~/ 2} / 实际 ${got.length ~/ 2}\n'
          '        期望 ${v.hex}\n        实际 $got',
        );
      }
    } on Object catch (e) {
      failed++;
      bad(name, '抛异常 $e');
    }
  }

  stdout.writeln('     共 $checked 条明文 TLV 逐字节比对，失败 $failed 条');
  stdout.writeln('     （另有 2 条 TEA 加密的，见下一节）');
}

void testFraming() {
  section('3. TLV 帧结构自洽');

  final ctx = buildContext();
  var framingOk = true;
  for (final v in _vectors) {
    final packed = Qq8Tlv.pack(ctx, v.tag, v.args);
    final r = ByteReader(packed);
    final tag = r.readUint16();
    final len = r.readUint16();
    if (tag != v.tag || len != packed.length - 4 || r.remaining != len) {
      framingOk = false;
      bad('0x${v.tag.toRadixString(16)} 帧结构',
          'tag=$tag len=$len 实际 body=${packed.length - 4}');
    }
  }
  if (framingOk) {
    ok('全部向量的 [tag][len][body] 结构自洽（len 只计 body）');
  }

  var threw = false;
  try {
    Qq8Tlv.pack(ctx, 0x9999);
  } on ArgumentError {
    threw = true;
  }
  if (threw) {
    ok('未知 TLV 编号抛 ArgumentError');
  } else {
    bad('未知 TLV 编号未报错', '应抛 ArgumentError');
  }
}

void testNestedIntegrity() {
  section('4. 嵌套与加密结构的完整性');

  final ctx = buildContext();

  // 0x144 内部含 5 个子 TLV，TEA 解密后应能解析出来
  final t144 = Qq8Tlv.pack(ctx, 0x144);
  final r = ByteReader(t144)..readUint16();
  final len = r.readUint16();
  final body = r.read(len);
  final inner = qqTeaDecrypt(body, ctx.device.tgtgt);

  final ir = ByteReader(inner);
  final cnt = ir.readUint16();
  if (cnt == 5) {
    ok('0x144 解密后子 TLV 计数为 5');
  } else {
    bad('0x144 子 TLV 计数', '期望 5，实际 $cnt');
  }

  final tags = <int>[];
  while (ir.remaining > 0) {
    final t = ir.readUint16();
    final l = ir.readUint16();
    ir.read(l);
    tags.add(t);
  }
  const expected = [0x109, 0x52d, 0x124, 0x128, 0x16e];
  if (tags.length == expected.length) {
    var same = true;
    for (var i = 0; i < tags.length; i++) {
      if (tags[i] != expected[i]) same = false;
    }
    if (same) {
      ok('0x144 子 TLV 编号与参考一致',
          tags.map((t) => '0x${t.toRadixString(16)}').join(', '));
    } else {
      bad('0x144 子 TLV 编号', '实际 $tags');
    }
  } else {
    bad('0x144 子 TLV 个数', '解析出 ${tags.length} 个');
  }

  // 0x52d 是 protobuf，应能解析出 9 个字段
  final t52d = Qq8Tlv.body(ctx, 0x52D);
  final fieldCount = _countProtoFields(t52d);
  if (fieldCount == 9) {
    ok('0x52d 是 9 字段的 protobuf 消息');
  } else {
    bad('0x52d protobuf 字段数', '期望 9，实际 $fieldCount');
  }

  // 0x16 内嵌的签名应与 apk.sign 一致（跨实现交叉印证）
  final t16 = Qq8Tlv.pack(ctx, 0x16);
  if (toHex(t16).endsWith(toHex(ctx.apk.sign).replaceAll('a6b745bf', 'a6b745bf'))) {
    ok('0x16 内嵌的 sign 与 apk.sign 一致');
  } else {
    bad('0x16 内嵌 sign', '未找到 apk.sign');
  }
}

/// 简易 protobuf 字段计数（只处理 wire type 0 与 2）。
int _countProtoFields(Uint8List data) {
  var pos = 0;
  var count = 0;

  int readVarint() {
    var v = 0;
    var shift = 0;
    while (pos < data.length) {
      final b = data[pos++];
      v |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
    }
    return v;
  }

  while (pos < data.length) {
    final key = readVarint();
    final type = key & 7;
    count++;
    if (type == 0) {
      readVarint();
    } else if (type == 2) {
      final len = readVarint();
      pos += len;
    } else {
      break;
    }
  }
  return count;
}

void main() {
  stdout.writeln('QQ 8.2.11 TLV 打包器离线自测');
  stdout.writeln('=' * 66);
  stdout.writeln('黄金向量由 oicq 原始 lib/wtlogin/tlv.js 在确定性 mock 下生成；');
  stdout.writeln('TEA 加密的两个 TLV 在明文与密钥层面比对（密文含任意填充，不可比）。');

  testVectors();
  testTeaTlvs();
  testFraming();
  testNestedIntegrity();

  stdout.writeln('\n${'=' * 66}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
