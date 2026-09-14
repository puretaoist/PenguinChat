/// 消息列表表现层测试（现代 Telegram 形态）
///
/// 覆盖三块**容易悄悄坏掉**的东西：
/// * [buildMessageItems] 的日期分隔与分组规则（名字在组首、头像在组尾）；
/// * [DateChip.label] 的"今天/昨天/日期"文案；
/// * [MessageBubble] 的回复条、@我竖条、送达状态、**反撤回（查看原文）**。
///
/// 最后一张 `flutter test --update-goldens` 可重新生成的金样，是给人看的：
/// 它按本机字体渲染，跨平台会有差异，所以只在 Windows 上跑（CI 是 Linux）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/client_api/chat_store.dart';
import 'package:qqclient/client_api/objects.dart';
import 'package:qqclient/client_api/segment.dart';
import 'package:qqclient/client_api/session.dart';
import 'package:qqclient/kernel/wlogin8/qq8_list.dart';
import 'package:qqclient/ui/theme/telegram_theme.dart';
import 'package:qqclient/ui/widgets/message_bubble.dart';
import 'package:qqclient/ui/widgets/group_members_panel.dart';
import 'package:qqclient/ui/widgets/jump_to_latest.dart';
import 'package:qqclient/ui/widgets/message_actions.dart';
import 'package:qqclient/ui/widgets/message_list_builder.dart';
import 'package:qqclient/ui/widgets/storage_dialog.dart';
import 'package:qqclient/ui/widgets/telegram_avatar.dart';

ChatMessage _msg(
  String id,
  String text, {
  required DateTime time,
  bool outgoing = false,
  String senderId = '20002',
  String senderName = '阿花',
  bool atMe = false,
  bool system = false,
  String? replyPreview,
  String replyToId = '',
  MessageSendState sendState = MessageSendState.sent,
  bool recalled = false,
  bool revealed = false,
  List<Segment>? segments,
}) =>
    ChatMessage(
      id: id,
      text: text,
      segments: segments ?? <Segment>[TextSegment(text)],
      time: time,
      outgoing: outgoing,
      senderId: senderId,
      senderName: senderName,
      chatId: 'group_12345',
      atMe: atMe,
      system: system,
      replyToId: replyToId.isEmpty ? null : replyToId,
      replyPreview: replyPreview,
      sendState: sendState,
      deleted: recalled,
      revealed: revealed,
    );

Widget _wrap(Widget child) => MaterialApp(
      theme: buildTelegramTheme(),
      home: Scaffold(
        backgroundColor: TelegramColors.bgChat,
        body: ListView(padding: const EdgeInsets.symmetric(vertical: 12), children: [
          child,
        ]),
      ),
    );

/// 一条消息按列表里的方式摆出来（含头像位）。
Widget _row(
  MessageListItem item, {
  VoidCallback? onReveal,
  VoidCallback? onRetry,
}) {
  final m = item.message!;
  return Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      if (item.showAvatarSlot)
        SizedBox(
          width: TelegramMetrics.bubbleAvatarSize + 10,
          child: item.showAvatar
              ? Padding(
                  padding: const EdgeInsets.only(left: 8, right: 6),
                  child: TelegramAvatar(
                      name: m.senderName,
                      size: TelegramMetrics.bubbleAvatarSize),
                )
              : null,
        ),
      Expanded(
        child: MessageBubble(
          message: m,
          showSenderName: item.showSenderName,
          highlighted: m.atMe || m.replyToId != null,
          onReveal: onReveal,
          onRetry: onRetry,
        ),
      ),
    ],
  );
}

