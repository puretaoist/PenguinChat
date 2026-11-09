/// PC NTLogin 的第一步：`trpc.login.ecdh.EcdhService.SsoKeyExchange`。
///
/// ## 这一步是什么
///
/// 登录前先做一次 ECDH 密钥交换，拿到后续所有 NTLogin 请求要用的
/// `sessionTicket`（会话票据）与 `sessionKey`（AES-GCM 密钥）。
/// 它**不涉及账号密码**，只提交 uin + guid。
///
/// ## 全部依据（逐行对过 Acidify）
///
/// 服务：`internal/service/system/KeyExchange.kt`
/// 消息：`internal/proto/login/NTEcdh.kt`
///
/// 流程：
/// ```text
/// ① 客户端生成 P-256 密钥对 (priv, publicKey)
/// ② sharedKey = ECDH(priv, serverPublicKey)              // 原始 32B，不 MD5
/// ③ secret    = AES-GCM( KeyExchangeRequestBuf{uin, guid}, sharedKey )
/// ④ verifyPkt = publicKey ‖ i32be(1) ‖ secret ‖ i32be(0) ‖ u32be(timestamp)
/// ⑤ verifyHash= AES-GCM( SHA256(verifyPkt), verifyHashKey )
/// ⑥ 请求      = KeyExchangeRequest{ 1:publicKey, 2:type=1, 3:secret,
///                                   4:timestamp, 5:verifyHash }
/// ⑦ 响应      = KeyExchangeResponse{ 1:secret, 2:field2, 3:publicKey }
///    sharedKey2 = ECDH(priv, response.publicKey)          // 同一个 priv
///    secret2    = AES-GCM.decrypt(response.secret, sharedKey2)
///                = KeyExchangeResponseSecret{ 1:sessionKey, 2:sessionTicket, 3:expiration }
/// ```
///
/// **两个易错点**（写错了就解不开，且报错不会指这里）：
/// - `KeyExchangeResponse` 的 `publicKey` 在字段 **3**，不是 2；`secret` 在字段 1。
/// - `KeyExchangeResponseSecret` 的 `sessionKey` 在字段 **1**、`sessionTicket` 在 **2**。
library;

import 'dart:typed_data';

import 'pc_crypto.dart';
import 'pc_proto.dart';

/// 一次 KeyExchange 的产物。
class PcKeyExchangeResult {
  const PcKeyExchangeResult({
    required this.sessionKey,
    required this.sessionTicket,
    required this.expiration,
  });

  /// AES-GCM 密钥（后续 NTLogin 的 buffer 用它加解密）。
  final Uint8List sessionKey;

  /// 会话票据（NTLoginForwardRequest.field 1）。
  final Uint8List sessionTicket;

  /// 过期时间（服务端给的秒级时间戳，0 表示未给）。
  final int expiration;
}

/// 待发送的 KeyExchange 请求。
class PcKeyExchangeRequest {
  const PcKeyExchangeRequest({
    required this.bytes,
    required this.keyPair,
  });

  /// protobuf 编码后的 KeyExchangeRequest body。
  final Uint8List bytes;

  /// 本次用的密钥对——解析响应时必须用同一个（第二次协商）。
  final PcEcdhKeyPair keyPair;
}

abstract final class PcKeyExchange {
  /// 硬编码服务端公钥（P-256 未压缩点，65 字节）。
  /// 出处：Acidify `internal/service/system/KeyExchange.kt` 的 `serverPublicKey`。
  static const String _serverPublicKeyHex =
      '049d1423332735980edabe7e9ea451b3395b6f35250db8fc56f25889f628cbae'
      '3e8e73077914071eeebc108f4e0170057792bb17aa303af652313d17c1ac815e'
      '79';

  /// verifyHash 的 AES-GCM 密钥（32 字节）。
  /// 出处：同上文件的 `verifyHashKey`。
  static const String _verifyHashKeyHex =
'e2733bf403149913cbf80c7a95168bd4ca6935ee53cd39764beebe2e007e3aee';

  /// 仅供自测：服务端公钥字节（避免测试里再抄一份常量而抄错）。
  static Uint8List get debugServerPublicKey => _hex(_serverPublicKeyHex);

