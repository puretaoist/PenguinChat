/// L4 设置二级页：通用（抄 ayu `GeneralPreferencesActivity` 的适用项）。
///
/// ayu 的 General 是"数字/时间格式 + 归档 + 资料 + 相机"，我们只保留
/// 真正有渲染层消费的两项：数字是否缩写、时间是否带秒。归档/相机/资料
/// 可见性在这些客户端里没有对应功能，按用户授权直接排除。
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

class GeneralSettingsPage extends ConsumerWidget {
  const GeneralSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 读 TelegramColors 前先把当前调色板设好（约定见 theme_mode.dart）。
    applyThemePalette(ref);
    final prefs = ref.watch(uiPrefsProvider);

    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            const TgPageHeader(title: '通用', showBack: true),
            Expanded(
              child: ListView(
                padding: EdgeInsets.only(
                  top: 8,
                  bottom: 24,
                  left: contentHorizontalInset(context),
                  right: contentHorizontalInset(context),
                ),
                children: <Widget>[
                  const TelegramSectionHeader(text: '格式'),
                  TelegramTileGroup(
                    children: <Widget>[
                      TgListTile(
                        key: const ValueKey('settings-unread-rounding'),
                        icon: Icons.filter_9_plus_outlined,
                        title: '未读数缩写',
                        subtitle: '超过 999 条显示成 1.2K',
                        trailing: Switch(
                          activeThumbColor: TelegramColors.accent,
                          // 存储字段是 disableNumberRounding（true=不缩写），
                          // 开关文案写正向，这里取反。
                          value: !prefs.disableNumberRounding,
                          onChanged: (bool value) => unawaited(
                            ref
                                .read(uiPrefsProvider.notifier)
                                .setDisableNumberRounding(!value),
                          ),
                        ),
                      ),
                      TgListTile(
                        key: const ValueKey('settings-time-with-seconds'),
                        icon: Icons.timer_outlined,
                        title: '时间带秒',
                        subtitle: '会话列表与气泡的时间显示到秒',
                        trailing: Switch(
                          activeThumbColor: TelegramColors.accent,
                          value: prefs.timeWithSeconds,
                          onChanged: (bool value) => unawaited(
                            ref
                                .read(uiPrefsProvider.notifier)
                                .setTimeWithSeconds(value),
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
