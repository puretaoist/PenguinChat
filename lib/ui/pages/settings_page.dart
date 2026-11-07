/// L4 设置页：结构照 Telegram Android `ui/SettingsActivity.java`（新版 UItem / UniversalAdapter 体系）。
///
/// 与官方的对应关系（行号均在 SettingsActivity.java 内）：
/// * 顶部资料块高 188dp —— :645 asCustomShadow(topView, 200 - 12)；头像 90dp
///   圆角 90（:429-430）、名字 22sp bold（:468-469）、副标题 13sp（:476-480）。
///   官方这块没有卡片背景、没有圆角，直接压在页面灰底上。
/// * 主设置组没有分组标题；只有 Help / Experimental / Debug 这类段才有 Header
///   （:760、:768、:775）。
/// * 行 = SettingCell：图标块 28×28、圆角 dp(10)、上下渐变（:1216-1292），
///   标题 16sp、副标题 13sp，行高 dp(mini ? 44 : twoLines ? 60 : 50)（:1264），
///   不画分割线（:1327-1336 bindView 直接忽略 divider）。
/// * 段卡圆角 16dp、左右内缩 12dp（RecyclerListView.java:3289 / :3394）；
///   段与段之间是 12dp 空白（UniversalAdapter.java:757）。
/// * 退出登录不在列表里，而在 ActionBar 的更多菜单（:334-353 → LogoutActivity）。
///
/// 本页带一层入场错落淡入（每 100ms 一组，520ms 走完），必须有限时长，
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
import '../widgets/search_field_box.dart';
import '../theme/theme_mode.dart';
import '../widgets/capped_content.dart';
import '../widgets/storage_dialog.dart';
import '../widgets/telegram_avatar.dart';
import '../widgets/scroll_to_top_scope.dart';
import '../widgets/telegram_list_item.dart';
import '../widgets/tg_action_bar.dart';
import 'connect_page.dart';
import 'qq8_connect_page.dart';
import 'settings/appearance_settings_page.dart';
import 'settings/chats_settings_page.dart';
import 'settings/general_settings_page.dart';
import 'settings/other_settings_page.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({
    super.key,
    this.embedded = false,
    this.bottomContentInset = 0,
  });

  /// 胶囊占位是内部滚动留白，不裁短页面（DialogsActivity.java:2982）。
  final double bottomContentInset;

  /// 作为 HomeShell 的底栏 tab 使用时为 true：页头不画返回箭头。
  final bool embedded;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;

  /// 设置页搜索态。官方是 ActionBar 原地变形（`SettingsActivity.java:327`
  /// `searchItem.setIsSearchField(true, false)`），所以这里不用路由，
  /// 只换顶栏与列表内容。
  bool _searching = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _query = '';

  /// 设置项索引：官方 `SettingsSearchCell` 搜的是全部设置项的标题与副标题，
  /// 点一行直接进对应页面。我方二级页的项没有集中登记，这里先覆盖一级页
  /// 能直达的条目。
  List<
    ({
      String title,
      String subtitle,
      IconData icon,
      List<Color> gradient,
      VoidCallback open,
    })
  >
  get _searchIndex =>
      <
        ({
          String title,
          String subtitle,
          IconData icon,
          List<Color> gradient,
          VoidCallback open,
        })
      >[
        (
          title: '通用',
          subtitle: '数字与时间格式',
          icon: Icons.tune,
          gradient: TgIconGradients.blue,
          open: () => _open(const GeneralSettingsPage()),
        ),
        (
          title: '外观',
          subtitle: '主题、气泡、聊天列表、顶栏',
          icon: Icons.palette_outlined,
          gradient: TgIconGradients.purple,
          open: () => _open(const AppearanceSettingsPage()),
        ),
        (
          title: '聊天',
          subtitle: '通知、键盘、长按菜单',
          icon: Icons.chat_bubble_outline,
          gradient: TgIconGradients.orange,
          open: () => _open(const ChatsSettingsPage()),
        ),
        (
          title: '其他',
          subtitle: '关于与重置',
          icon: Icons.more_horiz,
          gradient: TgIconGradients.blueAlt,
          open: () => _open(const OtherSettingsPage()),
        ),
        (
          title: '存储与缓存',
          subtitle: '清缓存、查看占用',
          icon: Icons.storage_outlined,
          gradient: TgIconGradients.blueDeep,
          open: () {},
        ),
        (
          title: '连接设置',
          subtitle: 'OneBot 后端地址与令牌',
          icon: Icons.dns_outlined,
          gradient: TgIconGradients.cyan,
          open: () => _open(const ConnectPage()),
        ),
        (
          title: 'QQ 账号登录',
          subtitle: '口令 / 短信 / 扫码 / 票据，四选一',
          icon: Icons.key_rounded,
          gradient: TgIconGradients.blue,
          open: () => _open(const Qq8ConnectPage()),
        ),
        (
          title: '关于 PenguinChat',
          subtitle: '版本、两条线路与合规声明',
          icon: Icons.info_outline,
          gradient: TgIconGradients.blueLight,
          open: () => _open(const OtherSettingsPage()),
        ),
      ];

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
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() {
      _searching = true;
      _query = '';
      _searchController.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    _searchFocus.unfocus();
    _searchController.clear();
    setState(() {
      _searching = false;
      _query = '';
    });
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

    final double topInset = MediaQuery.paddingOf(context).top;
    // 宽屏左栏里（embedded）不能用"按整屏宽算的居中留白"：那会把 320dp 的
    // 左栏内容压成 108dp 宽（实测溢出）。手机上 contentHorizontalInset 本来是
    // 0，两者等价。
    final double sideInset = widget.embedded
        ? 0
        : contentHorizontalInset(context);

    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: <Widget>[
            // 官方 ActionBar 透明、占状态栏（:321-324）；主 Tab 上没有返回箭头，
            // 压栈进入的二级页才有（:297）。退出登录不在列表里，在更多菜单里
            // （:334-353）。
            if (_searching)
              _searchBar(topInset)
            else
              TgActionBar(
                title: '设置',
                topInset: topInset,
                onBack: widget.embedded
                    ? null
                    : () => Navigator.of(context).pop(),
                actions: <Widget>[
                  IconButton(
                    key: const ValueKey<String>('settings-search'),
                    onPressed: _openSearch,
                    tooltip: '搜索设置',
                    icon: Icon(
                      Icons.search,
                      color: TelegramColors.textSecondary,
                      size: 24,
                    ),
                  ),
                  if (canDisconnect) _overflowMenu(),
                ],
              ),
            if (_searching)
              Expanded(child: _searchResults())
            else
              Expanded(
                // 点当前 tab 回顶（MainTabsActivity.java:334-349 对四个 tab 都生效）。
                child: ScrollToTopScope(
                  tab: 2,
                  builder: (BuildContext context, ScrollController c) =>
                      ListView(
                        controller: c,
                        padding: EdgeInsets.only(
                          // 官方列表 padding top = 状态栏 + 12dp（:367）；状态栏已被
                          // ActionBar 吃掉，这里只留 12。
                          top: 12,
                          bottom: 24 + widget.bottomContentInset,
                          left: sideInset,
                          right: sideInset,
                        ),
                        children: <Widget>[
                          _enter(0, _profileBlock(account, status, qq8Online)),
                          _enter(1, _mainGroup()),
                          _enter(2, _titledGroup('数据', _dataRows(store))),
                          _enter(
                            3,
                            _titledGroup('连接', _connectionRows(status)),
                          ),
                          _enter(4, _titledGroup('关于', _aboutRows())),
                          _enter(5, _footer()),
                        ],
                      ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 搜索态顶栏：返回 + 搜索框。官方 `SettingsActivity.java:327` 的
  /// `setIsSearchField` 就是 ActionBar 原地换成这个样子，高度不变。
  Widget _searchBar(double topInset) {
    return Container(
      color: TelegramColors.bgHeader,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(height: topInset),
          SizedBox(
            height: TelegramMetrics.headerHeight,
            child: Row(
              children: <Widget>[
                const SizedBox(width: 6),
                IconButton(
                  key: const ValueKey<String>('settings-search-back'),
                  onPressed: _closeSearch,
                  tooltip: '退出搜索',
                  icon: Icon(
                    Icons.arrow_back,
                    color: TelegramColors.textSecondary,
                    size: 24,
                  ),
                ),
                Expanded(
                  child: SearchFieldBox(
                    controller: _searchController,
                    focusNode: _searchFocus,
                    height: 36,
                    radius: 18,
                    hintText: '搜索设置',
                    onChanged: (String value) => setState(() => _query = value),
                    onCleared: () => setState(() => _query = ''),
                  ),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchResults() {
    final String query = _query.trim().toLowerCase();
    if (query.isEmpty) {
      return Center(
        child: Text(
          '搜索设置项',
          style: TextStyle(color: TelegramColors.textMuted, fontSize: 13),
        ),
      );
    }
    final hits = _searchIndex
        .where(
          (e) =>
              e.title.toLowerCase().contains(query) ||
              e.subtitle.toLowerCase().contains(query),
        )
        .toList();
    if (hits.isEmpty) {
      return Center(
        child: Text(
          '没有匹配的设置项',
          style: TextStyle(color: TelegramColors.textMuted, fontSize: 13),
        ),
      );
    }
    return ListView(
      key: const ValueKey<String>('settings-search-results'),
      padding: EdgeInsets.only(top: 12, bottom: 24 + widget.bottomContentInset),
      children: <Widget>[
        _section(<Widget>[
          for (final e in hits)
            TgSettingRow(
              icon: e.icon,
              iconGradient: e.gradient,
              title: e.title,
              subtitle: e.subtitle,
              onTap: e.open,
            ),
        ]),
      ],
    );
  }

  /// ActionBar 右侧的「更多」：官方唯一子项是 LogOut（:334-353）。
  Widget _overflowMenu() {
    return PopupMenuButton<String>(
      key: const ValueKey<String>('settings-overflow'),
      icon: const Icon(Icons.more_vert, size: 24),
      iconColor: TelegramColors.textSecondary,
      color: TelegramColors.bgSidebar,
      tooltip: '更多',
      onSelected: (String value) {
        if (value != 'logout') return;
        unawaited(ref.read(connectionControllerProvider.notifier).disconnect());
      },
      itemBuilder: (BuildContext _) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'logout',
          // 官方 LogoutActivity 用红字 key_text_RedRegular（:253-255）。
          child: Text(
            '断开连接',
            style: TextStyle(fontSize: 16, color: TelegramColors.danger),
          ),
        ),
      ],
    );
  }

  /// 主设置组：官方这一段没有 Header（fillItems 里 :719-727 直接接 :729 的
  /// shadow）。
  Widget _mainGroup() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 资料块与第一段之间的 12dp 空白（UniversalAdapter.java:757）。
        const SizedBox(height: 12),
        _section(<Widget>[
          TgSettingRow(
            key: const ValueKey<String>('settings-general'),
            icon: Icons.tune,
            iconGradient: TgIconGradients.blue,
            title: '通用',
            subtitle: '数字与时间格式',
            onTap: () => _open(const GeneralSettingsPage()),
          ),
          TgSettingRow(
            key: const ValueKey<String>('settings-appearance'),
            icon: Icons.palette_outlined,
            iconGradient: TgIconGradients.purple,
            title: '外观',
            subtitle: '主题、气泡、聊天列表、顶栏',
            onTap: () => _open(const AppearanceSettingsPage()),
          ),
          TgSettingRow(
            key: const ValueKey<String>('settings-chats'),
            icon: Icons.chat_bubble_outline,
            iconGradient: TgIconGradients.orange,
            title: '聊天',
            subtitle: '通知、键盘、长按菜单',
            onTap: () => _open(const ChatsSettingsPage()),
          ),
          TgSettingRow(
            key: const ValueKey<String>('settings-other'),
            icon: Icons.more_horiz,
            iconGradient: TgIconGradients.blueAlt,
            title: '其他',
            subtitle: '关于与重置',
            onTap: () => _open(const OtherSettingsPage()),
          ),
        ]),
      ],
    );
  }

  List<Widget> _dataRows(ChatStore? store) {
    return <Widget>[
      TgSettingRow(
        icon: Icons.storage_outlined,
        iconGradient: TgIconGradients.blueDeep,
        title: '存储与缓存',
        subtitle: store == null ? '连接后可用' : null,
        onTap: store == null ? null : () => _openStorageDialog(context, store),
      ),
    ];
  }

  List<Widget> _connectionRows(ConnectionStatus status) {
    return <Widget>[
      TgSettingRow(
        icon: Icons.dns_outlined,
        iconGradient: TgIconGradients.cyan,
        title: '连接设置（OneBot 后端）',
        // 官方的右侧值是蓝色文字（key_windowBackgroundWhiteBlueText，:1229）。
        value: status.stateLabel,
        onTap: () => _open(const ConnectPage()),
      ),
      TgSettingRow(
        icon: Icons.key_rounded,
        iconGradient: TgIconGradients.blue,
        title: 'QQ 账号登录（自实现协议）',
        subtitle: '口令 / 短信 / 扫码 / 票据，四选一',
        onTap: () => _open(const Qq8ConnectPage()),
      ),
    ];
  }

  List<Widget> _aboutRows() {
    return <Widget>[
      TgSettingRow(
        icon: Icons.info_outline,
        iconGradient: TgIconGradients.blueLight,
        title: '关于 PenguinChat',
        subtitle: '版本、两条线路与合规声明',
        onTap: () => _open(const OtherSettingsPage()),
      ),
    ];
  }

  /// 一段：Header + 卡片。官方 Header 在卡片之外，左 padding 20
  /// （HeaderCell.java:49），卡片自身左右内缩 12dp。
  Widget _titledGroup(String title, List<Widget> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 段与段之间是 12dp 空白（UniversalAdapter.java:757）。
        const SizedBox(height: 12),
        TelegramSectionHeader(text: title),
        _section(rows),
      ],
    );
  }

  /// 段卡片：圆角 16、左右内缩 12、无行间分割线（官方 SettingCell 不画）。
  Widget _section(List<Widget> rows) {
    return TelegramTileGroup(
      inset: 12,
      radius: 16,
      divided: false,
      children: rows,
    );
  }

  Widget _footer() {
    return Padding(
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
    );
  }

  /// 顶部资料块：官方 188dp，无卡片背景，头像 90 居中，名字 22 bold，副标题
  /// 13 灰（SettingsActivity.java:645 / :410 / :429-430 / :468-480）。
  /// 整块可点进登录/管理页；官方没有在线圆点、没有 chevron。
  Widget _profileBlock(
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

    return InkWell(
      key: const ValueKey<String>('account-card'),
      onTap: () => _open(const Qq8ConnectPage()),
      child: SizedBox(
        height: 188,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            TelegramAvatar(name: title, size: 90),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: TelegramColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: TelegramColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ),
          ],
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
