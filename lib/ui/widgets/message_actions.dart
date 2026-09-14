/// L4 组件：消息长按菜单（TG 的长按菜单在移动端落地成底部弹层）
///
/// 只放**真能用**的动作，不给假入口：
/// * 回复——任何消息都能被引用（发出时带上 `src_msg` 元素）；
/// * 复制——任何消息都能复制文本；
/// * 查看原文——已撤回且还没揭示时（反撤回，见 `ChatStore.revealMessage`）；
/// * 撤回——只有**自己发的**、且后端支持时才出现（`Session.supports('recall')`）；
/// * 删除——**仅本地**（TG 的 Delete for me）：对面不知道，和撤回是两件事；
/// * 转发——重发内容到别的会话（图片/语音等要先做上传，暂不支持）；
/// * 多选——进入多选模式，批量复制/删除/转发。

/// 拆成"哑弹层"（消息 + 回调）是为了能离线测：每个状态下该出现/不该出现
/// 哪个动作，是这类菜单最容易出错的地方。
library;

import 'package:flutter/material.dart';

import '../../client_api/objects.dart';
import '../theme/telegram_theme.dart';

class MessageActionsSheet extends StatelessWidget {
  final ChatMessage message;

  /// 是否显示「撤回」（自己发的 + 后端支持）。
  final bool canRecall;

  final VoidCallback? onCopy;
  final VoidCallback? onReply;
  final VoidCallback? onRecall;
  final VoidCallback? onReveal;

  /// 删除**本机**这条记录（TG 的 Delete for me；要让对方也看不到得用撤回）。
  final VoidCallback? onDelete;

  /// 转发到别的会话（只重发内容，见 ChatStore.forwardMessages）。
  final VoidCallback? onForward;

  /// 进入多选模式（TG 长按菜单里的 Select）。
  final VoidCallback? onSelect;

  const MessageActionsSheet({
    super.key,
    required this.message,
    this.canRecall = false,
    this.onCopy,
    this.onReply,
    this.onRecall,
    this.onReveal,
    this.onDelete,
    this.onForward,
    this.onSelect,
  });

  /// 弹出菜单（调用方负责判断 [canRecall] 与提供回调）。
  static Future<void> show(
    BuildContext context, {
    required ChatMessage message,
    bool canRecall = false,
    VoidCallback? onCopy,
    VoidCallback? onReply,
    VoidCallback? onRecall,
    VoidCallback? onReveal,
    VoidCallback? onDelete,
    VoidCallback? onForward,
    VoidCallback? onSelect,
  }) =>
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: TelegramColors.bgSidebar,
        builder: (_) => MessageActionsSheet(
          message: message,
          canRecall: canRecall,
          onCopy: onCopy,
          onReply: onReply,
          onRecall: onRecall,
          onReveal: onReveal,
          onDelete: onDelete,
          onForward: onForward,
          onSelect: onSelect,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final showReveal = message.isRecalled && !message.revealed;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 预览：让人确认点的是哪条
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                message.text.isEmpty ? message.displayText : message.text,
                key: const ValueKey('actions-preview'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: TelegramColors.textSecondary, fontSize: 13),
              ),
            ),
          ),
          Divider(height: 1, color: TelegramColors.divider),
          _action(
            key: const ValueKey('action-reply'),
            icon: Icons.reply,
            label: '回复',
            onTap: onReply,
            context: context,
          ),
          _action(
            key: const ValueKey('action-copy'),
            icon: Icons.copy_outlined,
            label: '复制',
            onTap: onCopy,
            context: context,
          ),
          _action(
            key: const ValueKey('action-forward'),
            icon: Icons.forward,
            label: '转发',
            onTap: onForward,
            context: context,
          ),
          _action(
            key: const ValueKey('action-select'),
            icon: Icons.check_circle_outline,
            label: '多选',
            onTap: onSelect,
            context: context,
          ),
          if (showReveal)
            _action(
              key: const ValueKey('action-reveal'),
              icon: Icons.visibility_outlined,
              label: '查看原文',
              onTap: onReveal,
              context: context,
            ),
          if (canRecall)
            _action(
              key: const ValueKey('action-recall'),
              icon: Icons.undo,
              label: '撤回',
              danger: true,
              onTap: onRecall,
              context: context,
            ),
          _action(
            key: const ValueKey('action-delete'),
            icon: Icons.delete_outline,
            label: '删除（仅本地）',
            danger: true,
            onTap: onDelete,
            context: context,
          ),
          _action(
            key: const ValueKey('action-cancel'),
            icon: Icons.close,
            label: '取消',
            onTap: () => Navigator.of(context).pop(),
            context: context,
          ),
        ],
      ),
    );
  }

  Widget _action({
    required Key key,
    required IconData icon,
    required String label,
    required BuildContext context,
    VoidCallback? onTap,
    bool danger = false,
  }) {
    final color = danger ? TelegramColors.danger : TelegramColors.textPrimary;
    return ListTile(
      key: key,
      dense: true,
      leading: Icon(icon, size: 20, color: color),
      title: Text(label, style: TextStyle(color: color, fontSize: 15)),
      onTap: onTap == null
          ? null
          : () {
              Navigator.of(context).pop();
              onTap();
            },
    );
  }
}
