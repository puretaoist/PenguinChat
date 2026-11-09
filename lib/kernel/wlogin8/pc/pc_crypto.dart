/// PC NTLogin 链路专用的密码学封装。
///
/// ## 与老线（`crypto/ecdh.dart`）的区别，为什么不能复用
///
/// 老线的 `Ecdh.exchange` 返回的是 **`MD5(共享秘密[0..16])`**（16 字节）——
/// 那是 **旧 wtlogin TLV** 的用法（0x106 的 TEA 密钥派生）。
///
/// **PC NTLogin 用的是「原始 32 字节共享秘密」直接作 AES-256-GCM 的 key**，
/// 不做 MD5。出处：Acidify `internal/service/system/KeyExchange.kt`
/// ```kotlin
/// val sharedKey = prime256V1.keyExchange(serverPublicKey, false)   // 原始秘密
/// AesGcmProvider.encrypt(..., sharedKey, ...)
/// ```
/// 若误用老线的 MD5 版，密钥长度和内容都不对，服务端必然解不开。
///
/// 所以这里独立实现一份，避免改动老线（老线 100% 自测通过，不能碰）。
///
/// ## AES-GCM 的信封格式（必须与 Acidify 一致）
///
/// 出处：Acidify `internal/crypto/aes/AesGcmProvider.kt`
/// ```
/// encrypt: IV(12) ‖ ciphertext ‖ tag(16)
/// decrypt: 前 12 字节为 IV，末 16 字节为 tag，中间为密文
/// ```
/// 若格式不同（例如把 tag 放前面），服务端解不开。
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 一次 P-256 密钥对。
class PcEcdhKeyPair {
  const PcEcdhKeyPair({required this.privateKey, required this.publicKey});

  final ECPrivateKey privateKey;

  /// 65 字节未压缩点（首字节 0x04）。
  final Uint8List publicKey;
}

/// P-256（prime256v1 / secp256r1）ECDH。
///
/// **必须暴露密钥对**：KeyExchange 要做两次协商 ——
///   ① 用本次生成的私钥 + 硬编码服务端公钥 → 加密请求
///   ② 用**同一个私钥** + 响应里的服务端公钥 → 解密响应
/// 两次必须是同一对密钥，所以不能像老线那样「一次 exchange 返回结果」。
abstract final class PcEcdh {
  static final ECDomainParameters _domain = ECCurve_prime256v1();

  /// 生成一对 P-256 密钥。
  static PcEcdhKeyPair generate() {
    final priv = _generatePrivate();
    final ownPoint = _domain.G * priv.d;
    if (ownPoint == null || ownPoint.isInfinity) {
      throw StateError('由私钥导出的公钥点无效');
    }
    return PcEcdhKeyPair(
      privateKey: priv,
      publicKey: ownPoint.getEncoded(false),
    );
  }

  /// 用 [kp] 的私钥与 [serverPublicKey] 协商，返回**原始 32 字节共享秘密**（不做 MD5）。
  static Uint8List sharedSecret(PcEcdhKeyPair kp, Uint8List serverPublicKey) {
    if (serverPublicKey.length != 65 || serverPublicKey[0] != 0x04) {
      throw ArgumentError(
        '服务端公钥必须是 65 字节未压缩点（首字节 0x04），'
        '实际 ${serverPublicKey.length} 字节',
      );
    }
    final serverPoint = _decodePoint(serverPublicKey);
    final agreement = ECDHBasicAgreement()..init(kp.privateKey);
    final secret =
        agreement.calculateAgreement(ECPublicKey(serverPoint, _domain));
    return _encodeBigInt(secret, 32);
  }

  static ECPrivateKey _generatePrivate() {
    final secure = Random.secure();
    final seed = Uint8List(32);
    for (var i = 0; i < seed.length; i++) {
      seed[i] = secure.nextInt(256);
    }
    final fortuna = FortunaRandom()..seed(KeyParameter(seed));
    final gen = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(_domain), fortuna));
    return gen.generateKeyPair().privateKey as ECPrivateKey;
  }

  static ECPoint _decodePoint(Uint8List encoded) {
    final x = _bytesToBigInt(Uint8List.sublistView(encoded, 1, 33));
    final y = _bytesToBigInt(Uint8List.sublistView(encoded, 33, 65));
    final point = _domain.curve.createPoint(x, y);
    if (point.isInfinity) {
      throw ArgumentError('服务端公钥解出的点落在无穷远点');
    }
    return point;
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var r = BigInt.zero;
    for (final b in bytes) {
      r = (r << 8) | BigInt.from(b);
    }
    return r;
  }

  static Uint8List _encodeBigInt(BigInt v, int length) {
    final out = Uint8List(length);
    var x = v;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x = x >> 8;
    }
    return out;
  }
}

/// AES-GCM，与 Acidify 的 `AesGcmProvider` 同格式。
abstract final class PcAesGcm {
  static const int ivSize = 12;
  static const int tagSize = 16;

  /// 加密，返回 `IV(12) ‖ ciphertext ‖ tag(16)`。
  ///
  /// [iv] 不给时随机生成（生产路径）；测试可传固定值复现。
  static Uint8List encrypt(
    Uint8List key,
    Uint8List plain, {
    Uint8List? iv,
  }) {
    final useIv = iv ?? _randomBytes(ivSize);
    if (useIv.length != ivSize) {
      throw ArgumentError('AES-GCM IV 必须是 $ivSize 字节');
    }
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(KeyParameter(key), tagSize * 8, useIv, Uint8List(0)),
      );
    final out = cipher.process(plain); // ciphertext ‖ tag
    final result = Uint8List(ivSize + out.length);
    result.setRange(0, ivSize, useIv);
    result.setRange(ivSize, result.length, out);
    return result;
  }

  /// 解密，输入必须是 `IV(12) ‖ ciphertext ‖ tag(16)`。
  static Uint8List decrypt(Uint8List key, Uint8List envelope) {
    if (envelope.length < ivSize + tagSize) {
      throw ArgumentError('AES-GCM 信封至少 ${ivSize + tagSize} 字节');
    }
    final iv = Uint8List.sublistView(envelope, 0, ivSize);
    final body = Uint8List.sublistView(envelope, ivSize);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(KeyParameter(key), tagSize * 8, iv, Uint8List(0)),
      );
    return cipher.process(body);
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = r.nextInt(256);
    }
    return out;
  }
}

/// SHA-256。
Uint8List pcSha256(Uint8List data) {
  final d = SHA256Digest()..update(data, 0, data.length);
  final out = Uint8List(d.digestSize);
  d.doFinal(out, 0);
  return out;
}
