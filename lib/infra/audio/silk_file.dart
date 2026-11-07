// SILK v3 文件容器读写 + AMR 格式识别。
//
// SILK v3 文件布局（腾讯/微信 silk 同款）：
//   头 10 字节：0x02 '#' '!' 'S' 'I' 'L' 'K' '_' 'V' '3'  即 "\x02#!SILK_V3"
//   之后重复：[2 字节小端长度][该长度的帧数据]
//
// AMR：仅识别（"\#!AMR\n"，或 "\#!AMR-WB\n"），不解析帧。
library;

// 见 silk_codec.dart 的同名说明。
// ignore_for_file: prefer_interpolation_to_compose_strings

import 'dart:typed_data';

/// 容器格式。
enum SilkFormat {
  /// SILK v3（可逐帧解析）
  silkV3,

  /// AMR / AMR-WB（仅识别，不解析）
  amr,

  /// 未知
  unknown,
}

/// SILK / AMR 文件。
class SilkFile {
  SilkFile({required this.frames, required this.format});

  /// SILK 帧列表（AMR 时为空）。
  final List<Uint8List> frames;

  /// 识别出的格式。
  final SilkFormat format;

  /// 是否为 AMR 标记。
  bool get isAmr => format == SilkFormat.amr;

  /// SILK v3 头：0x02 + "#!SILK_V3"。
  static const List<int> silkV3Header = <int>[
    0x02, //
    0x23, 0x21, 0x53, 0x49, 0x4C, 0x4B, 0x5F, 0x56, 0x33,
  ];

  /// AMR 头："#!AMR\n"。
  static const List<int> amrHeader = <int>[0x23, 0x21, 0x41, 0x4D, 0x52, 0x0A];

  /// 是否为 SILK v3 文件。
  static bool looksLikeSilk(Uint8List bytes) {
    if (bytes.length < silkV3Header.length) {
      return false;
    }
    for (var i = 0; i < silkV3Header.length; i++) {
      if (bytes[i] != silkV3Header[i]) {
        return false;
      }
    }
    return true;
  }

  /// 是否为 AMR 文件（仅识别头，支持 "#!AMR\n" 与 "#!AMR-WB\n"）。
  static bool looksLikeAmr(Uint8List bytes) {
    if (bytes.length < amrHeader.length) {
      return false;
    }
    // "#!AMR"
    const magic = <int>[0x23, 0x21, 0x41, 0x4D, 0x52];
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        return false;
      }
    }
    final next = bytes[magic.length];
    if (next == 0x0A) {
      return true; // "#!AMR\n"
    }
    // "#!AMR-WB\n"
    const wbTail = <int>[0x2D, 0x57, 0x42, 0x0A]; // "-WB\n"
    if (bytes.length < magic.length + wbTail.length) {
      return false;
    }
    for (var i = 0; i < wbTail.length; i++) {
      if (bytes[magic.length + i] != wbTail[i]) {
        return false;
      }
    }
    return true;
  }

  /// 解析字节流。SILK 返回逐帧列表；AMR 返回空帧列表并给出 amr 标记；
  /// 其它抛 [FormatException]。
  static SilkFile parse(Uint8List bytes) {
    if (looksLikeAmr(bytes)) {
      return SilkFile(frames: const <Uint8List>[], format: SilkFormat.amr);
    }
    if (!looksLikeSilk(bytes)) {
      throw const FormatException('不是 SILK v3 文件（缺少 0x02#!SILK_V3 头）');
    }
    final frames = <Uint8List>[];
    var pos = silkV3Header.length;
    while (pos < bytes.length) {
      if (pos + 2 > bytes.length) {
        throw const FormatException('SILK 帧长度字段被截断');
      }
      final len = bytes[pos] | (bytes[pos + 1] << 8);
      pos += 2;
      if (pos + len > bytes.length) {
        throw FormatException(
          'SILK 帧被截断：声明 ' +
              len.toString() +
              ' 字节，仅余 ' +
              (bytes.length - pos).toString(),
        );
      }
      frames.add(Uint8List.fromList(bytes.sublist(pos, pos + len)));
      pos += len;
    }
    return SilkFile(frames: frames, format: SilkFormat.silkV3);
  }

  /// 将帧列表封装成 SILK v3 文件字节。
  static Uint8List build(List<Uint8List> frames) {
    var total = silkV3Header.length;
    for (final f in frames) {
      if (f.length > 0xFFFF) {
        throw ArgumentError('单帧超过 65535 字节，无法写入 2 字节长度字段');
      }
      total += 2 + f.length;
    }
    final out = Uint8List(total);
    out.setAll(0, silkV3Header);
    var pos = silkV3Header.length;
    for (final f in frames) {
      out[pos] = f.length & 0xFF;
      out[pos + 1] = (f.length >> 8) & 0xFF;
      pos += 2;
      out.setAll(pos, f);
      pos += f.length;
    }
    return out;
  }
}
