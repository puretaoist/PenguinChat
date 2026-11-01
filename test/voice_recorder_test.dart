import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/ui/audio/voice_recorder_controller.dart';
import 'package:penguinchat/ui/platform/audio_bridge.dart';
import 'package:penguinchat/ui/widgets/voice_record_button.dart';

class _FakeRecorder implements RecorderPlatform {
  _FakeRecorder({this.granted = true});

  bool granted;
  int startCount = 0;
  int cancelCount = 0;
  RecordedPcm? nextResult;
  final StreamController<RecordProgress> _progress =
      StreamController<RecordProgress>.broadcast();

  void push(int ms, double amp) =>
      _progress.add(RecordProgress(durationMs: ms, amplitude: amp));

  @override
  Future<bool> ensurePermission() async => granted;

  @override
  Future<void> start({int sampleRate = 16000}) async {
    startCount++;
  }

  @override
  Future<RecordedPcm?> stop() async => nextResult;

  @override
  Future<void> cancel() async {
    cancelCount++;
  }

  @override
  Stream<RecordProgress> get progress => _progress.stream;
}

void main() {
  test('没有麦克风权限：start 返回 false，写错误文案', () async {
    final fake = _FakeRecorder(granted: false);
    final c = VoiceRecorderController(recorder: fake);
    expect(await c.start(), isFalse);
    expect(c.lastError, '没有麦克风权限');
    expect(c.phase, VoiceRecordPhase.idle);
    expect(fake.startCount, 0);
  });

  test('开始录音后进度推动时长/振幅/波形', () async {
    final fake = _FakeRecorder();
    final c = VoiceRecorderController(recorder: fake);
    expect(await c.start(), isTrue);
    expect(c.phase, VoiceRecordPhase.recording);
    fake.push(100, 0.2);
    fake.push(200, 0.6);
    await Future<void>.delayed(Duration.zero);
    expect(c.elapsedMs, 200);
    expect(c.amplitude, 0.6);
    expect(c.waveform, <double>[0.2, 0.6]);
  });

  test('时长够就返回文件', () async {
    final fake = _FakeRecorder();
    fake.nextResult =
        const RecordedPcm(path: '/tmp/a.pcm', durationMs: 1200, size: 38400);
    final c = VoiceRecorderController(recorder: fake);
    await c.start();
    fake.push(1200, 0.4);
    await Future<void>.delayed(Duration.zero);
    final result = await c.finish();
    expect(result, isNotNull);
    expect(result!.path, '/tmp/a.pcm');
    expect(c.phase, VoiceRecordPhase.idle);
    expect(fake.cancelCount, 0);
  });

  test('太短（<700ms）丢弃并撤掉临时文件', () async {
    final fake = _FakeRecorder();
    fake.nextResult =
        const RecordedPcm(path: '/tmp/a.pcm', durationMs: 400, size: 12800);
    final c = VoiceRecorderController(recorder: fake);
    await c.start();
    expect(await c.finish(), isNull);
    expect(fake.cancelCount, 1);
    expect(c.lastError, isNull);
  });

  test('取消：回到 idle 并叫原生取消', () async {
    final fake = _FakeRecorder();
    final c = VoiceRecorderController(recorder: fake);
    await c.start();
    fake.push(500, 0.3);
    await Future<void>.delayed(Duration.zero);
    await c.cancel();
    expect(c.phase, VoiceRecordPhase.idle);
    expect(c.elapsedMs, 0);
    expect(c.waveform, isEmpty);
    expect(fake.cancelCount, 1);
  });

  testWidgets('按住录音浮层出现，松手把 PCM 交给回调', (tester) async {
    final fake = _FakeRecorder();
    fake.nextResult =
        const RecordedPcm(path: '/tmp/a.pcm', durationMs: 1500, size: 48000);
    final c = VoiceRecorderController(recorder: fake);
    String? path;
    int? ms;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: VoiceRecordButton(
            controller: c,
            onRecorded: (pcm, waveform) async {
              path = pcm.path;
              ms = pcm.durationMs;
            },
          ),
        ),
      ),
    ));

    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(VoiceRecordButton)));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(const ValueKey('voice-record-overlay')), findsOneWidget);
    await gesture.up();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(path, '/tmp/a.pcm');
    expect(ms, 1500);
    expect(find.byKey(const ValueKey('voice-record-overlay')), findsNothing);
  });

  testWidgets('上滑超过阈值松手 = 取消，不回调', (tester) async {
    final fake = _FakeRecorder();
    fake.nextResult =
        const RecordedPcm(path: '/tmp/a.pcm', durationMs: 1500, size: 48000);
    final c = VoiceRecorderController(recorder: fake);
    var called = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: VoiceRecordButton(
            controller: c,
            onRecorded: (pcm, waveform) async => called = true,
          ),
        ),
      ),
    ));
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(VoiceRecordButton)));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(called, isFalse);
    expect(fake.cancelCount, 1);
  });
}
