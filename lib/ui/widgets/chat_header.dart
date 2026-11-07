import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../client_api/objects.dart';
import '../theme/telegram_theme.dart';
import 'glass_surface.dart';
import 'search_field_box.dart';
import 'telegram_avatar.dart';

/// 聊天页头部——**三块悬浮玻璃胶囊**，不是一整条通栏。
///
/// 几何 100% 抄官方（C:/Users/Administrator/penguis/telegram-src/
/// TelegramAndroid/TMessagesProj/src/main/java/org/telegram/ui/ActionBar/
/// ActionBar.java:2232-2280 dispatchDraw()，玻璃模式下胶囊几何的唯一来源）：
///   p = dp(6); s = dp(46); 高 = s + 2p = 58; 圆角 setRadius(dp(23))(:226/:228)
///   左（返回）: setBounds(0, t, s + p*2, b)                    → 宽 58
///   右（菜单）: setBounds(W - max(s, menuWidth) - p*2, t, W, b) → 宽 max(46,menuWidth)+12
///   中（头像+标题）: 宽 = min(W-106, 文字宽+82)，在 [s+p=52, W-(menuWidth+p)] 内居中
///     —— 见 :2246-2256 与 ChatAvatarContainer.getVisualWidth()(:1718-1732)
///   三块之间是「左右各重叠 p=6」的关系，不是用 Row 均分/拉满。
///
/// 头像 40（ChatAvatarContainer.java:668 dp(42)-2）、标题 17.5 / 副标题 13.5
/// （:756-765 setGlassMode）、头像左 9（:767-774 onLayout 1+leftPadding）、
/// 头像到文字 ≈9.66（57.66 - 8 - 40），文字右余量 18（getVisualWidth 的 dp(52+18)）。
class ChatHeader extends StatelessWidget {
  const ChatHeader({
    super.key,
    required this.chat,
    this.onBack,
    this.onOpenMembers,
    this.onOpenGroupFiles,
    this.onOpenGroupSettings,
    this.onOpenSettings,
    this.onSearch,
    this.searching = false,
    this.searchController,
    this.searchFocus,
    this.onExitSearch,
    this.onSearchChanged,
    this.hideStatus = false,
    this.centerTitle = false,
  });

  final Chat chat;
  final VoidCallback? onBack;
  final VoidCallback? onOpenMembers;
  final VoidCallback? onOpenGroupFiles;
  final VoidCallback? onOpenGroupSettings;
  final VoidCallback? onOpenSettings;

  /// 头部搜索（TG 顶栏右侧第一个图标就是放大镜）。
  final VoidCallback? onSearch;

  /// 是否处于搜索态。
  ///
  /// 官方是 ActionBar **原地变形**：藏掉头像 + 标题（`headerItem`）、附件
  /// （`attachItem`）、右侧菜单（`otherIcon`）与输入框（`editTextItem`），
  /// 只留搜索框和左侧那个会从放大镜形变成返回箭头的按钮
  /// （`ChatActivity.java:35364-35409`，`openSearchWithText`）。
  /// 这里保留左侧胶囊的几何，把搜索框铺满它右边——官方展开后 ActionBar
  /// 就只剩这两件东西，高度不变（`ActionBarMenuItem.toggleSearch` 是
  /// 150ms 的 alpha 交叉，没有宽度动画）。
  final bool searching;

  /// 搜索态的输入控制器与焦点（[searching] 为真时必须提供）。
  final TextEditingController? searchController;
  final FocusNode? searchFocus;

  /// 搜索态左侧按钮：退出搜索。
  final VoidCallback? onExitSearch;

  /// 搜索词变化（官方边输入边搜 `searchMessagesInChat`）。
  final ValueChanged<String>? onSearchChanged;

  /// 是否隐藏副标题（在线状态 / 成员数）。抄 `ExteraConfig.hideActionBarStatus`。
  final bool hideStatus;

  /// 标题是否居中。抄 `ExteraConfig.centerTitle`。
  final bool centerTitle;

