/// L4 页面：搜索（会话 + 已加载的消息）
///
/// 官方/Telegram 的搜索都是"一个入口、两类结果"：会话（按名字）和消息（按内容）。
/// 这里照做，但**只搜本地已经有的东西**：
///
/// * 会话：`chatsProvider` 里的标题（含群名/备注，见 `Qq8List` 怎么填的）；
/// * 消息：`ChatStore.searchMessages`——内存 + 本地文件里已加载的消息。
///
/// 搜不到不代表没有：服务端全文检索要另一套协议（我们还没做），所以页面上
/// 明说一句"只搜已加载的消息"，别让用户以为消息丢了。
///
/// 版面照 TG：顶部是胶囊搜索框 + 右侧「取消」（`ActionBar` 的搜索头），
/// 结果是 `Cells/DialogCell` 那套几何（高 70 / 头像 52 / 文字从 72 起 /
/// 1px 分隔线也从 72 起），分组标题是 `Cells/GraySectionCell`（高 32、
/// 14dp 粗体、左右 16）。
library;

import 'package:flutter/material.dart';

import '../../client_api/chat_store.dart';
import '../../client_api/objects.dart';
import '../theme/telegram_theme.dart';
import '../widgets/telegram_avatar.dart';

/// 搜索页：输入 → 会话结果 + 消息结果。
class SearchPage extends StatefulWidget {
  final List<Chat> chats;
  final ChatStore? store;

  /// 点会话（或在消息结果里点会话名）时打开它。
  final void Function(Chat chat) onOpenChat;

  const SearchPage({
    super.key,
    required this.chats,
    required this.store,
    required this.onOpenChat,
  });

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<Chat> get _chatHits {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return widget.chats
        .where((c) => c.title.toLowerCase().contains(q))
        .toList(growable: false);
  }

  List<({String chatId, ChatMessage message})> get _messageHits =>
      widget.store?.searchMessages(_query) ??
      const <({String chatId, ChatMessage message})>[];

  @override
  Widget build(BuildContext context) {
    final chatting = _chatHits;
    final messages = _messageHits;
    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      appBar: AppBar(
        backgroundColor: TelegramColors.bgHeader,
        iconTheme: IconThemeData(color: TelegramColors.textSecondary),
        titleSpacing: 8,
        title: _searchField(),
        actions: [
          // TG 的搜索头右侧永远是「取消」（纯文字按钮，强调色），
          // 不是图标。点它退出搜索页。
          TextButton(
            key: const ValueKey('search-cancel'),
            onPressed: () => Navigator.of(context).maybePop(),
            style: TextButton.styleFrom(
              foregroundColor: TelegramColors.accent,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 44),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('取消', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
      body: _query.trim().isEmpty
          ? _hint('输入名字找会话，或输入内容找消息')
          : (chatting.isEmpty && messages.isEmpty
              ? _hint('没有找到。\n消息只搜已加载的部分——更早的可能还没拉下来。')
              : ListView(
                  key: const ValueKey('search-results'),
                  padding: const EdgeInsets.only(top: 4),
                  children: [
                    if (chatting.isNotEmpty) ...[
                      _sectionTitle('会话'),
                      for (var i = 0; i < chatting.length; i++)
                        _withDivider(
                          _chatTile(chatting[i]),
                          last: i == chatting.length - 1 &&
                              messages.isEmpty,
                        ),
                    ],
                    if (messages.isNotEmpty) ...[
                      _sectionTitle('消息'),
                      for (var i = 0; i < messages.length; i++)
                        _withDivider(
                          _messageTile(messages[i]),
                          last: i == messages.length - 1,
                        ),
                    ],
                  ],
                )),
    );
  }

  /// 顶部胶囊搜索框（TG 搜索头：圆角灰底 + 放大镜 + 内部清除按钮）。
  Widget _searchField() {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: TelegramColors.bgHover,
        borderRadius: BorderRadius.circular(TelegramMetrics.inputRadius),
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(
            Icons.search,
            size: 18,
            color: TelegramColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: const ValueKey('search-input'),
              controller: _controller,
              autofocus: true,
              style: TextStyle(
                color: TelegramColors.textPrimary,
                fontSize: TelegramMetrics.fontBody,
              ),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索',
                hintStyle: TextStyle(color: TelegramColors.textSecondary),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          if (_query.isNotEmpty)
            IconButton(
              key: const ValueKey('search-clear'),
              onPressed: () {
                _controller.clear();
                setState(() => _query = '');
              },
              icon: Icon(
                Icons.cancel,
                size: 18,
                color: TelegramColors.textSecondary,
              ),
              tooltip: '清空',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            )
          else
            const SizedBox(width: 8),
        ],
      ),
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
  }) =>
      InkWell(
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
      subtitle: '$title · ${_formatTime(hit.message.time)}',
      onTap: () => _open(hit.chatId),
    );
  }

  void _open(String chatId) {
    final chat = widget.chats.where((c) => c.id == chatId).firstOrNull;
    if (chat == null) return;
    Navigator.of(context).pop();
    widget.onOpenChat(chat);
  }

  static String _formatTime(DateTime t) =>
      '${t.month}月${t.day}日 ${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}
