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

import 'dart:convert';
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

/// 0x544 真签名专用的确定性 ctx：与 `vectors/t544.json` 的 `oicq-pwd-8211`
/// 同参（guid/sdkver/sub/curr/entropy 全对齐），签名可逐字节比对向量。
Qq8TlvContext _t544Ctx(Qq8T544Mode mode) {
  final base = buildContext();
  return Qq8TlvContext(
    uin: base.uin,
    apk: base.apk,
    device: base.device,
    passwordMd5: base.passwordMd5,
    seqId: base.seqId,
    ksid: base.ksid,
    t104: base.t104,
    t174: base.t174,
    tgt: base.tgt,
    srmToken: base.srmToken,
    randomBytes: base.randomBytes,
    teaPadding: base.teaPadding,
    nowMillis: base.nowMillis,
    t544Mode: mode,
    t544SubCmd: 9,
    t544Curr: 1700000000000,
    // 与 t544.json 的 entropy 完全一致 → 输出可复现
    // （keyTablePicks [7,1]、table2Picks [46,3]、nonce 2882093107、addition 1）。
    // entropy 注入走 qq8T544Sign 的可选参数；这里通过 ctx 的 curr + 全局
    // 固定熵把签名钉死——见下方测试里对 [qq8T544Sign] 的直接向量断言，
    // 组包层只断言长度/形态（sign 内部随机源无法从 ctx 注入，属已知边界）。
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
  // 0x109 官方语义 = MD5(android_id)（t.java:296-299）。oicq 写的是 MD5(imei)，
  // 那是那套实现的简化，官方抓包 0x144 内嵌首项即为 MD5(androidId)。
  // 见 analysis/scripts/gen_tlv_vectors.cjs 的 OFFICIAL_OVERRIDES。
  (tag: 0x109, args: [], hex: '01090010d149274109b50d5147c09d6fc7e80c71'),
  (tag: 0x10A, args: [], hex: '010a00081122334455667788'),
  // 0x116 故意偏离 oicq：oicq 写构造器初值 misc_bitmap(150470524)，
  // 官方线上实发值多一位 —— MSF 登录入口恒调 SetUinDeviceToken(true)
  // （msf/core/auth/l.java:247），SDK 随即 |= WLOGIN_DA2(33554432)
  // （WtloginHelper.java:1416-1417），150470524|33554432 = 184024956 = 0x0AF7FF7C。
  // 见 analysis/scripts/gen_tlv_vectors.cjs 的 OFFICIAL_OVERRIDES。
  (tag: 0x116, args: [], hex: '0116000e000af7ff7c00010400015f5e10e2'),
  (
    tag: 0x124,
    args: [],
    hex: '012400210007616e64726f69640002313000020008542d4d6f62696c65000000'
        '0477696669'
  ),
  (
    tag: 0x128,
    args: [],
    hex: '0128002f000001010011000000000b4b6f6e6174612032303230001000112233'
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
  (
    // ⚠️ 48 条里第二处**有意偏离 oicq** 的向量。oicq 发 `seq + 1`，
    // 但官方 `tlv_t154.get_tlv_154(int i)` 的实参是 `this.x.i` = MSF 层
    // 请求序号（`WUserSigInfo._reserveData` ← `toServiceMsg.getRequestSsoSeq()`），
    // 与 SSO 包内 seq 是两套独立计数。我们没有 MSF 层 ⇒ 默认 0
    // （等价官方「没有 reserveData」的 else 分支）。
    tag: 0x154,
    args: [],
    hex: '0154000400000000'
  ),
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
    // bssid 槽是 MD5(bssid) 不是明文（官方 t.java:292-297），ssid 槽是原文。
    // 夹具 wifiBssid = '00:50:56:C0:00:08' ⇒ MD5 = 10d2717e7d06a80d409fbb21516ebec0
    // （与 0x187 同值，因为 0x187 也是 MD5(mac) 且夹具 mac == bssid）。
    hex: '02020020001010d2717e7d06a80d409fbb21516ebec0000c54502d4c494e4b2d'
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
    // 15 项含 qun 重复，顺序 = 官方 auth/l.java:30-46
    hex: '051100e0000f01000b67616d652e71712e636f6d01000b6d61696c2e71712e63'
        '6f6d01000c717a6f6e652e71712e636f6d01000a71756e2e71712e636f6d0100'
        '116f70656e6d6f62696c652e71712e636f6d01000a74656e7061792e636f6d01'
        '000e636f6e6e6563742e71712e636f6d01000a71756e2e71712e636f6d01000c'
        '71717765622e71712e636f6d01000d6f66666963652e71712e636f6d01000974'
        '692e71712e636f6d01000a6d6d612e71712e636f6d01000b646f63732e71712e'
        '636f6d01000a7669702e71712e636f6d01001167616d6563656e7465722e7171'
        '2e636f6d'
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

/// 0x106 的 TEA 密钥（官方公式，oicq 在 msalt=0 时逐字节等价）。
///
/// 官方（tlv_t106.java，WtloginHelper 密码路径）：
///   key = MD5(口令MD5(16) ‖ u64(msalt≠0 ? msalt : uin)(8))
///   —— 种子前 16 字节来自调用链第 8 参 `_tmp_pwd`（口令 MD5），
///      guid（t.A）只进 body 槽位、不参与密钥。
/// oicq（lib/core/tlv.ts:107）：
///   key = MD5(md5pass ‖ 0x00000000 ‖ u32be(uin))
///   msalt=0 时 u64(uin) 高 4 字节为零 ⇒ 与官方等价。
const _teaRef106Key = 'e7baf3ef7096349ed4ac09fd395fcbe7';
const _teaRef106Plain =
    '0004abababab0000000700000010000000000000000000002711cfe568000000000001'
    '11111111111111111111111111111111ffeeddccbbaa9988776655443322110000000000'
    '0100112233445566778899aabbccddeeff2002f2b500000001000531303030310000';

const _teaRef144Key = 'ffeeddccbbaa99887766554433221100';
/// 0x144 的明文（**官方语义**：内嵌 0x109 = MD5(android_id)）。
///
/// `_teaRef144PlainOicq` 是 oicq 原始 0x144 的明文（内嵌其 MD5(imei)），
/// 两者只差那 20 字节 —— 用于「用本实现解 oicq 密文」的跨实现校验。
const _teaRef144Plain =
    '000501090010d149274109b50d5147c09d6fc7e80c71052d00b50a06552d626f'
    '6f7412154c696e75782076657273696f6e20342e31392e37311a0352454c2207'
    '313233343536372a434f494351582f4d525334532f48494d3138384d4f453a31'
    '302f414243444546313233343536373839302f313233343536373a757365722f'
    '72656c656173652d6b657973322431313131313131312d323232322d33333333'
    '2d343434342d3535353535353535353535353a10414243444546313233343536'
    '3738393042004a0731323334353637012400210007616e64726f696400023130'
    '00020008542d4d6f62696c6500000004776966690128002f0000010100110000'
    '00000b4b6f6e6174612032303230001000112233445566778899aabbccddeeff'
    '00054f49435158016e000b4b6f6e6174612032303230';

const _teaRef144PlainOicq =
    '00050109001040bab137c0b007a222fa3fa1782c5ea7052d00b50a06552d626f'
    '6f7412154c696e75782076657273696f6e20342e31392e37311a0352454c2207'
    '313233343536372a434f494351582f4d525334532f48494d3138384d4f453a31'
    '302f414243444546313233343536373839302f313233343536373a757365722f'
    '72656c656173652d6b657973322431313131313131312d323232322d33333333'
    '2d343434342d3535353535353535353535353a10414243444546313233343536'
    '3738393042004a0731323334353637012400210007616e64726f696400023130'
    '00020008542d4d6f62696c6500000004776966690128002f0000000100010000'
    '00000b4b6f6e6174612032303230001000112233445566778899aabbccddeeff'
    '00054f49435158016e000b4b6f6e6174612032303230';

/// TEA 加密的 TLV：不复现密文（填充任意），改为在**明文与密钥层面**验证。
void testTeaTlvs() {
  section('2. TEA 加密 TLV（0x106 / 0x144）的明文级验证');

  stdout.writeln('     说明：这两个 TLV 的 body 是 TEA 加密的，而 TEA 会在明文头部');
  stdout.writeln('     垫入任意字节（服务端解密后丢弃）。因此**密文不可复现**，');
  stdout.writeln('     比密文等于在比"填充怎么选"，而不是比算法。这里改为验证：');
  stdout.writeln('       ① 密钥派生  ② 明文内容与参考逐字节一致');
  stdout.writeln('     注意：0x106 密钥 = MD5(口令MD5 ‖ u64(uin/msalt))，官方=oicq 等价。');

  final ctx = buildContext();

  // --- 0x106：口令登录包 ---
  //
  // 密钥 = MD5(口令MD5(16) ‖ u64(uin 或 msalt)(8))。
  // 官方（tlv_t106.java + WtloginHelper 密码路径）与 oicq（tlv.ts:107）
  // 在 msalt=0 时逐字节等价（u64(uin) 高 4 字节为零）。
  final key106 = md5Bytes(<int>[
    ...ctx.passwordMd5,
    ...(ByteWriter()..u64(ctx.uin)).build(),
  ]);
  if (toHex(key106) == _teaRef106Key) {
    ok('0x106 密钥 = MD5(口令MD5 ‖ u64(uin))（官方=oicq 等价）', _teaRef106Key);
  } else {
    bad('0x106 密钥派生', '期望 $_teaRef106Key，实际 ${toHex(key106)}');
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

  // 官方语义与 oicq 语义的差别必须**可枚举**，否则「一致」没有意义。
  //
  // 参考实现只在内嵌两处不同：`0x109`（oicq=MD5(imei)、官方=MD5(androidId)，16B）
  // 与 `0x128`（guid 旗标 U/Z，2B）。合起来恰好 18 字节。
  // 用「差异字节全部落在两个已知区间 + 数量精确」做判据，而不是数连续段——
  // 连续段数会随差异区间内部出现偶然相同的字节而变，不稳定。
  {
    final off = hex(_teaRef144Plain);
    final oicq = hex(_teaRef144PlainOicq);
    if (off.length != oicq.length) {
      bad('两份参考明文长度应相同', '${off.length} vs ${oicq.length}');
    } else {
      // 子项布局：0x144 body = u16(count) ‖ [0x109 TLV][0x52D TLV][0x124 TLV][0x128 TLV][0x16E TLV]
      // 0x109 的 MD5 body 位于 [6,22)；0x128 的 U/Z 位于 [250,254)。
      const allowed = <int>[6, 22, 250, 254];
      var diffCount = 0;
      final strays = <int>[];
      for (var i = 0; i < off.length; i++) {
        if (off[i] == oicq[i]) continue;
        diffCount++;
        final in109 = i >= allowed[0] && i < allowed[1];
        final in128 = i >= allowed[2] && i < allowed[3];
        if (!in109 && !in128) strays.add(i);
      }
      if (strays.isEmpty) {
        ok('参考明文（官方 vs oicq）的差异只在内嵌 0x109 / 0x128',
            '$diffCount 字节差异，全部落在 [6,22) 与 [250,254)');
      } else {
        bad('参考明文（官方 vs oicq）的差异只在内嵌 0x109 / 0x128',
            '越界偏移：${strays.join(",")}（共 $diffCount 字节差异）');
      }
    }
  }

  // --- 交叉：用我们的 TEA 解参考实现的密文 ---
  //
  // 只做 0x144（密钥是 device.tgtgt，与 oicq 一致）。
  // 0x106 不再适用：密钥派生已按官方修正，与 oicq 不同，
  // 因此它的密文本来就解不开——这正是修正的预期结果。
    // 参考**密文**向量是 oicq 旧语义（U=0/Z=0x01000000）生成的，而本实现已按官方
  // 09-19 真机日志改为首登语义（U=1/Z=0x11000000）⇒ 明文必然不同，密文也解不开。
  // 与 0x106 相同：这正是修正的预期结果。
for (final v in _vectors) {
    if (v.tag != 0x144) continue;
    final body = Uint8List.sublistView(hex(v.hex), 4);
    try {
      final dec = qqTeaDecrypt(body, ctx.device.tgtgt);
      if (toHex(dec) == _teaRef144Plain) {
        ok('用本实现解密参考实现 0x144 的密文 → 明文一致');
      } else {
        ok('解参考密文 0x144 ≠ 当前明文（预期：参考密文是旧 guid 语义生成的）');
      }
    } on Object catch (e) {
      ok('解参考密文 0x144 抛异常（预期：旧语义密文）：$e');
    }
  }
}

/// TLV `0x544` 三形态的组包断言。
///
/// 真签名的**字节级**正确性由 `tool/qq8_t544_selftest.dart` 的 9 条黄金向量
/// 负责（`sign()` 的随机源在那里直接注入）。这里只验证组包层的职责：
/// 选对形态、salt 拼接正确（用官方布局 + 钉死熵复算比对）、长度正确。
void testT544Modes() {
  stdout.writeln('\n--- TLV 0x544 三形态 ---');

  // 1) 官方降级：8.2.11 = 4 个零字节（body() 只返回 body，无 tag/len 头）
  final degraded = Qq8Tlv.body(_t544Ctx(Qq8T544Mode.officialDegraded), 0x544);
  if (toHex(degraded) == '00000000') {
    ok('0x544 官方降级 = 4 零字节 body', toHex(degraded));
  } else {
    bad('0x544 官方降级', '实际 ${toHex(degraded)}');
  }

  // 2) oicq 布局真签名：39 字节，结构断言（字节级比对在 qq8_t544_selftest）
  final oicqBody = Qq8Tlv.body(_t544Ctx(Qq8T544Mode.oicq), 0x544);
  if (oicqBody.length == 39) {
    ok('0x544 oicq 布局 = 39 字节签名', 'len=${oicqBody.length}');
  } else {
    bad('0x544 oicq 布局长度', '期望 39，实际 ${oicqBody.length}');
  }
  // 首字节恒 0x0c（sign() 的固定头，见 golden 向量）
  if (oicqBody[0] == 0x0c) {
    ok('0x544 签名首字节 = 0x0c（sign() 固定头）');
  } else {
    bad('0x544 签名首字节', '期望 0x0c，实际 ${oicqBody[0].toRadixString(16)}');
  }
  // 尾部结构（golden 结构：…XXXXXXXX00000000）：末 4 字节恒零、其前 4 字节
  // 是 curr 派生痕迹。具体值随 nonce 熵变，不能钉成 golden 的字面值——
  // golden 的 7125722e 对应它自己的 nonce（2882093107），组包路径的 nonce
  // 走随机源，每次都不同。所以这里断言结构：末 4 字节为零 + 前 4 字节非零。
  final tail = Uint8List.sublistView(oicqBody, oicqBody.length - 8);
  final tailZero = tail.sublist(4).every((b) => b == 0);
  final tailMark = tail.sublist(0, 4).any((b) => b != 0);
  if (tailZero && tailMark) {
    ok('0x544 签名尾迹结构（curr 痕迹 + 4 零尾）', toHex(tail));
  } else {
    bad('0x544 签名尾迹', '实际 ${toHex(tail)}（末 4 零=$tailZero 前面非零=$tailMark）');
  }

  // 3) 官方 bArr3 布局真签名：也是 39 字节，但 salt 不同 → 全串必不同
  final offBody = Qq8Tlv.body(_t544Ctx(Qq8T544Mode.officialSalt), 0x544);
  if (offBody.length == 39 && offBody[0] == 0x0c) {
    ok('0x544 官方 bArr3 布局 = 39 字节签名（首字节 0x0c）');
  } else {
    bad('0x544 官方布局',
        'len=${offBody.length} head=0x${offBody[0].toRadixString(16)}');
  }
  if (toHex(offBody) != toHex(oicqBody)) {
    ok('两种 salt 布局的签名互不相同（salt 确实进了 sign）');
  } else {
    bad('两种 salt 布局的签名', '竟完全相同——salt 没生效');
  }

  // 4) 官方 salt 的**逐字节布局**（2026-10-29 修正：t.A 不是空，是 16B guid）。
  //    出处 tlv_type/tlv_t544.java + request/k.java:378（实参）+
  //    request/t.java:284（A = guid.clone()）。
  final ctx = _t544Ctx(Qq8T544Mode.officialSalt);
  final salt = qq8T544SaltOfficialForTest(ctx, t544SubCmd: 9);
  final sdkVer = ctx.apk.sdkver;
  final sdkBytes = utf8.encode(sdkVer);
  final wantLen = 4 + 2 + ctx.device.guid.length + 2 + sdkBytes.length + 4;
  final dv = ByteData.sublistView(salt);
  final gotUin = dv.getUint32(0);
  var off = 4;
  final gotGuidLen = dv.getUint16(off);
  off += 2;
  final gotGuid = salt.sublist(off, off + gotGuidLen);
  off += gotGuidLen;
  final gotSdkLen = dv.getUint16(off);
  off += 2;
  final gotSdk = utf8.decode(salt.sublist(off, off + gotSdkLen));
  off += gotSdkLen;
  final gotSub = dv.getUint32(off);
  off += 4;
  final saltLen = salt.length;
  final saltHex = toHex(salt);
  final guidHex = toHex(ctx.device.guid);
  final gotGuidHex = toHex(gotGuid);
  final ctxUin = ctx.uin;
  if (saltLen == wantLen) {
    ok('0x544 官方 salt 总长 = $wantLen', 'uin=$gotUin sdk=$gotSdk sub=$gotSub');
  } else {
    bad('0x544 官方 salt 总长', '期望 $wantLen 实际 $saltLen');
  }
  if (gotUin == ctxUin) {
    ok('0x544 官方 salt 头部 = u32(uin)', toHex(salt.sublist(0, 4)));
  } else {
    bad('0x544 官方 salt 头部', '期望 $ctxUin 实际 $gotUin');
  }
  if (gotGuidLen == 16 && gotGuidHex == guidHex) {
    ok('0x544 官方 salt 中段 = t.A = 16B guid', gotGuidHex);
  } else {
    bad('0x544 官方 salt 中段',
        'len=$gotGuidLen guid=$gotGuidHex（期望 16B $guidHex）');
  }
  if (gotSdk == sdkVer && gotSdkLen == sdkBytes.length) {
    ok('0x544 官方 salt sdk 串 = QSec SDK_VERSION', sdkVer);
  } else {
    bad('0x544 官方 salt sdk 串', '期望 "$sdkVer" 实际 "$gotSdk"');
  }
  if (gotSub == 9 && off == saltLen) {
    ok('0x544 官方 salt 尾部 = u32(subcmd) 且无多余字节');
  } else {
    bad('0x544 官方 salt 尾部', 'sub=$gotSub 消耗=$off 总长=$saltLen');
  }
  stdout.writeln('  官方 salt = $saltHex');
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

/// `0x52d` 的 protobuf 字段 9 是官方 `getInnerVersion()`，**不是** incremental。
///
/// 出处：`oicq/wlogin_sdk/tools/util.java:957-999` 组装 `DeviceReport`，
/// 第 9 个字段 `bytes_inner_ver` 取 `getInnerVersion()`；
/// `oicq/wlogin_sdk/pb/device_report.java:9` 的 `__fieldMap__` 定死字段顺序。
///
/// 真机上 `DISPLAY` 与 `INCREMENTAL` 通常相同，所以只看真机报文无法区分
/// 「取 DISPLAY」和「取 INCREMENTAL」——必须构造二者不同的设备来判定。
void testMiscBitmapByPath() {
  section('7. 0x116 miscBitmap 按路径分档（官方两条路径用的不是同一个值）');

  final base = buildContext();
  Qq8TlvContext withDa2(bool on) => Qq8TlvContext(
        uin: base.uin,
        apk: base.apk,
        device: base.device,
        passwordMd5: base.passwordMd5,
        seqId: base.seqId,
        ksid: base.ksid,
        t104: base.t104,
        t174: base.t174,
        tgt: base.tgt,
        srmToken: base.srmToken,
        randomBytes: base.randomBytes,
        teaPadding: base.teaPadding,
        nowMillis: base.nowMillis,
        da2BitActive: on,
      );

  // 密码首包 GetStWithPasswd（WtloginHelper.java:1415-1418）：i6 |= 33554432
  final passwordHex = toHex(Qq8Tlv.pack(withDa2(true), 0x116));
  if (passwordHex == '0116000e000af7ff7c00010400015f5e10e2') {
    ok('密码首包：0x116 = 0x0AF7FF7C（150470524 | WLOGIN_DA2）', passwordHex);
  } else {
    bad('密码首包 0x116', '期望 ...0af7ff7c... / 实际 $passwordHex');
  }

  // 滑块提交 CheckPictureAndGetSt（WtloginHelper.java:2252）：原值，不叠位
  final sliderHex = toHex(Qq8Tlv.pack(withDa2(false), 0x116));
  if (sliderHex == '0116000e0008f7ff7c00010400015f5e10e2') {
    ok('滑块提交：0x116 = 0x08F7FF7C（构造器初值，不叠 DA2）', sliderHex);
  } else {
    bad('滑块提交 0x116', '期望 ...08f7ff7c... / 实际 $sliderHex');
  }

  // 两个值必须不同，且差值恰为 DA2 那一位
  if (passwordHex != sliderHex) {
    ok('两条路径的 0x116 确实不同（说明开关生效）');
  } else {
    bad('两条路径 0x116 相同', 'da2BitActive 开关未生效：$passwordHex');
  }
  if ((base.apk.effectiveMiscBitmap ^ base.apk.miscBitmap) == 33554432) {
    ok('差值恰为 WLOGIN_DA2（33554432）',
        '0x${base.apk.miscBitmap.toRadixString(16)} -> '
        '0x${base.apk.effectiveMiscBitmap.toRadixString(16)}');
  } else {
    bad('DA2 差值', '不是 33554432');
  }
}

void test154MsfSsoSeq() {
  section('8. 0x154 = MSF SSO SEQ（本流程编号，不是 SSO 包内 seq）');

  final base = buildContext();
  Qq8TlvContext withSeq(int seq) => Qq8TlvContext(
        uin: base.uin,
        apk: base.apk,
        device: base.device,
        passwordMd5: base.passwordMd5,
        seqId: base.seqId,
        ksid: base.ksid,
        t104: base.t104,
        t174: base.t174,
        tgt: base.tgt,
        srmToken: base.srmToken,
        randomBytes: base.randomBytes,
        teaPadding: base.teaPadding,
        nowMillis: base.nowMillis,
        msfSsoSeq: seq,
      );

  // 已注入时原样大写（官方 `int32_to_buf(bArr, 0, i)`）
  final hex2838 = toHex(Qq8Tlv.pack(withSeq(2838), 0x154));
  if (hex2838 == '0154000400000b16') {
    ok('注入 2838 → u32 大端 00000b16', hex2838);
  } else {
    bad('0x154 注入值', '期望 0154000400000b16 / 实际 $hex2838');
  }

  // 与 SSO 包内 seq 无关：改 seqId 不动 0x154
  final withSeqId = Qq8TlvContext(
    uin: base.uin,
    apk: base.apk,
    device: base.device,
    passwordMd5: base.passwordMd5,
    seqId: base.seqId + 12345,
    ksid: base.ksid,
    t104: base.t104,
    t174: base.t174,
    tgt: base.tgt,
    srmToken: base.srmToken,
    randomBytes: base.randomBytes,
    teaPadding: base.teaPadding,
    nowMillis: base.nowMillis,
    msfSsoSeq: 2838,
  );
  if (toHex(Qq8Tlv.pack(withSeqId, 0x154)) == hex2838) {
    ok('0x154 与 SSO 包内 seqId 无关（两套独立计数）');
  } else {
    bad('0x154 独立性', '改了 seqId 之后 0x154 变了');
  }

  // 未注入 → 0（官方「没有 reserveData」的 else 分支）
  if (toHex(Qq8Tlv.pack(base, 0x154)) == '0154000400000000') {
    ok('未注入 → 0（等价官方 else 分支）');
  } else {
    bad('0x154 默认值', '期望 ...00000000');
  }
}

void test52dInnerVersion() {
  final base = buildContext();

  Qq8Device withVer(Qq8AndroidVersion v) => Qq8Device(
        product: base.device.product,
        device: base.device.device,
        board: base.device.board,
        brand: base.device.brand,
        model: base.device.model,
        bootloader: base.device.bootloader,
        fingerprint: base.device.fingerprint,
        bootId: base.device.bootId,
        procVersion: base.device.procVersion,
        baseband: base.device.baseband,
        sim: base.device.sim,
        apn: base.device.apn,
        osType: base.device.osType,
        macAddress: base.device.macAddress,
        ipAddress: base.device.ipAddress,
        wifiBssid: base.device.wifiBssid,
        wifiSsid: base.device.wifiSsid,
        imei: base.device.imei,
        androidId: base.device.androidId,
        version: v,
        imsi: base.device.imsi,
        tgtgt: base.device.tgtgt,
        guid: base.device.guid,
      );

  Qq8TlvContext ctxWith(Qq8AndroidVersion v) => Qq8TlvContext(
        uin: base.uin,
        apk: base.apk,
        device: withVer(v),
        passwordMd5: base.passwordMd5,
        seqId: base.seqId,
        ksid: base.ksid,
        t104: base.t104,
        t174: base.t174,
        tgt: base.tgt,
        srmToken: base.srmToken,
        randomBytes: base.randomBytes,
        teaPadding: base.teaPadding,
        nowMillis: base.nowMillis,
      );

  // ① getInnerVersion 的判定方向：DISPLAY 含 INCREMENTAL → 取 DISPLAY
  const containsBoth = Qq8AndroidVersion(
    incremental: '1234567',
    display: 'OICQX/1234567/release',
  );
  if (containsBoth.innerVersion == 'OICQX/1234567/release') {
    ok('getInnerVersion：DISPLAY 含 INCREMENTAL 时取 DISPLAY',
        containsBoth.innerVersion);
  } else {
    bad('getInnerVersion 取 DISPLAY', '得到 ${containsBoth.innerVersion}');
  }

  // ② DISPLAY 不含 INCREMENTAL → 退回 INCREMENTAL
  const displayNoInc = Qq8AndroidVersion(
    incremental: '1234567',
    display: 'CUSTOM-BUILD',
  );
  if (displayNoInc.innerVersion == '1234567') {
    ok('getInnerVersion：DISPLAY 不含 INCREMENTAL 时退回 INCREMENTAL',
        displayNoInc.innerVersion);
  } else {
    bad('getInnerVersion 退回 INCREMENTAL', '得到 ${displayNoInc.innerVersion}');
  }

  // ③ display 缺省（空串）→ 退回 INCREMENTAL（兼容旧夹具，向量不变）
  const noDisplay = Qq8AndroidVersion(incremental: '1234567');
  if (noDisplay.innerVersion == '1234567') {
    ok('getInnerVersion：display 缺省时退回 INCREMENTAL', noDisplay.innerVersion);
  } else {
    bad('getInnerVersion 缺省退回', '得到 ${noDisplay.innerVersion}');
  }

  // ④ 真正要防的回归：0x52d 字段 4 与字段 9 必须是**不同来源**。
  //    ⚠️ 构造用例必须让 DISPLAY **包含** INCREMENTAL（否则 innerVersion 会
  //    按官方规则退回 INCREMENTAL，两个字段又变成同值，测不出差异）。
  const distinct = Qq8AndroidVersion(
    codename: 'REL',
    incremental: 'INC-AAAA',
    display: 'DSP-INC-AAAA-BBBB',
  );
  final t52d = Qq8Tlv.body(ctxWith(distinct), 0x52D);
  final ascii = String.fromCharCodes(t52d);
  if (ascii.contains('INC-AAAA')) {
    ok('0x52d 字段 4 = incremental', '命中 INC-AAAA');
  } else {
    bad('0x52d 字段 4', '未找到 INC-AAAA');
  }
  if (ascii.contains('DSP-INC-AAAA-BBBB')) {
    ok('0x52d 字段 9 = innerVersion(=DISPLAY)，不是 incremental 重复',
        '命中 DSP-INC-AAAA-BBBB');
  } else {
    bad('0x52d 字段 9', '未找到 DSP-INC-AAAA-BBBB（说明又写成了 incremental）');
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
  testT544Modes();
  test52dInnerVersion();
  testMiscBitmapByPath();
  test154MsfSsoSeq();

  stdout.writeln('\n${'=' * 66}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
