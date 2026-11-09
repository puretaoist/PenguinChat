/// 扫码登录的 TLV 基础：secp192k1 ECDH + TLV 构建 + 扫码 7 个 TLV。
///
/// ## 出处（逐项核过 Acidify）
/// - `internal/service/system/WtLogin.kt`：扫码走 `wtlogin.trans_emp`，
///   内层 `TEA(payload, shareKey)`，`shareKey = MD5(ECDH(secp192k1, 固定公钥))`
/// - `internal/tlv/TlvBuilder.kt`：`TLV = u16(tag) ‖ u16(bodyLen) ‖ body`；
///   包 = `u16(tlvCount) ‖ 各 TLV`
/// - `internal/tlv/TlvQRCode.kt`：7 个 TLV 的 body 结构
/// - `internal/proto/login/TlvQRCodeBodyD1.kt`：`0xD1` 的 pb
///
/// ⚠️ **曲线是 secp192k1（不是 P-256）**。KeyExchange 用 P-256，扫码用 secp192k1。
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../../crypto/digest.dart';
import 'pc_proto.dart';

/// secp192k1 ECDH（扫码专用）。
abstract final class PcSecp192k1 {
  static final ECDomainParameters domain = ECCurve_secp192k1();

  /// 服务端固定公钥（未压缩 49 字节）。
  /// 出处：Acidify `WtLogin.kt` 的 `secp192k1BobPublicKey`。
  static const String bobPublicKeyHex =
      '04928D8850673088B343264E0C6BACB8496D697799F37211DEB25BB73906CB089F'
      'EA9639B4E0260498B51A992D50813DA8';

  static Uint8List get bobPublicKey => _hex(bobPublicKeyHex);

