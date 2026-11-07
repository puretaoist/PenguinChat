/// L4 共享 ActionBar：按 Telegram Android `ui/ActionBar/ActionBar.java` 复刻。
///
/// 本类已取代旧的 TgPageHeader（恒 56dp / 20sp / 不带状态栏占位的简化页头，
/// 现无任何使用点）。复刻 ActionBar 的真实规则：
///
/// * 高度：竖屏 56dp、横屏 48dp（`ActionBar.getCurrentActionBarHeight()`，
///   ActionBar.java:1914；竖/横的取值见 :769 附近的 `barHeight` 计算）。
/// * 标题：竖屏 20sp、横屏 18sp（ActionBar.java:654 / :1455）。
/// * 高度含状态栏：`setMeasuredDimension(width, actionBarHeight +
///   (occupyStatusBar ? AndroidUtilities.statusBarHeight : 0))`
///   （ActionBar.java:1400）。edgeToEdge 之后我们同样把状态栏高度算进这块
///   背景里，标题落在状态栏下方居中。
/// * 右侧按钮：触摸区 48dp、图标 24dp、按下是圆形 selector
///   （ActionBar.java:270 的触摸区、:3175 的 actionBarDefaultSelector）。
/// * 头部阴影不是常驻的：列表滚出 5dp 之后才画（DialogsActivity.java:4607-4608
///   计算 shadowVisible、:14368-14369 用 `drawHeaderShadow` 画 3dp 贴图），
///   这部分由使用方的滚动监听负责，本组件只负责条本身。
library;

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';

class TgActionBar extends StatelessWidget {
  const TgActionBar({
    super.key,
    required this.title,
    this.actions = const <Widget>[],
    this.topInset = 0,
    this.onBack,
    this.subtitle,
    this.transparent = false,
  });

  final String title;

  /// 右侧操作区。用 [TgActionBar.iconButton] 造，保证 48dp 触摸区一致。
  final List<Widget> actions;

  /// 状态栏高度。背景会被这条 padding 顶到屏幕顶端。
  final double topInset;

  /// 非 null 时左侧画返回箭头（Tab 根视图传 null）。
  final VoidCallback? onBack;

  /// 标题下方的副标题（ActionBar 的 overlay title 两行形态，例如联系人页的
  /// 联系人数量）。为 null 时标题单独垂直居中，与原先完全一致。
  final String? subtitle;

  /// 背景是否透明。官方「我的资料」页的 ActionBar 是
  /// `setBackgroundColor(Color.TRANSPARENT)` + `setBackground(null)`
  /// （ProfileActivity.java:2488-2500），头像区直接铺到状态栏后面。
  final bool transparent;

  /// 竖屏 56 / 横屏 48。
  static double heightOf(BuildContext context) {
    final Size size = MediaQuery.sizeOf(context);
    return size.width > size.height ? 48.0 : 56.0;
  }

  /// 竖屏 20 / 横屏 18。
  static double titleSizeOf(BuildContext context) {
    final Size size = MediaQuery.sizeOf(context);
    return size.width > size.height ? 18.0 : 20.0;
  }

  /// 48dp 触摸区 + 24dp 图标 + 圆形水波纹（IconButton 的默认形状就是这个）。
  static Widget iconButton({
    Key? key,
    required IconData icon,
    required VoidCallback onPressed,
    String? tooltip,
  }) {
    return IconButton(
      key: key,
      onPressed: onPressed,
      iconSize: 24,
      color: TelegramColors.textSecondary,
      tooltip: tooltip,
      icon: Icon(icon),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: transparent ? Colors.transparent : TelegramColors.bgHeader,
      padding: EdgeInsets.only(top: topInset),
      child: SizedBox(
        height: heightOf(context),
        child: Row(
          children: <Widget>[
            if (onBack != null)
              iconButton(
                icon: Icons.arrow_back,
                onPressed: onBack!,
                tooltip: '返回',
              ),
            Expanded(
              child: Padding(
                // 有返回箭头时按钮自带内边距，标题不用再让 16。
                padding: EdgeInsets.only(left: onBack == null ? 16 : 2),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: TelegramColors.textPrimary,
                        fontSize: titleSizeOf(context),
                        // ActionBar 的标题是常规字重（SimpleTextView 默认），
                        // 之前这里用 w600 会显得比官方"胖"一圈。
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    // 官方副标题挂在 overlay title 容器里，比标题小一圈
                    // （ContactsActivity.java:990-999）。
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: TelegramColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            for (final Widget action in actions)
              Padding(padding: const EdgeInsets.only(left: 2), child: action),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}
