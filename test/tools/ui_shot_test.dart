/// 仅用于"看界面"的截图脚本（不是断言测试）。
///
/// 用法：设置环境变量 UI_SHOT=1 后跑
///   flutter test test/tools/ui_shot_test.dart
/// 截图写到 C:/Users/Administrator/.dsh/workspace/qqshots/ui_*.png。
/// 不设 UI_SHOT 时两个用例直接空跑，正常 flutter test 不受影响。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/client_api/chat_store.dart';
import 'package:penguinchat/client_api/objects.dart';
import 'package:penguinchat/client_api/segment.dart';
import 'package:penguinchat/client_api/session.dart';
import 'package:penguinchat/client_api/session_providers.dart';
import 'package:penguinchat/kernel/onebot/backend_profile.dart';
import 'package:penguinchat/kernel/safety/safety_gate.dart';
import 'package:penguinchat/ui/pages/home_page.dart';
import 'package:penguinchat/ui/pages/settings_page.dart';
import 'package:penguinchat/ui/theme/telegram_theme.dart';

import '../support/fake_session.dart';

const String _outDir = 'C:/Users/Administrator/.dsh/workspace/qqshots';
const String _fonts =
    'C:/Users/Administrator/scoop/apps/flutter/bin/cache/artifacts/material_fonts';

final bool _enabled = Platform.environment['UI_SHOT'] == '1';

late ChatStore store;
late FakeSession session;
late Directory dir;

Future<void> _makeStore(List<Chat> chats) async {
  dir = Directory.systemTemp.createTempSync('qqclient_shot');
  session = FakeSession();
  session.chatList = chats;
  session.markReady();
  store = ChatStore(session: session, dataDir: dir);
  await store.bootstrap();
}

ChatMessage _msg(
  String id,
  String text, {
  bool out = false,
  String name = '',
  String sid = '',
  int minute = 0,
  String chatId = 'private_20002',
}) => ChatMessage(
  id: id,
  text: text,
  segments: <Segment>[TextSegment(text)],
  time: DateTime(2026, 11, 6, 14, minute),
  outgoing: out,
  senderName: name,
  senderId: sid,
  chatId: chatId,
);

Widget _app(Widget home) => ProviderScope(
  overrides: <Override>[
    dataDirProvider.overrideWithValue(Directory.systemTemp),
    backendRegistryProvider.overrideWithValue(
      BackendProfileRegistry.fromJsonStrings(const <String>[]),
    ),
    safetyGateProvider.overrideWithValue(SafetyGate()),
    activeQq8BackendProvider.overrideWith(
      (ref) => (session: session, store: store),
    ),
  ],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _shotTheme(),
    home: home,
    builder: (BuildContext context, Widget? child) => RepaintBoundary(
      key: const ValueKey('shot-root'),
      child: child ?? const SizedBox.shrink(),
    ),
  ),
);

