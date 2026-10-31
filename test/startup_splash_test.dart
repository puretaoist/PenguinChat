/// 冷启动品牌页的渲染测试：品牌名、状态行（可换文案）、进度条都在。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/ui/pages/startup_splash.dart';

void main() {
  testWidgets('默认状态：品牌名 + 默认状态行 + 一根进度条', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: StartupSplash()));
    // 进度条是 indeterminate（永远在动），pumpAndSettle 会超时；固定推进 500ms 即可。
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('QQ Client'), findsOneWidget);
    expect(find.byKey(const ValueKey('startup-status')), findsOneWidget);
    expect(find.text('正在启动…'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.chat_bubble_rounded), findsOneWidget);
  });

  testWidgets('可以换状态文案（账号恢复过程展示）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: StartupSplash(status: '正在恢复账号 2089495846…')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('正在恢复账号 2089495846…'), findsOneWidget);
    expect(find.text('正在启动…'), findsNothing);
  });

  testWidgets('420ms 入场动画结束后不透明度到 1（不留半透明残影）', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: StartupSplash()));
    await tester.pump(const Duration(milliseconds: 500));
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: find.byType(Icon), matching: find.byType(Opacity)).first,
    );
    expect(opacity.opacity, 1.0);
  });
}
