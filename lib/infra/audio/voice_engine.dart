/// 语音播放的**纯接口**层：只有数据类与抽象类，不 import Flutter。
///
/// 具体实现分两处：
///   * `lib/ui/audio/voice_native.dart` —— SILK 解码 + 平台音频通道（要用 Flutter 插件）；
///   * `lib/ui/audio/voice_playback_controller.dart` —— 状态机（ChangeNotifier）。
/// 之所以把抽象放在 infra：控制器与自测都只依赖抽象，不需要真机。
library;

/// 解码结果。
class PreparedVoice {
  /// 裸 PCM16 小端、单声道、[sampleRate] 的文件路径。
  final String pcmPath;
  final int sampleRate;
  final int durationMs;

  /// 从 PCM 算出来的真实波形（0..1）；空表示没算。
  final List<double> waveform;

  const PreparedVoice(
    this.pcmPath, {
    this.sampleRate = 16000,
    this.durationMs = 0,
    this.waveform = const <double>[],
  });
}

class VoiceEngineEvent {
  final int positionMs;
  final bool completed;
  const VoiceEngineEvent(this.positionMs, {this.completed = false});
}

abstract class VoiceEngine {
  Future<void> play(String pcmPath, {int sampleRate = 16000});
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> seek(int positionMs);
  Stream<VoiceEngineEvent> get events;
}

abstract class VoicePreparer {
  /// 把 [localPath]（.slk/.amr/裸 pcm 都可能有）转成可播放 PCM；失败返回 null。
  Future<PreparedVoice?> prepare(String localPath);
}
