/// 消息操作浮层（`lib/ui/widgets/message_action_popup.dart`）的版面与交互。
///
/// 这一组守的是 TG 的**单击气泡**形态：popup 贴着气泡弹出、点条目执行并关闭、
/// 点遮罩只关闭、自己发的气泡菜单在左边（别人的在右边）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/ui/theme/telegram_theme.dart';
import 'package:penguinchat/ui/widgets/action_sheet.dart';
import 'package:penguinchat/ui/widgets/message_action_popup.dart';

/// 把浮层挂在 Scaffold 里，按钮点一下弹出。
Future<void> _pump(
  WidgetTester tester, {
  required Rect anchor,
  required bool outgoing,
  required List<ActionSheetItem> items,
}) async {
  TelegramColors.use(TelegramPalette.dark);
  addTearDown(() => TelegramColors.use(TelegramPalette.dark));
  await tester.pumpWidget(MaterialApp(
    theme: buildTelegramTheme(),
    home: Scaffold(
      body: Builder(
        builder: (ctx) => Center(
          child: ElevatedButton(
            key: const ValueKey('open-popup'),
            onPressed: () => showMessageActionPopup(
              ctx,
              anchor: anchor,
              outgoing: outgoing,
              items: items,
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('点条目：执行回调 + 浮层关闭', (tester) async {
    var tapped = 0;
    await _pump(
      tester,
      anchor: const Rect.fromLTWH(300, 300, 180, 60),
      outgoing: true,
      items: <ActionSheetItem>[
        ActionSheetItem(
          key: const ValueKey('popup-reply'),
          icon: Icons.reply,
          label: '回复',
          onTap: () => tapped++,
        ),
        const ActionSheetItem(
          key: ValueKey('popup-delete'),
          icon: Icons.delete_outline,
          label: '删除',
          danger: true,
        ),
      ],
    );

    await tester.tap(find.byKey(const ValueKey('open-popup')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('popup-reply')), findsOneWidget);
    expect(find.text('回复'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('popup-reply')));
    await tester.pumpAndSettle();
    expect(tapped, 1);
    expect(find.byKey(const ValueKey('popup-reply')), findsNothing,
        reason: '点完要关掉浮层');
  });

  testWidgets('点遮罩：只关闭，不执行任何动作', (tester) async {
    var tapped = 0;
    await _pump(
      tester,
      anchor: const Rect.fromLTWH(100, 400, 160, 50),
      outgoing: false,
      items: <ActionSheetItem>[
        ActionSheetItem(
          key: const ValueKey('popup-copy'),
          icon: Icons.copy_outlined,
          label: '复制',
          onTap: () => tapped++,
        ),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('open-popup')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('popup-copy')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('message-popup-barrier')));
    await tester.pumpAndSettle();
    expect(tapped, 0);
    expect(find.byKey(const ValueKey('popup-copy')), findsNothing);
  });

  testWidgets('定位：自己发的气泡菜单在左边，别人的在右边', (tester) async {
    // 自己发（outgoing）：气泡 x=300..480，菜单应贴在它的左边。
    await _pump(
      tester,
      anchor: const Rect.fromLTWH(300, 300, 180, 60),
      outgoing: true,
      items: <ActionSheetItem>[
        const ActionSheetItem(
          key: ValueKey('popup-a'),
          icon: Icons.reply,
          label: '回复',
        ),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('open-popup')));
    await tester.pumpAndSettle();
    final leftOfOutgoing =
        tester.getTopLeft(find.byKey(const ValueKey('popup-a'))).dx;
    expect(leftOfOutgoing, lessThanOrEqualTo(300 - 8),
        reason: '菜单右缘要落在气泡左边 8dp 处');
    expect(
      tester.getSize(find.byKey(const ValueKey('popup-a'))).width,
      kMessagePopupWidth,
      reason: 'popup 宽度是 TG 的 dp(200) 减去内边距后的行宽…',
    );
  });
}
