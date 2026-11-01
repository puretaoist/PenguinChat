/// 语音播放控制器的 Riverpod 接线（L4，可以 import Flutter）。
///
/// 引擎与解码器在 [AppBootstrap] 里通过 configure() 注入（真机才有平台通道）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/voice_playback_controller.dart';

/// 注意：不要再 ref.onDispose(controller.dispose) ——
/// ChangeNotifierProvider 自己会在销毁时 dispose 这个 notifier，再挂一次
/// 会 double dispose，测试里直接抛
/// A VoicePlaybackController was used after being disposed。
final voicePlaybackProvider =
    ChangeNotifierProvider<VoicePlaybackController>((ref) {
  return VoicePlaybackController();
});
