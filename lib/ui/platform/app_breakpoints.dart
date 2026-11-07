/// L4 响应式断点：全项目**只认这一处**，别在页面里散落 `width >= 720`。
///
/// 采用 Material 3 的窗口尺寸等级（compact <600 / medium 600–839 /
/// expanded ≥840），但只取一条线：**600dp 起就是"平板"**，直接上双栏。
/// 这条线是用户拍板的（"竖屏平板也要分栏"），不要按官方 Android 的
/// `isTablet()`（≥600 且短边…）另起一套判断——多一套规则就多一份对不上。
///
/// 出处参考：Telegram Android 平板布局同样是"列表常驻 + 右侧对话"，
/// 没有"竖屏平板退回单栏"的分支。
library;

/// 窗口宽度等级。
class AppBreakpoints {
  const AppBreakpoints._();

  /// 平板起点（含）。≥600dp 一律双栏：竖屏平板（600–839）和横屏平板都走同一套。
  static const double tablet = 600;

  /// 大屏起点（Material 3 expanded）。给"还能再宽一点"的场景留的钩子，
  /// 当前只有侧栏宽度用到。
  static const double expanded = 840;

  /// 二级页（设置、连接、关于…）正文的最大宽度：超过就居中留白。
  /// 720 是"表单类页面一眼能扫完一行"的经验上限（Material 3 建议 600–840）。
  static const double contentMaxWidth = 720;

  /// 气泡最大宽度上限（像素）。手机上由"可用宽度 × 0.78"决定，永远够不到
  /// 这个值；平板上不设上限的话一条消息会横跨七八百 dp，读起来要甩头。
  static const double bubbleMaxWidth = 520;

  /// 宽屏时左侧会话栏底部要给胶囊 tab 让出的高度：
  /// 胶囊高 56 + 下边距 8 + 上间隙 8 = 72（官方 MAIN_TABS_HEIGHT_WITH_MARGINS 同值）。
  static const double sidebarTabBarReserve = 72;

  static bool isTablet(double width) => width >= tablet;

  /// 平板侧栏宽度：**逐字照搬**官方公式。
  ///
  /// 出处 AndroidUtilities.java:3020-3022：
  ///   getTabletLeftFragmentSize(fullWidth, insetLeft, insetRight) =
  ///     insetLeft + max(dp(320), (fullWidth - insetLeft - insetRight) * 35 / 100)
  /// 即「下限 320dp、比例 35%、没有上限」。LaunchActivity.java:951-953 用它把
  /// 平板切成左栏(leftWidth) / 右栏(width-leftWidth)。
  ///
  /// 之前自己拍的 32% + 300~400 夹取是错的：600dp 平板官方左栏 320、
  /// 1280dp 横屏 448（35%），并不封顶 400。
  static double sidebarWidthFor(double width) {
    return (width * 0.35).clamp(320.0, double.infinity);
  }
}
