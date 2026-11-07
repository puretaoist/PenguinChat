/// L4 表现层：主题（暗/亮两套调色板 + 切换）
///
/// 暗色配色**逐 key 抄自 Telegram 内置主题文件**
/// `penguis/telegram-src/TelegramAndroid/TMessagesProj/src/main/assets/darkblue.attheme`
/// （Dark Blue，490 行 key=有符号 int 文本），不是自己拍的近似值：
/// `chat_inBubble`/`chat_outBubble`/`chat_wallpaper`/`actionBarDefault` 等直接对应
/// 下面的 bubbleIn/bubbleOut/bgChat/bgHeader。注：`ThemeColors.createDefaultColors()`
/// 只是**浅色兜底表**（`ThemeColors.java:307-313`：in 白、out 浅绿），真正的深色/蓝色
/// 皮肤在 assets 的 .attheme 里，运行时由 `Theme.applyThemeFile` 覆盖。
/// 亮色仍是旧的近似值（对应 `day.attheme`，待迁移）。
///
/// ## 为什么是"调色板持有者"而不是 `Theme.of(context).extension`
///
/// 全 UI 有 **141 处** `TelegramColors.xxx` 引用。用 `ThemeExtension` 的话每一处
/// 都要改成 `context.palette.xxx` 并保证 palette 在作用域里——一次覆盖 8 个
/// 文件的大重构。这里改成：颜色是**静态 getter**，背后指向当前调色板
/// （[TelegramColors.use] 由根组件在每次 build 时按主题设置）。
///
/// * 代价：全局单例。同一进程里**同时**渲染两套主题（比如并排预览）会互相污染；
///   本项目没有这种场景（`flutter test` 也是一个个 pump）。
/// * 将来真要并排两套主题，再按 `ThemeExtension` 重构——那时这批 getter 可以
///   原样保留为"默认调色板"，改动量仍可控。
library;

import 'package:flutter/material.dart';

/// 一套调色板（暗/亮各一份）。
class TelegramPalette {
  final Color bgApp;
  final Color bgSidebar;
  final Color bgChat;
  final Color bgHeader;

  /// 玻璃胶囊底色（官方 `chat_topPanelBackground`；topPanelChatActivity 用它 ×0.76）。
  final Color bgGlassPanel;
  final Color bgInput;
  final Color bgHover;
  final Color bgSelected;
  final Color bubbleOut;
  final Color bubbleIn;

  /// 自己气泡上的正文/次要元素：暗色是白字压紫色，亮色是黑字压浅绿。
  final Color bubbleOutText;
  final Color bubbleOutTime;
  final Color accent;
  final Color accentHover;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color divider;
  final Color online;
  final Color badge;
  final Color danger;

  /// 玻璃底栏：选中态图标色 / 选中态文字色 / 未选中态（图标与文字共用）。
  ///
  /// 官方三键取自 `T/ui/Components/glass/GlassTabView.java:270-276`
  /// `updateColorsLottie()`：`key_glass_tabUnselected` / `key_glass_tabSelected` /
  /// `key_glass_tabSelectedText`。这三个 key **在任何 .attheme 里都不存在**，
  /// 所以实际生效的是 `T/ui/ActionBar/Theme.java:3705-3716` 的 fallback 链：
  /// * `key_glass_tabSelected` → `key_chat_messagePanelSend`
  /// * `key_glass_tabSelectedText` → `key_chat_messagePanelSend`
  /// * `key_glass_tabUnselected` → `key_windowBackgroundWhiteBlackText`
  ///
  /// `assets/darkblue.attheme:155` 与 `assets/day.attheme:96` 的
  /// `chat_messagePanelSend` 同为 `-14509328` = `0xFF229AF0`，所以两个选中色
  /// 在两套主题下都是 `0xFF229AF0`（`ThemeColors.java:876-877` 的默认值
  /// `0xFF1a91e6` / `0xFF0d7fcf` 在真实主题下永远走不到）。
  ///
  /// 未选中色：`darkblue.attheme:89` `windowBackgroundWhiteBlackText = -1`
  /// = 纯白；`day.attheme:49` 同 key = `-13421773` = `0xFF333333`。
  ///
  /// 注意 `GlassTabView.java:254-255` 的插值端点：图标用
  /// `blendARGB(colorDefault, colorSelected)`、文字用
  /// `blendARGB(colorDefault, colorSelectedText)` —— **起点都是未选中色**，
  /// 不是各自的独立默认色。所以暗色下未选中的文字也是纯白。
  final Color glassTabSelected;
  final Color glassTabSelectedText;
  final Color glassTabUnselected;

