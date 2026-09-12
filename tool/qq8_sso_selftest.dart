/// QQ 8.2.11 SSO 包构建离线自测
///
/// 黄金向量由运行 **oicq 原始的 `lib/wtlogin/wt.js`** 生成
/// （mock 客户端 + 确定性随机源）。生成脚本与可运行树在分析目录：
/// `../analysis/scripts/gen_sso_vectors.cjs` + `../analysis/_ref/oicq-run-js/`。
///
/// ## 测法说明
///
/// SSO 包内含 TEA 加密区，而 TEA 的填充字节是任意的（服务端解密后丢弃），
/// **密文不可复现**。因此：
///   - 明文区（包头、长度、票据等）→ **逐字节比对**
///   - 密文区 → **解密后比对明文**
///
/// 这样测的是"结构 + 内容"是否一致，而不是"填充怎么选"。
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/qq8_sso_selftest.dart
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/crypto/tea.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_sso.dart';
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

Qq8SsoContext buildContext() {
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

  return Qq8SsoContext(
    uin: 10001,
    apk: Qq8ApkInfo(
      id: 'com.tencent.mobileqq',
      name: 'A8.2.11.4530',
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
    sessionId: fill(4, 0xab),
    randomKey: fill(16, 0xab),
    ecdhPublicKey: hex(
        '04e48813e656219b4090c282a020f40e07b4e1efd60a3dd17492a1667c5758ee'
        '5b760f9b9b1c840b4f4f63ab4043c0537ca29b3512c32e50e56f5e4e8d42d0d31e'),
    ecdhShareKey: hex('f3df7dfb6d55b17975d908d8228dee11'),
    sig: Qq8SigInfo(
      tgt: hex('1122334455667788'),
      d2: hex('d2d2d2d2'),
      d2key: hex('00112233445566778899aabbccddeeff'),
      sigKey: hex('aaaaaaaabbbbbbbbccccccccdddddddd'),
      ticketKey: hex('0102030405060708090a0b0c0d0e0f10'),
      srmToken: hex('99aabbcc'),
    ),
    seqId: 101,
  );
}

/// 测试用的业务体（与 Node 侧一致）。
final _bodies = <String, Uint8List>{
  'empty': Uint8List(0),
  'short': hex('deadbeef'),
  'medium': hex('0123456789abcdef0011223344556677'),
  'long': fill(105, 0xc3),
};

// GENERATED-VECTORS-BEGIN
/// ksid：由设备 IMEI 与客户端名派生。
const _ksidAscii = '|860000000000001|A8.2.11.4530';

const _oicqVectors = <({String name, bool emp, String hex})>[
  (
    name: 'empty',
    emp: false,
    hex: '0200861f4108100001000027110387000000000200000000000000000201'
        'abababababababababababababababab01310001004104e48813e656219b'
        '4090c282a020f40e07b4e1efd60a3dd17492a1667c5758ee5b760f9b9b1c'
        '840b4f4f63ab4043c0537ca29b3512c32e50e56f5e4e8d42d0d31e27149c'
        '488d5a82693e99815d738646c203'
  ),
  (
    name: 'empty',
    emp: true,
    hex: '02003f1f4108100001000027110345000000000200000000000000000010'
        'aaaaaaaabbbbbbbbccccccccdddddddd8cc96f6e9acf8ad06b39e36e7004'
        'f82503'
  ),
  (
    name: 'short',
    emp: false,
    hex: '0200861f4108100001000027110387000000000200000000000000000201'
        'abababababababababababababababab01310001004104e48813e656219b'
        '4090c282a020f40e07b4e1efd60a3dd17492a1667c5758ee5b760f9b9b1c'
        '840b4f4f63ab4043c0537ca29b3512c32e50e56f5e4e8d42d0d31efe23e0'
        '544aeb2b20ea315725a65e991403'
  ),
  (
    name: 'short',
    emp: true,
    hex: '02003f1f4108100001000027110345000000000200000000000000000010'
        'aaaaaaaabbbbbbbbccccccccdddddddd8319f83b7772a81e872003daa371'
        '731203'
  ),
  (
    name: 'medium',
    emp: false,
    hex: '0200961f4108100001000027110387000000000200000000000000000201'
        'abababababababababababababababab01310001004104e48813e656219b'
        '4090c282a020f40e07b4e1efd60a3dd17492a1667c5758ee5b760f9b9b1c'
        '840b4f4f63ab4043c0537ca29b3512c32e50e56f5e4e8d42d0d31e27149c'
        '488d5a82693bd6e4ea98b8cbfd73a99f66f5bb5301b82a9ee23c33821a03'
  ),
  (
    name: 'medium',
    emp: true,
    hex: '02004f1f4108100001000027110345000000000200000000000000000010'
        'aaaaaaaabbbbbbbbccccccccdddddddd8cc96f6e9acf8ad0c21e59246e94'
        'db25c4933313926d692d5cd4ec9c10db506503'
  ),
  (
    name: 'long',
    emp: false,
    hex: '0200ee1f4108100001000027110387000000000200000000000000000201'
        'abababababababababababababababab01310001004104e48813e656219b'
        '4090c282a020f40e07b4e1efd60a3dd17492a1667c5758ee5b760f9b9b1c'
        '840b4f4f63ab4043c0537ca29b3512c32e50e56f5e4e8d42d0d31ef745a7'
        'b1c59cdacc8c8e3338acf805d8382de8f1057034755a1758bc261db8306a'
        'c7c28543c932aeb10e4c2a20b7ffb338b4637c618d6524d8352c282fd2cf'
        '22dd73dd9e73676a827d4c81d006e874094a5ef28f67b598a96ce82c07dc'
        '50e5aec6c3342183a044746a2e32dd1ea72d3cc7f9a5ef8310f4a903'
  ),
  (
    name: 'long',
    emp: true,
    hex: '0200a71f4108100001000027110345000000000200000000000000000010'
        'aaaaaaaabbbbbbbbccccccccdddddddd9e9fa75c446ed3493784fd0e8f33'
        'ecb007ff676763ab9283204b4cafe495893100ade7b1d5a2508a4ca3b840'
        '8d5e01de3a95c141d695063a6a94b448d33fc04b3eed3cdaf06a367e992f'
        '4475a22cd07c034be27dc4257de060fe2e9dea2ed63064e3e65f0d57ca7c'
        '73b285c7547acc792a73d2de6acfcfcc03'
  ),
];

const _loginVectors = <({int type, int seq, String hex})>[
  (
    type: 0,
    seq: 101,
    hex: '000000ae0000000a0000000008d2d2d2d2000000000931303030310000007f00'
        '0000652002f2b52002f2b50100000000000000000001000000000c1122334455'
        '6677880000001577746c6f67696e2e7472616e735f656d7000000008abababab'
        '0000001338363030303030303030303030303100000004001f7c383630303030'
        '3030303030303030317c41382e322e31312e3435333000000004000000140123'
        '456789abcdef0011223344556677'
  ),
  (
    type: 1,
    seq: 101,
    hex: '000000bb0000000a0100000008d2d2d2d200000000093130303031bb81b83ccc'
        '85710141fe6ce115c2734ccc6f7ffd20e0127f79eaef1c5feff4a412acc0f4e5'
        '1c3ee590cb34169c477b1f860333614f1d732243147a9d153fecf95cecc21b92'
        '6a0b2637eb79508ddbe41ccf8258d9ea7ae7b89cb150da0518453e6c62161c84'
        'df6fe4dfec86d4a8cf3612f4b9e32352addd65d825b3e1b5b3e710634a82413a'
        'e5ab7549fb5b38aac8692e417f29aa6b37729619e34f2408525109'
  ),
  (
    type: 2,
    seq: 101,
    hex: '000000bb0000000a0200000008d2d2d2d200000000093130303031df3bd7b400'
        'b90b5a7cbe374ee829cbb75657e232db0377edd2a21e258958d4578a432fa57b'
        'c4fb4f27bbfd012d5723c01e83fe36a5a8930812c2786109ff158550feab3b98'
        '64872535a9003424a520efe4d82a3ed83b19ecb51010cfea4c76e56d8163d570'
        'e86f333cb7ac806fa1c286d3527912348cdd99088a7ac44289826c5ff7785aa7'
        '7c0cd87bb7e64267b2dd94b3cf0ccc6cfbac265f3c3caccd4114a6'
  ),
];
// GENERATED-VECTORS-END

// ---------------------------------------------------------------------------
// 比较工具：密文区解密后比明文
// ---------------------------------------------------------------------------

/// 比较两个含 TEA 密文的包。
///
/// [cipherStart] 密文在包内的起始偏移；[trailerLen] 包尾固定字节数。
/// 逐字节比对明文区与尾部，再把两侧密文各自解密后比对明文。
bool compareWithCipher(
  String label,
  Uint8List ours,
  Uint8List theirs, {
  required int cipherStart,
  required int trailerLen,
  required Uint8List key,
}) {
  if (ours.length != theirs.length) {
    bad('$label 长度', '期望 ${theirs.length}，实际 ${ours.length}');
    return false;
  }

  final oursHead = Uint8List.sublistView(ours, 0, cipherStart);
  final theirsHead = Uint8List.sublistView(theirs, 0, cipherStart);
  if (toHex(oursHead) != toHex(theirsHead)) {
    bad('$label 明文头不一致',
        '期望 ${toHex(theirsHead)}\n        实际 ${toHex(oursHead)}');
    return false;
  }

  final oursTail = Uint8List.sublistView(ours, ours.length - trailerLen);
  final theirsTail = Uint8List.sublistView(theirs, theirs.length - trailerLen);
  if (toHex(oursTail) != toHex(theirsTail)) {
    bad('$label 尾部不一致', '期望 ${toHex(theirsTail)}，实际 ${toHex(oursTail)}');
    return false;
  }

  final oursCipher =
      Uint8List.sublistView(ours, cipherStart, ours.length - trailerLen);
  final theirsCipher =
      Uint8List.sublistView(theirs, cipherStart, theirs.length - trailerLen);
  try {
    final a = toHex(qqTeaDecrypt(oursCipher, key));
    final b = toHex(qqTeaDecrypt(theirsCipher, key));
    if (a != b) {
      bad('$label 密文解密后的明文不一致',
          '期望 $b\n        实际 $a');
      return false;
    }
  } on Object catch (e) {
    bad('$label 解密失败', '$e');
    return false;
  }
  return true;
}

/// 纯明文包：整体逐字节比较。
bool comparePlain(String label, Uint8List ours, Uint8List theirs) {
  final a = toHex(ours);
  final b = toHex(theirs);
  if (a == b) return true;
  bad('$label 不一致',
      '长度 ${theirs.length} vs ${ours.length}\n        期望 $b\n        实际 $a');
  return false;
}

// ---------------------------------------------------------------------------
// 1. ksid
// ---------------------------------------------------------------------------

void testKsid() {
  section('1. ksid 派生');

  final ctx = buildContext();
  final ksid = ctx.ksid;
  if (String.fromCharCodes(ksid) == _ksidAscii) {
    ok('ksid = |IMEI|apkName', _ksidAscii);
  } else {
    bad('ksid 不一致', '实际 ${String.fromCharCodes(ksid)}');
  }
}

// ---------------------------------------------------------------------------
// 2. OICQ 层信封
// ---------------------------------------------------------------------------

void testOicqPacket() {
  section('2. OICQ 层信封（8 条向量）');

  final ctx = buildContext();
  var n = 0;

  for (final v in _oicqVectors) {
    final body = _bodies[v.name]!;
    final ours = Qq8Sso.buildOicqPacket(ctx, body, emp: v.emp);
    final theirs = hex(v.hex);
    final label = '${v.emp ? 'emp' : 'ecdh'}/${
        v.name}'; // ignore: unnecessary_brace_in_string_interps

    final bool passed;
    if (v.emp) {
      // emp 分支：28 字节固定头 + [u16(16) + sigKey(16)] + 密文 + 尾 1 字节
      passed = compareWithCipher(
        label,
        ours,
        theirs,
        cipherStart: 28 + 2 + 16,
        trailerLen: 1,
        key: ctx.sig.ticketKey,
      );
    } else {
      // ecdh 分支：28 + [2 + 16 + 2 + 2 + (2+65)] = 28+89
      passed = compareWithCipher(
        label,
        ours,
        theirs,
        cipherStart: 28 + 89,
        trailerLen: 1,
        key: ctx.ecdhShareKey,
      );
    }
    if (passed) ok(label, '${theirs.length} 字节');
    n++;
  }
  stdout.writeln('     共 $n 条');
}

