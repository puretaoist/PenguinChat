/// Telegram 风格的语音气泡内容：圆形播放键 + 波形条 + 时长。
///
/// 刻意只做「展示」：谁在播、播到哪、能不能播都由调用方给。真正的解码与
/// 播放（SILK → PCM → AudioTrack）在 VoicePlaybackController 里，
/// 这样这个组件可以在 widget 测试里被完全摆布，不需要真机音频栈。
library;

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';

class VoiceBubble extends StatelessWidget {
  /// 时长（秒）。协议线会给；缺失时按 0 处理（只影响宽度与文案）。
  final int seconds;

  /// 波形柱高度（0..1）。长度就是柱数。
  final List<double> waveform;

  /// 自己发的（右侧气泡）。
  final bool isOut;

  final bool playing;

  /// 0..1 播放进度。
  final double progress;

  /// 正在下载/解码：播放键位置显示一个静态下载图标（**不用转圈**——
  /// 无限动画会让 widget 测试的 pumpAndSettle 直接超时）。
  final bool loading;

  /// 取不到（下载失败/解码失败）时的提示。
  final String? errorText;

  final VoidCallback? onTap;

  const VoiceBubble({
    super.key,
    required this.seconds,
    required this.waveform,
    required this.isOut,
    this.playing = false,
    this.progress = 0,
    this.loading = false,
    this.errorText,
    this.onTap,
  });

  /// 内容宽度：秒数越大越宽，封顶 220、下限 128。
  double get width {
    final w = 128.0 + seconds * 2.6;
    if (w < 128) return 128;
    if (w > 220) return 220;
    return w;
  }

  @override
  Widget build(BuildContext context) {
    final circleBg = isOut
        ? Colors.white.withValues(alpha: 0.22)
        : TelegramColors.accent;
    final iconColor = isOut ? TelegramColors.bubbleOutText : Colors.white;
    final playedColor = isOut
        ? TelegramColors.bubbleOutText
        : TelegramColors.accent;
    final restColor = isOut
        ? Colors.white.withValues(alpha: 0.42)
        : TelegramColors.textSecondary.withValues(alpha: 0.45);
    final textColor = isOut
        ? TelegramColors.bubbleOutText.withValues(alpha: 0.85)
        : TelegramColors.textSecondary;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: width,
        height: 40,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: circleBg,
                shape: BoxShape.circle,
              ),
              child: loading
                  ? Icon(Icons.download_rounded, size: 18, color: iconColor)
                  : Icon(
                      playing
                          ? Icons.pause_rounded
                          : (errorText == null
                                ? Icons.play_arrow_rounded
                                : Icons.refresh_rounded),
                      size: 22,
                      color: iconColor,
                    ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, c) => _bars(
                        width: c.maxWidth,
                        playedColor: playedColor,
                        restColor: restColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (errorText != null)
                        Expanded(
                          child: Text(
                            errorText!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: textColor),
                          ),
                        )
                      else
                        const Spacer(),
                      Text(
                        _label,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.1,
                          color: textColor,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _label {
    if (seconds <= 0) return '语音';
    final s = seconds;
    final m = s ~/ 60;
    final r = s % 60;
    if (m == 0) return '$r″';
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  Widget _bars({
    required double width,
    required Color playedColor,
    required Color restColor,
  }) {
    final slot = 4.0;
    final count = (width ~/ slot).clamp(8, 64);
    final values = waveform.isEmpty ? const <double>[0.4] : waveform;
    final playedBars = (progress.clamp(0.0, 1.0) * count).floor();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < count; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 2),
              child: FractionallySizedBox(
                alignment: Alignment.bottomCenter,
                heightFactor:
                    (0.22 + values[(i * values.length) ~/ count] * 0.78).clamp(
                      0.15,
                      1.0,
                    ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: i < playedBars ? playedColor : restColor,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