  /// 是不是暗色基调。
  ///
  /// 不能再用 identical(_p, TelegramPalette.dark) 判暗色：主题色可配置后，
  /// 调色板是 paletteWithAccent 派生出来的新对象，那份常量比较会恒为 false，
  /// 暗色下会错误地走亮色分支（日期胶囊、群名颜色都会错）。
  final bool isDark;

  const TelegramPalette({
    required this.bgApp,
    required this.bgSidebar,
    required this.bgChat,
    required this.bgHeader,
    required this.bgGlassPanel,
    required this.bgInput,
    required this.bgHover,
    required this.bgSelected,
    required this.bubbleOut,
    required this.bubbleIn,
    required this.bubbleOutText,
    required this.bubbleOutTime,
    required this.accent,
    required this.accentHover,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.divider,
    required this.online,
    required this.badge,
    required this.danger,
    required this.glassTabSelected,
    required this.glassTabSelectedText,
    required this.glassTabUnselected,
    this.isDark = false,
  });

  /// 暗色（Dark Blue 主题；色值全部来自 `assets/darkblue.attheme`）。
  ///
  /// 括号里是该字段对应的 attheme key；改色请改 attheme 同 key 的值，别手调。
  static const dark = TelegramPalette(
    bgApp: Color(0xFF1D2733), // windowBackgroundWhite
    bgSidebar: Color(0xFF1D2733), // windowBackgroundWhite
    bgChat: Color(0xFF151E27), // chat_wallpaper（未设壁纸时的底色）
    bgHeader: Color(0xFF242D39), // actionBarDefault
    bgGlassPanel: Color(0xFF212D3B), // chat_topPanelBackground（胶囊玻璃底）
    bgInput: Color(0xFF1D2733), // windowBackgroundWhite
    bgHover: Color(0xFF25313F), // windowBackgroundWhite +8%
    bgSelected: Color(0xFF314A61), // chat_inBubbleSelected
    bubbleOut: Color(0xFF3E618A), // chat_outBubble
    bubbleIn: Color(0xFF232E3B), // chat_inBubble
    bubbleOutText: Color(0xFFFAFAFA), // chat_messageTextOut
    bubbleOutTime: Color(0xFF8FBCDF), // chat_outTimeText
    accent: Color(0xFF61A3D7), // switchTrackChecked / chat_inLoader 系
    accentHover: Color(0xFF7DB6E4),
    textPrimary: Color(0xFFFAFAFA), // chat_messageTextIn
    textSecondary: Color(0xFF8091A0), // chat_inTimeText RGB
    textMuted: Color(0xFF798997), // chat_inFileInfoText
    divider: Color(0xFF283545), // divider 0x95000000 over bg 后的可见等效
    online: Color(0xFF0AC630),
    badge: Color(0xFF61A3D7),
    danger: Color(0xFFFF5C5C),
    glassTabSelected: Color(0xFF229AF0), // chat_messagePanelSend
    glassTabSelectedText: Color(0xFF229AF0), // 同上（fallback 同 key）
    glassTabUnselected: Color(0xFFFFFFFF), // windowBackgroundWhiteBlackText
    isDark: true,
  );

  /// 亮色（Day，现行版）。
  static const light = TelegramPalette(
    bgApp: Color(0xFFFFFFFF),
    bgSidebar: Color(0xFFFFFFFF),
    bgChat: Color(0xFFE6EBEE),
    bgHeader: Color(0xFFFFFFFF),
    bgGlassPanel: Color(0xFFFFFFFF), // chat_topPanelBackground（亮色=白）
    bgInput: Color(0xFFFFFFFF),
    bgHover: Color(0xFFF1F4F6),
    bgSelected: Color(0xFF3390EC),
    bubbleOut: Color(0xFFEEFFDE),
    bubbleIn: Color(0xFFFFFFFF),
    bubbleOutText: Color(0xFF000000),
    bubbleOutTime: Color(0xFF62A03F),
    accent: Color(0xFF3390EC),
    accentHover: Color(0xFF54A9DE),
    textPrimary: Color(0xFF000000),
    textSecondary: Color(0xFF707579),
    textMuted: Color(0xFFA2ACB4),
    divider: Color(0xFFE4E4E5),
    online: Color(0xFF0AC630),
    badge: Color(0xFF3390EC),
    danger: Color(0xFFE53935),
    glassTabSelected: Color(0xFF229AF0), // chat_messagePanelSend
    glassTabSelectedText: Color(0xFF229AF0),
    glassTabUnselected: Color(0xFF333333), // windowBackgroundWhiteBlackText
    isDark: false,
  );

