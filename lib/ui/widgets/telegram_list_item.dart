/// L4 表现层：Telegram 设置页风格的基础列表组件。
///
/// 出处：telegram-src/TelegramAndroid 新版设置页（2021 改版后的分组卡片
/// 样式）。三个组件各对应一个官方 Cell：
/// - [TelegramSectionHeader] ← ui/Cells/HeaderCell.java
/// - [TgListTile]            ← ui/Cells/TextCell.java
/// - [TelegramTileGroup]     ← 分组卡片容器（现代 TG 白卡圆角 12）
///
/// 几何数值一律注明 Java 源码行号；颜色一律走 [TelegramColors]，
/// 本文件不新增硬编码色值。
library;

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';

/// 分组标题。
///
/// 几何抄 HeaderCell.java：高 40（:44），左 padding 20 / topMargin 7
/// （:49），文字 14dp bold（:94-95），颜色
/// key_windowBackgroundWhiteBlueHeader（官方蓝色标题 → 我们的
/// [TelegramColors.accent]）。
class TelegramSectionHeader extends StatelessWidget {
  const TelegramSectionHeader({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 20, top: 7),
      alignment: Alignment.bottomLeft,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: TelegramColors.accent,
        ),
      ),
    );
  }
}

/// 设置行。官方 TextCell.java：行高 50dp（:64）、imageLeft=16（:65）、
/// 文字起点偏移 58（:63，官方图标 24dp；这里用 40dp 圆角图标槽 +
/// 6 缝隙 → 16+40+6=62，视觉对齐官方新版设置页的"彩色圆角方块图标"）。
///
/// [subtitle] 有值时自然增高（官方单行版没有副标题行，双行更实用）；
/// [danger] 置危险色（如"断开连接"），图标槽底色随内容变红。
class TgListTile extends StatelessWidget {
  const TgListTile({
    super.key,
    required this.icon,
    this.iconBg,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.danger = false,
  });

  final IconData icon;

  /// 图标槽底色；缺省 = 强调色 15% 透明（danger 时为危险色 15%）。
  final Color? iconBg;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final titleColor =
        danger ? TelegramColors.danger : TelegramColors.textPrimary;
    final subColor = danger
        ? TelegramColors.danger.withValues(alpha: 0.7)
        : TelegramColors.textSecondary;
    final slotColor = iconBg ??
        (danger
            ? TelegramColors.danger.withValues(alpha: 0.15)
            : TelegramColors.accent.withValues(alpha: 0.15));

    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 50),
        padding: const EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 8),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: slotColor,
              ),
              child: Icon(
                icon,
                size: 22,
                color: danger ? TelegramColors.danger : TelegramColors.accent,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, color: titleColor),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: subColor),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 一行「人」（群成员、选择成员等）。
///
/// 几何抄 ui/Cells/UserCell.java：行高 58dp（:497）、头像 46dp 圆角 24 左距 7
/// （:182/:183）、名字 16dp bold 从 x=64 起（:189/:191）、状态 15dp 在 top 32
/// （:197/:199）。这里用 Row 垂直居中而不是绝对定位，视觉等价、更好排版；
/// 7 + 46 + 11 = 64 即官方文字起点。
class TgUserRow extends StatelessWidget {
  const TgUserRow({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  /// 头像位（官方 46x46；调用方给 TelegramAvatar(size: 46)）。
  final Widget leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 58,
        padding: const EdgeInsets.only(left: 7, right: 12),
        child: Row(
          children: <Widget>[
            leading,
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: TelegramColors.textPrimary,
                    ),
                  ),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        color: TelegramColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: 8),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 一行「文件」（群文件等）。
///
/// 几何抄 ui/Cells/SharedDocumentCell.java：行高 64dp（:615）、左侧 42dp 圆形
/// 图标（:280 createCircleDrawableWithIcon）、文字从 x=72 起（:543/:588）、
/// 文件名 16（:163）、副标题 13（:198）。16 + 42 + 14 = 72。
class TgFileRow extends StatelessWidget {
  const TgFileRow({
    super.key,
    required this.icon,
    this.highlight = false,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;

  /// 目录用强调色（官方文件夹图标是蓝的），普通文件用次要色。
  final bool highlight;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color =
        highlight ? TelegramColors.accent : TelegramColors.textSecondary;
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 64,
        padding: const EdgeInsets.only(left: 16, right: 8),
        child: Row(
          children: <Widget>[
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.15),
              ),
              child: Icon(icon, size: 22, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      color: TelegramColors.textPrimary,
                    ),
                  ),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: TelegramColors.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: 8),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 一行「会话」（转发目标、搜索结果等），几何同会话列表 DialogCell：
/// 行高 70（:172 heightDefault）、头像 52、文字起点 72（:171 messagePaddingStart）、
/// 标题 17（:1252）、摘要 16（:1254）。
class TgChatRow extends StatelessWidget {
  const TgChatRow({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        constraints: const BoxConstraints(minHeight: 70),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        child: Row(
          children: <Widget>[
            leading,
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: TelegramColors.textPrimary,
                    ),
                  ),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        color: TelegramColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: 8),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}
/// 分组卡片：现代 TG 设置页的圆角 12 卡 + 行间 1px 分隔线（分隔线缩进
/// 到文字起点再画到右缘，同 TextCell.java needDivider 的画法；缩进
/// 62 = 16 左距 + 40 图标槽 + 6 缝隙，即 TgListTile 的文字起点）。
class TelegramTileGroup extends StatelessWidget {
  const TelegramTileGroup({
    super.key,
    required this.children,
    this.divided = true,
  });

  final List<Widget> children;
  final bool divided;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (divided && i != children.length - 1) {
        rows.add(Container(
          height: 1,
          margin: const EdgeInsets.only(left: 62),
          color: TelegramColors.divider,
        ));
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: TelegramColors.bgSidebar,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          ),
        ),
      ),
    );
  }
}
