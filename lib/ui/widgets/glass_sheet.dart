import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';

/// 底部弹层的毛玻璃外壳：圆角 + 背景 blur + 半透明填充。
///
/// 为什么要统一这一层：TG/AyuGram 的 bottom sheet 都是浮在内容上的毛玻璃，
/// 纯色不透明面板会把下面的聊天/图片一刀切断。颜色统一取 bgSidebar，透明度
/// 0.92——再低文字对比度会掉，再高就看不见后面的 blur。
class GlassSheet extends StatelessWidget {
  const GlassSheet({
    super.key,
    required this.child,
    this.radius = 14,
    this.alpha = 0.92,
  });

  final Widget child;

  /// 顶部圆角。附件弹层用 16，其余 14。
  final double radius;

  final double alpha;

  @override
  Widget build(BuildContext context) {
    final BorderRadius r = BorderRadius.vertical(top: Radius.circular(radius));
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          // 用 Material 而不是 Container：ListTile / InkWell 的水波纹要画在最近
          // 的 Material 上，中间夹 DecoratedBox 会把水波纹一起遮住（debug 下抛
          // "ListTile background color or ink splashes may be invisible"）。
          color: TelegramColors.bgSidebar.withValues(alpha: alpha),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: r),
          child: child,
        ),
      ),
    );
  }
}

/// 毛玻璃版 showModalBottomSheet：调用方只管给内容，透明底 + blur 外壳这里处理。
Future<T?> showGlassSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  double radius = 14,
  Color barrierColor = const Color(0x59000000),
}) => showModalBottomSheet<T>(
  context: context,
  backgroundColor: Colors.transparent,
  isScrollControlled: isScrollControlled,
  barrierColor: barrierColor,
  builder: (BuildContext ctx) =>
      GlassSheet(radius: radius, child: builder(ctx)),
);
