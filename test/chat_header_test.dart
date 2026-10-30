/// 聊天页头部（ChatHeader）：几何对齐 TG \`ui/Components/ChatAvatarContainer.java\`
/// —— 高度 56（TelegramMetrics.headerHeight）、头像 42（:265 setRoundRadius(dp(21))）、
/// 标题 18 粗体（:282 titleTextView.setTextSize(18)）、副标题 14（:307）、
/// 右侧群工具 + 设置按钮 22dp。抽屉里 \`lib/ui/pages/home_page.dart\` 只负责传回调。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/client_api/objects.dart';
import 'package:qqclient/ui/theme/telegram_theme.dart';
import 'package:qqclient/ui/widgets/chat_header.dart';
import 'package:qqclient/ui/widgets/telegram_avatar.dart';

final bool goldenSkip = !Platform.isWindows;

Chat _group() => Chat(
      id: 'group_1',
      title: '产品讨论组',
      lastMessage: '',
      lastTime: DateTime(2026, 10, 30, 9, 12),
      type: ChatType.group,
      memberCount: 42,
    );

Chat _priv({bool online = true}) => Chat(
      id: 'private_2',
      title: '李四',
      lastMessage: '',
      lastTime: DateTime(2026, 10, 30, 8, 5),
      online: online,
    );

Future<void> _pump(WidgetTester tester, Widget child,
    {Size size = const Size(360, 120), bool dark = true}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 颜色是全局单例（TelegramColors.use），测试里必须自己切，否则"亮色"图仍是暗的。
  TelegramColors.use(dark ? TelegramPalette.dark : TelegramPalette.light);
  addTearDown(() => TelegramColors.use(TelegramPalette.dark));
  await tester.pumpWidget(MaterialApp(
    theme: buildTelegramTheme(dark: dark),
    home: Scaffold(body: child),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('几何：高 56、标题 18 w700、副标题 14、头像 42', (tester) async {
    await _pump(tester, ChatHeader(chat: _group(), onOpenSettings: () {}));
    expect(tester.getSize(find.byType(ChatHeader)).height, 56);
    final title = tester.widget<Text>(find.byKey(const ValueKey('chat-header-title')));
    expect(title.style!.fontSize, 18);
    expect(title.style!.fontWeight, FontWeight.w700);
    final sub = tester.widget<Text>(find.byKey(const ValueKey('chat-header-subtitle')));
    expect(sub.style!.fontSize, 14);
    expect(sub.data, '群聊 · 42 人');
    final avatar = tester.widget<TelegramAvatar>(find.byType(TelegramAvatar));
    expect(avatar.size, 42);
  });

  testWidgets('私聊显示在线/离线，没有群工具菜单', (tester) async {
    await _pump(tester, ChatHeader(chat: _priv()));
    expect(tester.widget<Text>(find.byKey(const ValueKey('chat-header-subtitle'))).data,
        '在线');
    expect(find.byKey(const ValueKey('group-menu')), findsNothing);
    await _pump(tester, ChatHeader(chat: _priv(online: false)));
    expect(tester.widget<Text>(find.byKey(const ValueKey('chat-header-subtitle'))).data,
        '离线');
  });

  testWidgets('群工具菜单三项，回调按项触发', (tester) async {
    final calls = <String>[];
    await _pump(
      tester,
      ChatHeader(
        chat: _group(),
        onOpenGroupFiles: () => calls.add('files'),
        onOpenGroupSettings: () => calls.add('settings'),
        onOpenMembers: () => calls.add('members'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('group-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-menu-files')), findsOneWidget);
    expect(find.byKey(const ValueKey('group-menu-settings')), findsOneWidget);
    expect(find.byKey(const ValueKey('group-menu-members')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('group-menu-settings')));
    await tester.pumpAndSettle();
    expect(calls, <String>['settings']);
  });

  testWidgets('返回键只在给了 onBack 时出现', (tester) async {
    await _pump(tester, ChatHeader(chat: _group()));
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    var back = 0;
    await _pump(tester, ChatHeader(chat: _group(), onBack: () => back++));
    await tester.tap(find.byIcon(Icons.arrow_back));
    expect(back, 1);
  });

  testWidgets('金样：群聊头部（暗）', (tester) async {
    await _pump(tester, ChatHeader(chat: _group(), onOpenSettings: () {}));
    await expectLater(find.byType(ChatHeader),
        matchesGoldenFile('goldens/chat_header_group.png'),
        skip: goldenSkip);
  });

  testWidgets('金样：私聊头部（亮）', (tester) async {
    await _pump(tester, ChatHeader(chat: _priv()), dark: false);
    await expectLater(find.byType(ChatHeader),
        matchesGoldenFile('goldens/chat_header_private_light.png'),
        skip: goldenSkip);
  });
}
