/// L4 组件：转发时选目标会话（TG 的"转发到…"列表）
///
/// 哑弹层：给一组会话和一个回调，不碰 session/store——转发本身由调用方去做
/// （见 `ChatStore.forwardMessages`）。
library;

import 'package:flutter/material.dart';

import '../../client_api/objects.dart';
import '../theme/telegram_theme.dart';
import 'telegram_avatar.dart';

class ForwardPickerSheet extends StatelessWidget {
  /// 候选会话（调用方已排好序；当前会话也会在里面——TG 也允许转发给自己）。
  final List<Chat> chats;

  final void Function(Chat chat) onPick;

  const ForwardPickerSheet({
    super.key,
    required this.chats,
    required this.onPick,
  });

  static Future<void> show(
    BuildContext context, {
    required List<Chat> chats,
    required void Function(Chat chat) onPick,
  }) =>
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: TelegramColors.bgSidebar,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        ),
        builder: (_) => ForwardPickerSheet(chats: chats, onPick: onPick),
      );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Row(
              children: [
                Text(
                  '转发到',
                  key: const ValueKey('forward-title'),
                  style: TextStyle(
                    color: TelegramColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '只转发内容，引用关系不带过去',
                  style: TextStyle(
                    color: TelegramColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: TelegramColors.divider),
          Flexible(
            child: chats.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '没有可选的会话',
                      style: TextStyle(
                        color: TelegramColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  )
                : ListView.builder(
                    key: const ValueKey('forward-list'),
                    shrinkWrap: true,
                    itemCount: chats.length,
                    itemBuilder: (_, i) {
                      final chat = chats[i];
                      return ListTile(
                        key: ValueKey('forward-to-${chat.id}'),
                        dense: true,
                        leading: TelegramAvatar(name: chat.title, size: 36),
                        title: Text(
                          chat.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: TelegramColors.textPrimary,
                            fontSize: 14.5,
                          ),
                        ),
                        subtitle: Text(
                          chat.isGroup ? '群聊' : '私聊',
                          style: TextStyle(
                            color: TelegramColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                        onTap: () {
                          Navigator.of(context).pop();
                          onPick(chat);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
