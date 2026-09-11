/// L4 主页面：Telegram Desktop 风格三栏布局
///
/// ┌──────────────┬────────────────────────────────────┐
/// │ 搜索 / 会话列表 │  标题栏                             │
/// │              │  消息流（气泡）                      │
/// │              │  输入栏                             │
/// └──────────────┴────────────────────────────────────┘
///
/// ## 数据来源
///
/// 全部来自 L3 的 provider（`chatsProvider` / `messagesProvider`），
/// 本页只做渲染与手势转发，**不缓存业务状态**——未读数、置顶、发送状态
/// 都归 [ChatStore] 管，页面自己存一份迟早会和磁盘上的真相不一致。
///
/// 唯一留在页面里的状态是「当前选中哪个会话」，因为它纯粹是视图状态。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/chat_store.dart';
import '../../client_api/objects.dart';
import '../../client_api/segment.dart';
import '../../client_api/session_providers.dart';
import '../theme/telegram_theme.dart';
import '../widgets/message_bubble.dart';
import '../widgets/telegram_avatar.dart';
import 'connect_page.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

  /// 当前选中的会话 id（视图状态，不是业务状态）。
  String? _selectedChatId;

  /// 窄屏时用于切换列表/对话。
  bool _showChatList = true;

  /// 本次 build 解析出的会话 id，供滚动/发送回调使用。
  String? _resolvedChatId;

  /// 已经触发过 openChat 的会话，避免每次 build 都排一次加载。
  final Set<String> _opened = <String>{};
  ChatStore? _openedForStore;

  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------
  //  动作
  // ---------------------------------------------------------------

  Future<void> _refreshChats() async {
    final store = ref.read(chatStoreProvider);
    if (store == null) return;
    await store.refreshChats();
  }

  /// 滚到顶部就翻页。`loadMore` 自己会在「没有更多」时变成空操作，
  /// 这里的 [_loadingMore] 只是防止一次手势里重复排队。
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels > 24) return;
    unawaited(_loadMore());
  }

  Future<void> _loadMore() async {
    final store = ref.read(chatStoreProvider);
    final chatId = _resolvedChatId;
    if (store == null || chatId == null) return;
    if (_loadingMore || !store.hasMore(chatId)) return;
    _loadingMore = true;
    try {
      await store.loadMore(chatId);
    } finally {
      _loadingMore = false;
    }
  }

  void _openChat(Chat chat) {
    setState(() {
      _selectedChatId = chat.id;
      _showChatList = false;
    });
    unawaited(_ensureOpened(chat.id));
  }

  /// 打开会话：首次会拉历史并清未读。
  ///
  /// 重复调用由 [ChatStore] 自己挡（`_historyFetched`），但本地也记一份，
  /// 免得每次 build 都排一个微任务。
  Future<void> _ensureOpened(String chatId) async {
    final store = ref.read(chatStoreProvider);
    if (store == null) return;
    if (!_opened.add(chatId)) return;
    await store.openChat(chatId);
  }

  void _send() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    final store = ref.read(chatStoreProvider);
    final chatId = _resolvedChatId;
    if (store == null || chatId == null) return;

    // 乐观插入：清空输入框不代表已送达，消息自己带 sending/failed 状态，
    // 失败也不会丢文本（见 ChatStore.send）。
    _inputController.clear();
    unawaited(store.send(chatId, [TextSegment(text)]));
    _scrollToBottom();
  }

  void _retry(String messageId) {
    final store = ref.read(chatStoreProvider);
    final chatId = _resolvedChatId;
    if (store == null || chatId == null) return;
    unawaited(store.retry(chatId, messageId));
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _openConnectPage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ConnectPage()),
    );
  }

  // ---------------------------------------------------------------
  //  构建
  // ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final chats = ref.watch(chatsProvider).valueOrNull ?? const <Chat>[];
    final store = ref.watch(chatStoreProvider);

    // 换了 store（重连会新建）就忘掉"已打开"记录，否则新 store 的历史拉不下来。
    if (!identical(_openedForStore, store)) {
      _openedForStore = store;
      _opened.clear();
    }

    _resolvedChatId = _resolveSelected(chats);
    if (_resolvedChatId != null && store != null && !_opened.contains(_resolvedChatId)) {
      // 首屏自动选中的会话也要拉历史，否则宽屏下右侧是一片空白。
      unawaited(_ensureOpened(_resolvedChatId!));
    }

    final wide = MediaQuery.of(context).size.width >= 720;
    if (wide) {
      return Scaffold(
        backgroundColor: TelegramColors.bgApp,
        body: Row(
          children: [
            SizedBox(width: TelegramMetrics.sidebarWidth, child: _buildSidebar(chats, store)),
            Container(width: 1, color: TelegramColors.divider),
            Expanded(child: _buildChatPane(chats, store)),
          ],
        ),
      );
    }
    // 窄屏（手机）：列表与对话二选一
    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      body: _showChatList
          ? _buildSidebar(chats, store)
          : _buildChatPane(
              chats,
              store,
              onBack: () => setState(() => _showChatList = true),
            ),
    );
  }

  /// 选中哪个会话：优先用户点过的，其次列表第一个。
  String? _resolveSelected(List<Chat> chats) {
    if (chats.isEmpty) return null;
    final selected = _selectedChatId;
    if (selected != null && chats.any((c) => c.id == selected)) return selected;
    return chats.first.id;
  }

  Widget _buildSidebar(List<Chat> chats, ChatStore? store) {
    return Container(
      color: TelegramColors.bgSidebar,
      child: Column(
        children: [
          _buildSearchBar(store),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refreshChats,
              color: TelegramColors.accent,
              backgroundColor: TelegramColors.bgHover,
              child: chats.isEmpty
                  ? _buildSidebarEmpty(store)
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: chats.length,
                      itemBuilder: (_, i) => _chatTile(chats[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// 列表为空时也要能下拉刷新，所以用可滚动容器包一层。
  Widget _buildSidebarEmpty(ChatStore? store) {
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
                style: const TextStyle(
                    color: TelegramColors.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 4),
              Text(
                store == null
                    ? '连上 OneBot 后端（NapCat 等）后，会话会出现在这里'
                    : '下拉可刷新会话列表',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: TelegramColors.textMuted, fontSize: 12, height: 1.4),
              ),
              if (store == null) ...[
                const SizedBox(height: 14),
                TextButton(
                  onPressed: _openConnectPage,
                  child: const Text('去连接设置',
                      style: TextStyle(color: TelegramColors.accent)),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSearchBar(ChatStore? store) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 38,
              decoration: BoxDecoration(
                color: TelegramColors.bgHover,
                borderRadius: BorderRadius.circular(TelegramMetrics.inputRadius),
              ),
              child: const Row(
                children: [
                  SizedBox(width: 14),
                  Icon(Icons.search, size: 18, color: TelegramColors.textSecondary),
                  SizedBox(width: 8),
                  Text('搜索',
                      style: TextStyle(
                          color: TelegramColors.textSecondary, fontSize: 14)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            onPressed: _openConnectPage,
            icon: const Icon(Icons.settings,
                size: 20, color: TelegramColors.textSecondary),
            tooltip: '连接设置',
          ),
        ],
      ),
    );
  }

  Widget _chatTile(Chat chat) {
    final selected = chat.id == _resolvedChatId;
    return InkWell(
      onTap: () => _openChat(chat),
      child: Container(
        color: selected ? TelegramColors.bgSelected : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Stack(
              children: [
                TelegramAvatar(name: chat.title),
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
                            color: TelegramColors.bgSidebar, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (chat.pinned) ...[
                        const Icon(Icons.push_pin,
                            size: 13, color: TelegramColors.textMuted),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          chat.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: TelegramColors.textPrimary,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    chat.lastMessage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: TelegramColors.textSecondary,
                      fontSize: 13,
                    ),
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
                  style: const TextStyle(
                    color: TelegramColors.textSecondary,
                    fontSize: TelegramMetrics.fontTimestamp,
                  ),
                ),
                const SizedBox(height: 6),
                if (chat.unreadCount > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: chat.muted
                          ? TelegramColors.textMuted
                          : TelegramColors.badge,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${chat.unreadCount}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
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

  Widget _buildChatPane(List<Chat> chats, ChatStore? store, {VoidCallback? onBack}) {
    final chatId = _resolvedChatId;
    final chat = chats.where((c) => c.id == chatId).firstOrNull;

    if (chat == null) {
      return _buildEmptyPane(store, onBack: onBack);
    }

    final messages = ref.watch(messagesProvider(chat.id)).valueOrNull ?? const <ChatMessage>[];

    return Column(
      children: [
        _buildHeader(chat, onBack),
        Expanded(
          child: Container(
            color: TelegramColors.bgChat,
            child: messages.isEmpty
                ? _buildMessagesEmpty(store)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    itemCount: messages.length,
                    itemBuilder: (_, i) {
                      final m = messages[i];
                      return MessageBubble(
                        message: m,
                        onRetry: m.isFailed ? () => _retry(m.id) : null,
                      );
                    },
                  ),
          ),
        ),
        _buildInputBar(store != null),
      ],
    );
  }

  Widget _buildEmptyPane(ChatStore? store, {VoidCallback? onBack}) {
    return Column(
      children: [
        Container(
          height: TelegramMetrics.headerHeight,
          color: TelegramColors.bgHeader,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              if (onBack != null)
                IconButton(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back,
                      color: TelegramColors.textSecondary),
                ),
              const Text('QQ Client',
                  style: TextStyle(
                      color: TelegramColors.textPrimary,
                      fontSize: TelegramMetrics.fontTitle,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: TelegramColors.bgChat,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('选择一个会话开始聊天',
                      style: TextStyle(
                          color: TelegramColors.textSecondary, fontSize: 14)),
                  if (store == null) ...[
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _openConnectPage,
                      child: const Text('去连接设置',
                          style: TextStyle(color: TelegramColors.accent)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        _buildInputBar(false),
      ],
    );
  }

  Widget _buildMessagesEmpty(ChatStore? store) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          store == null ? '未连接后端' : '还没有消息。历史会分页拉取，往下发一条也行。',
          textAlign: TextAlign.center,
          style: const TextStyle(color: TelegramColors.textMuted, fontSize: 13),
        ),
      ),
    );
  }

  Widget _buildHeader(Chat chat, VoidCallback? onBack) {
    return Container(
      height: TelegramMetrics.headerHeight,
      color: TelegramColors.bgHeader,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back,
                  color: TelegramColors.textSecondary),
            ),
          TelegramAvatar(name: chat.title, size: 40),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  chat.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: TelegramColors.textPrimary,
                    fontSize: TelegramMetrics.fontTitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  chat.isGroup
                      ? '群聊 · ${chat.memberCount} 人'
                      : (chat.online ? '在线' : '离线'),
                  style: TextStyle(
                    color: chat.online
                        ? TelegramColors.online
                        : TelegramColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _openConnectPage,
            icon: const Icon(Icons.settings,
                color: TelegramColors.textSecondary, size: 22),
            tooltip: '连接设置',
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(bool enabled) {
    return Container(
      color: TelegramColors.bgInput,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            const Icon(Icons.attach_file,
                color: TelegramColors.textSecondary, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: TelegramColors.bgHover,
                  borderRadius:
                      BorderRadius.circular(TelegramMetrics.inputRadius),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: TextField(
                  controller: _inputController,
                  enabled: enabled,
                  onSubmitted: (_) => _send(),
                  style: const TextStyle(
                      color: TelegramColors.textPrimary, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: enabled ? '输入消息…' : '未连接',
                    hintStyle:
                        const TextStyle(color: TelegramColors.textSecondary),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: enabled ? _send : null,
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: enabled
                      ? TelegramColors.accent
                      : TelegramColors.bgHover,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.send,
                    color: enabled ? Colors.white : TelegramColors.textMuted,
                    size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
