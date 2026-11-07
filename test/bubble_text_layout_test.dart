import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/ui/widgets/bubble_text_layout.dart';

void main() {
  Widget wrap(
    String text, {
    double width = 180,
    bool rtl = false,
    double scale = 1,
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: BubbleTextLayout(
              text: text,
              style: const TextStyle(fontSize: 16, height: 1.35),
              metadata: const SizedBox(
                key: ValueKey('meta'),
                width: 40,
                height: 14,
              ),
              metadataWidth: 40,
              rtl: rtl,
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('短正文时间在右下角，不进入正文文本流', (tester) async {
    await tester.pumpWidget(wrap('Hi'));
    final text = tester.getRect(find.text('Hi'));
    final meta = tester.getRect(find.byKey(const ValueKey('meta')));
    expect(meta.left, greaterThanOrEqualTo(text.right + 3.9));
    expect(meta.bottom, closeTo(text.bottom, 0.1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('正文先换行，末行无空间只新增时间行', (tester) async {
    const text = 'abcdefghi';
    await tester.pumpWidget(wrap(text, width: 150));
    final body = tester.getRect(find.text(text));
    final meta = tester.getRect(find.byKey(const ValueKey('meta')));
    expect(meta.top, greaterThanOrEqualTo(body.bottom));
    expect(meta.right, lessThanOrEqualTo(150));
    expect(tester.takeException(), isNull);
  });
  testWidgets('RTL及放大字体保持时间独立且不覆盖正文', (tester) async {
    await tester.pumpWidget(wrap('مرحبا', rtl: true, scale: 1.6));
    final body = tester.getRect(find.text('مرحبا'));
    final meta = tester.getRect(find.byKey(const ValueKey('meta')));
    expect(meta.top, greaterThanOrEqualTo(body.bottom - 0.1));
    expect(tester.takeException(), isNull);
  });
}
