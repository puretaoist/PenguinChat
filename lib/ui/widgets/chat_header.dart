import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../client_api/objects.dart';
import '../theme/telegram_theme.dart';
import 'glass_surface.dart';
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
/// 头像到文字 ≈9.66（57.66 - 8 - 40）、文字右余量 18（getVisualWidth 的 dp(52+18)）。
///
/// ## 搜索态（原地变形，不跳页、不换实例）
///
/// 官方没有任何「另摆一颗搜索框」的东西：**同一个标题玻璃背景变宽**，里面
/// 的头像标题淡出、输入框淡入。逐条依据：
///
/// * `ActionBar/ActionBar.java:2232-2279 dispatchDraw()`：
///   `width = lerp(min(widthDefault, avatarContainerWidth + p*2), widthDefault,
///   max(searchFactor, actionModeFactor))`，`left = (rightDefault + leftDefault
///   - width) / 2`，然后 `glassDrawable.setBounds(left, t, right, b)`。
///   即：玻璃从「头像标题那块的实际宽」扩宽到「中间可用宽」，并且始终居中。
/// * `ActionBar/ActionBar.java:2171-2175`：`animatorAvatarContainerWidth` 380ms、
///   菜单宽/有无菜单 320ms，都是 `CubicBezierInterpolator.EASE_OUT_QUINT`；
///   `ChatActivity.java:47069-47070` 搜索因子自己那条也是 **320ms EASE_OUT_QUINT**。
/// * `ChatActivity.java:46995-47004`：`avatarContainer` 的
///   `factor = (1 - actionMode) * (1 - searchFactor)`、`scale = lerp(0.95f, 1f, factor)`、
///   `alpha = factor` —— 头像标题是**淡出 + 微缩**，不是瞬间消失。
/// * `ActionBar/ActionBar.java:1207-1220`：`searchFieldVisibleAlpha` 单独 **150ms**。
/// * `ActionBar/ActionBarMenuItem.java:1527-1535`：聊天页里那个搜索框其实是
///   `searchContainer` 内部的 `EditText` —— **18dp、cursor 1.5、背景透明、padding 0**，
///   不是 `Components/SearchField.java` 那颗 16dp 自带底色的独立框。
/// * `ChatActivity.java:35378-35418 openSearchWithText()`：`headerItem`（头像标题）、
///   `attachItem`、`editTextItem` 隐掉，`otherIcon.setIconVisible(false)`，
///   `searchItem` 显示；普通群聊里 `searchIconItem` 本来就不显示
///   （`ChatActivity.java:18503-18538 showSearchAsIcon` 只在 self 且空间足够时为真），
///   搜索入口是 `headerItem.lazilyAddSubItem(search, ...)`（`:4466-4467`）——**就是 ⋮ 菜单**。
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

  /// 进入搜索。入口在 ⋮ 菜单里（官方 `headerItem.lazilyAddSubItem(search)`）。
  final VoidCallback? onSearch;

  /// 是否处于搜索态。见类文档「搜索态」一节。
  final bool searching;

  /// 搜索态的输入控制器与焦点。
  ///
  /// **退出搜索时也要传**：官方那段 150ms 的 alpha 交叉要有内容可淡出，
  /// 传 null 会让退出动画里输入框瞬间消失。
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

  /// 玻璃胶囊形变时长：320ms `EASE_OUT_QUINT`
  /// （`ActionBar.java:2171-2175`、`ChatActivity.java:47069-47070`）。
  static const Duration _glassDuration = Duration(milliseconds: 320);

  /// 搜索框内文字的淡入：150ms（`ActionBar.java:1207-1220`
  /// `searchFieldVisibleAlpha`）。
  static const Duration _contentDuration = Duration(milliseconds: 150);

  @override
  Widget build(BuildContext context) {
    // 全部单位 dp，数值来自上述官方源码。
    const double p = 6.0; // ActionBar.java:2232 dp(6)
    const double s = 46.0; // :2232 dp(46)
    const double capsuleH = s + 2 * p; // 58，与 s+2p 一致

    const double iconSlot = 48.0; // 官方每个 action item 占 48dp（menuWidth）
    const double leftDefault = s + p; // 52，中胶囊左界（:2249）

    // 普通群聊/单聊右侧只有 ⋮ 一个 action item：官方 `searchIconItem` 在非 self
    // 会话里是 GONE 的（`ChatActivity.java:18503-18538`），搜索藏在 ⋮ 菜单里
    // （`:4466-4467`）。
    final int menuItems = (chat.isGroup || onOpenSettings != null) ? 1 : 0;
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
          // 中间可用的整条宽度：搜索态铺满它（官方 widthDefault）。
          final double widthDefault = math.max(0.0, rightDefault - leftDefault);
          final double textW = math.max(
            _measure(context, chat.title, titleStyle),
            hideStatus ? 0.0 : _measure(context, subText, subStyle),
          );
          // 官方 getVisualWidth 有头像时加 dp(52+18)=70，再 +2p(12) 得胶囊宽。
          final double avatarW = math.min(widthDefault, textW + 82.0);

          return TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: searching ? 1 : 0),
            duration: _glassDuration,
            curve: Curves.easeOutQuint,
            builder: (BuildContext context, double raw, Widget? _) {
              final double t = raw.clamp(0.0, 1.0);
              // 官方 dispatchDraw：宽从「头像那块」扩到「中间可用宽」，左界居中。
              final double width = lerpDouble(
                math.min(widthDefault, avatarW + 2 * p),
                widthDefault,
                t,
              )!;
              final double left = math.max(
                0.0,
                (rightDefault + leftDefault - width) / 2,
              );

              // avatarContainer 的 factor = 1 - searchFactor（ChatActivity.java:46995-47004）。
              final double avatarFactor = 1 - t;
              final double avatarScale = lerpDouble(0.95, 1.0, avatarFactor)!;

              return Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  // 左侧返回胶囊：位置与尺寸都不动。进入搜索后同一个按钮
                  // 改成「退出搜索」（官方那个按钮是同一个 view 在形变）。
                  if (onBack != null || onExitSearch != null)
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
                          key: ValueKey<String>(
                            searching ? 'chat-search-back' : 'chat-header-back',
                          ),
                          onPressed: searching ? onExitSearch : onBack,
                          tooltip: searching ? '退出搜索' : '返回',
                          icon: Icon(
                            Icons.arrow_back,
                            color: TelegramColors.textSecondary,
                            size: 24,
                          ),
                        ),
                      ),
                    ),
                  // 中间那颗玻璃：同一个背景，宽度在动；里面头像标题与输入框交叉。
                  Positioned(
                    left: left,
                    top: 0,
                    width: width,
                    height: capsuleH,
                    child: GlassSurface.capsule(
                      radius: 23,
                      padding: EdgeInsets.zero,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(23),
                        child: Stack(
                          children: <Widget>[
                            if (avatarFactor > 0.001 && avatarW > 0)
                              Positioned.fill(
                                child: IgnorePointer(
                                  ignoring: searching,
                                  child: Opacity(
                                    opacity: avatarFactor,
                                    child: Transform.scale(
                                      scale: avatarScale,
                                      child: OverflowBox(
                                        alignment: Alignment.centerLeft,
                                        minWidth: avatarW,
                                        maxWidth: avatarW,
                                        child: SizedBox(
                                          width: avatarW,
                                          height: capsuleH,
                                          child: _middleContent(
                                            titleStyle: titleStyle,
                                            subStyle: subStyle,
                                            subText: subText,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            // 非搜索态不渲染输入框：官方 `searchContainer` 平时是
                            // GONE 的（`ActionBarMenuItem.java:1472`），只在形变期间存在。
                            // `searching || t > 0.001` 是为了让退出搜索时也留住它——
                            // 官方那段淡出要有内容可淡，t 还在往回走就说明动画没结束。
                            if ((searching || t > 0.001) &&
                                searchController != null &&
                                searchFocus != null)
                              Positioned.fill(
                                child: IgnorePointer(
                                  ignoring: !searching,
                                  // 用 TweenAnimationBuilder 而不是 AnimatedOpacity：
                                  // 这个 widget 是「进搜索那一刻」才第一次挂载的，
                                  // AnimatedOpacity 首次布局就直接取 opacity 1，
                                  // 没有任何 0→1 的过程——官方那是独立的 150ms
                                  // `searchFieldVisibleAlpha`（ActionBar.java:1207-1220），
                                  // 必须显式从 0 起。
                                  child: TweenAnimationBuilder<double>(
                                    tween: Tween<double>(
                                      begin: 0,
                                      end: searching ? 1 : 0,
                                    ),
                                    duration: _contentDuration,
                                    curve: Curves.easeOut,
                                    builder: (
                                      BuildContext context,
                                      double alpha,
                                      Widget? child,
                                    ) => Opacity(opacity: alpha, child: child),
                                    child: _SearchInput(
                                      controller: searchController!,
                                      focusNode: searchFocus!,
                                      onChanged: onSearchChanged,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 右侧菜单胶囊：官方 `otherIcon.setIconVisible(false)`，
                  // 随搜索因子淡出（ActionBar.java:2171-2175 的菜单 320ms 动画）。
                  Positioned(
                    right: 0,
                    top: 0,
                    width: menuCapsuleW,
                    height: capsuleH,
                    child: IgnorePointer(
                      ignoring: searching,
                      child: Opacity(
                        opacity: 1 - t,
                        child: GlassSurface.capsule(
                          radius: 23,
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: p),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              if (chat.isGroup || onOpenSettings != null)
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
                                      case 'search':
                                        onSearch?.call();
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
                                    // 官方把搜索放在头部菜单里
                                    // （`ChatActivity.java:4466-4467`
                                    // `headerItem.lazilyAddSubItem(search, ...)`）。
                                    if (onSearch != null)
                                      const PopupMenuItem<String>(
                                        key: ValueKey('group-menu-search'),
                                        value: 'search',
                                        child: Text('搜索'),
                                      ),
                                    if (chat
                                        .isGroup) ...<PopupMenuEntry<String>>[
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
                                    ],
                                    if (onOpenSettings != null)
                                      const PopupMenuItem<String>(
                                        key: ValueKey('chat-header-settings'),
                                        value: 'app-settings',
                                        child: Text('设置'),
                                      ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  /// 玻璃里的头像 + 标题 + 副标题，整块可点（群聊时打开成员列表）。
  ///
  /// 内边距 8 / 18 与原来 `GlassSurface.capsule(padding:)` 一致，只是现在由
  /// 这一层自己出——因为外层还要在同一块玻璃里叠输入框。
  Widget _middleContent({
    required TextStyle titleStyle,
    required TextStyle subStyle,
    required String subText,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 18),
      child: GestureDetector(
        key: const ValueKey('open-members'),
        onTap: chat.isGroup ? onOpenMembers : null,
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: <Widget>[
            TelegramAvatar(name: chat.title, url: chat.avatarUrl, size: 40),
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
                    textAlign: centerTitle ? TextAlign.center : null,
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

/// 玻璃里的搜索输入：官方 `ActionBarMenuItem` 的 `searchContainer` 内部那个
/// `EditText`（`ActionBarMenuItem.java:1527-1535`）——18dp、cursor 1.5、
/// **背景透明**、padding 0，左边留 `setSearchPaddingStart(7)`。
class _SearchInput extends StatelessWidget {
  const _SearchInput({
    required this.controller,
    required this.focusNode,
    this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (BuildContext context, TextEditingValue value, Widget? _) {
        final bool hasText = value.text.isNotEmpty;
        return Row(
          children: <Widget>[
            const SizedBox(width: 7), // setSearchPaddingStart(7)
            Expanded(
              child: TextField(
                key: const ValueKey('chat-search-input'),
                controller: controller,
                focusNode: focusNode,
                textInputAction: TextInputAction.search,
                cursorColor: TelegramColors.accent,
                cursorWidth: 1.5,
                style: TextStyle(
                  color: TelegramColors.textPrimary,
                  fontSize: 18,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  // ChatActivity.java:4299 setSearchFieldHint(R.string.Search)
                  hintText: '搜索',
                  hintStyle: TextStyle(
                    color: TelegramColors.textMuted,
                    fontSize: 18,
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
                onChanged: onChanged,
                onSubmitted: (_) => focusNode.unfocus(),
              ),
            ),
            if (hasText)
              IconButton(
                key: const ValueKey('chat-search-clear'),
                tooltip: '清除',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 40,
                  height: 40,
                ),
                iconSize: 18,
                onPressed: () {
                  controller.clear();
                  onChanged?.call('');
                  focusNode.requestFocus();
                },
                icon: Icon(Icons.cancel, color: TelegramColors.textMuted),
              ),
            const SizedBox(width: 6),
          ],
        );
      },
    );
  }
}
