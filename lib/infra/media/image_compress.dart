/// L1 基础设施：发送前的图片预处理（体积/尺寸压缩）。
///
/// ## 为什么放在 L1 而不是 UI
/// 压缩是对"一坨字节"的纯计算，和界面无关；以后群文件缩略图、头像上传也
/// 会用到它。放 UI 里就得在 L4 复制一份，更糟的是 L1–L3 都不能 import
/// Flutter（AGENTS.md §1.1），而 UI 层能拿到的一切编解码 API（dart:ui 的
/// instantiateImageCodec）在 L1 都不能用 ⇒ 只能选纯 Dart 的 package:image。
///
/// ## 为什么不无脑压
/// 重编码一次就要重新采样色度、丢元数据，画质只降不升。所以只在三种情况下
/// 动手：①字节数超过 [compressAboveBytes]（微信/QQ 的照片动辄 8–15 MiB，
/// 群里几百张图谁都不想等）；②长边超过 [maxEdge]（2400 万像素的相机原图
/// 解到 240px 缩略图是纯浪费）；③不压缩就超过 [maxUploadBytes] 根本发不出去。
/// 其余情况原样上传——服务端按 md5 收藏，原图还能少一次有损转换。
///
/// ## 已知代价
/// 解码大 JPEG 在纯 Dart 里要几秒，所以 [prepare] 把整段计算丢进
/// [Isolate.run]，UI 线程不卡；代价是这一轮会多复制一次字节（Isolate 传参
/// 是拷贝语义，Uint8List 走的是 TransferableTypedData 优化路径）。GIF/动图
/// 重编码会丢帧，所以动图**永不重编码**：够小就原样发，超过 30 MiB 直接报错。
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 服务端允许的最大图片字节数（与 `Qq8ImageProbe` 的上限一致，联调实测
/// 超过这个值 PicUp 直接回 -5503001）。
const int imageMaxUploadBytes = 30 * 1024 * 1024;

/// 超过这个字节数才考虑压缩（5 MiB：普通截图/表情远小于它，手机直出照片
/// 普遍超过它，这条线正好把"该压"和"不该压"分开）。
const int imageCompressAboveBytes = 5 * 1024 * 1024;

/// 压缩后长边的上限（像素）。2560 是"2K 屏全屏看仍清晰"和"体积可控"的折中。
const int imageMaxEdge = 2560;

/// 图片本身有问题（认不出格式/空文件）。
class ImageFormatException implements Exception {
  const ImageFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 压缩了也不够小（只能是动图或极端情况）。
class ImageTooLargeException implements Exception {
  const ImageTooLargeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 预处理结果。
class PreparedImage {
  const PreparedImage({
    required this.bytes,
    required this.changed,
    required this.format,
    required this.width,
    required this.height,
    required this.note,
    this.animated = false,
  });

  /// 要上传的字节（[changed] 为 false 时就是入参本身）。
  final Uint8List bytes;

  /// 是否真的重编码过（false 表示原图直传）。
  final bool changed;

  /// 输出格式：`jpeg` / `png` / `original`。
  final String format;

  /// 输出宽高（像素），给气泡算占位宽高比用。
  final int width;
  final int height;

  /// 给人看的一行说明（"原图" / "已压缩 12.4 MiB → 2.1 MiB"）。
  final String note;

  /// 是否动图（GIF/多帧 WebP）——动图永远不重编码。
  final bool animated;

  int get size => bytes.length;
}

/// 发送前图片预处理入口。
///
/// [bytes] 是文件原始字节；[name] 只用于日志/报错文案里的文件名。
class ImageCompressor {
  const ImageCompressor._();

  /// 异步版：先做一次"只看文件头"的快速判定，绝大多数图（截图、表情、
  /// 聊天里转存的小图）连解码都不用就能直接放行；只有真的可能需要压缩的
  /// 才丢进 Isolate（大图纯 Dart 解码要几秒，不该占 UI 线程）。
  ///
  /// 这个快速通道还有个副作用：widget 测试跑在 FakeAsync 里，真实 Isolate
  /// 的回包永远不会被调度（测试会挂），快速通道让"小图直传"这条最常用的
  /// 路径在测试里也可达。
  static Future<PreparedImage> prepare(
    Uint8List bytes, {
    String name = '',
  }) async {
    final quick = quickPass(bytes, name: name);
    if (quick != null) return quick;
    return Isolate.run(() => prepareSync(bytes, name: name));
  }

