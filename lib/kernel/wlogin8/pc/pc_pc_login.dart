/// 扫码登录 Step 3：PCLogin（`wtlogin.login` subCmd 9）——用扫码票据换完整凭证。
///
/// ## 出处（Acidify，逐项核过）
/// - `WtLogin.kt`：`abstract class Login(internalCmd) : WtLogin("login", 2064)`
///   - `buildWtLoginPayload` = `u16(internalCmd) ‖ tlvPack`（注意：比 TransEmp 少 requestBody/packet 两层）
///   - 外层 wtlogin 头固定 **2064**（TransEmp 是 2066）
/// - `object PCLogin : Login(9)`：buildLoginTlv 15 个 TLV；parseLoginTlv 解 tlv119
/// - `Tlv.kt`：各 TLV 结构
///
/// ## 15 个 TLV（顺序）
/// tlv106A2, tlv144, tlv116, tlv142, tlv145, tlv18, tlv141, tlv177,
/// tlv191, tlv100, tlv107, tlv318, tlv16a, tlv166, tlv521
///
/// ## 响应解析
/// 解密后 = `u16(cmd) ‖ u8(state) ‖ TLV包`；
/// state==0 → `tlv119 = TEA.decrypt(tgtgt)` → 内部 TLV：
///   d2Key=0x305, uid=0x543(TlvBody543: 9→11→1), a2=0x10A, d2=0x143, encryptedA1=0x106
library;

import 'dart:typed_data';

import 'dart:convert';

import '../../../infra/coder.dart';
import '../../crypto/tea.dart';
import 'pc_proto.dart';
import 'pc_qr_login.dart';
import 'pc_qr_tlv.dart';

/// PCLogin 拿到的完整凭证。
class PcLoginResult {
  const PcLoginResult({
    required this.d2Key,
    required this.uid,
    required this.a2,
    required this.d2,
    required this.encryptedA1,
  });

  final Uint8List d2Key;
  final String uid;
  final Uint8List a2;
  final Uint8List d2;
  final Uint8List encryptedA1;
}

abstract final class PcPcLogin {
  /// 构建 PCLogin 请求包。[tgtgt] 用于 tlv144；[encryptedA1]/[noPicSig] 来自扫码确认。
  static Future<PcQrRequest> build({
    required int appId,
    required int subAppId,
    required int appClientVersion,
    required int mainSigMap,
    required int subSigMap,
    required int uin,
    required Uint8List guid,
    required Uint8List tgtgt,
    required Uint8List encryptedA1,
    required Uint8List noPicSig,
    required String packageName,
    required String ptVersion,
    required String os,
    required String deviceName,
    required String wtLoginSdk,
    required String currentVersion,
    PcSigner? signer,
  }) async {
    final tlvPack = buildPcLoginTlv(
      appId: appId,
      subAppId: subAppId,
      appClientVersion: appClientVersion,
      mainSigMap: mainSigMap,
      subSigMap: subSigMap,
      uin: uin,
      guid: guid,
      tgtgt: tgtgt,
      encryptedA1: encryptedA1,
      noPicSig: noPicSig,
      packageName: packageName,
      ptVersion: ptVersion,
      os: os,
      deviceName: deviceName,
      wtLoginSdk: wtLoginSdk,
    );
    // Login payload = u16(9) + tlvPack
    final payload = (ByteWriterBe()
          ..u16(9)
          ..raw(tlvPack))
        .build();
    // 外层 wtlogin 头固定 2064（带签名）
    return PcWtLogin.buildWtLoginPacket(
      wtLoginSubCmd: 2064,
      appId: appId,
      subAppId: subAppId,
      appClientVersion: appClientVersion,
      uin: uin,
      payload: payload,
      guid: guid,
      currentVersion: currentVersion,
      signer: signer,
    );
  }

