/// Telegram 风格组件：消息气泡
///
/// 对方靠左（灰底）、自己靠右（蓝底），圆角 12px，时间戳小字右下。
library;

import 'package:flutter/material.dart';

import '../../client_api/objects.dart';
import '../theme/telegram_theme.dart';

String formatTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const MessageBubble({super.key, required this.message});

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
                      message.text,
                      style: const TextStyle(
                        color: TelegramColors.textPrimary,
                        fontSize: TelegramMetrics.fontBody,
                        height: 1.35,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        formatTime(message.time),
                        style: const TextStyle(
                          color: TelegramColors.textSecondary,
                          fontSize: TelegramMetrics.fontTimestamp,
                        ),
                      ),
                      if (isOut) ...[
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.done_all,
                          size: 14,
                          color: TelegramColors.accentHover,
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
