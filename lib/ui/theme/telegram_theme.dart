/// L4 表现层：主题（暗/亮两套调色板 + 切换）
///
/// 配色对齐**现代 Telegram**（2021 改版后沿用至今的那套）：暗色 = 紫色自己气泡 +
/// 深灰面板；亮色 = `#3390EC` 主题 + 浅绿自己气泡。与 `assets/theme.json` 同步。
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

  const TelegramPalette({
    required this.bgApp,
    required this.bgSidebar,
    required this.bgChat,
    required this.bgHeader,
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
  });

  /// 暗色（Night，现行版）。
  static const dark = TelegramPalette(
    bgApp: Color(0xFF0F0F0F),
    bgSidebar: Color(0xFF212121),
    bgChat: Color(0xFF0F0F0F),
    bgHeader: Color(0xFF212121),
    bgInput: Color(0xFF212121),
    bgHover: Color(0xFF2B2B2B),
    bgSelected: Color(0xFF3B3357),
    bubbleOut: Color(0xFF8774E1),
    bubbleIn: Color(0xFF212121),
    bubbleOutText: Color(0xFFFFFFFF),
    bubbleOutTime: Color(0x99FFFFFF),
    accent: Color(0xFF8774E1),
    accentHover: Color(0xFF9C8CEB),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFFAAAAAA),
    textMuted: Color(0xFF717171),
    divider: Color(0xFF2F2F2F),
    online: Color(0xFF0AC630),
    badge: Color(0xFF8774E1),
    danger: Color(0xFFFF5C5C),
  );

  /// 亮色（Day，现行版）。
  static const light = TelegramPalette(
    bgApp: Color(0xFFFFFFFF),
    bgSidebar: Color(0xFFFFFFFF),
    bgChat: Color(0xFFE6EBEE),
    bgHeader: Color(0xFFFFFFFF),
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

  static Color get bgApp => _p.bgApp;
  static Color get bgSidebar => _p.bgSidebar;
  static Color get bgChat => _p.bgChat;
  static Color get bgHeader => _p.bgHeader;
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
}

/// 尺寸规格（对齐现行 Telegram 客户端）
class TelegramMetrics {
  static const sidebarWidth = 320.0;
  static const headerHeight = 56.0;
  static const inputHeight = 48.0;

  /// 会话行高度（现行版列表行更高、头像更大）。
  static const chatRowHeight = 72.0;
  static const avatarSize = 54.0;

  /// 群聊里收到的消息旁的小头像。
  static const bubbleAvatarSize = 34.0;

  /// 气泡圆角：三个角大、贴着自己那侧的下角小（TG 的"尾巴"感）。
  static const bubbleRadius = 16.0;
  static const bubbleTailRadius = 6.0;

  /// 输入框胶囊圆角。
  static const inputRadius = 20.0;

  /// 日期分隔胶囊的圆角与字号。
  static const dateChipRadius = 12.0;
  static const fontDateChip = 12.0;

  static const fontBody = 14.5;
  static const fontTimestamp = 11.0;
  static const fontTitle = 15.0;
}

ThemeData buildTelegramTheme({bool dark = true}) {
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
    fontFamily: 'Roboto',
    splashFactory: NoSplash.splashFactory,
  );
}
