import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/infra/audio/voice_waveform.dart';
import 'package:penguinchat/ui/widgets/voice_bubble.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(
    backgroundColor: Colors.black,
    body: Center(child: child),
  ),
);

void main() {
  testWidgets('时长文案：5 秒显示 5″，75 秒显示 1:15', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VoiceBubble(
          seconds: 5,
          waveform: <double>[0.5, 0.8],
          isOut: false,
        ),
      ),
    );
    expect(find.text('5″'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

    await tester.pumpWidget(
      _wrap(
        const VoiceBubble(seconds: 75, waveform: <double>[0.5], isOut: false),
      ),
    );
    await tester.pump();
    expect(find.text('1:15'), findsOneWidget);
  });

  testWidgets('宽度随时长增长并封顶', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VoiceBubble(seconds: 0, waveform: <double>[0.5], isOut: false),
      ),
    );
    final narrow = tester.getSize(find.byType(VoiceBubble)).width;
    await tester.pumpWidget(
      _wrap(
        const VoiceBubble(seconds: 60, waveform: <double>[0.5], isOut: false),
      ),
    );
    final wide = tester.getSize(find.byType(VoiceBubble)).width;
    expect(narrow, 128);
    expect(wide, 220);
  });

  testWidgets('三态图标：播放 / 暂停 / 下载中', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VoiceBubble(
          seconds: 3,
          waveform: <double>[0.5],
          isOut: true,
          playing: true,
        ),
      ),
    );
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

    await tester.pumpWidget(
      _wrap(
        const VoiceBubble(
          seconds: 3,
          waveform: <double>[0.5],
          isOut: true,
          loading: true,
        ),
      ),
    );
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
  });

  testWidgets('失败态显示提示与重试图标', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VoiceBubble(
          seconds: 8,
          waveform: <double>[0.5],
          isOut: false,
          errorText: '下载失败，点按重试',
        ),
      ),
    );
    expect(find.text('下载失败，点按重试'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
  });

  test('兜底波形确定性：同一个 seed 两次结果一致，且都在 0.25..1', () {
    final a = voiceWaveformFor('voice:abc');
    final b = voiceWaveformFor('voice:abc');
    final c = voiceWaveformFor('voice:def');
    expect(a.length, 30);
    expect(a, b);
    expect(a, isNot(c));
    for (final v in a) {
      expect(v, inInclusiveRange(0.25, 1.0));
    }
  });

  test('从 PCM 抽波形：静音段给下限 0.25，峰值段归一化到 1', () {
    final samples = <int>[
      for (var i = 0; i < 16000; i++)
        i < 8000 ? 0 : (i % 2 == 0 ? 3000 : -3000),
    ];
    final w = voiceWaveformFromPcm(samples, bars: 10);
    expect(w.length, 10);
    expect(w.first, 0.25);
    expect(w.last, closeTo(1.0, 0.001));
  });
}
