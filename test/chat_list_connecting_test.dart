/// 会话栏空态的三种口吻必须分清楚：
///   store==null + connecting   -> 「正在连接…」（恢复中，别催用户配置）
///   store==null + !connecting  -> 「未连接后端」+ 去连接设置 / QQ 账号登录
///   store!=null                -> 「暂无会话」
///
/// 冷启动壳在超时后会提前放人进主界面（那会话栏的 store 还是 null），
/// 这里就是在锁那个"假消息"不再出现的回归。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/client_api/objects.dart';
import 'package:qqclient/ui/theme/telegram_theme.dart';
import 'package:qqclient/ui/widgets/chat_list_panel.dart';

Future<void> _pump(
  WidgetTester tester, {
  required bool connecting,
  List<Chat> chats = const <Chat>[],
}) async {
  TelegramColors.use(TelegramPalette.dark);
  addTearDown(() => TelegramColors.use(TelegramPalette.dark));
  tester.view.physicalSize = const Size(360, 560);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTelegramTheme(),
    home: Scaffold(
      body: ChatListPanel(
        chats: chats,
        store: null,
        connecting: connecting,
        selectedChatId: null,
        onOpenChat: (_) {},
        onLongPressChat: (_, _) {},
        onRefresh: () async {},
        onOpenSearch: () {},
        onToggleTheme: () {},
        onOpenSettings: () {},
        onOpenArchive: (_, _) {},
        onOpenConnect: () {},
        onOpenQq8Login: () {},
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('恢复中：显示「正在连接…」，不出现假的「未连接后端」与配置入口',
      (tester) async {
    await _pump(tester, connecting: true);

    expect(find.text('正在连接…'), findsOneWidget);
    expect(find.text('正在恢复上次的会话，请稍候'), findsOneWidget);
    expect(find.text('未连接后端'), findsNothing);
    expect(find.text('去连接设置'), findsNothing);
    expect(find.text('QQ 账号登录（自实现协议）'), findsNothing);
  });

  testWidgets('有缓存会话预览：直接画列表 + 顶部进度条，不出现空态文案',
      (tester) async {
    // 冷启动"第一帧就是列表"的那条路径：store 还没建好（登录中），
    // 会话来自磁盘索引预览。此时必须画真实的行，而不是「正在连接…」空态。
    await _pump(
      tester,
      connecting: true,
      chats: <Chat>[
        Chat(
          id: 'private_2089495846',
          title: '净凾',
          type: ChatType.private,
          rawId: 2089495846,
          lastMessage: '睡了会',
          lastTime: DateTime.fromMillisecondsSinceEpoch(1793436526000),
        ),
        Chat(
          id: 'group_486045673',
          title: '久有凌云志',
          type: ChatType.group,
          rawId: 486045673,
          lastMessage: '[图片]',
          unreadCount: 2,
        ),
      ],
    );

    expect(find.text('净凾'), findsOneWidget);
    expect(find.text('久有凌云志'), findsOneWidget);
    expect(find.text('正在连接…'), findsNothing);
    expect(find.text('未连接后端'), findsNothing);
    expect(find.byKey(const ValueKey('preview-connecting-line')), findsOneWidget);
  });

  testWidgets('没在恢复：仍显示「未连接后端」与两个入口', (tester) async {
    await _pump(tester, connecting: false);

    expect(find.text('未连接后端'), findsOneWidget);
    expect(find.text('去连接设置'), findsOneWidget);
    expect(find.text('QQ 账号登录（自实现协议）'), findsOneWidget);
    expect(find.text('正在连接…'), findsNothing);
  });
}
