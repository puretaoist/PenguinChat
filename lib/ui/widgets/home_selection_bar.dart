import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';

/// 首页聊天区的消息多选工具条；只派发动作，不持有选择或会话状态。
class HomeSelectionBar extends StatelessWidget {
  const HomeSelectionBar({
    super.key,
    required this.count,
    required this.onClose,
    required this.onCopy,
    required this.onForward,
    required this.onMergeForward,
    required this.onDelete,
  });

  final int count;
  final VoidCallback onClose;
  final VoidCallback onCopy;
  final VoidCallback onForward;
  final VoidCallback onMergeForward;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: TelegramMetrics.headerHeight,
      color: TelegramColors.bgHeader,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: <Widget>[
          IconButton(
            key: const ValueKey<String>('ms-close'),
            onPressed: onClose,
            icon: Icon(Icons.close, color: TelegramColors.textSecondary),
            tooltip: '退出多选',
          ),
          Expanded(
            child: Text(
              '已选 $count 条',
              key: const ValueKey<String>('ms-count'),
              style: TextStyle(
                color: TelegramColors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey<String>('ms-copy'),
            onPressed: onCopy,
            icon: Icon(
              Icons.copy_outlined,
              color: TelegramColors.textSecondary,
            ),
            tooltip: '复制',
          ),
          IconButton(
            key: const ValueKey<String>('ms-forward'),
            onPressed: onForward,
            icon: Icon(Icons.forward, color: TelegramColors.textSecondary),
            tooltip: '转发',
          ),
          IconButton(
            key: const ValueKey<String>('ms-merge-forward'),
            onPressed: onMergeForward,
            icon: Icon(Icons.merge_type, color: TelegramColors.textSecondary),
            tooltip: '合并转发',
          ),
          IconButton(
            key: const ValueKey<String>('ms-delete'),
            onPressed: onDelete,
            icon: Icon(Icons.delete_outline, color: TelegramColors.danger),
            tooltip: '删除（仅本地）',
          ),
        ],
      ),
    );
  }
}
