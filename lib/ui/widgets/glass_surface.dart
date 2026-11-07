import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';

/// 统一的玻璃（毛玻璃）表面。全部悬浮胶囊共用同一套参数：
/// ClipRRect → BackdropFilter(σ20) → 半透明底色 + 0.5dp 描边。
///
/// 为什么集中成一个组件：顶栏三块胶囊、tab 胶囊、输入栏胶囊、下滚圆钮、
/// 各类底部弹层原来是各写各的 σ / 透明度 / 描边，视觉与性能口径都对不上。
/// 官方也是同一套：ChatActivity.java:4623 顶栏、输入栏、tab 全部来自同一个
/// BlurredBackgroundDrawableViewFactory。
///
/// 两个坑：
/// 1) 阴影只能画在 ClipRRect 外层——内层会被 ClipRRect 裁掉，画不出来；
/// 2) 描边必须用 foregroundDecoration 而不是 decoration，否则 Border 会吃掉
///    0.5dp 内边距，内容宽度会少 1dp（message_action_popup 踩过：200→198）。
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
  });

  final Widget child;
  final double radius;

  /// 底色；不传则用 bgGlassPanel（=chat_topPanelBackground）×0.76 压一层。
  final Color? color;
  final double blurSigma;
  final bool showBorder;
  final EdgeInsetsGeometry? padding;

  /// 是否在外层画投影（被裁剪的圆角卡片需要浮起来时用）。
  final bool shadow;

  /// 内容对齐；胶囊内需要「垂直居中」或「左中」时用。
  final AlignmentGeometry? alignment;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    // 官方 BlurredBackgroundProviderImpl.java:169-186 topPanelChatActivity：
    // 底 = chat_topPanelBackground × alpha，非 Lite 玻璃 alpha=0.76（Liquid 0.85）。
    final Color base =
        color ?? TelegramColors.bgGlassPanel.withValues(alpha: 0.76);
    final BorderRadius br = BorderRadius.circular(radius);
    final Widget surface = ClipRRect(
      borderRadius: br,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: Container(
          padding: padding,
          alignment: alignment,
          decoration: BoxDecoration(color: base, borderRadius: br),
          foregroundDecoration: showBorder
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
        ),
      ),
    );
    if (!shadow) return surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: br,
        boxShadow: <BoxShadow>[
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