// ---------------------------------------------------------------------------
// 3. 登录层信封
// ---------------------------------------------------------------------------

void testLoginPacket() {
  section('3. 登录层信封（3 条向量，覆盖 type 0/1/2）');

  final ctx = buildContext();
  const cmd = 'wtlogin.trans_emp';
  final body = _bodies['medium']!;

  for (final v in _loginVectors) {
    final ours = Qq8Sso.buildLoginPacket(ctx, cmd, body, v.type);
    final theirs = hex(v.hex);
    final label = 'type=${v.type}';

    final bool passed;
    if (v.type == Qq8LoginType.heartbeat) {
      // type=0 不加密，整包逐字节比
      passed = comparePlain(label, ours, theirs);
    } else {
      // 外层 27 字节（u32 len + 0x0A + type + u32 d2len + d2 + 0 + u32 uinlen + uin）
      final key = v.type == Qq8LoginType.online
          ? ctx.sig.d2key
          : Uint8List(16);
      passed = compareWithCipher(
        label,
        ours,
        theirs,
        cipherStart: 4 + 4 + 1 + 8 + 1 + 9,
        trailerLen: 0,
        key: key,
      );
    }
    if (passed) ok(label, '${theirs.length} 字节');
  }
}

// ---------------------------------------------------------------------------
// 4. 结构自洽
// ---------------------------------------------------------------------------

