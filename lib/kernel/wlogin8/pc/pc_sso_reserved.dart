/// SSO 头的 `reservedFields`（protobuf）。
///
/// ## 出处
///
/// Acidify `internal/proto/system/SsoReservedFields.kt`（字段号逐项核过）：
/// ```kotlin
/// SsoReservedFields {
///     15: trace (String)          // 必填，见 generateTrace
///     16: uid (String?)
///     21: msgType (Int?)          // 默认 = ssoReservedMsgType（32）
///     24: secureInfo (SsoSecureInfo?)
///     26: ntCoreVersion (Int?)
/// }
/// SsoSecureInfo { 1: sign, 2: token, 3: extra }   // 都是 bytes
/// ```
///
/// `generateTrace`（Acidify `util/GenerateTrace.kt`）：
/// ```
/// "00" + "-" + 32位随机hex + "-" + 16位随机hex + "-" + "01"   // 共 55 字符
/// ```
library;

import 'dart:math';
import 'dart:typed_data';

import 'pc_proto.dart';

/// `SsoSecureInfo`（签名/令牌/附加）。
class PcSsoSecureInfo {
  const PcSsoSecureInfo({
    this.sign = const <int>[],
    this.token = const <int>[],
    this.extra = const <int>[],
  });

  final List<int> sign;
  final List<int> token;
  final List<int> extra;

  bool get isEmpty => sign.isEmpty && token.isEmpty && extra.isEmpty;

  Uint8List _encode() {
    final w = PbWriter();
    if (sign.isNotEmpty) w.writeBytes(1, sign);
    if (token.isNotEmpty) w.writeBytes(2, token);
    if (extra.isNotEmpty) w.writeBytes(3, extra);
    return w.toBytes();
  }
}

abstract final class PcSsoReserved {
  /// 生成 trace：`00-{32hex}-{16hex}-01`。
  static String generateTrace() {
    const hex = '1234567890abcdef';
    final r = Random.secure();
    final sb = StringBuffer('00-');
    for (var i = 0; i < 32; i++) {
      sb.write(hex[r.nextInt(16)]);
    }
    sb.write('-');
    for (var i = 0; i < 16; i++) {
      sb.write(hex[r.nextInt(16)]);
    }
    sb.write('-01');
    return sb.toString();
  }

  /// 编码 reservedFields。
  static Uint8List encode({
    String? trace,
    String? uid,
    int? msgType,
    PcSsoSecureInfo? secureInfo,
    int? ntCoreVersion,
  }) {
    final w = PbWriter();
    // trace 必填（Acidify 每次登录都生成一条）
    w.writeString(15, trace ?? generateTrace());
    if (uid != null && uid.isNotEmpty) w.writeString(16, uid);
    if (msgType != null) w.writeInt(21, msgType);
    if (secureInfo != null && !secureInfo.isEmpty) {
      w.writeBytes(24, secureInfo._encode());
    }
    if (ntCoreVersion != null) w.writeInt(26, ntCoreVersion);
    return w.toBytes();
  }
}
