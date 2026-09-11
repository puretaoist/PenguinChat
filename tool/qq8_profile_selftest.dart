/// 多版本客户端档案自测
///
/// 锁定 `qq8_profiles.dart` 里的四个档案，并**逐项验证版本差异真的只体现在
/// 该体现的地方**——即：
///
/// | 检查 | 目的 |
/// |---|---|
/// | TLV 顺序表关系 | 8.2.11 ≡ 8.9.50（37 项）；9.3.60 ≡ TIM（38 项 = 37 + 0x553） |
/// | `ssoVer` | 7 / 19 / 22 / 22，且同时出现在 `0x100` 与 `0x106` 的确定偏移 |
/// | `0x116` | 只带 `miscBitmap` 与 `subSigMap`，三代相同 |
/// | `0x544` | 降级 body：8.2.11 = `00 00 00 00`；8.9.50/TIM = 空 |
/// | `0x553` | 仅 9.3.60/TIM 有，降级 = `00` |
/// | 灯塔 appkey | 8.2.11 == 8.9.50 == TIM（故 TIM 的 QIMEI 通用） |
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/qq8_profile_selftest.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/crypto/digest.dart';
import 'package:qqclient/kernel/crypto/tea.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_profiles.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tlv.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  ✓ $name');
  } else {
    _failed++;
    stdout.writeln('  ✗ $name${detail == null ? '' : '  ($detail)'}');
  }
}

Uint8List _fill(int n, int v) =>
    Uint8List.fromList(List<int>.filled(n, v));

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

int _u32be(Uint8List b, int off) =>
    (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];

const int _fixedNow = 1600000000000;

/// 用给定档案构造一个确定性的 TLV 上下文。
Qq8TlvContext _context(Qq8ClientProfile p) {
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
    imsi: _fill(16, 0x22),
    tgtgt: _hex('ffeeddccbbaa99887766554433221100'),
    guid: _hex('00112233445566778899aabbccddeeff'),
  );

  return Qq8TlvContext(
    uin: 10001,
    apk: p.apk,
    device: device,
    passwordMd5: _fill(16, 0x11),
    seqId: 100,
    ksid: _fill(16, 0x33),
    t104: _hex('0102030405060708'),
    t174: _hex('aabbccdd'),
    tgt: _hex('1122334455667788'),
    srmToken: _hex('99aabbcc'),
    randomBytes: (n) => _fill(n, 0xab),
    teaPadding: (n) => _fill(n, 0),
    nowMillis: () => _fixedNow,
  );
}

/// TLV 0x106 的 TEA 密钥 = `MD5(guid(16) ‖ u64(uin 或 msalt))`。
Uint8List _key106(Qq8TlvContext ctx) {
  final seed = Uint8List(24);
  seed.setRange(0, 16, ctx.device.guid);
  seed[16] = (ctx.uin >> 56) & 0xff;
  seed[17] = (ctx.uin >> 48) & 0xff;
  seed[18] = (ctx.uin >> 40) & 0xff;
  seed[19] = (ctx.uin >> 32) & 0xff;
  seed[20] = (ctx.uin >> 24) & 0xff;
  seed[21] = (ctx.uin >> 16) & 0xff;
  seed[22] = (ctx.uin >> 8) & 0xff;
  seed[23] = ctx.uin & 0xff;
  return md5Bytes(seed);
}

final List<Qq8ClientProfile> _all = <Qq8ClientProfile>[
  qq8ProfileQQ8211,
  qq8ProfileQQ8950,
  qq8ProfileQQ9360,
  qq8ProfileTim410,
];

