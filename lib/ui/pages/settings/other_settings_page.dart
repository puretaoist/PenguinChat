/// L4 设置二级页：其他（抄 ayu `OtherPreferencesActivity` 的适用项）。
///
/// ayu 的 Other 主要是 Google 统计开关 + 注销 + 重置设置；我们没有 Google
/// SDK、也没有可注销的账号，保留「关于」与「重置所有外观设置」。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../prefs/ui_prefs.dart';
import '../../theme/telegram_theme.dart';
import '../../theme/theme_mode.dart';
import '../../widgets/about_penguinchat.dart';
import '../../widgets/telegram_list_item.dart';
import '../../widgets/capped_content.dart';
import '../../widgets/tg_action_bar.dart';

class OtherSettingsPage extends ConsumerWidget {
  const OtherSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    applyThemePalette(ref);

    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: <Widget>[
            // 二级页的 ActionBar：占状态栏、左侧返回（ActionBar.java:1400
            // 把 statusBar 高度算进条高），主 Tab 根视图没有这个箭头。
            TgActionBar(
              title: '其他',
              topInset: MediaQuery.paddingOf(context).top,
              onBack: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.only(
                  top: 8,
                  bottom: 24,
                  left: contentHorizontalInset(context),
                  right: contentHorizontalInset(context),
                ),
                children: <Widget>[
                  const TelegramSectionHeader(text: '关于'),
                  TelegramTileGroup(
                    children: <Widget>[
                      TgListTile(
                        icon: Icons.info_outline,
                        title: '关于 PenguinChat',
                        subtitle: '版本、两条线路与合规声明',
                        onTap: () => showAboutPenguinChat(context, ref),
                      ),
                    ],
                  ),
                  const TelegramSectionHeader(text: '重置'),
                  TelegramTileGroup(
                    children: <Widget>[
                      TgListTile(
                        key: const ValueKey('settings-reset-appearance'),
                        icon: Icons.restart_alt,
                        title: '重置所有外观设置',
                        subtitle: '字号/主题/气泡/列表等全部恢复默认',
                        danger: true,
                        showChevron: false,
                        onTap: () => _confirmReset(context, ref),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                    child: Text(
                      'PenguinChat · 自实现协议线路仅供学习用途',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: TelegramColors.textMuted,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: TelegramColors.bgSidebar,
        title: Text(
          '重置外观设置？',
          style: TextStyle(color: TelegramColors.textPrimary),
        ),
        content: Text(
          '字号、主题色、聊天背景、气泡圆角、列表样式等都会恢复默认，立即生效。',
          style: TextStyle(color: TelegramColors.textSecondary, fontSize: 14),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              '取消',
              style: TextStyle(color: TelegramColors.textMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('重置', style: TextStyle(color: TelegramColors.danger)),
          ),
        ],
      ),
    );
    if (ok ?? false) {
      await ref.read(uiPrefsProvider.notifier).reset();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已恢复默认外观')));
      }
    }
  }
}
