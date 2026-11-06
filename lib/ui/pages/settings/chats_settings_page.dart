/// L4 设置二级页：聊天（抄 ayu `ChatsPreferencesActivity` 的适用项）。
///
/// 贴纸/相机/视频消息/双击动作/快捷方式这些没有对应渲染层，按用户授权排除；
/// 保留"消息通知 + 滚动收键盘 + 长按菜单项可见性"——这三类都能被现有
/// message_actions.dart / home_page.dart 真正消费。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../prefs/ui_prefs.dart';
import '../../theme/telegram_theme.dart';
import '../../theme/theme_mode.dart';
import '../../widgets/telegram_list_item.dart';
import '../../widgets/capped_content.dart';
import '../../widgets/tg_page_header.dart';

class ChatsSettingsPage extends ConsumerWidget {
  const ChatsSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    applyThemePalette(ref);
    final prefs = ref.watch(uiPrefsProvider);

    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            const TgPageHeader(title: '聊天', showBack: true),
            Expanded(
              child: ListView(
                padding: EdgeInsets.only(
                  top: 8,
                  bottom: 24,
                  left: contentHorizontalInset(context),
                  right: contentHorizontalInset(context),
                ),
                children: <Widget>[
                  const TelegramSectionHeader(text: '消息'),
                  TelegramTileGroup(
                    children: <Widget>[
                      TgListTile(
                        key: const ValueKey('settings-notifications'),
                        icon: Icons.notifications_active_outlined,
                        title: '消息通知',
                        subtitle: '应用在后台时收到新消息弹系统通知',
                        trailing: Switch(
                          activeThumbColor: TelegramColors.accent,
                          value: prefs.notifications,
                          onChanged: (bool value) => unawaited(
                            ref
                                .read(uiPrefsProvider.notifier)
                                .setNotifications(value),
                          ),
                        ),
                      ),
                      TgListTile(
                        key: const ValueKey('settings-hide-keyboard-on-scroll'),
                        icon: Icons.keyboard_hide_outlined,
                        title: '滚动时收起键盘',
                        subtitle: '上下翻消息时自动隐藏输入法',
                        trailing: Switch(
                          activeThumbColor: TelegramColors.accent,
                          value: prefs.hideKeyboardOnScroll,
                          onChanged: (bool value) => unawaited(
                            ref
                                .read(uiPrefsProvider.notifier)
                                .setHideKeyboardOnScroll(value),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const TelegramSectionHeader(text: '长按消息菜单'),
                  TelegramTileGroup(
                    children: <Widget>[
                      TgListTile(
                        key: const ValueKey('settings-menu-copy'),
                        icon: Icons.copy_outlined,
                        title: '显示「复制」',
                        trailing: Switch(
                          activeThumbColor: TelegramColors.accent,
                          value: prefs.menuShowCopy,
                          onChanged: (bool value) => unawaited(
                            ref
                                .read(uiPrefsProvider.notifier)
                                .setMenuShowCopy(value),
                          ),
                        ),
                      ),
                      TgListTile(
                        key: const ValueKey('settings-menu-forward'),
                        icon: Icons.forward,
                        title: '显示「转发」',
                        trailing: Switch(
                          activeThumbColor: TelegramColors.accent,
                          value: prefs.menuShowForward,
                          onChanged: (bool value) => unawaited(
                            ref
                                .read(uiPrefsProvider.notifier)
                                .setMenuShowForward(value),
                          ),
                        ),
                      ),
                      TgListTile(
                        key: const ValueKey('settings-menu-delete'),
                        icon: Icons.delete_outline,
                        title: '显示「删除（仅本地）」',
                        trailing: Switch(
                          activeThumbColor: TelegramColors.accent,
                          value: prefs.menuShowDelete,
                          onChanged: (bool value) => unawaited(
                            ref
                                .read(uiPrefsProvider.notifier)
                                .setMenuShowDelete(value),
                          ),
                        ),
                      ),
                      TgListTile(
                        key: const ValueKey('settings-menu-recall'),
                        icon: Icons.undo,
                        title: '显示「撤回」',
                        subtitle: '仅自己发出且服务端支持撤回时出现',
                        trailing: Switch(
                          activeThumbColor: TelegramColors.accent,
                          value: prefs.menuShowRecall,
                          onChanged: (bool value) => unawaited(
                            ref
                                .read(uiPrefsProvider.notifier)
                                .setMenuShowRecall(value),
                          ),
                        ),
                      ),
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
}
