// audio_bridge_test.dart —— 用 TestDefaultBinaryMessenger 拦截 penguinchat/audio，
// 断言 Dart 封装发出的 method 名与参数、以及对原生返回值的解析。
//
// 说明：这里不打真机。方法调用走 mock handler 记录 MethodCall；
// 事件流（progress/completed、录音进度）用 handlePlatformMessage 从"平台侧"
// 推消息验证解码。EventChannel 的 'listen' 也需 mock，否则会因无实现而报错。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/ui/platform/audio_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(AudioBridge.methodChannelName);
  const playbackChannel = MethodChannel(
    AudioBridge.playbackEventChannelName,
    StandardMethodCodec(),
  );
  const recordChannel = MethodChannel(
    AudioBridge.recordEventChannelName,
    StandardMethodCodec(),
  );

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];
  Object? Function(MethodCall call)? responder;

  setUp(() {
    calls.clear();
    responder = null;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call);
      return responder?.call(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockMethodCallHandler(playbackChannel, null);
    messenger.setMockMethodCallHandler(recordChannel, null);
  });

  group('方法名与参数', () {
    test('playFile 发送 playPcmFile 并带上 path/sampleRate', () async {
      responder = (call) => <String, Object?>{'durationMs': 4200};
      final bridge = AudioBridge();
      final duration = await bridge.playFile('/data/x.pcm', sampleRate: 8000);
      expect(duration, 4200);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'playPcmFile');
      expect(calls.single.arguments, <String, Object?>{
        'path': '/data/x.pcm',
        'sampleRate': 8000,
      });
    });

    test('playFile 默认 sampleRate=16000', () async {
      responder = (call) => <String, Object?>{'durationMs': 0};
      final bridge = AudioBridge();
      await bridge.playFile('/data/x.pcm');
      expect(calls.single.method, 'playPcmFile');
      expect(calls.single.arguments, <String, Object?>{
        'path': '/data/x.pcm',
        'sampleRate': 16000,
      });
    });

    test('playFile 返回值缺 durationMs 时回退到 0', () async {
      responder = (call) => <String, Object?>{};
      final bridge = AudioBridge();
      expect(await bridge.playFile('/data/x.pcm'), 0);
    });

    test('seek 发送 positionMs 并返回落点', () async {
      responder = (call) => 500;
      final bridge = AudioBridge();
      final pos = await bridge.seek(500);
      expect(pos, 500);
      expect(calls.single.method, 'seek');
      expect(calls.single.arguments, <String, Object?>{'positionMs': 500});
    });

    test('pause/resume/stop/position 的方法名与返回值', () async {
      responder = (call) => 1234;
      final bridge = AudioBridge();
      expect(await bridge.pause(), 1234);
      expect(await bridge.resume(), 1234);
      expect(await bridge.stop(), 1234);
      expect(await bridge.position(), 1234);
      expect(calls.map((c) => c.method).toList(), <String>[
        'pause',
        'resume',
        'stop',
        'position',
      ]);
    });

    test('setSpeed 发送 speed 并解析 bool', () async {
      responder = (call) => true;
      final bridge = AudioBridge();
      expect(await bridge.setSpeed(1.5), isTrue);
      expect(calls.single.method, 'setSpeed');
      expect(calls.single.arguments, <String, Object?>{'speed': 1.5});
    });

    test('setSpeed 平台不支持（原生回 false）时返回 false', () async {
      responder = (call) => false;
      final bridge = AudioBridge();
      expect(await bridge.setSpeed(1.5), isFalse);
    });

    test('recordStart 发送 sampleRate', () async {
      responder = (call) => null;
      final bridge = AudioBridge();
      await bridge.recordStart(sampleRate: 44100);
      expect(calls.single.method, 'recordStart');
      expect(calls.single.arguments, <String, Object?>{'sampleRate': 44100});
    });

    test('recordStop 解析 path/durationMs/size', () async {
      responder = (call) => <String, Object?>{
        'path': '/cache/rec.pcm',
        'durationMs': 2500,
        'size': 80000,
      };
      final bridge = AudioBridge();
      final pcm = await bridge.recordStop();
      expect(pcm, isNotNull);
      expect(pcm!.path, '/cache/rec.pcm');
      expect(pcm.durationMs, 2500);
      expect(pcm.size, 80000);
      expect(calls.single.method, 'recordStop');
    });

    test('recordStop 原生回 null 时返回 null', () async {
      responder = (call) => null;
      final bridge = AudioBridge();
      expect(await bridge.recordStop(), isNull);
    });

    test('recordCancel 发送 recordCancel', () async {
      responder = (call) => null;
      final bridge = AudioBridge();
      await bridge.recordCancel();
      expect(calls.single.method, 'recordCancel');
    });
  });

  group('平台缺失', () {
    test('无原生实现时抛 UnsupportedError', () async {
      messenger.setMockMethodCallHandler(methodChannel, null);
      final bridge = AudioBridge();
      await expectLater(
        bridge.playFile('/x.pcm'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('PlatformException 转 UnsupportedError 并保留通道名/方法/原因', () async {
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        throw PlatformException(code: 'audio_error', message: 'boom');
      });
      final bridge = AudioBridge();
      await expectLater(
        bridge.pause(),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('penguinchat/audio'),
              contains('pause'),
              contains('boom'),
            ),
          ),
        ),
      );
    });
  });

  group('事件流解析', () {
    test('playbackEvents 解析 progress / completed', () async {
      messenger.setMockMethodCallHandler(playbackChannel, (call) async => null);
      final bridge = AudioBridge();
      final events = <PlaybackEvent>[];
      final sub = bridge.playbackEvents.listen(events.add);
      await bridge.ensure();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      const codec = StandardMethodCodec();
      Future<void> push(Map<String, Object?> payload) async {
        await messenger.handlePlatformMessage(
          AudioBridge.playbackEventChannelName,
          codec.encodeSuccessEnvelope(payload),
          (_) {},
        );
      }

      await push(<String, Object?>{'event': 'progress', 'positionMs': 100});
      await push(<String, Object?>{'event': 'completed', 'positionMs': 2000});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events.map((e) => e.event).toList(), <String>[
        'progress',
        'completed',
      ]);
      expect(events.first.positionMs, 100);
      expect(events.first.isProgress, isTrue);
      expect(events.last.positionMs, 2000);
      expect(events.last.isCompleted, isTrue);

      await sub.cancel();
      await bridge.dispose();
    });

    test('recordProgress 解析 durationMs/amplitude 并把振幅 clamp 到 0..1', () async {
      messenger.setMockMethodCallHandler(recordChannel, (call) async => null);
      final bridge = AudioBridge();
      final events = <RecordProgress>[];
      final sub = bridge.recordProgress.listen(events.add);
      await bridge.ensure();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      const codec = StandardMethodCodec();
      Future<void> push(Map<String, Object?> payload) async {
        await messenger.handlePlatformMessage(
          AudioBridge.recordEventChannelName,
          codec.encodeSuccessEnvelope(payload),
          (_) {},
        );
      }

      await push(<String, Object?>{'durationMs': 50, 'amplitude': 0.5});
      await push(<String, Object?>{'durationMs': 100, 'amplitude': 1.8});
      await push(<String, Object?>{'durationMs': 150, 'amplitude': -0.2});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events.map((e) => e.durationMs).toList(), <int>[50, 100, 150]);
      expect(events[0].amplitude, closeTo(0.5, 1e-9));
      expect(events[1].amplitude, 1.0);
      expect(events[2].amplitude, 0.0);

      await sub.cancel();
      await bridge.dispose();
    });
  });
}
