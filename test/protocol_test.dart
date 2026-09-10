/// 协议内核单元测试（M1 验收）
///
/// 覆盖：字节读写器往返、TLV 编解码、TEA/XXTEA 加解密。
/// 运行：flutter test
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/infra/coder.dart';
import 'package:qqclient/kernel/crypto/tea.dart';
import 'package:qqclient/kernel/wlogin/tlv.dart';

void main() {
  group('L1 字节读写器', () {
    test('小端序往返一致', () {
      final w = ByteWriter()
        ..u8(0x12)
        ..u16(0x3456)
        ..u32(0x789ABCDE)
        ..bytes16([1, 2, 3]);
      final r = ByteReader(w.build());
      expect(r.readUint8(), 0x12);
      expect(r.readUint16(), 0x3456);
      expect(r.readUint32(), 0x789ABCDE);
      expect(r.readBytesWithLen16(), [1, 2, 3]);
      expect(r.remaining, 0);
    });

    test('越界读取抛出异常', () {
      final r = ByteReader([1, 2, 3]);
      expect(() => r.read(5), throwsFormatException);
    });
  });

  group('L2 TLV 编解码', () {
    test('编码后字节布局符合小端约定，且能解码还原', () {
      final pkt = TlvPacket()
        ..add(0x104, [0x01, 0x02, 0x03, 0x04])
        ..add(0x106, List.filled(16, 0xAA))
        ..add(0x116, 'device-id-test'.codeUnits);

      final data = pkt.encode();
      // 首字段：type=0x104 -> 04 01, len=4 -> 04 00
      expect(data.sublist(0, 4), [0x04, 0x01, 0x04, 0x00]);

      final back = TlvPacket.decode(data);
      expect(back.length, 3);
      expect(back.get(0x104)!.value, [0x01, 0x02, 0x03, 0x04]);
      expect(back.get(0x106)!.value.length, 16);
      expect(back.get(0x116)!.value,
          'device-id-test'.codeUnits);
      expect(back.get(0x104)!.name, 'tlv_t104');
    });

    test('已知 TLV 常量表完整', () {
      expect(tlvKnownTypes.containsKey(0x104), true);
      expect(tlvKnownTypes.containsKey(0x106), true);
      expect(tlvKnownTypes.length >= 20, true);
    });

    test('容错模式遇到截断数据停止而不抛异常', () {
      final pkt = TlvPacket.decode([0x04, 0x01, 0xFF, 0xFF, 0x01]);
      expect(pkt.length, 0);
    });
  });

  group('L2 TEA 加密', () {
    final key = '0123456789abcdef'.codeUnits;

    test('TEA 加解密往返一致', () {
      final plain = '0123456789abcdef'.codeUnits;
      final enc = teaEncrypt(plain, key);
      expect(enc, isNot(equals(plain)));
      final dec = teaDecrypt(enc, key);
      expect(dec, equals(plain));
    });

    test('相同输入产生相同密文（ECB 特性）', () {
      final plain = '0123456789abcdef'.codeUnits;
      expect(teaEncrypt(plain, key), equals(teaEncrypt(plain, key)));
    });

    test('密钥长度非 16 字节时报错', () {
      expect(() => teaEncrypt([1, 2, 3, 4], [1, 2, 3]), throwsArgumentError);
    });

    test('XXTEA 加解密往返一致（含 padding）', () {
      final plain = 'hello qq protocol world!'.codeUnits; // 24 字节
      final enc = xxteaEncrypt(plain, key);
      final dec = xxteaDecrypt(enc, key);
      expect(dec.sublist(0, plain.length), equals(plain));
    });
  });

  group('协议调试工具', () {
    test('hexdump 输出格式正确', () {
      final out = hexdump(Uint8List.fromList([0x48, 0x65, 0x6C, 0x6C, 0x6F]));
      expect(out.contains('48 65 6c 6c 6f'), true);
      expect(out.contains('|Hello|'), true);
    });
  });
}
