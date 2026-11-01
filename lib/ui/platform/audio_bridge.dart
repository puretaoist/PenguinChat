/// L1 基础设施：Android 音频平台通道（裸 PCM 播放 + 裸 PCM 录音）。
///
/// ## 这个文件负责什么
///
/// 语音消息的"播放一段 PCM"和"录一段 PCM"都必须落到原生 AudioTrack /
/// AudioRecord，Dart 没有等价能力。本文件把原生通道封装成一个纯 Dart 的
/// [AudioBridge]：不依赖 Flutter widget（只依赖 flutter/services），因此可以
/// 在单元测试里用 TestDefaultBinaryMessenger 直接拦截通道验证协议。
///
/// ## 通道协议（与 AudioBridge.kt 一一对应）
///
/// MethodChannel penguinchat/audio：
///   playPcmFile {path, sampleRate=16000} -> {durationMs:Int}
///   pause / resume / stop                -> Int（当前毫秒）
///   seek {positionMs}                    -> Int（落点毫秒）
///   position                             -> Int（当前毫秒）
///   setSpeed {speed:Double}              -> Bool
///   recordStart {sampleRate=16000}       -> null
///   recordStop                           -> {path, durationMs, size} 或 null
///   recordCancel                         -> null
///
/// EventChannel penguinchat/audio/events：
///   {event:"progress", positionMs:Int} / {event:"completed", positionMs:Int}
///
/// EventChannel penguinchat/audio/record：
///   {durationMs:Int, amplitude:Double(0..1)}
///
/// ## 平台缺失时的行为
///
/// 桌面/测试环境没有原生实现：任何方法调用都会抛 [UnsupportedError]，
/// 消息里带通道名与被调方法，方便定位（而不是让 MissingPluginException
/// 一路冒到 UI 层显示成"未知错误"）。
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// 一次播放事件。[event] 取值 'progress' 或 'completed'；
/// 二者都带当前毫秒 [positionMs]。
class PlaybackEvent {
  const PlaybackEvent({required this.event, required this.positionMs});

  /// 'progress' 或 'completed'。
  final String event;

  /// 事件发生时的播放位置（毫秒）。
  final int positionMs;

  bool get isProgress => event == 'progress';
  bool get isCompleted => event == 'completed';

  @override
  String toString() => 'PlaybackEvent($event, ${positionMs}ms)';
}

/// 一次录音进度事件：已录时长与当前窗口的振幅（PCM 峰值归一化到 0..1）。
class RecordProgress {
  const RecordProgress({required this.durationMs, required this.amplitude});

  /// 已录时长（毫秒）。
  final int durationMs;

  /// 当前窗口振幅，0..1（原生按 PCM 绝对峰值 / 32768 归一）。
  final double amplitude;

  @override
  String toString() => 'RecordProgress(${durationMs}ms, amp=${amplitude.toStringAsFixed(2)})';
}

/// 一段录制完成的裸 PCM 文件。
class RecordedPcm {
  const RecordedPcm({
    required this.path,
    required this.durationMs,
    required this.size,
  });

  /// 临时文件绝对路径（位于应用 cacheDir）。
  final String path;

  /// 时长（毫秒）。
  final int durationMs;

  /// 文件字节数。
  final int size;

  /// 从原生返回的 Map 解析。字段缺失时给保守默认值（不抛异常）。
  factory RecordedPcm.fromMap(Map<Object?, Object?> map) => RecordedPcm(
        path: map['path'] as String? ?? '',
        durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
        size: (map['size'] as num?)?.toInt() ?? 0,
      );

  @override
  String toString() => 'RecordedPcm($path, ${durationMs}ms, $size bytes)';
}

/// Android 音频平台通道的 Dart 封装。
///
/// 典型用法：
///   1. 启动时 await bridge.ensure()（订阅播放/录音事件流）；
///   2. 播放：await playFile(path) -> 监听 playbackEvents 刷新进度条；
///   3. 录音：await recordStart() -> 监听 recordProgress 画波形 -> recordStop()。
class AudioBridge {
  AudioBridge({
    MethodChannel? methodChannel,
    EventChannel? playbackEventChannel,
    EventChannel? recordEventChannel,
  })  : _method = methodChannel ?? const MethodChannel(methodChannelName),
        _playbackChannel =
            playbackEventChannel ?? const EventChannel(playbackEventChannelName),
        _recordChannel =
            recordEventChannel ?? const EventChannel(recordEventChannelName);

  /// 方法通道名。写成常量是为了真机排障时能在 logcat/dumpsys 里搜到。
  static const String methodChannelName = 'penguinchat/audio';

  /// 播放事件通道名。
  static const String playbackEventChannelName = 'penguinchat/audio/events';

  /// 录音事件通道名。
  static const String recordEventChannelName = 'penguinchat/audio/record';

  final MethodChannel _method;
  final EventChannel _playbackChannel;
  final EventChannel _recordChannel;

  final StreamController<PlaybackEvent> _playbackController =
      StreamController<PlaybackEvent>.broadcast();
  final StreamController<RecordProgress> _recordController =
      StreamController<RecordProgress>.broadcast();

  StreamSubscription<dynamic>? _playbackSub;
  StreamSubscription<dynamic>? _recordSub;
  bool _ensured = false;

  /// 播放事件流（progress / completed）。
  Stream<PlaybackEvent> get playbackEvents => _playbackController.stream;

