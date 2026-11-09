/// 把 [FaceEntry] 渲染成图片。
///
/// ## 两条渲染路径
///
/// * [FaceKind.lottie] —— 矢量。用 `LottieComposition.decodeGZip` 解（**必须显式
///   调它**：`LottieComposition.fromBytes` 的默认 decoder 只认 zip 的 PK 头，
///   gzip 会落到 `parseJsonBytes` 直接抛 "malformed JSON"），再用 `Lottie`
///   播放。矢量在 160px 预览下仍然锐利，这是 v2 换掉 animated WebP 的原因。
/// * [FaceKind.webp] —— 位图。`Image.memory` 直接吃。
///
/// ## 为什么要把内容裁到 bbox
///
/// 两种资源的留白完全不同：Lottie 画布 512×512 但内容可能只占 27%（「贴贴」），
/// 静态 WebP 是从官方 PNG 重编码的、内容占 92%~95%。直接 `BoxFit.contain` 铺满
/// 同一个框，同一个面板里就会出现「动态表情很小、静态表情很大」。所以这里先用
/// [FaceEntry.bbox] 把内容框放大到整个 [size]，视觉上两类才一致。
///
/// 实现用 `Transform.scale` + `Transform.translate`（不用 `FractionallySizedBox`
/// ——那个会改变布局尺寸，`Lottie` 的宽高是按画布给的，改了会变形）。外层
/// `ClipRect` 保证放大后不越出格子。
///
/// ## 解码缓存
///
/// Lottie 的解析（gzip 解压 + json 解析 + 图层建模）是毫秒级的重活，每帧都做
/// 会卡；所以按 entry.id 缓存在 [_compositions] 里。静态 WebP 不缓存字节——
/// `Image.memory` 自己按 `cacheWidth` 进 Flutter 的 imageCache。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import 'face_pack.dart';

/// Lottie 解析结果缓存（id → composition）。
///
/// 上限 64 条：一屏面板最多几十个动态表情，再多就淘汰最旧的。
final Map<String, LottieComposition> _compositions =
    <String, LottieComposition>{};
const int _compositionCacheLimit = 64;

/// 一条表情的图片视图。包没加载或条目缺失时返回 [fallback]（默认是名字文字）。
class FaceImage extends StatefulWidget {
  const FaceImage({
    super.key,
    required this.entry,
    required this.size,
    this.fallback,
    this.cacheWidth,
    this.repeat = true,
    this.cropToContent = true,
  });

  final FaceEntry entry;

  /// 逻辑边长。
  final double size;

  /// 取不到图时显示什么。
  final Widget? fallback;

  /// 解码尺寸提示（像素）。给小图能显著降内存。
  final int? cacheWidth;

  /// Lottie 是否循环播放（面板里循环，消息气泡里也循环——官方如此）。
  final bool repeat;

  /// 是否按 [FaceEntry.bbox] 裁掉画布留白（默认裁，让两类资源一样大）。
  final bool cropToContent;

  /// 行内用：跟随正文行高。
  factory FaceImage.inline(FaceEntry entry, {double size = 22}) =>
      FaceImage(entry: entry, size: size, cacheWidth: (size * 3).round());

  /// 面板网格用。
  factory FaceImage.grid(FaceEntry entry, {double size = 32}) =>
      FaceImage(entry: entry, size: size, cacheWidth: (size * 2).round());

  /// 长按预览用（放大到 160）。
  factory FaceImage.preview(FaceEntry entry) =>
      FaceImage(entry: entry, size: 160, cacheWidth: 192);

  @override
  State<FaceImage> createState() => _FaceImageState();
}

class _FaceImageState extends State<FaceImage> {
  LottieComposition? _composition;
  bool _failed = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _ensureComposition();
  }

  @override
  void didUpdateWidget(FaceImage old) {
    super.didUpdateWidget(old);
    if (old.entry.id != widget.entry.id) {
      _composition = null;
      _failed = false;
      _ensureComposition();
    }
  }

  void _ensureComposition() {
    if (widget.entry.kind != FaceKind.lottie) return;
    final cached = _compositions[widget.entry.id];
    if (cached != null) {
      _composition = cached;
      return;
    }
    if (_loading) return;
    _loading = true;
    unawaited(_load());
  }

  Future<void> _load() async {
    final pack = FacePack.instance;
    final bytes = pack?.bytesOf(widget.entry);
    if (bytes == null) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    try {
      final comp = await LottieComposition.decodeGZip(bytes);
      if (comp == null) {
        if (mounted) setState(() => _failed = true);
        return;
      }
      if (_compositions.length >= _compositionCacheLimit) {
        _compositions.remove(_compositions.keys.first);
      }
      _compositions[widget.entry.id] = comp;
      if (mounted) setState(() => _composition = comp);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Widget _fallback() =>
      widget.fallback ??
      SizedBox(
        width: widget.size,
        height: widget.size,
        child: FittedBox(
          child: Text(widget.entry.name, style: const TextStyle(fontSize: 12)),
        ),
      );

  /// 把内容框放大到整个 [FaceImage.size]。
  ///
  /// bbox 是相对画布的归一化矩形：内容占 `[x0,y0]..[x1,y1]`。要让它撑满，
  /// 缩放倍数取 `1 / max(宽占比, 高占比)`，再把它平移到中心。等比缩放（不按
  /// 宽高分别拉）是关键——两个方向拉不同倍数会让表情变形。
  Widget _crop(Widget child) {
    if (!widget.cropToContent) return child;
    final Rect b = widget.entry.bbox;
    final double w = (b.right - b.left).clamp(0.0, 1.0);
    final double h = (b.bottom - b.top).clamp(0.0, 1.0);
    // 满幅或数据异常：不缩放。
    if (w >= 0.999 && h >= 0.999) return child;
    final double cover = math.max(w, h);
    if (cover <= 0.01) return child;
    final double scale = 1 / cover;
    // 内容中心相对画布中心的偏移（归一化 → 逻辑像素）。
    final double cx = (b.left + b.right) / 2 - 0.5;
    final double cy = (b.top + b.bottom) / 2 - 0.5;
    return ClipRect(
      child: Transform.translate(
        offset: Offset(-cx * widget.size * scale, -cy * widget.size * scale),
        child: Transform.scale(scale: scale, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pack = FacePack.instance;
    if (pack == null || _failed) return _fallback();

    if (widget.entry.kind == FaceKind.lottie) {
      final comp = _composition;
      if (comp == null) {
        // 解析中：占位但不闪（面板里几十个格子同时起，先留空比先画名字更稳）。
        return SizedBox(width: widget.size, height: widget.size);
      }
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: _crop(
          Lottie(
            composition: comp,
            width: widget.size,
            height: widget.size,
            fit: BoxFit.contain,
            repeat: widget.repeat,
            animate: true,
          ),
        ),
      );
    }

    final Uint8List bytes = pack.bytesOf(widget.entry);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: _crop(
        Image.memory(
          bytes,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.contain,
          cacheWidth: widget.cacheWidth,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (context, error, stack) => _fallback(),
        ),
      ),
    );
  }
}
