/// 语音播放状态机（UI 层）：下载 → 解码 → 平台播放，状态喂给气泡。
///
/// 放在 lib/ui 而不是 lib/infra：它继承 ChangeNotifier（Flutter），
/// 而 infra 层有「不得 import Flutter」的分层门禁（tool/layering_selftest.dart 第 4 条）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../infra/audio/voice_engine.dart';
import '../../infra/audio/voice_waveform.dart';

class VoicePlaybackController extends ChangeNotifier {
  VoicePlaybackController({VoicePreparer? preparer, VoiceEngine? engine}) {
    _preparer = preparer;
    _engine = engine;
  }

  VoicePreparer? _preparer;
  VoiceEngine? _engine;
  StreamSubscription<VoiceEngineEvent>? _sub;

  void configure({VoicePreparer? preparer, VoiceEngine? engine}) {
    _preparer = preparer ?? _preparer;
    _engine = engine ?? _engine;
    _resubscribe();
  }

  String? _currentKey;
  bool _playing = false;
  bool _loading = false;
  String? _error;
  int _positionMs = 0;
  int _durationMs = 0;
  final Map<String, List<double>> _waveforms = {};

  String? get currentKey => _currentKey;
  bool get playing => _playing;
  bool get loading => _loading;
  String? get error => _error;
  int get positionMs => _positionMs;
  int get durationMs => _durationMs;

  bool isPlayingKey(String key) => _currentKey == key && _playing;
  bool isLoadingKey(String key) => _currentKey == key && _loading;
  String? errorOfKey(String key) => _currentKey == key ? _error : null;

  List<double> waveformOf(String key) =>
      _waveforms[key] ?? voiceWaveformFor(key);

  double progressOf(String key) {
    if (_currentKey != key || _durationMs <= 0) return 0;
    return (_positionMs / _durationMs).clamp(0.0, 1.0);
  }

  void _resubscribe() {
    _sub?.cancel();
    _sub = _engine?.events.listen(_onEngineEvent);
  }

  void _onEngineEvent(VoiceEngineEvent ev) {
    if (_currentKey == null) return;
    if (ev.completed) {
      _playing = false;
      _positionMs = _durationMs;
    } else {
      _positionMs = ev.positionMs;
    }
    notifyListeners();
  }

  /// 点一下：同一个语音 播放/暂停 切换；换一条就切过去从头播。
  Future<void> toggle({
    required String key,
    required int seconds,
    required Future<String?> Function() ensurePath,
  }) async {
    final engine = _engine;
    if (engine == null) {
      _currentKey = key;
      _playing = false;
      _error = '音频组件未就绪';
      notifyListeners();
      return;
    }
    if (_currentKey == key) {
      if (_loading) return;
      if (_error != null) {
        await _start(key: key, seconds: seconds, ensurePath: ensurePath);
        return;
      }
      if (_playing) {
        await engine.pause();
        _playing = false;
        notifyListeners();
        return;
      }
      if (_positionMs > 0 && _positionMs < _durationMs) {
        await engine.resume();
        _playing = true;
        notifyListeners();
        return;
      }
      await _start(key: key, seconds: seconds, ensurePath: ensurePath);
      return;
    }
    await _start(key: key, seconds: seconds, ensurePath: ensurePath);
  }

  Future<void> _start({
    required String key,
    required int seconds,
    required Future<String?> Function() ensurePath,
  }) async {
    final engine = _engine!;
    await engine.stop();
    _currentKey = key;
    _playing = false;
    _loading = true;
    _error = null;
    _positionMs = 0;
    _durationMs = seconds > 0 ? seconds * 1000 : 0;
    notifyListeners();
    try {
      final local = await ensurePath();
      if (local == null || local.isEmpty) {
        _loading = false;
        _error = '下载失败，点按重试';
        notifyListeners();
        return;
      }
      final preparer = _preparer;
      if (preparer == null) {
        _loading = false;
        _error = '音频组件未就绪';
        notifyListeners();
        return;
      }
      final prepared = await preparer.prepare(local);
      if (prepared == null) {
        _loading = false;
        _error = '无法解码这条语音';
        notifyListeners();
        return;
      }
      if (prepared.waveform.isNotEmpty) {
        _waveforms[key] = prepared.waveform;
      }
      await engine.play(prepared.pcmPath, sampleRate: prepared.sampleRate);
      if (prepared.durationMs > 0) _durationMs = prepared.durationMs;
      _loading = false;
      _playing = true;
      notifyListeners();
    } catch (e) {
      _loading = false;
      _playing = false;
      _error = '播放失败';
      notifyListeners();
    }
  }

  Future<void> stop() async {
    await _engine?.stop();
    _playing = false;
    _positionMs = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _engine?.stop();
    super.dispose();
  }
}
