// PC 扫码模块的离线自测：secp192k1 ECDH + TLV + FetchQRCode body 结构。
import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/kernel/wlogin8/pc/pc_qr_tlv.dart';

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

void main() {
  section('1. secp192k1：基本形态');
  {
    final kx = PcSecp192k1.exchange();
    check('shareKey 是 16 字节（MD5）', kx.shareKey.length == 16,
        '${kx.shareKey.length}');
    check('压缩公钥是 25 字节（1 + 24）', kx.publicKeyCompressed.length == 25,
        '${kx.publicKeyCompressed.length}');
    check('压缩公钥首字节 0x02/0x03',
        kx.publicKeyCompressed[0] == 0x02 || kx.publicKeyCompressed[0] == 0x03,
        '${kx.publicKeyCompressed[0].toRadixString(16)}');
    check('固定 bob 公钥 49 字节',
        PcSecp192k1.bobPublicKey.length == 49,
        '${PcSecp192k1.bobPublicKey.length}');
  }

  section('2. secp192k1：两次交换 shareKey 不同（随机密钥对）');
  {
    final a = PcSecp192k1.exchange();
    final b = PcSecp192k1.exchange();
    var same = true;
    for (var i = 0; i < 16; i++) {
      if (a.shareKey[i] != b.shareKey[i]) same = false;
    }
    check('两次交换的 shareKey 应不同（密钥随机）', !same);
  }

  section('3. TLV 构建：结构');
  {
    final guid = Uint8List.fromList(List<int>.generate(16, (i) => 0x30 + i));
    final tlv = pcBuildTlvQrCode(
      appId: 1600001615,
      subAppId: 537313942,
      mainSigMap: 169742560,
      ssoVersion: 19,
      packageName: 'com.tencent.qq',
      ptVersion: '2.0.0',
      os: 'Linux',
      deviceName: 'DESKTOP',
      guid: guid,
    );
    // TLV 包 = u16(count) + TLVs
    final count = (tlv[0] << 8) | tlv[1];
    check('TLV 数量 = 7', count == 7, '$count');
    // 解析回来验证键
    final m = pcReadTlv(tlv);
    final keys = m.keys.toList()..sort();
    check('含 0x16/1b/1d/33/35/66/D1',
        keys.contains(0x16) &&
            keys.contains(0x1b) &&
            keys.contains(0x1d) &&
            keys.contains(0x33) &&
            keys.contains(0x35) &&
            keys.contains(0x66) &&
            keys.contains(0xD1),
        keys.map((k) => '0x${k.toRadixString(16)}').join(','));
    check('0x1d 长度 = 1+4+4+1 = 10', m[0x1d]!.length == 10, '${m[0x1d]!.length}');
    check('0x35 长度 = 4（u32 ssoVersion）', m[0x35]!.length == 4,
        '${m[0x35]!.length}');
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
