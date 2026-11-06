import 'package:flutter/widgets.dart';

/// 水平滑动切页，参数照搬 Telegram 的 ViewPagerFixed.scrollToPosition：
/// - 时长 320ms（ViewPagerActivity.java:484-487 `getManualScrollDuration()=320`）、
///   缓动 EASE_OUT_QUINT（ViewPagerFixed.java:285-287）；
/// - 旧页与新页**相向平移**，方向由目标索引决定（ViewPagerFixed.java:243-255）：
///   向后切时新页从右侧滑入、旧页向左移出，反之相反。
///
/// 与 IndexedStack 的差别只在"动画呈现"：所有子页仍然常驻树中，非当前页用
/// [Offstage] 隐藏，所以切走再回来时页面状态（滚动位置、输入框内容等）不会丢——
/// 这是既有"滚动记忆"行为的前提，不能换成 AnimatedSwitcher（会 dispose 旧页）。
class HorizontalPager extends StatefulWidget {
  const HorizontalPager({
    super.key,
    required this.index,
    required this.children,
    this.duration = const Duration(milliseconds: 320),
  });

  final int index;
  final List<Widget> children;
  final Duration duration;

  @override
  State<HorizontalPager> createState() => _HorizontalPagerState();
}

class _HorizontalPagerState extends State<HorizontalPager>
    with SingleTickerProviderStateMixin {
  /// CubicBezierInterpolator.EASE_OUT_QUINT = (0.22, 1, 0.36, 1)。
  static const Curve _kEaseOutQuint = Cubic(0.22, 1, 0.36, 1);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1,
  );

  late int _current = widget.index;
  int? _previous;
  int _direction = 1;

  /// 已经访问过的页。和 IndexedStack 的懒构建一样：没轮到的页不 build，
  /// 这样既不会在后台白跑 provider（未访问的联系人/设置页在测试环境里缺
  /// override 就会直接抛错），又能在访问过后把状态一直留住。
  late final Set<int> _built = <int>{widget.index};

  @override
  void initState() {
    super.initState();
    _controller
      ..addListener(_onTick)
      ..addStatusListener(_onStatus);
  }

  void _onTick() {
    if (_previous != null) setState(() {});
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _previous != null) {
      setState(() => _previous = null);
    }
  }

  @override
  void didUpdateWidget(covariant HorizontalPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != _current) {
      _previous = _current;
      _direction = widget.index > _current ? 1 : -1;
      _current = widget.index;
      _built.add(widget.index);
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final double p = _kEaseOutQuint.transform(_controller.value);
        return SizedBox.expand(
          child: ClipRect(
            child: Stack(
              children: <Widget>[
                for (int i = 0; i < widget.children.length; i++)
                  _childAt(i, width, p),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _childAt(int i, double width, double p) {
    final double dx;
    if (i == _current) {
      dx = _previous == null ? 0 : _direction * (1 - p) * width;
    } else if (_previous != null && i == _previous) {
      dx = -_direction * p * width;
    } else {
      return Positioned.fill(
        child: Offstage(
          offstage: true,
          child: _built.contains(i)
              ? widget.children[i]
              : const SizedBox.shrink(),
        ),
      );
    }
    return Positioned.fill(
      child: Transform.translate(
        offset: Offset(dx, 0),
        child: widget.children[i],
      ),
    );
  }
}
