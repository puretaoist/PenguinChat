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
        titleSpacing: 0,
        title: TextField(
          key: const ValueKey('search-input'),
          controller: _controller,
          autofocus: true,
          style: TextStyle(color: TelegramColors.textPrimary, fontSize: 15),
          decoration: InputDecoration(
            hintText: '搜索会话与消息…',
            hintStyle: TextStyle(color: TelegramColors.textSecondary),
            border: InputBorder.none,
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        actions: [
          if (_query.isNotEmpty)
            IconButton(
              key: const ValueKey('search-clear'),
              onPressed: () {
                _controller.clear();
                setState(() => _query = '');
              },
              icon: Icon(Icons.close, color: TelegramColors.textSecondary),
              tooltip: '清空',
            ),
        ],
      ),
      body: _query.trim().isEmpty
          ? _hint('输入名字找会话，或输入内容找消息')
          : (chatting.isEmpty && messages.isEmpty
              ? _hint('没有找到。\n消息只搜已加载的部分——更早的可能还没拉下来。')
              : ListView(
                  key: const ValueKey('search-results'),
                  children: [
                    if (chatting.isNotEmpty) ...[
                      _sectionTitle('会话'),
                      for (final chat in chatting) _chatTile(chat),
                    ],
                    if (messages.isNotEmpty) ...[
                      _sectionTitle('消息'),
                      for (final hit in messages) _messageTile(hit),
                    ],
                  ],
                )),
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

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Text(
          text,
          style: TextStyle(
            color: TelegramColors.textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  Widget _chatTile(Chat chat) => ListTile(
        key: ValueKey('search-chat-${chat.id}'),
        dense: true,
        leading: TelegramAvatar(name: chat.title, size: 36),
        title: Text(
          chat.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: TelegramColors.textPrimary, fontSize: 14.5),
        ),
        subtitle: Text(
          chat.lastMessage,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: TelegramColors.textSecondary, fontSize: 12.5),
        ),
        onTap: () => _open(chat.id),
      );

  Widget _messageTile(({String chatId, ChatMessage message}) hit) {
    final chat = widget.chats.where((c) => c.id == hit.chatId).firstOrNull;
    final title = chat?.title ?? hit.chatId;
    return ListTile(
      key: ValueKey('search-msg-${hit.message.id}'),
      dense: true,
      leading: CircleAvatar(
        backgroundColor: TelegramColors.bgHover,
        child: Icon(Icons.chat_bubble_outline,
            size: 18, color: TelegramColors.textSecondary),
      ),
      title: Text(
        hit.message.text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: TelegramColors.textPrimary, fontSize: 14),
      ),
      subtitle: Text(
        '$title · ${_formatTime(hit.message.time)}',
        style: TextStyle(color: TelegramColors.textSecondary, fontSize: 12),
      ),
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