void testStructure() {
  section('4. 结构自洽');

  final ctx = buildContext();
  final pkt = Qq8Sso.buildOicqPacket(ctx, _bodies['medium']!);
  final r = _Reader(pkt);

  final b0 = r.u8();
  final len = r.u16();
  final proto = r.u16();
  final cmd = r.u16();

  if (b0 == 0x02) {
    ok('首字节 0x02');
  } else {
    bad('首字节', '实际 0x${b0.toRadixString(16)}');
  }
  // 该长度字段**包含整包**（含首字节与它自己），不是"总长 − 1"
  if (len == pkt.length) {
    ok('长度字段 = 整包长度', 'len=$len 总长=${pkt.length}');
  } else {
    bad('长度字段', 'len=$len，总长=${pkt.length}');
  }
  if (proto == qq8ProtocolVersion) {
    ok('协议版本 8001');
  } else {
    bad('协议版本', '实际 $proto');
  }
  if (cmd == qq8CmdWtLogin) {
    ok('命令字 0x810');
  } else {
    bad('命令字', '实际 0x${cmd.toRadixString(16)}');
  }
  if (pkt.last == 0x03) {
    ok('尾部固定 0x03');
  } else {
    bad('尾字节', '实际 0x${pkt.last.toRadixString(16)}');
  }

  // BUF_UNKNOWN 只出现在**登录层信封**里，必须原样写入、不能被清零
  final lp0 = Qq8Sso.buildLoginPacket(
      ctx, 'wtlogin.trans_emp', Uint8List(0), 0);
  final lpHex = toHex(lp0);
  final unknownHex =
      qq8BufUnknown.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  if (lpHex.contains(unknownHex)) {
    ok('登录信封内 BUF_UNKNOWN 原样写入（12 字节）', unknownHex);
  } else {
    bad('BUF_UNKNOWN', '包内未找到 $unknownHex');
  }

  // 登录信封的 uin 必须以「含自身的长度前缀 + ASCII」形式出现
  if (lpHex.contains('000000093130303031')) {
    ok('uin 字段：len=9（4+5）前缀 + "10001"');
  } else {
    bad('登录信封 uin 字段', '未找到 000000093130303031');
  }

  // 长度前缀必须含自身：d2 是 4 字节，前缀应为 8
  if (lpHex.contains('00000008d2d2d2d2')) {
    ok('d2 字段：len=8（4+4）前缀 + 4 字节值');
  } else {
    bad('d2 字段长度前缀', '未找到 00000008d2d2d2d2');
  }
}

