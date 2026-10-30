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
///
/// 拆成"哑弹层"（消息 + 回调）是为了能离线测：每个状态下该出现/不该出现
/// 哪个动作，是这类菜单最容易出错的地方。版面统一由 [ActionSheet] 画。
library;

import 'package:flutter/material.dart';

import '../../client_api/objects.dart';
import '../theme/telegram_theme.dart';
import 'action_sheet.dart';

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

  /// 转发到别的会话（只重发内容，见 `ChatStore.forwardMessages`）。
  final VoidCallback? onForward;

  /// 戳一戳对方（后端支持 `poke` 且这条是对面发的时才给回调）。
  final VoidCallback? onPoke;

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
    this.onPoke,
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
    VoidCallback? onPoke,
  }) =>
      ActionSheet.show(
        context,
        preview: _preview(message),
        items: _items(
          context,
          message: message,
          canRecall: canRecall,
          onCopy: onCopy,
          onReply: onReply,
          onRecall: onRecall,
          onReveal: onReveal,
          onDelete: onDelete,
          onForward: onForward,
          onSelect: onSelect,
          onPoke: onPoke,
        ),
      );

  /// 顶部预览：让人确认点的是哪条（左侧一条强调色竖线，同 TG 的引用块）。
  static Widget _preview(ChatMessage message) => Row(
        children: <Widget>[
          Container(
            width: 3,
            height: 34,
            decoration: BoxDecoration(
              color: TelegramColors.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message.text.isEmpty ? message.displayText : message.text,
              key: const ValueKey('actions-preview'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: TelegramColors.textPrimary,
                fontSize: 15,
                height: 1.25,
              ),
            ),
          ),
        ],
      );

  static List<ActionSheetItem> _items(
    BuildContext context, {
    required ChatMessage message,
    required bool canRecall,
    VoidCallback? onCopy,
    VoidCallback? onReply,
    VoidCallback? onRecall,
    VoidCallback? onReveal,
    VoidCallback? onDelete,
    VoidCallback? onForward,
    VoidCallback? onSelect,
    VoidCallback? onPoke,
  }) {
    final showReveal = message.isRecalled && !message.revealed;
    return <ActionSheetItem>[
      ActionSheetItem(
        key: const ValueKey('action-reply'),
        icon: Icons.reply,
        label: '回复',
        onTap: onReply,
      ),
      ActionSheetItem(
        key: const ValueKey('action-copy'),
        icon: Icons.copy_outlined,
        label: '复制',
        onTap: onCopy,
      ),
      if (onPoke != null)
        ActionSheetItem(
          key: const ValueKey('action-poke'),
          icon: Icons.touch_app_outlined,
          label: '戳一戳',
          onTap: onPoke,
        ),
      ActionSheetItem(
        key: const ValueKey('action-forward'),
        icon: Icons.forward,
        label: '转发',
        onTap: onForward,
      ),
      ActionSheetItem(
        key: const ValueKey('action-select'),
        icon: Icons.check_circle_outline,
        label: '多选',
        onTap: onSelect,
      ),
      if (showReveal)
        ActionSheetItem(
          key: const ValueKey('action-reveal'),
          icon: Icons.visibility_outlined,
          label: '查看原文',
          onTap: onReveal,
        ),
      if (canRecall)
        ActionSheetItem(
          key: const ValueKey('action-recall'),
          icon: Icons.undo,
          label: '撤回',
          danger: true,
          onTap: onRecall,
        ),
      ActionSheetItem(
        key: const ValueKey('action-delete'),
        icon: Icons.delete_outline,
        label: '删除（仅本地）',
        danger: true,
        onTap: onDelete,
      ),
      ActionSheetItem(
        key: const ValueKey('action-cancel'),
        icon: Icons.close,
        label: '取消',
        onTap: () {},
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ActionSheet(
      preview: _preview(message),
      items: _items(
        context,
        message: message,
        canRecall: canRecall,
        onCopy: onCopy,
        onReply: onReply,
        onRecall: onRecall,
        onReveal: onReveal,
        onDelete: onDelete,
        onForward: onForward,
        onSelect: onSelect,
        onPoke: onPoke,
      ),
    );
  }
}
