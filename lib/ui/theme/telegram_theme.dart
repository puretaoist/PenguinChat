/// L4 表现层：主题定义
///
/// 配色取样自 Telegram Desktop，语义与官方客户端对齐。
/// 与 assets/theme.json 保持同步；此处用 Dart 常量便于编译期使用与 IDE 补全。
library;

import 'package:flutter/material.dart';

class TelegramColors {
  // 暗色主题（主用）
  static const bgApp = Color(0xFF0E1621);
  static const bgSidebar = Color(0xFF17212B);
  static const bgChat = Color(0xFF0E1621);
  static const bgHeader = Color(0xFF17212B);
  static const bgInput = Color(0xFF17212B);
  static const bgHover = Color(0xFF202B36);
  static const bgSelected = Color(0xFF2B5278);

  static const bubbleOut = Color(0xFF2B5278);
  static const bubbleIn = Color(0xFF182533);

  static const accent = Color(0xFF5288C1);
  static const accentHover = Color(0xFF6FA8DC);

  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFF7F91A4);
  static const textMuted = Color(0xFF5C6B7A);

  static const divider = Color(0xFF101921);
  static const online = Color(0xFF4DCD5E);
  static const badge = Color(0xFF5288C1);
}

/// 尺寸规格（对齐 Telegram Desktop 桌面端标准）
class TelegramMetrics {
  static const sidebarWidth = 300.0;
  static const headerHeight = 56.0;
  static const inputHeight = 48.0;
  static const bubbleRadius = 12.0;
  static const inputRadius = 18.0;
  static const avatarSize = 46.0;
  static const fontBody = 14.0;
  static const fontTimestamp = 11.0;
  static const fontTitle = 15.0;
}

ThemeData buildTelegramTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: TelegramColors.bgApp,
    colorScheme: const ColorScheme.dark(
      primary: TelegramColors.accent,
      surface: TelegramColors.bgSidebar,
      onSurface: TelegramColors.textPrimary,
    ),
    fontFamily: 'Roboto',
    splashFactory: NoSplash.splashFactory,
  );
}
