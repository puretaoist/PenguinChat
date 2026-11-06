/// L4 我的资料页：Telegram ProfileActivity(myProfile=true) 的简版。
///
/// 官方分组顺序：头像 → Account（手机号/用户名/简介）→ Settings 组 → 版本行。
/// 本项目没有手机号/用户名体系，Account 组换成「QQ 号 / 昵称」；设置组只留
/// 一个入口跳设置页（设置本身是底栏第 3 个 tab）。
///
/// 「关于」**只在设置页**有一份（TG 也是 Settings → About）：本页原先自己又
/// 写了一个 _showAbout，文案与设置页那份还不一样，两处「关于」互相打脸。
///
/// 数据：uin / 自己昵称都来自服务层（[Qq8LoginService]）。**登录协议不返回
/// 自己昵称**，只能从群成员名单里认出自己那一条（qq8_login_service.dart 的
/// _rememberGroupMemberName）。所以本页进来时顺手 best-effort 触发一次
/// [Qq8LoginService.ensureSelfNickname]；认不出就退化成「QQ 号」，
/// **绝不编一个「我」当昵称**（用户反馈：我的界面昵称是「我」）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/qq8_providers.dart';
import '../theme/telegram_theme.dart';
import '../theme/theme_mode.dart';
import '../widgets/telegram_avatar.dart';
import '../widgets/telegram_list_item.dart';
import '../widgets/tg_page_header.dart';
import 'contacts_page.dart' show qqAvatarUrl;
import 'settings_page.dart';

class MyProfilePage extends ConsumerStatefulWidget {
  const MyProfilePage({super.key, this.onOpenSettings});

  /// 底栏设置 tab 的入口（由 [HomeShell] 传入）。为 null 时退化成压栈打开。
  final VoidCallback? onOpenSettings;

  @override
  ConsumerState<MyProfilePage> createState() => _MyProfilePageState();
}

class _MyProfilePageState extends ConsumerState<MyProfilePage> {
  /// 每次 build 都尝试一次（服务层内部有「每账号只试一次」与「未上线直接返回」
  /// 两道闸门，所以这里的额外调用是零成本的）。
  ///
  /// **不能只放在 initState**：HomeShell 用 IndexedStack 全量构建四个 Tab，
  /// 本页在**冷启动那一刻**就被 build 了，那时还没上线 ⇒ 若只在 initState 试
  /// 一次，就永远错过了，昵称会一直是未知（真机 2026-11-01 实测踩到）。
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

    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            const TgPageHeader(title: '我的'),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: <Widget>[
                  const SizedBox(height: 24),
                  Center(
                    child: TelegramAvatar(
                      name: title,
                      size: 100,
                      url: uin == null ? null : qqAvatarUrl(uin, size: 640),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: TelegramColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  // 标题已经是「QQ <uin>」时不要再重复一遍同样的文字。
                  if (hasNickname) ...[
                    const SizedBox(height: 4),
                    Text(
                      uin == null ? '未登录' : 'QQ $uin',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: TelegramColors.textSecondary,
                        fontSize: 13.5,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  const TelegramSectionHeader(text: '账号'),
                  TelegramTileGroup(
                    children: <Widget>[
                      TgListTile(
                        icon: Icons.badge_outlined,
                        title: 'QQ 号',
                        subtitle: uin == null ? '未登录' : '$uin',
                        showChevron: false,
                        onTap: uin == null
                            ? null
                            : () => _copyUin(context, uin),
                      ),
                      // 昵称行只在真的知道昵称时出现（否则与标题重复成两行一样的字）。
                      if (hasNickname)
                        TgListTile(
                          icon: Icons.person_outline,
                          title: '昵称',
                          subtitle: selfNickname,
                          showChevron: false,
                        ),
                    ],
                  ),
                  const TelegramSectionHeader(text: '设置'),
                  TelegramTileGroup(
                    children: <Widget>[
                      TgListTile(
                        icon: Icons.settings_outlined,
                        title: '设置',
                        subtitle: '外观、文字大小、通知与数据',
                        onTap: () => _openSettings(context),
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
          ],
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
