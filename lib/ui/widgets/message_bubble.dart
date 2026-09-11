/// Telegram 风格组件：消息气泡
///
/// 对方靠左（灰底）、自己靠右（蓝底），圆角 12px，时间戳小字右下。
///
/// 三种非正常态也在这里收口，避免调用方各写一套：
///   - `sending`：时钟图标，表示还没等到服务端回包
///   - `failed`：红色感叹号 + 「点此重试」入口（文本必须还在，不得静默丢弃）
///   - `recalled`：显示占位文案而不是把气泡删掉
library;

import 'package:flutter/material.dart';

import '../../client_api/objects.dart';
import '../theme/telegram_theme.dart';

String formatTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// 失败态用的红色。比主题里任何一个色都更扎眼——它需要被看到。
const Color _failColor = Color(0xFFE05252);

class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  /// 发送失败时的重试入口。为 null 表示不提供重试（例如收到的消息）。
  final VoidCallback? onRetry;

  const MessageBubble({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final isOut = message.outgoing;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        mainAxisAlignment:
            isOut ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: isOut
                    ? TelegramColors.bubbleOut
                    : TelegramColors.bubbleIn,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(TelegramMetrics.bubbleRadius),
                  topRight: const Radius.circular(TelegramMetrics.bubbleRadius),
                  bottomLeft: Radius.circular(
                      isOut ? TelegramMetrics.bubbleRadius : 4),
                  bottomRight: Radius.circular(
                      isOut ? 4 : TelegramMetrics.bubbleRadius),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isOut && message.senderName.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        message.senderName,
                        style: const TextStyle(
                          color: TelegramColors.accent,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      message.displayText,
                      style: TextStyle(
                        color: message.isRecalled
                            ? TelegramColors.textSecondary
                            : TelegramColors.textPrimary,
                        fontStyle: message.isRecalled
                            ? FontStyle.italic
                            : FontStyle.normal,
                        fontSize: TelegramMetrics.fontBody,
                        height: 1.35,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message.isFailed && onRetry != null) ...[
                        GestureDetector(
                          onTap: onRetry,
                          child: const Text(
                            '发送失败，点此重试',
                            style: TextStyle(
                                color: _failColor,
                                fontSize: TelegramMetrics.fontTimestamp),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        formatTime(message.time),
                        style: const TextStyle(
                          color: TelegramColors.textSecondary,
                          fontSize: TelegramMetrics.fontTimestamp,
                        ),
                      ),
                      if (isOut) ...[
                        const SizedBox(width: 4),
                        Icon(
                          message.isFailed
                              ? Icons.error_outline
                              : message.isSending
                                  ? Icons.schedule
                                  : Icons.done_all,
                          size: 14,
                          color: message.isFailed
                              ? _failColor
                              : message.isSending
                                  ? TelegramColors.textSecondary
                                  : TelegramColors.accentHover,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
