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
    this.showChevron,
  });

  final IconData icon;

  /// 图标槽底色；缺省 = 强调色 15% 透明（danger 时为危险色 15%）。
  final Color? iconBg;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;

  /// 是否显示右侧箭头。null = 自动：可点且没自带 trailing 时才显示
  /// （TG 的设置行只要可点就带 chevron，纯开关行不带）。
  final bool? showChevron;

  @override
  Widget build(BuildContext context) {
    final titleColor = danger
        ? TelegramColors.danger
        : TelegramColors.textPrimary;
    final subColor = danger
        ? TelegramColors.danger.withValues(alpha: 0.7)
        : TelegramColors.textSecondary;
    final slotColor =
        iconBg ??
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
            ] else if (showChevron ?? (onTap != null)) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: TelegramColors.textMuted,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 一行「人」（群成员、联系人、选择成员等）。
///
/// 几何抄 ui/Cells/UserCell.java 的**两种模式**：
/// - 默认（群成员等）：行高 58dp（:497）、头像 46dp 圆角 24 左距 7
///   （:182/:183）、名字 16dp bold 从 x=64 起（:189/:191）、状态 15dp 在
///   top 32（:197/:199）。
/// - [compact]（联系人页）：UserCell:479-497 的 callCellStyle 分支——行高
///   56dp、头像 44dp 圆角 22、名字 15sp、状态 13sp，文字起点仍是 64。
/// 这里用 Row 垂直居中而不是绝对定位，视觉等价、更好排版；7 + 46 + 11 = 64
/// 即官方文字起点。
///
/// 官方 cell **没有右侧箭头**（UserCell.java 全文只有 checkbox / 右侧图标
/// 槽，没有 chevron），靠 ripple 表达可点，所以这里也不画 ▸。
class TgUserRow extends StatelessWidget {
  const TgUserRow({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.compact = false,
  });

