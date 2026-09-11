/// L2 协议内核：ECDH 密钥交换
///
/// ## 在 QQ 登录流程里的位置
///
/// 登录的第一个往返就要做密钥协商：
///
/// ```text
///   1. 客户端生成临时 EC 密钥对（prime256v1 / secp256r1）
///   2. share_key = MD5( ECDH(自己的私钥, 服务端固定公钥)[0..16) )
///   3. 用自己的公钥 + share_key 加密 TLV 载荷
///   4. 把公钥放进 TLV 0x128 发给服务端，服务端推出同一个 share_key
/// ```
///
/// 第 2 步的细节容易写错：是**截取共享秘密的前 16 字节再取 MD5**，
/// 而不是对完整 32 字节取 MD5。
///
/// ## 为什么不用 native 库
///
/// QQ 把这个算法放在 `libwtecdh.so`（8.2.11 里 17,800 字节）里，
/// 但它引用的是 `libcrypto.so` 的 OpenSSL 原语：
///
/// ```text
///   EC_KEY_new_by_curve_name / EC_KEY_generate_key / ECDH_compute_key
/// ```
///
/// 也就是说它没有自己的算法，只是 OpenSSL 的薄包装。用 pointycastle
/// 重写等价且不引入 native 依赖。
///
/// ## 对照实现
///
/// `takayama-lily/oicq` 的 `lib/wtlogin/ecdh.js`（513 字节，纯 JS）：
///
/// ```js
/// const ecdh = createECDH("prime256v1");
/// this.public_key = ecdh.generateKeys();
/// this.share_key = md5(ecdh.computeSecret(OICQ_PUBLIC_KEY).slice(0, 16));
/// ```
///
/// 本文件用固定私钥的黄金向量与之交叉验证（见 `tool/qq8_selftest.dart`）。
///
/// 本文件是纯 Dart，不依赖 Flutter。
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'digest.dart';

/// 保持既有 import 路径可用：摘要函数已迁至 `digest.dart`。
export 'digest.dart' show md5Bytes;

/// 一次 ECDH 密钥对及其与指定服务端公钥协商出的共享密钥。
class EcdhKeyPair {
  /// 自己生成的公钥（未压缩形式，65 字节，首字节 `0x04`）。
  ///
  /// 这个值要作为 TLV 0x128 的内容发给服务端。
  final Uint8List publicKey;

  /// 与服务端公钥协商出的 16 字节共享密钥。
  ///
  /// 用于 `tea.encrypt(body, shareKey)`。
  final Uint8List shareKey;

  const EcdhKeyPair({required this.publicKey, required this.shareKey});

  @override
  String toString() =>
      'EcdhKeyPair(pub=${publicKey.length}B, share=${shareKey.length}B)';
}

/// prime256v1（= NIST P-256 = secp256r1）上的 ECDH。
///
/// QQ 全系客户端都用这条曲线；不是可选参数，因此本类不暴露曲线选择。
class Ecdh {
  /// 曲线参数。
  static final ECDomainParameters domain = ECCurve_prime256v1();

  /// 用 [privateKey]（32 字节大端标量）对 [serverPublicKey] 协商共享密钥。
  ///
  /// [privateKey] 为空时随机生成密钥对。
  ///
  /// [serverPublicKey] 是服务端的公钥，未压缩形式（65 字节，首字节 `0x04`）。
  /// QQ 8.2.11 的值见 `Qq8Config.serverEcdhPublicKey`。
  static EcdhKeyPair exchange(
    Uint8List serverPublicKey, {
    Uint8List? privateKey,
  }) {
    if (serverPublicKey.length != 65 || serverPublicKey[0] != 0x04) {
      throw ArgumentError(
        '服务端公钥必须是 65 字节的未压缩点（首字节 0x04），'
        '实际 ${serverPublicKey.length} 字节，首字节 '
        '${serverPublicKey.isEmpty ? 'N/A' : '0x${serverPublicKey[0].toRadixString(16)}'}',
      );
    }

    final priv = privateKey == null
        ? _generatePrivate()
        : ECPrivateKey(_decodeScalar(privateKey), domain);

    // pointycastle 的 ECPrivateKey 不提供 publicKey，公钥点自己算：Q = G * d
    // （ECPoint 的乘法运算符返回可空值，需要显式判空）
    final ownPoint = domain.G * priv.d;
    if (ownPoint == null || ownPoint.isInfinity) {
      throw StateError('由私钥导出的公钥点无效');
    }
    final serverPoint = _decodePoint(serverPublicKey);

    final agreement = ECDHBasicAgreement()..init(priv);
    final secret = agreement.calculateAgreement(ECPublicKey(serverPoint, domain));

    final secretBytes = _encodeBigInt(secret, 32);
    final seed = Uint8List.sublistView(secretBytes, 0, 16);

    return EcdhKeyPair(
      publicKey: ownPoint.getEncoded(false),
      shareKey: md5Bytes(seed),
    );
  }

  /// 随机生成一个私钥标量。
  static ECPrivateKey _generatePrivate() {
    // 用 dart:math 的密码学安全随机源播种，避开 pointycastle
    // SecureRandom 构造函数在不同版本间的签名差异。
    final secure = Random.secure();
    final seed = Uint8List(32);
    for (var i = 0; i < seed.length; i++) {
      seed[i] = secure.nextInt(256);
    }
    final fortuna = FortunaRandom()..seed(KeyParameter(seed));
    final gen = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(domain), fortuna));
    return gen.generateKeyPair().privateKey as ECPrivateKey;
  }

  /// 把 32 字节大端标量解成 BigInt。
  static BigInt _decodeScalar(Uint8List bytes) {
    if (bytes.length != 32) {
      throw ArgumentError('私钥必须是 32 字节，实际 ${bytes.length}');
    }
    return _bytesToBigInt(bytes);
  }

  /// 从 65 字节未压缩点构造 [ECPoint]。
  ///
  /// 刻意手工构造 X/Y 而不用 `curve.decodePoint`：后者的
  /// `encodedType` 参数在不同版本语义不一致，手工构造没有歧义。
  static ECPoint _decodePoint(Uint8List encoded) {
    final x = _bytesToBigInt(Uint8List.sublistView(encoded, 1, 33));
    final y = _bytesToBigInt(Uint8List.sublistView(encoded, 33, 65));
    final point = domain.curve.createPoint(x, y);
    if (point.isInfinity) {
      throw ArgumentError('服务端公钥解出的点落在无穷远点');
    }
    return point;
  }

  /// 把非负 BigInt 按大端补零成定长字节。
  static Uint8List _encodeBigInt(BigInt v, int length) {
    final out = Uint8List(length);
    var n = v;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (n & BigInt.from(0xff)).toInt();
      n = n >> 8;
    }
    if (n != BigInt.zero) {
      throw ArgumentError('数值超出 $length 字节');
    }
    return out;
  }

  /// 大端字节 → BigInt。
  static BigInt _bytesToBigInt(Uint8List bytes) {
    var r = BigInt.zero;
    for (final b in bytes) {
      r = (r << 8) | BigInt.from(b);
    }
    return r;
  }
}

/// MD5 的实现在 `digest.dart`，此处仅 re-export（见文件顶部）。