  /// 复制一份并按需替换少数字段（其余沿用当前调色板）。
  TelegramPalette copyWith({
    Color? accent,
    Color? accentHover,
    Color? bgSelected,
    Color? bubbleOut,
    Color? bubbleOutTime,
    Color? badge,
  }) => TelegramPalette(
    bgApp: bgApp,
    bgSidebar: bgSidebar,
    bgChat: bgChat,
    bgHeader: bgHeader,
    bgGlassPanel: bgGlassPanel,
    bgInput: bgInput,
    bgHover: bgHover,
    bgSelected: bgSelected ?? this.bgSelected,
    bubbleOut: bubbleOut ?? this.bubbleOut,
    bubbleIn: bubbleIn,
    bubbleOutText: bubbleOutText,
    bubbleOutTime: bubbleOutTime ?? this.bubbleOutTime,
    accent: accent ?? this.accent,
    accentHover: accentHover ?? this.accentHover,
    textPrimary: textPrimary,
    textSecondary: textSecondary,
    textMuted: textMuted,
    divider: divider,
    online: online,
    badge: badge ?? this.badge,
    danger: danger,
    glassTabSelected: glassTabSelected,
    glassTabSelectedText: glassTabSelectedText,
    glassTabUnselected: glassTabUnselected,
    isDark: isDark,
  );
}

/// 按主题色派生一套调色板。
///
/// 跟 TG 的做法一致：暗色下自己气泡就跟着主题色走（默认紫，换蓝就变蓝）；
/// 亮色下自己气泡仍是浅绿（#EEFFDE），主题色只影响强调色/未读徽标/选中行。
TelegramPalette paletteWithAccent({required bool dark, required Color accent}) {
  final TelegramPalette base = dark
      ? TelegramPalette.dark
      : TelegramPalette.light;
  final Color hover = Color.lerp(accent, Colors.white, 0.22)!;
  final Color selected = dark
      ? Color.alphaBlend(accent.withValues(alpha: 0.30), base.bgApp)
      : accent;
  return base.copyWith(
    accent: accent,
    accentHover: hover,
    bgSelected: selected,
    badge: accent,
    bubbleOut: dark ? accent : null,
  );
}

/// 当前生效的调色板（默认暗色）。
///
/// ⚠️ 全局单例，见文件头"为什么是调色板持有者"。
class TelegramColors {
  static TelegramPalette _p = TelegramPalette.dark;

  /// 切换调色板（根组件按主题模式调用；测试也用它）。
  static void use(TelegramPalette p) => _p = p;

  /// 当前调色板（诊断/测试用）。
  static TelegramPalette get current => _p;

  /// 是否暗色（少数需要按明暗分叉画的地方用它，比如日期胶囊的底色）。
  static bool get isDark => _p.isDark;

  static Color get bgApp => _p.bgApp;
  static Color get bgSidebar => _p.bgSidebar;
  static Color get bgChat => _p.bgChat;
  static Color get bgHeader => _p.bgHeader;
  static Color get bgGlassPanel => _p.bgGlassPanel;
  static Color get bgInput => _p.bgInput;
  static Color get bgHover => _p.bgHover;
  static Color get bgSelected => _p.bgSelected;
  static Color get bubbleOut => _p.bubbleOut;
  static Color get bubbleIn => _p.bubbleIn;
  static Color get bubbleOutText => _p.bubbleOutText;
  static Color get bubbleOutTime => _p.bubbleOutTime;
  static Color get accent => _p.accent;
  static Color get accentHover => _p.accentHover;
  static Color get textPrimary => _p.textPrimary;
  static Color get textSecondary => _p.textSecondary;
  static Color get textMuted => _p.textMuted;
  static Color get divider => _p.divider;
  static Color get online => _p.online;
  static Color get badge => _p.badge;
  static Color get danger => _p.danger;

