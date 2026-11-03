/// L4 设置页：Telegram 设置页同构（分组标题 + 圆角卡片 + 行）。
///
/// 把原先散在主页顶栏的「存储与缓存」「连接设置」和空态里的
/// 「QQ 账号登录」收进一个页面 —— TG 的做法是所有二级操作都进设置，
/// 顶栏只留一个入口（Icons.settings → 本页）。列表组件用
/// [TelegramSectionHeader]/[TgListTile]/[TelegramTileGroup]，
/// 几何出处见 telegram_list_item.dart 的注释（HeaderCell/TextCell.java）。
///
/// 分组顺序照 TG 的设置习惯：**账号在最上**（一眼知道现在是谁），
/// 然后通用 → 消息 → 数据 → 连接 → 关于；越往后越少动。
///
/// 本页带一层**入场错落淡入**（每 60ms 一组，520ms 走完）：设置页是
/// 从右侧滑进来的第二条路径，整页"啪"一下出现显得生硬；错落幅度很小
/// （12dp / 0.55 曲线），只是让视线有个从上到下的落点。**必须有限时长**，
/// 无限动画会让 pumpAndSettle 永远等不到静止。
///
/// 本文件是 Flutter 层（L4）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/chat_store.dart';
import '../../client_api/session.dart';
import '../../client_api/session_providers.dart';
import '../prefs/ui_prefs.dart';
import '../theme/telegram_theme.dart';
import '../theme/theme_accent.dart';
import '../theme/theme_mode.dart';
import '../widgets/about_penguinchat.dart';
import '../widgets/pressable_scale.dart';
import '../widgets/storage_dialog.dart';
import '../widgets/chat_wallpaper.dart';
import '../widgets/telegram_avatar.dart';
import '../widgets/telegram_list_item.dart';
import '../widgets/tg_page_header.dart';
import 'connect_page.dart';
import 'qq8_connect_page.dart';