void main() {
  final day1 = DateTime(2026, 9, 11, 9, 30);
  final day2 = DateTime(2026, 9, 12, 10, 0);

  /// 单条消息按列表里的方式摆出来（跳过它前面那条日期分隔）。
  MessageListItem singleOf(ChatMessage m) => buildMessageItems(
        <ChatMessage>[m],
        showAvatars: true,
      ).firstWhere((i) => i.message != null);

  group('buildMessageItems：日期分隔与分组', () {
    test('跨天处插日期项，首尾各一次', () {
      final items = buildMessageItems(<ChatMessage>[
        _msg('1', 'a', time: day1),
        _msg('2', 'b', time: day1.add(const Duration(minutes: 1))),
        _msg('3', 'c', time: day2),
      ], showAvatars: true);
      expect(items.map((e) => e.isDay).toList(), <bool>[true, false, false, true, false]);
      expect(items[0].day, DateTime(2026, 9, 11));
      expect(items[3].day, DateTime(2026, 9, 12));
    });

    test('同人 5 分钟内：名字只在组首、头像只在组尾', () {
      final items = buildMessageItems(<ChatMessage>[
        _msg('1', 'a', time: day2),
        _msg('2', 'b', time: day2.add(const Duration(minutes: 1))),
        _msg('3', 'c', time: day2.add(const Duration(minutes: 2))),
      ], showAvatars: true);
      final msgs = items.where((e) => !e.isDay).toList();
      expect(msgs.map((e) => e.showSenderName).toList(), <bool>[true, false, false]);
      expect(msgs.map((e) => e.showAvatar).toList(), <bool>[false, false, true]);
      expect(msgs.every((e) => e.showAvatarSlot), isTrue);
    });

    test('超过 5 分钟 / 换人 / 自己发的：各自新开一组', () {
      final items = buildMessageItems(<ChatMessage>[
        _msg('1', 'a', time: day2),
        _msg('2', 'b', time: day2.add(const Duration(minutes: 6))),
        _msg('3', 'c', senderId: '30003', senderName: '阿明',
            time: day2.add(const Duration(minutes: 7))),
        _msg('4', 'd', outgoing: true, time: day2.add(const Duration(minutes: 8))),
      ], showAvatars: true);
      final msgs = items.where((e) => !e.isDay).toList();
      expect(msgs.map((e) => e.showSenderName).toList(),
          <bool>[true, true, true, true]);
      // 自己发的不占头像位（TG 不画自己的头像）
      expect(msgs.last.showAvatarSlot, isFalse);
      expect(msgs.last.showAvatar, isFalse);
    });

    test('私聊（showAvatars=false）不留头像位', () {
      final items = buildMessageItems(
        <ChatMessage>[_msg('1', 'a', time: day2)],
        showAvatars: false,
      );
      expect(items.where((e) => !e.isDay).single.showAvatarSlot, isFalse);
    });
  });

  group('DateChip.label', () {
    test('今天 / 昨天 / 今年日期 / 跨年日期', () {
      final now = DateTime(2026, 9, 12, 15, 0);
      expect(DateChip.label(DateTime(2026, 9, 12, 1, 0), now: now), '今天');
      expect(DateChip.label(DateTime(2026, 9, 11, 23, 0), now: now), '昨天');
      expect(DateChip.label(DateTime(2026, 3, 5), now: now), '3月5日');
      expect(DateChip.label(DateTime(2025, 12, 31), now: now), '2025年12月31日');
    });
  });

  group('MessageBubble：现代 TG 形态', () {
    testWidgets('回复条显示被引用的原文', (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _msg('1', '这句是回复', time: day2,
            replyPreview: '被引用的那句', replyToId: '99'),
      )));
      expect(find.text('被引用的那句'), findsOneWidget);
      expect(find.text('这句是回复'), findsOneWidget);
    });

    testWidgets('发送失败：红字重试入口 + 文本仍在', (tester) async {
      var retried = 0;
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _msg('1', '没发出去的话', time: day2,
            outgoing: true, sendState: MessageSendState.failed),
        onRetry: () => retried++,
      )));
      expect(find.text('没发出去的话'), findsOneWidget);
      await tester.tap(find.text('发送失败，点此重试'));
      await tester.pump();
      expect(retried, 1);
    });

    testWidgets('未送达显示时钟、已送达显示双勾', (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _msg('1', 'a', time: day2,
            outgoing: true, sendState: MessageSendState.sending),
      )));
      expect(find.byIcon(Icons.schedule), findsOneWidget);

      await tester.pumpWidget(_wrap(MessageBubble(
        message: _msg('2', 'b', time: day2, outgoing: true),
      )));
      expect(find.byIcon(Icons.done_all), findsOneWidget);
    });

    testWidgets('反撤回：默认只显示占位 + 「查看」，点开后显示原文', (tester) async {
      var revealed = 0;
      final recalled = _msg('1', '原始内容', time: day2, recalled: true);
      await tester.pumpWidget(_wrap(MessageBubble(
        message: recalled,
        onReveal: () => revealed++,
      )));
      expect(find.text('[消息已撤回]'), findsOneWidget);
      expect(find.text('原始内容'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('msg-reveal')));
      await tester.pump();
      expect(revealed, 1);

      // 揭示之后：原文 + "已撤回"标注
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _msg('1', '原始内容', time: day2, recalled: true, revealed: true),
      )));
      expect(find.text('原始内容'), findsOneWidget);
      expect(find.byKey(const ValueKey('msg-recalled-note')), findsOneWidget);
      expect(find.byKey(const ValueKey('msg-reveal')), findsNothing);
    });

    testWidgets('没有 onReveal 时不出现「查看」（例如没有 store 的场景）', (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _msg('1', 'x', time: day2, recalled: true),
      )));
      expect(find.byKey(const ValueKey('msg-reveal')), findsNothing);
    });
  });

  group('多元素渲染：图片 / 表情 / @', () {
    testWidgets('图片段：没有直链时显示占位（文件名 + 尺寸），不留空白', (tester) async {
      final msg = _msg('img1', '[图片]', time: day2, segments: <Segment>[
        const TextSegment('看这张 '),
        const ImageSegment(
          '00112233445566778899aabbccddeeff4096-320-240.jpg',
          summary: '[图片]',
          width: 320,
          height: 240,
        ),
      ]);
      await tester.pumpWidget(_wrap(_row(singleOf(msg))));
      await tester.pumpAndSettle();

      expect(find.text('看这张 '), findsOneWidget);
      expect(find.textContaining('00112233445566778899aabbccddeeff4096'), findsOneWidget,
          reason: '占位里要有文件名，排查时才知道是哪张图');
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('图片段：有直链但加载不出来（测试环境没有网）→ 占位兜底，不抛异常',
        (tester) async {
      final msg = _msg('img2', '[图片]', time: day2, segments: <Segment>[
        const ImageSegment('x.jpg',
            url: 'https://c2cpicdw.qpic.cn/offpic_new/0/abc/0',
            width: 100,
            height: 100),
      ]);
      await tester.pumpWidget(_wrap(_row(singleOf(msg))));
      await tester.pumpAndSettle();

      // flutter_test 默认把网络请求打成 400，Image.network 会走 errorBuilder
      expect(tester.takeException(), isNull, reason: '加载失败必须被 errorBuilder 接住');
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    });

    testWidgets('闪照：显示"闪照 · 点击查看"，不直接出图', (tester) async {
      final msg = _msg('flash1', '[闪照]', time: day2, segments: <Segment>[
        const ImageSegment('f.jpg', flash: true, summary: '[闪照]'),
      ]);
      await tester.pumpWidget(_wrap(_row(singleOf(msg))));
      await tester.pumpAndSettle();

      expect(find.text('闪照 · 点击查看'), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    });

    testWidgets('表情段：用名字表显示 [微笑]，名字查不到退回 [表情]', (tester) async {
      final msg = _msg('face1', '[表情]', time: day2, segments: <Segment>[
        const TextSegment('笑一个'),
        const FaceSegment('14'),
        const TextSegment('吧'),
        const FaceSegment('999999'),
      ]);
      await tester.pumpWidget(_wrap(_row(singleOf(msg))));
      await tester.pumpAndSettle();

      // 行内混排（文本+表情）走 Text.rich，所以查 span 要 findRichText
      expect(find.textContaining('[微笑]', findRichText: true), findsOneWidget);
      expect(find.textContaining('[表情]', findRichText: true), findsOneWidget,
          reason: '名字表里没有的 id 不能瞎编名字');
    });

    testWidgets('@ 段：显示 @名字（拿不到名字就显示 @uin）', (tester) async {
      final msg = _msg('at1', '@你', time: day2, segments: <Segment>[
        const AtSegment('10001', name: '我'),
        const TextSegment(' 看一下'),
        const AtSegment('20002'),
      ]);
      await tester.pumpWidget(_wrap(_row(singleOf(msg))));
      await tester.pumpAndSettle();

      expect(find.textContaining('@我', findRichText: true), findsOneWidget);
      expect(find.textContaining('@20002', findRichText: true), findsOneWidget);
    });
  });

  group('buildMessageItems：未读分隔线', () {
    List<ChatMessage> three() => <ChatMessage>[
          _msg('1', 'a', time: day2),
          _msg('2', 'b', time: day2.add(const Duration(minutes: 1))),
          _msg('3', 'c', time: day2.add(const Duration(minutes: 2))),
        ];

    test('锚点之后插一条未读项（锚点 = 最后一条已读）', () {
      final items = buildMessageItems(three(), showAvatars: false, unreadAnchorId: '1');
      // 日期 + 消息1 + 未读 + 消息2 + 消息3
      expect(items.map((e) => e.isUnread ? 'U' : (e.isDay ? 'D' : 'm')).join(),
          'DmUmm');
    });

    test('锚点就是最后一条 → 没有未读（后面没东西，别凭空画一条）', () {
      final items = buildMessageItems(three(), showAvatars: false, unreadAnchorId: '3');
      expect(items.any((e) => e.isUnread), isFalse);
    });

    test('锚点不在这一页里 → 不画（位置不明时宁可没有）', () {
      final items = buildMessageItems(three(), showAvatars: false, unreadAnchorId: 'nope');
      expect(items.any((e) => e.isUnread), isFalse);
      final none = buildMessageItems(three(), showAvatars: false);
      expect(none.any((e) => e.isUnread), isFalse);
    });

    test('分隔线切断分组：跨线不共享头像与名字', () {
      // 三条同人同分钟：不带锚点时是同组；带锚点后必须断开
      final msgs = <ChatMessage>[
        _msg('1', 'a', time: day2),
        _msg('2', 'b', time: day2.add(const Duration(seconds: 10))),
        _msg('3', 'c', time: day2.add(const Duration(seconds: 20))),
      ];
      final grouped = buildMessageItems(msgs, showAvatars: true);
      final gMsgs = grouped.where((e) => e.message != null).toList();
      expect(gMsgs[0].showAvatar, isFalse, reason: '同组时头像只在最后一条上');
      expect(gMsgs[2].showAvatar, isTrue);

      final split = buildMessageItems(msgs, showAvatars: true, unreadAnchorId: '1');
      final sMsgs = split.where((e) => e.message != null).toList();
      expect(sMsgs[0].showAvatar, isTrue, reason: '分隔线把第 1、2 条切开，第 1 条自成一组');
      expect(sMsgs[1].showSenderName, isTrue, reason: '跨线要重新显示发送者名');
    });

    testWidgets('未读分隔线能画出来（文案 + 下箭头）', (tester) async {
      await tester.pumpWidget(_wrap(const UnreadDivider()));
      await tester.pumpAndSettle();
      expect(find.text('未读消息'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    });
  });

  group('JumpToLatestButton：跳到最新', () {
    testWidgets('没有未读时只有箭头，没有徽章', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(child: JumpToLatestButton(unread: 0, onTap: () {})),
        ),
      ));
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('有未读时挂出条数，点击回调一次', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(child: JumpToLatestButton(unread: 7, onTap: () => taps++)),
        ),
      ));
      expect(find.text('7'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });
  });

  group('多元素渲染：语音 / 视频 / 文件 / 卡片 / 认不出', () {
    testWidgets('语音：显示时长与体积（不假装能播）', (tester) async {
      final msg = _msg('voice1', '[语音]', time: day2, segments: <Segment>[
        const RecordSegment('abc', seconds: 12, size: 8192),
      ]);
      await tester.pumpWidget(_wrap(_row(singleOf(msg))));
      await tester.pumpAndSettle();

      expect(find.text('语音'), findsOneWidget);
      expect(find.textContaining('12″'), findsOneWidget);
      expect(find.textContaining('8.0 KB'), findsOneWidget);
      expect(find.byIcon(Icons.mic_none), findsOneWidget);
    });

    testWidgets('视频：文件名 + 时长', (tester) async {
      final msg = _msg('video1', '[视频]', time: day2, segments: <Segment>[
        const VideoSegment('fid', name: 'funny.mp4', seconds: 15, size: 1048576),
      ]);
      await tester.pumpWidget(_wrap(_row(singleOf(msg))));
      await tester.pumpAndSettle();

      expect(find.text('funny.mp4'), findsOneWidget);
      expect(find.textContaining('15″'), findsOneWidget);
      expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
    });

    testWidgets('文件：名字 + 体积', (tester) async {
      final msg = _msg('file1', '[文件]', time: day2, segments: <Segment>[
        const FileSegment('fid', name: '报告.pdf', size: 2048),
      ]);
      await tester.pumpWidget(_wrap(_row(singleOf(msg))));
      await tester.pumpAndSettle();

      expect(find.text('报告.pdf'), findsOneWidget);
      expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);
    });

    testWidgets('卡片：有摘要显示摘要，没有就显示"卡片消息"', (tester) async {
      final withSummary = _msg('card1', '[卡片]', time: day2,
          segments: <Segment>[const XmlSegment('<msg/>', summary: '一篇文章')]);
      await tester.pumpWidget(_wrap(_row(singleOf(withSummary))));
      await tester.pumpAndSettle();
      expect(find.text('一篇文章'), findsOneWidget);

      final noSummary = _msg('card2', '[卡片消息]', time: day2,
          segments: <Segment>[const XmlSegment('<msg/>')]);
      await tester.pumpWidget(_wrap(_row(singleOf(noSummary))));
      await tester.pumpAndSettle();
      expect(find.text('卡片消息'), findsOneWidget);
    });

    testWidgets('认不出的段：显示官方那句"不支持显示的消息"，绝不空气泡', (tester) async {
      // 适配器把认不出的元素翻成 UnknownSegment('不支持显示的消息', {...})，
      // 这里按 UI 的契约直接构造同样的段
      final msg = _msg('unk1', '[不支持显示的消息]', time: day2, segments: <Segment>[
        const UnknownSegment('不支持显示的消息', <String, dynamic>{}),
      ]);
      await tester.pumpWidget(_wrap(_row(singleOf(msg))));
      await tester.pumpAndSettle();

      expect(find.textContaining('[不支持显示的消息]'), findsOneWidget);
    });

    testWidgets('收到的消息带引用：引用条显示原文（回复别人的消息）', (tester) async {
      final msg = _msg('reply1', '这句是回复', time: day2,
          replyPreview: '被引用的原话', segments: <Segment>[
            const TextSegment('这句是回复'),
          ]);
      await tester.pumpWidget(_wrap(_row(singleOf(msg))));
      await tester.pumpAndSettle();

      expect(find.text('被引用的原话'), findsOneWidget);
      expect(find.text('这句是回复'), findsOneWidget);
    });
  });

  group('金样：一整段对话长什么样', () {
    // 金样按本机字体渲染，跨平台有差异，所以只在 Windows 上跑（CI 是 Linux）。
    final goldenSkip = !Platform.isWindows;

    final items = buildMessageItems(<ChatMessage>[
      _msg('1', '昨天聊的那件事', time: day1),
      _msg('2', '今天接着说', time: day2),
      _msg('3', '同一个人继续说', time: day2.add(const Duration(minutes: 1))),
      _msg('4', '这条被撤回了', time: day2.add(const Duration(minutes: 2)),
          recalled: true),
      _msg('5', '我看过了', time: day2.add(const Duration(minutes: 3)),
          recalled: true, revealed: true),
      _msg('6', '这条引用了上面', time: day2.add(const Duration(minutes: 4)),
          replyPreview: '同一个人继续说', replyToId: '3'),
      _msg('7', '@你 一下', time: day2.add(const Duration(minutes: 5)), atMe: true),
      _msg('8', '我发出去的', time: day2.add(const Duration(minutes: 6)),
          outgoing: true, senderId: '10001', senderName: '我'),
      _msg('9', '这条没发出去', time: day2.add(const Duration(minutes: 7)),
          outgoing: true, senderId: '10001', senderName: '我',
          sendState: MessageSendState.failed),
      // 10/11 专门盯"自己气泡上的次要元素"：引用条与「查看」在亮色下是黑字压浅绿，
      // 暗色下是白字压紫色——用错颜色就是看不见（曾经就是写死的白色）。
      _msg('10', '我引用了上面这条', time: day2.add(const Duration(minutes: 8)),
          outgoing: true, senderId: '10001', senderName: '我',
          replyPreview: '今天接着说', replyToId: '2'),
      _msg('11', '我撤回的也留着', time: day2.add(const Duration(minutes: 9)),
          outgoing: true, senderId: '10001', senderName: '我',
          recalled: true, revealed: true),
      // 12/13/14：多元素——图片、表情、@（都要能在气泡里看出来）
      _msg('12', '[图片]', time: day2.add(const Duration(minutes: 10)),
          segments: <Segment>[
            const TextSegment('看这张 '),
            const ImageSegment(
              '00112233445566778899aabbccddeeff4096-320-240.jpg',
              summary: '[图片]',
              width: 320,
              height: 240,
            ),
          ]),
      _msg('13', '[表情]', time: day2.add(const Duration(minutes: 11)),
          segments: <Segment>[
            const TextSegment('笑一个'),
            const FaceSegment('14'),
            const TextSegment('吧'),
          ]),
      _msg('14', '@我 看一下', time: day2.add(const Duration(minutes: 12)),
          atMe: true, segments: <Segment>[
            const AtSegment('10001', name: '我'),
            const TextSegment(' 看一下这张'),
            const ImageSegment(
              'ffeeddccbbaa99887766554433221100512-160-120.png',
              summary: '[图片]',
              width: 160,
              height: 120,
            ),
          ]),
      // 15~18：补齐的消息类型（语音/文件/卡片/认不出），都能看出是什么而不是空气泡
      _msg('15', '[语音]', time: day2.add(const Duration(minutes: 13)),
          segments: <Segment>[
            const RecordSegment('abc', seconds: 12, size: 8192),
          ]),
      _msg('16', '[文件]', time: day2.add(const Duration(minutes: 14)),
          segments: <Segment>[
            const FileSegment('fid', name: '季度报告.pdf', size: 204800),
          ]),
      _msg('17', '[卡片] 一篇文章', time: day2.add(const Duration(minutes: 15)),
          segments: <Segment>[
            const XmlSegment('<msg brief="一篇文章"/>', summary: '一篇文章'),
          ]),
      _msg('18', '[不支持显示的消息', time: day2.add(const Duration(minutes: 16)),
          segments: <Segment>[
            const UnknownSegment('不支持显示的消息', <String, dynamic>{}),
          ]),
    ], showAvatars: true, unreadAnchorId: '3');
    // 锚点 3：未读线落在第 3、4 条之间（同一人连续发言被切开，顺便看分组怎么断开）

    Future<void> pumpChatPane(WidgetTester tester, {required bool dark}) async {
      // 调色板是全局单例：这里显式设成要画的那套，跑完还原成暗色。
      TelegramColors.use(dark ? TelegramPalette.dark : TelegramPalette.light);
      addTearDown(() => TelegramColors.use(TelegramPalette.dark));

      // 默认 800×600 会把后面的消息裁掉，金样就不完整了；给一个手机宽、
      // 足够高的画布，让整段对话（含图片/表情块）一次看全。
      tester.view.physicalSize = const Size(420, 2100);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: buildTelegramTheme(dark: dark),
        home: Scaffold(
          backgroundColor: TelegramColors.bgChat,
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              for (final item in items)
                item.isDay
                    // 固定基准时间：金样不能随"今天是几号"变（跨零点就红）。
                    ? DateChip(day: item.day!, now: DateTime(2026, 9, 12, 15))
                    : item.isUnread
                        ? const UnreadDivider()
                        : _row(item, onReveal: () {}, onRetry: () {}),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('现代 TG 形态（日期胶囊 / 分组 / 引用 / @我 / 失败 / 反撤回）',
        (tester) async {
      await pumpChatPane(tester, dark: true);
      await expectLater(
        find.byType(ListView).first,
        matchesGoldenFile('goldens/chat_pane.png'),
      );
    }, skip: goldenSkip);

    testWidgets('亮色：同一段对话（白底 / 绿气泡 / 蓝色我方）', (tester) async {
      await pumpChatPane(tester, dark: false);
      await expectLater(
        find.byType(ListView).first,
        matchesGoldenFile('goldens/chat_pane_light.png'),
      );
    }, skip: goldenSkip);
  });

  group('MessageActionsSheet：长按菜单', () {
    testWidgets('收到的普通消息：只有 复制 / 取消（没有撤回、没有查看原文）', (tester) async {
      var copied = 0;
      await tester.pumpWidget(MaterialApp(
        theme: buildTelegramTheme(),
        home: Scaffold(
          body: MessageActionsSheet(
            message: _msg('1', '别人发的', time: day2),
            onCopy: () => copied++,
            onRecall: () {},
            onReveal: () {},
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('action-copy')), findsOneWidget);
      expect(find.byKey(const ValueKey('action-cancel')), findsOneWidget);
      expect(find.byKey(const ValueKey('action-recall')), findsNothing);
      expect(find.byKey(const ValueKey('action-reveal')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('action-copy')));
      await tester.pump();
      expect(copied, 1);
    });

    testWidgets('自己发的 + 后端支持：出现 撤回', (tester) async {
      var recalled = 0;
      await tester.pumpWidget(MaterialApp(
        theme: buildTelegramTheme(),
        home: Scaffold(
          body: MessageActionsSheet(
            message: _msg('1', '我发的', time: day2, outgoing: true),
            canRecall: true,
            onCopy: () {},
            onRecall: () => recalled++,
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('action-recall')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('action-recall')));
      await tester.pump();
      expect(recalled, 1);
    });

    testWidgets('已撤回未揭示：出现 查看原文；揭示后消失', (tester) async {
      var revealed = 0;
      await tester.pumpWidget(MaterialApp(
        theme: buildTelegramTheme(),
        home: Scaffold(
          body: MessageActionsSheet(
            message: _msg('1', '原文', time: day2, recalled: true),
            onCopy: () {},
            onReveal: () => revealed++,
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('action-reveal')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('action-reveal')));
      await tester.pump();
      expect(revealed, 1);

      await tester.pumpWidget(MaterialApp(
        theme: buildTelegramTheme(),
        home: Scaffold(
          body: MessageActionsSheet(
            message: _msg('1', '原文', time: day2, recalled: true, revealed: true),
            onCopy: () {},
            onReveal: () {},
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('action-reveal')), findsNothing);
    });

    testWidgets('预览显示消息文本（空文本回落占位文案）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTelegramTheme(),
        home: Scaffold(
          body: MessageActionsSheet(
            message: _msg('1', '预览这句', time: day2),
            onCopy: () {},
          ),
        ),
      ));
      expect(find.text('预览这句'), findsOneWidget);
    });
  });

  group('引用回复：菜单入口', () {
    testWidgets('别人发的消息也能"回复"', (tester) async {
      var replied = 0;
      await tester.pumpWidget(MaterialApp(
        theme: buildTelegramTheme(),
        home: Scaffold(
          body: MessageActionsSheet(
            message: _msg('1', '别人的话', time: day2),
            onCopy: () {},
            onReply: () => replied++,
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('action-reply')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('action-reply')));
      await tester.pumpAndSettle();
      expect(replied, 1);
    });

    testWidgets('自己发的消息也能"回复"', (tester) async {
      var replied = 0;
      await tester.pumpWidget(MaterialApp(
        theme: buildTelegramTheme(),
        home: Scaffold(
          body: MessageActionsSheet(
            message: _msg('2', '我的话', time: day2, outgoing: true),
            onCopy: () {},
            onReply: () => replied++,
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey('action-reply')));
      await tester.pumpAndSettle();
      expect(replied, 1);
    });
  });

  group('GroupMembersPanel：群成员面板', () {
    testWidgets('加载中显示 loading，加载完显示成员与身份', (tester) async {
      final completer = Completer<List<Qq8GroupMember>>();
      await tester.pumpWidget(MaterialApp(
        theme: buildTelegramTheme(),
        home: Scaffold(
          body: GroupMembersPanel(
            title: '测试群',
            ownerUin: 20001,
            loader: () => completer.future,
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('members-title')), findsOneWidget);
      expect(find.text('加载中…'), findsOneWidget);

      completer.complete(<Qq8GroupMember>[
        Qq8GroupMember(uin: 20001, nick: '群主大人', card: '老板', gender: 0, age: 0, level: 1, title: '', titleExpireTime: 0, joinTime: 0, lastSpeakTime: 0, shutupUntil: 0, admin: false),
        Qq8GroupMember(uin: 20002, nick: '小明', card: '小明的名片', gender: 0, age: 0, level: 1, title: '摸鱼王', titleExpireTime: 0, joinTime: 0, lastSpeakTime: 0, shutupUntil: 0, admin: true),
        Qq8GroupMember(uin: 20003, nick: '路人', card: '', gender: -1, age: 0, level: 1, title: '', titleExpireTime: 0, joinTime: 0, lastSpeakTime: 0, shutupUntil: 0, admin: false),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('3 位成员'), findsOneWidget);
      expect(find.byKey(const ValueKey('member-20001')), findsOneWidget);
      expect(find.text('群主'), findsOneWidget);
      expect(find.text('管理员'), findsOneWidget);
    });

    testWidgets('显示名优先群名片；没名片用昵称', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTelegramTheme(),
        home: Scaffold(
          body: GroupMembersPanel(
            title: '测试群',
            loader: () async => <Qq8GroupMember>[Qq8GroupMember(uin: 20002, nick: '小明', card: '小明的名片', gender: 0, age: 0, level: 1, title: '摸鱼王', titleExpireTime: 0, joinTime: 0, lastSpeakTime: 0, shutupUntil: 0, admin: true), Qq8GroupMember(uin: 20003, nick: '路人', card: '', gender: -1, age: 0, level: 1, title: '', titleExpireTime: 0, joinTime: 0, lastSpeakTime: 0, shutupUntil: 0, admin: false)],
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('小明的名片'), findsOneWidget);
      expect(find.text('路人'), findsOneWidget);
    });

    testWidgets('加载失败：把原因显示出来（不假装成功）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTelegramTheme(),
        home: Scaffold(
          body: GroupMembersPanel(
            title: '测试群',
            loader: () async => throw const SessionException('当前后端没有成员列表能力'),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('members-error')), findsOneWidget);
      expect(find.textContaining('没有成员列表能力'), findsOneWidget);
    });

    testWidgets('空列表显示"没有成员数据"', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTelegramTheme(),
        home: Scaffold(
          body: GroupMembersPanel(
            title: '测试群',
            loader: () async => <Qq8GroupMember>[],
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('没有成员数据'), findsOneWidget);
    });
  });

  group('StorageDialog：存储与缓存对话框', () {
    testWidgets('按类别显示用量（消息库 vs 媒体缓存）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTelegramTheme(),
        home: Scaffold(
          body: StorageDialog(
            stats: const StorageStats(
              dbBytes: 3 * 1024 * 1024,
              cacheBytes: 800 * 1024 * 1024,
              cacheByCategory: <String, int>{'photos': 500 * 1024 * 1024, 'videos': 300 * 1024 * 1024},
              messageCount: 42,
              chatCount: 7,
            ),
            limitsNote: '媒体缓存上限 512.0 MB · 保留 30 天',
          ),
        ),
      ));
      expect(find.text('存储与缓存'), findsOneWidget);
      expect(find.text('3.0 MB'), findsOneWidget);
      expect(find.text('800.0 MB'), findsOneWidget);
      expect(find.text('7 个会话 · 内存里 42 条消息'), findsOneWidget);
      expect(find.text('图片 500.0 MB'), findsOneWidget);
      expect(find.text('视频 300.0 MB'), findsOneWidget);
      expect(find.textContaining('聊天记录不会被自动清理'), findsOneWidget);
    });

    testWidgets('两个清理入口各自触发回调', (tester) async {
      var clearedCache = 0;
      var clearedHistory = 0;
      await tester.pumpWidget(MaterialApp(
        theme: buildTelegramTheme(),
        home: Scaffold(
          body: StorageDialog(
            stats: const StorageStats(dbBytes: 1, cacheBytes: 2),
            onClearCache: () => clearedCache++,
            onClearHistory: () => clearedHistory++,
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey('storage-clear-cache')));
      await tester.pumpAndSettle();
      expect(clearedCache, 1);
      expect(clearedHistory, 0);
    });

    testWidgets('没有 store 时（回调为 null）按钮禁用而不是崩', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTelegramTheme(),
        home: const Scaffold(
          body: StorageDialog(stats: StorageStats(dbBytes: 0, cacheBytes: 0)),
        ),
      ));
      final cacheBtn = tester.widget<TextButton>(
          find.byKey(const ValueKey('storage-clear-cache')));
      final historyBtn = tester.widget<TextButton>(
          find.byKey(const ValueKey('storage-clear-history')));
      expect(cacheBtn.onPressed, isNull);
      expect(historyBtn.onPressed, isNull);
    });
  });
}