class _Reader {
  final Uint8List _b;
  int _p = 0;
  _Reader(this._b);

  int get pos => _p;

  int u8() => _b[_p++];
  int u16() {
    final v = (_b[_p] << 8) | _b[_p + 1];
    _p += 2;
    return v;
  }

  int u32() {
    final v = (_b[_p] << 24) | (_b[_p + 1] << 16) | (_b[_p + 2] << 8) | _b[_p + 3];
    _p += 4;
    return v;
  }

  void skip(int n) => _p += n;
}

/// 相等断言（沿用 ok/bad 的计数口径）。
void checkEq(String name, Object? actual, Object? expected) {
  final okv = '$actual' == '$expected';
  if (okv) {
    ok(name);
  } else {
    bad(name, '期望 $expected，实际 $actual');
  }
}

// ---------------------------------------------------------------------------
// 5. UNI 包（业务包）——黄金向量来自 oicq `buildUniPkt`
// ---------------------------------------------------------------------------

/// 由 `../analysis/scripts/gen_uni_vector.cjs` 生成（可重跑）。
///
/// 固定输入：uin=10001、cmd=`StatSvc.register`、seq=2、session=`01020304`、
/// d2key=`00112233445566778899aabbccddeeff`、body=`deadbeef`。
const String _uniGoldenHex =
    '0000004f0000000b0100000002000000000931303030314ce56dbc9860ec2ee82a493d'
    'fae5c5713dd2916b5256c0d3dd926530dbdbb621e52124d4b9652482566e46d746ab'
    '59224ba7f27112591bce';

