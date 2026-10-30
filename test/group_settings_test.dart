/// 群设置面板：版式对齐 TG 设置页（`ui/Cells/GraySectionCell.java`
/// :40 layerHeight=32 / :57 字 14 / :54 灰底 / :61 左右 16；
/// 输入框走"灰底无边框胶囊"；按钮右对齐 accent 14 w600；页头标题 20）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/ui/theme/telegram_theme.dart';
import 'package:qqclient/ui/widgets/group_settings_panel.dart';

final bool goldenSkip = !Platform.isWindows;

Future<void> _pump(WidgetTester tester, {Size size = const Size(360, 620)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  TelegramColors.use(TelegramPalette.dark);
  addTearDown(() => TelegramColors.use(TelegramPalette.dark));
  await tester.pumpWidget(MaterialApp(
    theme: buildTelegramTheme(),
    home: Scaffold(
      body: GroupSettingsPanel(
        title: '产品讨论组',
        initialName: '产品讨论组',
        onRename: (a) async => true,
        onAnnounce: (a) async => true,
        onWholeMute: (a) async => true,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('页头标题 20、分组标题 32 高 14 w700、输入框灰底', (tester) async {
    await _pump(tester);
    expect(tester.widget<Text>(find.byKey(const ValueKey('gset-title'))).style!.fontSize,
        20);
    final sec = tester.widget<Text>(find.text('群名'));
    expect(sec.style!.fontSize, 14);
    expect(sec.style!.fontWeight, FontWeight.w700);
    // 分组标题所在 Container 高 32（GraySectionCell.layerHeight）+ 上边距 8 = 40
    final band = find.ancestor(of: find.text('群名'), matching: find.byType(Container)).first;
    expect(tester.getSize(band).height, 40);
    final tf = tester.widget<TextField>(find.byKey(const ValueKey('gset-name')));
    expect(tf.decoration!.filled, isTrue);
    expect(tf.decoration!.fillColor, TelegramColors.bgHover);
  });

  testWidgets('三个动作按钮都在，点保存群名会回调', (tester) async {
    String? renamed;
    await tester.pumpWidget(MaterialApp(
      theme: buildTelegramTheme(),
      home: Scaffold(
        body: GroupSettingsPanel(
          title: '产品讨论组',
          initialName: '旧名字',
          onRename: (a) async {
            renamed = a;
            return true;
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('gset-name-ok')));
    await tester.pumpAndSettle();
    expect(renamed, '旧名字');
    // ListView 的子项是懒构建的，下面的按钮要滚进视口才存在
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('gset-announce-ok')), findsOneWidget);
    expect(find.byKey(const ValueKey('gset-mute-all-on')), findsOneWidget);
    expect(find.byKey(const ValueKey('gset-mute-all-off')), findsOneWidget);
  });

  testWidgets('金样：群设置面板', (tester) async {
    await _pump(tester);
    await expectLater(find.byType(GroupSettingsPanel),
        matchesGoldenFile('goldens/group_settings.png'), skip: goldenSkip);
  });
}
