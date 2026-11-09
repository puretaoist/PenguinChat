/// 扫码登录：`wtlogin.trans_emp` 信封 + FetchQRCode（subCmd 0x31）。
///
/// ## 出处
/// Acidify `internal/service/system/WtLogin.kt`：
/// - `WtLogin` 基类：内层 `TEA(payload, shareKey)`，`shareKey=MD5(ECDH(secp192k1))`
/// - `TransEmp.buildWtLoginPayload` / `parseWtLoginPayload`
/// - `FetchQRCode.buildCode2DPayload`（subCmd 0x31）
///
/// ## 双层结构（务必分清）
/// ```
/// 外层 SSO：PcSso.buildRequest12(command='wtlogin.trans_emp', payload=wtLogin)
/// 内层 wtLogin：u8(2) ‖ u16(含自身,len) { 8001 ‖ subCmd ‖ ... ‖ TEA(payload,shareKey) ‖ 3 }
/// ```
library;

import 'dart:math';
import 'dart:typed_data';

import '../../../infra/coder.dart';

import '../../crypto/tea.dart';
import 'pc_qr_tlv.dart';
import 'pc_sso.dart';
import 'pc_sso_reserved.dart';

/// 签名回调：给 wtlogin 包（u8(2)‖…）算 sign/token/extra（来自本地签名服务）。
typedef PcSigner = Future<PcSsoSecureInfo?> Function(
    String cmd, Uint8List wtloginBody, int seq);

/// 一次 trans_emp 请求的产物（含内层密钥，供解析响应用）。
class PcQrRequest {
  const PcQrRequest({required this.packet, required this.shareKey});

  /// 完整 SSO 包（可直接写 TCP）。
  final Uint8List packet;

  /// 内层 TEA 密钥（解析响应时必须用同一个）。
  final Uint8List shareKey;
}

abstract final class PcWtLogin {
  /// 构造 trans_emp 请求。
  ///
  /// [tlvPack] 是子命令的 code2D body（如 FetchQRCode 的 body）。
  ///
  /// ## 两层要注意（第一版写错的就是这里）
  /// - **外层** wtlogin 包的 subCmd 固定 **2066**（`wtlogin.trans_emp` 命令字）
  /// - **内层** `TransEmp.requestBody` 里的 subCmd 才是 0x31（FetchQRCode）
  /// 而且 requestBody 是一层完整包装（时间戳/head_len/21字节/.../tlvPack），
  /// 不能把 code2D body 直接拿去加密。
  /// 通用 wtlogin 封装：加密 [payload] → 外层 wtlogin 头（2064=login / 2066=trans_emp）
  /// → 外层 SSO。Login 的 payload 是 `u16(cmd)+tlvPack`（不含 TransEmp 的 requestBody/packet 两层），
  /// 所以这里直接把调用方给的 payload 加密。
  static Future<PcQrRequest> buildWtLoginPacket({
    required int wtLoginSubCmd,
    required int appId,
    required int subAppId,
    required int appClientVersion,
    required int uin,
    required Uint8List payload,
    required Uint8List guid,
    String currentVersion = '',
    PcSigner? signer,
  }) async {
    final kx = PcSecp192k1.exchange();
    final shareKey = kx.shareKey;
    final compressedPub = kx.publicKeyCompressed;
    final encrypted = qqTeaEncrypt(payload, shareKey);

    final head = ByteWriterBe()
      ..u16(8001)
      ..u16(wtLoginSubCmd)
      ..u16(0)
      ..u32(uin)
      ..u8(3)
      ..u8(135)
      ..u32(0)
      ..u8(19)
      ..u16(0)
      ..u16(appClientVersion)
      ..u32(0)
      ..u8(1)
      ..u8(1)
      ..raw(_random16())
      ..u16(0x102);
    head
      ..u16(compressedPub.length)
      ..raw(compressedPub);
    head
      ..raw(encrypted)
      ..u8(3);
    final headBytes = head.build();

    final body = ByteWriterBe()
      ..u8(2)
      ..u16(headBytes.length + 3)
      ..raw(headBytes);
    final bodyBytes = body.build();

    final cmd = wtLoginSubCmd == 2064 ? 'wtlogin.login' : 'wtlogin.trans_emp';
    final seq = 0x10000 + DateTime.now().millisecondsSinceEpoch % 0x10000;
    Uint8List? ssoReserved;
    if (signer != null) {
      final sec = await signer(cmd, bodyBytes, seq);
      if (sec != null && !sec.isEmpty) {
        ssoReserved = PcSsoReserved.encode(msgType: 32, secureInfo: sec);
      }
    }

    final sso = PcSso.buildRequest12(
      uin: uin,
      sequence: seq,
      subAppId: subAppId,
      currentVersion: currentVersion,
      command: cmd,
      payload: bodyBytes,
      guid: guid,
      ssoReserved: ssoReserved,
    );
    return PcQrRequest(packet: sso, shareKey: shareKey);
  }

