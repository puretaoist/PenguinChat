/// L4 组件：图片 blur-up（模糊小图占位 → 清晰图淡入）。
///
/// 为什么值得做：TG 的 `ImageLoader` 收到图先拿一张几十像素的 blurred
/// thumb 铺满，原图解码完再淡入，所以滚动时不会出现"空洞 → 突然一张图"的
/// 硬切。我们的图片都是从本地 MediaCache 读，同样能先解码一张 32px 的小图
/// 做占位——成本是一次极小解码，视觉收益最大。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 模糊占位 + 清晰图淡入。[image] 是**清晰图**的 provider。
class BlurUpImage extends StatefulWidget {
  const BlurUpImage({
    super.key,
    required this.image,
    this.fit = BoxFit.cover,
    this.blurSigma = 10,
    this.previewWidth = 32,
    this.fade = const Duration(milliseconds: 180),
    this.errorBuilder,
  });

  final ImageProvider image;
  final BoxFit fit;

  /// 占位图的模糊强度（逻辑像素 sigma）。
  final double blurSigma;

  /// 占位图解码宽度（物理像素）。32 已经能看清大致色块。
  final int previewWidth;

  final Duration fade;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  State<BlurUpImage> createState() => _BlurUpImageState();
}

class _BlurUpImageState extends State<BlurUpImage> {
  /// 清晰图淡入完成后就把占位层摘掉：省一张常驻的 Image 组件（也省解码
  /// 出来的小纹理），顺带让 widget 树里只剩一张图——测试里按
  /// `find.byType(Image)` 数图片时不会数出两份。
  bool _previewGone = false;

  Widget _preview() {
    // 故意用 DecorationImage 而不是 Image 组件来画占位图：占位和清晰图如果
    // 都是 Image 组件，widget 树里会同时存在两张图（测试按 find.byType(Image)
    // 数图会数出两份，肉眼调试时也容易误判"图重复了"）。
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(
        sigmaX: widget.blurSigma,
        sigmaY: widget.blurSigma,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: ResizeImage(
              widget.image,
              width: widget.previewWidth,
              allowUpscaling: true,
            ),
            fit: widget.fit,
            onError: (Object _, StackTrace? _) {},
          ),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Image(
      image: widget.image,
      fit: widget.fit,
      gaplessPlayback: true,
      errorBuilder: widget.errorBuilder,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        // 已经同步拿到（ImageCache 命中）就别再播淡入，否则每次滚动
        // 复用都会"闪一下"。
        if (wasSynchronouslyLoaded || _previewGone) return child;
        if (frame == null) {
          // 还没解出第一帧：近黑底 + 模糊小图。
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              const ColoredBox(color: Color(0xFF1C1C1C)),
              _preview(),
            ],
          );
        }
        // 首帧到了：清晰图淡入，占位层同时淡出，播完摘掉占位层。
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: 1),
          duration: widget.fade,
          curve: Curves.easeOut,
          onEnd: () {
            if (mounted && !_previewGone) setState(() => _previewGone = true);
          },
          builder: (context, t, clear) {
            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (_previewGone)
                  const ColoredBox(color: Color(0xFF1C1C1C))
                else
                  Opacity(opacity: 1 - t, child: _preview()),
                Opacity(opacity: t, child: clear!),
              ],
            );
          },
          child: child,
        );
      },
    );
  }
}
