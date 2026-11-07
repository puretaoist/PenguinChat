/// 平板（宽屏）布局测试：断点、分栏、气泡封顶、二级页限宽。
///
/// 这一组锁的是用户拍板的方案 A——**600dp 起就是双栏**（竖屏平板也分栏，
/// 和 Telegram Android 一致）。以前用的是散落的 `width >= 720`，现在统一走
/// [AppBreakpoints]；本文件同时守住"别再退回魔法数字"这件事：
/// 只断言 720 两侧的行为不够，必须覆盖 600/601 与 719/720 两个边界。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/client_api/objects.dart';
import 'package:penguinchat/client_api/segment.dart';
import 'package:penguinchat/client_api/session_providers.dart';
import 'package:penguinchat/kernel/onebot/backend_profile.dart';
import 'package:penguinchat/kernel/safety/safety_gate.dart';
import 'package:penguinchat/ui/pages/home_page.dart';
import 'package:penguinchat/ui/pages/settings/general_settings_page.dart';
import 'package:penguinchat/ui/pages/settings_page.dart';
import 'package:penguinchat/ui/platform/app_breakpoints.dart';
import 'package:penguinchat/ui/theme/telegram_theme.dart';
import 'package:penguinchat/ui/widgets/capped_content.dart';
import 'package:penguinchat/ui/widgets/chat_list_panel.dart';
import 'package:penguinchat/ui/widgets/message_bubble.dart';

late Directory _dir;

List<Override> _overrides() => <Override>[
  dataDirProvider.overrideWithValue(_dir),
  backendRegistryProvider.overrideWithValue(
    BackendProfileRegistry.fromJsonStrings(const <String>[]),
  ),
  safetyGateProvider.overrideWithValue(SafetyGate()),
];

Widget _host(Widget child) => ProviderScope(
  overrides: _overrides(),
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTelegramTheme(),
    home: child,
  ),
);

void _setSize(WidgetTester tester, double w, double h) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

ChatMessage _longMessage() => ChatMessage(
  id: 'm1',
  text: '这是一条很长的消息，' * 20,
  segments: <Segment>[TextSegment('这是一条很长的消息，' * 20)],
  time: DateTime(2026, 9, 12, 10, 30),
  outgoing: false,
  senderId: '20002',
  senderName: '小明',
  chatId: 'private_20002',
);

