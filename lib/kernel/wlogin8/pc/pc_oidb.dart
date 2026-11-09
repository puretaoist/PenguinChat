/// PC NTQQ 的 OIDB 通用封装（对齐 acidify `Oidb.kt` / `OidbServiceBase.kt`）。
///
/// 命令 = `OidbSvcTrpcTcp.0x{command}_{service}`，报文外层是 `Oidb` proto：
///   1:command(int) 2:service(int) 3:result(int) 4:body(bytes) 5:message(str) 12:reserved(bool)
library;

import 'dart:typed_data';

import 'pc_proto.dart';

class PcOidbResponse {
  const PcOidbResponse({
    required this.result,
    required this.message,
    required this.body,
  });
  final int result;
  final String message;
  final Uint8List body;

  bool get ok => result == 0;
}

abstract final class PcOidb {
  static String cmdOf(int command, int service) =>
      'OidbSvcTrpcTcp.0x${command.toRadixString(16)}_$service';

  /// 编码外层 `Oidb`（请求只填 command/service/body，reserved 可选）。
  static Uint8List build({
    required int command,
    required int service,
    required Uint8List body,
    bool reserved = false,
  }) {
    final w = PbWriter()
      ..writeInt(1, command)
      ..writeInt(2, service)
      ..writeBytes(4, body);
    if (reserved) w.writeInt(12, 1);
    return w.toBytes();
  }

  /// 解析外层 `Oidb` 响应，取出 result/body。
  static PcOidbResponse parse(Uint8List bytes) {
    final r = PbReader(bytes);
    var result = 0;
    var message = '';
    var body = Uint8List(0);
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 3) {
        result = r.readVarint();
      } else if (f == 4) {
        body = Uint8List.fromList(r.readBytes());
      } else if (f == 5) {
        message = r.readString();
      } else {
        r.skip(w);
      }
    }
    return PcOidbResponse(result: result, message: message, body: body);
  }

  /// 把一组 int 编码为 protobuf **packed varint** 的字节（直接作为 `writeBytes` 的字段体，
  /// 因为 packed = tag(wire2) + len + 连续 varint，与 writeBytes(field, varint-bytes) 等价）。
  static Uint8List packedVarints(List<int> values) {
    final w = PbWriter();
    for (final v in values) {
      w.varint(v);
    }
    return w.toBytes();
  }
}
