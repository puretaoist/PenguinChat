/// L4 好友资料页：Telegram ProfileActivity 同构（简版）。
///
/// 几何依据（org/telegram/ui/ProfileActivity.java）：
/// - 大头像折叠 100dp、正圆（:6400/:6429）；名字 17.5dp bold（:5561），
///   状态 13.5dp（:5627）——这里名字用 20（本项目列表字号整体比官方大一号）。
/// - 动作行 [Components/ProfileActionsView.java:715-721]：用户模式顺序
///   发消息 → 通知 → 语音通话 → 视频通话；按钮高 54、圆角 16、图标 24、
///   文案 11sp bold（:128-141/:1030）。本项目只有"发消息"是真的能走通，
///   另两个显式禁用（点了给提示，不假装能打）。
/// - 信息组 [Cells/TextDetailCell.java:79/82/191/270]：行高 60、正文 16 /
///   右值 13、分割线左右内缩 20。
///
/// 「发消息」不自己导航：找到已有会话就把 chatId 通过 `Navigator.pop` 交回
/// [ContactsPage]，由它写 pendingOpenChatProvider 并切 tab——聊天页只有一个
/// 入口（见 home_page.dart 的 pendingOpenChatProvider 注释）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/objects.dart';
import '../../client_api/qq8_providers.dart';
import '../../client_api/session_providers.dart';
import '../../kernel/wlogin8/qq8_list.dart';
import '../theme/telegram_theme.dart';
import '../theme/theme_mode.dart';
import '../widgets/telegram_avatar.dart';
import '../widgets/telegram_list_item.dart';
import 'contacts_page.dart' show qqAvatarUrl;

class FriendProfilePage extends ConsumerWidget {
  const FriendProfilePage({super.key, required this.friend});

  final Qq8Friend friend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    applyThemePalette(ref);
    final service = ref.watch(qq8LoginServiceProvider);

    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            _header(context),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: <Widget>[
                  const SizedBox(height: 24),
                  Center(
                    child: TelegramAvatar(
                      name: friend.displayName,
                      size: 100,
                      url: qqAvatarUrl(friend.uin, size: 640),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    friend.displayName,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: TelegramColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'QQ ${friend.uin}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: TelegramColors.textSecondary,
                      fontSize: 13.5,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      _action(
                        context,
                        icon: Icons.chat_bubble_outline,
                        label: '发消息',
                        onTap: () => _sendMessage(context, ref),
                      ),
                      const SizedBox(width: 16),
                      _action(
                        context,
                        icon: Icons.notifications_off_outlined,
                        label: '静音',
                        onTap: () => _notSupported(context, '会话内可设置免打扰'),
                      ),
                      const SizedBox(width: 16),
                      _action(
                        context,
                        icon: Icons.call_outlined,
                        label: '语音通话',
                        onTap: () => _notSupported(context, '暂不支持语音通话'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const TelegramSectionHeader(text: 'Info'),
                  TelegramTileGroup(
                    children: <Widget>[
                      _infoRow('昵称', friend.nick.isEmpty ? '（空）' : friend.nick),
                      _infoRow(
                        '备注',
                        friend.remark.isEmpty || friend.remark == friend.nick
                            ? '未设置'
                            : friend.remark,
                      ),
                      _infoRow(
                        '分组',
                        service.friendGroupNameOf(friend.groupId) ?? '好友',
                      ),
                      _infoRow('性别', _sexLabel(friend.sex)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _sexLabel(int sex) => switch (sex) {
    1 => '男',
    2 => '女',
    _ => '未知',
  };

  Widget _header(BuildContext context) {
    return Container(
      height: TelegramMetrics.headerHeight,
      color: TelegramColors.bgHeader,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icon(Icons.arrow_back, color: TelegramColors.textSecondary),
          ),
          Text(
            '资料',
            style: TextStyle(
              color: TelegramColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// ProfileActionsView 的单个动作按钮：54 高 / 圆角 16 / 图标 24 / 文案 11。
  Widget _action(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: 76,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Column(
          children: <Widget>[
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: TelegramColors.bgHover,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, size: 24, color: TelegramColors.accent),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: TelegramColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// TextDetailCell 同构：60 高、标题 16 / 右侧值 13、左右内缩 20，
  /// **没有图标槽**（官方 Info 组就是纯文字行，TgListTile 的图标槽会跑偏）。
  Widget _infoRow(String title, String value) {
    return Container(
      constraints: const BoxConstraints(minHeight: 60),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: TextStyle(color: TelegramColors.textPrimary, fontSize: 16),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: TextStyle(color: TelegramColors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }

  void _notSupported(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _sendMessage(BuildContext context, WidgetRef ref) {
    final chats = ref.read(chatsProvider).valueOrNull ?? const <Chat>[];
    Chat? found;
    for (final c in chats) {
      if (c.type == ChatType.private && c.rawId == friend.uin) {
        found = c;
        break;
      }
    }
    if (found == null) {
      _notSupported(context, '还没有和 TA 的会话，收到第一条消息后会出现在列表里');
      return;
    }
    Navigator.of(context).pop(found.id);
  }
}
