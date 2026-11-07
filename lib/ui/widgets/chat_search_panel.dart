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