  static Future<PcQrRequest> buildTransEmp({
    required int transEmpSubCmd,
    required int appId,
    required int subAppId,
    required int appClientVersion,
    required int uin,
    required Uint8List tlvPack,
    required Uint8List guid,
    String currentVersion = '',
    PcSigner? signer,
  }) async {
    // ① secp192k1 ECDH
    final kx = PcSecp192k1.exchange();
    final shareKey = kx.shareKey;
    final compressedPub = kx.publicKeyCompressed;

    // ② TransEmp.requestBody（对齐 Diana：head_len = 46 + tlv，version 后多一个 i16(0)）
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final headLen = 46 + tlvPack.length;
    final rb = ByteWriterBe()
      ..u32(nowSec)
      ..u8(0x2) // packet start
      ..u16(headLen)
      ..u16(transEmpSubCmd) // 0x31
      ..raw(Uint8List(21)) // 固定 21 字节
      ..u8(0x3)
      ..u32(0x32) // close(0) + version code 50 合成 i32(0x32)
      ..u16(0) // 额外字段（Diana 有、acidify 无）
      ..u32(0) // sequence
      ..raw(Uint8List(8)) // dummy uin (u64)
      ..raw(tlvPack)
      ..u8(0x3);
    final requestBody = rb.build();

    // ★ 关键：requestBody 之外还有一层 packet 包装（第一版漏了这层）
    //   u8(0) ‖ u16(rbLen) ‖ u32(appId) ‖ u32(0x72) ‖ u16(0) ‖ u8(0) ‖ requestBody
    final packet = ByteWriterBe()
      ..u8(0x0) // encryptMethod = EM_ST / EM_ECDH_ST
      ..u16(requestBody.length)
      ..u32(appId)
      ..u32(0x72) // Role
      ..u16(0) // uSt（u16|LENGTH_ONLY 空）
      ..u8(0) // rollback（u8|LENGTH_ONLY 空）
      ..raw(requestBody);
    // 加密的是 packet，不是 requestBody
    final encrypted = qqTeaEncrypt(packet.build(), shareKey);

    // ③ 外层 wtlogin 包：u8(2) ‖ u16(含自身) { 8001 ‖ 2066 ‖ ... }
    final head = ByteWriterBe()
      ..u16(8001)
      ..u16(2066) // ← 固定 wtlogin.trans_emp
      ..u16(0) // sequence
      ..u32(uin)
      ..u8(3) // extVer
      ..u8(135) // cmdVer
      ..u32(0)
      ..u8(19) // pubId
      ..u16(0) // insId
      ..u16(appClientVersion)
      ..u32(0) // retryTime
      ..u8(1)
      ..u8(1)
      ..raw(_random16())
      ..u16(0x102);
    head
      ..u16(compressedPub.length)
      ..raw(compressedPub);
    head
      ..raw(encrypted)
      ..u8(3);
    final headBytes = head.build();

    final body = ByteWriterBe()
      ..u8(2)
      // barrier(UINT_16|INCLUDE, addition=1)：写入长度 = 内容 + 1 + 2(含前缀) = 内容 + 3
      ..u16(headBytes.length + 3)
      ..raw(headBytes);
    final bodyBytes = body.build();

    // ④ 外层 SSO（带签名：把 wtlogin 包体的 sign/token/extra 填进 ssoReserved.secureInfo）
    final seq = 0x10000 + DateTime.now().millisecondsSinceEpoch % 0x10000;
    Uint8List? ssoReserved;
    if (signer != null) {
      final sec = await signer('wtlogin.trans_emp', bodyBytes, seq);
      if (sec != null && !sec.isEmpty) {
        ssoReserved = PcSsoReserved.encode(msgType: 32, secureInfo: sec);
      }
    }
    final sso = PcSso.buildRequest12(
      uin: uin,
      sequence: seq,
      subAppId: subAppId,
      currentVersion: currentVersion,
      command: 'wtlogin.trans_emp',
      payload: bodyBytes,
      guid: guid,
      ssoReserved: ssoReserved,
    );
    return PcQrRequest(packet: sso, shareKey: shareKey);
  }