void main() {
  setUp(() {
    _dir = Directory.systemTemp.createTempSync('qqclient_tablet_');
    TelegramColors.use(TelegramPalette.dark);
  });

  tearDown(() {
    TelegramColors.use(TelegramPalette.dark);
    try {
      if (_dir.existsSync()) _dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄未放开，留给系统清。
    }
  });

  group('AppBreakpoints', () {
    test('600dp 起算平板（含 600，不含 599）', () {
      expect(AppBreakpoints.isTablet(599.9), isFalse);
      expect(AppBreakpoints.isTablet(600), isTrue);
      // 旧实现是 720，这里特意覆盖 700——它现在必须是双栏。
      expect(AppBreakpoints.isTablet(700), isTrue);
    });

    test('侧栏宽度 = max(320, 宽×35%)，照搬官方 getTabletLeftFragmentSize', () {
      // AndroidUtilities.java:3020-3022，下限 320dp、比例 35%、无上限。
      expect(AppBreakpoints.sidebarWidthFor(600), 320); // 210 → 夹到 320
      expect(AppBreakpoints.sidebarWidthFor(800), 320); // 280 → 夹到 320
      expect(AppBreakpoints.sidebarWidthFor(1000), 350);
      expect(AppBreakpoints.sidebarWidthFor(1280), 448);
      expect(AppBreakpoints.sidebarWidthFor(2560), 896);
    });

    testWidgets('contentHorizontalInset：窄屏 0，宽屏取超出 720 的一半', (tester) async {
      final List<double> got = <double>[];
      for (final double w in <double>[390, 720, 721, 1280]) {
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(size: Size(w, 800)),
            child: Builder(
              builder: (BuildContext c) {
                got.add(contentHorizontalInset(c));
                return const SizedBox.shrink();
              },
            ),
          ),
        );
      }
      expect(got[0], 0);
      expect(got[1], 0);
      expect(got[2], 0.5);
      expect(got[3], 280);
    });
  });

  group('聊天主界面（HomePage）', () {
    testWidgets('800dp 竖屏平板：分栏，侧栏 320dp + 右侧空态', (tester) async {
      _setSize(tester, 800, 1280);
      await tester.pumpWidget(_host(const HomePage()));
      await tester.pumpAndSettle();

      expect(find.byType(ChatListPanel), findsOneWidget);
      expect(find.text('选择一个会话开始聊天'), findsOneWidget);
      expect(tester.getSize(find.byType(ChatListPanel)).width, 320);
    });

    testWidgets('390dp 手机：仍是单栏，不出现右侧对话空态', (tester) async {
      _setSize(tester, 390, 844);
      await tester.pumpWidget(_host(const HomePage()));
      await tester.pumpAndSettle();

      expect(find.byType(ChatListPanel), findsOneWidget);
      expect(find.text('选择一个会话开始聊天'), findsNothing);
    });
  });

  group('气泡宽度', () {
    Future<double> widthAt(WidgetTester tester, double screenWidth) async {
      RenderBox? box;
      _setSize(tester, screenWidth, 900);
      await tester.pumpWidget(
        _host(
          Scaffold(
            backgroundColor: TelegramColors.bgChat,
            body: Center(
              child: SizedBox(
                width: screenWidth,
                child: MessageBubble(
                  message: _longMessage(),
                  onBubbleBox: (RenderBox b) => box = b,
                  onBubbleBoxGone: (RenderBox _) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(box, isNotNull, reason: '气泡 RenderBox 没交回来');
      return box!.size.width;
    }

    testWidgets('平板：气泡封顶 520dp，不再横跨整块对话区', (tester) async {
      final double w = await widthAt(tester, 1280);
      expect(w, lessThanOrEqualTo(AppBreakpoints.bubbleMaxWidth));
      expect(w, greaterThan(300), reason: '长文本应该撑到接近上限');
    });

    testWidgets('手机：仍按可用宽度的 78% 走（没被 520 影响）', (tester) async {
      final double w = await widthAt(tester, 390);
      expect(w, lessThanOrEqualTo(390 * 0.78 + 0.5));
      expect(w, greaterThan(200));
    });
  });

  group('二级页正文限宽', () {
    testWidgets('设置一级页：1280dp 下正文左右各留 280dp', (tester) async {
      _setSize(tester, 1280, 800);
      await tester.pumpWidget(_host(const SettingsPage()));
      await tester.pumpAndSettle();

      final ListView list = tester.widget<ListView>(
        find.byType(ListView, skipOffstage: false).first,
      );
      final EdgeInsets pad = list.padding! as EdgeInsets;
      expect(pad.left, 280);
      expect(pad.right, 280);
    });

    testWidgets('通用设置页：平板同样限宽，手机不加内边距', (tester) async {
      _setSize(tester, 1280, 800);
      await tester.pumpWidget(_host(const GeneralSettingsPage()));
      await tester.pumpAndSettle();
      final ListView wide = tester.widget<ListView>(
        find.byType(ListView, skipOffstage: false).first,
      );
      expect((wide.padding! as EdgeInsets).left, 280);

      _setSize(tester, 390, 844);
      await tester.pumpWidget(_host(const GeneralSettingsPage()));
      await tester.pumpAndSettle();
      final ListView narrow = tester.widget<ListView>(
        find.byType(ListView, skipOffstage: false).first,
      );
      expect((narrow.padding! as EdgeInsets).left, 0);
    });
  });
}
