/// L2 协议内核：JCE 编解码（WUP 协议的数据层）
///
/// 用途：业务请求/响应的序列化——`StatSvc.register`（上线注册）等服务的
/// 参数与响应都是 JCE 结构。
///
/// ## 证据（规则逐条对照官方反编译）
///
/// 官方 8.9.50 的 JCE 是**纯 Java**（与包编码不同，那层在 native）：
/// `com.qq.taf.jce.JceOutputStream` / `com.qq.taf.RequestPacket`（jadx 单类
/// 反编译，产物在 `../analysis/_decompiled` 外的 scratch 反编译目录，
/// 结论逐条记录如下）：
///
/// | 规则 | 官方写法 | 本实现 |
/// |---|---|---|
/// | 头字节 | `writeHead(type, tag)`：tag<15 → `type\|(tag<<4)`；<256 → `type\|0xF0`+tag；否则抛错 | 同 |
/// | 字符串 | UTF-8 字节数 >255 → head(7)+u32 长度；否则 head(6)+u8 长度 | 同 |
/// | 字节数组 | head(13)+head(0,0)+长度元素+原始字节 | 同 |
/// | Map | head(8)+计数(tag 0)+每对(键 tag 0 / 值 tag 1) | 同 |
/// | 集合 | head(9)+计数(tag 0)+每个元素 tag 0 | 同 |
/// | 结构体 | head(10)+字段+head(11, 0) | 同 |
/// | 整数收窄 | 0→head(12)；[-128,127]→head(0)+i8；[-32768,32767]→head(1)+i16；[-2^31,2^31-1]→head(2)+i32；否则 head(3)+i64 | 同 |
/// | 布尔 | `write(boolean)` → `write(byte 0/1)` | 同 |
/// | WUP 包装 | `RequestPacket.writeTo`：1=version 2=pktType 3=msgType 4=requestId 5=service 6=method 7=payload 8=timeout 9=context 10=status | [encodeWrapper] |
///
/// 参考实现（js 时代 oicq，可跑）：`../analysis/_ref/oicq-run-js/lib/algo/jce/`；
/// 黄金向量：`../analysis/scripts/gen_jce_vectors.cjs`，
/// 见 `tool/qq8_jce_selftest.dart`。
///
/// 本文件是纯 Dart。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../infra/coder.dart';

// 类型标签（官方 `JceStruct` 常量值）。
const int _tInt8 = 0;
const int _tInt16 = 1;
const int _tInt32 = 2;
const int _tInt64 = 3;
const int _tFloat = 4;
const int _tDouble = 5;
const int _tString1 = 6;
const int _tString4 = 7;
const int _tMap = 8;
const int _tList = 9;
const int _tStructBegin = 10;
const int _tStructEnd = 11;
const int _tZero = 12;
const int _tSimpleList = 13;

/// JCE 编解码错误。
class Qq8JceException implements Exception {
  final String message;
  Qq8JceException(this.message);

  @override
  String toString() => 'Qq8JceException: $message';
}

/// 嵌套结构（对应参考实现的 `Nested`）：在元素里写成
/// `head(10) + data + head(11, 0)`。
class Qq8JceNested {
  final Uint8List data;
  const Qq8JceNested(this.data);
}

/// 结构体结束哨兵（解码内部用）。
const Object _structEnd = _StructEnd();

class _StructEnd {
  const _StructEnd();
}

/// JCE 编解码。
abstract final class Qq8Jce {
  // ------------------------------------------------------------------
  // 编码
  // ------------------------------------------------------------------

  /// 编码 `tag → 值`。**值为 null 的项跳过**（与参考实现一致——
  /// 业务结构里"可选字段"就是靠这个表达）。
  static Uint8List encode(Map<int, Object?> fields) {
    final w = ByteWriter();
    for (final e in fields.entries) {
      final v = e.value;
      if (v == null) continue;
      _writeElement(w, e.key, v);
    }
    return w.build();
  }

  /// 编码结构体：`tag 0` 的 `STRUCT_BEGIN … STRUCT_END`。
  ///
  /// 对应参考实现的 `encodeStruct`（= `encode([encodeNested(fields)])`），
  /// 即业务请求里 struct 层的字节。
  static Uint8List encodeStruct(Map<int, Object?> fields) =>
      encode(<int, Object?>{0: Qq8JceNested(encode(fields))});

