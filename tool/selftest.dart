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
import '../lib/kernel/transport/transport.dart';
import '../lib/kernel/wlogin/login_commands.dart';
import '../lib/kernel/wlogin/tlv.dart';
import '../lib/kernel/wlogin/tlv_types.dart';

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

Future<void> main() async {
  print('=== 协议内核自测（Dart）===');

  print('\n[L1] 字节读写器（默认大端，反编译证实）');
  {
    final w = ByteWriter()
      ..u8(0x12)
      ..u16(0x3456)
      ..u32(0x789ABCDE)
      ..bytes16([1, 2, 3]);
    final r = ByteReader(w.build());
    check('u8/u16/u32 往返', r.readUint8() == 0x12 && r.readUint16() == 0x3456 && r.readUint32() == 0x789ABCDE);
    check('长度前缀字节串往返', r.readBytesWithLen16().join(',') == '1,2,3');
    check('读到末尾无残留', r.remaining == 0);

    // 大端字节布局：高字节在前
    final be = (ByteWriter()..u16(0x0104)..u32(0x789ABCDE)).build();
    check('大端 u16 0x0104 -> 01 04', be.sublist(0, 2).join(',') == '1,4', be.sublist(0, 2).join(','));
    check('大端 u32 布局', be.sublist(2, 6).join(',') == '120,154,188,222', be.sublist(2, 6).join(','));

    // 显式小端变体仍可用
    final le = (ByteWriter()..u16le(0x0104)).build();
    check('显式小端 u16 0x0104 -> 04 01', le.join(',') == '4,1', le.join(','));
    check('显式小端读取一致', ByteReader(le).readUint16Le() == 0x0104);

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
    // 大端：[cmd 0x0104 -> 01 04][len 4 -> 00 04]
    check('TLV 头大端布局 = 01 04 00 04',
        data.sublist(0, 4).join(',') == '1,4,0,4',
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
    check('长度只计 body 不含头',
        back.get(0x104)!.encode().length == 4 + 4);
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

  print('\n[M2] TLV 编号注册表');
  {
    check('注册表项数 == 113', tlvRegistry.length == 113, '${tlvRegistry.length}');
    // 派生校验：类名后缀的十六进制值必须等于 map 的 key
    var mismatch = <String>[];
    tlvRegistry.forEach((type, cls) {
      final suffix = cls.replaceFirst('tlv_t', '');
      final expected = int.parse(suffix, radix: 16);
      if (expected != type) mismatch.add('$cls -> 0x${type.toRadixString(16)}');
    });
    check('全部 113 项「类名后缀 == 编号」自洽', mismatch.isEmpty,
        mismatch.take(3).join('; '));
    // 反编译已证实的锚点：tlv_t104 的 CMD_104 常量 == 260 == 0x0104
    check('锚点 tlv_t104 存在且编号 0x0104', tlvRegistry[0x104] == 'tlv_t104');
    check('锚点 tlv_t106 存在且编号 0x0106', tlvRegistry[0x106] == 'tlv_t106');
    check('语义表条目均属注册表',
        tlvSemantics.keys.every(tlvRegistry.containsKey));
    check('语义表条目数合理（>25）', tlvSemantics.length > 25,
        '${tlvSemantics.length}');
  }

  print('\n[M2] 登录命令字');
  {
    check('命令字总数 == 14', LoginSsoCommand.all.length == 14,
        '${LoginSsoCommand.all.length}');
    check('无重复命令字',
        LoginSsoCommand.all.toSet().length == LoginSsoCommand.all.length);
    check('全部以 EcdhService.SsoNTLogin 或 Sso 开头',
        LoginSsoCommand.all.every((c) => c.startsWith('EcdhService.')));
    check('登录入口 4 种',
        LoginSsoCommand.entryPoints.length == 4);
    check('返回码描述可用',
        LoginResultCode.describe(LoginResultCode.success) == '成功' &&
            LoginResultCode.describe(0x99).contains('未知'));
    check('登录阶段枚举完整（10 态）', LoginStage.values.length == 10,
        '${LoginStage.values.length}');
  }

  print('\n[M2] 传输层（回环实现）');
  {
    final t = LoopbackTransport();
    check('初始为未连接', t.state == TransportState.disconnected);

    var threw = false;
    try {
      await t.send(0x825, Uint8List(0));
    } catch (_) {
      threw = true;
    }
    check('未连接时 send 抛异常', threw);

    await t.connect();
    check('连接后状态正确', t.state == TransportState.connected);

    t.on(0x825, (body) => Uint8List.fromList([0xAA, 0xBB]));
    final rsp = await t.send(0x825, Uint8List.fromList([1, 2, 3]));
    check('响应按命令字回填', rsp.join(',') == '170,187', rsp.join(','));
    check('请求已记录', t.sent.length == 1 && t.sent.first.command == 0x825);

    final empty = await t.send(0x999, Uint8List(0));
    check('未注册命令返回空响应', empty.isEmpty);

    await t.close();
    check('关闭后状态为 closed', t.state == TransportState.closed);
  }

  print('\n[M2] QQ TEA（填充 + CBC，反编译证实）');
  {
    // 填充公式：pad = (8 - (len + 10) % 8) % 8
    check('填充长度公式 len=0 -> 6', qqTeaPadLength(0) == 6, '${qqTeaPadLength(0)}');
    check('填充长度公式 len=1 -> 5', qqTeaPadLength(1) == 5, '${qqTeaPadLength(1)}');
    check('填充长度公式 len=6 -> 0', qqTeaPadLength(6) == 0, '${qqTeaPadLength(6)}');
    check('填充长度恒在 0..7', [
      for (var i = 0; i < 64; i++) qqTeaPadLength(i)
    ].every((p) => p >= 0 && p <= 7));

    final key = '0123456789abcdef'.codeUnits;
    const text = 'hello qq protocol';
    final plain = text.codeUnits;

    // 注入确定性填充，便于断言结构
    final pad = qqTeaPadLength(plain.length);
    final filler = List<int>.generate(3 + pad, (i) => 0x10 + i);
    final enc = qqTeaEncrypt(plain, key, paddingBytes: filler);

    check('密文长度 = pad + len + 10',
        enc.length == pad + plain.length + 10,
        '${enc.length} vs ${pad + plain.length + 10}');
    check('密文长度为 8 的倍数', enc.length % 8 == 0);
    check('密文 != 明文', enc.join(',') != plain.join(','));

    final back = qqTeaDecrypt(enc, key);
    check('解密还原明文', String.fromCharCodes(back) == text,
        String.fromCharCodes(back));

    // 错误密钥必须解密失败（尾部 7 字节非零校验）
    final wrongKey = 'fedcba9876543210'.codeUnits;
    var threwWrong = false;
    try {
      qqTeaDecrypt(enc, wrongKey);
    } catch (_) {
      threwWrong = true;
    }
    check('错误密钥解密失败', threwWrong);

    // 零 IV 的 CBC：相同明文块的密文应因链式而不同
    final long = List<int>.filled(40, 0x41);
    final e2 = qqTeaEncrypt(long, key,
        paddingBytes: List.filled(qqTeaPadLength(40) + 3, 0));
    final c0 = e2.sublist(0, 8).join(',');
    final c1 = e2.sublist(8, 16).join(',');
    check('CBC 链式：相邻块密文不同（非 ECB）', c0 != c1);

    // 非法输入
    var threw = false;
    try {
      qqTeaDecrypt([1, 2, 3], key);
    } catch (_) {
      threw = true;
    }
    check('长度非法时报错', threw);

    // 篡改尾部导致校验失败
    final tampered = List<int>.from(enc);
    tampered[tampered.length - 1] ^= 0xFF;
    var throwT = false;
    try {
      qqTeaDecrypt(tampered, key);
    } catch (_) {
      throwT = true;
    }
    check('尾部校验能发现篡改', throwT);

    // 大端序：验证字解析方向
    final words = bytesToU32BE([0x01, 0x02, 0x03, 0x04]);
    check('大端字解析 01020304 -> 0x01020304',
        words[0] == 0x01020304, '0x${words[0].toRadixString(16)}');
    check('大端往返一致',
        u32ToBytesBE(words).join(',') == '1,2,3,4');
  }

  print('\n=== 结果: $_passed 通过, $_failed 失败 ===');
  if (_failed > 0) {
    throw StateError('存在失败用例');
  }
  print('全部通过 ✓ 内核基础层可用');
}
