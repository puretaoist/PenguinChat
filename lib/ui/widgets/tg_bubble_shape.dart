/// 普通消息逐条绘制，不把连续消息误当成媒体相册。
/// ChatActivity.java:37905-38047 → ChatMessageCell.java:6884-6919。
/// 有后继消息时选择 TYPE_MEDIA 无尾背景（20531-20617），仅靠发送者侧
/// 相邻圆角收为 min(6, radius)，另一侧始终大圆角。
/// 路径依据 MessageDrawable.java:675-803；这里统一在出站坐标绘制再镜像。
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart';

class TgBubbleShape extends ShapeBorder {
  const TgBubbleShape({
    required this.isOut,
    this.isFirst = true,
    this.isLast = true,
    this.showTail = true,
    this.radius = 17,
    this.tailRadius = 6,
    this.inset = 2,
  });
  final bool isOut;
  final bool isFirst;
  final bool isLast;

  /// false 对应真实媒体背景；普通文本的非末条也选择无尾背景。
  final bool showTail;
  final double radius;
  final double tailRadius;
  final double inset;
  bool get hasTail => showTail && isLast;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;
  @override
  ShapeBorder scale(double t) => TgBubbleShape(
    isOut: isOut,
    isFirst: isFirst,
    isLast: isLast,
    showTail: showTail,
    radius: radius * t,
    tailRadius: tailRadius * t,
    inset: inset * t,
  );
  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    if (rect.width <= 0 || rect.height <= 0) return Path();
    // 20579-20605 / 20662-20684：cell 内的 drawable bounds。
    // 真实媒体不做文本背景的 ±1dp 调整；纯图无额外内缩。
    final top = (isFirst ? 1.0 : 0.0) - (showTail && !isFirst ? 1 : 0);
    final offsetBottom = !isLast ? (!isFirst ? 0.0 : 1.0) : 2.0;
    final height =
        rect.height -
        offsetBottom +
        (showTail && !isFirst ? 1 : 0) +
        (showTail && !isLast ? 1 : 0);
    final bottom = top + height;
    final left = inset;
    // 无尾文本背景宽度减 6dp；真实媒体的 6dp 在行外定位。
    final right =
        rect.width - (showTail && !isLast ? 6 : 0) - (hasTail ? 8 : inset);
    final y = top + inset;
    final b = bottom - inset;
    if (right <= left || b <= y) return Path();
    final rad = math.max(
      0.0,
      math.min(radius, math.min((right - left) / 2, (height - inset) / 2)),
    );
    final near = math.min(6.0, rad);
    final tr = isFirst ? rad : near;
    final br = isLast ? rad : near;
    final p = Path();
    const q = math.pi / 2;
    p.moveTo(hasTail ? rect.width - 2.6 : right - rad, b);
    p.lineTo(left + rad, b);
    p.arcTo(Rect.fromLTRB(left, b - 2 * rad, left + 2 * rad, b), q, q, false);
    p.lineTo(left, y + rad);
    p.arcTo(
      Rect.fromLTRB(left, y, left + 2 * rad, y + 2 * rad),
      math.pi,
      q,
      false,
    );
    p.lineTo(right - tr, y);
    p.arcTo(Rect.fromLTRB(right - 2 * tr, y, right, y + 2 * tr), -q, q, false);
    if (hasTail) {
      final small = tailRadius;
      p.lineTo(right, b - small - 3);
      p.arcTo(
        Rect.fromLTRB(
          right,
          b - small * 2 - 9,
          rect.width - 7 + small * 2,
          b - 1,
        ),
        math.pi,
        -83 * math.pi / 180,
        false,
      );
    } else {
      p.lineTo(right, b - br);
      p.arcTo(Rect.fromLTRB(right - br * 2, b - br * 2, right, b), 0, q, false);
    }
    p.close();
    // 入站与出站的近角位置镜像；两者内部内容偏移由 MessageBubble 单独处理。
    final m = Matrix4.identity();
    if (isOut) {
      m.setTranslationRaw(rect.left, rect.top, 0);
    } else {
      m.setEntry(0, 0, -1);
      m.setTranslationRaw(rect.right, rect.top, 0);
    }
    return p.transform(m.storage);
  }
}
