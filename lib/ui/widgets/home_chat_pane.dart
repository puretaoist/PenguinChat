import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../client_api/objects.dart';
import '../theme/telegram_theme.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/chat_wallpaper.dart';
import '../widgets/jump_to_latest.dart';
import '../widgets/message_list_builder.dart';

/// 聊天详情页的纯布局组件。
///
/// 对标 Telegram 的 ChatActivity：页面状态机决定当前会话和动作，
/// 这个组件只负责把消息列表、头部、输入栏和浮动按钮放进同一层叠布局。
class HomeChatPane extends StatelessWidget {
  const HomeChatPane({
    super.key,
    required this.chat,
    required this.items,
    required this.hasMessages,
    required this.wallpaperId,
    required this.controller,
    required this.reverse,
    required this.topInset,
    required this.header,
    required this.inputBar,
    required this.messagesEmpty,
    required this.atBottom,
    required this.onScrollNotification,
    required this.onJumpToLatest,
    required this.itemBuilder,
    this.overlay,
  });

  final Chat chat;
  final List<MessageListItem> items;
  final bool hasMessages;
  final String wallpaperId;
  final ScrollController controller;
  final bool reverse;
  final double topInset;
  final Widget header;
  final Widget inputBar;
  final Widget messagesEmpty;
  final bool atBottom;
  final bool Function(ScrollNotification) onScrollNotification;
  final VoidCallback onJumpToLatest;
  final Widget Function(BuildContext context, int index, MessageListItem item)
  itemBuilder;

  /// 叠在整页最上层的浮层（会话内搜索的上下跳按钮就挂这里）。
  ///
  /// 官方这些按钮属于 ChatActivity 自己的 sideControlsButtonsLayout
  /// （`ChatActivity.java:7209`，`Gravity.RIGHT | Gravity.BOTTOM`），
  /// 不归聊天流组件管；这里给个口子，免得在外面再套一层 Stack。
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    const double headerHeight = 58.0;
    final double inputReserve = ChatInputBar.reserve(context);
    // 列表从屏幕顶端算起（页面不再被 SafeArea 让位），所以顶部留给
    // 状态栏 + 页头胶囊的留白要自己加：official 的 ListView paddingTop 是
    // actionBar 总高（含 statusBar，ActionBar.java:1400）。
    final double listTop = topInset + headerHeight + 8;
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: Stack(
            children: <Widget>[
              Positioned(
                top: -topInset,
                left: 0,
                right: 0,
                bottom: 0,
                child: ChatWallpaperBackground(
                  wallpaperId: wallpaperId,
                  child: !hasMessages
                      ? messagesEmpty
                      : NotificationListener<ScrollNotification>(
                          onNotification: onScrollNotification,
                          child: ListView.builder(
                            key: ValueKey<String>('msglist-${chat.id}'),
                            controller: controller,
                            reverse: reverse,
                            padding: EdgeInsets.only(
                              top: listTop,
                              bottom: inputReserve + 8,
                            ),
                            addAutomaticKeepAlives: false,
                            // 与 RecyclerView 的预取窗口对应，避免图片刚进屏才开始解码。
                            scrollCacheExtent: const ScrollCacheExtent.pixels(
                              400,
                            ),
                            itemCount: items.length,
                            itemBuilder: (context, index) {
                              final int sourceIndex = reverse
                                  ? items.length - 1 - index
                                  : index;
                              return itemBuilder(
                                context,
                                sourceIndex,
                                items[sourceIndex],
                              );
                            },
                          ),
                        ),
                ),
              ),
              // 状态栏后面是壁纸，壁纸亮的时候白图标会糊掉。官方按壁纸
              // 感知亮度切图标色（ChatActivity 的 computePerceivedBrightness），
              // 这里图标色跟主题固定，只能用一层自上而下的暗渐变兜底，
              // 高度只到页头胶囊下缘的一部分，不压住胶囊本体。
              if (topInset > 0)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: topInset + headerHeight * 0.55,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      key: const ValueKey<String>('status-bar-scrim'),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: <Color>[
                            Colors.black.withValues(
                              alpha: TelegramColors.isDark ? 0.38 : 0.16,
                            ),
                            Colors.black.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (!atBottom)
                Positioned(
                  right: 14,
                  bottom: inputReserve + 8,
                  child: JumpToLatestButton(
                    key: const ValueKey<String>('jump-to-latest'),
                    unread: chat.unreadCount,
                    onTap: onJumpToLatest,
                  ),
                ),
              Positioned(left: 0, right: 0, bottom: 0, child: inputBar),
            ],
          ),
        ),
        // 页头胶囊让出状态栏：背景仍铺到屏幕顶端（壁纸/模糊在下面），
        // 胶囊本身从状态栏下沿开始，和官方 ChatActivity 的 actionBar 一致。
        Positioned(top: topInset, left: 0, right: 0, child: header),
        ?overlay,
      ],
    );
  }
}

/// 没有选中会话时仍保持聊天页的浮动输入栏几何。
class HomeEmptyPane extends StatelessWidget {
  const HomeEmptyPane({
    super.key,
    required this.wallpaperId,
    required this.inputBar,
    required this.onConnect,
    required this.connected,
    this.topInset = 0,
  });

  final String wallpaperId;
  final Widget inputBar;
  final VoidCallback onConnect;
  final bool connected;

  /// 状态栏高度：空态没有页头，壁纸要自己往上多铺一段盖住状态栏。
  final double topInset;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned(
          top: -topInset,
          left: 0,
          right: 0,
          bottom: 0,
          child: ChatWallpaperBackground(
            wallpaperId: wallpaperId,
            child: Padding(
              padding: EdgeInsets.only(
                bottom: ChatInputBar.reserve(context) + 8,
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '选择一个会话开始聊天',
                      style: TextStyle(
                        color: TelegramColors.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                    if (!connected) ...<Widget>[
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: onConnect,
                        child: Text(
                          '去连接设置',
                          style: TextStyle(color: TelegramColors.accent),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(left: 0, right: 0, bottom: 0, child: inputBar),
      ],
    );
  }
}