  /// 构造请求。[guid] 是设备 guid（16 字节），[timestamp] 不给取当前秒。
  static PcKeyExchangeRequest build({
    required String uin,
    required Uint8List guid,
    int? timestamp,
  }) {
    final serverPub = _hex(_serverPublicKeyHex);
    final verifyKey = _hex(_verifyHashKeyHex);
    final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // ① 生成密钥对，② 与服务端协商
    final kp = PcEcdh.generate();
    final sharedKey = PcEcdh.sharedSecret(kp, serverPub);

    // ③ 加密 {uin, guid}
    final reqBuf = (PbWriter()
          ..writeString(1, uin)
          ..writeBytes(2, guid))
        .toBytes();
    final secret = PcAesGcm.encrypt(sharedKey, reqBuf);

    // ④ 拼 verifyPacket：publicKey ‖ i32be(1) ‖ secret ‖ i32be(0) ‖ u32be(ts)
    final vp = BytesBuilder(copy: false)
      ..add(kp.publicKey)
      ..add(_i32be(1))
      ..add(secret)
      ..add(_i32be(0))
      ..add(_u32be(ts));
    final verifyPacket = vp.toBytes();

    // ⑤ verifyHash = AES-GCM(SHA256(verifyPacket), verifyHashKey)
    final verifyHash = PcAesGcm.encrypt(verifyKey, pcSha256(verifyPacket));

    // ⑥ 请求 protobuf
    final req = (PbWriter()
          ..writeBytes(1, kp.publicKey)
          ..writeInt(2, 1)
          ..writeBytes(3, secret)
          ..writeInt(4, ts)
          ..writeBytes(5, verifyHash))
        .toBytes();

    return PcKeyExchangeRequest(bytes: req, keyPair: kp);
  }

  /// 解析响应。必须用 [request] 里同一个 [PcKeyExchangeRequest.keyPair]。
  static PcKeyExchangeResult parse({
    required Uint8List response,
    required PcEcdhKeyPair keyPair,
  }) {
    Uint8List? secret;
    Uint8List? serverPub;
    final r = PbReader(response);
    while (!r.atEnd) {
      final (field, wire) = r.readTag();
      switch (field) {
        case 1:
          secret = r.readBytes();
        case 3:
          serverPub = r.readBytes();
        default:
          r.skip(wire);
      }
    }
    if (secret == null || serverPub == null) {
      throw const FormatException('KeyExchange 响应缺 secret 或 publicKey');
    }

    // 第二次协商：同一个私钥 + 响应里的服务端公钥
    final sharedKey2 = PcEcdh.sharedSecret(keyPair, serverPub);
    final plain = PcAesGcm.decrypt(sharedKey2, secret);

    // 解 KeyExchangeResponseSecret：1=sessionKey, 2=sessionTicket, 3=expiration
    Uint8List sessionKey = Uint8List(0);
    Uint8List sessionTicket = Uint8List(0);
    var expiration = 0;
    final s = PbReader(plain);
    while (!s.atEnd) {
      final (field, wire) = s.readTag();
      switch (field) {
        case 1:
          sessionKey = s.readBytes();
        case 2:
          sessionTicket = s.readBytes();
        case 3:
          expiration = s.readVarint();
        default:
          s.skip(wire);
      }
    }
    return PcKeyExchangeResult(
      sessionKey: sessionKey,
      sessionTicket: sessionTicket,
      expiration: expiration,
    );
  }

  static Uint8List _hex(String s) {
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// 4 字节大端有符号 int（Kotlin `Buffer.writeInt` 的等价物）。
  static Uint8List _i32be(int v) {
    final out = Uint8List(4);
    out[0] = (v >> 24) & 0xff;
    out[1] = (v >> 16) & 0xff;
    out[2] = (v >> 8) & 0xff;
    out[3] = v & 0xff;
    return out;
  }

  /// 4 字节大端无符号 int（Kotlin `Buffer.writeUInt` 的等价物）。
  static Uint8List _u32be(int v) => _i32be(v & 0xffffffff);
}
