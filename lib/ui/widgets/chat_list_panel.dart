/// L4 表现层：会话侧栏（Telegram Desktop 左栏）。
///
/// 从 home_page.dart 抽出的**纯哑视图**：不碰 Riverpod，数据与回调全部
/// 由 [HomePage] 注入 —— 与 Qq8ConnectView 同一套「哑视图 + 宿主」拆法，
/// widget 测试可以直接喂假数据，不必先连上后端。
///
/// 几何出处（telegram-src/TelegramAndroid）：会话行抄
/// `Cells/DialogCell.java:170-171`（avatarStart = 11、messagePaddingStart
/// = 72 = 11 + 52 + 9）；归档入口行高 52；搜索框高 38、圆角 inputRadius。
library;

import 'package:flutter/material.dart';

import '../../client_api/chat_store.dart';
import '../../client_api/objects.dart';
import '../theme/telegram_theme.dart';
import 'message_bubble.dart' show formatTime;
import 'telegram_avatar.dart';
import 'tg_page_header.dart';

/// 会话侧栏：搜索条 + 归档入口 + 会话列表（下拉刷新、空态、未读徽章）。
class ChatListPanel extends StatelessWidget {
  const ChatListPanel({
    super.key,
    required this.chats,
    required this.store,
    required this.selectedChatId,
    required this.onOpenChat,
    required this.onLongPressChat,
    required this.onRefresh,
    required this.onOpenSearch,
    required this.onToggleTheme,
    required this.onOpenSettings,
    required this.onOpenArchive,
    required this.onOpenConnect,
    this.connecting = false,
    required this.onOpenQq8Login,
    this.onArchiveChat,
    this.onToggleMuteChat,
  });

  /// 会话列表快照（含归档；归档行只出现在顶部入口）。
  final List<Chat> chats;

  /// 空态要区分「没连后端」和「连了但没会话」，所以把 store 带进来。
  final ChatStore? store;

  /// store 仍是 null、但账号恢复正在进行中（冷启动壳在超时后先放人进来）。
  ///
  /// 这时既不是「用户没配后端」也不是「没有会话」，空态不能写「未连接后端」
  /// 去催用户配置——那是假消息。只显示等待态，登录完成后本子树自然重建出列表。
  final bool connecting;

  /// 当前选中的会话 id（选中行翻色，见 [_chatTile]）。
  final String? selectedChatId;
  final ValueChanged<Chat> onOpenChat;

  /// 长按会话 → 宿主弹操作单（置顶/免打扰/归档/删除）。
  final void Function(Chat chat, ChatStore? store) onLongPressChat;

  /// 下拉刷新（RefreshIndicator 要求返回 Future）。
  final Future<void> Function() onRefresh;
  final VoidCallback onOpenSearch;
  final VoidCallback onToggleTheme;
  final VoidCallback onOpenSettings;
  final void Function(List<Chat> archived, ChatStore? store) onOpenArchive;
  final VoidCallback onOpenConnect;
  final VoidCallback onOpenQq8Login;

  /// 左滑一行 = 归档（TG Android 的 swipe-to-archive）。
  ///
  /// 传 null 表示不提供滑动手势（widget 测试与纯展示场景）。
  final Future<void> Function(Chat chat)? onArchiveChat;

  /// 右滑一行 = 静音/取消静音（TG 的 swipe action 之一）。
  final Future<void> Function(Chat chat)? onToggleMuteChat;