  @override
  Widget build(BuildContext context) {
    // 全部单位 dp，数值来自上述官方源码。
    const double p = 6.0; // ActionBar.java:2232 dp(6)
    const double s = 46.0; // :2232 dp(46)
    const double capsuleH = s + 2 * p; // 58，与 s+2p 一致

    if (searching && searchController != null && searchFocus != null) {
      return SizedBox(
        height: capsuleH,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned(
              left: 0,
              top: 0,
              width: capsuleH,
              height: capsuleH,
              child: GlassSurface.capsule(
                radius: 23,
                alignment: Alignment.center,
                padding: EdgeInsets.zero,
                child: IconButton(
                  key: const ValueKey<String>('chat-search-back'),
                  onPressed: onExitSearch,
                  tooltip: '退出搜索',
                  icon: Icon(
                    Icons.arrow_back,
                    color: TelegramColors.textSecondary,
                    size: 24,
                  ),
                ),
              ),
            ),
            Positioned(
              left: capsuleH,
              right: p,
              top: 0,
              height: capsuleH,
              child: Center(
                child: SearchFieldBox(
                  controller: searchController!,
                  focusNode: searchFocus!,
                  height: 46,
                  radius: 23,
                  hintText: '搜索本会话',
                  onChanged: onSearchChanged,
                  onCleared: () => onSearchChanged?.call(''),
                ),
              ),
            ),
          ],
        ),
      );
    }
    const double iconSlot = 48.0; // 官方每个 action item 占 48dp（menuWidth）
    const double leftDefault = s + p; // 52，中胶囊左界（:2249）

    final int menuItems =
        (onSearch != null ? 1 : 0) +
        (chat.isGroup ? 1 : (onOpenSettings != null ? 1 : 0));
    final double menuWidth = menuItems * iconSlot;
    final double menuCapsuleW = (menuWidth > s ? menuWidth : s) + 2 * p;
    final double rightOffset = menuWidth + p; // 中胶囊右界让出菜单宽 + p

    final TextStyle titleStyle = TextStyle(
      color: TelegramColors.textPrimary,
      fontSize: 17.5, // ChatAvatarContainer.java:759 setGlassMode
      fontWeight: FontWeight.w700,
    );
    final TextStyle subStyle = TextStyle(
      color: chat.online ? TelegramColors.online : TelegramColors.textSecondary,
      fontSize: 13.5, // :762
    );
    final String subText = chat.isGroup
        ? '群聊 · ${chat.memberCount} 人'
        : (chat.online ? '在线' : '离线');

    return SizedBox(
      height: capsuleH,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          final double w = c.maxWidth;
          final double rightDefault = w - rightOffset;
          // 不压住左右胶囊的可用宽度。官方允许中胶囊最宽到 W-106（会压住
          // 返回/菜单），这里取更保守的 W-52-rightOffset，长标题靠省略号。
          final double maxMiddle = w - leftDefault - rightOffset;
          final double textW = math.max(
            _measure(context, chat.title, titleStyle),
            hideStatus ? 0.0 : _measure(context, subText, subStyle),
          );
          // 官方 getVisualWidth 有头像时加 dp(52+18)=70，再 +2p(12) 得胶囊宽。
          final double desired = textW + 82.0;
          final double middleW = math.min(
            maxMiddle > 0 ? maxMiddle : 0.0,
            desired,
          );
          final double centered = (rightDefault + leftDefault - middleW) / 2;
          final double middleLeft = centered < leftDefault
              ? leftDefault
              : centered;

          return Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              if (onBack != null)
                Positioned(
                  left: 0,
                  top: 0,
                  width: capsuleH, // 官方 s+p*2 = 58，正方形
                  height: capsuleH,
                  child: GlassSurface.capsule(
                    radius: 23,
                    alignment: Alignment.center,
                    padding: EdgeInsets.zero,
                    child: IconButton(
                      onPressed: onBack,
                      tooltip: '返回',
                      icon: Icon(
                        Icons.arrow_back,
                        color: TelegramColors.textSecondary,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: middleLeft,
                top: 0,
                width: middleW,
                height: capsuleH,
                child: GlassSurface.capsule(
                  radius: 23,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.only(left: 8, right: 18),
                  child: GestureDetector(
                    key: const ValueKey('open-members'),
                    onTap: chat.isGroup ? onOpenMembers : null,
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      children: <Widget>[
                        TelegramAvatar(
                          name: chat.title,
                          url: chat.avatarUrl,
                          size: 40,
                        ),
                        const SizedBox(width: 9.66),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: centerTitle
                                ? CrossAxisAlignment.center
                                : CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                chat.title,
                                key: const ValueKey('chat-header-title'),
                                maxLines: 1,
                                textAlign: centerTitle
                                    ? TextAlign.center
                                    : null,
                                overflow: TextOverflow.ellipsis,
                                style: titleStyle,
                              ),
                              if (!hideStatus)
                                Text(
                                  subText,
                                  key: const ValueKey('chat-header-subtitle'),
                                  style: subStyle,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 0,
                top: 0,
                width: menuCapsuleW,
                height: capsuleH,
                child: GlassSurface.capsule(
                  radius: 23,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: p),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (onSearch != null)
                        IconButton(
                          key: const ValueKey('chat-header-search'),
                          onPressed: onSearch,
                          tooltip: '搜索',
                          icon: Icon(
                            Icons.search,
                            color: TelegramColors.textSecondary,
                            size: 22,
                          ),
                        ),
                      if (chat.isGroup)
                        PopupMenuButton<String>(
                          key: const ValueKey('group-menu'),
                          tooltip: '更多',
                          icon: Icon(
                            Icons.more_vert,
                            color: TelegramColors.textSecondary,
                            size: 22,
                          ),
                          onSelected: (String value) {
                            switch (value) {
                              case 'files':
                                onOpenGroupFiles?.call();
                              case 'settings':
                                onOpenGroupSettings?.call();
                              case 'members':
                                onOpenMembers?.call();
                              case 'app-settings':
                                onOpenSettings?.call();
                            }
                          },
                          itemBuilder: (_) => <PopupMenuEntry<String>>[
                            const PopupMenuItem<String>(
                              key: ValueKey('group-menu-files'),
                              value: 'files',
                              child: Text('群文件'),
                            ),
                            const PopupMenuItem<String>(
                              key: ValueKey('group-menu-settings'),
                              value: 'settings',
                              child: Text('群设置'),
                            ),
                            const PopupMenuItem<String>(
                              key: ValueKey('group-menu-members'),
                              value: 'members',
                              child: Text('群成员'),
                            ),
                            if (onOpenSettings != null)
                              const PopupMenuItem<String>(
                                key: ValueKey('chat-header-settings'),
                                value: 'app-settings',
                                child: Text('设置'),
                              ),
                          ],
                        )
                      else if (onOpenSettings != null)
                        IconButton(
                          key: const ValueKey('chat-header-settings'),
                          onPressed: onOpenSettings,
                          tooltip: '设置',
                          icon: Icon(
                            Icons.settings,
                            color: TelegramColors.textSecondary,
                            size: 22,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 量一行文字的宽度，等价官方 `getVisualWidth()` 里的 TextPaint.measureText。
  double _measure(BuildContext context, String text, TextStyle style) {
    final TextPainter tp = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return tp.width;
  }
}
