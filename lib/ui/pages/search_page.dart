/// L4 视图：搜索（会话 + 已加载的消息）
///
/// 官方有两套搜索，形态完全不同，这里都要照顾：
///
/// * **会话列表的搜索**（`DialogsActivity:3222` `searchItem.setIsSearchField`）：
///   ActionBar 原地变成搜索头，列表内容被搜索结果顶掉，**不跳页**；
/// * **聊天页的搜索**（`ChatActivity.openSearchWithText`，`:35364`）：顶栏原地
///   变形（隐藏头像/标题/附件/更多），然后 `searchMessagesInChat(...)` ——
///   **只搜当前会话**。
///
/// 所以这里是一个可嵌入的视图（[SearchView]），由宿主决定铺在哪一栏；
/// [SearchPage] 只是把它整屏铺开的外壳（窄屏与测试用）。
///
/// 搜索范围仍然是本地：`ChatStore.searchMessages`——内存 + 本地文件里已经加载
/// 的消息。服务端全文检索要另一套协议（还没做），所以页面上明说一句
/// "只搜已加载的消息"，别让用户以为消息丢了。
///
/// 版面照 TG：结果是 `Cells/DialogCell` 那套几何（高 70 / 头像 52 / 文字从 72
/// 起 / 1px 分隔线也从 72 起），分组标题是 `Cells/GraySectionCell`（高 32、
/// 14dp 粗体、左右 16）。
library;

import 'package:flutter/material.dart';

import '../../client_api/chat_store.dart';
import '../../client_api/objects.dart';
import '../theme/telegram_theme.dart';
import '../widgets/search_field_box.dart';
import '../widgets/telegram_avatar.dart';

/// 搜索视图：顶栏（返回 + 搜索框 + 取消）+ 结果，可嵌入任意一栏。
///
/// [scope] 非空 = 会话内搜索：只搜这一个会话的消息，不显示「会话」分组。
class SearchView extends StatefulWidget {
  final List<Chat> chats;
  final ChatStore? store;

  /// 点结果时打开会话。
  final void Function(Chat chat) onOpenChat;

  /// 关闭搜索（返回箭头、取消、或点了某条结果之后）。
  final VoidCallback onClose;

  /// 会话内搜索的目标；null 表示全局搜索。
  final Chat? scope;

  /// 顶部状态栏让位。整屏铺开时传 `MediaQuery.paddingOf(context).top`；
  /// 嵌在宽屏某一栏里同样要传——状态栏是全屏共享的，栏内并不能省。
  final double topInset;

  /// 底部胶囊占位（只加在列表内部，不缩短视口）。
  final double bottomContentInset;

  const SearchView({
    super.key,
    required this.chats,
    required this.store,
    required this.onOpenChat,
    required this.onClose,
    this.scope,
    this.topInset = 0,
    this.bottomContentInset = 0,
  });

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String _query = '';

  bool get _scoped => widget.scope != null;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<Chat> get _chatHits {
    // 会话内搜索不搜会话名——官方那条路只查消息。
    if (_scoped) return const [];
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return widget.chats
        .where((c) => c.title.toLowerCase().contains(q))
        .toList(growable: false);
  }

  List<({String chatId, ChatMessage message})> get _messageHits =>
      widget.store?.searchMessages(_query, chatId: widget.scope?.id) ??
      const <({String chatId, ChatMessage message})>[];

  String get _emptyHint => _scoped ? '搜索本会话的消息' : '输入名字找会话，或输入内容找消息';

