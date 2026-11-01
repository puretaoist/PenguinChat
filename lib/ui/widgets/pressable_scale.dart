/// L4 表现层：按下缩小的触感反馈（跨组件复用）。
///
/// 为什么用 [Listener] 而不是 [GestureDetector]：本组件只做"视觉反馈"，
/// 不能参与手势竞技场 —— 它经常套在已经有 onTap / onLongPress 的组件外面
/// （气泡、卡片），用 GestureDetector 会和内层抢手势，轻则长按失效，
/// 重则点击被吃掉。[Listener] 只旁听指针事件，绝不影响命中测试。
///
/// 缩放幅度 0.97 / 110ms：TG 的按下反馈靠 ripple 就够，这里给**没有
/// ripple 的暗色卡片**（Container + BoxDecoration 不吃墨水）一点手感；
/// 有 Material 的地方仍以内层 InkWell 的 ripple 为主。
library;

import 'package:flutter/widgets.dart';

class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.scale = 0.97,
    this.duration = const Duration(milliseconds: 110),
    this.enabled = true,
  });

  final Widget child;

  /// 按下时的目标缩放。0.97 已经很轻，再大会像"按扁"。
  final double scale;
  final Duration duration;

  /// 关掉时完全透明（不建动画、不改缩放），便于整块禁用态复用。
  final bool enabled;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  void _set(bool value) {
    if (!widget.enabled || _down == value) return;
    setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down && widget.enabled ? widget.scale : 1.0,
        duration: widget.duration,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
