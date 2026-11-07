/// 列表 cell 的几何测试。
///
/// 数值全部来自 Telegram Android 源码（路径相对 org/telegram/ui），
/// 改这里之前先回去看对应行号，别凭手感调。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/ui/theme/telegram_theme.dart';
import 'package:penguinchat/ui/widgets/telegram_list_item.dart';

Widget _wrap(Widget child) => MaterialApp(
  // 靠左上摆放，x 原点才是 0（Center 会整体右移 (400-360)/2 = 20）。
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 360, child: child),
    ),
  ),
);

void _dark(WidgetTester tester) {
  TelegramColors.use(TelegramPalette.dark);
  addTearDown(() => TelegramColors.use(TelegramPalette.dark));
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('联系人行（callCellStyle）：56 高、15sp、文字 x=66', (tester) async {
    _dark(tester);
    await tester.pumpWidget(
      _wrap(
        const TgUserRow(
          compact: true,
          leading: SizedBox(width: 44, height: 44),
          title: '张三',
          subtitle: 'QQ 20002',
        ),
      ),
    );

    // UserCell.java:479-490 → 行高 56；7 + 44 + 15 = 66 是文字起点。
    expect(tester.getSize(find.byType(TgUserRow)).height, 56);
    expect(tester.getTopLeft(find.text('张三')).dx, closeTo(66, 0.5));
    expect(tester.widget<Text>(find.text('张三')).style?.fontSize, 15);
    expect(tester.widget<Text>(find.text('QQ 20002')).style?.fontSize, 13);
  });

  testWidgets('分组字母条：64 高、22sp（LetterSectionCell.java:30-37）', (tester) async {
    _dark(tester);
    await tester.pumpWidget(_wrap(const TgLetterHeader('我的好友（3）')));

    expect(tester.getSize(find.byType(TgLetterHeader)).height, 64);
    expect(tester.widget<Text>(find.text('我的好友（3）')).style?.fontSize, 22);
    // 左内边距 12（dp(12+64) 的 12）。
    expect(tester.getTopLeft(find.text('我的好友（3）')).dx, closeTo(12, 0.5));
  });

  testWidgets('设置行：双行 60 高、图标块 28、没有右箭头', (tester) async {
    _dark(tester);
    await tester.pumpWidget(
      _wrap(
        TgSettingRow(
          icon: Icons.tune,
          title: '通用',
          subtitle: '数字与时间格式',
          onTap: () {},
        ),
      ),
    );

    // SettingsActivity.java:1264 twoLines → 60。
    expect(tester.getSize(find.byType(TgSettingRow)).height, 60);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    // 图标块 28×28（:1218）。
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('setting-row-icon'))),
      const Size(28, 28),
    );
  });

  testWidgets('资料行：最小 60 高、标题 16 / 值 13', (tester) async {
    _dark(tester);
    await tester.pumpWidget(
      _wrap(const TgTextDetailRow(title: 'QQ 号', value: '20002')),
    );

    // TextDetailCell.java:82 setMinimumHeight(dp(60))。
    expect(
      tester.getSize(find.byType(TgTextDetailRow)).height,
      greaterThanOrEqualTo(60),
    );
    expect(tester.widget<Text>(find.text('QQ 号')).style?.fontSize, 16);
    expect(tester.widget<Text>(find.text('20002')).style?.fontSize, 13);
  });
}
