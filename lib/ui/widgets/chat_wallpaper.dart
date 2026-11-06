/// L4 表现层：聊天背景（预设渐变）。
///
/// 不用图片资源：APK 里塞一张 1080x2400 的壁纸要几 MB，而预设渐变在
/// 任何一种分辨率下都清晰、不糊、不吃内存。想要图片壁纸是下一步的事。
library;

import 'package:flutter/material.dart';

import '../prefs/ui_prefs.dart';
import '../theme/telegram_theme.dart';

/// 一个可选聊天背景。
class ChatWallpaper {
  const ChatWallpaper({required this.id, required this.colors});

  final String id;

  /// 上下渐变的两端颜色；空列表 = 纯色（跟随主题的 bgChat）。
  final List<Color> colors;

  /// 是否纯色（默认档）。
  bool get isPlain => colors.isEmpty;

  /// 人话名（来自 UiPrefs.wallpaperLabel）。
  String get name => UiPrefs.wallpaperLabel(id);
}

/// 全部可选聊天背景（'plain' 必须排第一 = 默认）。
const List<ChatWallpaper> wallpaperChoices = <ChatWallpaper>[
  ChatWallpaper(id: 'plain', colors: <Color>[]),
  ChatWallpaper(
    id: 'dusk',
    colors: <Color>[Color(0xFF1E1B2E), Color(0xFF3A2E4F)],
  ),
  ChatWallpaper(
    id: 'forest',
    colors: <Color>[Color(0xFF10261B), Color(0xFF1E4433)],
  ),
  ChatWallpaper(
    id: 'ocean',
    colors: <Color>[Color(0xFF0A2233), Color(0xFF15496B)],
  ),
  ChatWallpaper(
    id: 'sunset',
    colors: <Color>[Color(0xFF331E2B), Color(0xFF6E3A2E)],
  ),
];

/// 按 id 取背景；认不出的 id 回默认纯色，不抛异常。
ChatWallpaper wallpaperOf(String id) => wallpaperChoices.firstWhere(
  (ChatWallpaper w) => w.id == id,
  orElse: () => wallpaperChoices.first,
);

/// 聊天区背景：按 [wallpaperId] 画渐变，纯色档直接铺 TelegramColors.bgChat。
///
/// 只做背景，不改任何前景色：气泡本身都是不透明底，换背景不会影响可读性。
class ChatWallpaperBackground extends StatelessWidget {
  const ChatWallpaperBackground({
    super.key,
    this.wallpaperId = 'plain',
    required this.child,
  });

  final String wallpaperId;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ChatWallpaper w = wallpaperOf(wallpaperId);
    if (w.isPlain) {
      return ColoredBox(color: TelegramColors.bgChat, child: child);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: w.colors,
        ),
      ),
      child: child,
    );
  }
}
