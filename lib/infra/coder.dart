/// L1 基础设施：字节流读写器
///
/// ## 字节序：默认大端（已由反编译证实）
///
/// 证据来源：`oicq.wlogin_sdk.tools.util`
/// ```java
/// // 读：首字节是高位
/// public static int buf_to_int16(byte[] b, int i) {
///     return ((b[i] << 8) & 0xFF00) + ((b[i+1] << 0) & 0xFF);
/// }
/// // 写：高字节写到低位偏移
/// public static void int16_to_buf(byte[] b, int i, int v) {
///     b[i + 1] = (byte) (v >> 0);
///     b[i + 0] = (byte) (v >> 8);
/// }
/// ```
/// `int32_to_buf` / `int64_to_buf` 同为高字节在前。
///
/// 因此 WLogin 层（TLV 头、长度字段）一律 **大端（Big-Endian）**。
///
/// ⚠️ 本实现早期版本误用小端，已于 M2 依据上述证据修正。
/// 由于 QQ 协议栈各层字节序未必一致（native MSF 层可能不同），
/// 本文件同时提供显式的小端方法 [u16le] / [u32le] / `readUint16Le` 等，
/// 供其他层按各自证据选用——不依赖「默认值恰好对」。
library;

import 'dart:typed_data';

/// 顺序读字节流，越界抛出 [FormatException]（协议解析失败即视为报文损坏）。
class ByteReader {
  final Uint8List _buf;
  int _pos = 0;

  ByteReader(List<int> data)
      : _buf = data is Uint8List ? data : Uint8List.fromList(data);

  int get pos => _pos;
  int get remaining => _buf.length - _pos;
  int get length => _buf.length;

  /// 读取 n 字节
  Uint8List read(int n) {
    if (_pos + n > _buf.length) {
      throw FormatException('read $n bytes overflow at $_pos/${_buf.length}');
    }
    final out = Uint8List.sublistView(_buf, _pos, _pos + n);
    _pos += n;
    return out;
  }

  int readUint8() => read(1)[0];

  /// 大端 uint16（WLogin 默认）
  int readUint16() {
    final b = read(2);
    return (b[0] << 8) | b[1];
  }

  /// 显式小端 uint16
  int readUint16Le() {
    final b = read(2);
    return b[0] | (b[1] << 8);
  }

  /// 大端 uint32（WLogin 默认）
  int readUint32() {
    final b = read(4);
    return ((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]) & 0xFFFFFFFF;
  }

  /// 显式小端 uint32
  int readUint32Le() {
    final b = read(4);
    return (b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)) & 0xFFFFFFFF;
  }

  /// 大端有符号 int32
  int readInt32() {
    final v = readUint32();
    return v >= 0x80000000 ? v - 0x100000000 : v;
  }

  /// 大端 uint64（Dart 的 int 为 64 位，可直接承载）
  int readUint64() {
    final b = read(8);
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | b[i];
    }
    return v;
  }

  /// 长度前缀字节串：uint16 长度 + 内容（大端长度）
  Uint8List readBytesWithLen16() => read(readUint16());

  /// 长度前缀字节串：uint32 长度 + 内容（大端长度）
  Uint8List readBytesWithLen32() => read(readUint32());

  Uint8List peek(int n) => Uint8List.sublistView(
        _buf,
        _pos,
        (_pos + n).clamp(0, _buf.length),
      );

  /// 剩余全部字节
  Uint8List readRest() => read(remaining);
}

/// 顺序写字节流，方法链式调用。默认大端。
class ByteWriter {
  final BytesBuilder _bb = BytesBuilder(copy: false);

  ByteWriter u8(int v) {
    _bb.addByte(v & 0xFF);
    return this;
  }

  /// 大端 uint16
  ByteWriter u16(int v) {
    _bb.add([(v >> 8) & 0xFF, v & 0xFF]);
    return this;
  }

  /// 显式小端 uint16
  ByteWriter u16le(int v) {
    _bb.add([v & 0xFF, (v >> 8) & 0xFF]);
    return this;
  }

  /// 大端 uint32
  ByteWriter u32(int v) {
    _bb.add([
      (v >> 24) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
    ]);
    return this;
  }

  /// 显式小端 uint32
  ByteWriter u32le(int v) {
    _bb.add([
      v & 0xFF,
      (v >> 8) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 24) & 0xFF,
    ]);
    return this;
  }

  /// 大端 uint64
  ByteWriter u64(int v) {
    final b = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      b[i] = (v >> (8 * (7 - i))) & 0xFF;
    }
    _bb.add(b);
    return this;
  }

  ByteWriter raw(List<int> b) {
    _bb.add(b);
    return this;
  }

  /// uint16 长度前缀 + 内容，配合 [ByteReader.readBytesWithLen16]
  ByteWriter bytes16(List<int> b) => u16(b.length).raw(b);

  /// uint32 长度前缀 + 内容，配合 [ByteReader.readBytesWithLen32]
  ByteWriter bytes32(List<int> b) => u32(b.length).raw(b);

  Uint8List build() => _bb.toBytes();

  int get length => _bb.length;
}

/// 协议调试必备：十六进制 + ASCII 双栏
String hexdump(List<int> data, {int width = 16, String prefix = ''}) {
  final sb = StringBuffer();
  for (var off = 0; off < data.length; off += width) {
    final end = (off + width).clamp(0, data.length);
    final chunk = data.sublist(off, end);
    final hexpart = chunk
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ')
        .padRight(width * 3 - 1);
    final asc = chunk
        .map((b) => (b >= 32 && b < 127) ? String.fromCharCode(b) : '.')
        .join();
    sb.writeln(
        '$prefix${off.toRadixString(16).padLeft(8, '0')}  $hexpart  |$asc|');
  }
  return sb.toString();
}
