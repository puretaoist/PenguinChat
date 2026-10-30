/// 三处「列表行」的几何与外观：群成员（UserCell）/ 群文件（SharedDocumentCell）/
/// 转发目标（DialogCell）。
///
/// 出处（TG 源码）：
/// * UserCell.java:497 行高 58、:183 头像 46 左距 7、:189 名字 16 bold、:197 状态 15
/// * SharedDocumentCell.java:615 行高 64、:280 图标圆 42、:163 名 16、:198 副标题 13、
///   :753 分隔线从 72 起
/// * DialogCell.java:172 行高 70、:171 文字起点 72、:1252 标题 17、:1254 摘要 16
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/client_api/objects.dart';
import 'package:qqclient/kernel/wlogin8/qq8_gfs.dart';
import 'package:qqclient/kernel/wlogin8/qq8_list.dart';
import 'package:qqclient/ui/theme/telegram_theme.dart';
import 'package:qqclient/ui/widgets/forward_picker.dart';
import 'package:qqclient/ui/widgets/group_files_panel.dart';
import 'package:qqclient/ui/widgets/group_members_panel.dart';

final bool goldenSkip = !Platform.isWindows;

Qq8GroupMember _member(int uin, String nick,
        {bool admin = false, String title = ''}) =>
    Qq8GroupMember(
      uin: uin,
      nick: nick,
      card: '',
      gender: -1,
      age: 0,
      level: 1,
      title: title,
      titleExpireTime: 0,
      joinTime: 0,
      lastSpeakTime: 0,
      shutupUntil: 0,
      admin: admin,
    );

List<Qq8GroupMember> _members() => <Qq8GroupMember>[
      _member(10001, '张三', admin: true, title: '产品'),
      _member(10002, '李四'),
      _member(10003, '王五', title: '摸鱼中'),
      _member(10004, '赵六'),
    ];

List<Qq8GfsEntry> _files() => <Qq8GfsEntry>[
      const Qq8GfsEntry(
          fid: '/docs', pid: Qq8Gfs.rootPid, name: '资料', isDir: true, fileCount: 3),
      const Qq8GfsEntry(
          fid: 'a1b2c3d4',
          pid: Qq8Gfs.rootPid,
          name: '需求文档.pdf',
          isDir: false,
          size: 1024 * 1024 * 2,
          uploaderUin: 10001,
          createTime: 1793000000),
      const Qq8GfsEntry(
          fid: 'e5f6a7b8',
          pid: Qq8Gfs.rootPid,
          name: '会议纪要.docx',
          isDir: false,
          size: 24576,
          uploaderUin: 10002,
          createTime: 1793100000),
    ];

List<Chat> _chats() => <Chat>[
      Chat(
        id: 'group_1',
        title: '产品讨论组',
        lastMessage: '',
        lastTime: DateTime(2026, 10, 30, 9, 12),
        type: ChatType.group,
      ),
      Chat(
        id: 'private_2',
        title: '李四',
        lastMessage: '',
        lastTime: DateTime(2026, 10, 30, 8, 5),
      ),
    ];

Future<void> _pump(WidgetTester tester, Widget child,
    {Size size = const Size(360, 620)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: buildTelegramTheme(),
    home: Scaffold(body: child),
  ));
  await tester.pumpAndSettle();
}

TextStyle _styleOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!;

void main() {
  group('群成员行（UserCell 几何）', () {
    testWidgets('行高 58、名字 16 w600、状态 15', (tester) async {
      await _pump(
        tester,
        GroupMembersPanel(
          title: '产品讨论组',
          ownerUin: 10001,
          loader: () async => _members(),
        ),
      );
      expect(tester.getSize(find.byKey(const ValueKey('member-10002'))).height,
          58);
      expect(_styleOf(tester, '李四').fontSize, 16);
      expect(_styleOf(tester, '李四').fontWeight, FontWeight.w600);
      final sub = tester.widgetList<Text>(find.byType(Text)).firstWhere(
          (t) => (t.data ?? '').contains('10002 ·'));
      expect(sub.style!.fontSize, 15);
    });

    testWidgets('金样：群成员面板', (tester) async {
      await _pump(
        tester,
        GroupMembersPanel(
          title: '产品讨论组',
          ownerUin: 10001,
          onMemberMenu: (_) {},
          loader: () async => _members(),
        ),
      );
      await expectLater(find.byType(GroupMembersPanel),
          matchesGoldenFile('goldens/group_members_panel.png'),
          skip: goldenSkip);
    });
  });

  group('群文件行（SharedDocumentCell 几何）', () {
    testWidgets('行高 64、文件名 16、副标题 13、分隔线从 72 起', (tester) async {
      await _pump(
        tester,
        GroupFilesPanel(
          title: '产品讨论组',
          loader: (_) async => _files(),
        ),
      );
      expect(tester.getSize(find.byKey(const ValueKey('gf-entry-/docs'))).height,
          64);
      expect(_styleOf(tester, '需求文档.pdf').fontSize, 16);
      expect(
          tester
              .widgetList<Text>(find.byType(Text))
              .firstWhere((t) => (t.data ?? '').startsWith('2.0 MB'))
              .style!
              .fontSize,
          13);
      expect(
        find.byWidgetPredicate((w) =>
            w is Container && w.margin == const EdgeInsets.only(left: 72)),
        findsWidgets,
      );
    });

    testWidgets('金样：群文件面板', (tester) async {
      await _pump(
        tester,
        GroupFilesPanel(
          title: '产品讨论组',
          loader: (_) async => _files(),
          onDownload: (_) async => '/tmp/x',
          onRename: (a, b) async {},
          onDelete: (_) async {},
          onCreateDir: (_) async {},
          onUpload: () async {},
        ),
      );
      await expectLater(find.byType(GroupFilesPanel),
          matchesGoldenFile('goldens/group_files_panel.png'),
          skip: goldenSkip);
    });
  });

  group('转发行（DialogCell 几何）', () {
    testWidgets('行高 70、标题 17、副标题 16、分隔线从 72 起', (tester) async {
      await _pump(tester, ForwardPickerSheet(chats: _chats(), onPick: (_) {}));
      expect(
          tester.getSize(find.byKey(const ValueKey('forward-to-group_1'))).height,
          70);
      expect(_styleOf(tester, '产品讨论组').fontSize, 17);
      expect(_styleOf(tester, '群聊').fontSize, 16);
      expect(
        find.byWidgetPredicate((w) =>
            w is Container && w.margin == const EdgeInsets.only(left: 72)),
        findsOneWidget, // 两条会话之间只画一条
      );
    });

    testWidgets('金样：转发选择器', (tester) async {
      await _pump(tester, ForwardPickerSheet(chats: _chats(), onPick: (_) {}));
      await expectLater(find.byType(ForwardPickerSheet),
          matchesGoldenFile('goldens/forward_picker.png'),
          skip: goldenSkip);
    });
  });
}