  /// 玻璃底栏三色，见 [TelegramPalette.glassTabSelected] 的文档注释。
  static Color get glassTabSelected => _p.glassTabSelected;
  static Color get glassTabSelectedText => _p.glassTabSelectedText;
  static Color get glassTabUnselected => _p.glassTabUnselected;

  /// 群聊里发送者名字的 7 色轮转（TG UserObject.java:212-216 的
  /// colorId = (int)(user.id % 7)，取 Theme.keys_avatar_nameInMessage 七色）。
  ///
  /// 顺序固定为 Red, Orange, Violet, Green, Cyan, Blue, Pink——**不能改序**，
  /// 否则同一个人的颜色会和官方对不上。两套真值直接抄主题文件，不做二次
  /// 提亮/混合（以前在暗色下往白 lerp 18%，等于凭空改了官方色，已删）。
  ///
  /// * dark：darkblue.attheme 的 avatar_nameInMessage[0..6]
  /// * light：day.attheme 只覆写 Violet/Pink/Blue 三个，其余取 ThemeColors
  ///   的 default 值（day.attheme 里没有这几项 = 用内置默认）
  static const List<Color> _nameColorsDark = <Color>[
    Color(0xFFE88878), // Red
    Color(0xFFE8AB5A), // Orange
    Color(0xFF8C8DEA), // Violet
    Color(0xFF7DD071), // Green
    Color(0xFF53CCC6), // Cyan
    Color(0xFF5CADEA), // Blue
    Color(0xFFE8749A), // Pink
  ];
  static const List<Color> _nameColorsLight = <Color>[
    Color(0xFFCC5049), // Red（default）
    Color(0xFFD67722), // Orange（default）
    Color(0xFF836FE6), // Violet（day.attheme 覆写）
    Color(0xFF40A920), // Green（default）
    Color(0xFF309EBA), // Cyan（default）
    Color(0xFF2586D6), // Blue（day.attheme 覆写）
    Color(0xFFCB4F86), // Pink（day.attheme 覆写）
  ];

  /// 当前主题下的七色表。
  static List<Color> get nameColors =>
      current.isDark ? _nameColorsDark : _nameColorsLight;

  /// 按发送者 id 取名字颜色；非数字 id 退强调色。
  static Color nameColorFor(String senderId) {
    final n = int.tryParse(senderId);
    if (n == null) return accent;
    return nameColors[n.abs() % nameColors.length];
  }
}

/// 尺寸规格（对齐现行 Telegram 客户端）
///
/// ## 数值出处（以官方 Android 源码为准，不凭感觉取整）
///
/// 2026-10-25 逐项抄自 `penguis/telegram-src/TelegramAndroid`：
///
/// | 项 | TG 出处 | 值 |
/// |---|---|---|
/// | 会话行高 | exteraGram `Cells/DialogCell.java:135` `heightDefault = 72` | 72 |
/// | 头像直径 | exteraGram `DialogCell.java:1881` `dp(54)` | 54 |
/// | 会话名 | `DialogCell.java:1252` `dialogs_namePaint = dp(17)` | 17 |
/// | 会话摘要 | `DialogCell.java:1254` `dialogs_messagePaint = dp(16)` | 16 |
/// | 会话时间 | `ActionBar/Theme.java:7897` `dialogs_timePaint = dp(12)` | 12 |
/// | 气泡正文 | `Theme.java:8035` `chat_msgTextPaint = dp(SharedConfig.fontSize)`，默认 16 | 16 |
/// | 气泡时间 | `Theme.java:8408` `chat_timePaint = dp(12)` | 12 |
///
/// 平板/折叠屏上 TG 会把正文字号抬到 18（`SharedConfig.java:613`
/// `isTablet() && !isFold() ? 18 : 16`），这里**不做设备分支**：本项目目标设备是
/// 手机，多一套分支只会让截图和测试期望对不上。
class TelegramMetrics {
  static const sidebarWidth = 320.0;
  static const headerHeight = 56.0;
  static const inputHeight = 48.0;

  /// 会话行高度（TG `DialogCell.java:172 heightDefault = dp(70)`；三行版 76）。
  static const chatRowHeight = 70.0;

  /// 头像直径（TG `DialogCell.java:2472` `dp(52)`；三行版 56）。
  static const avatarSize = 52.0;

