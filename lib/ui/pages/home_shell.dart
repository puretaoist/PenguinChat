/// L4 主壳：4 槽底栏（Telegram MainTabsActivity 同构），窄屏与宽屏都叠。
///
/// 依据（org/telegram/ui/MainTabsActivity.java / MainTabsLayout.java / GlassTabView.java）：
/// - TABS_COUNT=4（:93），视觉 4 槽：聊天 / 联系人 / 设置 / 我的（第 4 槽
///   在官方是头像 createAvatar，GlassTabView.java:319）。
/// - 形态是**悬浮胶囊**：高 56dp、上下 margin 8dp、圆角 28dp、内 padding 12dp、
///   最大宽 344dp、Gravity.BOTTOM|CENTER_HORIZONTAL（MainTabsLayout.java:311-385
///   与 DialogsActivity.java:291）；内容底部留白 72dp（DialogsActivity.java:2982）。
/// - 点当前 tab = 列表回顶（MainTabsActivity.java:334-349）。
/// - 内容视口铺到底；72dp + 系统底部 inset 只作为列表内部滚动留白
///   （DialogsActivity.java:2982），不裁短整个页面。按用户要求不画胶囊外渐变遮罩。
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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show SpringDescription, SpringSimulation;
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

import '../../client_api/objects.dart';
import '../../client_api/qq8_providers.dart';
import '../../client_api/session_providers.dart';
import '../platform/app_breakpoints.dart';
import '../platform/wide_tab_state.dart';
import '../theme/telegram_theme.dart';
import '../theme/theme_mode.dart';
import '../widgets/glass_capsule_border.dart';
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
  /// 状态栏透明 + 内容延伸到状态栏下（AndroidUtilities.java:6807-6831
  /// enableEdgeToEdge：setDecorFitsSystemWindows(false) + 两条系统栏都设透明）。
  /// 图标亮度跟主题走（AndroidUtilities.java:5343-5355 setLightStatusBar）。
  static SystemUiOverlayStyle _overlayStyle() {
    final Brightness icons = TelegramColors.isDark
        ? Brightness.light
        : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      statusBarBrightness: icons,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
    );
  }

  /// 用 AnnotatedRegion 而不是 SystemChrome：切页/切主题时样式跟着重建，
  /// 不会和别的页面抢全局状态。
  Widget _withSystemBars(Widget child) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: _overlayStyle(),
    child: child,
  );

  int _tab = 0;

  /// 切页动画进行中。官方在 `viewPager.isManualScrolling() || isTouch()` 期间
  /// 直接丢弃 tab 点击（MainTabsActivity.java:334-349），避免连点把翻页队列
  /// 打乱。由 [HorizontalPager.onAnimatingChanged] 驱动。
  bool _pagerAnimating = false;

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
    // 切页动画没结束就丢点击：官方 `viewPager.isManualScrolling() ||
    // isTouch()` 直接 return（MainTabsActivity.java:334-349）。
    if (_pagerAnimating) return;
    final bool wide = AppBreakpoints.isTablet(MediaQuery.sizeOf(context).width);
    final int cur = wide ? ref.read(wideTabProvider) : _tab;
    if (cur == index) {
      // 已经是当前 tab：官方语义是"列表回到顶部"，而不是重新选中
      // （MainTabsActivity.java:334-349 → TabFragmentDelegate.onParentScrollToTop）。
      // 官方四个 tab 都回顶，所以按索引分片请求。
      ref.read(tabScrollToTopProvider(index).notifier).state++;
      return;
    }
    if (wide) {
      ref.read(wideTabProvider.notifier).state = index;
    } else {
      setState(() => _tab = index);
    }
  }

  @override
  Widget build(BuildContext context) {
    applyThemePalette(ref);
    final size = MediaQuery.sizeOf(context);
    final bool wide = AppBreakpoints.isTablet(size.width);
    final double bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final int curTab = wide ? ref.watch(wideTabProvider) : _tab;
    final double listBottomInset = _MainTabBar.wrapperHeight + bottomInset;

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
      return _withSystemBars(
        PopScope(
          canPop: curTab == 0,
          onPopInvokedWithResult: (bool didPop, Object? _) {
            if (!didPop) _selectTab(0);
          },
          child: Scaffold(
            backgroundColor: TelegramColors.bgApp,
            body: SafeArea(
              top: false,
              bottom: false,
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: HomePage(
                      key: const ValueKey<String>('tab-chats'),
                      connecting: widget.connecting,
                      previewChats: widget.previewChats,
                      bottomContentInset: listBottomInset,
                    ),
                  ),
                  _sidebarBar(sidebarWidth, bar, bottomInset),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final bool showBar = !(_tab == 0 && _chatPaneOpen);
    // 留白传给列表而不是外层 Padding：滚动内容才能从胶囊下方穿过。

    // 四页常驻（HorizontalPager 用 Offstage 隐藏非当前页），切走再回来时页面
    // 状态不丢——滚动记忆、设置页勾选状态等都依赖这一点。
    final Widget pager = HorizontalPager(
      key: const ValueKey<String>('tab-content-pager'),
      index: _tab,
      // 切页动画期间忽略 tab 点击：官方 `viewPager.isManualScrolling() ||
      // isTouch()` 直接 return（MainTabsActivity.java:334-349）。
      onAnimatingChanged: (bool v) {
        if (mounted && _pagerAnimating != v) {
          setState(() => _pagerAnimating = v);
        }
      },
      children: <Widget>[
        HomePage(
          key: const ValueKey<String>('tab-chats'),
          connecting: widget.connecting,
          previewChats: widget.previewChats,
          onChatPaneVisibilityChanged: _onChatPaneVisibility,
          bottomContentInset: listBottomInset,
        ),
        ContactsPage(
          key: const ValueKey<String>('tab-contacts'),
          onOpenChats: () => _selectTab(0),
          bottomContentInset: listBottomInset,
        ),
        SettingsPage(
          key: const ValueKey<String>('tab-settings'),
          embedded: true,
          bottomContentInset: listBottomInset,
        ),
        MyProfilePage(
          key: const ValueKey<String>('tab-profile'),
          onOpenSettings: () => _selectTab(2),
          bottomContentInset: listBottomInset,
        ),
      ],
    );

    return _withSystemBars(
      PopScope(
        canPop: _tab == 0,
        onPopInvokedWithResult: (bool didPop, Object? _) {
          if (!didPop) _selectTab(0);
        },
        child: Scaffold(
          backgroundColor: TelegramColors.bgApp,
          body: Stack(
            children: <Widget>[
              Positioned.fill(child: pager),
              // 用户指定只保留胶囊内的实时模糊，不叠整宽 fadeView。
              // 底栏常驻，用滑出+淡出退场：条件插入会让它在一帧内凭空出现，
              // 和内容区的让位动画对不上。退场后必须 IgnorePointer，免得看不见还能点。
              // 官方 tabsViewWrapper 是 MATCH_PARENT 贴底（MainTabsActivity.java:383
              // `createFrame(MATCH_PARENT, 72, BOTTOM|CENTER_HORIZONTAL)`），左右不
              // 留 margin —— 视觉缩进全部来自 tabsView 的 12dp padding（:311）与
              // 背景 7.666dp 内缩（:368），所以这里也贴边、只让出导航栏高度。
              Positioned(
                left: 0,
                right: 0,
                bottom: bottomInset,
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
      ),
    );
  }

  /// 宽屏胶囊：外层定位在左栏，内部居中并夹在 min(344, 侧栏宽)。
  ///
  /// 不做"滚动收起"。官方底栏的显隐只由两个条件驱动，都不在滚动上：
  /// ① 搜索态 ② 进会话转场时 blurredView 遮罩可见
  /// （`T/DialogsActivity.java:14076-14082` `checkUi_mainTabsVisible()`：
  /// `mainTabsVisible = !searching && (blurredView == null || getBackground() == null
  ///  || getAlpha() < 0.01f || getVisibility() == GONE)`）。
  /// 官方 `checkUi_tabsPosition`（MainTabsActivity.java:1073-1087）那套
  /// 40dp 位移 + scale 0.85 + 淡出是给这两个条件用的，不是给滚动的。
  Widget _sidebarBar(double sidebarWidth, Widget bar, double bottomInset) {
    return Positioned(
      left: 0,
      width: sidebarWidth,
      bottom: bottomInset,
      child: Center(
        // 官方 tabsViewWrapper 左右不留 margin（MainTabsActivity.java:383），
        // 视觉缩进全在 tabsView 的 12dp padding 与背景 7.666dp 内缩里。
        child: bar,
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

  /// 外层槽高：官方 `MAIN_TABS_HEIGHT_WITH_MARGINS = 56 + 8*2 = 72`
  /// （DialogsActivity.java:293），`tabsViewWrapper.addView(tabsView,
  /// createFrame(MATCH_PARENT, 72, BOTTOM|CENTER_HORIZONTAL))`
  /// （MainTabsActivity.java:383）。
  static const double wrapperHeight = 72;

  /// 背景相对外层的内缩：`tabsViewBackground.setPadding(dp(8 - 0.334f))`
  /// （MainTabsActivity.java:368）。注意 `BlurredBackgroundDrawable.build()`
  /// 里是 `boundsWithPadding.inset(padding, padding)`（:256-271）——是**内缩**，
  /// 所以视觉胶囊 = 72 - 7.666*2 ≈ 56.67dp 高、宽 = 外层宽 - 15.33dp。
  static const double capsuleInset = 7.666;

  /// tab 内容区高度：官方 `tabHeight = height - paddingTop - paddingBottom`
  /// （`MainTabsLayout.java:63`），即 72 - 12*2 = **48**。视觉胶囊高则由
  /// [capsuleInset] 撑出 ≈ 56.67（= 72 - 7.666*2），不再单列常量。
  static const double tabHeight = 48;

  /// tab 内容区相对胶囊的内边距：官方 tabsView padding 12 四周
  /// （MainTabsActivity.java:311），背景再内缩 7.666 → 12 - 7.666 = 4.334。
  /// 等价于内容区高 48dp（= 72 - 12*2，MainTabsLayout.onMeasure 的
  /// `tabHeight = height - paddingTop - paddingBottom`，:63）。
  static const double contentPadding = 12 - capsuleInset;

  /// 三档自适应（官方 MainTabsLayout.java:46-47）：
  /// 文字 12→12→10dp、tab 内 padding 16→8→4dp，逐档试到能塞进可用宽为止。
  static const List<double> passTextSizes = <double>[12, 12, 10];
  static const List<double> passPaddings = <double>[16, 8, 4];

  /// 可用宽不足时也要占满的最小总宽（`MainTabsLayout.java:69`
  /// `minTotalWidthForTabs = Math.min(dp(320), maxTotalWidthForTabs)`）。
  static const double minTotalWidth = 320;

  /// 四个槽的文案（官方 MainTabsChats / MainTabsContacts / Settings /
  /// MainTabsProfile）。
  static const List<String> labels = <String>['聊天', '联系人', '设置', '我的'];

  /// tab 内容区宽度 = 外层宽 - 24（官方 tabsView 四周 12dp padding）。
  static const double contentInset = 12;

  /// 外层槽最大宽：官方 `setMaxWidth(dp(328 + MAIN_TABS_MARGIN*2))` = 344
  /// （MainTabsActivity.java:312）。
  static const double _maxWidth = 344;

  /// 胶囊圆角：官方 `setRadius(dp(MAIN_TABS_HEIGHT/2f))` = 28
  /// （MainTabsActivity.java:367）。注意胶囊实际高 56.67，官方仍写死 28，
  /// 所以不是严格"高的一半"，照抄。
  static const double radius = 28;

  final int index;

  /// 总未读消息数（>99 显示 99+）。
  final int unreadTotal;
  final ValueChanged<int> onSelect;
  final int? selfUin;
  final String? selfName;

  @override
  State<_MainTabBar> createState() => _MainTabBarState();
}

class _MainTabBarState extends State<_MainTabBar>
    with TickerProviderStateMixin {
  /// 按下整体缩放：官方 `animatorIsScaled` 是
  /// `BoolAnimator(0, setScaleX/Y(lerp(1, 1.019f, factor)),
  /// CubicBezierInterpolator.EASE_OUT_QUINT, 380)`
  /// （MainTabsLayout.java:436-439）—— 1.019、380ms、EASE_OUT_QUINT。
  /// 以前写的 1.012 / 120ms / easeOut 是凭感觉定的，三项全偏。
  static const Duration _kPressDuration = Duration(milliseconds: 380);
  static const double _kPressScale = 1.019;
  static const Curve _kEaseOutQuint = Cubic(0.22, 1, 0.36, 1);

  /// 长按阈值：官方 `getLongPressDuration()` 返回
  /// `ClickHelper.Delegate.super.getLongPressDuration() * 750 / 1000`
  /// （MainTabsLayout.java:484-486），而父类默认是
  /// `ViewConfiguration.getLongPressTimeout()` = 500ms（ClickHelper.java:49），
  /// 所以真实值是 **375ms**。以前直接写 750 是把倍数当成了绝对值。
  static const Duration _kLongPress = Duration(milliseconds: 375);

  /// 长按松手后多久才恢复"每个 tab 自绘底板"：官方
  /// `runOnUIThread(restoreDrawSelector, 450)`（MainTabsLayout.java:493）。
  static const Duration _kRestoreSelectorDelay = Duration(milliseconds: 450);

  /// 图标 outline↔filled 变形的时长。
  ///
  /// 官方是每条 tab 一支 lottie（`GlassTabView.checkPlayAnimation`，:280-398），
  /// 选中时 `setCustomEndFrame(framesCount)` 正放、取消时
  /// `setPlayInDirectionOfCustomEndFrame(true)` 倒放。本机 tgs 里帧数自相矛盾
  /// （`tab_chats.json` 根节点 `op:6`、layer `op:179`），无法取证真实时长，
  /// 所以 320ms 是**自定值**，取它只为和选中底板动画
  /// （`isSelectedAnimator` 320ms DECELERATE，GlassTabView.java:67）同节拍。
  static const Duration _kIconMorphDuration = Duration(milliseconds: 320);

  /// 官方拖动 selector 的弹簧：`SpringForce(1).setStiffness(STIFFNESS_MEDIUM)
  /// .setDampingRatio(DAMPING_RATIO_LOW_BOUNCY)`
  /// （MainTabsLayout.java:356-369）。Android 的 STIFFNESS_MEDIUM = 1500、
  /// DAMPING_RATIO_LOW_BOUNCY = 0.6，Flutter 的 SpringDescription.damping 是
  /// 阻尼系数而不是比值，换算 `damping = ratio * 2 * sqrt(mass * stiffness)`。
  static final SpringDescription _kSelectorSpring = SpringDescription(
    mass: 1,
    stiffness: 1500,
    damping: 0.6 * 2 * math.sqrt(1500),
  );

  Timer? _longPressTimer;
  Timer? _restoreTimer;

  /// 按下整体缩放（380ms EASE_OUT_QUINT，1→1.019）。
  late final AnimationController _pressCtrl = AnimationController(
    vsync: this,
    duration: _kPressDuration,
  );
  late final Animation<double> _pressCurve = CurvedAnimation(
    parent: _pressCtrl,
    curve: _kEaseOutQuint,
  );

  /// 缩放的 pivot 偏移（绝对坐标，含官方纵向 3 倍放大）。
  Offset _pivot = Offset.zero;

  /// 长按拖动时 layout 自绘的 selector 中心 x（内容区坐标系）与宽度。
  /// 官方 `drawCustomSelector`（MainTabsLayout.java:310-324）：
  /// `sWidth = getInterpolatedWidthByX(x)`（在相邻两 tab 宽度间线性插值，
  /// :672-718）、`sHeight = height - paddingTop - paddingBottom`、圆角
  /// `sHeight/2`、色 `multAlpha(key_glass_tabSelected, 0.09f)`（:289）。
  late final AnimationController _selectorCtrl = AnimationController.unbounded(
    vsync: this,
  );

  /// 长按期间置真：各 tab 不再自绘底板，改由 [_dragSelector] 统一画。
  bool _skipDrawSelector = false;

  /// 长按拖动中手指所在的槽（只做高亮，松手才真正切）。
  int? _dragIndex;

  /// 胶囊实际宽度，用于把指针 x 换算成槽索引。
  double _barWidth = _MainTabBar._maxWidth;

  /// 当前档位的文字大小（官方三档 12/12/10，MainTabsLayout.java:46）。
  double _textSize = 12;

  /// 各槽宽度与左边界（内容区坐标系，官方 onMeasure 的 tabsWidth/tabsLeftPos）。
  List<double> _tabWidths = <double>[0, 0, 0, 0];
  final List<double> _tabLefts = <double>[0, 0, 0, 0];

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _restoreTimer?.cancel();
    _pressCtrl.dispose();
    _selectorCtrl.dispose();
    super.dispose();
  }

  void _onDown(PointerDownEvent event) {
    _updatePivot(event.localPosition);
    _pressCtrl.forward();
    _startLongPress();
  }

  /// 复刻官方 `checkPivot`（MainTabsLayout.java:563-604）：把按下点相对中心的
  /// 偏移先归一化到椭圆边界，再用 `mappedR = 1.5r/(r+0.5)` 映射，最后
  /// **纵向再放大 3 倍**（`pivotY = lerp(cy, pivotY, 3f)`），让 1.019 的缩放
  /// 看起来是从底部弹起而不是原地膨胀。
  void _updatePivot(Offset p) {
    final double w = _barWidth;
    final double h = _MainTabBar.wrapperHeight;
    if (w <= 0 || h <= 0) return;
    final double cx = w * 0.5;
    final double cy = h * 0.5;
    final double dx = p.dx - cx;
    final double dy = p.dy - cy;
    final double nx = dx / (w * 0.5);
    final double ny = dy / (h * 0.5);
    final double r = math.sqrt(nx * nx + ny * ny);
    double pivotX = cx;
    double pivotY = cy;
    if (r > 1e-4) {
      final double mappedR = 1.5 * r / (r + 0.5);
      final double scale = mappedR / r;
      pivotX = cx + dx * scale;
      pivotY = cy + dy * scale;
    }
    _pivot = Offset(cx + (pivotX - cx) * 1, cy + (pivotY - cy) * 3);
  }

  void _startLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = Timer(_kLongPress, () {
      if (!mounted) return;
      // 官方 onLongPressRequestedAt（MainTabsLayout.java:465-474）：
      // setSkipDrawSelector(true) → 各 tab 不再自绘底板 → checkLongMove(start)
      // → longTouchStart()。
      _restoreTimer?.cancel();
      _selectorCtrl.value = _centerOf(widget.index);
      setState(() {
        _skipDrawSelector = true;
        _dragIndex = widget.index;
      });
      _selectorCtrl.animateWith(
        SpringSimulation(
          _kSelectorSpring,
          _selectorCtrl.value,
          _selectorCtrl.value,
          0,
        ),
      );
    });
  }

  double _centerOf(int i) {
    if (i < 0 || i >= _tabWidths.length) return 0;
    return _tabLefts[i] + _tabWidths[i] / 2;
  }

  /// 官方 `getInterpolatedWidthByX`（MainTabsLayout.java:672-718）：拖动中
  /// selector 的宽度在"左侧最近的 tab"与"右侧最近的 tab"宽度之间线性插值，
  /// 不是固定取某一个 tab 的宽度。
  double _widthAt(double x) {
    int? left;
    int? right;
    for (int i = 0; i < _tabWidths.length; i++) {
      if (_tabWidths[i] <= 0) continue;
      final double c = _centerOf(i);
      if (c <= x && (left == null || c > _centerOf(left))) left = i;
      if (c >= x && (right == null || c < _centerOf(right))) right = i;
    }
    if (left == null && right == null) return 0;
    if (left == null) return _tabWidths[right!];
    if (right == null) return _tabWidths[left];
    final double lx = _centerOf(left);
    final double rx = _centerOf(right);
    if (left == right || lx == rx) return _tabWidths[left];
    final double ratio = (x - lx) / (rx - lx);
    return _tabWidths[left] + (_tabWidths[right] - _tabWidths[left]) * ratio;
  }

  /// 官方 `clampXToChildrenCenters`（:613-643）：拖到首/末 tab 中心外就夹住。
  double _clampToCenters(double x) {
    double lo = double.infinity;
    double hi = -double.infinity;
    for (int i = 0; i < _tabWidths.length; i++) {
      if (_tabWidths[i] <= 0) continue;
      final double c = _centerOf(i);
      if (c < lo) lo = c;
      if (c > hi) hi = c;
    }
    if (lo > hi) return x;
    return x.clamp(lo, hi);
  }

  void _onMove(PointerMoveEvent event) {
    if (_dragIndex == null) return;
    final double x = _clampToCenters(
      event.localPosition.dx - _MainTabBar.contentInset,
    );
    // 拖动中 selector 跟手指走（官方 `animatedLongSelectedViewCenterX = x`，
    // :412-415），并同步高亮最近槽（`setTabSelected(found, true)`，:417-419）。
    _selectorCtrl.value = x;
    final int i = _indexAt(event.localPosition.dx);
    if (i != _dragIndex) setState(() => _dragIndex = i);
  }

  void _onUp(PointerUpEvent event) {
    _longPressTimer?.cancel();
    _pressCtrl.reverse();
    final int? drag = _dragIndex;
    final bool wasDragging = _skipDrawSelector;
    if (wasDragging) {
      // 落定回弹：官方用 `selectedTabPositionX.animateToFinalPosition(cx)` +
      // STIFFNESS_MEDIUM / DAMPING_RATIO_LOW_BOUNCY 弹簧（:421-427、:356-369）。
      final int target = drag ?? widget.index;
      _selectorCtrl.animateWith(
        SpringSimulation(
          _kSelectorSpring,
          _selectorCtrl.value,
          _centerOf(target),
          0,
        ),
      );
      // 450ms 后才恢复每 tab 自绘底板（`runOnUIThread(restoreDrawSelector, 450)`，
      // :493），这期间仍由 layout 自绘 selector，视觉上不会闪。
      _restoreTimer?.cancel();
      _restoreTimer = Timer(_kRestoreSelectorDelay, () {
        if (!mounted) return;
        setState(() => _skipDrawSelector = false);
      });
    }
    if (drag != null) {
      setState(() => _dragIndex = null);
    }
    if (drag != null && drag != widget.index) widget.onSelect(drag);
  }

  void _onCancel(PointerCancelEvent event) {
    _longPressTimer?.cancel();
    _restoreTimer?.cancel();
    _pressCtrl.reverse();
    if (_dragIndex != null || _skipDrawSelector) {
      setState(() {
        _dragIndex = null;
        _skipDrawSelector = false;
      });
    }
  }

  int _indexAt(double x) {
    if (_tabWidths.every((double w) => w <= 0)) return widget.index;
    // Listener 挂在外层 72dp 槽上，而 _tabLefts 是内容区坐标系（相对胶囊
    // 再缩 contentPadding）。两者原点差 = capsuleInset + contentPadding
    // = 7.666 + 4.334 = 12（= contentInset）。
    final double local = x - _MainTabBar.contentInset;
    int best = 0;
    double bestDist = double.infinity;
    for (int i = 0; i < _tabWidths.length; i++) {
      final double center = _tabLefts[i] + _tabWidths[i] / 2;
      final double d = (local - center).abs();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  // 胶囊底色 / 上下两段描边 / 贴地薄影全部收在 GlassCapsule
  // （glass_capsule_border.dart）：官方 mainTabs() 与 topPanel() 的 alpha、
  // 描边上下色、阴影色、阴影层、线宽逐项相同，只有 target 色不同，而两个
  // target key 的 fallback 都指向 key_dialogBackground（Theme.java:3707-3708），
  // 默认主题下同色 —— 主 tab 胶囊与聊天顶栏胶囊本来就是同一套玻璃。

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _barWidth = math.min(constraints.maxWidth, _MainTabBar._maxWidth);
        // 外层槽 72 高（官方 MAIN_TABS_HEIGHT_WITH_MARGINS），tab 内容区 48 高
        // 由四周 12dp padding 让出来（MainTabsActivity.java:311/:383），胶囊背景
        // 再相对外层内缩 7.666dp（:368 + BlurredBackgroundDrawable.java:256-271），
        // 所以视觉胶囊比内容区每边大 4.334dp。
        return SizedBox(
          key: const ValueKey<String>('main-tab-bar'),
          width: _barWidth,
          height: _MainTabBar.wrapperHeight,
          child: Listener(
            onPointerDown: _onDown,
            onPointerMove: _onMove,
            onPointerUp: _onUp,
            onPointerCancel: _onCancel,
            child: AnimatedBuilder(
              animation: _pressCurve,
              builder: (BuildContext context, Widget? child) {
                // 官方 setScaleX/Y 是整体缩放、pivot 由 checkPivot 定
                // （MainTabsLayout.java:436-439 + :563-604）。
                final double s = 1 + (_kPressScale - 1) * _pressCurve.value;
                return Transform(
                  transform: Matrix4.identity()
                    ..translateByDouble(_pivot.dx, _pivot.dy, 0, 1)
                    ..scaleByDouble(s, s, 1, 1)
                    ..translateByDouble(-_pivot.dx, -_pivot.dy, 0, 1),
                  child: child,
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(_MainTabBar.capsuleInset),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(_MainTabBar.radius),
                    // 贴地薄影：官方 setShadowLayer(dpf2(2.667), 0, dpf2(0.85))，
                    // 色 0x20000000（亮）/ 0x04FFFFFF（暗）。换算与取值见
                    // GlassCapsule.shadows。
                    boxShadow: GlassCapsule.shadows(),
                  ),
                  // 玻璃胶囊：底下的列表/内容透过 blur 浮上来。阴影留在最外层
                  // （ClipRRect 内的阴影会被裁）。blur 半径官方查不到具体值，
                  // 取值与登记见 GlassCapsule.blurSigma。
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(_MainTabBar.radius),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(
                        sigmaX: GlassCapsule.blurSigma,
                        sigmaY: GlassCapsule.blurSigma,
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          color: GlassCapsule.fill(),
                          borderRadius: BorderRadius.circular(
                            _MainTabBar.radius,
                          ),
                        ),
                        // 描边用自绘：官方是上下两段异色、0.4dp
                        // （BlurredBackgroundProviderImpl.java:29-33），
                        // BoxDecoration + borderRadius 只支持 uniform Border，
                        // 做不出上下异色。
                        child: GlassCapsuleBorder(
                          radius: _MainTabBar.radius,
                          topColor: GlassCapsule.strokeTop(),
                          bottomColor: GlassCapsule.strokeBottom(),
                          strokeWidth: GlassCapsule.strokeWidth,
                          child: Padding(
                            padding: const EdgeInsets.all(
                              _MainTabBar.contentPadding,
                            ),
                            // 内容区高固定 48 = 72 - 12*2（官方 onMeasure
                            // `tabHeight = height - paddingTop - paddingBottom`，
                            // MainTabsLayout.java:63）。
                            child: SizedBox(
                              height: _MainTabBar.tabHeight,
                              child: Stack(
                                children: <Widget>[
                                  // 长按拖动期间由"布局层"统一画一个 selector
                                  // （官方 MainTabsLayout.dispatchDraw 在
                                  // super.dispatchDraw 之前画，:310-324），
                                  // 各 tab 自己的底板同时停画（setSkipDrawSelector）。
                                  if (_skipDrawSelector)
                                    Positioned.fill(child: _dragSelector()),
                                  Row(children: _slots()),
                                ],
                              ),
                            ),
                          ),
                        ),
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

  /// 长按拖动时由布局层统一绘制的 selector。
  ///
  /// 照官方 `MainTabsLayout.dispatchDraw`（:310-324）：
  /// - `x = animatedLongSelectedViewCenterX + animatedLongSelectedViewOffsetX`
  /// - `sWidth = getInterpolatedWidthByX(x, this)` —— 相邻两 tab 宽度线性插值
  /// - `sHeight = getHeight() - paddingTop - paddingBottom` = 内容区高 48
  /// - 圆角 `sHeight / 2` = 24
  /// - 色 `multAlpha(key_glass_tabSelected, 0.09f)`（:289）
  Widget _dragSelector() {
    return AnimatedBuilder(
      animation: _selectorCtrl,
      builder: (BuildContext context, Widget? child) {
        final double x = _selectorCtrl.value;
        final double w = _widthAt(x);
        if (w <= 0) return const SizedBox.shrink();
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned(
              left: x - w / 2,
              top: 0,
              width: w,
              height: _MainTabBar.tabHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // 官方 selector 色 = multAlpha(key_glass_tabSelected, 0.09f)
                  // （MainTabsLayout.java:289 setSkipDrawSelector 里设的
                  // selectorPaint），不是 TelegramColors.accent。
                  color: TelegramColors.glassTabSelected.withValues(
                    alpha: 0.09,
                  ),
                  borderRadius: BorderRadius.circular(
                    _MainTabBar.tabHeight / 2,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 四个槽 + 按官方算法算出来的每槽宽度。
  ///
  /// 宽度分配照抄 `MainTabsLayout.onMeasure`（:59-154）：
  /// 1. 三档降级：文字 12/12/10dp、tab 内 padding 16/8/4dp，逐档试
  ///    `Σ(文字宽 + padding*2) <= 可用宽`，第一档能塞下就用它（:73-90）；
  /// 2. 超宽等比缩 `m = 可用宽 / 总宽`（:121-125）；
  /// 3. 不足 `min(320, 可用宽)` 时按权重均分补齐（:126-133）。
  List<Widget> _slots() {
    final double contentWidth = _barWidth - _MainTabBar.contentInset * 2;
    final List<double> textWidths = _measureTextWidths(
      _MainTabBar.passTextSizes.first,
    );

    int chosen = _MainTabBar.passTextSizes.length - 1;
    for (int pass = 0; pass < _MainTabBar.passTextSizes.length; pass++) {
      final double pad = _MainTabBar.passPaddings[pass];
      double total = 0;
      for (final double w in textWidths) {
        total += w + pad * 2;
      }
      if (total <= contentWidth ||
          pass == _MainTabBar.passTextSizes.length - 1) {
        chosen = pass;
        break;
      }
    }
    _textSize = _MainTabBar.passTextSizes[chosen];
    final double tabPadding = _MainTabBar.passPaddings[chosen];
    final double maxTabTextWidthIfEq = contentWidth / 4 - tabPadding * 2;

    final List<double> widths = <double>[];
    double totalWidth = 0;
    int totalWeight = 0;
    for (final double w in textWidths) {
      final double withMargin = w + tabPadding * 2;
      widths.add(withMargin);
      totalWidth += withMargin;
      totalWeight += w > maxTabTextWidthIfEq ? 0 : 1;
    }
    if (totalWeight == 0) totalWeight = 4;

    if (totalWidth > contentWidth) {
      final double m = contentWidth / totalWidth;
      for (int i = 0; i < widths.length; i++) {
        widths[i] *= m;
      }
    } else {
      final double minTotal = math.min(_MainTabBar.minTotalWidth, contentWidth);
      if (totalWidth < minTotal) {
        final double growP = (minTotal - totalWidth) / totalWeight;
        for (int i = 0; i < widths.length; i++) {
          if (textWidths[i] <= maxTabTextWidthIfEq) widths[i] += growP;
        }
      }
    }

    _tabWidths = widths;
    double left = 0;
    for (int i = 0; i < widths.length; i++) {
      _tabLefts[i] = left;
      left += widths[i];
    }

    return <Widget>[
      _slot(
        0,
        widths[0],
        (double t) => _item(
          0,
          Icons.chat_bubble_outline,
          Icons.chat_bubble,
          _MainTabBar.labels[0],
          t,
          badge: widget.unreadTotal,
        ),
      ),
      _slot(
        1,
        widths[1],
        (double t) => _item(
          1,
          Icons.people_outline,
          Icons.people,
          _MainTabBar.labels[1],
          t,
        ),
      ),
      _slot(
        2,
        widths[2],
        (double t) => _item(
          2,
          Icons.settings_outlined,
          Icons.settings,
          _MainTabBar.labels[2],
          t,
        ),
      ),
      _slot(3, widths[3], _profileItem),
    ];
  }

  List<double> _measureTextWidths(double fontSize) {
    return <double>[
      for (final String label in _MainTabBar.labels)
        (TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w500),
          ),
          textDirection: TextDirection.ltr,
        )..layout()).width,
    ];
  }

  /// 选中态的底板：官方 GlassTabView.dispatchDraw(:150-165) 用 9% 的强调色
  /// 画一个圆角块（320ms DECELERATE、scale lerp 0.6→1），label 始终显示、
  /// 选中时换 extra-bold（:233-237、:254-265 updateColors 让 label 与图标同色）。
  ///
  /// 宽度由 [_slots] 按官方 onMeasure 算好后传进来（不再用 Expanded 均分）。
  Widget _slot(int i, double width, Widget Function(double t) builder) {
    final bool active = widget.index == i;
    // 长按拖动时临时把高亮跟着手指走（官方 CheckHelper.checkLongMove 只移动
    // selector，松手才 performClick 真正切页）。
    final bool highlighted = _dragIndex == null ? active : _dragIndex == i;
    return SizedBox(
      width: width,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: highlighted ? 1 : 0),
        duration: const Duration(milliseconds: 320),
        curve: Curves.decelerate,
        builder: (BuildContext context, double t, Widget? child) {
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // 官方 dispatchDraw 的条件是
              // `selectedFactor > 0 && !skipDrawSelector`
              // （GlassTabView.java:154）—— 长按期间各 tab 停画底板，
              // 改由布局层 [_dragSelector] 统一画（MainTabsLayout.java:286-302）。
              //
              // 注意官方**不是**"一块底板在 tab 之间横移"：每个 tab 各持一个
              // isSelectedAnimator（320ms DECELERATE，GlassTabView.java:67），
              // 选中时本 tab 底板 alpha 0→0.09、scale lerp(0.6,1)（:157-163），
              // 旧 tab 同时反向淡出缩小 —— 是两个胶囊原地交叉淡入淡出。
              if (t > 0.001 && !_skipDrawSelector)
                // 官方底板铺满整个 tab 宽高（GlassTabView.java:158
                // `tmpRectF.set(0, 0, viewWidth, getHeight())`），圆角取
                // 短边一半（:159 `r = min(width, height) / 2f`）——内容区高
                // 48 恒小于槽宽，所以圆角恒 = 24，画出来是完整胶囊而非
                // 圆角方块。以前内缩 2dp + radius 16 是"板感"主因之一。
                Transform.scale(
                  scale: 0.6 + 0.4 * t,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      // 同 _dragSelector：官方 multAlpha(glass_tabSelected, 0.09*alpha)
                      // （GlassTabView.java:157）。
                      color: TelegramColors.glassTabSelected.withValues(
                        alpha: 0.09 * t,
                      ),
                      borderRadius: BorderRadius.circular(
                        _MainTabBar.tabHeight / 2,
                      ),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              builder(t),
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
    String label,
    double t, {
    int badge = 0,
  }) {
    final bool active = widget.index == i;
    // 官方是**两套插值端点**（GlassTabView.java:254-255 updateColors）：
    // 图标 `blendARGB(colorDefault, colorSelected)`、
    // 文字 `blendARGB(colorDefault, colorSelectedText)`，
    // 起点都是 colorDefault = key_glass_tabUnselected。
    // 真实主题下（Theme.java:3705-3716 fallback）：
    //   glass_tabSelected = glass_tabSelectedText = chat_messagePanelSend = 0xFF229AF0
    //   glass_tabUnselected = windowBackgroundWhiteBlackText（暗纯白 / 亮 0xFF333333）
    // 以前这里用 textSecondary→accent 一个 lerp 同时喂图标和文字，暗色下
    // 起点是灰蓝 0xFF8091A0（官方纯白）、终点是 0xFF61A3D7（官方 0xFF229AF0）。
    final Color iconColor = Color.lerp(
      TelegramColors.glassTabUnselected,
      TelegramColors.glassTabSelected,
      t,
    )!;
    final Color textColor = Color.lerp(
      TelegramColors.glassTabUnselected,
      TelegramColors.glassTabSelectedText,
      t,
    )!;
    return InkWell(
      key: ValueKey<String>('main-tab-$i'),
      borderRadius: BorderRadius.circular(16),
      onTap: () => widget.onSelect(i),
      // 空 onLongPress：注册长按识别器，让 InkWell 在长按后让出 tap，
      // 真正"长按拖动切 tab"由外层 Listener 计时 375ms 后处理
      // （官方 500ms × 750/1000，MainTabsLayout.java:484-486）。
      onLongPress: () {},
      child: Padding(
        // 官方是绝对定位不是居中排版：图标 24×24 top 4（GlassTabView.java:406
        // `createFrame(24, 24, ..., 0, 4, 0, 0)`），文字 top 28.33（:96），
        // 两者间隙只有 0.33dp。这里用"顶部对齐 + 4dp 内边距 + 0.33 间隙"
        // 复刻同一组基线，而不是 Column 居中（居中会整体下移约 3dp）。
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: <Widget>[
            Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                // 图标 outline↔filled 变形（A29）。
                //
                // 官方每条 tab 挂一支 lottie（`GlassTabView.checkPlayAnimation`，
                // :280-398；资源 `res/raw/tab_{chats,contacts,settings,calls}.json`），
                // 选中时 `setCustomEndFrame(framesCount)` 正放、取消时
                // `setPlayInDirectionOfCustomEndFrame(true)` 倒放 —— 是**路径变形**，
                // 中间帧能看到气泡分裂、齿轮咬合。
                //
                // 我方不做 lottie：本机 tgs 的帧数自相矛盾（`tab_chats.json` 根节点
                // `op:6`、layer `op:179`，直接喂 lottie 只播前 6 帧），且要额外引
                // 一个渲染器。按用户 2026-11-07 决策（m01702 选方案 B）用自带能力
                // 近似：交叉淡入 + 0.82→1 缩放。**这是自定值，不是官方路径变形**，
                // 已在 docs/ui-parity-matrix.md A29 标注。
                AnimatedSwitcher(
                  duration: _kIconMorphDuration,
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (Widget child, Animation<double> anim) {
                    return FadeTransition(
                      opacity: anim,
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.82, end: 1).animate(anim),
                        child: child,
                      ),
                    );
                  },
                  child: Icon(
                    active ? activeIcon : icon,
                    key: ValueKey<bool>(active),
                    size: 24,
                    color: iconColor,
                  ),
                ),
                if (badge > 0)
                  Positioned(
                    // 官方角标相对 tab 定位：cx = viewWidth/2 + dpf2(11)、
                    // cy = dpf2(10)（GlassTabView.java:179-180），即中心在图标
                    // 右侧 11dp、顶部 10dp 处；换成相对 24dp 图标的左上角偏移
                    // ≈ right: -11-8, top: 10-8 → 这里按图标中心 +11/+10 折算。
                    right: -7,
                    top: 2,
                    child: _TabBadge(count: badge),
                  ),
              ],
            ),
            // 官方 icon 底边 = 4+24 = 28，文字 top = 28.33，间隙 0.33。
            const SizedBox(height: 0.33),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: textColor,
                fontSize: _textSize,
                // 官方未选中是 bold()→medium(500)（AndroidUtilities.java:253-267），
                // 选中换 rextrabold（GlassTabView.java:237）。
                fontWeight: active ? FontWeight.w800 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 第 4 槽是头像（官方 createAvatar）：22×22、圆角 11、top 5、**无描边圈**
  /// （GlassTabView.java:424-427）。选中态只换图标/文字颜色。
  Widget _profileItem(double t) {
    final bool active = widget.index == 3;
    return InkWell(
      key: const ValueKey<String>('main-tab-3'),
      borderRadius: BorderRadius.circular(16),
      onTap: () => widget.onSelect(3),
      onLongPress: () {},
      child: Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 22,
              height: 22,
              // 官方 createAvatar 只做 `BackupImageView.setRoundRadius(dp(11))`
              // + 22×22 top 5（GlassTabView.java:424-427），**没有**选中描边圈；
              // 选中反馈只靠 9% 强调色底板 + 文字变色。以前套 28×28 圆 + 1.5dp
              // 强调色圆环是自造样式，已按 A27 移除。
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
              ),
              alignment: Alignment.center,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: TelegramAvatar(
                  // 昵称未知时用「Q」当首字母兜底：以前写死 '我'，一进「我的」
                  // 页就显示成「我的昵称：我」（用户反馈第 1 条）。
                  name: (widget.selfName?.isNotEmpty ?? false)
                      ? widget.selfName!
                      : (widget.selfUin == null ? '?' : 'Q'),
                  size: 22,
                  url: widget.selfUin == null
                      ? null
                      : qqAvatarUrl(widget.selfUin!, size: 100),
                ),
              ),
            ),
            const SizedBox(height: 0.33),
            Text(
              _MainTabBar.labels[3],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                // 同 _item：文字端点用 glassTabSelectedText（fallback 同
                // chat_messagePanelSend = 0xFF229AF0），起点 glassTabUnselected。
                color: Color.lerp(
                  TelegramColors.glassTabUnselected,
                  TelegramColors.glassTabSelectedText,
                  t,
                ),
                fontSize: _textSize,
                fontWeight: active ? FontWeight.w800 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 未读徽章：380ms EASE_OUT_QUINT 从 0 放大到 1（GlassTabView.java:68/:167/:192），
/// 数字变化走 160ms 交叉淡入，避免直接从 5 跳到 6。
///
/// 几何照官方 dispatchDraw（GlassTabView.java:178-184）：
/// `height = dpf2(16)`、`rInner = dpf2(8)`、`width = max(height, 文字宽 + dp(8))`，
/// 数字走 `LocaleController.formatNumber(unreadCount, ',')` —— **千位逗号、
/// 无 99+ 上限**（MainTabsActivity.java:400-412）。
class _TabBadge extends StatelessWidget {
  const _TabBadge({required this.count});

  final int count;

  static const Curve _kEaseOutQuint = Cubic(0.22, 1, 0.36, 1);

  /// 官方角标底色 = `blendARGB(key_telegram_color, key_fill_RedNormal, 错误因子)`
  /// （`T/GlassTabView.java:208`），其中 `key_telegram_color = 0xFF229AF0`
  /// （`T/ThemeColors.java:14,885`）、`key_fill_RedNormal = 0xffeb5e5e`（:98）。
  ///
  /// 静止态错误因子恒为 0，所以底色就是品牌蓝 `0xFF229AF0`——这是**固定品牌色**，
  /// 不随明暗主题变化，所以不能取 `TelegramColors.accent`（我方强调色暗色
  /// 0xFF61A3D7 / 亮色 0xFF3390EC，都不是官方品牌蓝）。我方暂无错误态角标，
  /// 插值的第二个端点没有调用方，已在 ui-parity-matrix A42 登记。
  static const Color _kBadgeFill = Color(0xFF229AF0);

  /// 千位逗号，等价官方 `LocaleController.formatNumber(count, ',')`。
  static String _format(int n) {
    final String digits = n.abs().toString();
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return n < 0 ? '-$out' : out.toString();
  }

  @override
  Widget build(BuildContext context) {
    final String text = _format(count);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 380),
      curve: _kEaseOutQuint,
      builder: (BuildContext context, double t, Widget? child) {
        return Transform.scale(scale: t, child: child);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        constraints: const BoxConstraints(minWidth: 16),
        height: 16,
        decoration: BoxDecoration(
          // 官方 blendARGB(key_telegram_color, key_fill_RedNormal, 错误因子)
          // （GlassTabView.java:208）；静止态错误因子为 0 → 品牌蓝。
          color: _kBadgeFill,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          child: Text(
            text,
            key: ValueKey<String>(text),
            maxLines: 1,
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
