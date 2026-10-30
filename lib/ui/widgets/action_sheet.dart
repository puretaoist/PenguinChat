/// L4 组件：底部动作弹层（TG 风格）——会话长按、消息长按共用同一套版面。
///
/// 为什么抽出来：`message_actions.dart` 与 `chat_actions.dart` 原来是两份
/// 同样的代码（顶部预览 + 分隔线 + 一串 dense `ListTile`），字号/行高都停在
/// Flutter 默认（dense ListTile 行高约 48 但标题 15dp、图标 20dp），和 TG 的
/// 动作行差一档。现在统一成：圆角顶部 12、动作行 48dp、图标 24dp、文字 16dp，
/// 危险项红色，末尾「取消」与上面用一条分隔线隔开。
///
/// 仍是**哑组件**：动作项由调用方给（key/图标/文案/回调/是否危险），
/// 这样每个状态下该出现哪个动作都能离线测。
library;

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';

/// 一个动作项。
class ActionSheetItem {
  final Key key;
  final IconData icon;
  final String label;

  /// 危险动作（撤回/删除）用警示色。
  final bool danger;

  /// 为 null 表示这一项目前不可用（仍画出来，但点了没反应）。
  final VoidCallback? onTap;

  const ActionSheetItem({
    required this.key,
    required this.icon,
    required this.label,
    this.danger = false,
    this.onTap,
  });
}

/// 底部动作弹层本体（哑）。`preview` 是顶部那条上下文（会话名或消息摘要）。
class ActionSheet extends StatelessWidget {
  final Widget? preview;
  final List<ActionSheetItem> items;

  const ActionSheet({super.key, this.preview, required this.items});

  /// 统一入口：圆角由 [ActionSheet] 自己画，所以底层的 modal 背景要透明。
  static Future<void> show(
    BuildContext context, {
    Widget? preview,
    required List<ActionSheetItem> items,
  }) =>
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (_) => ActionSheet(preview: preview, items: items),
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: TelegramColors.bgSidebar,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (preview != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: preview!,
              ),
              Divider(height: 1, color: TelegramColors.divider),
            ],
            for (var i = 0; i < items.length; i++) ...[
              // 末尾「取消」单独隔开（TG 的底部弹层都这么画）
              if (i == items.length - 1)
                Divider(height: 1, color: TelegramColors.divider),
              _row(context, items[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, ActionSheetItem item) {
    final color = item.danger ? TelegramColors.danger : TelegramColors.textPrimary;
    return InkWell(
      key: item.key,
      onTap: item.onTap == null
          ? null
          : () {
              Navigator.of(context).pop();
              item.onTap!();
            },
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: <Widget>[
              Icon(item.icon, size: 24, color: color),
              const SizedBox(width: 20),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontSize: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