  /// 15 个 TLV。
  static Uint8List buildPcLoginTlv({
    required int appId,
    required int subAppId,
    required int appClientVersion,
    required int mainSigMap,
    required int subSigMap,
    required int uin,
    required Uint8List guid,
    required Uint8List tgtgt,
    required Uint8List encryptedA1,
    required Uint8List noPicSig,
    required String packageName,
    required String ptVersion,
    required String os,
    required String deviceName,
    required String wtLoginSdk,
  }) {
    final b = PcTlvBuilder();

    // 0x106：encryptedA1（裸写）
    b.add(0x106, encryptedA1);

    // 0x144：TEA(tlv16e ‖ tlv147 ‖ tlv128 ‖ tlv124, tgtgt)
    final inner144 = (ByteWriterBe()
          ..raw(_tlv16e(deviceName))
          ..raw(_tlv147(appId, ptVersion, packageName))
          ..raw(_tlv128(os, guid))
          ..raw(_tlv124()))
        .build();
    b.add(0x144, qqTeaEncrypt(inner144, tgtgt));

    // 0x116
    b.add(
      0x116,
      (ByteWriterBe()
            ..u8(0)
            ..u32(12058620)
            ..u32(subSigMap)
            ..u8(0))
          .build(),
    );

    // 0x142
    b.add(0x142, (ByteWriterBe()
          ..u16(0)
          ..raw(_str16(packageName)))
        .build());

    // 0x145
    b.add(0x145, guid);

    // 0x18
    b.add(
      0x18,
      (ByteWriterBe()
            ..u16(0)
            ..u32(5)
            ..u32(0)
            ..u32(8001)
            ..u32(uin)
            ..u16(0)
            ..u16(0))
          .build(),
    );

    // 0x141
    b.add(
      0x141,
      (ByteWriterBe()
            ..raw(_str32('Unknown'))
            ..u32(0))
          .build(),
    );

    // 0x177
    b.add(
      0x177,
      (ByteWriterBe()
            ..u8(1)
            ..u32(0)
            ..raw(_str16(wtLoginSdk)))
          .build(),
    );

    // 0x191
    b.add(0x191, (ByteWriterBe()..u8(0)).build());

    // 0x100
    b.add(
      0x100,
      (ByteWriterBe()
            ..u16(0)
            ..u32(5)
            ..u32(appId)
            ..u32(subAppId)
            ..u32(appClientVersion)
            ..u32(mainSigMap))
          .build(),
    );

    // 0x107（对齐 Diana：picType u16=1, capType u8=0, picSize u16=0x0d, retType u8=1）
    b.add(
      0x107,
      (ByteWriterBe()
            ..u16(1)
            ..u8(0)
            ..u16(0x0d)
            ..u8(1))
          .build(),
    );

    // 0x318（空）
    b.add(0x318, Uint8List(0));

    // 0x16a
    b.add(0x16a, noPicSig);

    // 0x166
    b.add(0x166, (ByteWriterBe()..u8(5)).build());

    // 0x521
    b.add(
      0x521,
      (ByteWriterBe()
            ..u32(0x13)
            ..raw(_str16('basicim')))
          .build(),
    );

    // 0x511：pskey 域名登记（对齐 Diana/Lagrange Tlv511）
    b.add(0x511, _tlv511());

    return b.build();
  }

  /// 解析 PCLogin 响应（已剥 wtlogin 头的 code2D body）。
  static PcLoginResult parse(Uint8List decryptedPayload, Uint8List tgtgt) {
    final r = ByteReader(decryptedPayload);
    r.readUint16(); // command
    final state = r.readUint8();
    final tlv = pcReadTlv(Uint8List.fromList(decryptedPayload.sublist(r.pos)));
    if (state != 0) {
      final e = tlv[0x146];
      var detail = '';
      if (e != null) {
        final er = ByteReader(e);
        final code = er.readUint32();
        final tagLen = er.readUint16();
        final tag = utf8.decode(er.read(tagLen), allowMalformed: true);
        final msgLen = er.readUint16();
        final msg = utf8.decode(er.read(msgLen), allowMalformed: true);
        detail = ' code=$code tag=$tag msg=$msg';
      }
      final keys =
          tlv.keys.map((k) => '0x${k.toRadixString(16)}').join(',');
      throw StateError('PCLogin state=$state$detail tlv=[$keys]');
    }
    final tlv119 = tlv[0x119];
    if (tlv119 == null) throw StateError('PCLogin 响应缺 tlv119');
    final plain = qqTeaDecrypt(tlv119, tgtgt);
    final inner = pcReadTlv(plain);
    final uidPb = inner[0x543];
    return PcLoginResult(
      d2Key: inner[0x305] ?? Uint8List(0),
      uid: uidPb == null ? '' : _parseUid543(uidPb),
      a2: inner[0x10A] ?? Uint8List(0),
      d2: inner[0x143] ?? Uint8List(0),
      encryptedA1: inner[0x106] ?? Uint8List(0),
    );
  }

