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
    required this.onOpenQq8Login,
  });

  /// 会话列表快照（含归档；归档行只出现在顶部入口）。
  final List<Chat> chats;

  /// 空态要区分「没连后端」和「连了但没会话」，所以把 store 带进来。
  final ChatStore? store;

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

  @override
  Widget build(BuildContext context) {
    // 归档会话不进主列表（TG/Nagram 的 Archived chats：只从顶部入口进）
    final visible = chats.where((c) => !c.archived).toList(growable: false);
    final archived = chats.where((c) => c.archived).toList(growable: false);
    return Container(
      color: TelegramColors.bgSidebar,
      child: Column(
        children: [
          _buildSearchBar(),
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
                        final row = (archived.isNotEmpty && i == 0)
                            ? _archivedRow(archived)
                            : _chatTile(
                                visible[i - (archived.isEmpty ? 0 : 1)],
                              );
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
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
      child: Row(
        children: [
          Expanded(
            // 点一下进搜索页（之前这里只是个壳，点了没反应）
            child: InkWell(
              key: const ValueKey('open-search'),
              borderRadius: BorderRadius.circular(TelegramMetrics.inputRadius),
              onTap: onOpenSearch,
              child: Container(
                height: 38,
                decoration: BoxDecoration(
                  color: TelegramColors.bgHover,
                  borderRadius: BorderRadius.circular(
                    TelegramMetrics.inputRadius,
                  ),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 14),
                    Icon(
                      Icons.search,
                      size: 18,
                      color: TelegramColors.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '搜索会话与消息',
                      style: TextStyle(
                        color: TelegramColors.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            key: const ValueKey('toggle-theme'),
            onPressed: onToggleTheme,
            icon: Icon(
              TelegramColors.current == TelegramPalette.dark
                  ? Icons.light_mode
                  : Icons.dark_mode,
              size: 20,
              color: TelegramColors.textSecondary,
            ),
            tooltip: '切换亮色 / 暗色',
          ),
          // TG 顶栏右侧就是设置：存储/连接等二级操作全部收进设置页，
          // 侧栏只留这一个入口。
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
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
          child: Column(
            children: [
              Icon(
                store == null ? Icons.link_off : Icons.inbox_outlined,
                color: TelegramColors.textMuted,
                size: 36,
              ),
              const SizedBox(height: 12),
              Text(
                store == null ? '未连接后端' : '暂无会话',
                style: TextStyle(
                  color: TelegramColors.textSecondary,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                store == null
                    ? '连上 OneBot 后端（NapCat 等）后，会话会出现在这里'
                    : '下拉可刷新会话列表',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: TelegramColors.textMuted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              if (store == null) ...[
                const SizedBox(height: 14),
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
      ],
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
      child: Container(
        color: selected ? TelegramColors.bgSelected : Colors.transparent,
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
                      if (chat.pinned) ...[
                        Icon(
                          Icons.push_pin,
                          size: 13,
                          color: selected
                              ? Colors.white.withValues(alpha: 0.85)
                              : TelegramColors.textMuted,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          chat.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          // TG `DialogCell` 的会话名是 dp(17)（Theme.java:7897
                          // 附近的 dialogs_namePaint），有未读时加粗。我们原来写
                          // 14.5，整列看起来比 TG 小一号。
                          style: TextStyle(
                            color: titleColor,
                            fontSize: 17,
                            fontWeight: chat.unreadCount > 0
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
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
                    Text(
                      chat.lastMessage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // 摘要 dp(16)：TG 的 dialogs_messagePaint。
                      style: TextStyle(color: subColor, fontSize: 16),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  chat.lastTime == null ? '' : formatTime(chat.lastTime!),
                  style: TextStyle(
                    color: subColor,
                    fontSize: TelegramMetrics.fontTimestamp,
                  ),
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
