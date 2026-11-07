/// L4 我的资料页：照 Telegram Android ui/ProfileActivity.java 的
/// myProfile=true 形态（"自己看自己"的页）。
///
/// 几何依据（行号均在 ProfileActivity.java 内）：
/// * ActionBar 全透明、不设标题（:2488-2500 只有 setBackgroundColor(TRANSPARENT)
///   + 返回键，全文没有 setTitle），头像区直接铺到状态栏后面。
/// * 首屏顶部是浮层 TopView（头像 100dp 容器 ×0.96 静息缩放 = 实显 96dp，
///   :5358-5387 / :8739）；名字 17.5sp bold（:5587-5589），状态 13.5sp
///   （:5653）、颜色 key_actionBarDefaultSubtitle。
/// * 头像下面是 ProfileActionsView，高 74dp（:3909 / ProfileActionsView.java:128），
///   内部按钮 targetHeight 54dp；宽 (w-7*(n-1)-28)/n、间距 7dp、左右 14dp、
///   圆角 16dp、图标 24dp、文字 11sp（ProfileActionsView.java:218-270）。
/// * 列表顶部 padding = getHeaderExtraHeight() = 152 + 74 = 226dp
///   （:5236 / :6056-6074），首行前还有 12dp 空隙（:13279 VIEW_TYPE_EMPTY2）。
/// * 资料行 = TextDetailCell：标题 16 / 值 13，单行 60dp + 分割线 1dp，
///   分割线左右各缩进 20dp（TextDetailCell.java:79/:117/:191/:275-277）。
/// * myProfile 页没有 Account 灰标题、没有设置项列表、没有版本行、没有
///   chevron（:10665 的 if (UserObject.isUserSelf(user) && !myProfile) 分支才
///   建设置列表；设置入口已迁到 SettingsActivity 顶部资料块）。
///
/// 三按钮的文案按本项目能力落地（官方是改头像 / 编辑资料 / 设置；QQ 协议
/// 不允许改头像与改资料，所以换成同一套几何下的三个真实入口：设置、账号
/// 登录、复制 QQ 号）。
///
/// 数据：uin / 自己昵称都来自服务层（Qq8LoginService）。登录协议不返回自己
/// 昵称，只能从群成员名单里认出自己那一条（qq8_login_service.dart 的
/// _rememberGroupMemberName）。所以本页进来时顺手 best-effort 触发一次
/// Qq8LoginService.ensureSelfNickname；认不出就退化成「QQ 号」，绝不编一个
/// 「我」当昵称。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/qq8_providers.dart';
import '../theme/telegram_theme.dart';
import '../theme/theme_mode.dart';
import '../widgets/scroll_to_top_scope.dart';
import '../widgets/telegram_avatar.dart';
import '../widgets/telegram_list_item.dart';
import '../widgets/tg_action_bar.dart';
import 'contacts_page.dart' show qqAvatarUrl;
import 'qq8_connect_page.dart';
import 'settings_page.dart';

class MyProfilePage extends ConsumerStatefulWidget {
  const MyProfilePage({super.key, this.onOpenSettings});

  /// 底栏设置 tab 的入口（由 HomeShell 传入）。为 null 时退化成压栈打开。
  final VoidCallback? onOpenSettings;

  @override
  ConsumerState<MyProfilePage> createState() => _MyProfilePageState();
}

