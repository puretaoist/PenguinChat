/// L4 共享页头：四个 Tab（聊天/联系人/设置/我的）用同一套几何。
///
/// 之前每个页面各写一遍 `Container(height: 56, color: bgHeader)`，字体/左右
/// 内边距/副标题位置都各写各的，切 Tab 时标题会轻微跳动。这里收成一处，
/// 依据 Telegram Android `ActionBar` 的默认高度（56dp）+ 标题 20sp w600。
/// **已停用**：四个 Tab 与四个二级设置页都改用 [TgActionBar]（复刻官方
/// ActionBar 的高度/字号/状态栏规则）。本文件暂无使用点，保留只为避免
/// 一次性删除引发无关 diff，确认后删除。
library;

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';

class TgPageHeader extends StatelessWidget {
  const TgPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing = const <Widget>[],
    this.onBack,
    this.showBack = false,
  });

  final String title;

  /// 标题右侧的次要文字（例如联系人页的人数）。
  final String? subtitle;

  /// 右侧操作区（图标按钮）。间距统一 4。
  final List<Widget> trailing;

  final VoidCallback? onBack;

  /// 作为 Tab 根视图时为 false（不能画返回箭头）；被 push 打开时为 true。
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: TelegramMetrics.headerHeight,
      color: TelegramColors.bgHeader,
      padding: EdgeInsets.only(left: showBack ? 4 : 16, right: 8),
      child: Row(
        children: <Widget>[
          if (showBack)
            IconButton(
              onPressed: onBack ?? () => Navigator.of(context).maybePop(),
              icon: Icon(Icons.arrow_back, color: TelegramColors.textSecondary),
              tooltip: '返回',
            ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: TelegramColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: TelegramColors.textSecondary,
                      fontSize: 15,
                    ),
                  ),
                ],
              ],
            ),
          ),
          for (final w in trailing)
            Padding(padding: const EdgeInsets.only(left: 4), child: w),
        ],
      ),
    );
  }
}