void testUniPacket() {
  section('5. UNI 包（业务包，黄金向量来自 oicq buildUniPkt）');

  final d2key = hex('00112233445566778899aabbccddeeff');
  final pkt = Qq8Uni.build(
    uin: 10001,
    cmd: 'StatSvc.register',
    body: hex('deadbeef'),
    seq: 2,
    session: hex('01020304'),
    d2key: d2key,
  );
  final theirs = hex(_uniGoldenHex);

  // 明文头（前 23 字节 = 18 头 + uin 5 字节）逐字节一致；
  // TEA 区含任意填充，按本文件既有的口径比较**解密后的明文**。
  checkEq('长度一致', pkt.length, theirs.length);
  checkEq('明文头逐字节一致（前 23 字节）',
      toHex(pkt.sublist(0, 23)), toHex(theirs.sublist(0, 23)));
  checkEq(
      'TEA 区解密后一致',
      toHex(qqTeaDecrypt(pkt.sublist(23), d2key)),
      toHex(qqTeaDecrypt(theirs.sublist(23), d2key)));

  // ---- 结构自洽（不依赖黄金向量）----
  final r = _Reader(pkt);
  checkEq('首 4 字节声明总长 = 实体', r.u32(), pkt.length);
  checkEq('服务类型标记 0x0B', r.u32(), 0x0B);
  checkEq('常量 1', r.u8(), 1);
  checkEq('seq', r.u32(), 2);
  checkEq('常量 0', r.u8(), 0);
  checkEq('uin 长度前缀 = 4 + 5', r.u32(), 9);
  checkEq('uin ASCII', String.fromCharCodes(pkt.sublist(18, 23)), '10001');

  // 内层 SSO 块：用 d2key 解密后逐字段核对（与收包侧 parseSSO 对偶）
  final inner = qqTeaDecrypt(pkt.sublist(23), d2key);
  final ir = _Reader(inner);
  checkEq('SSO headlen = cmdLen + 20', ir.u32(), 36);
  final cmdLen = ir.u32();
  checkEq('cmd 长度前缀 = 4 + 16', cmdLen, 20);
  final cmd = String.fromCharCodes(inner.sublist(8, 8 + cmdLen - 4));
  checkEq('cmd 回读一致', cmd, 'StatSvc.register');
  ir.skip(cmdLen - 4);
  checkEq('session 长度前缀 = 8', ir.u32(), 8);
  checkEq('session 内容', toHex(inner.sublist(ir.pos, ir.pos + 4)), '01020304');
  ir.skip(4);
  checkEq('固定字段 = 4', toHex(inner.sublist(ir.pos, ir.pos + 4)), '00000004');
  ir.skip(4);
  checkEq('body 长度前缀 = 4 + 4', ir.u32(), 8);
  checkEq('body 回读', toHex(inner.sublist(ir.pos, ir.pos + 4)), 'deadbeef');

  // 序号推进
  checkEq('nextSeq(1) = 2', Qq8Uni.nextSeq(1), 2);
  checkEq('nextSeq(0x7FFF) 回绕到 1', Qq8Uni.nextSeq(0x7FFF), 1);
}

// ---------------------------------------------------------------------------

void main() {
  stdout.writeln('QQ 8.2.11 SSO 包构建离线自测');
  stdout.writeln('=' * 66);
  stdout.writeln('黄金向量由运行 oicq 原始 lib/wtlogin/wt.js 生成；');
  stdout.writeln('含 TEA 密文的部分比较解密后的明文（密文含任意填充，不可比）。');

  testKsid();
  testOicqPacket();
  testLoginPacket();
  testStructure();
  testUniPacket();

  stdout.writeln('\n${'=' * 66}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
