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
