/// L4 主壳：窄屏 4 槽底栏（Telegram MainTabsActivity 同构）。
///
/// 依据（org/telegram/ui/MainTabsActivity.java / MainTabsLayout.java）：
/// - TABS_COUNT=4（:93），视觉 4 槽：聊天 / 联系人 / 设置 / 我的（第 4 槽
///   在官方是头像 createAvatar，GlassTabView.java:319）。
/// - 形态是**悬浮胶囊**：高 56dp、上下 margin 8dp、圆角 28dp、内 padding 12dp、
///   最大宽 344dp、Gravity.BOTTOM|CENTER_HORIZONTAL（MainTabsLayout.java:311-385
///   与 DialogsActivity.java:291）；内容底部留白 72dp（DialogsActivity.java:2982）。
///
/// 与官方的两处刻意差异：
/// 1. **宽屏不套底栏**——本项目宽屏是三栏工作台（左侧会话栏 + 右侧对话），
///    再叠一条底栏只会挤掉消息区，保留原来的 Row 布局。
/// 2. **打开对话时隐藏底栏**——手机上一旦进了聊天，输入栏就在底部，
///    底栏压上去会把输入框顶掉；官方也是这样（聊天页是全屏 push）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/objects.dart';
import '../../client_api/qq8_providers.dart';
import '../../client_api/session_providers.dart';
import '../theme/telegram_theme.dart';
import '../theme/theme_mode.dart';
import '../widgets/telegram_avatar.dart';
import 'contacts_page.dart';
import 'home_page.dart';
import 'my_profile_page.dart';
import 'settings_page.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({
    super.key,
    this.connecting = false,
    this.previewChats = const <Chat>[],
  });

  final bool connecting;
  final List<Chat> previewChats;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with SingleTickerProviderStateMixin {
  /// 0=聊天 1=联系人 2=设置 3=我的
  int _tab = 0;

  /// 切 Tab 的入场动画：TG 的 MainTabsLayout 切换是 200ms 内的淡入 + 轻微上浮。
  /// 只动透明度与 8dp 位移，不动布局，IndexedStack 的页面状态仍然全部保留。
  late final AnimationController _tabAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1,
  );
  late final Animation<double> _tabFade = Tween<double>(begin: 0.75, end: 1)
      .animate(CurvedAnimation(parent: _tabAnim, curve: Curves.easeOut));
  late final Animation<Offset> _tabSlide = Tween<Offset>(
    begin: const Offset(0, 0.02),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _tabAnim, curve: Curves.easeOut));

  @override
  void dispose() {
    _tabAnim.dispose();
    super.dispose();
  }

  /// 聊天 tab 里是否正打开着某个会话（窄屏"列表/对话二选一"）。
  bool _chatPaneOpen = false;

  void _onChatPaneVisibility(bool open) {
    if (_chatPaneOpen == open) return;
    setState(() => _chatPaneOpen = open);
  }

  void _selectTab(int index) {
    if (_tab == index) return;
    setState(() => _tab = index);
    _tabAnim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    applyThemePalette(ref);
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 720;

    // 宽屏：沿用原来的三栏工作台，不套底栏。
    if (wide) {
      return HomePage(
        connecting: widget.connecting,
        previewChats: widget.previewChats,
        onChatPaneVisibilityChanged: _onChatPaneVisibility,
      );
    }

    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final barHeight = _MainTabBar.height;
    // 聊天页打开对话时输入栏自身占底部，底栏必须让位。
    final showBar = !(_tab == 0 && _chatPaneOpen);
    final contentBottom = showBar ? barHeight + 8 + bottomInset : 0.0;

    final chatUnread = (ref.watch(chatsProvider).valueOrNull ?? const <Chat>[])
        .fold<int>(0, (sum, c) => sum + (c.unreadCount > 0 ? 1 : 0));

    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(bottom: contentBottom),
              child: FadeTransition(
                opacity: _tabFade,
                child: SlideTransition(
                  position: _tabSlide,
                  child: IndexedStack(
                    index: _tab,
                    children: <Widget>[
                      HomePage(
                        key: const ValueKey<String>('tab-chats'),
                        connecting: widget.connecting,
                        previewChats: widget.previewChats,
                        onChatPaneVisibilityChanged: _onChatPaneVisibility,
                      ),
                      ContactsPage(
                        key: const ValueKey<String>('tab-contacts'),
                        onOpenChats: () => _selectTab(0),
                      ),
                      const SettingsPage(
                        key: ValueKey<String>('tab-settings'),
                        embedded: true,
                      ),
                      MyProfilePage(
                        key: const ValueKey<String>('tab-profile'),
                        onOpenSettings: () => _selectTab(2),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (showBar)
            Positioned(
              left: 8,
              right: 8,
              bottom: 8 + bottomInset,
              child: Align(
                child: _MainTabBar(
                  index: _tab,
                  chatsWithUnread: chatUnread,
                  selfUin: ref.watch(qq8LoginServiceProvider).uin,
                  selfName: ref.watch(qq8LoginServiceProvider).selfNickname,
                  onSelect: _selectTab,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 悬浮胶囊底栏：宽 <= 344、高 56、圆角 28。
class _MainTabBar extends StatelessWidget {
  const _MainTabBar({
    required this.index,
    required this.chatsWithUnread,
    required this.onSelect,
    this.selfUin,
    this.selfName,
  });

  static const double height = 56;
  static const double _maxWidth = 344;

  final int index;
  final int chatsWithUnread;
  final ValueChanged<int> onSelect;
  final int? selfUin;
  final String? selfName;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('main-tab-bar'),
      height: height,
      constraints: const BoxConstraints(maxWidth: _maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        // 之前是 bgSidebar(#212121)：与会话列表底色同色 ⇒ 胶囊"看不见"，
        // 而又在它下面叠了一条 bgApp 渐变，把列表底部压出一道更黑的横带
        // （用户反馈「底栏会出现色差」）。现在列表底色统一成 bgApp，
        // 胶囊改用比背景亮一档的 bgHover + 一圈 divider 描边，悬浮感由
        // 颜色层次+阴影表达，不需要遮罩渐变。
        color: TelegramColors.bgHover,
        border: Border.all(color: TelegramColors.divider),
        borderRadius: BorderRadius.circular(28),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          _item(0, Icons.chat_bubble_outline, Icons.chat_bubble, '聊天',
              badge: chatsWithUnread),
          _item(1, Icons.people_outline, Icons.people, '联系人'),
          _item(2, Icons.settings_outlined, Icons.settings, '设置'),
          _profileItem(),
        ],
      ),
    );
  }

  Widget _item(
    int i,
    IconData icon,
    IconData activeIcon,
    String label, {
    int badge = 0,
  }) {
    final active = index == i;
    final color = active ? TelegramColors.accent : TelegramColors.textSecondary;
    return Expanded(
      child: InkWell(
        key: ValueKey<String>('main-tab-$i'),
        borderRadius: BorderRadius.circular(24),
        onTap: () => onSelect(i),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Icon(active ? activeIcon : icon, size: 22, color: color),
                if (badge > 0)
                  Positioned(
                    right: -8,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      constraints: const BoxConstraints(minWidth: 15),
                      height: 15,
                      decoration: BoxDecoration(
                        color: TelegramColors.accent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        badge > 99 ? '99+' : '$badge',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 第 4 槽是头像（官方 createAvatar）：选中时套一圈强调色。
  Widget _profileItem() {
    final active = index == 3;
    final size = 24.0;
    return Expanded(
      child: InkWell(
        key: const ValueKey<String>('main-tab-3'),
        borderRadius: BorderRadius.circular(24),
        onTap: () => onSelect(3),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              width: size + 4,
              height: size + 4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: active ? TelegramColors.accent : Colors.transparent,
                  width: 1.5,
                ),
              ),
              alignment: Alignment.center,
              child: TelegramAvatar(
                // 昵称未知时用「Q」当首字母兜底：以前写死 '我'，一进「我的」
                // 页就显示成「我的昵称：我」（用户反馈第 1 条）。
                name: (selfName?.isNotEmpty ?? false)
                    ? selfName!
                    : (selfUin == null ? '?' : 'Q'),
                size: size,
                url: selfUin == null ? null : qqAvatarUrl(selfUin!, size: 100),
              ),
            ),
            const SizedBox(height: 1),
            Text(
              '我的',
              style: TextStyle(
                color:
                    active ? TelegramColors.accent : TelegramColors.textSecondary,
                fontSize: 11,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}