/// L2 协议内核：最小 protobuf 编码（QQ 业务里用到的子集）
///
/// 规则对照参考实现 oicq `lib/algo/pb.js` 的 `_encode`（底层 protobufjs）：
///
/// | 值 | wiretype | 编码 |
/// |---|---|---|
/// | 整数 / 布尔 | 0 | varint（负数按 64 位补码，最多 10 字节） |
/// | 字符串 / 字节数组 | 2 | 长度分隔（varint 长度 + 内容） |
/// | 嵌套消息（Map） | 2 | 长度分隔（递归编码） |
/// | 列表 | —— | **同一 tag 重复出现**（repeated） |
/// | null | —— | 跳过 |
///
/// ⚠️ 未覆盖 wiretype 1（fixed64）——参考实现只对"非整数"用，而注册体
/// 等现有场景里没有非整数；遇到时显式抛错，不猜。
///
/// 黄金向量：`../analysis/scripts/gen_pb_vector.cjs`；
/// 用法与断言见 `tool/qq8_register_selftest.dart`。
///
/// 本文件是纯 Dart。
library;

import 'dart:convert';
import 'dart:typed_data';

/// protobuf 编码错误。
class Qq8PbException implements Exception {
  final String message;
  Qq8PbException(this.message);

  @override
  String toString() => 'Qq8PbException: $message';
}

/// 最小 protobuf 写入器。
abstract final class Qq8Pb {
  /// 编码 `tag → 值`（值语义见文件头表格）。
  static Uint8List encode(Map<int, Object?> fields) {
    final b = BytesBuilder(copy: false);
    for (final e in fields.entries) {
      _value(b, e.key, e.value);
    }
    return b.takeBytes();
  }

  static void _value(BytesBuilder b, int tag, Object? value) {
    if (value == null) return;
    if (value is bool) {
      _value(b, tag, value ? 1 : 0);
      return;
    }
    if (value is int) {
      _key(b, tag, 0);
      _varint(b, value);
      return;
    }
    if (value is String) {
      final bytes = utf8.encode(value);
      _key(b, tag, 2);
      _varint(b, bytes.length);
      b.add(bytes);
      return;
    }
    if (value is Uint8List) {
      _key(b, tag, 2);
      _varint(b, value.length);
      b.add(value);
      return;
    }
    if (value is Map) {
      final nested = encode(Map<int, Object?>.from(value));
      _key(b, tag, 2);
      _varint(b, nested.length);
      b.add(nested);
      return;
    }
    if (value is List) {
      for (final item in value) {
        _value(b, tag, item); // repeated：同一 tag 重复
      }
      return;
    }
    throw Qq8PbException('未支持的类型: ${value.runtimeType}（fixed64 未覆盖）');
  }

  static void _key(BytesBuilder b, int tag, int wireType) =>
      _varint(b, (tag << 3) | wireType);

  /// varint：负数按 64 位补码（`>>>` 逻辑右移，最多 10 字节）。
  static void _varint(BytesBuilder b, int v) {
    var x = v;
    while (true) {
      final byte = x & 0x7f;
      x = x >>> 7;
      if (x == 0) {
        b.addByte(byte);
        return;
      }
      b.addByte(byte | 0x80);
    }
  }
}