  /// 会话列表：头像左内边距（TG `DialogCell.java:170 avatarStart = dp(11)`）。
  static const chatRowPadding = 11.0;

  /// 会话列表：头像右缘到文字区的间距。
  ///
  /// TG 的文字起点是 `dp(messagePaddingStart + 4)` = 76（`DialogCell.java:171/
  /// 1448`），76 − 11 − 52 = 13。
  static const chatAvatarGap = 13.0;

  /// 群聊里收到的消息旁的小头像。
  ///
  /// TG ChatMessageCell.java:1936 的 setRoundRadius(dp(21)) 即直径 42，
  /// 左留 6dp（:13839 setImageCoords(dp(6), y, dp(42), dp(42))）。
  static const bubbleAvatarSize = 42.0;

  /// 气泡圆角：三个角大、贴着自己那侧的下角小（TG 的"尾巴"感）。
  static const bubbleRadius = 17.0;
  static const bubbleTailRadius = 5.0;

  /// 输入框胶囊圆角。
  static const inputRadius = 20.0;

  /// 日期分隔胶囊的圆角与字号。
  ///
  /// 字号取 12 而不是 TG 服务消息的 14：TG 里日期与服务消息共用
  /// chat_actionTextPaint（ui/ActionBar/Theme.java:8129，尺寸 dp(max(16,fontSize)-2)=14），
  /// 但那是给"XX 加入了群聊"这类整行提示用的；日期胶囊只是弱化的时间分隔，
  /// 14 在中文字体下显得抢眼，这里跟会话列表时间（fontTimestamp=12）对齐。
  static const dateChipRadius = 12.0;
  static const fontDateChip = 12.0;

  static const fontBody = 16.0;
  static const fontTimestamp = 12.0;
  static const fontTitle = 17.0;
}

/// [useSystemFonts] 为 true（默认）时不指定 fontFamily，跟随机型系统字体；
/// 关掉则强制 Roboto，保证跨机型字形一致（抄 `ExteraConfig.useSystemFonts`）。
ThemeData buildTelegramTheme({bool dark = true, bool useSystemFonts = true}) {
  final p = dark ? TelegramPalette.dark : TelegramPalette.light;
  return ThemeData(
    useMaterial3: true,
    brightness: dark ? Brightness.dark : Brightness.light,
    scaffoldBackgroundColor: p.bgApp,
    colorScheme: dark
        ? ColorScheme.dark(
            primary: p.accent,
            surface: p.bgSidebar,
            onSurface: p.textPrimary,
            error: p.danger,
          )
        : ColorScheme.light(
            primary: p.accent,
            surface: p.bgSidebar,
            onSurface: p.textPrimary,
            error: p.danger,
          ),
    fontFamily: useSystemFonts ? null : 'Roboto',
    // TG 的列表行/按钮都有水波纹（RecyclerListView 的 SelectableBackground）。
    // 之前是 NoSplash，整个 App 点下去毫无反馈，像卡住了一样。
    splashFactory: InkRipple.splashFactory,
    hoverColor: p.bgHover,
    // 页面切换统一走 TG 观感（淡入 + 右侧轻推），而不是 Material 默认的
    // 缩放（ZoomPageTransitionsBuilder）——后者在深色主题下会露出一层白边，
    // 和"设置/登录页滑进来"的 TG 手感也完全不同。
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: TgPageTransitionsBuilder(),
        TargetPlatform.iOS: TgPageTransitionsBuilder(),
        TargetPlatform.macOS: TgPageTransitionsBuilder(),
        TargetPlatform.windows: TgPageTransitionsBuilder(),
        TargetPlatform.linux: TgPageTransitionsBuilder(),
        TargetPlatform.fuchsia: TgPageTransitionsBuilder(),
      },
    ),
  );
}

/// Telegram 风格的页面切换：淡入 + 从右侧轻推（220ms）。
///
/// 只影响"整页 push/pop"；列表/气泡之类的局部动画各有各的实现，
/// 别指望这一个类把全应用的动效都包了。
class TgPageTransitionsBuilder extends PageTransitionsBuilder {
  const TgPageTransitionsBuilder();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      // 前 70% 就把不透明度拉满：整段都在淡会显得"蒙一层灰"。
      opacity: CurvedAnimation(
        parent: animation,
        curve: const Interval(0, 0.7, curve: Curves.easeOut),
      ),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.08, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
