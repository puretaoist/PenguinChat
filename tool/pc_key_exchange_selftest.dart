// PC NTLogin 第 1 步（KeyExchange）的离线自测。
//
// 覆盖四件能离线证明的事：
//   1. P-256 ECDH 双方协商一致（证明曲线/点编解码实现对）
//   2. AES-GCM 往返 + 信封格式 IV(12)‖ct‖tag(16)
//   3. protobuf 编解码往返（字段号/线类型对）
//   4. KeyExchange.build 自洽：产出的 secret 能用同一 sharedKey 解回 {uin,guid}
//
// **不能离线证明的**：服务端是否接受（那要连真实服务器，另行授权）。
import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/kernel/wlogin8/pc/pc_crypto.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_key_exchange.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_proto.dart';

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

bool _bytesEq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  section('1. P-256 ECDH：双方协商一致');
  {
    final a = PcEcdh.generate();
    final b = PcEcdh.generate();
    check('公钥是 65 字节未压缩点（0x04 开头）',
        a.publicKey.length == 65 && a.publicKey[0] == 0x04,
        '${a.publicKey.length} 字节，首字节 ${a.publicKey[0]}');
    final s1 = PcEcdh.sharedSecret(a, b.publicKey);
    final s2 = PcEcdh.sharedSecret(b, a.publicKey);
    checkEq('A 与 B 协商出的秘密长度', s1.length, 32);
    check('A 与 B 协商结果相同', _bytesEq(s1, s2));
  }

  section('2. AES-GCM：往返 + 信封格式');
  {
    final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final plain = Uint8List.fromList('hello 腾讯 NTLogin'.codeUnits);
    final iv = Uint8List.fromList(List<int>.filled(12, 7));
    final env = PcAesGcm.encrypt(key, plain, iv: iv);
    checkEq('信封长度 = 12 + 明文 + 16',
        env.length, 12 + plain.length + 16);
    check('前 12 字节是 IV', _bytesEq(Uint8List.sublistView(env, 0, 12), iv));
    final dec = PcAesGcm.decrypt(key, env);
    check('解密还原明文', _bytesEq(dec, plain));

    // 错误 key 必须解不开（GCM 有认证标签）
    var threw = false;
    try {
      PcAesGcm.decrypt(
        Uint8List.fromList(List<int>.filled(32, 9)),
        env,
      );
    } on Object {
      threw = true;
    }
    check('错误 key 解密必须失败（认证标签）', threw);

    // 随机 IV：两次加密同一明文应得不同密文
    final e1 = PcAesGcm.encrypt(key, plain);
    final e2 = PcAesGcm.encrypt(key, plain);
    check('随机 IV → 两次密文不同', !_bytesEq(e1, e2));
  }

  section('3. protobuf：编解码往返');
  {
    final guid = Uint8List.fromList(List<int>.generate(16, (i) => 0xA0 + i));
    final w = PbWriter()
      ..writeString(1, '10001')
      ..writeBytes(2, guid)
      ..writeInt(3, 1234567890)
      ..writeBytes(5, Uint8List.fromList([1, 2, 3]));
    final r = PbReader(w.toBytes());
    String? f1;
    Uint8List? f2;
    int? f3;
    Uint8List? f5;
    while (!r.atEnd) {
      final (field, wire) = r.readTag();
      switch (field) {
        case 1:
          f1 = r.readString();
        case 2:
          f2 = r.readBytes();
        case 3:
          f3 = r.readVarint();
        case 5:
          f5 = r.readBytes();
        default:
          r.skip(wire);
      }
    }
    checkEq('string 字段往返', f1, '10001');
    check('bytes 字段往返', f2 != null && _bytesEq(f2, guid));
    checkEq('varint 字段往返', f3, 1234567890);
    check('多字节 bytes 往返', f5 != null && _bytesEq(f5, Uint8List.fromList([1, 2, 3])));

    // 未知字段必须能跳过（向后兼容）
    final w2 = PbWriter()
      ..writeInt(9, 42) // 未知字段
      ..writeString(1, 'x');
    final r2 = PbReader(w2.toBytes());
    String? got;
    while (!r2.atEnd) {
      final (field, wire) = r2.readTag();
      if (field == 1) {
        got = r2.readString();
      } else {
        r2.skip(wire);
      }
    }
    checkEq('跳过未知字段后仍能读到后面的字段', got, 'x');
  }

  section('4. KeyExchange.build：结构自洽');
  {
    // 与实现里同一份服务端公钥（测试里独立复制，用于自洽验证）
    final serverPub = PcKeyExchange.debugServerPublicKey;
    final guid = Uint8List.fromList(List<int>.generate(16, (i) => i));
    final req = PcKeyExchange.build(
      uin: '10001',
      guid: guid,
      timestamp: 1700000000,
    );

    // 解析请求，验证 5 个字段齐全且类型对
    Uint8List? pub;
    int? type;
    Uint8List? secret;
    int? ts;
    Uint8List? verifyHash;
    final r = PbReader(req.bytes);
    while (!r.atEnd) {
      final (field, wire) = r.readTag();
      switch (field) {
        case 1:
          pub = r.readBytes();
        case 2:
          type = r.readVarint();
        case 3:
          secret = r.readBytes();
        case 4:
          ts = r.readVarint();
        case 5:
          verifyHash = r.readBytes();
        default:
          r.skip(wire);
      }
    }
    check('字段1 publicKey 是 65 字节', pub != null && pub.length == 65);
    check('字段1 publicKey 与 keyPair 一致',
        pub != null && _bytesEq(pub, req.keyPair.publicKey));
    checkEq('字段2 type = 1', type, 1);
    check('字段3 secret 非空（AES-GCM 信封）',
        secret != null && secret.length > 12 + 16);
    checkEq('字段4 timestamp = 1700000000', ts, 1700000000);
    check('字段5 verifyHash 是 AES-GCM 信封（>28B）',
        verifyHash != null && verifyHash.length > 12 + 16);

    // 自洽：用同一 keyPair + 服务端公钥算出 sharedKey，能解回 {uin, guid}
    final sharedKey = PcEcdh.sharedSecret(req.keyPair, serverPub);
    final inner = PcAesGcm.decrypt(sharedKey, secret!);
    final ir = PbReader(inner);
    String? uin;
    Uint8List? g;
    while (!ir.atEnd) {
      final (field, wire) = ir.readTag();
      switch (field) {
        case 1:
          uin = ir.readString();
        case 2:
          g = ir.readBytes();
        default:
          ir.skip(wire);
      }
    }
    checkEq('secret 解回 uin', uin, '10001');
    check('secret 解回 guid', g != null && _bytesEq(g, guid));
  }

  section('5. 确定性：同私钥+同服务端公钥 → 同秘密');
  {
    final kp = PcEcdh.generate();
    final serverPub = PcKeyExchange.debugServerPublicKey;
    final a = PcEcdh.sharedSecret(kp, serverPub);
    final b = PcEcdh.sharedSecret(kp, serverPub);
    check('同一私钥两次协商结果相同', _bytesEq(a, b));

    // 非法公钥必须拒绝
    var threw = false;
    try {
      PcEcdh.sharedSecret(kp, Uint8List(64));
    } on Object {
      threw = true;
    }
    check('64 字节公钥（非未压缩点）必须被拒绝', threw);
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
