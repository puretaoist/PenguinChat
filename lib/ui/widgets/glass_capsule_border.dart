/// 玻璃胶囊的叠色与描边（对齐 Telegram blur3 的真实画法）。
///
/// 出处（全部为实读官方源码，见 AGENTS.md §1.8）：
/// - 底色不是"直接叠 alpha"，而是反解源色：
///   `T/ui/Components/blur3/drawable/color/impl/BlurredBackgroundProviderImpl.java:24-27`
///   取 `alpha = FLAG_LIQUID_GLASS ? 0.85 : 0.76`，再
///   `solveSrcColor(key_windowBackgroundWhite, key_glass_targetMainTabs, alpha)`；
///   算法在同文件 `:304-332`：`src = clamp(round((out - bg * (1 - a)) / a), 0, 255)`，
///   返回值 alpha 为 `round(a * 255)`。
/// - 描边宽 `0.4dp`、上下异色：
///   `T/.../BlurredBackgroundProviderImpl.java:29-30` `setStrokeColorTop/Bottom`、
///   `:33` `setStrokeWidth(dpf2(0.4f), dpf2(0.4f))`。
/// - 描边被切成上下两段 path，分界线在垂直方向的圆角切点：
///   `T/.../BlurredBackgroundDrawable.java:277-284` 上半段高度取
///   `min(boundsWithPadding.top + radii[0], bottom)`；`:288-298` 下半段从
///   `max(boundsWithPadding.bottom - radii[4], top)` 起。因为主 tab 胶囊
///   `radius(28) * 2 == height(56)`，两段正好在中线相接，视觉上是**整圈 0.4dp
///   描边、上半段一种色、下半段另一种色**。
/// - 逐段绘制见 `:723-731`（`Theme.multAlpha` 后再画）。
///
/// Flutter 侧约束：`BoxDecoration` 带 `borderRadius` 时 `Border` 必须是 uniform
/// （`packages/flutter/lib/src/painting/box_border.dart` 的 `isUniform` 分支），
/// 做不出"上下异色"，所以这里用 `CustomPaint` 自绘两段。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';

/// 官方 `solveSrcColor`：给定背景色 [bg] 与叠完要等于的目标色 [target]，
/// 反解出"源色 + alpha"，使 alpha 混合后正好落在 [target] 上。
///
/// `BlurredBackgroundProviderImpl.java:304-332` 的逐通道实现。
Color solveSrcColor(Color bg, Color target, double alpha) {
  assert(alpha > 0 && alpha <= 1, 'alpha 必须落在 (0, 1]');
  int channel(double out, double back) =>
      ((out - back * (1 - alpha)) / alpha).round().clamp(0, 255);
  return Color.fromARGB(
    (alpha * 255).round(),
    channel(target.r * 255, bg.r * 255),
    channel(target.g * 255, bg.g * 255),
    channel(target.b * 255, bg.b * 255),
  );
}

/// 官方 `mainTabs()` 与 `topPanel()` 共用的一套玻璃胶囊基准参数。
///
/// `T/ui/Components/blur3/drawable/color/impl/BlurredBackgroundProviderImpl.java:20-52`
/// 里两个 provider 的 alpha、描边上下色、阴影色、阴影层、线宽逐项相同，只有
/// target 色不同（`key_glass_targetMainTabs` vs `key_glass_targetMainTopPanel`），
/// 而这两个 key 的 `fallbackKeys` 都指向 `key_dialogBackground`
/// （`T/ui/ActionBar/Theme.java:3707-3708`），默认主题下同色。
/// 也就是官方口径里"主 tab 胶囊"和"聊天页顶栏胶囊"本来就是同一套玻璃，
/// 所以这里收成一处常量：主 tab、三个顶栏胶囊、输入栏、下滚圆钮共用。
class GlassCapsule {
  GlassCapsule._();

  /// 官方 `alpha = LiteMode.FLAG_LIQUID_GLASS ? 0.85f : 0.76f`，我方无液态玻璃取 0.76。
  static const double alpha = 0.76;

  /// 官方 `setStrokeWidth(dpf2(0.4f), dpf2(0.4f))`（`:33`）。
  static const double strokeWidth = 0.4;

  /// 模糊半径官方查不到（`BlurredBackgroundSourceRenderNode.setBlur` 只收外部传参，
  /// `MainTabsActivity` 与 `BlurredBackgroundDrawableViewFactory` 都没写死），
  /// 20 是自定值，登记在 `docs/blur-parity.md` §四。
  static const double blurSigma = 20;

