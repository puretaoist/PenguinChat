/// 最小 protobuf 编解码器 —— 只覆盖 PC NTLogin 链路用到的子集。
///
/// ## 为什么不用 `package:protobuf`
///
/// 1. 需要的是**精确的字段号与线类型**，生成器会引入一堆我们不用生成的模型类；
/// 2. QQ 的 SSO 包是「命令字 + 裸 protobuf body」，自己拼更透明，也便于在注释里
///    写明每个字段的出处（`AGENTS.md` §1.7：常量必须有出处）；
/// 3. 本项目的既有习惯也是手写 pb（见 `qq8_pb.dart`）。
///
/// ## protobuf 线类型（只实现用到的三种）
///
/// | wire | 含义 | 用于 |
/// |---|---|---|
/// | 0 | varint | uint32 / int64 / bool |
/// | 2 | length-delimited | bytes / string / 嵌套消息 |
///
/// 出处：字段号来自 Acidify 的 `internal/proto/login/NTEcdh.kt` 与 `NTLogin.kt`
/// （`@ProtoNumber(n)` 注解，逐项核过）。
/// 本文件只实现**编解码原语**，具体消息的字段号由调用方（`pc_key_exchange.dart`
/// / 后续 `pc_nt_login.dart`）按 Acidify 的定义填写。
library;

import 'dart:convert';
import 'dart:typed_data';

/// protobuf 写入器。
class PbWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  /// 写一个 varint（无符号；负数需调用方先转成补码的 64 位）。
  void varint(int value) {
    var v = value;
    while (true) {
      final b = v & 0x7f;
      v = v >>> 7;
      if (v == 0) {
        _b.addByte(b);
        return;
      }
      _b.addByte(b | 0x80);
    }
  }

  /// 写「tag = (field << 3) | wire」。
  void _tag(int field, int wire) => varint((field << 3) | wire);

  /// 字段：uint32 / int64 / bool（wire = 0）。
  void writeInt(int field, int value) {
    _tag(field, 0);
    varint(value);
  }

  /// 字段：bytes（wire = 2）。
  void writeBytes(int field, List<int> bytes) {
    _tag(field, 2);
    varint(bytes.length);
    _b.add(bytes);
  }

  /// 字段：string（wire = 2，UTF-8）。
  void writeString(int field, String s) => writeBytes(field, utf8.encode(s));

  /// 字段：嵌套消息（wire = 2）。先编码子消息再作为 bytes 写入。
  void writeMessage(int field, PbWriter sub) =>
      writeBytes(field, sub.toBytes());

  Uint8List toBytes() => _b.toBytes();

  int get length => _b.length;
}

/// protobuf 读取器。
class PbReader {
  PbReader(this._data, [this._offset = 0]);

  final Uint8List _data;
  int _offset;

  int get offset => _offset;
  bool get atEnd => _offset >= _data.length;

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_offset >= _data.length) {
        throw const FormatException('protobuf varint 越界');
      }
      final b = _data[_offset++];
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
      if (shift > 63) throw const FormatException('protobuf varint 过长');
    }
  }

  /// 读一个字段头，返回 (field, wire)。
  (int, int) readTag() {
    final t = readVarint();
    return (t >> 3, t & 7);
  }

  Uint8List readBytes() {
    final len = readVarint();
    if (_offset + len > _data.length) {
      throw const FormatException('protobuf bytes 越界');
    }
    final out = Uint8List.sublistView(_data, _offset, _offset + len);
    _offset += len;
    return out;
  }

  String readString() => utf8.decode(readBytes());

  /// 跳过未知字段（保证向后兼容：服务端加了新字段也不会让我们解析失败）。
  void skip(int wire) {
    switch (wire) {
      case 0:
        readVarint();
      case 2:
        readBytes();
      case 1:
        _offset += 8; // fixed64
      case 5:
        _offset += 4; // fixed32
      default:
        throw FormatException('未知 protobuf wire type: $wire');
    }
  }
}
