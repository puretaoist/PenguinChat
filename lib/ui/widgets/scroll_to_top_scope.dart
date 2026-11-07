/// 让一个列表响应「点击当前 tab → 回到顶部」。
///
/// 依据 `T/MainTabsActivity.java:334-349`：点击**已经是当前**的 tab 时，官方不是
/// 重新选中，而是调 `TabFragmentDelegate.onParentScrollToTop()` —— 也就是**四个
/// tab 都支持回顶**，不是只有聊天列表。请求经 `tabScrollToTopProvider(tab)` 传递
/// （见 `lib/ui/platform/wide_tab_state.dart`），自增一次 = 一次请求。
///
/// 用法：把列表的 controller 交给本 widget 创建，页面本身不必是 StatefulWidget。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/wide_tab_state.dart';

/// 回顶动画时长。官方 `onParentScrollToTop` 走 `listView.smoothScrollTo(0)`
/// （`DialogsActivity` 里的 `smoothScrollTo`，默认 smooth 时长），本机源码没写
/// 具体毫秒数，这里取与主壳切页一致的观感值 220ms，属**自定值**。
const Duration _kScrollToTopDuration = Duration(milliseconds: 220);

class ScrollToTopScope extends ConsumerStatefulWidget {
  const ScrollToTopScope({
    super.key,
    required this.tab,
    required this.builder,
  });

  /// 本列表所属的 tab 索引（0=聊天 1=联系人 2=设置 3=我的）。
  final int tab;

  /// 用本 widget 给的 controller 构建列表。
  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  @override
  ConsumerState<ScrollToTopScope> createState() => _ScrollToTopScopeState();
}

class _ScrollToTopScopeState extends ConsumerState<ScrollToTopScope> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(tabScrollToTopProvider(widget.tab), (int? prev, int next) {
      if (!_controller.hasClients) return;
      _controller.animateTo(
        0,
        duration: _kScrollToTopDuration,
        curve: Curves.easeOut,
      );
    });
    return widget.builder(context, _controller);
  }
}
