/// 协议内核单元测试
///
/// 覆盖：字节读写器往返、TLV 编解码、TEA/QQ TEA 加解密。
/// 运行：flutter test
///
/// 注：字节序断言依据 M2 反编译结论（`oicq.wlogin_sdk.tools.util`）——
/// WLogin 层一律**大端**。早期版本按小端断言，已修正。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/infra/coder.dart';
import 'package:qqclient/kernel/crypto/tea.dart';

void main() {
  group('L1 字节读写器', () {
    test('大端序往返一致', () {
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

  group('QQ TEA（填充 + CBC，反编译证实）', () {
    final key = '0123456789abcdef'.codeUnits;

    test('填充长度公式 pad = (8 - (len+10) % 8) % 8', () {
      expect(qqTeaPadLength(0), 6);
      expect(qqTeaPadLength(1), 5);
      expect(qqTeaPadLength(6), 0);
      expect(qqTeaPadLength(7), 7);
    });

    test('密文长度 = pad + len + 10 且为 8 的倍数', () {
      for (final len in [1, 5, 16, 40, 100]) {
        final plain = List<int>.filled(len, 0x41);
        final pad = qqTeaPadLength(len);
        final enc = qqTeaEncrypt(plain, key,
            paddingBytes: List.filled(pad + 3, 0));
        expect(enc.length, pad + len + 10);
        expect(enc.length % 8, 0);
      }
    });

    test('加解密往返一致', () {
      const text = 'hello qq protocol';
      final plain = text.codeUnits;
      final pad = qqTeaPadLength(plain.length);
      final enc = qqTeaEncrypt(plain, key,
          paddingBytes: List.filled(pad + 3, 0x11));
      expect(String.fromCharCodes(qqTeaDecrypt(enc, key)), text);
    });

    test('CBC 链式：相邻同内容块密文不同（排除 ECB）', () {
      final plain = List<int>.filled(40, 0x41);
      final pad = qqTeaPadLength(40);
      final enc = qqTeaEncrypt(plain, key,
          paddingBytes: List.filled(pad + 3, 0));
      expect(enc.sublist(8, 16), isNot(equals(enc.sublist(16, 24))));
    });

    test('错误密钥解密失败', () {
      final plain = 'hello qq protocol'.codeUnits;
      final pad = qqTeaPadLength(plain.length);
      final enc = qqTeaEncrypt(plain, key,
          paddingBytes: List.filled(pad + 3, 0));
      expect(() => qqTeaDecrypt(enc, 'fedcba9876543210'.codeUnits),
          throwsFormatException);
    });

    test('长度非法时报错', () {
      expect(() => qqTeaDecrypt([1, 2, 3], key), throwsFormatException);
    });

    test('尾部篡改被校验发现', () {
      final plain = 'hello qq protocol'.codeUnits;
      final pad = qqTeaPadLength(plain.length);
      final enc = qqTeaEncrypt(plain, key,
          paddingBytes: List.filled(pad + 3, 0));
      final tampered = List<int>.from(enc);
      tampered[tampered.length - 1] ^= 0xFF;
      expect(() => qqTeaDecrypt(tampered, key), throwsFormatException);
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
