/// 消息气泡入场动画：淡入 + 上浮 + 轻微放大（复刻 Telegram 的"新消息"观感）。
///
/// ## 参数照抄 Telegram
///
/// - 时长 250ms：`ChatListItemAnimator.DEFAULT_DURATION`
///   （ui/recyclerview/ChatListItemAnimator.java:46）；
/// - 曲线 `CubicBezierInterpolator(0.19919472913616398, 0.010644531250000006,
///   0.27920937042459737, 0.91025390625)`：同上 :47 `DEFAULT_INTERPOLATOR`
///   （头段极快、尾段极缓，比 Material 的 easeOut 收得更干脆）；
/// - 0.9 → 1 的缩放：`animateAdd` 里 `setScaleX/setScaleY(0.9f)`（:328-331），
///   入场时再 ObjectAnimator 回到 1（:1497-1501）；
/// - 缩放轴心在气泡水平中心（`pivotX = 背景左 + 宽/2`，:1413-1414），
///   所以由宿主按"我方/对方"传 [BubbleEntrance.alignment]。
///
/// 三条（位移/缩放/透明度）同时跑，也是 Telegram 的 `playTogether`（:1496-1501）。
///
/// ## 为什么包一层 widget，而不是在 MessageBubble 里做
///
/// MessageBubble 只管"一屏上的气泡长什么样"，它不知道自己是"刚到的"
/// 还是"顺手渲染出来的历史"。判断权在宿主（home_page 的 itemBuilder），
/// 所以动画也留给宿主控制：宿主说 animate: true 才播，其余一律直出。
/// 这样打开会话翻历史时不会整屏气泡一起淡进来（那才是真的难看）。
library;

import 'package:flutter/widgets.dart';

/// Telegram `ChatListItemAnimator.DEFAULT_INTERPOLATOR` 的等价曲线。
const Cubic kTelegramItemAnimatorCurve = Cubic(
  0.19919472913616398,
  0.010644531250000006,
  0.27920937042459737,
  0.91025390625,
);

class BubbleEntrance extends StatefulWidget {
  const BubbleEntrance({
    super.key,
    required this.child,
    required this.animate,
    this.alignment = Alignment.center,
    this.slideBegin = const Offset(0, 0.06),
    this.scaleBegin = 0.9,
  });

  final Widget child;

  /// 只有首次挂载时读它：true 播一次 250ms，false 直接显示。
  final bool animate;

  /// 缩放轴心（相对子视图）。Telegram 把轴心放在气泡水平中心：
  /// 我方气泡靠右、对方靠左，所以这个值由宿主决定。
  final Alignment alignment;

  /// 起始位移（相对自身高度）。默认 0.06＝TG 的「新消息」插入
  /// （ChatListItemAnimator :369-370 的 addedItemsHeight 很短）。
  ///
  /// 自己**发出去**的气泡要更夸张：TG 的 TextMessageEnterTransition
  /// （ayugram-pick/TextMessageEnterTransition.java:636-645）把输入框里的
  /// 文字从输入栏的位置一路位移+缩放飞到气泡位置，量级远大于 6% 的高度。
  final Offset slideBegin;

  /// 起始缩放。默认 0.9（ChatListItemAnimator :328-331）；发送飞入用 0.72
  /// ——文字从输入框那一小块长成完整气泡，缩得太轻就看不出来。
  final double scaleBegin;

  @override
  State<BubbleEntrance> createState() => _BubbleEntranceState();
}

class _BubbleEntranceState extends State<BubbleEntrance>
    with SingleTickerProviderStateMixin {
  static const Duration _duration = Duration(milliseconds: 250);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _duration,
    // 不播时就停在终点：下面的三个动画在 value=1 处都是"原样"。
    value: widget.animate ? 0 : 1,
  );

  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: kTelegramItemAnimatorCurve,
  );

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: widget.slideBegin,
    end: Offset.zero,
  ).animate(_curve);

  late final Animation<double> _scale = Tween<double>(
    begin: widget.scaleBegin,
    end: 1.0,
  ).animate(_curve);

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
      opacity: _curve,
      child: SlideTransition(
        position: _slide,
        child: ScaleTransition(
          scale: _scale,
          alignment: widget.alignment,
          child: widget.child,
        ),
      ),
    );
  }
}
