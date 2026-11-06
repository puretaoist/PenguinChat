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
  final Future<void> Function(RecordedPcm pcm, List<double> waveform)
  onRecorded;

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
            final color = _willCancel
                ? TelegramColors.danger
                : TelegramColors.accent;
            // 官方是输入区上方居中的 RecordCircle（
            // `ChatActivityEnterView.java:4512` + recordCircle.onTouch），
            // 一个直径约 200dp 的圆：上箭头（取消时变垃圾桶）、计时、
            // 实时波形，底部一行提示。之前做成 180 宽的圆角卡片，离得远。
            return Align(
              alignment: const Alignment(0, 0.62),
              child: Container(
                key: const ValueKey('voice-record-overlay'),
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  color: TelegramColors.bgHeader.withValues(alpha: 0.97),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color.withValues(alpha: 0.85),
                    width: 2,
                  ),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(color: Color(0x77000000), blurRadius: 28),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      _willCancel
                          ? Icons.delete_outline_rounded
                          : Icons.keyboard_arrow_up_rounded,
                      color: color,
                      size: 24,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${seconds.toStringAsFixed(1)}\u2033',
                      style: TextStyle(
                        color: _willCancel
                            ? TelegramColors.danger
                            : TelegramColors.textPrimary,
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 26,
                      width: 150,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: List<Widget>.generate(24, (i) {
                          final double amp = i < bars.length
                              ? bars[bars.length - 1 - i]
                              : 0.0;
                          final h = 3 + amp.clamp(0.0, 1.0) * 21;
                          return Container(
                            width: 3,
                            height: h,
                            margin: const EdgeInsets.symmetric(horizontal: 1.3),
                            decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          );
                        }),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _willCancel ? '松开 取消' : '松开 发送 · 上滑取消',
                      style: TextStyle(
                        color: _willCancel
                            ? TelegramColors.danger
                            : TelegramColors.textSecondary,
                        fontSize: 11.5,
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
          color: widget.enabled
              ? TelegramColors.accent
              : TelegramColors.bgHover,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.mic_none,
          color: widget.enabled ? Colors.white : TelegramColors.textMuted,
          size: 22,
        ),
      ),
    );
  }
}