/// 设置页：账号卡 / 通用 / 消息 / 数据 / 连接 / 关于。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.embedded = false});

  /// 作为 [HomeShell] 的底栏 tab 使用时为 true：页头不画返回箭头
  /// （tab 是根视图，退回上一页没有意义），底部也给悬浮底栏留出空间。
  final bool embedded;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage>
    with SingleTickerProviderStateMixin {
  /// 整页共用一条时间线：每组用 [Interval] 取自己那段，避免 6 个
  /// AnimationController（每帧都要 tick，纯浪费）。
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
    final start = (index * 0.1).clamp(0.0, 0.6);
    final end = (start + 0.55).clamp(0.0, 1.0);
    final curved = CurvedAnimation(
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

  @override
  Widget build(BuildContext context) {
    // watch 了 themeModeProvider 的 build 必须先 applyThemePalette
    // （切暗色时本页要跟着整页重画，见 theme_mode.dart 的约定）。
    final dark = applyThemePalette(ref);
    final prefs = ref.watch(uiPrefsProvider);
    final status = ref.watch(connectionControllerProvider);
    final account = ref.watch(accountProvider);
    final store = ref.watch(chatStoreProvider);
    // 协议线（自实现 QQ）在线时 activeQq8Backend 非 null：账号卡不能只看
    // OneBot 的 ConnectionStatus，否则"协议线明明在线"却写"当前未连接"
    // （真机上就这么自相矛盾过，见 _accountCard 的注释）。
    final qq8Online = ref.watch(activeQq8BackendProvider) != null;
    // 断开只在"确实连着"时有意义；busy 中等控制器自己收尾，避免重复拆链。
    final canDisconnect =
        status.sessionState != SessionState.closed && !status.busy;

    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      // 必须 SafeArea：自绘页头不认状态栏高度，不加的话标题会压到
      // MIUI 的时钟/信号那一行上（真机实测）。
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            TgPageHeader(title: '设置', showBack: !widget.embedded),
            Expanded(
              child: ListView(
                // 嵌在底栏里时多留 80（56 胶囊 + 8 边距 + 余量），否则最后
                // 一行会被悬浮底栏压住点不到。
                padding: EdgeInsets.only(
                    top: 8, bottom: widget.embedded ? 96 : 24),
                children: [
                  _enter(0, _accountCard(context, account, status, qq8Online)),
                  _enter(
                    1,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const TelegramSectionHeader(text: '通用'),
                        TelegramTileGroup(children: [
                          TgListTile(
                            icon: Icons.dark_mode_outlined,
                            title: '外观',
                            subtitle: dark ? '暗色（当前）' : '亮色（当前）',
                            trailing: Switch(
                              // v3.31 起 activeColor 弃用，activeThumbColor 同值同义
                              activeThumbColor: TelegramColors.accent,
                              value: dark,
                              onChanged: (value) => unawaited(
                                ref
                                    .read(themeModeProvider.notifier)
                                    .setDark(value),
                              ),
                            ),
                          ),
                          TgListTile(
                            key: const ValueKey('settings-font-scale'),
                            icon: Icons.format_size,
                            title: '文字大小',
                            subtitle: UiPrefs.fontScaleLabel(prefs.fontScale),
                            onTap: () => _pickFontScale(context, ref),
                          ),
                          TgListTile(
                            key: const ValueKey('settings-accent'),
                            icon: Icons.palette_outlined,
                            title: '主题色',
                            subtitle: UiPrefs.accentLabel(prefs.accentId),
                            trailing: Container(
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                color: accentChoiceOf(prefs.accentId).isDefault
                                    ? null
                                    : accentChoiceOf(prefs.accentId).color,
                                gradient: accentChoiceOf(prefs.accentId).isDefault
                                    ? const LinearGradient(
                                        colors: <Color>[
                                          Color(0xFF8774E1),
                                          Color(0xFF3390EC),
                                        ],
                                      )
                                    : null,
                                shape: BoxShape.circle,
                              ),
                            ),
                            onTap: () => _pickAccent(context, ref),
                          ),
                          TgListTile(
                            key: const ValueKey('settings-wallpaper'),
                            icon: Icons.wallpaper_outlined,
                            title: '聊天背景',
                            subtitle: UiPrefs.wallpaperLabel(prefs.wallpaperId),
                            onTap: () => _pickWallpaper(context, ref),
                          ),
                        ]),
                      ],
                    ),
                  ),
                  _enter(
                    2,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const TelegramSectionHeader(text: '消息'),
                        TelegramTileGroup(children: [
                          TgListTile(
                            icon: Icons.notifications_active_outlined,
                            title: '消息通知',
                            subtitle: '应用在后台时收到新消息弹系统通知',
                            trailing: Switch(
                              activeThumbColor: TelegramColors.accent,
                              value: prefs.notifications,
                              onChanged: (value) => unawaited(
                                ref
                                    .read(uiPrefsProvider.notifier)
                                    .setNotifications(value),
                              ),
                            ),
                          ),
                          TgListTile(
                            icon: Icons.animation,
                            title: '消息入场动画',
                            subtitle: '新消息气泡淡入并轻微上浮',
                            trailing: Switch(
                              activeThumbColor: TelegramColors.accent,
                              value: prefs.messageAnimations,
                              onChanged: (value) => unawaited(
                                ref
                                    .read(uiPrefsProvider.notifier)
                                    .setMessageAnimations(value),
                              ),
                            ),
                          ),
                        ]),
                      ],
                    ),
                  ),
                  _enter(
                    3,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const TelegramSectionHeader(text: '数据'),
                        TelegramTileGroup(children: [
                          TgListTile(
                            icon: Icons.storage_outlined,
                            title: '存储与缓存',
                            subtitle: store == null ? '连接后可用' : null,
                            onTap: store == null
                                ? null
                                : () => _openStorageDialog(context, store),
                          ),
                        ]),
                      ],
                    ),
                  ),
                  _enter(
                    4,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
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
                            showChevron: false,
                            onTap: canDisconnect
                                ? () => unawaited(
                                    ref
                                        .read(connectionControllerProvider
                                            .notifier)
                                        .disconnect(),
                                  )
                                : null,
                          ),
                        ]),
                      ],
                    ),
                  ),
                  _enter(
                    5,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const TelegramSectionHeader(text: '关于'),
                        TelegramTileGroup(children: [
                          TgListTile(
                            icon: Icons.info_outline,
                            title: '关于 PenguinChat',
                            subtitle: '版本、两条线路与合规声明',
                            onTap: () => _showAbout(context, ref),
                          ),
                        ]),
                      ],
                    ),
                  ),
                  // 页脚：TG 设置页底部也是这么一行灰字（版本 + 说明），
                  // 不做成可点行，纯装饰。
                  _enter(
                    6,
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

  /// 字号选择：底部弹层里给四档（UiPrefs.fontScaleChoices）。
  ///
  /// 用弹层而不是就地循环：档位以后只会变多，弹层能加滚动，
  /// 设置页里塞一排单选按钮会把这一组撑得很高。
  Future<void> _pickFontScale(BuildContext context, WidgetRef ref) async {
    final current = ref.read(uiPrefsProvider).fontScale;
    final picked = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: TelegramColors.bgSidebar,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  Text(
                    '文字大小',
                    style: TextStyle(
                      color: TelegramColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '立即生效',
                    style: TextStyle(
                      color: TelegramColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: TelegramColors.divider),
            for (final value in UiPrefs.fontScaleChoices)
              TgUserRow(
                key: ValueKey<String>('font-scale-$value'),
                leading: SizedBox(
                  width: 28,
                  child: Icon(
                    Icons.text_fields,
                    size: 18,
                    color: value == current
                        ? TelegramColors.accent
                        : TelegramColors.textMuted,
                  ),
                ),
                title: UiPrefs.fontScaleLabel(value),
                subtitle: 'x$value',
                trailing: value == current
                    ? Icon(Icons.check, size: 18, color: TelegramColors.accent)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(value),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      await ref.read(uiPrefsProvider.notifier).setFontScale(picked);
    }
  }

  /// 主题色选择：底部弹层里铺全部色板。
  Future<void> _pickAccent(BuildContext context, WidgetRef ref) async {
    final current = ref.read(uiPrefsProvider).accentId;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: TelegramColors.bgSidebar,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  Text(
                    '主题色',
                    style: TextStyle(
                      color: TelegramColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '立即生效',
                    style: TextStyle(
                      color: TelegramColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: TelegramColors.divider),
            for (final choice in accentChoices)
              TgUserRow(
                key: ValueKey<String>('accent-${choice.id}'),
                leading: SizedBox(
                  width: 28,
                  child: Center(
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: choice.isDefault ? null : choice.color,
                        gradient: choice.isDefault
                            ? const LinearGradient(
                                colors: <Color>[
                                  Color(0xFF8774E1),
                                  Color(0xFF3390EC),
                                ],
                              )
                            : null,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
                title: choice.name,
                trailing: choice.id == current
                    ? Icon(Icons.check, size: 18, color: TelegramColors.accent)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(choice.id),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      await ref.read(uiPrefsProvider.notifier).setAccentId(picked);
    }
  }

  /// 聊天背景选择：每行左侧给一个小预览块。
  Future<void> _pickWallpaper(BuildContext context, WidgetRef ref) async {
    final current = ref.read(uiPrefsProvider).wallpaperId;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: TelegramColors.bgSidebar,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  Text(
                    '聊天背景',
                    style: TextStyle(
                      color: TelegramColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '立即生效',
                    style: TextStyle(
                      color: TelegramColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: TelegramColors.divider),
            for (final wall in wallpaperChoices)
              TgUserRow(
                key: ValueKey<String>('wallpaper-${wall.id}'),
                leading: SizedBox(
                  width: 28,
                  child: Center(
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: wall.isPlain ? TelegramColors.bgChat : null,
                        gradient: wall.isPlain
                            ? null
                            : LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: wall.colors,
                              ),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: TelegramColors.divider),
                      ),
                    ),
                  ),
                ),
                title: wall.name,
                trailing: wall.id == current
                    ? Icon(Icons.check, size: 18, color: TelegramColors.accent)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(wall.id),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      await ref.read(uiPrefsProvider.notifier).setWallpaperId(picked);
    }
  }

  /// 账号卡：TG 设置页顶部的「头像 + 名字 + 状态」，**整卡可点**直接去
  /// 登录/管理页（TG 里点头像卡进 EditProfile，这里进账号页）。
  Widget _accountCard(
    BuildContext context,
    AccountInfo? account,
    ConnectionStatus status,
    bool qq8Online,
  ) {
    final nickname = account?.nickname;
    final hasName = nickname != null && nickname.isNotEmpty;
    // 昵称空时不写「未登录」：这张卡读的是 OneBot 后端的账号，协议线在线时
    // 写「未登录」会自相矛盾（真机上就这么显示过），退成 QQ 号更诚实。
    final title =
        hasName ? nickname : (account == null ? '未登录' : 'QQ ${account.uin}');
    final connected = status.isConnected || qq8Online;
    // 同一张卡要能说清"哪条线在通"：协议线在线时地址是空的，不能说"已连接"。
    final String onlineLabel = status.isConnected
        ? (status.address ?? '已连接')
        : '自实现协议线路已上线';
    final subtitle = account == null
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
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const Qq8ConnectPage()),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  TelegramAvatar(name: title, size: 56),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
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
                            // 在线小绿点：比整段文字更快的"通没通"信号。
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
                        // 状态胶囊只在真正连通时出现：没连时写「未连接」会和
                        // 「协议线其实是通的」矛盾，宁可不显示。
                        if (connected) ...[
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: TelegramColors.accent
                                  .withValues(alpha: 0.15),
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

  /// 打开"存储与缓存"（原 home_page 的 _openStorageDialog 原样搬来）。
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
        // 先清空、再按预算清一次（store 内部会记日志）
        await store.clearMediaCache();
        await store.pruneMediaCache();
      },
      onClearHistory: () => store.clearAllHistory(),
    );
  }

  /// 「关于」：版本信息 + 两条线路的定位 + SAFETY 声明（红线摘要）。
  Future<void> _showAbout(BuildContext context, WidgetRef ref) =>
      showAboutPenguinChat(context, ref);

}
