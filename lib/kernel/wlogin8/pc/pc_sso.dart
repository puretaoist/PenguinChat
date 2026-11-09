/// PC NTLogin 的 SSO 信封（Protocol 12）。
///
/// ## 为什么不能复用 `qq8_sso.dart`
///
/// 老线是 **Android wtlogin** 的信封：`tgt / cmd / sessionId / imeiSlot /
/// ksidRaw / ksid串 / reserveFields / payload`。
/// PC 的 Protocol 12 内层是 `sequence / subAppId / locale / 固定12字节 / a2 /
/// cmd / 空 / guidHex / 空 / version / ssoReserved` —— **字段完全不同**。
///
/// 出处：Acidify `internal/context/PacketContext.kt` 的 `buildProtocol12` /
/// `decode`（base64 原文已核）。
///
/// ## 结构（请求）
///
/// ```text
/// u32(含自身) {
///     u32 12                        // protocol
///     u8  encryptType               // None=0 / WithD2Key=1 / WithEmptyKey=2
///     withLength(d2 或 空)
///     u8  0
///     withLength(uin)
///     TEA( sso )                     // 裸写，无长度前缀
/// }
/// sso = withLength( {
///     u32 sequence; u32 subAppId; u32 2052（locale）;
///     raw 固定12字节: 02 00*11;
///     withLength(a2);
///     withLength(command);
///     withLength(空);
///     withLength(guidHex);
///     withLength(空);
///     u16含自身(version);
///     withLength(ssoReserved);
/// } ) + withLength(payload)
/// ```
///
/// `withLength(x)` = `u32(x.length + 4) ‖ x`（长度**含自身** 4 字节）。
///
/// ## 响应
///
/// ```text
/// u32 protocol ‖ u8 authFlag ‖ u8 dummy ‖ withLength(uin) ‖ 其余(TEA 密文)
///   → 按 authFlag 解密
///   → u32 headLen ‖ u32 sequence ‖ i32 retCode ‖ withLength(extra)
///     ‖ withLength(command) ‖ withLength(cookie) ‖ i32 isCompressed
///     ‖ u32(裸长度) reserved ‖ withLength(payload)
///   → isCompressed == 1 时 payload 用 gzip 解压
/// ```
library;

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import '../../../infra/coder.dart';
import '../../crypto/tea.dart';
import 'pc_sso_reserved.dart';

/// 加密方式（Acidify `EncryptType`：None=0 / WithD2Key=1 / WithEmptyKey=2）。
enum PcSsoEncryptType {
  none(0),
  withD2Key(1),
  withEmptyKey(2);

  const PcSsoEncryptType(this.underlying);
  final int underlying;
}

/// 解析后的 SSO 响应。
class PcSsoResponse {
  const PcSsoResponse({
    required this.retCode,
    required this.command,
    required this.payload,
    required this.sequence,
    this.extra = '',
  });

  final int retCode;
  final String command;
  final Uint8List payload;
  final int sequence;
  final String extra;

  bool get ok => retCode == 0;
}

abstract final class PcSso {
  /// 内层固定的 12 字节（`02 00 00 00 00 00 00 00 00 00 00 00`）。
  /// 出处：Acidify `buildSsoFixedBytes`。
  static final Uint8List _fixedBytes = Uint8List.fromList(<int>[
    0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  ]);

  /// 编码一个 Protocol 12 请求包（不含 4 字节 TCP 分帧头——那由传输层加）。
  ///
  /// [ssoReserved] 是 pb 编码的 `SsoReservedFields`（见 `pc_sso_reserved.dart`），
  /// 没有就传空。
  static Uint8List buildRequest12({
    required int uin,
    required int sequence,
    required int subAppId,
    required String currentVersion,
    required String command,
    required Uint8List payload,
    required Uint8List guid,
    PcSsoEncryptType encryptType = PcSsoEncryptType.withEmptyKey,
    Uint8List? d2,
    Uint8List? d2Key,
    Uint8List? a2,
    Uint8List? ssoReserved,
    int ssoReservedMsgType = 32,
  }) {
    // reservedFields 是必填的（trace 每次登录都要生成一条）。
    // 未显式给就自动生成：trace 随机、msgType 默认 32。
    final reserved = ssoReserved ??
        PcSsoReserved.encode(msgType: ssoReservedMsgType);

    // ---- 内层 sso ----
    final ssoInner = ByteWriter()
      ..u32(sequence)
      ..u32(subAppId)
      ..u32(2052) // locale id
      ..raw(_fixedBytes);
    _withLength(ssoInner, a2 ?? Uint8List(0));
    _withLength(ssoInner, utf8.encode(command));
    _withLength(ssoInner, Uint8List(0)); // unknown
    _withLength(ssoInner, utf8.encode(_hexUpper(guid)));
    _withLength(ssoInner, Uint8List(0)); // unknown
    // version：u16 含自身
    final ver = utf8.encode(currentVersion);
    ssoInner
      ..u16(ver.length + 2)
      ..raw(ver);
    _withLength(ssoInner, reserved);

    final sso = ByteWriter();
    final innerBytes = ssoInner.build();
    sso
      ..u32(innerBytes.length + 4)
      ..raw(innerBytes);
    _withLength(sso, payload);
    final ssoBytes = sso.build();

    // ---- 加密 ----
    final encrypted = _encrypt(ssoBytes, encryptType, d2Key ?? d2);

    // ---- 外层 ----
    final body = ByteWriter()
      ..u32(12) // protocol
      ..u8(encryptType.underlying);
    _withLength(body, d2 ?? Uint8List(0));
    body.u8(0);
    _withLength(body, utf8.encode('$uin'));
    body.raw(encrypted); // 裸写，无长度前缀

    final bodyBytes = body.build();
    return (ByteWriter()
          ..u32(bodyBytes.length + 4)
          ..raw(bodyBytes))
        .build();
  }

