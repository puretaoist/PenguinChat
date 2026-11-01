import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/client_api/segment.dart';
import 'package:penguinchat/infra/audio/voice_engine.dart';
import 'package:penguinchat/ui/audio/voice_playback_controller.dart';
import 'package:penguinchat/ui/widgets/voice_message.dart';

class _FakeEngine implements VoiceEngine {
  final List<String> played = <String>[];
  int pauseCount = 0;
  int resumeCount = 0;
  int stopCount = 0;
  final StreamController<VoiceEngineEvent> _events =
      StreamController<VoiceEngineEvent>.broadcast();

  @override
  Stream<VoiceEngineEvent> get events => _events.stream;

  @override
  Future<void> play(String pcmPath, {int sampleRate = 16000}) async {
    played.add(pcmPath);
  }

  @override
  Future<void> pause() async => pauseCount++;

  @override
  Future<void> resume() async => resumeCount++;

  @override
  Future<void> stop() async => stopCount++;

  @override
  Future<void> seek(int positionMs) async {}
}

class _FakePreparer implements VoicePreparer {
  _FakePreparer({this.fail = false});
  final bool fail;
  int calls = 0;

  @override
  Future<PreparedVoice?> prepare(String localPath) async {
    calls++;
    if (fail) return null;
    return PreparedVoice('/tmp/decoded.pcm',
        durationMs: 4200, waveform: const <double>[0.4, 0.9, 0.3]);
  }
}

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(backgroundColor: Colors.black, body: Center(child: child)),
    );

void main() {
  testWidgets('点一下开始播放：解码 → engine.play，图标变暂停', (tester) async {
    final engine = _FakeEngine();
    final preparer = _FakePreparer();
    final controller =
        VoicePlaybackController(preparer: preparer, engine: engine);
    await tester.pumpWidget(_wrap(VoiceMessage(
      segment: const RecordSegment('abc123', seconds: 4, size: 6400),
      isOut: false,
      mediaKey: 'voice:abc123',
      retryMedia: (_) async => '/tmp/a.slk',
      controllerOverride: controller,
    )));
    await tester.tap(find.byType(VoiceMessage));
    await tester.pumpAndSettle();
    expect(preparer.calls, 1);
    expect(engine.played, <String>['/tmp/decoded.pcm']);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    controller.dispose();
  });

  testWidgets('再点一下暂停，再点继续（不重新解码）', (tester) async {
    final engine = _FakeEngine();
    final preparer = _FakePreparer();
    final controller =
        VoicePlaybackController(preparer: preparer, engine: engine);
    await tester.pumpWidget(_wrap(VoiceMessage(
      segment: const RecordSegment('abc123', seconds: 4),
      isOut: true,
      mediaKey: 'voice:abc123',
      retryMedia: (_) async => '/tmp/a.slk',
      controllerOverride: controller,
    )));
    await tester.tap(find.byType(VoiceMessage));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(VoiceMessage));
    await tester.pumpAndSettle();
    expect(engine.pauseCount, 1);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    controller.dispose();
  });

  testWidgets('取不到本地文件：显示下载失败，点按重试会再走一次', (tester) async {
    final engine = _FakeEngine();
    final preparer = _FakePreparer();
    final controller =
        VoicePlaybackController(preparer: preparer, engine: engine);
    var attempts = 0;
    await tester.pumpWidget(_wrap(VoiceMessage(
      segment: const RecordSegment('abc123', seconds: 4),
      isOut: false,
      mediaKey: 'voice:abc123',
      retryMedia: (_) async {
        attempts++;
        return null;
      },
      controllerOverride: controller,
    )));
    await tester.tap(find.byType(VoiceMessage));
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(find.text('下载失败，点按重试'), findsOneWidget);
    expect(engine.played, isEmpty);

    await tester.tap(find.byType(VoiceMessage));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    controller.dispose();
  });

  testWidgets('解码失败：显示无法解码，不调 engine.play', (tester) async {
    final engine = _FakeEngine();
    final controller = VoicePlaybackController(
        preparer: _FakePreparer(fail: true), engine: engine);
    await tester.pumpWidget(_wrap(VoiceMessage(
      segment: const RecordSegment('abc123', seconds: 4),
      isOut: false,
      mediaKey: 'voice:abc123',
      retryMedia: (_) async => '/tmp/a.slk',
      controllerOverride: controller,
    )));
    await tester.tap(find.byType(VoiceMessage));
    await tester.pumpAndSettle();
    expect(find.text('无法解码这条语音'), findsOneWidget);
    expect(engine.played, isEmpty);
    controller.dispose();
  });
}
