import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/client_api/objects.dart';
import 'package:qqclient/client_api/segment.dart';
import 'package:qqclient/ui/widgets/message_content.dart';

// 缺陷3（图片首屏只显示文件名占位卡，重启才出图）的回归测试：
// 图片块在首帧拿不到本地文件时应当自己补一次 ensureMedia，成功后换成真图；
// 没有 ensureMedia 钩子时保持旧行为（只占位，不发请求）。
void main() {
  late Directory tmp;
  late String pngPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('msgcontent_test');
    pngPath = '${tmp.path}/pic.png';
    File(pngPath).writeAsBytesSync(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='));
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  ChatMessage imageMessage() => ChatMessage(
        id: 'm1',
        chatId: 'group:1',
        text: '[图片]',
        segments: <Segment>[
          ImageSegment('aabbccdd1080-1080-2337.jpg', width: 1080, height: 2337),
        ],
        time: DateTime(2026, 10, 31, 8),
        senderName: '小明',
        senderId: '10001',
      );

  testWidgets('首帧没本地文件时补一次下载，成功后显示真图（缺陷3）', (tester) async {
    var downloaded = false;
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageContent(
          message: imageMessage(),
          isOut: false,
          localMedia: (s) => downloaded ? pngPath : null,
          ensureMedia: (s) async {
            calls++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            downloaded = true;
            return pngPath;
          },
        ),
      ),
    ));

    // 首帧：占位（带文件名与尺寸，便于排查）
    expect(find.textContaining('aabbccdd1080-1080-2337.jpg'), findsOneWidget);
    expect(find.byType(Image), findsNothing);

    await tester.pump(); // 帧后回调：发起补下载
    await tester.pump(const Duration(milliseconds: 40)); // 下载完成
    await tester.pumpAndSettle();

    expect(calls, 1, reason: '同一条媒体只补一次');
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('aabbccdd1080-1080-2337.jpg'), findsNothing);
  });

  testWidgets('没有 ensureMedia 钩子时不补下载、不崩（旧行为）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageContent(
          message: imageMessage(),
          isOut: false,
          localMedia: (s) => null,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('aabbccdd1080-1080-2337.jpg'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('本地文件已存在时不起请求，直接显示', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageContent(
          message: imageMessage(),
          isOut: false,
          localMedia: (s) => pngPath,
          ensureMedia: (s) async {
            calls++;
            return pngPath;
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.byType(Image), findsOneWidget);
  });
}