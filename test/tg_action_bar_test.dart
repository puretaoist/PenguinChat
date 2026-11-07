/// ActionBar 的几何测试。
///
/// 锁的是官方那两条**按屏幕朝向变化**的规则（ActionBar.java:769 高度、
/// :654/:1455 标题字号），以及"状态栏高度算进条自身"（:1400）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/ui/theme/telegram_theme.dart';
import 'package:penguinchat/ui/widgets/tg_action_bar.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

Future<void> _setSize(WidgetTester tester, Size size) async {
  TelegramColors.use(TelegramPalette.dark);
  addTearDown(() => TelegramColors.use(TelegramPalette.dark));
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('竖屏：条高 56、标题 20、状态栏高度算进条内', (tester) async {
    await _setSize(tester, const Size(400, 800));
    await tester.pumpWidget(
      _wrap(
        const TgActionBar(
          title: '聊天',
          topInset: 24,
          actions: <Widget>[Icon(Icons.search)],
        ),
      ),
    );

    // 条本身 56，加上 24 的状态栏留白。
    expect(tester.getSize(find.byType(TgActionBar)).height, 80);
    final Text title = tester.widget<Text>(find.text('聊天'));
    expect(title.style?.fontSize, 20);
    // 标题落在状态栏下方（44 = 24 + 56/2）。
    expect(tester.getCenter(find.text('聊天')).dy, closeTo(24 + 28, 0.5));
  });

  testWidgets('横屏：条高 48、标题 18', (tester) async {
    await _setSize(tester, const Size(900, 500));
    await tester.pumpWidget(_wrap(const TgActionBar(title: '聊天')));

    expect(tester.getSize(find.byType(TgActionBar)).height, 48);
    expect(tester.widget<Text>(find.text('聊天')).style?.fontSize, 18);
  });

  testWidgets('右侧按钮触摸区 48dp、图标 24dp', (tester) async {
    await _setSize(tester, const Size(400, 800));
    await tester.pumpWidget(
      _wrap(
        TgActionBar(
          title: '聊天',
          actions: <Widget>[
            TgActionBar.iconButton(
              key: const ValueKey('btn'),
              icon: Icons.search,
              onPressed: () {},
            ),
          ],
        ),
      ),
    );

    expect(
      tester.getSize(find.byKey(const ValueKey('btn'))),
      const Size(48, 48),
    );
    // 图标尺寸挂在 IconButton.iconSize 上（Icon 自身的 size 是 null）。
    final IconButton button = tester.widget<IconButton>(
      find.byKey(const ValueKey('btn')),
    );
    expect(button.iconSize, 24);
  });

  testWidgets('副标题：13sp 挂在标题下方，条高不变', (tester) async {
    await _setSize(tester, const Size(400, 800));
    await tester.pumpWidget(
      _wrap(const TgActionBar(title: '联系人', subtitle: '18 位联系人', topInset: 24)),
    );

    // 副标题不改变条高（官方把两行塞进同一个 overlay title 容器）。
    expect(tester.getSize(find.byType(TgActionBar)).height, 80);
    expect(tester.widget<Text>(find.text('18 位联系人')).style?.fontSize, 13);
    expect(
      tester.getCenter(find.text('18 位联系人')).dy,
      greaterThan(tester.getCenter(find.text('联系人')).dy),
    );
  });

  testWidgets('透明模式：背景不画 bgHeader（我的资料页）', (tester) async {
    await _setSize(tester, const Size(400, 800));
    await tester.pumpWidget(
      _wrap(const TgActionBar(title: '', transparent: true, topInset: 24)),
    );
    final Container box = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(TgActionBar),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(box.color, Colors.transparent);
    // 条本身仍然给状态栏让位。
    expect(tester.getSize(find.byType(TgActionBar)).height, 80);
  });
}
