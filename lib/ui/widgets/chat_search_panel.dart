/// 聊天页搜索的底部面板——官方在会话内搜索时，输入栏位置上浮出的那一条。
///
/// 出处（`T/ui/ChatActivity.java`）：
/// * 高 `44`：`:615` `private final int searchContainerHeight = 44;`
/// * 贴底、左右各 `7`：`:10604` `LayoutHelper.createFrame(MATCH_PARENT,
///   searchContainerHeight, Gravity.BOTTOM, 7, 0, 7, 0)`，挂在
///   `chatInputBubbleContainer` 上——也就是**输入栏的位子**，不是屏幕最底。
/// * 左侧计数文本：`AnimatedTextView`，`15dp`、`bold`、
///   `key_chat_searchPanelText`、`Gravity.LEFT`，`:10596-10602`；
///   左边距 `18 + 48 × 可见按钮数`（`:10578-10585`，官方有日历与按成员两个
///   44dp 按钮，我方没有，所以固定 18）。
/// * 右侧切换：`:10606-10618`，`15dp`、`bold`、
///   `key_windowBackgroundWhiteBlueText2`、左右内距 `15.33`、
///   文案 `SearchAsChat` / `SearchAsList`，动画 `420ms EASE_OUT_QUINT`、
///   起始 scale `0.7`；无结果时 `alpha 0.5` 且不可点（`:27292-27295`）。
/// * 计数文案：`:27299-27320` —— 无结果 `NoResult`；列表态
///   `SearchMessagesResultCount`（「N 条消息」）；聊天态 `Of`（「2 of 20」）。
library;

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';
import 'glass_surface.dart';

class ChatSearchPanel extends StatelessWidget {
  const ChatSearchPanel({
    super.key,
    required this.count,
    required this.listMode,
    required this.onToggleMode,
    this.index = 0,
  });

  /// 命中条数。
  final int count;

  /// 是否正以「结果列表」的方式看（对应官方 `isMessagesSearchListVisible()`）。
  final bool listMode;

  /// 切换「以聊天方式查看 / 以列表方式查看」。
  final VoidCallback onToggleMode;

  /// 聊天态下当前停在第几条（从 0 起）。列表态忽略。
  final int index;

  static const double height = 44; // ChatActivity.java:615

  @override
  Widget build(BuildContext context) {
    final bool empty = count <= 0;
    final String countText = empty
        ? '没有结果'
        : (listMode ? '$count 条消息' : '${index + 1} of $count');

    return Padding(
      // :10604 左右各 7dp。
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: SizedBox(
        height: height,
        child: Row(
          children: <Widget>[
            // :10578-10585 左边距 18（官方还要加两个 44dp 按钮的 48）。
            const SizedBox(width: 18),
            Text(
              countText,
              key: const ValueKey<String>('chat-search-count'),
              style: TextStyle(
                color: TelegramColors.textSecondary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: empty ? 0.5 : 1,
              child: IgnorePointer(
                ignoring: empty,
                child: TextButton(
                  key: const ValueKey<String>('chat-search-toggle-mode'),
                  onPressed: onToggleMode,
                  style: TextButton.styleFrom(
                    // :10614 setPadding(dp(15.33), 0, dp(15.33), 0)
                    padding: const EdgeInsets.symmetric(horizontal: 15.33),
                    minimumSize: const Size(0, height),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    listMode ? '以聊天方式查看' : '以列表方式查看',
                    style: TextStyle(
                      // :10612 key_windowBackgroundWhiteBlueText2
                      color: TelegramColors.accent,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 聊天页右侧那对「上一条 / 下一条」玻璃圆钮。
///
/// 出处：`Components/chat/layouts/ChatActivitySideControlsButtonsLayout.java`
/// * 按钮本体 44：`ChatActivityBlurredRoundButton.BUTTON_SIZE = 44`；
///   外层容器 56×64、`Gravity.RIGHT | Gravity.BOTTOM`
///   （`ChatActivity.java:7209` `createFrame(57, 300, Gravity.RIGHT | Gravity.BOTTOM)`）。
/// * 竖排间距 10：`:188` `gap = dp(10 + 10 * counterVisibility)`，无计数时就是 10。
/// * 出现/消失 280ms DECELERATE、`translationY = dp(80) * (1 - visibility)`、
///   scale `lerp(0.7, 1)`：`:176-205`。
/// * `BUTTON_SEARCH_UP` 靠 `reverseIconByY()` 把 pagedown 图标翻过来（`:236-238`）。
///
/// 我方没有 pagedown 资源，用 Material 的上下箭头；玻璃底色走已经统一的
/// [GlassSurface.capsule]，与主胶囊同一套参数。
class ChatSearchNavButtons extends StatelessWidget {
  const ChatSearchNavButtons({
    super.key,
    required this.index,
    required this.total,
    required this.onPrevious,
    required this.onNext,
  });

  /// 当前停在第几条（从 0 起）。
  final int index;

  /// 命中总数。
  final int total;

  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _RoundButton(
          key: const ValueKey<String>('chat-search-prev'),
          icon: Icons.keyboard_arrow_up,
          tooltip: '上一条',
          onTap: index > 0 ? onPrevious : null,
        ),
        const SizedBox(height: 10), // :188 gap dp(10)
        _RoundButton(
          key: const ValueKey<String>('chat-search-next'),
          icon: Icons.keyboard_arrow_down,
          tooltip: '下一条',
          onTap: index < total - 1 ? onNext : null,
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onTap != null;
    return SizedBox(
      // BUTTON_SIZE = 44
      width: 44,
      height: 44,
      child: GlassSurface.capsule(
        radius: 22,
        padding: EdgeInsets.zero,
        alignment: Alignment.center,
        child: IconButton(
          onPressed: onTap,
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 44, height: 44),
          iconSize: 22,
          icon: Icon(
            icon,
            color: enabled
                ? TelegramColors.textPrimary
                : TelegramColors.textMuted.withValues(alpha: 0.45),
          ),
        ),
      ),
    );
  }
}