  /// 读文件 + 预处理（UI 层唯一该调的入口）。
  ///
  /// 为什么不在这里用 `File.readAsBytes()`（异步）：读几十 KB 也是异步 IO，
  /// 而"发图"这条链路上真正贵的是大图解码，不是读盘。小文件（≤5 MiB）同步
  /// 读 + 文件头快速判定，整条链路几乎瞬时完成；只有大图才把"读盘 + 解码"
  /// 一起丢进 Isolate，UI 线程不碰。
  static Future<PreparedImage> prepareFile(
    String path, {
    String name = '',
  }) async {
    final file = File(path);
    final label = name.isEmpty ? '图片' : name;
    final size = file.lengthSync();
    if (size == 0) {
      throw ImageFormatException('$label 是空文件');
    }
    if (size > imageMaxUploadBytes) {
      throw ImageTooLargeException(
        '$label 有 ${_mib(size)}，超过服务端 ${_mib(imageMaxUploadBytes)} 上限，发不出去',
      );
    }
    if (size <= imageCompressAboveBytes) {
      final bytes = file.readAsBytesSync();
      final quick = quickPass(bytes, name: name);
      if (quick != null) return quick;
      return Isolate.run(() => prepareSync(bytes, name: name));
    }
    // 大图：读盘也别占 UI 线程（30 MiB 的读 + 解码都在 Isolate 里）。
    return Isolate.run(
      () => prepareSync(File(path).readAsBytesSync(), name: name),
    );
  }

  /// 只读文件头就能下结论的情况：格式认得出、宽高读得出、体积没超、长边没超
  /// ⇒ 原图直传，不解码。判断不了（webp 变体、尺寸字段异常）就返回 null，
  /// 交给 [prepareSync] 走完整解码。
  static PreparedImage? quickPass(Uint8List bytes, {String name = ''}) {
    if (bytes.isEmpty) return null;
    final format = _sniff(bytes);
    final size = _headerSize(bytes, format);
    if (size == null) return null;
    final (w, h) = size;
    if (w <= 0 || h <= 0) return null;
    if (bytes.length > imageCompressAboveBytes ||
        w > imageMaxEdge ||
        h > imageMaxEdge) {
      return null;
    }
    return PreparedImage(
      bytes: bytes,
      changed: false,
      format: 'original',
      width: w,
      height: h,
      note: '原图 ${_mib(bytes.length)}',
      animated: format == 'gif',
    );
  }

  /// 从文件头读宽高（不解码像素）。认不出的格式返回 null。
  static (int, int)? _headerSize(Uint8List b, String format) {
    int be32(int o) =>
        (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
    int le32(int o) =>
        b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
    switch (format) {
      case 'png': // 签名 8 字节 + IHDR 长度/类型各 4 字节 → 宽在 16、高在 20
        if (b.length < 24) return null;
        return (be32(16), be32(20));
      case 'gif': // "GIF89a" + 逻辑屏宽高（小端 16 位）
        if (b.length < 10) return null;
        return (b[6] | (b[7] << 8), b[8] | (b[9] << 8));
      case 'bmp':
        if (b.length < 26) return null;
        return (le32(18), le32(22).abs());
      case 'jpeg':
        // 逐段扫到 SOFn（0xC0–0xCF，排除 C4/C8/CC），段内高在 +5、宽在 +7。
        var i = 2;
        while (i + 9 < b.length) {
          if (b[i] != 0xFF) {
            i++;
            continue;
          }
          final m = b[i + 1];
          if (m == 0xFF) {
            i++;
            continue;
          }
          if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) {
            i += 2;
            continue;
          }
          final len = (b[i + 2] << 8) | b[i + 3];
          if (len < 2) return null;
          final isSof =
              m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC;
          if (isSof) {
            if (i + 9 >= b.length) return null;
            final hh = (b[i + 5] << 8) | b[i + 6];
            final ww = (b[i + 7] << 8) | b[i + 8];
            return (ww, hh);
          }
          i += 2 + len;
        }
        return null;
      default:
        return null;
    }
  }

  /// 同步版：给单元测试和已经处在后台 isolate 里的调用方用。
  static PreparedImage prepareSync(Uint8List bytes, {String name = ''}) {
    final label = name.isEmpty ? '图片' : name;
    if (bytes.isEmpty) {
      throw ImageFormatException('$label 是空文件');
    }
    final format = _sniff(bytes);
    img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } on Object catch (e) {
      throw ImageFormatException('$label 解码失败：$e');
    }
    if (decoded == null) {
      throw ImageFormatException('$label 认不出图片格式（文件头=$format）');
    }

