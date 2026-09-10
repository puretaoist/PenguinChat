/// M1 内核自测（不依赖 Flutter 引擎，纯 Dart 运行）
///
/// 运行：dart run tool/selftest.dart
/// 说明：flutter_test 需要 flutter_tester 进程（部分受限环境无法启动），
///       本脚本用纯 Dart 断言覆盖同样的内核逻辑，便于在任意环境验证。
// ignore_for_file: avoid_print, avoid_relative_lib_imports
library;

import 'dart:typed_data';

import '../lib/infra/coder.dart';
import '../lib/kernel/crypto/tea.dart';
import '../lib/kernel/wlogin/tlv.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    print('  [OK] $name');
  } else {
    _failed++;
    print('  [FAIL] $name${detail == null ? '' : ' -> $detail'}');
  }
}

void main() {
  print('=== M1 协议内核自测（Dart）===');

  print('\n[L1] 字节读写器');
  {
    final w = ByteWriter()
      ..u8(0x12)
      ..u16(0x3456)
      ..u32(0x789ABCDE)
      ..bytes16([1, 2, 3]);
    final r = ByteReader(w.build());
    check('小端序 u8/u16/u32 往返', r.readUint8() == 0x12 && r.readUint16() == 0x3456 && r.readUint32() == 0x789ABCDE);
    check('长度前缀字节串往返', r.readBytesWithLen16().join(',') == '1,2,3');
    check('读到末尾无残留', r.remaining == 0);
    var threw = false;
    try {
      ByteReader([1, 2, 3]).read(5);
    } catch (_) {
      threw = true;
    }
    check('越界读取抛出异常', threw);
  }

  print('\n[L2] TLV 编解码');
  {
    final pkt = TlvPacket()
      ..add(0x104, [0x01, 0x02, 0x03, 0x04])
      ..add(0x106, List.filled(16, 0xAA))
      ..add(0x116, 'device-id-test'.codeUnits);
    final data = pkt.encode();
    check('首字段字节布局 = 04 01 04 00',
        data.sublist(0, 4).join(',') == '4,1,4,0',
        data.sublist(0, 4).join(','));

    final back = TlvPacket.decode(data);
    check('解码后字段数一致', back.length == 3);
    check('tlv_t104 值还原', back.get(0x104)!.value.join(',') == '1,2,3,4');
    check('tlv_t106 长度 16', back.get(0x106)!.value.length == 16);
    check('tlv_t116 字符串还原',
        String.fromCharCodes(back.get(0x116)!.value) == 'device-id-test');
    check('TLV 命名规则 tlv_t104', back.get(0x104)!.name == 'tlv_t104');
    check('已知常量表 >= 20 项', tlvKnownTypes.length >= 20);
    check('容错模式不抛异常', TlvPacket.decode([0x04, 0x01, 0xFF, 0xFF, 0x01]).length == 0);
  }

  print('\n[L2] TEA 加密');
  {
    final key = '0123456789abcdef'.codeUnits;
    final plain = '0123456789abcdef'.codeUnits;
    final enc = teaEncrypt(plain, key);
    check('密文 != 明文', enc.join(',') != plain.join(','));
    check('解密还原成功', teaDecrypt(enc, key).join(',') == plain.join(','));
    check('ECB 确定性（同输入同输出）', teaEncrypt(plain, key).join(',') == enc.join(','));
    print('       明文: 0123456789abcdef');
    print('       密文: ${enc.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
    var threw = false;
    try {
      teaEncrypt([1, 2, 3, 4], [1, 2, 3]);
    } catch (_) {
      threw = true;
    }
    check('非法密钥长度报错', threw);

    final xplain = 'hello qq protocol world!'.codeUnits;
    final xenc = xxteaEncrypt(xplain, key);
    check('XXTEA 往返一致',
        xxteaDecrypt(xenc, key).sublist(0, xplain.length).join(',') == xplain.join(','));
  }

  print('\n[调试工具] hexdump');
  {
    final out = hexdump(Uint8List.fromList([0x48, 0x65, 0x6C, 0x6C, 0x6F]));
    check('十六进制部分正确', out.contains('48 65 6c 6c 6f'));
    check('ASCII 部分正确', out.contains('|Hello|'));
  }

  print('\n=== 结果: $_passed 通过, $_failed 失败 ===');
  if (_failed > 0) {
    throw StateError('存在失败用例');
  }
  print('全部通过 ✓ 内核基础层可用');
}
