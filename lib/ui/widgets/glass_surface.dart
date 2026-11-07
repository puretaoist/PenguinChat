import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';
import 'glass_capsule_border.dart';

/// 统一的玻璃（毛玻璃）表面。
///
/// 两档：
/// - [GlassSurface.capsule]：官方 `mainTabs()`/`topPanel()` 那一套（底色反解、
///   0.4dp 上下异色描边、贴地薄影），参数全部来自 [GlassCapsule]。主 tab 胶囊、
///   聊天顶栏三颗胶囊、输入栏胶囊、下滚圆钮都用这一档，口径唯一；
/// - 默认档：给底部弹层类表面用（实底 0.92~0.94 + 细白描边），不套胶囊描边。
///
/// 官方也是同一套：ChatActivity.java:4623 顶栏、输入栏、tab 全部来自同一个
/// BlurredBackgroundDrawableViewFactory。
///
/// 三个坑：
/// 1) 阴影只能画在 ClipRRect 外层——内层会被 ClipRRect 裁掉，画不出来；
/// 2) 描边必须用 foregroundDecoration 而不是 decoration，否则 Border 会吃掉
///    0.5dp 内边距，内容宽度会少 1dp（message_action_popup 踩过：200→198）；
/// 3) 胶囊档的上下异色描边由 [GlassCapsuleBorder] 自绘，不占内边距。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = 23,
    this.color,
    this.blurSigma = 20,
    this.showBorder = true,
    this.padding,
    this.shadow = false,
    this.alignment,
  }) : capsule = false;

  /// 官方玻璃胶囊档：参数一律取自 [GlassCapsule]，不允许逐个覆盖，
  /// 避免再回到"每个胶囊一套数字"。
  const GlassSurface.capsule({
    super.key,
    required this.child,
    this.radius = 23,
    this.showBorder = true,
    this.padding,
    this.alignment,
  }) : capsule = true,
       color = null,
       blurSigma = GlassCapsule.blurSigma,
       shadow = true;

  final Widget child;
  final double radius;

  /// 底色；不传则用 bgGlassPanel ×0.76 压一层。胶囊档忽略此值。
  final Color? color;
  final double blurSigma;
  final bool showBorder;
  final EdgeInsetsGeometry? padding;

  /// 是否在外层画投影（被裁剪的圆角卡片需要浮起来时用）。
  final bool shadow;

  /// 内容对齐；胶囊内需要「垂直居中」或「左中」时用。
  final AlignmentGeometry? alignment;

  /// 是否走官方胶囊档（[GlassCapsule] 那一套参数）。
  final bool capsule;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color base = capsule
        ? GlassCapsule.fill()
        // 官方 BlurredBackgroundProviderImpl.java:169-186 topPanelChatActivity：
        // 底 = chat_topPanelBackground × alpha，非 Lite 玻璃 alpha=0.76。
        : (color ?? TelegramColors.bgGlassPanel.withValues(alpha: 0.76));
    final BorderRadius br = BorderRadius.circular(radius);
    Widget content = Container(
      padding: padding,
      alignment: alignment,
      decoration: BoxDecoration(color: base, borderRadius: br),
      // 胶囊档的描边由 GlassCapsuleBorder 画在更外层（不占内边距）。
      foregroundDecoration: !capsule && showBorder
          ? BoxDecoration(
              borderRadius: br,
              // 官方描边是白色半透明、上亮下暗（BlurredBackgroundProviderImpl
              // :181-185：暗色上 0x20FFFFFF / 下 0x14FFFFFF，宽 0.55dp）。
              // Flutter 的 BoxDecoration 在给了 borderRadius 时只允许
              // uniform Border（非均匀会在 paint 阶段断言），这里取两者
              // 中间值 0x1AFFFFFF 近似，视觉差异 <2% alpha。
              border: Border.all(
                color: dark ? const Color(0x1AFFFFFF) : Colors.white,
                width: 0.55,
              ),
            )
          : null,
      child: child,
    );
    if (capsule && showBorder) {
      content = GlassCapsuleBorder(
        radius: radius,
        topColor: GlassCapsule.strokeTop(),
        bottomColor: GlassCapsule.strokeBottom(),
        strokeWidth: GlassCapsule.strokeWidth,
        child: content,
      );
    }
    final Widget surface = ClipRRect(
      borderRadius: br,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: content,
      ),
    );
    if (!shadow) return surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: br,
        boxShadow: capsule
            ? GlassCapsule.shadows()
            : <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.28 : 0.12),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
      ),
      child: surface,
    );
  }
}