  static ECPrivateKey _generatePrivate() {
    // FortunaRandom.seed 要求 32 字节种子（与曲线字段大小无关）。
    final seed = Uint8List(32);
    final r = Random.secure();
    for (var i = 0; i < 32; i++) {
      seed[i] = r.nextInt(256);
    }
    final fortuna = FortunaRandom()..seed(KeyParameter(seed));
    final gen = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(domain), fortuna));
    return gen.generateKeyPair().privateKey as ECPrivateKey;
  }

  /// 生成密钥对 + 计算 shareKey（`MD5(ECDH)`，16 字节）。
  static ({Uint8List publicKeyCompressed, Uint8List shareKey}) exchange() {
    return _exchangeWithSecret(null);
  }

  /// 仅供自测：用固定私钥协商，验证与标准 secp192k1 一致。
  static ({Uint8List publicKeyCompressed, Uint8List shareKey})
      debugExchangeWithSecret(Uint8List secret) => _exchangeWithSecret(secret);

  static ({Uint8List publicKeyCompressed, Uint8List shareKey})
      _exchangeWithSecret(Uint8List? secret) {
    final priv = secret == null
        ? _generatePrivate()
        : ECPrivateKey(
            BigInt.parse(secret.map((b) => b.toRadixString(16).padLeft(2, '0')).join(), radix: 16),
            domain,
          );
    final point = domain.G * priv.d;
    if (point == null || point.isInfinity) {
      throw StateError('secp192k1 公钥点无效');
    }
    final bob = _decodePoint(bobPublicKey);
    final agreement = ECDHBasicAgreement()..init(priv);
    final shared = agreement.calculateAgreement(ECPublicKey(bob, domain));
    final secretBytes = _encodeBigInt(shared, 24);
    return (
      publicKeyCompressed: point.getEncoded(true), // 25 字节
      shareKey: md5Bytes(secretBytes),
    );
  }

  static ECPoint _decodePoint(Uint8List encoded) {
    // 未压缩：0x04 ‖ X(24) ‖ Y(24)
    final x = _bytesToBigInt(Uint8List.sublistView(encoded, 1, 25));
    final y = _bytesToBigInt(Uint8List.sublistView(encoded, 25, 49));
    final p = domain.curve.createPoint(x, y);
    if (p.isInfinity) throw ArgumentError('服务端公钥解出无穷远点');
    return p;
  }

  static BigInt _bytesToBigInt(Uint8List b) {
    var r = BigInt.zero;
    for (final x in b) {
      r = (r << 8) | BigInt.from(x);
    }
    return r;
  }

  static Uint8List _encodeBigInt(BigInt v, int len) {
    final out = Uint8List(len);
    var x = v;
    for (var i = len - 1; i >= 0; i--) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x = x >> 8;
    }
    return out;
  }

  static Uint8List _hex(String s) {
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

/// TLV 构建器：`u16(tag) ‖ u16(bodyLen) ‖ body`，包 = `u16(count) ‖ ...`。
class PcTlvBuilder {
  final BytesBuilder _tlvs = BytesBuilder(copy: false);
  int _count = 0;

  void add(int tag, Uint8List body) {
    _count++;
    _tlvs
      ..addByte((tag >> 8) & 0xff)
      ..addByte(tag & 0xff)
      ..addByte((body.length >> 8) & 0xff)
      ..addByte(body.length & 0xff)
      ..add(body);
  }

  Uint8List build() {
    final out = BytesBuilder(copy: false)
      ..addByte((_count >> 8) & 0xff)
      ..addByte(_count & 0xff)
      ..add(_tlvs.toBytes());
    return out.toBytes();
  }
}

/// 解析 TLV 包：`u16(count) ‖ { u16 tag ‖ u16 len ‖ body }*`。
Map<int, Uint8List> pcReadTlv(Uint8List data) {
  final r = _R(data);
  final count = r.u16();
  final out = <int, Uint8List>{};
  for (var i = 0; i < count; i++) {
    final tag = r.u16();
    final len = r.u16();
    out[tag] = r.bytes(len);
  }
  return out;
}

/// 扫码的 7 个 TLV（`tlv11/16/1b/1d/33/35/66/D1`）。
///
/// 参数里 `appId/subAppId/mainSigMap/ssoVersion/packageName/ptVersion/os/deviceName/guid`
/// 由调用方传入（来自 profile + 设备身份）。
Uint8List pcBuildTlvQrCode({
  required int appId,
  required int subAppId,
  int? appIdQrCode,
  required int mainSigMap,
  required int ssoVersion,
  required String packageName,
  required String ptVersion,
  required String os,
  required String deviceName,
  required Uint8List guid,
  Uint8List? unusualSig,
}) {
  final b = PcTlvBuilder();

  if (unusualSig != null) {
    b.add(0x11, unusualSig);
  }

  // 0x16：appId/appIdQrCode/guid/包名/版本/包名（Diana/官方用 AppIdQrCode）
  b.add(0x16, _tlv16(appId, appIdQrCode ?? appId, guid, packageName, ptVersion));

  // 0x1b：二维码参数（固定值）
  b.add(
    0x1b,
    (ByteWriterBe()
          ..u32(0) // micro
          ..u32(0) // version
          ..u32(3) // size
          ..u32(4) // margin
          ..u32(72) // dpi
          ..u32(2) // eclevel
          ..u32(2) // hint
          ..u16(0))
        .build(),
  );

  // 0x1d：u8 1 ‖ i32 mainSigMap ‖ u32 0 ‖ u8 0
  b.add(
    0x1d,
    (ByteWriterBe()
          ..u8(1)
          ..u32(mainSigMap)
          ..u32(0)
          ..u8(0))
        .build(),
  );

  b.add(0x33, guid); // 0x33
  b.add(0x35, (ByteWriterBe()..u32(ssoVersion)).build()); // 0x35
  b.add(0x66, (ByteWriterBe()..u32(ssoVersion)).build()); // 0x66

  // 0xD1：pb{ 1: system{1:os,2:deviceName}, 4: typeBuf="3001" }
  final system = (PbWriter()
        ..writeString(1, os)
        ..writeString(2, deviceName))
      .toBytes();
  final d1 = (PbWriter()
        ..writeBytes(1, system)
        ..writeBytes(4, Uint8List.fromList([0x30, 0x01])))
      .toBytes();
  b.add(0xD1, d1);

  return b.build();
}

Uint8List _tlv16(
  int appId,
  int qrAppId,
  Uint8List guid,
  String packageName,
  String ptVersion,
) {
  final w = ByteWriterBe()
    ..u32(0) // uin 占位
    ..u32(appId)
    ..u32(qrAppId) // AppIdQrCode
    ..raw(guid);
  _writeStr16(w, packageName);
  _writeStr16(w, ptVersion);
  _writeStr16(w, packageName);
  return w.build();
}

void _writeStr16(ByteWriterBe w, String s) {
  final b = Uint8List.fromList(s.codeUnits);
  w
    ..u16(b.length)
    ..raw(b);
}

/// 大端字节写器（局部）。
class ByteWriterBe {
  final BytesBuilder _b = BytesBuilder(copy: false);
  void u8(int v) => _b.addByte(v & 0xff);
  void u16(int v) {
    _b
      ..addByte((v >> 8) & 0xff)
      ..addByte(v & 0xff);
  }

  void u32(int v) {
    _b
      ..addByte((v >> 24) & 0xff)
      ..addByte((v >> 16) & 0xff)
      ..addByte((v >> 8) & 0xff)
      ..addByte(v & 0xff);
  }

  void raw(List<int> d) => _b.add(d);
  Uint8List build() => _b.toBytes();
}

/// 小端读取器（局部）。
class _R {
  _R(this._d);
  final Uint8List _d;
  int _p = 0;

  int u8() => _d[_p++];

  int u16() {
    final v = (_d[_p] << 8) | _d[_p + 1];
    _p += 2;
    return v;
  }

  Uint8List bytes(int n) {
    final out = Uint8List.sublistView(_d, _p, _p + n);
    _p += n;
    return out;
  }
}