  /// 官方 `setShadowLayer(dpf2(2.667f), 0, dpf2(0.85f))`（`:32`）。Flutter 的
  /// `blurRadius` 是半径，换算 sigma = radius * 0.57735 + 0.5，故
  /// 2.667 → (2.667 - 0.5) / 0.57735 ≈ 3.75。
  static const double shadowBlurRadius = 3.75;

  /// 官方阴影 dy `dpf2(0.85f)`，无 dx。
  static const Offset shadowOffset = Offset(0, 0.85);

  /// 胶囊底色：反解源色，使叠在 [TelegramColors.bgApp] 上正好等于
  /// [TelegramColors.bgGlassPanel]（官方 target 同义，见文件头文档）。
  static Color fill() {
    return solveSrcColor(
      TelegramColors.bgApp,
      TelegramColors.bgGlassPanel,
      alpha,
    );
  }

  /// 上半段描边：官方亮色 `0x11000000`、暗色 `0x06FFFFFF`。用户明确不要暗色的
  /// 白色描边（m00304），暗色返回透明等于不画这一段。
  static Color strokeTop() {
    return TelegramColors.isDark ? Colors.transparent : const Color(0x11000000);
  }

  /// 下半段描边：官方亮色 `0x20000000`、暗色 `0x11FFFFFF`（同上）。
  static Color strokeBottom() {
    return TelegramColors.isDark ? Colors.transparent : const Color(0x20000000);
  }

  /// 贴地薄影：官方亮色 `0x20000000`、暗色 `0x04FFFFFF`（`:31`）。
  static List<BoxShadow> shadows() {
    return <BoxShadow>[
      BoxShadow(
        color: TelegramColors.isDark
            ? const Color(0x04FFFFFF)
            : const Color(0x20000000),
        blurRadius: shadowBlurRadius,
        offset: shadowOffset,
      ),
    ];
  }
}

/// 给 [child] 套一圈官方样式的胶囊描边（上下两段异色、0.4dp）。
///
/// 只有 `alpha > 0` 的段才画，所以把某段设成透明就等于"这段不描边"。
class GlassCapsuleBorder extends StatelessWidget {
  const GlassCapsuleBorder({
    super.key,
    required this.radius,
    required this.topColor,
    required this.bottomColor,
    this.strokeWidth = 0.4,
    required this.child,
  });

  /// 胶囊圆角，官方 `MainTabsActivity.java:367` `setRadius(dp(28))`。
  final double radius;

  /// 上半段描边色（官方 `setStrokeColorTop`）。
  final Color topColor;

  /// 下半段描边色（官方 `setStrokeColorBottom`）。
  final Color bottomColor;

  /// 官方 `setStrokeWidth(dpf2(0.4f), dpf2(0.4f))`。
  final double strokeWidth;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _CapsuleBorderPainter(
        radius: radius,
        topColor: topColor,
        bottomColor: bottomColor,
        strokeWidth: strokeWidth,
      ),
      child: child,
    );
  }
}

class _CapsuleBorderPainter extends CustomPainter {
  const _CapsuleBorderPainter({
    required this.radius,
    required this.topColor,
    required this.bottomColor,
    required this.strokeWidth,
  });

  final double radius;
  final Color topColor;
  final Color bottomColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || strokeWidth <= 0) return;
    if (topColor.a <= 0 && bottomColor.a <= 0) return;

    // 官方环带是"从轮廓向内 strokeWidth"，而 Flutter 的 stroke 居中在路径上，
    // 所以路径先内缩半个线宽，画出来才正好压住最外 0.4dp。
    final double half = strokeWidth / 2;
    final RRect outline = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(half),
      Radius.circular(math.max(0, radius - half)),
    );
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    // 分界线 = 垂直中线。radius * 2 >= height 时官方两段正好在此相接。
    final double mid = size.height / 2;

    if (topColor.a > 0) {
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(0, 0, size.width, mid));
      canvas.drawRRect(outline, paint..color = topColor);
      canvas.restore();
    }
    if (bottomColor.a > 0) {
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(0, mid, size.width, size.height));
      canvas.drawRRect(outline, paint..color = bottomColor);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_CapsuleBorderPainter old) =>
      old.radius != radius ||
      old.topColor != topColor ||
      old.bottomColor != bottomColor ||
      old.strokeWidth != strokeWidth;
}
