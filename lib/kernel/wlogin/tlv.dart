/// L2 协议内核：WLogin TLV 编解码器
///
/// WLogin（oicq.wlogin_sdk）是 QQ 登录鉴权的核心协议。基于对目标 APK 全 41 个
/// dex 的静态扫描结果，本文件实现 TLV 容器的通用编解码，用于还原登录报文布局。
///
/// TLV 结构（逆向共识 + 本项目扫描证据 tlv_t104/t106/t116/t126/...）：
///     +--------+--------+------------------+
///     | type   | len    | value            |
///     | uint16 | uint16 | len 字节          |
///     +--------+--------+------------------+
///     全部小端序（LE）
///
/// 对应 Python 实现：qqclient-python/kernel/wlogin/tlv.py
library;

import 'dart:typed_data';

import '../../infra/coder.dart';

/// 单个 TLV 字段。type 用十六进制语义（0x104 == tlv_t104）。
class Tlv {
  final int type;
  final Uint8List value;

  const Tlv(this.type, this.value);

  /// 人类可读名：0x104 -> 'tlv_t104'（QQ 惯例的 t 前缀 + 十六进制）
  String get name => 'tlv_t${type.toRadixString(16)}';

  Uint8List encode() =>
      (ByteWriter()..u16(type)..u16(value.length)..raw(value)).build();

  @override
  String toString() {
    final preview = value
        .take(16)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final more = value.length > 16 ? '...' : '';
    return '<$name len=${value.length} $preview$more>';
  }
}

/// 一组 TLV 构成的报文。WLogin 的请求/响应即 TLV 序列。
class TlvPacket {
  final List<Tlv> items = [];

  TlvPacket add(int type, List<int> value) {
    items.add(Tlv(type, Uint8List.fromList(value)));
    return this;
  }

  Tlv? get(int type) {
    for (final t in items) {
      if (t.type == type) return t;
    }
    return null;
  }

  List<Tlv> getAll(int type) => items.where((t) => t.type == type).toList();

  int get length => items.length;
  bool get isEmpty => items.isEmpty;

  Uint8List encode() {
    final bb = BytesBuilder(copy: false);
    for (final t in items) {
      bb.add(t.encode());
    }
    return bb.toBytes();
  }

  /// MSF/WLogin 外层常带 uint32 总长度前缀
  Uint8List encodeWithPrefix() {
    final body = encode();
    return (ByteWriter()..u32(body.length)..raw(body)).build();
  }

  /// 解析 TLV 序列。[strict]=false 时遇到坏字段即停止（容错尾部填充）。
  static TlvPacket decode(List<int> data, {bool strict = false}) {
    final r = ByteReader(data);
    final pkt = TlvPacket();
    while (r.remaining >= 4) {
      final start = r.pos;
      final t = r.readUint16();
      final len = r.readUint16();
      if (r.remaining < len) {
        if (strict) {
          throw FormatException(
              'at $start: need $len bytes, only ${r.remaining} left');
        }
        break;
      }
      pkt.items.add(Tlv(t, r.read(len)));
    }
    return pkt;
  }

  String summary() {
    final sb = StringBuffer('TlvPacket(${items.length} items)');
    for (final t in items) {
      sb.write('\n  $t');
    }
    return sb.toString();
  }
}

/// 已逆向确认存在的 QQ 特化 TLV 常量（来自全 dex 扫描）
const Map<int, String> tlvKnownTypes = {
  0x104: '环境信息（版本/SDK/设备）',
  0x105: '头像/账号信息 hash',
  0x106: '密码 hash（TEA 加密）',
  0x108: '验证码 / 强制跳转信息',
  0x109: '好友/消息相关标记',
  0x10c: '登录票据（A2 相关）',
  0x113: '登录结果标记',
  0x116: '机器码 / 设备标识',
  0x124: '临时票据',
  0x126: '设备密码 / 登录校验',
  0x128: '设备信息扩展',
  0x142: 'A2 / 登录票据',
  0x145: '加密标记',
  0x147: '身份信息',
  0x16e: '登录成功后的会话票据',
  0x172: '登录状态标记',
  0x174: '登录附加信息',
  0x18: '密码校验 / 短信相关',
  0x191: '设备信息（新）',
  0x192: '会话信息',
  0x202: '登录结果扩展',
  0x52d: '设备指纹（52d 系列，QQ 特化）',
  0x544: '新版鉴权票据（544 系列）',
  0x545: '新版鉴权扩展',
  0x548: '安全校验',
  0x553: '风控 / 新特性标记',
};