  /// WUP 请求包装（官方 `com.qq.taf.RequestPacket.writeTo` 的十字段）。
  ///
  /// [attributes] 是"属性表"：键 = 结构名（如 `SvcReqRegister`），
  /// 值 = 该结构的 [encodeStruct] 字节——与 `StatSvc.register` 一致。
  static Uint8List encodeWrapper({
    required String service,
    required String method,
    required Map<String, Uint8List> attributes,
    int requestId = 0,
  }) {
    final payload =
        encode(<int, Object?>{0: Map<Object?, Object?>.of(attributes)});
    return encode(<int, Object?>{
      1: 3, // iVersion（参考实现默认 3）
      2: 0, // cPacketType
      3: 0, // iMessageType
      // iRequestId：推送回执（OnlinePush.RespPush）要放推送的 seq，
      // 其余请求是 0——参考实现 `jce.encodeWrapper(..., seq)` 的第 4 个参数
      // 就是它。
      4: requestId,
      5: service, // sServantName
      6: method, // sFuncName
      7: payload, // sBuffer
      8: 0, // iTimeout
      9: <Object?, Object?>{}, // context
      10: <Object?, Object?>{}, // status
    });
  }

  /// 写一个元素：头 + 体。类型收窄规则见文件头表格。
  static void _writeElement(ByteWriter w, int tag, Object? value) {
    if (value is Qq8JceNested) {
      _writeHead(w, _tStructBegin, tag);
      w.raw(value.data);
      _writeHead(w, _tStructEnd, 0);
      return;
    }
    if (value is bool) {
      _writeElement(w, tag, value ? 1 : 0); // 官方 write(boolean) 即 0/1
      return;
    }
    if (value is int) {
      if (value == 0) {
        _writeHead(w, _tZero, tag);
      } else if (value >= -128 && value <= 127) {
        _writeHead(w, _tInt8, tag);
        w.u8(value & 0xff);
      } else if (value >= -32768 && value <= 32767) {
        _writeHead(w, _tInt16, tag);
        w.u16(value & 0xffff);
      } else if (value >= -2147483648 && value <= 2147483647) {
        _writeHead(w, _tInt32, tag);
        w.u32(value & 0xffffffff);
      } else {
        _writeHead(w, _tInt64, tag);
        w.u64(value);
      }
      return;
    }
    if (value is double) {
      _writeHead(w, _tDouble, tag);
      w.raw(_f64(value));
      return;
    }
    if (value is String) {
      final bytes = utf8.encode(value);
      if (bytes.length > 0xff) {
        _writeHead(w, _tString4, tag);
        w.u32(bytes.length);
      } else {
        _writeHead(w, _tString1, tag);
        w.u8(bytes.length);
      }
      w.raw(bytes);
      return;
    }
    if (value is Uint8List) {
      _writeHead(w, _tSimpleList, tag);
      _writeHead(w, 0, 0); // 字节元素的头（类型 0、tag 0）
      _writeElement(w, 0, value.length);
      w.raw(value);
      return;
    }
    if (value is List) {
      _writeHead(w, _tList, tag);
      _writeElement(w, 0, value.length);
      for (final item in value) {
        _writeElement(w, 0, item);
      }
      return;
    }
    if (value is Map) {
      _writeHead(w, _tMap, tag);
      _writeElement(w, 0, value.length);
      for (final entry in value.entries) {
        _writeElement(w, 0, entry.key);
        _writeElement(w, 1, entry.value);
      }
      return;
    }
    throw Qq8JceException('不支持的类型: ${value.runtimeType}');
  }

  /// 头字节：tag<15 → 单字节；<256 → 两字节；否则抛错（官方同）。
  static void _writeHead(ByteWriter w, int type, int tag) {
    if (tag < 15) {
      w.u8(type | (tag << 4));
    } else if (tag < 256) {
      w.u8(type | 0xf0);
      w.u8(tag);
    } else {
      throw Qq8JceException('tag 超出范围: $tag（官方上限 255）');
    }
  }

  // ------------------------------------------------------------------
  // 解码
  // ------------------------------------------------------------------

