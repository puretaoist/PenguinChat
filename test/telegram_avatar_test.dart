import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/ui/widgets/telegram_avatar.dart';

// 头像真图的重试约定：
//  - 失败不再**永久**钉成首字母（旧实现一次 CDN 超时就固定到重建为止）；
//  - 形状必须是正方形（C103：槽宽算错会画成椭圆）；
//  - 没有直链时就是首字母块，不发请求。
void main() {
  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets('没有直链：直接首字母块，不出现 Image', (tester) async {
    await tester.pumpWidget(wrap(const TelegramAvatar(name: '净凾', size: 44)));
    expect(find.text('净'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('有直链：ClipOval 必须是正方形（C103 回归）', (tester) async {
    await tester.pumpWidget(wrap(const TelegramAvatar(
      name: '净凾',
      size: 44,
      url: 'https://q1.qlogo.cn/g?b=qq&nk=2089495846&s=100',
    )));
    await tester.pump();
    final ovals = tester.widgetList<ClipOval>(find.byType(ClipOval)).toList();
    expect(ovals, isNotEmpty, reason: '有直链时要画出圆形裁剪');
    for (final e in ovals) {
      final size = tester.getSize(find.byWidget(e));
      expect(size.width, moreOrLessEquals(size.height),
          reason: '头像必须正圆，实测 ${size.width}x${size.height}');
    }
  });

  testWidgets('请求失败（测试环境恒 400）：退回首字母且不崩、ClipOval 仍在', (tester) async {
    await tester.pumpWidget(wrap(const TelegramAvatar(
      name: '净凾',
      size: 44,
      url: 'https://example.invalid/a.png',
    )));
    await tester.pump();
    // 首帧就失败 -> errorBuilder -> 后帧回调触发第 1 次重试等待
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('净'), findsWidgets);
    expect(find.byType(ClipOval), findsOneWidget, reason: '形状容器不能被摘掉');
  });
}
