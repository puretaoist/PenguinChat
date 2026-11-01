/// 真机上的语音解码与播放实现：SILK v3 → PCM16 → Android AudioTrack。
///
/// 这一层把 [VoicePreparer] / [VoiceEngine] 两个接口接到具体实现上，
/// 控制器与 UI 因此完全不用知道 SILK 或平台通道的存在。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../infra/log/logger.dart';
import '../platform/audio_bridge.dart';
import '../../infra/audio/silk_codec.dart';
import '../../infra/audio/silk_file.dart';
import '../../infra/audio/voice_engine.dart';

/// 把下载到本地的语音文件解成裸 PCM16 并算出波形。
class SilkVoicePreparer implements VoicePreparer {
  SilkVoicePreparer([this._codec, this.tmpDir]);

  SilkCodec? _codec;
  final Directory? tmpDir;
  static final Logger _log = Log.get('语音解码');

  SilkCodec _ensureCodec() => _codec ??= SilkCodec();

  @override
  Future<PreparedVoice?> prepare(String localPath) async {
    final file = File(localPath);
    if (!file.existsSync()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;

    if (SilkFile.looksLikeSilk(bytes)) {
      return _prepareSilk(file, bytes);
    }
    if (SilkFile.looksLikeAmr(bytes)) {
      // AMR 需要系统 MediaPlayer 才能播；本层只输出 PCM，先明确失败，
      // 不要假装能播（宁可显示「无法解码这条语音」）。
      _log.w('收到 AMR 语音，本层不支持解码：$localPath');
      return null;
    }
    // 不是 SILK/AMR：当作裸 PCM16 处理（我方录音 V2 的中间产物就是这种）。
    return _prepareRawPcm(file, bytes);
  }

  Future<PreparedVoice?> _prepareSilk(File file, Uint8List bytes) async {
    final SilkFile silk;
    try {
      silk = SilkFile.parse(bytes);
    } on FormatException catch (e) {
      _log.w('SILK 容器解析失败：${e.message}');
      return null;
    }
    if (silk.frames.isEmpty) return null;
    final codec = _ensureCodec();
    final pcm = BytesBuilder(copy: false);
    final peaks = <int>[];
    for (final frame in silk.frames) {
      final Uint8List out;
      try {
        out = codec.decodeFrame(frame);
      } catch (e) {
        _log.w('SILK 解码失败（放弃这条语音）', error: e);
        return null;
      }
      pcm.add(out);
      peaks.add(_peakOf(out));
    }
    final pcmBytes = pcm.takeBytes();
    final outPath = await _pcmPathFor(file);
    await File(outPath).writeAsBytes(pcmBytes, flush: true);
    final durationMs = silk.frames.length * 20;
    return PreparedVoice(
      outPath,
      durationMs: durationMs,
      waveform: _waveformFromPeaks(peaks),
    );
  }

  Future<PreparedVoice?> _prepareRawPcm(File file, Uint8List bytes) async {
    if (bytes.length.isOdd) return null;
    final samples = bytes.length ~/ 2;
    final durationMs = (samples / 16000 * 1000).round();
    final peaks = <int>[];
    final data = ByteData.sublistView(bytes);
    const window = 320; // 20ms
    for (var i = 0; i + 1 < bytes.length; i += window * 2) {
      var peak = 0;
      for (var j = i; j + 1 < bytes.length && j < i + window * 2; j += 2) {
        final v = data.getInt16(j, Endian.little).abs();
        if (v > peak) peak = v;
      }
      peaks.add(peak);
    }
    return PreparedVoice(
      file.path,
      durationMs: durationMs,
      waveform: _waveformFromPeaks(peaks),
    );
  }

  Future<String> _pcmPathFor(File source) async {
    final dir = tmpDir ?? Directory.systemTemp;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final base = source.uri.pathSegments.isEmpty
        ? 'voice'
        : source.uri.pathSegments.last;
    return '${dir.path}${Platform.pathSeparator}$base.pcm';
  }

  static int _peakOf(Uint8List pcm16) {
    final data = ByteData.sublistView(pcm16);
    var peak = 0;
    for (var i = 0; i + 1 < pcm16.length; i += 2) {
      final v = data.getInt16(i, Endian.little).abs();
      if (v > peak) peak = v;
    }
    return peak;
  }

  /// 每 20ms 一个峰值 → 压到 [bars] 根柱子（取窗口内最大值）。
  List<double> _waveformFromPeaks(List<int> peaks, {int bars = 30}) {
    if (peaks.isEmpty) return const <double>[];
    final out = <double>[];
    final chunk = (peaks.length / bars).ceil();
    var maxPeak = 1;
    for (final p in peaks) {
      if (p > maxPeak) maxPeak = p;
    }
    for (var i = 0; i < bars; i++) {
      final start = i * chunk;
      if (start >= peaks.length) break;
      final end = (start + chunk).clamp(0, peaks.length);
      var m = 0;
      for (var j = start; j < end; j++) {
        if (peaks[j] > m) m = peaks[j];
      }
      out.add((0.25 + m / maxPeak * 0.75).clamp(0.25, 1.0));
    }
    return out;
  }
}

/// 把 [AudioBridge] 包成播放引擎。
class BridgeVoiceEngine implements VoiceEngine {
  BridgeVoiceEngine(this._bridge);

  final AudioBridge _bridge;
  final StreamController<VoiceEngineEvent> _events =
      StreamController<VoiceEngineEvent>.broadcast();
  StreamSubscription<PlaybackEvent>? _sub;

  Future<void> init() async {
    await _bridge.ensure();
    _sub = _bridge.playbackEvents.listen((e) {
      if (_events.isClosed) return;
      _events.add(VoiceEngineEvent(e.positionMs, completed: e.isCompleted));
    });
  }

  @override
  Stream<VoiceEngineEvent> get events => _events.stream;

  @override
  Future<void> play(String pcmPath, {int sampleRate = 16000}) async {
    await _bridge.playFile(pcmPath, sampleRate: sampleRate);
  }

  @override
  Future<void> pause() async {
    await _bridge.pause();
  }

  @override
  Future<void> resume() async {
    await _bridge.resume();
  }

  @override
  Future<void> stop() async {
    await _bridge.stop();
  }

  @override
  Future<void> seek(int positionMs) async {
    await _bridge.seek(positionMs);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _bridge.dispose();
    await _events.close();
  }
}