  /// 解码：返回 `tag → 值`。
  ///
  /// 值类型：整数 → int；浮点 → double；字符串 → String；
  /// 字节数组 → Uint8List；列表 → List；映射/结构体 → Map。
  static Map<int, Object?> decode(Uint8List blob) {
    final r = ByteReader(blob);
    final out = <int, Object?>{};
    while (r.remaining > 0) {
      final e = _readElement(r);
      out[e.tag as int] = e.value;
    }
    return out;
  }

  /// 响应侧便捷解码（对应参考实现 `index.js` 的 `decode`）：
  /// 解 WUP 包装 → `sBuffer(7)` → 属性表 → 第一个属性 → 再解出结构。
  static Map<int, Object?> decodeWrapper(Uint8List blob) {
    final wrapper = decode(blob);
    final payload = wrapper[7];
    if (payload is! Uint8List) {
      throw Qq8JceException('WUP 包装里没有 sBuffer(7)（实际 ${payload.runtimeType}）');
    }
    final attrs = decode(payload)[0];
    if (attrs is! Map || attrs.isEmpty) {
      throw Qq8JceException('WUP 属性表为空或类型不对');
    }
    Object? nested = attrs[attrs.keys.first];
    if (nested is! Uint8List) {
      if (nested is Map && nested.isNotEmpty) {
        nested = nested[nested.keys.first];
      }
    }
    if (nested is! Uint8List) {
      throw Qq8JceException('属性表里的结构不是字节数组（实际 ${nested.runtimeType}）');
    }
    final fields = decode(nested);
    final first = fields[0];
    return first is Map<int, Object?> ? first : fields;
  }

  /// 只读头（类型 + tag），不读体——供 SIMPLE_LIST 的内层标记位使用。
  static ({int tag, int type}) _readHead(ByteReader r) {
    final head = r.readUint8();
    final type = head & 0xf;
    var tag = (head & 0xf0) >> 4;
    if (tag == 0xf) tag = r.readUint8();
    return (tag: tag, type: type);
  }

  /// 读一个元素：`(_tag, _value)`。
  static ({int? tag, Object? value}) _readElement(ByteReader r) {
    final head = _readHead(r);
    final value = _readBody(r, head.type);
    return (tag: head.tag, value: value);
  }

  static Object? _readBody(ByteReader r, int type) {
    switch (type) {
      case _tZero:
        return 0;
      case _tInt8:
        final v = r.readUint8();
        return v > 127 ? v - 256 : v;
      case _tInt16:
        final v = r.readUint16();
        return v > 32767 ? v - 65536 : v;
      case _tInt32:
        final v = r.readUint32();
        return v > 2147483647 ? v - 4294967296 : v;
      case _tInt64:
        return r.readUint64();
      case _tFloat:
        return ByteData.sublistView(r.read(4)).getFloat32(0, Endian.big);
      case _tDouble:
        return ByteData.sublistView(r.read(8)).getFloat64(0, Endian.big);
      case _tString1:
        final len = r.readUint8();
        return len == 0 ? '' : utf8.decode(r.read(len));
      case _tString4:
        final len = r.readUint32();
        return len == 0 ? '' : utf8.decode(r.read(len));
      case _tSimpleList:
        _readHead(r); // 只消费内层元素的头（类型 0、tag 0，无体）
        final len = _readElement(r).value as int;
        return r.read(len);
      case _tList:
        final len = _readElement(r).value as int;
        final list = <Object?>[];
        for (var i = 0; i < len; i++) {
          list.add(_readElement(r).value);
        }
        return list;
      case _tMap:
        final len = _readElement(r).value as int;
        final map = <Object?, Object?>{};
        for (var i = 0; i < len; i++) {
          final k = _readElement(r).value;
          map[k] = _readElement(r).value;
        }
        return map;
      case _tStructBegin:
        final fields = <int, Object?>{};
        while (true) {
          final e = _readElement(r);
          if (identical(e.value, _structEnd)) return fields;
          fields[e.tag as int] = e.value;
        }
      case _tStructEnd:
        return _structEnd;
      default:
        throw Qq8JceException('未知的 JCE 类型: $type');
    }
  }

  static Uint8List _f64(double v) {
    final b = ByteData(8)..setFloat64(0, v, Endian.big);
    return b.buffer.asUint8List();
  }
}