    final w = decoded.width;
    final h = decoded.height;
    final animated = decoded.numFrames > 1;
    final longest = w > h ? w : h;
    final needResize = longest > imageMaxEdge;
    final needShrink = bytes.length > imageCompressAboveBytes;

    // 又小又不够大：原样发，少一次有损转换。
    if (!needResize && !needShrink) {
      return PreparedImage(
        bytes: bytes,
        changed: false,
        format: 'original',
        width: w,
        height: h,
        note: '原图 ${_mib(bytes.length)}',
        animated: animated,
      );
    }

    // 动图（GIF / 多帧 WebP）重编码会丢帧，宁可不压。
    if (animated || format == 'gif') {
      if (bytes.length <= imageMaxUploadBytes) {
        return PreparedImage(
          bytes: bytes,
          changed: false,
          format: 'original',
          width: w,
          height: h,
          note: '动图不压缩 ${_mib(bytes.length)}',
          animated: true,
        );
      }
      throw ImageTooLargeException(
        '$label 是动图且超过 ${_mib(imageMaxUploadBytes)}，服务端不收（重编码会丢帧，故不压）',
      );
    }

    var work = img.bakeOrientation(decoded);
    if (longest > imageMaxEdge) {
      work = w >= h
          ? img.copyResize(
              work,
              width: imageMaxEdge,
              interpolation: img.Interpolation.average,
            )
          : img.copyResize(
              work,
              height: imageMaxEdge,
              interpolation: img.Interpolation.average,
            );
    }

    // 有 alpha 的图先试 PNG（保透明）；PNG 压不下来（照片型 PNG 常见）再转
    // JPEG 并放弃透明——比发不出去强。
    var outFormat = work.hasAlpha ? 'png' : 'jpeg';
    var out = outFormat == 'png'
        ? img.encodePng(work, level: 6)
        : img.encodeJpg(work, quality: 85);

    if (out.length > imageMaxUploadBytes && outFormat == 'jpeg') {
      for (final q in const <int>[75, 65, 55, 45]) {
        out = img.encodeJpg(work, quality: q);
        if (out.length <= imageMaxUploadBytes) break;
      }
    } else if (out.length > imageMaxUploadBytes && outFormat == 'png') {
      out = img.encodeJpg(work, quality: 80);
      outFormat = 'jpeg';
    }

    if (out.length > imageMaxUploadBytes) {
      throw ImageTooLargeException(
        '$label 压到 ${_mib(out.length)} 仍超过 ${_mib(imageMaxUploadBytes)}，发不出去',
      );
    }
    // 压完反而更大（小尺寸高质量图常见）：除非原图本来超标，否则退回原图。
    if (out.length >= bytes.length && bytes.length <= imageMaxUploadBytes) {
      return PreparedImage(
        bytes: bytes,
        changed: false,
        format: 'original',
        width: w,
        height: h,
        note: '原图 ${_mib(bytes.length)}（重编码无收益）',
      );
    }

    return PreparedImage(
      bytes: Uint8List.fromList(out),
      changed: true,
      format: outFormat,
      width: work.width,
      height: work.height,
      note:
          '已压缩 ${_mib(bytes.length)} → ${_mib(out.length)}'
          '${work.width == w ? '' : '（${work.width}×${work.height}）'}',
    );
  }

  /// 文件头嗅探（只用于报错文案和"是不是 GIF"的判断）。
  static String _sniff(Uint8List b) {
    bool at(List<int> sig, [int off = 0]) {
      if (b.length < off + sig.length) return false;
      for (var i = 0; i < sig.length; i++) {
        if (b[off + i] != sig[i]) return false;
      }
      return true;
    }

    if (at(const <int>[0xFF, 0xD8])) return 'jpeg';
    if (at(const <int>[0x89, 0x50, 0x4E, 0x47])) return 'png';
    if (at(const <int>[0x47, 0x49, 0x46, 0x38])) return 'gif';
    if (at(const <int>[0x42, 0x4D])) return 'bmp';
    if (at(const <int>[0x52, 0x49, 0x46, 0x46]) &&
        at(const <int>[0x57, 0x45, 0x42, 0x50], 8)) {
      return 'webp';
    }
    return 'unknown';
  }

  static String _mib(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}
