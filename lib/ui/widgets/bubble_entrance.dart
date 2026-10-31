/// 消息气泡入场动画：淡入 + 轻微上浮（Telegram 的"新消息"观感）。
///
/// ## 为什么包一层 widget，而不是在 MessageBubble 里做
///
/// MessageBubble 只管"一屏上的气泡长什么样"，它不知道自己是"刚到的"
/// 还是"顺手渲染出来的历史"。判断权在宿主（home_page 的 itemBuilder），
/// 所以动画也留给宿主控制：宿主说 animate: true 才播，其余一律直出。
/// 这样打开会话翻历史时不会整屏气泡一起淡进来（那才是真的难看）。
library;

import 'package:flutter/widgets.dart';

class BubbleEntrance extends StatefulWidget {
  const BubbleEntrance({
    super.key,
    required this.child,
    required this.animate,
  });

  final Widget child;

  /// 只有首次挂载时读它：true 播一次 220ms，false 直接显示。
  final bool animate;

  @override
  State<BubbleEntrance> createState() => _BubbleEntranceState();
}

class _BubbleEntranceState extends State<BubbleEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    // 不播时就停在终点：下面的两个动画在 value=1 处都是"原样"。
    value: widget.animate ? 0 : 1,
  );

  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.06),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    if (widget.animate) _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}
