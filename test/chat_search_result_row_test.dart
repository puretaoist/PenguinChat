/// 会话内搜索结果行的几何：官方 `MessagesSearchAdapter` 那套 48dp 紧凑行。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/ui/widgets/chat_search_result_row.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required double cut}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: ChatSearchResultRow(
                senderName: '小明',
                text: '会议改到三点',
                cut: cut,
              ),
            ),
          ),
        ),
      );

  testWidgets('行高 48，和官方一致', (tester) async {
    await pump(tester, cut: 0);
    expect(tester.getSize(find.byType(ChatSearchResultRow)).height, 48);
  });

  testWidgets('完整可见时文字不被推走，也不透明', (tester) async {
    await pump(tester, cut: 0);
    final double left = tester.getTopLeft(find.text('小明')).dx;
    final Opacity opacity = tester.widget<Opacity>(
      find.ancestor(
        of: find.text('小明'),
        matching: find.byType(Opacity),
      ).first,
    );
    expect(opacity.opacity, 1);
    // 文字区左内距 76（MessagesSearchAdapter.java:345 的 leftMargin）。
    expect(left.round(), 76);
  });

  testWidgets('被视口裁掉时文字往左滑 62dp 并淡出', (tester) async {
    await pump(tester, cut: 0);
    final double base = tester.getTopLeft(find.text('小明')).dx;

    await pump(tester, cut: 1);
    final double shifted = tester.getTopLeft(find.text('小明')).dx;
    expect((base - shifted).round(), 62);

    final Opacity opacity = tester.widget<Opacity>(
      find.ancestor(
        of: find.text('小明'),
        matching: find.byType(Opacity),
      ).first,
    );
    expect(opacity.opacity, 0);
  });
}
