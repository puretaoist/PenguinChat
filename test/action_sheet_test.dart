/// 底部动作弹层（`lib/ui/widgets/action_sheet.dart`）的金样与几何。
///
/// 会话长按 / 消息长按共用同一套版面：圆角顶部 12、动作行 48dp、图标 24、
/// 文字 16、末尾「取消」前一条分隔线。原来两份实现都是 dense ListTile
/// （标题 15、图标 20），和 TG 差一档，改完必须有图盯着。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/client_api/objects.dart';
import 'package:qqclient/client_api/segment.dart';
import 'package:qqclient/ui/theme/telegram_theme.dart';
import 'package:qqclient/ui/widgets/action_sheet.dart';
import 'package:qqclient/ui/widgets/chat_actions.dart';
import 'package:qqclient/ui/widgets/message_actions.dart';

ChatMessage _msg() => ChatMessage(
      id: 'm1',
      text: '这条消息用来试试长按菜单的版面',
      segments: const <Segment>[TextSegment('这条消息用来试试长按菜单的版面')],
      time: DateTime(2026, 10, 30, 9, 30),
      chatId: 'group_1',
      senderId: '20002',
      senderName: '张三',
    );

Future<void> _pumpSheet(WidgetTester tester, Widget sheet,
    {Size size = const Size(360, 620)}) async {
  TelegramColors.use(TelegramPalette.dark);
  addTearDown(() => TelegramColors.use(TelegramPalette.dark));
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTelegramTheme(),
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Align(alignment: Alignment.bottomCenter, child: sheet),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('动作行 48 高、图标 24、文字 16：版面照 TG 的底部弹层', (tester) async {
    await _pumpSheet(tester, MessageActionsSheet(message: _msg()));

    final label = tester.widget<Text>(find.text('复制'));
    expect(label.style?.fontSize, 16);

    final icon = tester.widget<Icon>(find.byIcon(Icons.copy_outlined));
    expect(icon.size, 24);

    final row = tester.widget<SizedBox>(
      find.ancestor(of: find.text('复制'), matching: find.byType(SizedBox)).first,
    );
    expect(row.height, 48);
  });

  testWidgets('危险动作（撤回/删除）是警示色，普通动作不是', (tester) async {
    await _pumpSheet(
      tester,
      MessageActionsSheet(message: _msg(), canRecall: true),
    );
    final del = tester.widget<Text>(find.text('删除（仅本地）'));
    final copy = tester.widget<Text>(find.text('复制'));
    expect(del.style?.color, TelegramColors.danger);
    expect(copy.style?.color, TelegramColors.textPrimary);
  });

  testWidgets('顶部预览带强调色竖线，内容和消息正文一致', (tester) async {
    await _pumpSheet(tester, MessageActionsSheet(message: _msg()));
    final preview = tester.widget<Text>(find.byKey(const ValueKey('actions-preview')));
    expect(preview.data, '这条消息用来试试长按菜单的版面');
    expect(preview.style?.fontSize, 15);
  });

  testWidgets('金样：消息长按菜单', (tester) async {
    if (!Platform.isWindows) return;
    await _pumpSheet(
      tester,
      MessageActionsSheet(message: _msg(), canRecall: true, onPoke: () {}),
    );
    await expectLater(
      find.byType(ActionSheet),
      matchesGoldenFile('goldens/action_sheet_message.png'),
    );
  });

  testWidgets('金样：会话长按菜单', (tester) async {
    if (!Platform.isWindows) return;
    await _pumpSheet(
      tester,
      const ChatActionsSheet(chat: Chat(id: 'group_1', title: '产品讨论组')),
    );
    await expectLater(
      find.byType(ActionSheet),
      matchesGoldenFile('goldens/action_sheet_chat.png'),
    );
  });
}