ThemeData _shotTheme() {
  final ThemeData base = buildTelegramTheme(dark: true, useSystemFonts: false);
  return base.copyWith(textTheme: base.textTheme.apply(fontFamily: 'ShotCJK'));
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  final RenderRepaintBoundary boundary = tester.firstRenderObject(
    find.byKey(const ValueKey('shot-root')),
  );
  await tester.runAsync(() async {
    final ui.Image img = await boundary.toImage(pixelRatio: 2);
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);
    File('$_outDir/ui_$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<void> _loadFonts() async {
  final FontLoader roboto = FontLoader('Roboto');
  for (final String f in <String>[
    'roboto-regular.ttf',
    'roboto-medium.ttf',
    'roboto-bold.ttf',
  ]) {
    final Uint8List bytes = File('$_fonts/$f').readAsBytesSync();
    roboto.addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
  }
  await roboto.load();
  // 中文字形：Roboto 没有 CJK，测试引擎不会回落到系统字体，另起一族并挂到主题上。
  final FontLoader cjk = FontLoader('ShotCJK');
  final Uint8List db = File('C:/Windows/Fonts/Deng.ttf').readAsBytesSync();
  cjk.addFont(Future<ByteData>.value(ByteData.view(db.buffer)));
  await cjk.load();
  final FontLoader icons = FontLoader('MaterialIcons');
  final Uint8List ib = File('$_fonts/materialicons-regular.otf').readAsBytesSync();
  icons.addFont(Future<ByteData>.value(ByteData.view(ib.buffer)));
  await icons.load();
}

void main() {
  setUpAll(() async {
    if (_enabled) await _loadFonts();
  });

  testWidgets('会话列表', (WidgetTester tester) async {
    if (!_enabled) return;
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => _makeStore(<Chat>[
      Chat(
        id: 'private_20002',
        title: '小明',
        type: ChatType.private,
        rawId: 20002,
        lastMessage: '在吗，晚上一起吃饭？',
        lastTime: DateTime(2026, 11, 6, 14, 3),
        unreadCount: 2,
        online: true,
      ),
      Chat(
        id: 'group_12345',
        title: '测试群',
        type: ChatType.group,
        rawId: 12345,
        memberCount: 128,
        lastMessage: '张三: 文档我发群里了',
        lastTime: DateTime(2026, 11, 6, 13, 40),
        unreadCount: 12,
      ),
      Chat(
        id: 'private_30003',
        title: '李四',
        type: ChatType.private,
        rawId: 30003,
        lastMessage: '收到',
        lastTime: DateTime(2026, 11, 5, 22, 10),
      ),
      Chat(
        id: 'group_40004',
        title: '产品需求对接群（临时）',
        type: ChatType.group,
        rawId: 40004,
        memberCount: 6,
        lastMessage: '[图片]',
        lastTime: DateTime(2026, 11, 4, 9, 5),
        muted: true,
      ),
    ]));
    await tester.pumpWidget(_app(const HomePage()));
    await _settle(tester);
    await _shot(tester, 'list_dark');
  });

  testWidgets('聊天页', (WidgetTester tester) async {
    if (!_enabled) return;
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => _makeStore(<Chat>[
      Chat(
        id: 'private_20002',
        title: '小明',
        type: ChatType.private,
        rawId: 20002,
        lastMessage: '好',
        lastTime: DateTime(2026, 11, 6, 14, 8),
        online: true,
      ),
    ]));
    session.historyPages.add(
      HistoryPage(<ChatMessage>[
        _msg('m1', '下午有空吗？', name: '小明', sid: '20002', minute: 1),
        _msg('m2', '想约你去看那个新开的展', name: '小明', sid: '20002', minute: 1),
        _msg('m3', '在哪', out: true, minute: 2),
        _msg(
          'm4',
          '就在中山路那边，周末人应该挺多的，得早点去排队',
          name: '小明',
          sid: '20002',
          minute: 3,
        ),
        _msg('m5', '行，那周六上午？', out: true, minute: 4),
        _msg('m6', '好', name: '小明', sid: '20002', minute: 8),
      ]),
    );
    await tester.pumpWidget(_app(const HomePage()));
    await _settle(tester);
    await tester.tap(find.text('小明').first);
    await _settle(tester);
    await _shot(tester, 'chat_dark');
  });

  testWidgets('群聊页', (WidgetTester tester) async {
    if (!_enabled) return;
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => _makeStore(<Chat>[
      Chat(
        id: 'group_12345',
        title: '测试群',
        type: ChatType.group,
        rawId: 12345,
        memberCount: 128,
        lastMessage: '谢谢！',
        lastTime: DateTime(2026, 11, 6, 14, 8),
      ),
    ]));
    session.historyPages.add(
      HistoryPage(<ChatMessage>[
        _msg('g1', '大家好，我是新来的', name: '张三', sid: '30001',
            minute: 1, chatId: 'group_12345'),
        _msg('g2', '欢迎欢迎', name: '李四', sid: '30002',
            minute: 2, chatId: 'group_12345'),
        _msg('g3', '同上', name: '李四', sid: '30002',
            minute: 2, chatId: 'group_12345'),
        _msg('g4', '这条没有昵称的成员', sid: '39999',
            minute: 3, chatId: 'group_12345'),
        _msg('g5', '谢谢！', name: '张三', sid: '30001',
            minute: 4, chatId: 'group_12345'),
      ]),
    );
    await tester.pumpWidget(_app(const HomePage()));
    await _settle(tester);
    await tester.tap(find.text('测试群').first);
    await _settle(tester);
    await _shot(tester, 'group_dark');
  });

  // 平板（1904x3040 @2.75 → 逻辑 692x1105，>=600 走宽屏分栏）：
  // 这两个用例是给 "平板没有悬浮底栏" 那条 bug 取证用的。
  testWidgets('平板-空会话页', (WidgetTester tester) async {
    if (!_enabled) return;
    tester.view.physicalSize = const Size(1904, 3040);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => _makeStore(<Chat>[
      Chat(
        id: 'private_20002',
        title: '小明',
        type: ChatType.private,
        rawId: 20002,
        lastMessage: '好',
        lastTime: DateTime(2026, 11, 6, 14, 8),
        online: true,
      ),
      Chat(
        id: 'group_12345',
        title: '测试群',
        type: ChatType.group,
        rawId: 12345,
        memberCount: 128,
        lastMessage: '谢谢！',
        lastTime: DateTime(2026, 11, 6, 14, 8),
      ),
    ]));
    await tester.pumpWidget(_app(const HomePage()));
    await _settle(tester);
    await _shot(tester, 'tablet_empty_dark');
  });

  testWidgets('平板-会话页', (WidgetTester tester) async {
    if (!_enabled) return;
    tester.view.physicalSize = const Size(1904, 3040);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => _makeStore(<Chat>[
      Chat(
        id: 'private_20002',
        title: '小明',
        type: ChatType.private,
        rawId: 20002,
        lastMessage: '好',
        lastTime: DateTime(2026, 11, 6, 14, 8),
        online: true,
      ),
    ]));
    session.historyPages.add(
      HistoryPage(<ChatMessage>[
        _msg('m1', '下午有空吗？', name: '小明', sid: '20002', minute: 1),
        _msg('m2', '想约你去看那个新开的展', name: '小明', sid: '20002', minute: 1),
        _msg('m3', '在哪', out: true, minute: 2),
        _msg('m4', '就在中山路那边，周末人应该挺多的，得早点去排队',
            name: '小明', sid: '20002', minute: 3),
        _msg('m5', '行，那周六上午？', out: true, minute: 4),
        _msg('m6', '好', name: '小明', sid: '20002', minute: 8),
      ]),
    );
    await tester.pumpWidget(_app(const HomePage()));
    await _settle(tester);
    await tester.tap(find.text('小明').first);
    await _settle(tester);
    await _shot(tester, 'tablet_chat_dark');
  });

  testWidgets('设置页', (WidgetTester tester) async {
    if (!_enabled) return;
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => _makeStore(<Chat>[]));
    await tester.pumpWidget(_app(const SettingsPage()));
    await _settle(tester);
    await _shot(tester, 'settings_dark');
  });
}
