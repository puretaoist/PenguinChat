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

  // -------------------------------------------------------------------------
  // 解码（读服务端响应要用；只覆盖 wiretype 0/2）
  // -------------------------------------------------------------------------

  /// 解码为 `tag → 值列表`（同一 tag 重复 = repeated 字段）。
  ///
  /// 返回值里：wiretype 0 → `int`；wiretype 2 → `Uint8List`（是文本还是嵌套
  /// 消息由调用方按业务判断，本函数不猜）。wiretype 1/5 显式抛错（无样本）。
  static Map<int, List<Object>> decode(Uint8List data) {
    final out = <int, List<Object>>{};
    var i = 0;
    while (i < data.length) {
      final k = _readVarint(data, i);
      i = k.$2;
      final tag = k.$1 >> 3;
      final wire = k.$1 & 7;
      if (tag == 0) throw Qq8PbException('tag=0 非法（偏移 $i）');
      switch (wire) {
        case 0:
          final v = _readVarint(data, i);
          i = v.$2;
          out.putIfAbsent(tag, () => <Object>[]).add(v.$1);
        case 2:
          final l = _readVarint(data, i);
          i = l.$2;
          final end = i + l.$1;
          if (end > data.length) {
            throw Qq8PbException(
                '长度越界：tag=$tag 声明 ${l.$1} 字节，剩余 ${data.length - i}');
          }
          out.putIfAbsent(tag, () => <Object>[]).add(data.sublist(i, end));
          i = end;
        default:
          throw Qq8PbException('未支持的 wiretype $wire（tag=$tag）');
      }
    }
    return out;
  }

  /// 取某个 tag 的第一个整数（没有则 null）。
  static int? intAt(Map<int, List<Object>> m, int tag) {
    final v = m[tag];
    if (v == null || v.isEmpty) return null;
    final first = v.first;
    return first is int ? first : null;
  }

  /// 取某个 tag 的第一个字节串（没有或类型不符则 null）。
  static Uint8List? bytesAt(Map<int, List<Object>> m, int tag) {
    final v = m[tag];
    if (v == null || v.isEmpty) return null;
    final first = v.first;
    return first is Uint8List ? first : null;
  }

  /// 取某个 tag 的第一个字符串（按 UTF-8 解，畸形字节按替换字符处理）。
  static String? textAt(Map<int, List<Object>> m, int tag) {
    final b = bytesAt(m, tag);
    return b == null ? null : utf8.decode(b, allowMalformed: true);
  }

  /// 读一个 varint，返回 (值, 新偏移)。
  static (int, int) _readVarint(Uint8List data, int offset) {
    var v = 0;
    var shift = 0;
    var i = offset;
    while (true) {
      if (i >= data.length) throw Qq8PbException('varint 被截断（偏移 $offset）');
      final b = data[i++];
      v |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) return (v, i);
      shift += 7;
      if (shift > 63) throw Qq8PbException('varint 超长（偏移 $offset）');
    }
  }

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