  /// TlvBody543: 9=layer1{ 11=layer2{ 1=uid } }
  static String _parseUid543(Uint8List pb) {
    final l1 = _pbField(pb, 9);
    if (l1 == null) return '';
    final l2 = _pbField(l1, 11);
    if (l2 == null) return '';
    final uid = _pbField(l2, 1);
    if (uid == null) return '';
    return String.fromCharCodes(uid);
  }

  static Uint8List? _pbField(Uint8List pb, int field) {
    final r = PbReader(pb);
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == field && w == 2) return r.readBytes();
      r.skip(w);
    }
    return null;
  }

  static Uint8List _tlv16e(String deviceName) => _tlv(0x16e, _strAny(deviceName));

  static Uint8List _tlv147(int appId, String ptVersion, String pkg) => _tlv(
        0x147,
        (ByteWriterBe()
              ..u32(appId)
              ..raw(_str16(ptVersion))
              ..raw(_str16(pkg)))
            .build(),
      );

  static Uint8List _tlv128(String os, Uint8List guid) => _tlv(
        0x128,
        (ByteWriterBe()
              ..u16(0) // field0
              ..u8(0) // guidNew
              ..u8(1) // guidAvailable（对齐 Diana）
              ..u8(0) // guidChanged
              ..u32(0) // guidFlag
              ..raw(_str16(os))
              ..raw(_bytes16(guid))
              ..raw(_str16('')))
            .build(),
      );

  static Uint8List _tlv124() => _tlv(0x124, Uint8List(12));

  /// 0x511：pskey 域名登记（Diana PSKEY_DOMAINS）。
  static Uint8List _tlv511() {
    const domains = [
      'qq.com', 'office.qq.com', 'qun.qq.com', 'gamecenter.qq.com',
      'docs.qq.com', 'mail.qq.com', 'tim.qq.com', 'ti.qq.com', 'vip.qq.com',
      'tenpay.com', 'qqweb.qq.com', 'qzone.qq.com', 'mma.qq.com', 'game.qq.com',
      'openmobile.qq.com', 'connect.qq.com',
    ];
    final w = ByteWriterBe()..u16(domains.length);
    for (final d in domains) {
      final b = Uint8List.fromList(d.codeUnits);
      w
        ..u8(1)
        ..u16(b.length)
        ..raw(b);
    }
    return w.build();
  }

  /// 简单 TLV：u16 tag ‖ u16 len ‖ body。
  static Uint8List _tlv(int tag, Uint8List body) {
    final b = ByteWriterBe()
      ..u16(tag)
      ..u16(body.length)
      ..raw(body);
    return b.build();
  }

  static Uint8List _str16(String s) {
    final d = Uint8List.fromList(s.codeUnits);
    return (ByteWriterBe()
          ..u16(d.length)
          ..raw(d))
        .build();
  }

  static Uint8List _str32(String s) {
    final d = Uint8List.fromList(s.codeUnits);
    return (ByteWriterBe()
          ..u32(d.length)
          ..raw(d))
        .build();
  }

  static Uint8List _bytes16(Uint8List d) =>
      (ByteWriterBe()
            ..u16(d.length)
            ..raw(d))
          .build();

  /// tlv16e 的 body 是 `writeString(deviceName)`（默认 Prefix.NONE = 裸写 UTF-8）。
  static Uint8List _strAny(String s) => Uint8List.fromList(s.codeUnits);
}
