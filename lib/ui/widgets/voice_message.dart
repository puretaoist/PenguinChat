/// 一条语音消息：接播放控制器，点一下播/停。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/segment.dart';
import '../audio/voice_playback_controller.dart';
import '../providers/voice_playback_provider.dart';
import 'voice_bubble.dart';

class VoiceMessage extends ConsumerWidget {
  final RecordSegment segment;
  final bool isOut;

  /// 缓存键（与 ChatStore.mediaRefOf 一致）；为 null 时按 file 兜底。
  final String? mediaKey;

  final Future<String?> Function(Segment segment)? ensureMedia;
  final Future<String?> Function(Segment segment)? retryMedia;

  /// 测试用：直接注入控制器，绕开 Riverpod。
  final VoicePlaybackController? controllerOverride;

  const VoiceMessage({
    super.key,
    required this.segment,
    required this.isOut,
    this.mediaKey,
    this.ensureMedia,
    this.retryMedia,
    this.controllerOverride,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ChangeNotifierProvider 的 watch 在 analyzer 眼里是可空的（泛型上界是
    // ChangeNotifier?），provider 里 create 一定返回实例，这里断言非空。
    final controller = controllerOverride ?? ref.watch(voicePlaybackProvider)!;
    // 用 ListenableBuilder 而不是只靠 ref.watch：测试里传 controllerOverride
    // 绕开了 Riverpod，那种情况下没有任何东西会触发重建。
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _bubble(controller),
    );
  }

  Widget _bubble(VoicePlaybackController controller) {
    final key = mediaKey ?? 'voice:${segment.file}';
    final seconds = segment.seconds ?? 0;
    return VoiceBubble(
      seconds: seconds,
      waveform: controller.waveformOf(key),
      isOut: isOut,
      playing: controller.isPlayingKey(key),
      progress: controller.progressOf(key),
      loading: controller.isLoadingKey(key),
      errorText: controller.errorOfKey(key),
      onTap: () => controller.toggle(
        key: key,
        seconds: seconds,
        ensurePath: () async {
          final fn = retryMedia ?? ensureMedia;
          if (fn == null) return null;
          return fn(segment);
        },
      ),
    );
  }
}