  /// 录音进度流（时长 + 振幅）。
  Stream<RecordProgress> get recordProgress => _recordController.stream;

  /// 初始化：订阅两个 EventChannel。重复调用幂等。
  ///
  /// 平台缺失时不会在这里抛（EventChannel 的 listen 是异步的）；
  /// 错误会通过事件流的 error 通道以 [UnsupportedError] 形式交给监听者。
  Future<void> ensure() async {
    if (_ensured) return;
    _ensured = true;
    _playbackSub = _playbackChannel.receiveBroadcastStream().listen(
          _onPlaybackEvent,
          onError: (Object error) {
            if (!_playbackController.isClosed) {
              _playbackController.addError(_toUnsupported(error, '播放事件流'));
            }
          },
        );
    _recordSub = _recordChannel.receiveBroadcastStream().listen(
          _onRecordEvent,
          onError: (Object error) {
            if (!_recordController.isClosed) {
              _recordController.addError(_toUnsupported(error, '录音事件流'));
            }
          },
        );
  }

  /// 播放一段裸 PCM 文件。返回总时长（毫秒）。
  ///
  /// [sampleRate] 必须与文件内容一致（单声道 PCM16），否则速度会跑偏。
  Future<int> playFile(String path, {int sampleRate = 16000}) async {
    final result = await _invoke<Map<Object?, Object?>>('playPcmFile', <String, Object?>{
      'path': path,
      'sampleRate': sampleRate,
    });
    return (result?['durationMs'] as num?)?.toInt() ?? 0;
  }

  /// 暂停播放，返回当前毫秒。
  Future<int> pause() async => (await _invoke<int>('pause')) ?? 0;

  /// 继续播放，返回当前毫秒。
  Future<int> resume() async => (await _invoke<int>('resume')) ?? 0;

  /// 停止播放，返回停止时的毫秒。
  Future<int> stop() async => (await _invoke<int>('stop')) ?? 0;

  /// 跳转到 [positionMs]（毫秒），返回实际落点毫秒。
  Future<int> seek(int positionMs) async {
    final v = await _invoke<int>('seek', <String, Object?>{'positionMs': positionMs});
    return v ?? 0;
  }

  /// 当前播放位置（毫秒）。
  Future<int> position() async => (await _invoke<int>('position')) ?? 0;

  /// 设置播放速度。API<23 或平台不支持时返回 false。
  Future<bool> setSpeed(double speed) async {
    final v = await _invoke<bool>('setSpeed', <String, Object?>{'speed': speed});
    return v ?? false;
  }

  /// 开始录音（单声道 PCM16），写入 cacheDir 临时文件。
  Future<void> recordStart({int sampleRate = 16000}) async {
    await _invoke<Object?>('recordStart', <String, Object?>{'sampleRate': sampleRate});
  }

  /// 结束录音。没有进行中的录音时返回 null。
  Future<RecordedPcm?> recordStop() async {
    final map = await _invoke<Map<Object?, Object?>>('recordStop');
    if (map == null) return null;
    return RecordedPcm.fromMap(map);
  }

  /// 取消录音并丢弃临时文件。
  Future<void> recordCancel() async {
    await _invoke<Object?>('recordCancel');
  }

  /// 释放事件流订阅与控制器。
  Future<void> dispose() async {
    await _playbackSub?.cancel();
    await _recordSub?.cancel();
    _playbackSub = null;
    _recordSub = null;
    await _playbackController.close();
    await _recordController.close();
    _ensured = false;
  }

  // ── 内部 ────────────────────────────────────────────────────────────────

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _method.invokeMethod<T>(method, args);
    } on MissingPluginException {
      throw UnsupportedError(
        '音频平台通道不可用（$methodChannelName.$method）：当前平台未实现原生音频桥。',
      );
    } on PlatformException catch (e) {
      final detail = e.message == null ? '' : ' ${e.message!}';
      throw UnsupportedError(
        '音频平台通道调用失败（$methodChannelName.$method）：${e.code}$detail。',
      );
    }
  }

  void _onPlaybackEvent(dynamic data) {
    if (data is! Map) return;
    final event = data['event'];
    if (event is! String) return;
    if (_playbackController.isClosed) return;
    _playbackController.add(PlaybackEvent(
      event: event,
      positionMs: (data['positionMs'] as num?)?.toInt() ?? 0,
    ));
  }

  void _onRecordEvent(dynamic data) {
    if (data is! Map) return;
    if (_recordController.isClosed) return;
    final rawAmplitude = (data['amplitude'] as num?)?.toDouble() ?? 0.0;
    _recordController.add(RecordProgress(
      durationMs: (data['durationMs'] as num?)?.toInt() ?? 0,
      amplitude: rawAmplitude.clamp(0.0, 1.0).toDouble(),
    ));
  }

  UnsupportedError _toUnsupported(Object error, String where) {
    if (error is MissingPluginException) {
      return UnsupportedError('音频平台通道不可用（$where）：当前平台未实现原生音频桥。');
    }
    if (error is PlatformException) {
      final detail = error.message == null ? '' : ' ${error.message!}';
      return UnsupportedError(
        '音频平台通道出错（$where）：${error.code}$detail。',
      );
    }
    return UnsupportedError('音频平台通道出错（$where）：$error。');
  }
}