  String get _noResultHint => _scoped
      ? '没有找到。\n只会搜已经加载到本地的消息，更早的还没拉下来。'
      : '没有找到。\n消息只搜已加载的部分——更早的可能还没拉下来。';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _header(),
        Expanded(child: _results()),
      ],
    );
  }

  /// 搜索态顶栏：高度与列表页顶栏一致（`headerHeight` + 状态栏），
  /// 这样从列表切进来时内容不会跳一下——官方的 ActionBar 也是原地变形。
  Widget _header() {
    return Container(
      color: TelegramColors.bgHeader,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: widget.topInset),
          SizedBox(
            height: TelegramMetrics.headerHeight,
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('search-back'),
                  onPressed: widget.onClose,
                  icon: Icon(
                    Icons.arrow_back,
                    size: 24,
                    color: TelegramColors.textSecondary,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 48,
                    height: 48,
                  ),
                  tooltip: '返回',
                ),
                Expanded(child: _searchField()),
                // TG 的搜索头右侧永远是「取消」（纯文字按钮，强调色）。
                TextButton(
                  key: const ValueKey('search-cancel'),
                  onPressed: widget.onClose,
                  style: TextButton.styleFrom(
                    foregroundColor: TelegramColors.accent,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 44),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('取消', style: TextStyle(fontSize: 16)),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部胶囊搜索框（TG `Components/SearchField.java`）。
  ///
  /// 几何逐项对齐官方：框高 36（`:46`、`:48`）、圆角 18（`:44`
  /// `createRoundRectDrawable(dp(18))`）、放大镜是框内一个 36×36 的独立视图
  /// 且只离框左边 2（`:57-59`）、文字左内距 40、右内距 32（`:118` 的
  /// `margin+2+38` 与 `:120` 的 `margin+2+30`，都扣掉框自身的 14 margin）、
  /// 字号 16（`:104`）、光标高 20 宽 1.5 取强调色（`:114-116`）、软键盘动作
  /// 是「搜索」（`:113` `setImeOptions(IME_ACTION_SEARCH)`）。
  ///
  /// 底色：亮色 `key_dialogSearchBackground` = `0xFFF2F4F5`
  /// （`ThemeColors.java:57`）；暗色官方是"白色 6.7%"（
  /// `DarkThemeResourceProvider.java:45` `setAlphaComponent(Color.WHITE, 17)`）。
  /// 注意暗色下不能直接用 `bgHover`——它和顶栏底色 `bgHeader` 几乎同色，
  /// 框会看不见边界。
  ///
  /// 清除钮初始 `scaleX/Y = 0.1`、`alpha = 0`，有字时 `alpha(1).scaleX/Y(1)`
  /// 走 **150ms**（`:72-74`、`:139-144`）；点它先 `setText("")` 再
  /// `AndroidUtilities.showKeyboard(...)` 把键盘唤回来（`:81-84`），所以这里
  /// 清空之后要重新拿焦点。
  /// 顶部胶囊搜索框。几何与行为集中在 [SearchFieldBox]（官方
  /// `Components/SearchField.java` 的逐项对应），这里只负责把它接上本页的
  /// 控制器、焦点与查询状态。
  Widget _searchField() => SearchFieldBox(
    controller: _controller,
    focusNode: _focus,
    onChanged: (String value) => setState(() => _query = value),
    onCleared: () => setState(() => _query = ''),
  );

  Widget _results() {
    final chatting = _chatHits;
    final messages = _messageHits;
    if (_query.trim().isEmpty) return _hint(_emptyHint);
    if (chatting.isEmpty && messages.isEmpty) return _hint(_noResultHint);
    return ListView(
      key: const ValueKey('search-results'),
      // 胶囊占位只加在列表末端，视口仍然铺到底（同四个 Tab 的做法）。
      padding: EdgeInsets.only(top: 4, bottom: 4 + widget.bottomContentInset),
      children: [
        if (chatting.isNotEmpty) ...[
          _sectionTitle('会话'),
          for (var i = 0; i < chatting.length; i++)
            _withDivider(
              _chatTile(chatting[i]),
              last: i == chatting.length - 1 && messages.isEmpty,
            ),
        ],
        if (messages.isNotEmpty) ...[
          // 会话内搜索只有一种结果，不需要分组标题。
          if (!_scoped) _sectionTitle('消息'),
          for (var i = 0; i < messages.length; i++)
            _withDivider(
              _messageTile(messages[i]),
              last: i == messages.length - 1,
            ),
        ],
      ],
    );
  }

  Widget _hint(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: TelegramColors.textSecondary,
          fontSize: 13,
          height: 1.5,
        ),
      ),
    ),
  );

  /// 分组标题 = TG `Cells/GraySectionCell.java`：高 32（`layerHeight`）、
  /// 14dp 粗体（`:57`）、左右 padding 16（`:50`）、底色 `key_graySection`。
  Widget _sectionTitle(String text) => Container(
    height: 32,
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    color: TelegramColors.bgHover,
    child: Text(
      text,
      style: TextStyle(
        color: TelegramColors.textMuted,
        fontSize: 14,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  /// 行间分隔线：从文字起点（72）画到右缘，最后一行不画
  /// （同 `Cells/DialogCell` 的 `needDivider`）。
  Widget _withDivider(Widget child, {required bool last}) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      child,
      if (!last)
        Container(
          height: 1,
          margin: const EdgeInsets.only(left: 72),
          color: TelegramColors.divider,
        ),
    ],
  );

  /// 结果行 = TG `Cells/DialogCell.java:170-172`： avatarStart 11、
  /// messagePaddingStart 72、heightDefault 70；标题 dp(17)、摘要 dp(16)。
  Widget _resultRow({
    required Key key,
    required Widget avatar,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) => InkWell(
    key: key,
    onTap: onTap,
    child: Container(
      constraints: const BoxConstraints(
        minHeight: TelegramMetrics.chatRowHeight,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: TelegramMetrics.chatRowPadding,
        vertical: 9,
      ),
      child: Row(
        children: [
          avatar,
          const SizedBox(width: TelegramMetrics.chatAvatarGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: TelegramColors.textPrimary,
                    fontSize: TelegramMetrics.fontTitle,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: TelegramColors.textSecondary,
                    fontSize: TelegramMetrics.fontBody,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _chatTile(Chat chat) => _resultRow(
    key: ValueKey('search-chat-${chat.id}'),
    avatar: TelegramAvatar(
      name: chat.title,
      url: chat.avatarUrl,
      size: TelegramMetrics.avatarSize,
    ),
    title: chat.title,
    subtitle: chat.lastMessage,
    onTap: () => _open(chat.id),
  );

  Widget _messageTile(({String chatId, ChatMessage message}) hit) {
    final chat = widget.chats.where((c) => c.id == hit.chatId).firstOrNull;
    final title = chat?.title ?? hit.chatId;
    return _resultRow(
      key: ValueKey('search-msg-${hit.message.id}'),
      avatar: TelegramAvatar(
        name: title,
        url: chat?.avatarUrl,
        size: TelegramMetrics.avatarSize,
      ),
      title: hit.message.text.isEmpty ? '（无文字）' : hit.message.text,
      // 会话内搜索的结果都在同一个会话里，副标题只留时间。
      subtitle: _scoped
          ? _formatTime(hit.message.time)
          : '$title · ${_formatTime(hit.message.time)}',
      onTap: () => _open(hit.chatId),
    );
  }

  void _open(String chatId) {
    final chat = widget.chats.where((c) => c.id == chatId).firstOrNull;
    if (chat == null) return;
    widget.onClose();
    widget.onOpenChat(chat);
  }

  static String _formatTime(DateTime t) =>
      '${t.month}月${t.day}日 ${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}

/// 整屏铺开的搜索壳（窄屏、以及测试里用）。
///
/// 宽屏不在这一层：左栏/右栏各自嵌入 [SearchView]（官方是 ActionBar 原地
/// 变形，没有页面转场）。
class SearchPage extends StatelessWidget {
  final List<Chat> chats;
  final ChatStore? store;
  final void Function(Chat chat) onOpenChat;
  final Chat? scope;

  const SearchPage({
    super.key,
    required this.chats,
    required this.store,
    required this.onOpenChat,
    this.scope,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      body: SafeArea(
        top: false,
        bottom: false,
        child: SearchView(
          chats: chats,
          store: store,
          onOpenChat: onOpenChat,
          scope: scope,
          topInset: MediaQuery.paddingOf(context).top,
          onClose: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }
}
