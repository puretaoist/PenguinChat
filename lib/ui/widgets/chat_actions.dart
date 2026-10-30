/// L4 组件：会话长按菜单（TG 在会话列表长按弹的那套）
///
/// 只放**真能用**的动作——这里刻意都不依赖服务端：
///
/// * 置顶 / 取消置顶、免打扰 / 取消免打扰：本地生效（服务端同步需要额外的 oidb
///   命令，字段没核实过，见 `chat_store.dart` 里那段说明）；
/// * 标为未读：把已读位置往回退一条，列表上重新出现未读点 + 未读分隔线；
/// * 归档 / 取消归档：收进列表顶部的"已归档"入口（TG/Nagram 的 Archived chats）；
/// * 删除会话：**只删本地**（对面不知道），和"撤回/删除消息"是两码事。
///
/// 和消息菜单一样拆成哑弹层（会话 + 回调），每个状态该出现哪个动作能离线测；
/// 版面统一由 [ActionSheet] 画。
library;

import 'package:flutter/material.dart';

import '../../client_api/objects.dart';
import '../theme/telegram_theme.dart';
import 'action_sheet.dart';

class ChatActionsSheet extends StatelessWidget {
  final Chat chat;

  final VoidCallback? onTogglePinned;
  final VoidCallback? onToggleMuted;
  final VoidCallback? onToggleArchived;
  final VoidCallback? onMarkUnread;
  final VoidCallback? onDelete;

  const ChatActionsSheet({
    super.key,
    required this.chat,
    this.onTogglePinned,
    this.onToggleMuted,
    this.onToggleArchived,
    this.onMarkUnread,
    this.onDelete,
  });

  static Future<void> show(
    BuildContext context, {
    required Chat chat,
    VoidCallback? onTogglePinned,
    VoidCallback? onToggleMuted,
    VoidCallback? onToggleArchived,
    VoidCallback? onMarkUnread,
    VoidCallback? onDelete,
  }) =>
      ActionSheet.show(
        context,
        preview: _preview(chat),
        items: _items(
          chat,
          onTogglePinned: onTogglePinned,
          onToggleMuted: onToggleMuted,
          onToggleArchived: onToggleArchived,
          onMarkUnread: onMarkUnread,
          onDelete: onDelete,
        ),
      );

  static Widget _preview(Chat chat) => Text(
        chat.title,
        key: const ValueKey('chat-actions-preview'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: TelegramColors.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      );

  static List<ActionSheetItem> _items(
    Chat chat, {
    VoidCallback? onTogglePinned,
    VoidCallback? onToggleMuted,
    VoidCallback? onToggleArchived,
    VoidCallback? onMarkUnread,
    VoidCallback? onDelete,
  }) =>
      <ActionSheetItem>[
        ActionSheetItem(
          key: const ValueKey('chat-action-pin'),
          icon: chat.pinned ? Icons.push_pin : Icons.push_pin_outlined,
          label: chat.pinned ? '取消置顶' : '置顶',
          onTap: onTogglePinned,
        ),
        ActionSheetItem(
          key: const ValueKey('chat-action-mute'),
          icon: chat.muted
              ? Icons.notifications_active_outlined
              : Icons.notifications_off_outlined,
          label: chat.muted ? '取消免打扰' : '消息免打扰',
          onTap: onToggleMuted,
        ),
        ActionSheetItem(
          key: const ValueKey('chat-action-unread'),
          icon: Icons.mark_chat_unread_outlined,
          label: '标为未读',
          onTap: onMarkUnread,
        ),
        ActionSheetItem(
          key: const ValueKey('chat-action-archive'),
          icon: chat.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
          label: chat.archived ? '取消归档' : '归档',
          onTap: onToggleArchived,
        ),
        ActionSheetItem(
          key: const ValueKey('chat-action-delete'),
          icon: Icons.delete_outline,
          label: '删除会话（仅本地）',
          danger: true,
          onTap: onDelete,
        ),
        ActionSheetItem(
          key: const ValueKey('chat-action-cancel'),
          icon: Icons.close,
          label: '取消',
          onTap: () {},
        ),
      ];

  @override
  Widget build(BuildContext context) {
    return ActionSheet(
      preview: _preview(chat),
      items: _items(
        chat,
        onTogglePinned: onTogglePinned,
        onToggleMuted: onToggleMuted,
        onToggleArchived: onToggleArchived,
        onMarkUnread: onMarkUnread,
        onDelete: onDelete,
      ),
    );
  }
}