  /// 编码一个 Protocol 13 请求包（`RequestType.Simple` 用，目前仅 `Heartbeat.Alive`）。
  ///
  /// 出处：Acidify `internal/context/PacketContext.kt` 的 `buildProtocol13`（逐项核过）。
  /// 与 protocol12 的区别：无 subAppId / locale / 固定12字节 / a2 / guid / version，
  /// 外层是 `protocol=13 ‖ encryptType ‖ i32(sequence) ‖ u8(0) ‖ string(uin)`，
  /// sso 内是 `string(command) ‖ i32(4) ‖ ssoReserved`，再接 payload。
  static Uint8List buildRequest13({
    required int uin,
    required int sequence,
    required String command,
    required Uint8List payload,
    PcSsoEncryptType encryptType = PcSsoEncryptType.none,
    Uint8List? d2,
    Uint8List? ssoReserved,
    int ssoReservedMsgType = 32,
  }) {
    final reserved =
        ssoReserved ?? PcSsoReserved.encode(msgType: ssoReservedMsgType);

    // sso 内层：barrier(UINT32|INCLUDE){ string(command), i32(4), withLength(ssoReserved) }
    final ssoInner = ByteWriter();
    _withLength(ssoInner, utf8.encode(command));
    ssoInner.u32(4); // i32(4)：空 bytes 的 withLength（长度含自身 4 字节）
    _withLength(ssoInner, reserved);
    final innerBytes = ssoInner.build();

    final sso = ByteWriter();
    sso.u32(innerBytes.length + 4); // barrier(UINT32|INCLUDE)
    sso.raw(innerBytes);
    _withLength(sso, payload);

    final encrypted = _encrypt(sso.build(), encryptType, d2);

    final body = ByteWriter()
      ..u32(13)
      ..u8(encryptType.underlying)
      ..u32(sequence)
      ..u8(0);
    _withLength(body, utf8.encode('$uin'));
    body.raw(encrypted);

    final bodyBytes = body.build();
    return (ByteWriter()
          ..u32(bodyBytes.length + 4)
          ..raw(bodyBytes))
        .build();
  }

  /// 解析一个 Protocol 12 响应（不含 4 字节 TCP 分帧头）。
  ///
  /// [d2Key] 用于 WithD2Key 解密；WithEmptyKey 用 16 个零字节，无需传。
  static PcSsoResponse parseResponse(Uint8List packet, {Uint8List? d2Key}) {
    final r = ByteReader(packet);
    final protocol = r.readUint32();
    if (protocol != 12 && protocol != 13) {
      throw FormatException('未识别的 SSO protocol: $protocol');
    }
    final authFlag = r.readUint8();
    r.readUint8(); // dummy
    _readWithLength(r); // uin

    final encrypted = r.readRest();
    final plain = switch (authFlag) {
      0 => encrypted,
      1 => qqTeaDecrypt(encrypted, d2Key ?? Uint8List(16)),
      2 => qqTeaDecrypt(encrypted, Uint8List(16)),
      _ => throw FormatException('未识别的 authFlag: $authFlag'),
    };

    final b = ByteReader(plain);
    b.readUint32(); // headLen
    final sequence = b.readUint32();
    final retCode = b.readInt32();
    final extra = utf8.decode(_readWithLength(b));
    final command = utf8.decode(_readWithLength(b));
    _readWithLength(b); // messageCookie
    final isCompressed = b.readInt32() == 1;
    _readBare(b); // reservedField（裸长度，非含自身）
    var payload = _readWithLength(b);
    if (isCompressed) {
      payload = Uint8List.fromList(gzip.decode(payload));
    }
    return PcSsoResponse(
      retCode: retCode,
      command: command,
      payload: payload,
      sequence: sequence,
      extra: extra,
    );
  }

  /// 读「长度含自身 4 字节」的字节串（SSO 的 withLength 语义）。
  static Uint8List _readWithLength(ByteReader r) => r.read(r.readUint32() - 4);

  /// 读「裸长度」的字节串。
  static Uint8List _readBare(ByteReader r) => r.read(r.readUint32());

  static Uint8List _encrypt(
    Uint8List data,
    PcSsoEncryptType type,
    Uint8List? d2,
  ) {
    switch (type) {
      case PcSsoEncryptType.none:
        return data;
      case PcSsoEncryptType.withD2Key:
        if (d2 == null) throw ArgumentError('withD2Key 需要 d2');
        return qqTeaEncrypt(data, d2);
      case PcSsoEncryptType.withEmptyKey:
        return qqTeaEncrypt(data, Uint8List(16));
    }
  }

  static void _withLength(ByteWriter w, List<int> data) {
    w
      ..u32(data.length + 4)
      ..raw(data);
  }

  static String _hexUpper(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
}
