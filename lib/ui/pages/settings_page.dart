/// L4 设置页：Telegram 设置页同构（分组标题 + 圆角卡片 + 行）。
///
/// 把原先散在主页顶栏的「存储与缓存」「连接设置」和空态里的
/// 「QQ 账号登录」收进一个页面 —— TG 的做法是所有二级操作都进设置，
/// 顶栏只留一个入口（Icons.settings → 本页）。列表组件用
/// [TelegramSectionHeader]/[TgListTile]/[TelegramTileGroup]，
/// 几何出处见 telegram_list_item.dart 的注释（HeaderCell/TextCell.java）。
///
/// 本文件是 Flutter 层（L4）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/chat_store.dart';
import '../../client_api/session.dart';
import '../../client_api/session_providers.dart';
import '../../infra/device/device_info.dart';
import '../theme/telegram_theme.dart';
import '../theme/theme_mode.dart';
import '../widgets/storage_dialog.dart';
import '../widgets/telegram_avatar.dart';
import '../widgets/telegram_list_item.dart';
import 'connect_page.dart';
import 'qq8_connect_page.dart';

/// 设置页：账号状态 / 通用（外观、存储）/ 连接（两条线路、断开）/ 关于。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // watch 了 themeModeProvider 的 build 必须先 applyThemePalette
    // （切暗色时本页要跟着整页重画，见 theme_mode.dart 的约定）。
    final dark = applyThemePalette(ref);
    final status = ref.watch(connectionControllerProvider);
    final account = ref.watch(accountProvider);
    final store = ref.watch(chatStoreProvider);
    // 断开只在"确实连着"时有意义；busy 中等控制器自己收尾，避免重复拆链。
    final canDisconnect =
        status.sessionState != SessionState.closed && !status.busy;

    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      body: Column(
        children: [
          // 页头与主页空态同款（headerHeight + bgHeader），不引 AppBar，
          // 免得主题里的 AppBarTheme 又多一套独立出处。
          Container(
            height: TelegramMetrics.headerHeight,
            color: TelegramColors.bgHeader,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Icon(
                    Icons.arrow_back,
                    color: TelegramColors.textSecondary,
                  ),
                ),
                Text(
                  '设置',
                  // ActionBar.java:654：手机竖屏页面标题 20dp
                  style: TextStyle(
                    color: TelegramColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                _accountCard(account, status),
                const SizedBox(height: 12),
                const TelegramSectionHeader(text: '通用'),
                TelegramTileGroup(children: [
                  TgListTile(
                    icon: Icons.dark_mode_outlined,
                    title: '外观：亮色 / 暗色',
                    subtitle: '保存在本机，下次启动照旧',
                    trailing: Switch(
                      // v3.31 起 activeColor 弃用，activeThumbColor 同值同义
                      activeThumbColor: TelegramColors.accent,
                      value: dark,
                      onChanged: (value) => unawaited(
                        ref.read(themeModeProvider.notifier).setDark(value),
                      ),
                    ),
                  ),
                  TgListTile(
                    icon: Icons.storage_outlined,
                    title: '存储与缓存',
                    subtitle: store == null ? '连接后可用' : null,
                    onTap: store == null
                        ? null
                        : () => _openStorageDialog(context, store),
                  ),
                ]),
                const SizedBox(height: 12),
                const TelegramSectionHeader(text: '连接'),
                TelegramTileGroup(children: [
                  TgListTile(
                    icon: Icons.dns_outlined,
                    title: '连接设置（OneBot 后端）',
                    subtitle: status.stateLabel,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ConnectPage(),
                      ),
                    ),
                  ),
                  TgListTile(
                    icon: Icons.key_rounded,
                    title: 'QQ 账号登录（自实现协议）',
                    subtitle: '口令 / 短信 / 扫码 / 票据，四选一',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const Qq8ConnectPage(),
                      ),
                    ),
                  ),
                  TgListTile(
                    icon: Icons.link_off,
                    title: '断开连接',
                    danger: true,
                    onTap: canDisconnect
                        ? () => unawaited(
                            ref
                                .read(connectionControllerProvider.notifier)
                                .disconnect(),
                          )
                        : null,
                  ),
                ]),
                const SizedBox(height: 12),
                const TelegramSectionHeader(text: '关于'),
                TelegramTileGroup(children: [
                  TgListTile(
                    icon: Icons.info_outline,
                    title: '关于 QQ Client',
                    onTap: () => _showAbout(context, ref),
                  ),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 账号卡：TG 设置页顶部的「头像 + 名字 + 状态」。
  Widget _accountCard(AccountInfo? account, ConnectionStatus status) {
    final nickname = account?.nickname;
    final title = nickname == null || nickname.isEmpty ? '未登录' : nickname;
    final subtitle = account == null
        ? '先在「连接」里连上 OneBot 后端，或登录 QQ 账号'
        : 'QQ ${account.uin}'
            '${status.address == null ? '' : ' · ${status.address}'}';
    final connected = status.isConnected;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        // 与 TelegramTileGroup 同一观感：圆角 12 卡片
        decoration: BoxDecoration(
          color: TelegramColors.bgSidebar,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            TelegramAvatar(name: title, size: 52),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: TelegramColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: TelegramColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            // 状态胶囊：连着才上强调色，一眼区分「能用 / 不能用」
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: connected
                    ? TelegramColors.accent.withValues(alpha: 0.15)
                    : TelegramColors.bgHover,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                status.stateLabel,
                style: TextStyle(
                  color: connected
                      ? TelegramColors.accent
                      : TelegramColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开"存储与缓存"（原 home_page 的 _openStorageDialog 原样搬来）。
  Future<void> _openStorageDialog(
    BuildContext context,
    ChatStore store,
  ) async {
    final stats = await store.storageStats();
    if (!context.mounted) return;
    await StorageDialog.show(
      context,
      stats: stats,
      limitsNote:
          '媒体缓存上限 ${StorageStats.formatBytes(store.maxCacheBytes)}'
          ' · 保留 ${store.keepMediaFor == null ? '永久' : '${store.keepMediaFor!.inDays} 天'}',
      onClearCache: () async {
        // 先清空、再按预算清一次（store 内部会记日志）
        await store.clearMediaCache();
        await store.pruneMediaCache();
      },
      onClearHistory: () => store.clearAllHistory(),
    );
  }

  /// 「关于」：版本信息 + 两条线路的定位 + SAFETY 声明（红线摘要）。
  Future<void> _showAbout(BuildContext context, WidgetRef ref) async {
    final BuildInfo info = await ref.read(deviceInfoProvider).buildInfo();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('关于 QQ Client'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '版本 ${info.appVersion}',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text(
              '提交 ${info.gitCommit} · 构建 ${info.buildTime}',
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 12),
            const Text(
              '两条线路：日用线走 OneBot（NapCat 等）；研究线是自实现 QQ '
              '协议，只作课程学习用途。',
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 6),
            Text(
              '注意：自实现协议线违反 QQ 用户协议，账号可能被永久封禁；'
              '这是刻意保留的设计取舍，不做任何规避（详见 SAFETY.md）。',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: TelegramColors.danger,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}