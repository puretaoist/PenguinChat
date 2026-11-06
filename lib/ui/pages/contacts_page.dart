/// L4 联系人页：Telegram 联系人列表同构。
///
/// 几何依据（TDesktop/Android 源码，路径相对 org/telegram/ui）：
/// - 行 [Cells/UserCell.java:475-497]：头像 44dp 圆角 22、姓名 15sp、
///   状态 13sp、行高 56dp；这里沿用项目既有 [TgUserRow]（58 高 / 46 头像 /
///   标题 16 w600 / 副 15），比官方大一号，和其它列表保持一致。
/// - 分组头 [Cells/LetterSectionCell.java]：官方按首字母分组。中文名按字母
///   分组没有意义，这里改按 **QQ 好友分组**（"我的好友"等）分段，
///   信息量和官方一致（一眼能看出这个人在哪个分组）。
/// - **官方 cell 没有右侧 ">" 箭头**（靠 ripple 表达可点），所以本页不画箭头。
///
/// 数据来自 [qq8FriendsProvider]（服务层好友缓存，见 qq8_login_service.dart
/// 的 fetchFriendList 回填）。未登录/未拉到时是空表，不报错。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/qq8_providers.dart';
import '../../client_api/session_providers.dart';
import '../../kernel/wlogin8/qq8_list.dart';
import '../theme/telegram_theme.dart';
import '../theme/theme_mode.dart';
import '../widgets/telegram_avatar.dart';
import '../widgets/tg_page_header.dart';
import '../widgets/telegram_list_item.dart';
import 'friend_profile_page.dart';

/// 公开头像直链（qlogo，和会话列表头像同一个来源，见 qq8_session_adapter.dart）。
String qqAvatarUrl(int uin, {int size = 100}) =>
    'https://q1.qlogo.cn/g?b=qq&nk=$uin&s=$size';

class ContactsPage extends ConsumerWidget {
  const ContactsPage({super.key, this.onOpenChats});

  /// 「资料页 → 发消息」成功后要切回聊天 tab。由 [HomeShell] 传入。
  final VoidCallback? onOpenChats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    applyThemePalette(ref);
    final async = ref.watch(qq8FriendsProvider);
    final friends = <Qq8Friend>[...(async.valueOrNull ?? const <Qq8Friend>[])]
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    final service = ref.watch(qq8LoginServiceProvider);

    // 按好友分组切段；分组名来自服务层缓存的 FriendListResp 分组表。
    final groups = <String, List<Qq8Friend>>{};
    for (final f in friends) {
      final name = service.friendGroupNameOf(f.groupId) ?? '好友';
      (groups[name] ??= <Qq8Friend>[]).add(f);
    }

    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            TgPageHeader(
              title: '联系人',
              subtitle: friends.isEmpty ? null : '${friends.length}',
            ),
            Expanded(
              child: friends.isEmpty
                  ? _empty(async.isLoading)
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: groups.length,
                      itemBuilder: (context, index) {
                        final name = groups.keys.elementAt(index);
                        final members = groups[name]!;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            TelegramSectionHeader(
                              text: '$name（${members.length}）',
                            ),
                            for (var i = 0; i < members.length; i++)
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  TgUserRow(
                                    key: ValueKey<String>(
                                      'contact-${members[i].uin}',
                                    ),
                                    leading: TelegramAvatar(
                                      name: members[i].displayName,
                                      size: 46,
                                      url: qqAvatarUrl(members[i].uin),
                                    ),
                                    title: members[i].displayName,
                                    // 备注与昵称相同时（服务端常这么返回）别再重复一遍名字。
                                    subtitle:
                                        members[i].remark.isNotEmpty &&
                                            members[i].nick.isNotEmpty &&
                                            members[i].remark != members[i].nick
                                        ? members[i].nick
                                        : 'QQ ${members[i].uin}',
                                    onTap: () =>
                                        _openProfile(context, ref, members[i]),
                                  ),
                                  if (i != members.length - 1)
                                    Container(
                                      height: 1,
                                      margin: const EdgeInsets.only(
                                        left: 64,
                                        right: 12,
                                      ),
                                      color: TelegramColors.divider,
                                    ),
                                ],
                              ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(bool loading) {
    if (loading) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 52),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.people_outline,
              size: 96,
              color: TelegramColors.textMuted,
            ),
            const SizedBox(height: 16),
            Text(
              '还没有好友',
              style: TextStyle(
                color: TelegramColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '登录后会自动同步好友列表',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: TelegramColors.textSecondary,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openProfile(
    BuildContext context,
    WidgetRef ref,
    Qq8Friend friend,
  ) async {
    // 资料页「发消息」通过 pop 回来的 chatId 表达意图：本页负责把它交给
    // pendingOpenChatProvider（HomePage 唯一的"外部打开会话"入口），再切回
    // 聊天 tab。这样资料页不需要知道导航结构。
    final chatId = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => FriendProfilePage(friend: friend),
      ),
    );
    if (chatId == null) return;
    ref.read(pendingOpenChatProvider.notifier).state = chatId;
    onOpenChats?.call();
  }
}