  @override
  Widget build(BuildContext context) {
    // 归档会话不进主列表（TG/Nagram 的 Archived chats：只从顶部入口进）
    final visible = chats.where((c) => !c.archived).toList(growable: false);
    final archived = chats.where((c) => c.archived).toList(growable: false);
    return Container(
      // 与其他三个 Tab（联系人/设置/我的，都是 bgApp）统一：以前这里是
      // bgSidebar #212121，切 Tab 时整块底色会跳一下（用户反馈第 5 条）。
      color: TelegramColors.bgApp,
      child: Column(
        children: [
          // 聊天 Tab 以前没有标题页头（只有一条搜索框），四个 Tab 里唯一
          // 一个"没有名字"的页面。现在补上，并把切换主题/设置两个入口从
          // 搜索框右侧挪到页头右侧（TG 也是 ActionBar 右侧放设置）。
          TgPageHeader(
            title: '聊天',
            trailing: <Widget>[
              IconButton(
                key: const ValueKey('toggle-theme'),
                onPressed: onToggleTheme,
                icon: Icon(
                  TelegramColors.isDark
                      ? Icons.light_mode
                      : Icons.dark_mode,
                  size: 20,
                  color: TelegramColors.textSecondary,
                ),
                tooltip: '切换亮色 / 暗色',
              ),
              IconButton(
                onPressed: onOpenSettings,
                icon: Icon(
                  Icons.settings,
                  size: 20,
                  color: TelegramColors.textSecondary,
                ),
                tooltip: '设置',
              ),
            ],
          ),
          _buildSearchBar(),
          // 有预览列表但还没连上时，列表顶部压一条 2px 的强调色细线：提醒
          // "这些是缓存，正在后台恢复连接"。
          //
          // 刻意用**静态**细线而不是 LinearProgressIndicator：后者是无限
          // 动画，会一直向引擎要帧（低端机/ debug 包上是持续的掉帧源），
          // 而这条线要表达的信息只有"还没连上"，静态就够。
          if (store == null && connecting)
            Container(
              key: const ValueKey('preview-connecting-line'),
              height: 2,
              color: TelegramColors.accent.withValues(alpha: 0.7),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: onRefresh,
              color: TelegramColors.accent,
              backgroundColor: TelegramColors.bgHover,
              child: visible.isEmpty && archived.isEmpty
                  ? _buildSidebarEmpty()
                  : ListView.builder(
                      addAutomaticKeepAlives: false,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      // 第一行是"已归档"入口（没有归档会话时不占位置）
                      itemCount: visible.length + (archived.isEmpty ? 0 : 1),
                      itemBuilder: (_, i) {
                        final total =
                            visible.length + (archived.isEmpty ? 0 : 1);
                        final Widget row;
                        if (archived.isNotEmpty && i == 0) {
                          row = _archivedRow(archived);
                        } else {
                          final chat = visible[i - (archived.isEmpty ? 0 : 1)];
                          row = _swipeable(chat, _chatTile(chat));
                        }
                        // 行间 1px 分隔线：TG `Cells/DialogCell.java` 的
                        // needDivider 画法——从文字起点（messagePaddingStart
                        // = 72 = 11 + 52 + 9）画到右缘，最后一行不画。
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            row,
                            if (i != total - 1)
                              Container(
                                height: 1,
                                margin: const EdgeInsets.only(left: 72),
                                color: TelegramColors.divider,
                              ),
                          ],
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      // TG 的搜索条外边距 14、高 36、圆角 18、字号 16、图标 24
      // （DialogsActivity 的 searchLayout / Theme.dialogs_searchField）。我们
      // 原来 38/20/14/18，量出来比 TG 小半号，而且左右留白偏窄。
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      child: Row(
        children: [
          Expanded(
            // 点一下进搜索页（之前这里只是个壳，点了没反应）
            child: InkWell(
              key: const ValueKey('open-search'),
              borderRadius: BorderRadius.circular(TelegramMetrics.inputRadius),
              onTap: onOpenSearch,
              child: Container(
                height: 36,
                decoration: BoxDecoration(
                  color: TelegramColors.bgHover,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    Icon(
                      Icons.search,
                      size: 22,
                      color: TelegramColors.textSecondary,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '搜索会话与消息',
                      style: TextStyle(
                        color: TelegramColors.textSecondary,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 归档入口：一行"已归档 (N)"，点开看归档里的会话。
  Widget _archivedRow(List<Chat> archived) {
    return InkWell(
      key: const ValueKey('archived-row'),
      onTap: () => onOpenArchive(archived, store),
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(
              Icons.archive_outlined,
              size: 20,
              color: TelegramColors.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '已归档',
                style: TextStyle(
                  color: TelegramColors.textPrimary,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '${archived.length}',
              style: TextStyle(
                color: TelegramColors.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right,
              size: 20,
              color: TelegramColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }

  /// 列表为空时也要能下拉刷新，所以用可滚动容器包一层。
  Widget _buildSidebarEmpty() {
    // 恢复中 vs 真没连：文案与入口完全不同，先算一次。
    final bool pending = store == null && connecting;
    // TG 空态（Cells/DialogsEmptyCell.java:84/90/100/103/109）：整块**垂直居中**、
    // 图 100、标题 20 粗、说明 14、左右各 52 的留白。我们原来是顶部起 60px
    // 左对齐小字，看起来像一条提示而不是"这里本来就没内容"。
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 52, vertical: 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    pending
                        ? Icons.sync
                        : (store == null ? Icons.link_off : Icons.inbox_outlined),
                    color: TelegramColors.textMuted,
                    size: 96,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    pending
                        ? '正在连接…'
                        : (store == null ? '未连接后端' : '暂无会话'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: TelegramColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    pending
                        ? '正在恢复上次的会话，请稍候'
                        : (store == null
                            ? '连上 OneBot 后端（NapCat 等）后，会话会出现在这里'
                            : '下拉可刷新会话列表'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: TelegramColors.textSecondary,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                  if (store == null && !pending) ...[
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: onOpenConnect,
                      child: Text(
                        '去连接设置',
                        style: TextStyle(color: TelegramColors.accent),
                      ),
                    ),
                    // 协议线（自实现 QQ 协议）的主入口：与 OneBot 线并存，一条直达。
                    const SizedBox(height: 4),
                    TextButton.icon(
                      onPressed: onOpenQq8Login,
                      icon: const Icon(Icons.key, size: 16),
                      label: const Text('QQ 账号登录（自实现协议）'),
                      style: TextButton.styleFrom(
                        foregroundColor: TelegramColors.accent,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 会话摘要：群聊显示「发送者: 正文」，私聊与老数据只显示正文。
  ///
  /// 发送者名比正文粗一档（TG dialogs_messageNamePaint 与 messagePaint 只差
  /// 字重），颜色一致，避免整行出现第三种颜色。
  Widget _preview(Chat chat, Color subColor) {
    final sender = chat.lastMessage.isEmpty ? '' : chat.lastSender.trim();
    if (!chat.isGroup || sender.isEmpty) {
      return Text(
        chat.lastMessage,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        // 摘要 dp(16)：TG 的 dialogs_messagePaint。
        style: TextStyle(color: subColor, fontSize: 16),
      );
    }
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: '$sender: ',
          style: TextStyle(
            color: subColor,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        TextSpan(
          text: chat.lastMessage,
          style: TextStyle(color: subColor, fontSize: 16),
        ),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// 滑动手势：左滑归档、右滑静音（TG Android 的 DialogCell 滑动动作）。
  ///
  /// 归档会让这一行从主列表消失，所以 [Dismissible] 直接吃掉；
  /// 静音只改字段不改列表成员，必须回弹（返回 false），否则 Dismissible
  /// 会因为"已 dismiss 但还在树里"报错。
  Widget _swipeable(Chat chat, Widget child) {
    final canArchive = onArchiveChat != null;
    final canMute = onToggleMuteChat != null;
    if (!canArchive && !canMute) return child;
    return Dismissible(
      key: ValueKey<String>('swipe-${chat.id}'),
      direction: DismissDirection.horizontal,
      background: _swipeBackground(
        alignment: Alignment.centerLeft,
        icon: chat.muted ? Icons.notifications_active : Icons.notifications_off,
        color: TelegramColors.textSecondary,
      ),
      secondaryBackground: _swipeBackground(
        alignment: Alignment.centerRight,
        icon: Icons.archive_outlined,
        color: TelegramColors.accent,
      ),
      // 两个动作都返回 false（回弹）：列表成员只由 store 的变更驱动重建。
      // 返回 true 会让 Dismissible 自己摘掉这一行，而数据层此时可能还没刷新，
      // 下一帧就会丢出 "A dismissed Dismissible widget is still part of the
      // tree" —— 归档也一样，交给 chatsProvider 重建才是一条真相。
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) {
          await onArchiveChat?.call(chat);
        } else {
          await onToggleMuteChat?.call(chat);
        }
        return false;
      },
      child: child,
    );
  }

  Widget _swipeBackground({
    required Alignment alignment,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      color: TelegramColors.bgHover,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Icon(icon, size: 22, color: color),
    );
  }

  Widget _chatTile(Chat chat) {
    final selected = chat.id == selectedChatId;
    // 选中行在亮色下是蓝色底（#3390EC），文字必须跟着翻白——
    // 否则就是黑字压蓝底。暗色的选中底是深紫，白字同样成立。
    final titleColor = selected ? Colors.white : TelegramColors.textPrimary;
    final subColor = selected
        ? Colors.white.withValues(alpha: 0.85)
        : TelegramColors.textSecondary;
    return InkWell(
      key: ValueKey('chat-row-${chat.id}'),
      onTap: () => onOpenChat(chat),
      onLongPress: () => onLongPressChat(chat, store),
      // 选中/取消选中的底色做 140ms 过渡（TG 的 DialogCell 换选中态也是渐显）。
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        // 置顶行整行带一层浅底（TG 的 chats_pinnedOverlay，DialogCell.java:4164-4188）。
        color: selected
            ? TelegramColors.bgSelected
            : (chat.pinned ? TelegramColors.bgHover : Colors.transparent),
        constraints: const BoxConstraints(
          minHeight: TelegramMetrics.chatRowHeight,
        ),
        // 几何抄 TG `Cells/DialogCell.java:170-171`：avatarStart = 11、
        // messagePaddingStart = 72（= 11 + 52 + 9）；垂直方向 70 - 52 = 18，
        // 上下各 9，正好填满 chatRowHeight。
        padding: const EdgeInsets.symmetric(
          horizontal: TelegramMetrics.chatRowPadding,
          vertical: 9,
        ),
        child: Row(
          children: [
            Stack(
              children: [
                TelegramAvatar(
                  name: chat.title,
                  url: chat.avatarUrl,
                  size: TelegramMetrics.avatarSize,
                ),
                if (chat.online)
                  Positioned(
                    right: 1,
                    bottom: 1,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: TelegramColors.online,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: TelegramColors.bgSidebar,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: TelegramMetrics.chatAvatarGap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          chat.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          // TG 的会话名一律加粗（Theme.java:7812 的 dialogs_namePaint
                          // 走 Typeface.BOLD；未读时再粗一档视觉上已经无差）——
                          // 我们原来常态 w500，整列比 TG 淡。
                          style: TextStyle(
                            color: titleColor,
                            fontSize: 17,
                            fontWeight: chat.unreadCount > 0
                                ? FontWeight.w700
                                : FontWeight.w600,
                          ),
                        ),
                      ),
                      // 免打扰：标题后一个小铃铛斜杠（TG DialogCell 的 muted 图标）。
                      if (chat.muted) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.notifications_off,
                          size: 16,
                          color: selected
                              ? Colors.white.withValues(alpha: 0.85)
                              : TelegramColors.textMuted,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  // 有草稿就显示草稿（TG/Nagram 的 `Draft:` 前缀），
                  // 不然用户会以为刚才打的字丢了
                  if (chat.draft.isNotEmpty)
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '草稿: ',
                            style: TextStyle(
                              color: selected
                                  ? Colors.white
                                  : TelegramColors.danger,
                              fontSize: 16,
                            ),
                          ),
                          TextSpan(
                            text: chat.draft.replaceAll('\n', ' '),
                            style: TextStyle(color: subColor, fontSize: 16),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  else
                    // 群聊摘要按 TG 排成「发送者: 正文」（DialogCell.java:1802-1827）：
                    // 只有正文的话，群里的消息看不出是谁说的。
                    _preview(chat, subColor),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 置顶标记放在时间左边（TG DialogCell.java:2491-2496 的小 pin），
                    // 不是压在标题前面——否则每个置顶会话的名字都要缩进。
                    if (chat.pinned) ...[
                      Icon(
                        Icons.push_pin,
                        size: 12,
                        color: selected
                            ? Colors.white.withValues(alpha: 0.85)
                            : TelegramColors.textMuted,
                      ),
                      const SizedBox(width: 3),
                    ],
                    Text(
                      chat.lastTime == null ? '' : formatTime(chat.lastTime!),
                      style: TextStyle(
                        // 有未读的会话，时间也是强调色加粗（TG dialogs_timePaint 的
                        // 未读态）。
                        color: chat.unreadCount > 0 && !selected
                            ? TelegramColors.accent
                            : subColor,
                        fontSize: TelegramMetrics.fontTimestamp,
                        fontWeight: chat.unreadCount > 0
                            ? FontWeight.w700
                            : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (chat.unreadCount > 0)
                  Container(
                    // TG 的未读数是个 22dp 高的胶囊（`dialogs_unreadCounterDrawable`
                    // 的 setSize(dp(22)...)），两位数以上自动加宽，圆角 = 高度一半。
                    constraints: const BoxConstraints(minWidth: 22),
                    height: 22,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    decoration: BoxDecoration(
                      // 选中行整行就是强调色，徽章再刷同色等于看不见——
                      // 翻成白底 + 强调色字（TG 选中会话的未读徽章就是这样）。
                      color: selected
                          ? Colors.white
                          : chat.muted
                          ? TelegramColors.textMuted
                          : TelegramColors.badge,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Text(
                      '${chat.unreadCount}',
                      style: TextStyle(
                        color: selected
                            ? TelegramColors.bgSelected
                            : Colors.white,
                        // TG 的未读数文字是 dp(12) 加粗（22dp 胶囊里就是这么排的）。
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