void main() {
  stdout.writeln('=' * 66);
  stdout.writeln('QQ 多版本客户端档案自测');
  stdout.writeln('=' * 66);

  // -- 1. 档案自洽 --------------------------------------------------------
  stdout.writeln('\n【1】档案字段自洽');
  for (final p in _all) {
    check(
      '${p.label}：subAppId 与 apk.subid 一致（${p.subAppId}）',
      p.subAppId == p.apk.subid,
      'profile=${p.subAppId} apk=${p.apk.subid}',
    );
    check(
      '${p.label}：appid 恒为 16',
      p.apk.appid == 16,
      '${p.apk.appid}',
    );
    check(
      '${p.label}：三个 sigmap 与官方一致',
      p.apk.miscBitmap == 150470524 &&
          p.apk.mainSigMap == 16724722 &&
          p.apk.subSigMap == 66560,
      '${p.apk.miscBitmap}/${p.apk.mainSigMap}/${p.apk.subSigMap}',
    );
    check(
      '${p.label}：qua 里嵌的 versionCode 与档案一致',
      p.qua.contains('_${p.versionCode}_'),
      p.qua,
    );
  }

  // -- 2. TLV 顺序表关系 --------------------------------------------------
  stdout.writeln('\n【2】登录 TLV 顺序表');
  check(
    '8.2.11 与 8.9.50 的表逐项相同',
    qq8ProfileQQ8211.apk.loginTlvOrder.join(',') ==
        qq8ProfileQQ8950.apk.loginTlvOrder.join(','),
  );
  check(
    '8.2.11 表长 37',
    qq8ProfileQQ8211.apk.loginTlvOrder.length == 37,
    '${qq8ProfileQQ8211.apk.loginTlvOrder.length}',
  );
  for (final p in <Qq8ClientProfile>[qq8ProfileQQ9360, qq8ProfileTim410]) {
    final t = p.apk.loginTlvOrder;
    check(
      '${p.label} 表长 38',
      t.length == 38,
      '${t.length}',
    );
    check(
      '${p.label} 前 37 项与 8.2.11 相同',
      t.sublist(0, 37).join(',') ==
          qq8ProfileQQ8211.apk.loginTlvOrder.join(','),
    );
    check(
      '${p.label} 第 38 项是 0x553',
      t.last == 0x553,
      '0x${t.last.toRadixString(16)}',
    );
  }
  check(
    '0x553 不在 8.2.11/8.9.50 的表里',
    !qq8ProfileQQ8211.apk.loginTlvOrder.contains(0x553) &&
        !qq8ProfileQQ8950.apk.loginTlvOrder.contains(0x553),
  );

  // -- 3. ssoVer ---------------------------------------------------------
  stdout.writeln('\n【3】ssoVer');
  const expectedVer = <String, int>{
    'QQ 8.2.11 (Play)': 7,
    'QQ 8.9.50': 19,
    'QQ 9.3.60': 22,
    'TIM 4.1.0.4050': 22,
  };
  for (final p in _all) {
    check(
      '${p.label}：ssoVer = ${expectedVer[p.label]}',
      p.apk.ssoVer == expectedVer[p.label],
      '${p.apk.ssoVer}',
    );
  }

  // -- 4. 版本差异真的落到字节上 -------------------------------------------
  stdout.writeln('\n【4】版本差异落到实际字节');
  for (final p in _all) {
    final ctx = _context(p);

    // 0x100：u16 db_buf_ver | u32 sso_ver | ...
    final b100 = Qq8Tlv.body(ctx, 0x100);
    check(
      '${p.label}：0x100 body[2..6) == ssoVer',
      _u32be(b100, 2) == p.apk.ssoVer,
      '0x${_u32be(b100, 2).toRadixString(16)}',
    );
    check(
      '${p.label}：0x100 的 db_buf_ver = 1',
      b100[0] == 0 && b100[1] == 1,
    );

    // 0x106：TEA 密文，解密后 u16 tgtgt_ver | u32 rnd | u32 sso_ver | ...
    final b106 = Qq8Tlv.body(ctx, 0x106);
    final plain = qqTeaDecrypt(b106, _key106(ctx));
    check(
      '${p.label}：0x106 可解开',
      plain.length > 10,
      'len=${plain.length}',
    );
    check(
      '${p.label}：0x106 plain[6..10) == ssoVer',
      _u32be(plain, 6) == p.apk.ssoVer,
      '0x${_u32be(plain, 6).toRadixString(16)}',
    );
    check(
      '${p.label}：0x106 的 tgtgt_ver = 4',
      plain[0] == 0 && plain[1] == 4,
    );

    // 0x116：u8(0) | u32 miscBitmap | u32 subSigMap | ...
    final b116 = Qq8Tlv.body(ctx, 0x116);
    check(
      '${p.label}：0x116 miscBitmap 正确',
      _u32be(b116, 1) == 150470524,
      '0x${_u32be(b116, 1).toRadixString(16)}',
    );
    check(
      '${p.label}：0x116 subSigMap 正确',
      _u32be(b116, 5) == 66560,
      '0x${_u32be(b116, 5).toRadixString(16)}',
    );

    // 0x544：降级 body
    final b544 = Qq8Tlv.body(ctx, 0x544);
    check(
      '${p.label}：0x544 降级 body 长度 = ${p.apk.tlv544DegradedBody.length}',
      b544.length == p.apk.tlv544DegradedBody.length,
      'len=${b544.length}',
    );

    // 0x553：只有 9.3.60 / TIM 有
    final b553 = Qq8Tlv.body(ctx, 0x553);
    final want553 = p.apk.tlv553DegradedBody;
    check(
      '${p.label}：0x553 body 符合档案（${want553 ?? '不发'}）',
      want553 == null
          ? b553.isEmpty
          : (b553.length == want553.length && b553[0] == want553[0]),
      'len=${b553.length}',
    );
  }

  // 8.2.11 的 0x544 必须是 4 个零字节
  final b544a = Qq8Tlv.body(_context(qq8ProfileQQ8211), 0x544);
  check(
    '8.2.11 的 0x544 = 00 00 00 00（ByteData.getCode 降级）',
    b544a.length == 4 && b544a.every((v) => v == 0),
    b544a.map((v) => v.toRadixString(16).padLeft(2, '0')).join(' '),
  );
  // 8.9.50 的 0x544 必须为空
  final b544b = Qq8Tlv.body(_context(qq8ProfileQQ8950), 0x544);
  check(
    '8.9.50 的 0x544 为空（liteSign 初值 new byte[0]）',
    b544b.isEmpty,
    'len=${b544b.length}',
  );
  // 9.3.60 的 0x553 必须是单字节 00
  final b553c = Qq8Tlv.body(_context(qq8ProfileQQ9360), 0x553);
  check(
    '9.3.60 的 0x553 = 00（getFeKitAttach 失败返回 byte[]{0}）',
    b553c.length == 1 && b553c[0] == 0,
    b553c.map((v) => v.toRadixString(16).padLeft(2, '0')).join(' '),
  );

  // -- 4b. 0x545 QIMEI 取值方式随版本变 -----------------------------------
  stdout.writeln('\n【4b】0x545 QIMEI 的取值方式');
  const sample = '3F2A9C8B1D4E6075A1B2C3D4E5F60718ABCD';
  final q8211 =
      Qq8Tlv.body(_context(qq8ProfileQQ8211), 0x545, const <Object?>[sample]);
  final q8950 =
      Qq8Tlv.body(_context(qq8ProfileQQ8950), 0x545, const <Object?>[sample]);
  check(
    '8.2.11 的 0x545 = MD5(qimei 原文)，16 字节',
    q8211.length == 16 &&
        q8211.join(',') ==
            md5Bytes(Uint8List.fromList(utf8.encode(sample))).join(','),
    'len=${q8211.length}',
  );
  check(
    '8.9.50 的 0x545 = qimei 原文（不哈希）',
    q8950.length == sample.length && String.fromCharCodes(q8950) == sample,
    'len=${q8950.length}',
  );
  check(
    '两者长度不同 → 确属协议差异，不是实现细节',
    q8211.length != q8950.length,
    '${q8211.length} vs ${q8950.length}',
  );
  for (final p in _all) {
    final empty = Qq8Tlv.body(_context(p), 0x545);
    check(
      '${p.label}：拿不到 QIMEI 时 0x545 为空 body（同官方 listener==null 行为）',
      empty.isEmpty,
      'len=${empty.length}',
    );
  }

  // -- 5. 灯塔 appkey ----------------------------------------------------
  stdout.writeln('\n【5】灯塔 appkey（旧 Beacon）');
  check(
    '8.2.11 与 8.9.50 的 APPKEY_DENGTA 相同',
    qq8ProfileQQ8211.beaconAppKey == qq8ProfileQQ8950.beaconAppKey,
    '${qq8ProfileQQ8211.beaconAppKey} / ${qq8ProfileQQ8950.beaconAppKey}',
  );
  check(
    'appkey = 0S200MNJT807V3GE',
    qq8ProfileQQ8211.beaconAppKey == '0S200MNJT807V3GE',
  );
  check(
    '9.3.60 manifest 里没有 APPKEY_DENGTA（运行时下发）',
    qq8ProfileQQ9360.beaconAppKey.isEmpty,
  );
  // 实机取证更正：这个 appkey 只属于旧 Beacon。
  // 8.9.50+ 的 QIMEI 走新 SDK，appkey 是每 app 一套的 0AND0* 形态
  // （TIM = 0AND063BSR94DSGA，QQ 8.9.50 的 dex 里没有它）
  // ⇒ TIM 的 QIMEI 不能用于 QQ 客户端。
  check(
    'TIM 与 8.2.11 的 APPKEY_DENGTA 相同（仅旧 Beacon 层面）',
    qq8ProfileTim410.beaconAppKey == qq8ProfileQQ8211.beaconAppKey,
  );

  // -- 6. 未验证字段必须被显式标注 ----------------------------------------
  stdout.writeln('\n【6】未核实字段必须显式标注');
  for (final p in _all) {
    if (p.apk.buildtime == 0 && !p.unverified.contains('buildtime')) {
      check('${p.label}：buildtime 未知却未标注', false);
    } else {
      check('${p.label}：缺失项已标注（${p.unverified.isEmpty ? '无' : p.unverified.join('/')}）', true);
    }
  }
  check(
    '默认档案是 8.9.50',
    identical(qq8DefaultProfile, qq8ProfileQQ8950),
    qq8DefaultProfile.label,
  );
  check('档案表有 4 项', qq8ClientProfiles.length == 4);

  // -- 7. sign（TLV 0x142）跨版本 -----------------------------------------
  stdout.writeln('\n【7】sign（TLV 0x142）跨版本');
  String hexOf(List<int> b) =>
      b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  const qqCert = 'a6b745bf24a2c277527716f6f36eb68d';
  const timCert = '775e696d09856872fdd8ab4f3f06b1e0';
  for (final p in <Qq8ClientProfile>[
    qq8ProfileQQ8211,
    qq8ProfileQQ8950,
    qq8ProfileQQ9360,
  ]) {
    check(
      '${p.label}：sign = 腾讯同一张 QQ 证书',
      hexOf(p.apk.sign) == qqCert,
      hexOf(p.apk.sign),
    );
  }
  check(
    'TIM 用另一张证书（不是 QQ 那张）',
    hexOf(qq8ProfileTim410.apk.sign) == timCert,
    hexOf(qq8ProfileTim410.apk.sign),
  );
  check(
    'TIM 的 sign ≠ QQ 的 sign',
    hexOf(qq8ProfileTim410.apk.sign) != hexOf(qq8ProfileQQ8950.apk.sign),
  );

  // -- 汇总 --------------------------------------------------------------
  stdout.writeln('\n${'=' * 66}');
  stdout.writeln('通过 $_passed 项，失败 $_failed 项');
  if (_failed == 0) {
    stdout.writeln('四版本档案一致 ✓');
  }
  exitCode = _failed == 0 ? 0 : 1;
}
