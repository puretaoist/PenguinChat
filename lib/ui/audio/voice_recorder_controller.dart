/// 录音状态机（UI 层，因为要 ChangeNotifier + 被 widget 直接消费）。
///
/// 只做"按住说话"这一层：权限 → 开录 → 收进度 → 停止/取消。
/// 编码（PCM→SILK）和发送都不在这里，见 [SilkVoiceEncoder] 与 HomePage 的上行回调。
///
/// 状态迁移只有一条主线：
///   idle --start--> requesting --(授权)--> recording --finish--> idle
///                                     \--cancel--> idle
/// 任何一步失败都回到 idle 并写 [lastError]，绝不半死状态。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/audio_bridge.dart';

/// 录音平台抽象：让 widget 测试能塞假实现，不碰 MethodChannel。
abstract class RecorderPlatform {
  Future<bool> ensurePermission();
  Future<void> start({int sampleRate = 16000});
  Future<RecordedPcm?> stop();
  Future<void> cancel();
  Stream<RecordProgress> get progress;
}

/// 用真实原生通道的实现。
class AudioBridgeRecorder implements RecorderPlatform {
  AudioBridgeRecorder([AudioBridge? bridge]) : _bridge = bridge ?? AudioBridge();

  final AudioBridge _bridge;

  @override
  Future<bool> ensurePermission() => _bridge.ensureRecordPermission();

  @override
  Future<void> start({int sampleRate = 16000}) async {
    await _bridge.ensure();
    await _bridge.recordStart(sampleRate: sampleRate);
  }

  @override
  Future<RecordedPcm?> stop() => _bridge.recordStop();

  @override
  Future<void> cancel() => _bridge.recordCancel();

  @override
  Stream<RecordProgress> get progress => _bridge.recordProgress;
}

/// 录音阶段。
enum VoiceRecordPhase { idle, requesting, recording }

class VoiceRecorderController extends ChangeNotifier {
  VoiceRecorderController({
    RecorderPlatform? recorder,
    this.minDurationMs = 700,
    this.sampleRate = 16000,
  }) : _platform = recorder;

  RecorderPlatform? _platform;

  /// 短于这个时长视为"手滑"，不发送（TG: DEFAULT_MINIMUM_DURATION_MS = 700）。
  final int minDurationMs;

  final int sampleRate;

  VoiceRecordPhase _phase = VoiceRecordPhase.idle;
  int _elapsedMs = 0;
  double _amplitude = 0;
  final List<double> _waveform = <double>[];
  String? _lastError;
  StreamSubscription<RecordProgress>? _sub;

  VoiceRecordPhase get phase => _phase;
  bool get isRecording => _phase == VoiceRecordPhase.recording;
  int get elapsedMs => _elapsedMs;
  double get amplitude => _amplitude;

  /// 实时波形（每 ~100ms 一个柱，0..1），用于画录制的振幅条。
  List<double> get waveform => List<double>.unmodifiable(_waveform);
  String? get lastError => _lastError;

  /// 换成别的平台实现（测试用）。
  void configure(RecorderPlatform platform) {
    _platform = platform;
  }

  /// 开始录音。返回 false 表示没开始（无权限/平台不可用/已在录）。
  Future<bool> start() async {
    if (_phase != VoiceRecordPhase.idle) return false;
    final platform = _platform;
    if (platform == null) {
      _lastError = '录音组件未就绪';
      notifyListeners();
      return false;
    }
    _lastError = null;
    _elapsedMs = 0;
    _amplitude = 0;
    _waveform.clear();
    _setPhase(VoiceRecordPhase.requesting);
    try {
      final granted = await platform.ensurePermission();
      if (!granted) {
        _lastError = '没有麦克风权限';
        _setPhase(VoiceRecordPhase.idle);
        return false;
      }
    } on UnsupportedError {
      _lastError = '录音组件未就绪';
      _setPhase(VoiceRecordPhase.idle);
      return false;
    } catch (e) {
      _lastError = '无法开始录音';
      _setPhase(VoiceRecordPhase.idle);
      return false;
    }
    try {
      unawaited(_sub?.cancel());
      _sub = platform.progress.listen(_onProgress);
      await platform.start(sampleRate: sampleRate);
    } catch (e) {
      _lastError = '无法开始录音';
      _setPhase(VoiceRecordPhase.idle);
      return false;
    }
    _setPhase(VoiceRecordPhase.recording);
    return true;
  }

  /// 结束录音并返回结果；时长不足 [minDurationMs] 时丢弃（取消 + 返回 null）。
  Future<RecordedPcm?> finish() async {
    if (_phase == VoiceRecordPhase.idle) return null;
    final platform = _platform;
    _setPhase(VoiceRecordPhase.idle);
    unawaited(_sub?.cancel());
    _sub = null;
    if (platform == null) return null;
    RecordedPcm? result;
    try {
      result = await platform.stop();
    } catch (e) {
      _lastError = '录音失败';
      notifyListeners();
      return null;
    }
    final duration = result?.durationMs ?? _elapsedMs;
    if (result == null || duration < minDurationMs) {
      if (result != null) {
        // 太短：把原生侧留下的临时文件也撤掉，别在 cacheDir 里堆垃圾。
        try {
          await platform.cancel();
        } catch (_) {
          // 取消失败不影响用户可见结果。
        }
      }
      _lastError = null;
      _waveform.clear();
      _elapsedMs = 0;
      notifyListeners();
      return null;
    }
    notifyListeners();
    return result;
  }

  /// 放弃这次录音（上滑取消 / 页面切走）。
  Future<void> cancel() async {
    if (_phase == VoiceRecordPhase.idle) return;
    final platform = _platform;
    _setPhase(VoiceRecordPhase.idle);
    unawaited(_sub?.cancel());
    _sub = null;
    _elapsedMs = 0;
    _amplitude = 0;
    _waveform.clear();
    try {
      await platform?.cancel();
    } catch (_) {
      // 取消失败不能让 UI 卡在浮层上。
    }
    notifyListeners();
  }

  void _onProgress(RecordProgress p) {
    if (_phase != VoiceRecordPhase.recording) return;
    _elapsedMs = p.durationMs;
    _amplitude = p.amplitude;
    _waveform.add(p.amplitude);
    // 浮层只画最近 40 个柱，避免长录音无限增长。
    if (_waveform.length > 40) _waveform.removeAt(0);
    notifyListeners();
  }

  void _setPhase(VoiceRecordPhase next) {
    if (_phase == next) return;
    _phase = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
