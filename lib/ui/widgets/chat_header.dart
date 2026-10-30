import 'package:flutter/material.dart';

import '../../client_api/objects.dart';
import '../theme/telegram_theme.dart';
import 'telegram_avatar.dart';

/// 聊天页头部（56dp）——从 \`home_page.dart\` 的 \`_buildHeader\` 抽出来的哑视图，
/// 几何全部对齐 TG \`ui/Components/ChatAvatarContainer.java\`：
/// 高度 56、头像 42（:265 setRoundRadius(dp(21))）、标题 18 粗体（:282）、
/// 副标题 14（:307）。右侧群工具/设置两个图标按钮 22dp。
class ChatHeader extends StatelessWidget {
  const ChatHeader({
    super.key,
    required this.chat,
    this.onBack,
    this.onOpenMembers,
    this.onOpenGroupFiles,
    this.onOpenGroupSettings,
    this.onOpenSettings,
  });

  final Chat chat;
  final VoidCallback? onBack;
  final VoidCallback? onOpenMembers;
  final VoidCallback? onOpenGroupFiles;
  final VoidCallback? onOpenGroupSettings;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: TelegramMetrics.headerHeight,
      color: TelegramColors.bgHeader,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: <Widget>[
          if (onBack != null)
            IconButton(
              onPressed: onBack,
              icon: Icon(
                Icons.arrow_back,
                color: TelegramColors.textSecondary,
              ),
            ),
          GestureDetector(
            key: const ValueKey('open-members'),
            onTap: chat.isGroup ? onOpenMembers : null,
            child: TelegramAvatar(name: chat.title, url: chat.avatarUrl, size: 42),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  chat.title,
                  key: const ValueKey('chat-header-title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: TelegramColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  chat.isGroup
                      ? '群聊 · ${chat.memberCount} 人'
                      : (chat.online ? '在线' : '离线'),
                  key: const ValueKey('chat-header-subtitle'),
                  style: TextStyle(
                    color: chat.online
                        ? TelegramColors.online
                        : TelegramColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          if (chat.isGroup)
            PopupMenuButton<String>(
              key: const ValueKey('group-menu'),
              tooltip: '群工具',
              icon: Icon(
                Icons.folder_outlined,
                color: TelegramColors.textSecondary,
                size: 22,
              ),
              onSelected: (String value) {
                switch (value) {
                  case 'files':
                    onOpenGroupFiles?.call();
                  case 'settings':
                    onOpenGroupSettings?.call();
                  case 'members':
                    onOpenMembers?.call();
                }
              },
              itemBuilder: (_) => const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  key: ValueKey('group-menu-files'),
                  value: 'files',
                  child: Text('群文件'),
                ),
                PopupMenuItem<String>(
                  key: ValueKey('group-menu-settings'),
                  value: 'settings',
                  child: Text('群设置'),
                ),
                PopupMenuItem<String>(
                  key: ValueKey('group-menu-members'),
                  value: 'members',
                  child: Text('群成员'),
                ),
              ],
            ),
          IconButton(
            key: const ValueKey('chat-header-settings'),
            onPressed: onOpenSettings,
            icon: Icon(
              Icons.settings,
              color: TelegramColors.textSecondary,
              size: 22,
            ),
            tooltip: '设置',
          ),
        ],
      ),
    );
  }
}