  /// 联系人页的紧凑行（UserCell 的 callCellStyle）：56 高、15/13 字号。
  final bool compact;

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
        height: compact ? 56 : 58,
        padding: const EdgeInsets.only(left: 7, right: 12),
        child: Row(
          children: <Widget>[
            leading,
            // UserCell 默认文字 x=64（头像 46 + 间隔 11）；callCellStyle 是
            // 44 头像 + 15 间隔 = x 66（UserCell.java:479-490）。
            SizedBox(width: compact ? 15 : 11),
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
                      fontSize: compact ? 15 : 16,
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
                        fontSize: compact ? 13 : 15,
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

/// 分组/字母分隔条：ui/Cells/LetterSectionCell.java 的几何。
///
/// * 尺寸 76×64dp —— :30 `new ViewGroup.LayoutParams(dp(12 + 64), dp(64))`；
/// * 文字 22sp bold、颜色 key_windowBackgroundWhiteGrayText4、左内边距 12dp、
///   垂直居中（:33-37）。
///
/// 官方按首字母分组；QQ 没有字母索引，这里显示好友分组名。
class TgLetterHeader extends StatelessWidget {
  const TgLetterHeader(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.only(left: 12, right: 12),
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: TelegramColors.textMuted,
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
    final color = highlight
        ? TelegramColors.accent
        : TelegramColors.textSecondary;
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

/// 设置项图标的渐变底色：ui/Components/IconBackgroundColors.java:4-16 的
/// 真值，官方用 GradientDrawable orientation TOP_BOTTOM（上→下），
/// 套在 SettingCell 的 28×28 圆角 10 图标块里（SettingsActivity.java:1216-1292）。
class TgIconGradients {
  const TgIconGradients._();

  static const List<Color> blue = <Color>[Color(0xFF1CA5ED), Color(0xFF1488E1)];
  static const List<Color> blueAlt = <Color>[
    Color(0xFF1CA5ED),
    Color(0xFF1387E1),
  ];
  static const List<Color> blueDeep = <Color>[
    Color(0xFF4F85F6),
    Color(0xFF3568E8),
  ];
  static const List<Color> blueLight = <Color>[
    Color(0xFF1BA4ED),
    Color(0xFF1488E1),
  ];
  static const List<Color> orange = <Color>[
    Color(0xFFF09F1B),
    Color(0xFFE18A11),
  ];
  static const List<Color> orangeDeep = <Color>[
    Color(0xFFF28B31),
    Color(0xFFE26314),
  ];
  static const List<Color> green = <Color>[Color(0xFF55CA47), Color(0xFF27B434)];
  static const List<Color> red = <Color>[Color(0xFFF45255), Color(0xFFDF3955)];
  static const List<Color> cyan = <Color>[Color(0xFF32C0CE), Color(0xFF1D9CC6)];
  static const List<Color> purple = <Color>[Color(0xFFC46EF4), Color(0xFF9F55DF)];
  static const List<Color> gray = <Color>[Color(0xFF8699AA), Color(0xFF6E8397)];
}

/// 设置行：ui/SettingsActivity.java 的 SettingCell（新版 UItem 体系）。
///
/// * 行高 `dp(mini ? 44 : twoLines ? 60 : 50)`（:1264）—— 有副标题即 60；
/// * 图标块 28×28、左距 18（:1218，mini 时 9）；
/// * 文字左 18、右 20（:1219）；右侧值右距 20（:1220）；
/// * **右侧值文字是蓝色** key_windowBackgroundWhiteBlueText（:1229），
///   不是旧 TextCell 体系的灰色；
/// * **SettingCell 本身没有 chevron**（全文只有 AccountCell 在 :1054-1074
///   画 msg_arrowright），所以本行不画右箭头。
class TgSettingRow extends StatelessWidget {
  const TgSettingRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.iconGradient,
    this.danger = false,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// 图标块的上下渐变底色（官方九项各有配色，见 [TgIconGradients]）。
  /// 有值时图标转白；缺省仍是强调色 15% 平的圆角块。
  final List<Color>? iconGradient;

  /// 右侧蓝色值文字（对应 SettingCell 的 valueView）。
  final String? value;
  final bool danger;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Color titleColor = danger
        ? TelegramColors.danger
        : TelegramColors.textPrimary;
    final Color iconColor = danger
        ? TelegramColors.danger
        : TelegramColors.accent;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(minHeight: subtitle == null ? 50 : 60),
        padding: const EdgeInsets.only(left: 18, right: 20, top: 6, bottom: 6),
        child: Row(
          children: <Widget>[
            Container(
              // 固定 key 只为测试量几何；同层兄弟里唯一即可。
              key: const ValueKey<String>('setting-row-icon'),
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                // 圆角 10（SettingsActivity.java:1216 dp(10)）。
                borderRadius: BorderRadius.circular(10),
                color: iconGradient == null
                    ? iconColor.withValues(alpha: 0.15)
                    : null,
                gradient: iconGradient == null
                    ? null
                    : LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: iconGradient!,
                      ),
              ),
              // 图标 24×24 FIT_CENTER（:1218）；渐变块上的图标是白的。
              child: Icon(
                icon,
                size: 24,
                color: iconGradient == null ? iconColor : Colors.white,
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, color: titleColor),
                  ),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: TelegramColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (value != null) ...<Widget>[
              const SizedBox(width: 8),
              Text(
                value!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 16, color: TelegramColors.accent),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 「标题 + 值」两行资料行：ui/Cells/TextDetailCell.java。
///
/// * 最小行高 60dp（:82/:147 `setMinimumHeight(dp(60))`，实测 60+1dp 分割线）；
/// * 标题 16dp（:79），值 13dp（:117）；
/// * 分割线左右各缩进 20dp（:275-277），与 TextCell 的 58 缩进不同。
///
/// 官方「我的资料」页的 QQ 号/昵称就是这种行（ProfileActivity.java:14375
/// 把 phoneRow 映射成 VIEW_TYPE_TEXT_DETAIL）。
class TgTextDetailRow extends StatelessWidget {
  const TgTextDetailRow({
    super.key,
    required this.title,
    required this.value,
    this.onTap,
  });

  final String title;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 60),
        padding: const EdgeInsets.only(left: 20, right: 20, top: 8, bottom: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 16, color: TelegramColors.textPrimary),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: TelegramColors.textSecondary,
              ),
            ),
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
    this.dividerIndent = 62,
    this.inset = 16,
    this.radius = 12,
  });

  final List<Widget> children;
  final bool divided;

  /// 卡片左右内缩。官方设置页每条 section 内缩 12dp
  /// （UniversalRecyclerView.java:430-431、RecyclerListView.java:3394）。
  final double inset;

  /// 卡片圆角。官方设置段卡 16dp（RecyclerListView.java:3289/:3616-3618）。
  final double radius;

  /// 行间分割线的左缩进。TextCell 体系是 62（图标槽 + 缝隙），
  /// TextDetailCell 体系是 20（TextDetailCell.java:275-277）。
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (divided && i != children.length - 1) {
        rows.add(
          Container(
            height: 1,
            margin: EdgeInsets.only(left: dividerIndent),
            color: TelegramColors.divider,
          ),
        );
      }
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inset),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
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
