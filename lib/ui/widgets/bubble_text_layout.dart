import 'dart:math' as math;

import 'package:flutter/material.dart';

/// TG calcBackgroundWidth:12911-12954：正文先独立换行，再看末行能否容纳时间。
/// 时间绝不进入文本流，放不下时只增加时间行，不挤掉正文末尾的单词。
class BubbleTextLayout extends StatelessWidget {
  const BubbleTextLayout({
    super.key,
    required this.text,
    required this.style,
    required this.metadata,
    required this.metadataWidth,
    this.rtl = false,
  });
  final String text;
  final TextStyle style;
  final Widget metadata;
  final double metadataWidth;
  final bool rtl;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final resolvedStyle = DefaultTextStyle.of(context).style.merge(style);
      final scaler = MediaQuery.textScalerOf(context);
      final direction = Directionality.of(context);
      final painter = TextPainter(
        text: TextSpan(text: text, style: resolvedStyle),
        textDirection: direction,
        textScaler: scaler,
        locale: Localizations.maybeLocaleOf(context),
      )..layout(maxWidth: constraints.maxWidth);
      final lines = painter.computeLineMetrics();
      final last = lines.isEmpty ? 0.0 : lines.last.width;
      final bodyWidth = lines.fold<double>(0, (w, l) => math.max(w, l.width));
      final separate = rtl || last + 4 + metadataWidth > constraints.maxWidth;
      final width = math.min(
        constraints.maxWidth,
        math.max(
          metadataWidth,
          separate ? bodyWidth : math.max(bodyWidth, last + 4 + metadataWidth),
        ),
      );
      final height = painter.height;
      painter.dispose();
      return SizedBox(
        width: width,
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(bottom: separate ? scaler.scale(14) : 0),
              child: Text(
                text,
                style: style,
                textWidthBasis: TextWidthBasis.longestLine,
              ),
            ),
            Positioned(
              right: 0,
              top:
                  math.max(0, height - scaler.scale(14)) +
                  (separate ? scaler.scale(14) : 0),
              child: metadata,
            ),
          ],
        ),
      );
    },
  );
}