class _MyProfilePageState extends ConsumerState<MyProfilePage> {
  /// 每次 build 都尝试一次（服务层内部有「每账号只试一次」与「未上线直接返回」
  /// 两道闸门，所以这里的额外调用是零成本的）。
  ///
  /// 不能只放在 initState：HomeShell 用 IndexedStack 全量构建四个 Tab，本页在
  /// 冷启动那一刻就被 build 了，那时还没上线 ⇒ 若只在 initState 试一次，就
  /// 永远错过了，昵称会一直是未知（真机 2026-11-01 实测踩到）。
  void _kickNicknameLookup() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // ignore: discarded_futures
      ref.read(qq8LoginServiceProvider).ensureSelfNickname();
    });
  }

  @override
  Widget build(BuildContext context) {
    applyThemePalette(ref);
    final service = ref.watch(qq8LoginServiceProvider);
    final uin = service.uin;
    final selfNickname = service.selfNickname;
    final hasNickname = selfNickname != null && selfNickname.isNotEmpty;
    _kickNicknameLookup();
    // 昵称未知时退化成账号，不显示「我」。
    final title = hasNickname
        ? selfNickname
        : (uin == null ? '未登录' : 'QQ $uin');
    final bool online = uin != null;

    final double topInset = MediaQuery.paddingOf(context).top;

    // 官方是浮层 TopView + 列表从 226dp 起画（列表 padding 盖住浮层）。这里
    // 用同一个 Stack：列表顶部留白 226，浮层绝对定位在顶部。
    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Stack(
          children: <Widget>[
            // 点当前 tab 回顶（MainTabsActivity.java:334-349 对四个 tab 都生效）。
            ScrollToTopScope(
              tab: 3,
              builder: (BuildContext context, ScrollController c) => ListView(
                controller: c,
                padding: EdgeInsets.only(
                  top: topInset + 226,
                  bottom: 32,
                  left: 12,
                  right: 12,
                ),
                children: <Widget>[
                  // 官方首行前 12dp 空隙（VIEW_TYPE_EMPTY2，:13279）。
                  const SizedBox(height: 12),
                  TelegramTileGroup(
                    inset: 0,
                    radius: 16,
                    // TextDetailCell 的分割线左右各缩进 20（:275-277）。
                    dividerIndent: 20,
                    children: <Widget>[
                      TgTextDetailRow(
                        title: 'QQ 号',
                        value: uin == null ? '未登录' : '$uin',
                        onTap: uin == null
                            ? null
                            : () => _copyUin(context, uin),
                      ),
                      // 昵称行只在真的知道昵称时出现（否则与标题重复成两行一样的字）。
                      if (hasNickname)
                        TgTextDetailRow(title: '昵称', value: selfNickname),
                      TgTextDetailRow(
                        title: '登录状态',
                        value: online ? '自实现协议线路在线' : '未登录',
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Center(
                    child: Text(
                      'PenguinChat · 自实现协议线路仅供学习用途',
                      style: TextStyle(
                        color: TelegramColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 浮层：头像 + 名字 + 状态 + 74dp 按钮行（ProfileActivity 的
            // TopView 结构），底下压着页面灰底。
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _profileHeader(
                title: title,
                subtitle: online ? '在线' : '未登录',
                uin: uin,
                topInset: topInset,
              ),
            ),
            // 官方 ActionBar 没有标题、背景透明，只是给状态栏让位。
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: TgActionBar(
                  title: '',
                  topInset: topInset,
                  transparent: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 浮层头部：状态栏 + 头像（96）+ 名字（17.5 bold）+ 状态（13.5）+ 按钮行
  /// （74dp，三个按钮）。
  Widget _profileHeader({
    required String title,
    required String subtitle,
    required int? uin,
    required double topInset,
  }) {
    return Padding(
      padding: EdgeInsets.only(top: topInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(height: 12),
          TelegramAvatar(
            name: title,
            // 官方容器 100dp × 静息缩放 0.96 = 实显 96dp（:8739）。
            size: 96,
            url: uin == null ? null : qqAvatarUrl(uin, size: 640),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: TelegramColors.textPrimary,
                // 官方 17.5sp bold（:5587-5589）。
                fontSize: 17.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: TelegramColors.textSecondary,
              // 官方 13.5sp（:5653）。
              fontSize: 13.5,
            ),
          ),
          // 官方 ProfileActionsView 高 74dp（:3909）。
          SizedBox(height: 74, child: _actionsRow(context, uin)),
        ],
      ),
    );
  }

  /// 三个按钮：官方几何 (w-7*(n-1)-28)/n、间距 7、左右 14、圆角 16、图标 24、
  /// 文字 11（ProfileActionsView.java:218-270）。
  Widget _actionsRow(BuildContext context, int? uin) {
    final List<_ProfileAction> actions = <_ProfileAction>[
      _ProfileAction(
        icon: Icons.settings_outlined,
        label: '设置',
        onTap: () => _openSettings(context),
      ),
      _ProfileAction(
        icon: Icons.key_rounded,
        label: '账号登录',
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(builder: (_) => const Qq8ConnectPage()),
        ),
      ),
      _ProfileAction(
        icon: Icons.copy_rounded,
        label: '复制 QQ 号',
        onTap: uin == null ? null : () => _copyUin(context, uin),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < actions.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 7),
            Expanded(child: _actionButton(actions[i])),
          ],
        ],
      ),
    );
  }

  Widget _actionButton(_ProfileAction action) {
    final bool enabled = action.onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: TelegramColors.bgSidebar,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: action.onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(action.icon, size: 24, color: TelegramColors.accent),
              const SizedBox(height: 3),
              Text(
                action.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: TelegramColors.textPrimary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copyUin(BuildContext context, int uin) async {
    await Clipboard.setData(ClipboardData(text: '$uin'));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('QQ 号已复制')));
  }

  void _openSettings(BuildContext context) {
    final onOpenSettings = widget.onOpenSettings;
    if (onOpenSettings != null) {
      onOpenSettings();
      return;
    }
    // 兜底：没有 tab 回调时压栈打开（例如将来从别的入口进来）。
    Navigator.of(
      context,
    ).push<void>(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
  }
}

class _ProfileAction {
  const _ProfileAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
}
