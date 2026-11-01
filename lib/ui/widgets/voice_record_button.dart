/// 输入栏右侧的麦克风键 + 按住说话的浮层。
///
/// 交互对齐 TG（ChatActivityEnterView 的六态录屏状态机，我们只留必要三态）：
///   - 按住开始录，浮层显示计时 + 实时振幅；
///   - 手指上滑超过 [cancelDistance]（TG: distCanMove = dp(80)）变红提示"松开取消"；
///   - 松手发送，太短（<700ms）丢弃。
library;

import 'package:flutter/material.dart';

import '../audio/voice_recorder_controller.dart';
import '../platform/audio_bridge.dart';
import '../theme/telegram_theme.dart';

class VoiceRecordButton extends StatefulWidget {
  const VoiceRecordButton({
    super.key,
    required this.onRecorded,
    this.enabled = true,
    this.controller,
    this.onError,
    this.size = 42,
    this.cancelDistance = 80,
  });

  /// 录完（且时长够）后回调：裸 PCM 文件 + 波形（0..1）。
  final Future<void> Function(RecordedPcm pcm, List<double> waveform) onRecorded;

  final bool enabled;

  /// 测试可注入；为空则自己造一个走原生通道的。
  final VoiceRecorderController? controller;

  /// 起不来时给用户看的文案（调用方负责显示，例如 SnackBar）。
  final void Function(String message)? onError;

  final double size;

  /// 上滑多少逻辑像素算"取消"。
  final double cancelDistance;

  @override
  State<VoiceRecordButton> createState() => _VoiceRecordButtonState();
}

class _VoiceRecordButtonState extends State<VoiceRecordButton> {
  VoiceRecorderController? _owned;
  OverlayEntry? _overlay;
  bool _willCancel = false;

  VoiceRecorderController get _controller =>
      widget.controller ??
      (_owned ??= VoiceRecorderController(recorder: AudioBridgeRecorder()));

  @override
  void dispose() {
    _removeOverlay();
    _owned?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!widget.enabled) return;
    _willCancel = false;
    final ok = await _controller.start();
    if (!mounted) return;
    if (!ok) {
      widget.onError?.call(_controller.lastError ?? '无法开始录音');
      return;
    }
    _showOverlay();
  }

  Future<void> _end() async {
    _removeOverlay();
    if (_controller.phase == VoiceRecordPhase.idle) {
      // start() 里已经失败了，或者根本没开起来。
      return;
    }
    if (_willCancel) {
      await _controller.cancel();
      return;
    }
    final waveform = _controller.waveform;
    final result = await _controller.finish();
    if (result == null) {
      final err = _controller.lastError;
      if (err != null && err.isNotEmpty) widget.onError?.call(err);
      return;
    }
    await widget.onRecorded(result, waveform);
  }

  void _updateCancel(double dy) {
    final cancel = dy < -widget.cancelDistance;
    if (cancel != _willCancel) {
      setState(() => _willCancel = cancel);
      _overlay?.markNeedsBuild();
    }
  }

  void _showOverlay() {
    _removeOverlay();
    final overlay = Overlay.of(context, rootOverlay: true);
    _overlay = OverlayEntry(builder: (context) => _overlayContent());
    overlay.insert(_overlay!);
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  Widget _overlayContent() {
    return Positioned.fill(
      child: IgnorePointer(
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            final seconds = _controller.elapsedMs / 1000;
            final bars = _controller.waveform;
            final color =
                _willCancel ? TelegramColors.danger : TelegramColors.accent;
            return Center(
              child: Container(
                key: const ValueKey('voice-record-overlay'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
                decoration: BoxDecoration(
                  color: TelegramColors.bgHeader.withValues(alpha: 0.96),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(color: Color(0x66000000), blurRadius: 24),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SizedBox(
                      height: 46,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: <Widget>[
                          Icon(
                            _willCancel ? Icons.delete_outline : Icons.mic,
                            color: color,
                            size: 26,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '${seconds.toStringAsFixed(1)}\u2033',
                            style: TextStyle(
                              color: _willCancel
                                  ? TelegramColors.danger
                                  : TelegramColors.textPrimary,
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 22,
                      width: 180,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: List<Widget>.generate(28, (i) {
                          final double amp = i < bars.length
                              ? bars[bars.length - 1 - i]
                              : 0.0;
                          final h = 3 + amp.clamp(0.0, 1.0) * 19;
                          return Container(
                            width: 3,
                            height: h,
                            margin:
                                const EdgeInsets.symmetric(horizontal: 1.5),
                            decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          );
                        }),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _willCancel ? '松开取消' : '松开 发送 · 上滑取消',
                      style: TextStyle(
                        color: _willCancel
                            ? TelegramColors.danger
                            : TelegramColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('voice-record-button'),
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (_) => _start(),
      onLongPressMoveUpdate: (d) => _updateCancel(d.offsetFromOrigin.dy),
      onLongPressEnd: (_) => _end(),
      onLongPressCancel: () => _end(),
      onTap: () => widget.onError?.call('按住说话'),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: TelegramColors.bgHover,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.mic_none,
          color: TelegramColors.textMuted,
          size: 20,
        ),
      ),
    );
  }
}
