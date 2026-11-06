/// L4 主壳：4 槽底栏（Telegram MainTabsActivity 同构），窄屏与宽屏都叠。
///
/// 依据（org/telegram/ui/MainTabsActivity.java / MainTabsLayout.java / GlassTabView.java）：
/// - TABS_COUNT=4（:93），视觉 4 槽：聊天 / 联系人 / 设置 / 我的（第 4 槽
///   在官方是头像 createAvatar，GlassTabView.java:319）。
/// - 形态是**悬浮胶囊**：高 56dp、上下 margin 8dp、圆角 28dp、内 padding 12dp、
///   最大宽 344dp、Gravity.BOTTOM|CENTER_HORIZONTAL（MainTabsLayout.java:311-385
///   与 DialogsActivity.java:291）；内容底部留白 72dp（DialogsActivity.java:2982）。
/// - 点当前 tab = 列表回顶（MainTabsActivity.java:334-349）。
/// - 列表上滑看历史时胶囊收起：hiddenY = normalY + 40dp、scale lerp(0.85,1,factor)、
///   alpha/clickable 跟可见因子走，380ms EASE_OUT_QUINT（:109-111、:1073-1087）。
/// - 切页是水平滑动 320ms EASE_OUT_QUINT（ViewPagerActivity.java:484-487、
///   ViewPagerFixed.java:243-287），见 widgets/horizontal_pager.dart。
///
/// 窄屏与宽屏的结构差异（LaunchActivity.java:949-953）：
/// - 窄屏：HorizontalPager 四页整页切换；进对话时隐藏胶囊（官方聊天页是全屏 push）。
/// - 宽屏（平板）：主壳只占左栏，**换 tab 只换左栏内容**，右栏始终是当前会话。
///   所以宽屏只渲染一个 HomePage，左栏按 wideTabProvider 切页（见 HomePage._wideLeftPane）。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/objects.dart';
import '../../client_api/qq8_providers.dart';
import '../../client_api/session_providers.dart';
import '../platform/app_breakpoints.dart';
import '../platform/wide_tab_state.dart';
import '../theme/telegram_theme.dart';
import '../theme/theme_mode.dart';
import '../widgets/horizontal_pager.dart';
import '../widgets/telegram_avatar.dart';
import 'contacts_page.dart';
import 'home_page.dart';
import 'my_profile_page.dart';
import 'settings_page.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({
    super.key,
    this.connecting = false,
    this.previewChats = const <Chat>[],
  });

  final bool connecting;
  final List<Chat> previewChats;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  /// 窄屏当前 tab：0=聊天 1=联系人 2=设置 3=我的（宽屏看 wideTabProvider）。
  int _tab = 0;

  /// 宽屏胶囊是否因列表滚动而收起。
  bool _barHidden = false;

  /// 与 lib/ui/pages/home_page.dart 的 _kChatSwitchDuration 保持一致（150ms）：
  /// 转场和底栏/内容区让位必须同一个节拍，这是 Telegram ActionBarLayout 的做法。
  static const Duration _kPaneShift = Duration(milliseconds: 150);

  /// 聊天 tab 里是否正打开着某个会话（窄屏"列表/对话二选一"）。
  bool _chatPaneOpen = false;

  void _onChatPaneVisibility(bool open) {
    if (_chatPaneOpen == open) return;
    setState(() => _chatPaneOpen = open);
  }

  void _selectTab(int index) {
    final bool wide = AppBreakpoints.isTablet(MediaQuery.sizeOf(context).width);
    final int cur = wide ? ref.read(wideTabProvider) : _tab;
    if (cur == index) {
      // 已经是当前 tab：官方语义是"列表回到顶部"，而不是重新选中
      // （MainTabsActivity.java:334-349 → TabFragmentDelegate.onParentScrollToTop）。
      if (index == 0) ref.read(chatListToTopProvider.notifier).state++;
      return;
    }
    if (wide) {
      ref.read(wideTabProvider.notifier).state = index;
    } else {
      setState(() => _tab = index);
    }
  }

  /// 宽屏列表滚动时收起/展开胶囊。官方用 380ms 的 BoolAnimator 驱动
  /// animatorTabsVisible（MainTabsActivity.java:109-111），并把 40dp 位移、
  /// scale 0.85、alpha、clickable 一起插值（checkUi_tabsPosition :1073-1087）。
  /// 只在方向变化时 setState，避免逐帧重建。
  void _onBarScroll(ScrollNotification n) {
    if (n.depth != 0 || n is! ScrollUpdateNotification) return;
    final double delta = n.scrollDelta ?? 0;
    if (delta > 3 && n.metrics.pixels > 32) {
      if (!_barHidden) setState(() => _barHidden = true);
    } else if (delta < -3 || n.metrics.pixels <= 0) {
      if (_barHidden) setState(() => _barHidden = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    applyThemePalette(ref);
    final size = MediaQuery.sizeOf(context);
    final bool wide = AppBreakpoints.isTablet(size.width);
    final double bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final int curTab = wide ? ref.watch(wideTabProvider) : _tab;

    // 徽章 = 总未读**消息数**（官方 checkUnreadCount 用
    // MessagesStorage.getMainUnreadCount，MainTabsActivity.java:400-412），
    // 不是"有未读的会话个数"。
    final int unreadTotal =
        (ref.watch(chatsProvider).valueOrNull ?? const <Chat>[]).fold<int>(
          0,
          (int sum, Chat c) => sum + (c.unreadCount > 0 ? c.unreadCount : 0),
        );

    final Widget bar = _MainTabBar(
      index: curTab,
      unreadTotal: unreadTotal,
      selfUin: ref.watch(qq8LoginServiceProvider).uin,
      selfName: ref.watch(qq8LoginServiceProvider).selfNickname,
      onSelect: _selectTab,
    );

    if (wide) {
      // 平板：左栏由 HomePage 按 wideTabProvider 切页，右栏是当前会话。
      // 胶囊只落在左栏内，宽度夹在 min(344, 侧栏宽-16) 并居中
      // （MainTabsLayout.java:64-69 与 DialogsActivity.java:291）。
      final double sidebarWidth = AppBreakpoints.sidebarWidthFor(size.width);
      return PopScope(
        canPop: curTab == 0,
        onPopInvokedWithResult: (bool didPop, Object? _) {
          if (!didPop) _selectTab(0);
        },
        child: Scaffold(
          backgroundColor: TelegramColors.bgApp,
          body: SafeArea(
            bottom: false,
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (ScrollNotification n) {
                      // 右栏对话的消息列表也会把滚动通知冒到这里；它不该控制
                      // 左栏胶囊的显隐，否则一进会话、消息列表首帧滚动就把胶囊
                      // 藏起来——这正是平板「没有底栏」的成因。用 Scrollable 的
                      // 横向位置区分左右栏：x >= 侧栏宽即右栏。
                      final BuildContext? ctx = n.context;
                      if (ctx != null) {
                        final RenderObject? ro = ctx.findRenderObject();
                        if (ro is RenderBox &&
                            ro.hasSize &&
                            ro.localToGlobal(Offset.zero).dx >=
                                sidebarWidth - 1.0) {
                          return false;
                        }
                      }
                      _onBarScroll(n);
                      return false;
                    },
                    child: HomePage(
                      key: const ValueKey<String>('tab-chats'),
                      connecting: widget.connecting,
                      previewChats: widget.previewChats,
                    ),
                  ),
                ),
                _collapsibleBar(sidebarWidth, bar, bottomInset),
              ],
            ),
          ),
        ),
      );
    }

    final double barHeight = _MainTabBar.height;
    final bool showBar = !(_tab == 0 && _chatPaneOpen);
    // 底栏的出现/让位不能是瞬跳：打开会话时 HomePage 会播 150ms 的进/退转场
    // （home_page.dart 的 _kChatSwitchDuration，DecelerateInterpolator(1.5)），
    // 内容区高度和底栏必须用同样长度、同样缓动跟上，否则整块布局先闪一下，
    // 转场动画再顺也白搭（用户实际就是这么看到"退出没有动效"的）。
    // 让位高度取 MAIN_TABS_HEIGHT_WITH_MARGINS = 56 + 8*2 = 72
    // （DialogsActivity.java:293，官方内容区底部留白见 :2982）。
    final double contentBottom = showBar
        ? barHeight + 8 + 8 + bottomInset
        : 0.0;

    // 四页常驻（HorizontalPager 用 Offstage 隐藏非当前页），切走再回来时页面
    // 状态不丢——滚动记忆、设置页勾选状态等都依赖这一点。
    final Widget pager = HorizontalPager(
      key: const ValueKey<String>('tab-content-pager'),
      index: _tab,
      children: <Widget>[
        HomePage(
          key: const ValueKey<String>('tab-chats'),
          connecting: widget.connecting,
          previewChats: widget.previewChats,
          onChatPaneVisibilityChanged: _onChatPaneVisibility,
        ),
        ContactsPage(
          key: const ValueKey<String>('tab-contacts'),
          onOpenChats: () => _selectTab(0),
        ),
        const SettingsPage(
          key: ValueKey<String>('tab-settings'),
          embedded: true,
        ),
        MyProfilePage(
          key: const ValueKey<String>('tab-profile'),
          onOpenSettings: () => _selectTab(2),
        ),
      ],
    );

    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) _selectTab(0);
      },
      child: Scaffold(
        backgroundColor: TelegramColors.bgApp,
        body: Stack(
          children: <Widget>[
            Positioned.fill(
              child: AnimatedPadding(
                duration: _kPaneShift,
                curve: Curves.easeOutCubic,
                padding: EdgeInsets.only(bottom: contentBottom),
                child: pager,
              ),
            ),
            // 手机底部 60dp 模糊遮罩：官方 fadeView =
            // BlurredBackgroundWithFadeDrawable.setFadeHeight(dp(60), true)
            // （MainTabsActivity.java:374-379），平板不显示（tabletLayout 时
            // alpha=0，:1055-1071）。这里是真 blur（不做整屏模糊是因为
            // BackdropFilter 每帧都要采样，代价大），随胶囊一起淡入淡出。
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 60 + bottomInset,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 380),
                  curve: Curves.easeOut,
                  opacity: showBar ? 1 : 0,
                  // 真模糊 + 同色渐变淡出：官方 fadeView 是
                  // BlurredBackgroundWithFadeDrawable（先 blur，再按高度把 alpha
                  // 渐降到 0）。ClipRect 把 blur 限制在这 60dp 带内（否则会把整个
                  // 列表糊掉），上面再叠 bgApp 透明→实色，顶部无缝、底部同底栏色。
                  child: ClipRect(
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: <Color>[
                              TelegramColors.bgApp.withValues(alpha: 0),
                              TelegramColors.bgApp,
                            ],
                          ),
                        ),
                        // 无 child 的 DecoratedBox 尺寸为 0，渐变画不出来。
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 底栏常驻，用滑出+淡出退场：条件插入会让它在一帧内凭空出现，
            // 和内容区的让位动画对不上。退场后必须 IgnorePointer，免得看不见还能点。
            Positioned(
              left: 8,
              right: 8,
              bottom: 8 + bottomInset,
              child: IgnorePointer(
                ignoring: !showBar,
                child: AnimatedSlide(
                  duration: _kPaneShift,
                  curve: Curves.easeOutCubic,
                  offset: showBar ? Offset.zero : const Offset(0, 0.35),
                  child: AnimatedOpacity(
                    duration: _kPaneShift,
                    curve: Curves.easeOutCubic,
                    opacity: showBar ? 1 : 0,
                    child: Align(child: bar),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 宽屏胶囊：外层定位在左栏，内部居中并夹在 min(344, 侧栏宽-16)。
  /// 滚动收起 = 40dp 下移 + scale 0.85 + 淡出 + 禁点（同官方 checkUi_tabsPosition）。
  Widget _collapsibleBar(double sidebarWidth, Widget bar, double bottomInset) {
    return Positioned(
      left: 0,
      width: sidebarWidth,
      bottom: bottomInset + 8,
      child: IgnorePointer(
        ignoring: _barHidden,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOut,
          offset: _barHidden ? const Offset(0, 0.72) : Offset.zero,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOut,
            opacity: _barHidden ? 0 : 1,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 380),
                  curve: Curves.easeOut,
                  scale: _barHidden ? 0.85 : 1,
                  child: bar,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 悬浮胶囊底栏：宽 <= 344、高 56、圆角 28。
///
/// 交互对齐官方 MainTabsLayout / GlassTabView：
/// - 按压缩放 1.012（MainTabsLayout.java:517-535 SpringAnimation）；
/// - 长按 750ms 后左右拖动切 tab、松手落定（ClickHelper :441-538，
///   长按阈值 = getLongPressDuration*750/1000）。Flutter 没有可调的 750ms
///   长按阈值，只能用 Pointer 计时器自己实现，见 [_startLongPress]。
/// - 选中块 320ms DECELERATE、scale 0.6→1、9% 强调色（GlassTabView.java:150-165）；
/// - 徽章 380ms EASE_OUT_QUINT scale 0→1（GlassTabView.java:68/:167/:192）。
class _MainTabBar extends StatefulWidget {
  const _MainTabBar({
    required this.index,
    required this.unreadTotal,
    required this.onSelect,
    this.selfUin,
    this.selfName,
  });

  static const double height = 56;
  static const double _maxWidth = 344;
  static const double padding = 12;

  final int index;

  /// 总未读消息数（>99 显示 99+）。
  final int unreadTotal;
  final ValueChanged<int> onSelect;
  final int? selfUin;
  final String? selfName;

  @override
  State<_MainTabBar> createState() => _MainTabBarState();
}

class _MainTabBarState extends State<_MainTabBar> {
  static const Duration _kPressDuration = Duration(milliseconds: 120);
  static const Duration _kLongPress = Duration(milliseconds: 750);
  static const double _kPressScale = 1.012;

  bool _pressed = false;
  Timer? _longPressTimer;

  /// 长按拖动中手指所在的槽（只做高亮，松手才真正切）。
  int? _dragIndex;

  /// 胶囊实际宽度，用于把指针 x 换算成槽索引。
  double _barWidth = _MainTabBar._maxWidth;

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  void _onDown(PointerDownEvent event) {
    if (!_pressed) setState(() => _pressed = true);
    _startLongPress();
  }

  void _startLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = Timer(_kLongPress, () {
      if (!mounted) return;
      setState(() => _dragIndex = widget.index);
    });
  }

  void _onMove(PointerMoveEvent event) {
    if (_dragIndex == null) return;
    final int i = _indexAt(event.localPosition.dx);
    if (i != _dragIndex) setState(() => _dragIndex = i);
  }

  void _onUp(PointerUpEvent event) {
    _longPressTimer?.cancel();
    final int? drag = _dragIndex;
    if (_pressed || drag != null) {
      setState(() {
        _pressed = false;
        _dragIndex = null;
      });
    }
    if (drag != null && drag != widget.index) widget.onSelect(drag);
  }

  void _onCancel(PointerCancelEvent event) {
    _longPressTimer?.cancel();
    if (_pressed || _dragIndex != null) {
      setState(() {
        _pressed = false;
        _dragIndex = null;
      });
    }
  }

  int _indexAt(double x) {
    final double usable = _barWidth - _MainTabBar.padding * 2;
    if (usable <= 0) return widget.index;
    final int i = ((x - _MainTabBar.padding) / (usable / 4)).floor();
    return i.clamp(0, 3);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _barWidth = math.min(constraints.maxWidth, _MainTabBar._maxWidth);
        return SizedBox(
          width: _barWidth,
          height: _MainTabBar.height,
          child: Listener(
            onPointerDown: _onDown,
            onPointerMove: _onMove,
            onPointerUp: _onUp,
            onPointerCancel: _onCancel,
            child: AnimatedScale(
              scale: _pressed ? _kPressScale : 1,
              duration: _kPressDuration,
              curve: Curves.easeOut,
              child: Container(
                key: const ValueKey<String>('main-tab-bar'),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.28),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                // 玻璃胶囊：底下的列表/内容透过 blur 浮上来，比单纯换个浅色更
                // 接近 AyuGram 的观感。阴影留在最外层（ClipRRect 内的阴影会被裁）。
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: _MainTabBar.padding,
                      ),
                      decoration: BoxDecoration(
                        color: TelegramColors.bgHover.withValues(alpha: 0.80),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      foregroundDecoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: TelegramColors.divider),
                      ),
                      child: Row(
                        children: <Widget>[
                          _item(
                            0,
                            Icons.chat_bubble_outline,
                            Icons.chat_bubble,
                            '聊天',
                            badge: widget.unreadTotal,
                          ),
                          _item(1, Icons.people_outline, Icons.people, '联系人'),
                          _item(
                            2,
                            Icons.settings_outlined,
                            Icons.settings,
                            '设置',
                          ),
                          _profileItem(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 选中态的底板：官方 GlassTabView.dispatchDraw(:150-165) 用 9% 的强调色
  /// 画一个圆角块（320ms DECELERATE、scale lerp 0.6→1），label 始终显示、
  /// 选中时换 extra-bold（:233-237、:254-265 updateColors 让 label 与图标同色）。
  Widget _slot(int i, Widget Function(BuildContext, double) builder) {
    final bool active = widget.index == i;
    // 长按拖动时临时把高亮跟着手指走（官方 CheckHelper.checkLongMove 只移动
    // selector，松手才 performClick 真正切页）。
    final bool highlighted = _dragIndex == null ? active : _dragIndex == i;
    return Expanded(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: highlighted ? 1 : 0),
        duration: const Duration(milliseconds: 320),
        curve: Curves.decelerate,
        builder: (BuildContext context, double t, Widget? child) {
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (t > 0.001)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 2,
                    horizontal: 2,
                  ),
                  child: Transform.scale(
                    scale: 0.6 + 0.4 * t,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: TelegramColors.accent.withValues(
                          alpha: 0.09 * t,
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              builder(context, t),
            ],
          );
        },
      ),
    );
  }

  Widget _item(
    int i,
    IconData icon,
    IconData activeIcon,
    String label, {
    int badge = 0,
  }) {
    final bool active = widget.index == i;
    return _slot(i, (BuildContext context, double t) {
      // 图标与文字颜色随选中因子 blend（GlassTabView.java:255-256 blendARGB）。
      final Color color = Color.lerp(
        TelegramColors.textSecondary,
        TelegramColors.accent,
        t,
      )!;
      return InkWell(
        key: ValueKey<String>('main-tab-$i'),
        borderRadius: BorderRadius.circular(16),
        onTap: () => widget.onSelect(i),
        // 空 onLongPress：注册长按识别器，让 InkWell 在长按后让出 tap，
        // 真正"长按拖动切 tab"由外层 Listener 计时 750ms 后处理。
        onLongPress: () {},
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Icon(active ? activeIcon : icon, size: 22, color: color),
                if (badge > 0)
                  Positioned(
                    right: -8,
                    top: -4,
                    child: _TabBadge(count: badge),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: active ? FontWeight.w800 : FontWeight.w400,
              ),
            ),
          ],
        ),
      );
    });
  }

  /// 第 4 槽是头像（官方 createAvatar）：选中时套一圈强调色。
  Widget _profileItem() {
    final bool active = widget.index == 3;
    const double size = 24;
    return _slot(3, (BuildContext context, double t) {
      return InkWell(
        key: const ValueKey<String>('main-tab-3'),
        borderRadius: BorderRadius.circular(16),
        onTap: () => widget.onSelect(3),
        onLongPress: () {},
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              width: size + 4,
              height: size + 4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: active ? TelegramColors.accent : Colors.transparent,
                  width: 1.5,
                ),
              ),
              alignment: Alignment.center,
              child: TelegramAvatar(
                // 昵称未知时用「Q」当首字母兜底：以前写死 '我'，一进「我的」
                // 页就显示成「我的昵称：我」（用户反馈第 1 条）。
                name: (widget.selfName?.isNotEmpty ?? false)
                    ? widget.selfName!
                    : (widget.selfUin == null ? '?' : 'Q'),
                size: size,
                url: widget.selfUin == null
                    ? null
                    : qqAvatarUrl(widget.selfUin!, size: 100),
              ),
            ),
            const SizedBox(height: 1),
            Text(
              '我的',
              style: TextStyle(
                color: Color.lerp(
                  TelegramColors.textSecondary,
                  TelegramColors.accent,
                  t,
                ),
                fontSize: 12,
                fontWeight: active ? FontWeight.w800 : FontWeight.w400,
              ),
            ),
          ],
        ),
      );
    });
  }
}

/// 未读徽章：380ms EASE_OUT_QUINT 从 0 放大到 1（GlassTabView.java:68/:167/:192），
/// 数字变化走 160ms 交叉淡入，避免直接从 5 跳到 6。
class _TabBadge extends StatelessWidget {
  const _TabBadge({required this.count});

  final int count;

  static const Curve _kEaseOutQuint = Cubic(0.22, 1, 0.36, 1);

  @override
  Widget build(BuildContext context) {
    final String text = count > 99 ? '99+' : '$count';
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 380),
      curve: _kEaseOutQuint,
      builder: (BuildContext context, double t, Widget? child) {
        return Transform.scale(scale: t, child: child);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        constraints: const BoxConstraints(minWidth: 15),
        height: 15,
        decoration: BoxDecoration(
          color: TelegramColors.accent,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          child: Text(
            text,
            key: ValueKey<String>(text),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
