/// L4 设置页：一级列表（结构照 ayu `MainPreferencesActivity`）。
///
/// 与以前"单页 7 分组"的区别：把所有可调配项收进四个二级页
/// （通用 / 外观 / 聊天 / 其他），一级只留入口卡片 + 存储/连接/关于，
/// 和 TG/ayu 的"设置列表 → 二级详情"一致，避免设置页越加越长。
///
/// 分组顺序：**账号在最上**（一眼知道现在是谁），然后 设置 → 数据 → 连接 → 关于。
///
/// 本页带一层**入场错落淡入**（每 60ms 一组，520ms 走完），必须有限时长，
/// 否则 pumpAndSettle 永远等不到静止。
///
/// 本文件是 Flutter 层（L4）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/chat_store.dart';
import '../../client_api/session.dart';
import '../../client_api/session_providers.dart';
import '../theme/telegram_theme.dart';
import '../theme/theme_mode.dart';
import '../widgets/capped_content.dart';
import '../widgets/pressable_scale.dart';
import '../widgets/storage_dialog.dart';
import '../widgets/telegram_avatar.dart';
import '../widgets/telegram_list_item.dart';
import '../widgets/tg_page_header.dart';
import 'connect_page.dart';
import 'qq8_connect_page.dart';
import 'settings/appearance_settings_page.dart';
import 'settings/chats_settings_page.dart';
import 'settings/general_settings_page.dart';
import 'settings/other_settings_page.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.embedded = false});

  /// 作为 [HomeShell] 的底栏 tab 使用时为 true：页头不画返回箭头。
  final bool embedded;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    )..forward();
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  /// 第 [index] 组的入场包装（淡入 + 12dp 上浮）。
  Widget _enter(int index, Widget child) {
    final double start = (index * 0.1).clamp(0.0, 0.6);
    final double end = (start + 0.55).clamp(0.0, 1.0);
    final CurvedAnimation curved = CurvedAnimation(
      parent: _entrance,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: curved,
      child: AnimatedBuilder(
        animation: curved,
        builder: (_, Widget? c) => Transform.translate(
          offset: Offset(0, 12 * (1 - curved.value)),
          child: c,
        ),
        child: child,
      ),
    );
  }

  void _open(Widget page) {
    unawaited(
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 读 TelegramColors 前先按当前主题把调色板设好（约定见 theme_mode.dart）。
    applyThemePalette(ref);
    final status = ref.watch(connectionControllerProvider);
    final account = ref.watch(accountProvider);
    final store = ref.watch(chatStoreProvider);
    // 协议线（自实现 QQ）在线时 activeQq8Backend 非 null：账号卡不能只看
    // OneBot 的 ConnectionStatus，否则"协议线明明在线"却写"当前未连接"。
    final bool qq8Online = ref.watch(activeQq8BackendProvider) != null;
    final bool canDisconnect =
        status.sessionState != SessionState.closed && !status.busy;

    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            TgPageHeader(title: '设置', showBack: !widget.embedded),
            Expanded(
              child: ListView(
                padding: EdgeInsets.only(
                  top: 8,
                  bottom: widget.embedded ? 96 : 24,
                  // 宽屏左栏里（embedded）不能用"按整屏宽算的居中留白"：
                  // 那会把 320dp 的左栏内容压成 108dp 宽（实测溢出）。
                  // 手机上 contentHorizontalInset 本来就是 0，两者等价。
                  left: widget.embedded ? 0 : contentHorizontalInset(context),
                  right: widget.embedded ? 0 : contentHorizontalInset(context),
                ),
                children: <Widget>[
                  _enter(0, _accountCard(context, account, status, qq8Online)),
                  _enter(
                    1,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const TelegramSectionHeader(text: '设置'),
                        TelegramTileGroup(
                          children: <Widget>[
                            TgListTile(
                              key: const ValueKey('settings-general'),
                              icon: Icons.tune,
                              title: '通用',
                              subtitle: '数字与时间格式',
                              onTap: () => _open(const GeneralSettingsPage()),
                            ),
                            TgListTile(
                              key: const ValueKey('settings-appearance'),
                              icon: Icons.palette_outlined,
                              title: '外观',
                              subtitle: '主题、气泡、聊天列表、顶栏',
                              onTap: () =>
                                  _open(const AppearanceSettingsPage()),
                            ),
                            TgListTile(
                              key: const ValueKey('settings-chats'),
                              icon: Icons.chat_bubble_outline,
                              title: '聊天',
                              subtitle: '通知、键盘、长按菜单',
                              onTap: () => _open(const ChatsSettingsPage()),
                            ),
                            TgListTile(
                              key: const ValueKey('settings-other'),
                              icon: Icons.more_horiz,
                              title: '其他',
                              subtitle: '关于与重置',
                              onTap: () => _open(const OtherSettingsPage()),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _enter(
                    2,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const TelegramSectionHeader(text: '数据'),
                        TelegramTileGroup(
                          children: <Widget>[
                            TgListTile(
                              icon: Icons.storage_outlined,
                              title: '存储与缓存',
                              subtitle: store == null ? '连接后可用' : null,
                              onTap: store == null
                                  ? null
                                  : () => _openStorageDialog(context, store),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _enter(
                    3,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const TelegramSectionHeader(text: '连接'),
                        TelegramTileGroup(
                          children: <Widget>[
                            TgListTile(
                              icon: Icons.dns_outlined,
                              title: '连接设置（OneBot 后端）',
                              subtitle: status.stateLabel,
                              onTap: () => _open(const ConnectPage()),
                            ),
                            TgListTile(
                              icon: Icons.key_rounded,
                              title: 'QQ 账号登录（自实现协议）',
                              subtitle: '口令 / 短信 / 扫码 / 票据，四选一',
                              onTap: () => _open(const Qq8ConnectPage()),
                            ),
                            TgListTile(
                              icon: Icons.link_off_rounded,
                              title: '断开连接',
                              danger: true,
                              showChevron: false,
                              onTap: canDisconnect
                                  ? () => unawaited(
                                      ref
                                          .read(
                                            connectionControllerProvider
                                                .notifier,
                                          )
                                          .disconnect(),
                                    )
                                  : null,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _enter(
                    4,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const TelegramSectionHeader(text: '关于'),
                        TelegramTileGroup(
                          children: <Widget>[
                            TgListTile(
                              icon: Icons.info_outline,
                              title: '关于 PenguinChat',
                              subtitle: '版本、两条线路与合规声明',
                              onTap: () => _open(const OtherSettingsPage()),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _enter(
                    5,
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
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 账号卡：TG 设置页顶部的「头像 + 名字 + 状态」，整卡可点进登录/管理页。
  Widget _accountCard(
    BuildContext context,
    AccountInfo? account,
    ConnectionStatus status,
    bool qq8Online,
  ) {
    final String? nickname = account?.nickname;
    final bool hasName = nickname != null && nickname.isNotEmpty;
    final String title = hasName
        ? nickname
        : (account == null ? '未登录' : 'QQ ${account.uin}');
    final bool connected = status.isConnected || qq8Online;
    final String onlineLabel = status.isConnected
        ? (status.address ?? '已连接')
        : '自实现协议线路已上线';
    final String subtitle = account == null
        ? '点按登录 QQ 账号，或连接 OneBot 后端'
        : connected
        ? onlineLabel
        : '账号已缓存，当前未连接';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: PressableScale(
        child: Material(
          color: TelegramColors.bgSidebar,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('account-card'),
            onTap: () => _open(const Qq8ConnectPage()),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: <Widget>[
                  TelegramAvatar(name: title, size: 56),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: TelegramColors.textPrimary,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (connected) ...[
                              const SizedBox(width: 6),
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: TelegramColors.online,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: TelegramColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                        if (connected) ...[
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: TelegramColors.accent.withValues(
                                alpha: 0.15,
                              ),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              status.isConnected ? status.stateLabel : '已上线',
                              style: TextStyle(
                                color: TelegramColors.accent,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 22,
                    color: TelegramColors.textMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 打开"存储与缓存"。
  Future<void> _openStorageDialog(BuildContext context, ChatStore store) async {
    final stats = await store.storageStats();
    if (!context.mounted) return;
    await StorageDialog.show(
      context,
      stats: stats,
      limitsNote:
          '媒体缓存上限 ${StorageStats.formatBytes(store.maxCacheBytes)} · 保留 '
          '${store.keepMediaFor == null ? '永久' : '${store.keepMediaFor!.inDays} 天'}',
      onClearCache: () async {
        await store.clearMediaCache();
        await store.pruneMediaCache();
      },
      onClearHistory: () => store.clearAllHistory(),
    );
  }
}