  /// 构造 FetchQRCode（subCmd 0x31）的 code2D body。
  static Uint8List buildFetchQrCodeBody({
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
    final tlv = pcBuildTlvQrCode(
      appId: appId,
      subAppId: subAppId,
      appIdQrCode: appIdQrCode,
      mainSigMap: mainSigMap,
      ssoVersion: ssoVersion,
      packageName: packageName,
      ptVersion: ptVersion,
      os: os,
      deviceName: deviceName,
      guid: guid,
      unusualSig: unusualSig,
    );
    // code2D body（对齐 Diana transEmp31）：appId ‖ uin(u64) ‖ a2(空) ‖ u8(0) ‖ u16(0) ‖ tlvPack
    // 注意：Diana/官方没有 acidify 那个开头的 u16(0)
    final code2d = ByteWriterBe()
      ..u32(appId)
      ..u32(0) // uin lo
      ..u32(0) // uin hi（u64 uin）
      // a2 = 空（裸写 0 字节）
      ..u8(0) // field4
      ..u16(0) // field5
      ..raw(tlv);
    return code2d.build();
  }
}

Uint8List _random16() {
  final r = Random.secure();
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

/// 扫码状态查询结果。
class PcQrStateResult {
  const PcQrStateResult({
    required this.state,
    this.uin,
    this.tgtgt,
    this.encryptedA1,
    this.noPicSig,
  });

  final int state;
  final int? uin;
  final Uint8List? tgtgt;
  final Uint8List? encryptedA1;
  final Uint8List? noPicSig;

  bool get confirmed => state == 0;

  String get stateName => switch (state) {
        0 => 'CONFIRMED(已确认)',
        17 => 'CODE_EXPIRED(已过期)',
        48 => 'WAITING_FOR_SCAN(待扫描)',
        53 => 'WAITING_FOR_CONFIRMATION(已扫待确认)',
        54 => 'CANCELLED(已取消)',
        _ => 'UNKNOWN($state)',
      };
}

/// 构造 QueryQRCodeState（trans_emp 0x12）的 code2D body。
/// 出处：Acidify WtLogin.kt `QueryQRCodeState.buildCode2DPayload`。
Uint8List pcBuildQueryStateBody({
  required int appId,
  required Uint8List qrSig,
}) {
  // 对齐 Diana：u32 appId ‖ u16 len ‖ qrSig ‖ u64 uin ‖ u32 0 ‖ u8 0 ‖ u8 0x03
  final w = ByteWriterBe()
    ..u32(appId)
    ..u16(qrSig.length)
    ..raw(qrSig)
    ..u32(0) // uin lo
    ..u32(0) // uin hi
    ..u32(0)
    ..u8(0)
    ..u8(0x03);
  return w.build();
}

/// 解析 QueryQRCodeState 响应。
/// CONFIRMED 时：discard(4) ‖ u32(uin) ‖ discard(4) ‖ TLV{0x1e:tgtgt, 0x18:encryptedA1, 0x19:noPicSig}
PcQrStateResult pcParseQueryState(Uint8List code2d) {
  final r = ByteReader(code2d);
  final state = r.readUint8();
  if (state == 0) {
    r.read(4);
    final uin = r.readUint32();
    r.read(4);
    final tlv = pcReadTlv(Uint8List.fromList(code2d.sublist(r.pos)));
    return PcQrStateResult(
      state: 0,
      uin: uin,
      tgtgt: tlv[0x1e],
      encryptedA1: tlv[0x18],
      noPicSig: tlv[0x19],
    );
  }
  return PcQrStateResult(state: state);
}
