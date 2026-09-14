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
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/chat_store.dart';
import '../../client_api/objects.dart';
import '../../client_api/segment.dart';
import '../../client_api/qq8_providers.dart';
import '../../client_api/session.dart';
import '../../client_api/session_providers.dart';
import '../theme/telegram_theme.dart';
import '../theme/theme_mode.dart';
import '../widgets/message_bubble.dart';
import '../widgets/chat_actions.dart';
import '../widgets/face_panel.dart';
import '../widgets/forward_picker.dart';
import '../widgets/group_members_panel.dart';
import '../widgets/message_actions.dart';
import '../widgets/jump_to_latest.dart';
import '../widgets/message_list_builder.dart';
import '../widgets/storage_dialog.dart';
import '../widgets/telegram_avatar.dart';
import 'connect_page.dart';
import 'search_page.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

  /// 正在回复哪条消息（长按 → 回复；发出去就清）。
  ChatMessage? _replyTarget;

  /// 当前选中的会话 id（视图状态，不是业务状态）。
  String? _selectedChatId;

  /// 窄屏时用于切换列表/对话。
  bool _showChatList = true;

  /// 本次 build 解析出的会话 id，供滚动/发送回调使用。
  String? _resolvedChatId;

  /// 已经触发过 openChat 的会话，避免每次 build 都排一次加载。
  final Set<String> _opened = <String>{};
  ChatStore? _openedForStore;

  /// 未读分隔线的锚点（= 打开会话那一刻的 `Chat.lastReadId`）。
  ///
  /// 为什么快照：`openChat` 会立刻把 `lastReadId` 推到最新一条（那是"已读位置"
  /// 的正确语义），但分隔线要留在**当初开始未读的地方**——不然一进会话线就没了。
  /// 换会话时清空，所以它只在本次会话里存活，和 TG/Nagram 的行为一致。
  String? _unreadAnchorId;

  /// 消息列表是不是贴在底部（决定要不要显示"跳到最新"按钮）。
  bool _atBottom = true;

  /// 当前输入框里装着哪个会话的草稿（换会话时要靠它判断"要不要先存上一份"）。
  String? _draftChatId;
  Timer? _draftTimer;

  /// 缓存的 store 引用：`dispose()` 里 **不能再碰 `ref`**（Riverpod 会抛
  /// "Cannot use ref after the widget was disposed"），而退出前还想把草稿写回去，
  /// 所以每次 build 时把 store 记在这里，[flushDraft] 只用这个字段。
  ChatStore? _draftStore;

  /// 多选模式里选中的消息 id（空 = 不在多选模式）。
  final Set<String> _selected = <String>{};

  bool get _selecting => _selected.isNotEmpty;

  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _inputController.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    // 退出前把没落盘的草稿写回去（防抖计时器可能还挂着）
    _flushDraft();
    _draftTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _inputController.removeListener(_onInputChanged);
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 打字 → 防抖 600ms 落草稿（每敲一个字都写盘太浪费）。
  void _onInputChanged() {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 600), _flushDraft);
  }

  /// 把当前输入框内容作为草稿存到 [_draftChatId] 那个会话上。
  ///
  /// 只用 [_draftStore]（build 里缓存的），不走 `ref`——这个方法会被 `dispose()`
  /// 调用，那时 `ref` 已经不可用了。
  void _flushDraft() {
    _draftTimer?.cancel();
    _draftTimer = null;
    final store = _draftStore;
    final chatId = _draftChatId;
    if (store == null || chatId == null) return;
    final text = _inputController.text;
    final chat = store.chatOf(chatId);
    if (chat == null || chat.draft == text) return;
    unawaited(store.setDraft(chatId, text));
  }

  /// 换会话时把输入框换成那个会话的草稿。
  ///
  /// **必须在 post-frame 里改 controller**：build 期间动它会让 TextField
  /// 在 build 中 markNeedsBuild（Flutter 直接报错）。所以这里只记 id，
  /// 真正的赋值排到下一帧。
  void _syncDraft(Chat? chat) {
    final id = chat?.id;
    if (id == _draftChatId) return;
    _flushDraft(); // 先把上一个会话的草稿存好，再换
    _draftChatId = id;
    final text = chat?.draft ?? '';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _inputController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    });
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
  ///
  /// 顺带盯着"有没有贴到底部"：这决定 [UnreadDivider] 上方那条"跳到最新"
  /// 按钮显不显示，也决定滚到底时要不要清未读（TG 就是这么做的——不是一进
  /// 会话就算读完，而是**看到最新那条**才算）。
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final atBottom = pos.maxScrollExtent - pos.pixels <= 40;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
    if (atBottom) _markReadIfUnread();

    if (pos.pixels > 24) return;
    unawaited(_loadMore());
  }

  /// 滚到底/跳到底之后把会话标成已读（store 内部会顺带上报给服务端）。
  void _markReadIfUnread() {
    final store = ref.read(chatStoreProvider);
    final chatId = _resolvedChatId;
    if (store == null || chatId == null) return;
    final chat = store.chats.where((c) => c.id == chatId).firstOrNull;
    if (chat == null || chat.unreadCount == 0) return;
    // 手动"标为未读"期间不自动清：那是用户的明确意图，得撑到下次打开会话
    if (chat.manualUnread) return;
    unawaited(store.markChatRead(chatId));
  }

  /// 跳到最新（"跳到最新"按钮）：滚到底 + 清未读。
  void _jumpToLatest(String chatId) {
    _scrollToBottom();
    final store = ref.read(chatStoreProvider);
    if (store != null) unawaited(store.markChatRead(chatId));
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
  /// 重复调用由 [ChatStore] 自己挡（`_historyFetched`），但**锚点每次都要重算**，
  /// 所以要放在 `_opened` 守卫之外——否则重回同一个会话会留着上次的未读线。
  Future<void> _ensureOpened(String chatId) async {
    final store = ref.read(chatStoreProvider);
    if (store == null) return;
    final chat = store.chats.where((c) => c.id == chatId).firstOrNull;
    _unreadAnchorId =
        (chat != null && chat.unreadCount > 0) ? chat.lastReadId : null;
    if (!_opened.add(chatId)) return;
    await store.openChat(chatId);
    // 拉完历史贴到底：新消息在末尾，用户开会话要看的就是它们。
    if (mounted) _scrollToBottom();
  }

  /// 停在底部就等于"已经看到最新"——顺手把已读位置推到最后一条，
  /// 否则会话列表上会挂着一个在底部读不掉的 1，未读分隔线也会停错地方。
  ///
  /// 不做"未读为 0 就跳过"的判断：自己发出去的消息同样要把位置推走。
  /// 重复调用由 store 自己挡（位置没变就不落盘、不发通知）。
  /// 放在 post-frame 里做：build 期间改 provider 会报错。
  void _markReadWhenAtBottom(Chat chat) {
    if (!_atBottom) return;
    // 同上：手动标为未读的会话，停在底部也不清
    if (chat.manualUnread) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final store = ref.read(chatStoreProvider);
      if (store == null) return;
      unawaited(store.markChatRead(chat.id));
    });
  }

  /// 📎：发本地图片。桌面端不引文件选择器依赖，用"填路径"的对话框
  /// （读文件在适配器里做，UI 不碰 IO）。
  Future<void> _sendImageFromPath() async {
    final store = ref.read(chatStoreProvider);
    final chatId = _resolvedChatId;
    if (store == null || chatId == null) return;
    final controller = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('send-image-dialog'),
        title: const Text('发送图片'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('填本地图片路径（PNG / JPEG / GIF / BMP / WebP，≤30 MiB）：'),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('send-image-path'),
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: r'C:\图片\cat.png'),
              onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
            ),
            const SizedBox(height: 8),
            const Text('发送时先上传到 QQ 图床（服务端已有同一张图就免传），'
                '再把 fid 填进消息发出去。',
                style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('send-image-ok'),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (path == null || path.isEmpty) return;
    await store.send(chatId, <Segment>[ImageSegment(path)]);
  }

  /// 打开表情面板：选中的表情以 `/名字` 插到光标处。
  ///
  /// 不直接塞 FaceSegment，是因为输入框里只有文本——协议层本来就认 `/名字`
  /// （官方客户端的输入约定），走同一条路，用户也能自己手打或删改。
  void _openFacePicker() {
    unawaited(showFacePicker(context, onPick: _insertAtCursor));
  }

  void _insertAtCursor(String token) {
    final text = _inputController.text;
    final sel = _inputController.selection;
    final at = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    _inputController.value = TextEditingValue(
      text: text.replaceRange(at, end, token),
      selection: TextSelection.collapsed(offset: at + token.length),
    );
  }

  void _send() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    final store = ref.read(chatStoreProvider);
    final chatId = _resolvedChatId;
    if (store == null || chatId == null) return;

    // 乐观插入：清空输入框不代表已送达，消息自己带 sending/failed 状态，
    // 失败也不会丢文本（见 ChatStore.send）。
    // 引用回复：把引用段塞在最前（协议线会把它翻成 src_msg 元素）。
    final target = _replyTarget;
    final segments = <Segment>[
      if (target != null)
        ReplySegment(
          target.id,
          text: target.text,
          qq: target.senderId,
          time: target.time,
        ),
      TextSegment(text),
    ];
    _inputController.clear();
    setState(() => _replyTarget = null);
    unawaited(store.send(chatId, segments));
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
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const ConnectPage()));
  }

  // ---------------------------------------------------------------
  //  构建
  // ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // 只为"换主题时整页重画"而 watch：颜色是静态 getter（见 telegram_theme.dart），
    // 本方法不重建就不会重读新的调色板。
    applyThemePalette(ref);
    final chats = ref.watch(chatsProvider).valueOrNull ?? const <Chat>[];
    final store = ref.watch(chatStoreProvider);
    _draftStore = store; // 给 dispose() 里的草稿收尾用（那时不能再碰 ref）

    // 换了 store（重连会新建）就忘掉"已打开"记录，否则新 store 的历史拉不下来。
    if (!identical(_openedForStore, store)) {
      _openedForStore = store;
      _opened.clear();
    }

    _resolvedChatId = _resolveSelected(chats);
    if (_resolvedChatId != null &&
        store != null &&
        !_opened.contains(_resolvedChatId)) {
      // 首屏自动选中的会话也要拉历史，否则宽屏下右侧是一片空白。
      unawaited(_ensureOpened(_resolvedChatId!));
    }

    final wide = MediaQuery.of(context).size.width >= 720;
    if (wide) {
      return Scaffold(
        backgroundColor: TelegramColors.bgApp,
        body: Row(
          children: [
            SizedBox(
              width: TelegramMetrics.sidebarWidth,
              child: _buildSidebar(chats, store),
            ),
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

  /// 选中哪个会话：优先用户点过的（归档里的也算，从归档入口点进去要能留住），
  /// 否则取主列表第一个。
  String? _resolveSelected(List<Chat> chats) {
    if (chats.isEmpty) return null;
    final selected = _selectedChatId;
    if (selected != null && chats.any((c) => c.id == selected)) return selected;
    final visible = chats.where((c) => !c.archived);
    return (visible.isEmpty ? chats : visible).first.id;
  }

  Widget _buildSidebar(List<Chat> chats, ChatStore? store) {
    // 归档会话不进主列表（TG/Nagram 的 Archived chats：只从顶部入口进）
    final visible = chats.where((c) => !c.archived).toList(growable: false);
    final archived = chats.where((c) => c.archived).toList(growable: false);
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
              child: visible.isEmpty && archived.isEmpty
                  ? _buildSidebarEmpty(store)
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      // 第一行是"已归档"入口（没有归档会话时不占位置）
                      itemCount: visible.length + (archived.isEmpty ? 0 : 1),
                      itemBuilder: (_, i) {
                        if (archived.isNotEmpty && i == 0) {
                          return _archivedRow(archived, store);
                        }
                        return _chatTile(
                          visible[i - (archived.isEmpty ? 0 : 1)],
                          store,
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// 归档入口：一行"已归档 (N)"，点开看归档里的会话。
  Widget _archivedRow(List<Chat> archived, ChatStore? store) {
    return InkWell(
      key: const ValueKey('archived-row'),
      onTap: () => _openArchiveSheet(archived, store),
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

  /// 归档列表：复用会话行，长按可以"取消归档"。
  void _openArchiveSheet(List<Chat> archived, ChatStore? store) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: TelegramColors.bgSidebar,
      builder: (sheetCtx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  Text(
                    '已归档',
                    style: TextStyle(
                      color: TelegramColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '长按可取消归档',
                    style: TextStyle(
                      color: TelegramColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: TelegramColors.divider),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: archived.length,
                itemBuilder: (_, i) {
                  final chat = archived[i];
                  return ListTile(
                    key: ValueKey('archived-${chat.id}'),
                    dense: true,
                    leading: TelegramAvatar(name: chat.title, size: 34),
                    title: Text(
                      chat.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: TelegramColors.textPrimary,
                        fontSize: 14.5,
                      ),
                    ),
                    subtitle: Text(
                      chat.lastMessage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: TelegramColors.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _openChat(chat);
                    },
                    onLongPress: () {
                      Navigator.of(sheetCtx).pop();
                      unawaited(store?.setChatArchived(chat.id, false));
                    },
                  );
                },
              ),
            ),
          ],
        ),
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
                  onPressed: _openConnectPage,
                  child: Text(
                    '去连接设置',
                    style: TextStyle(color: TelegramColors.accent),
                  ),
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
            // 点一下进搜索页（之前这里只是个壳，点了没反应）
            child: InkWell(
              key: const ValueKey('open-search'),
              borderRadius: BorderRadius.circular(TelegramMetrics.inputRadius),
              onTap: _openSearch,
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
            onPressed: _toggleTheme,
            icon: Icon(
              TelegramColors.current == TelegramPalette.dark
                  ? Icons.light_mode
                  : Icons.dark_mode,
              size: 20,
              color: TelegramColors.textSecondary,
            ),
            tooltip: '切换亮色 / 暗色',
          ),
          IconButton(
            key: const ValueKey('open-storage'),
            onPressed: () => _openStorageDialog(store),
            icon: Icon(
              Icons.sd_storage,
              size: 20,
              color: TelegramColors.textSecondary,
            ),
            tooltip: '存储与缓存',
          ),
          IconButton(
            onPressed: _openConnectPage,
            icon: Icon(
              Icons.settings,
              size: 20,
              color: TelegramColors.textSecondary,
            ),
            tooltip: '连接设置',
          ),
        ],
      ),
    );
  }

  /// 亮 ↔ 暗。根组件（main.dart）会跟着换成另一套调色板与 ThemeData，
  /// 本页因为 watch 了同一个 provider 也整页重画；选择落盘在
  /// `<dataDir>/ui_settings.json`，下次启动照旧。
  void _toggleTheme() {
    unawaited(ref.read(themeModeProvider.notifier).toggle());
  }

  /// 打开"存储与缓存"（TG 的 数据与存储 → 存储用量）。
  Future<void> _openStorageDialog(ChatStore? store) async {
    if (store == null) return;
    final stats = await store.storageStats();
    if (!mounted) return;
    await StorageDialog.show(
      context,
      stats: stats,
      limitsNote:
          '媒体缓存上限 ${StorageStats.formatBytes(store.maxCacheBytes)}'
          ' · 保留 ${store.keepMediaFor == null ? '永久' : '${store.keepMediaFor!.inDays} 天'}',
      onClearCache: () async {
        // 先清空、再按预算清一次（store 内部会记日志）
        await store.clearMediaCache();
        await store.pruneMediaCache();
      },
      onClearHistory: () => store.clearAllHistory(),
    );
  }

  /// 长按消息：复制 / 查看原文 / 撤回（只放真能用的动作）。
  Future<void> _showMessageActions(ChatMessage m, String chatId) async {
    final store = ref.read(chatStoreProvider);
    final session = ref.read(sessionProvider);
    final canRecall =
        m.outgoing && !m.isRecalled && (session?.supports('recall') ?? false);
    await MessageActionsSheet.show(
      context,
      message: m,
      canRecall: canRecall,
      onCopy: () {
        // 不 await：写剪贴板走平台通道，慢/无实现时不该把 UI 与提示一起拖住
        unawaited(Clipboard.setData(ClipboardData(text: m.text)));
        _toast('已复制');
      },
      onReveal: () => store?.revealMessage(chatId, m.id),
      onReply: () => setState(() => _replyTarget = m),
      onRecall: () => _recall(store, chatId, m.id),
      onDelete: () => _deleteMessage(store, chatId, m),
      onForward: () => _forwardMessages(chatId, <String>[m.id]),
      onSelect: () => setState(() => _selected.add(m.id)),
    );
  }

  /// 转发：先挑目标会话，再交给 store（只重发内容，发不了的会抛异常）。
  Future<void> _forwardMessages(String fromChatId, List<String> ids) async {
    final store = ref.read(chatStoreProvider);
    if (store == null || ids.isEmpty) return;
    final chats = ref.read(chatsProvider).valueOrNull ?? const <Chat>[];
    final candidates = chats.where((c) => c.id != fromChatId).toList();
    if (candidates.isEmpty) {
      _toast('没有别的会话可转发');
      return;
    }
    await ForwardPickerSheet.show(
      context,
      chats: candidates,
      onPick: (target) => _doForward(store, fromChatId, ids, target),
    );
  }

  Future<void> _doForward(
    ChatStore store,
    String fromChatId,
    List<String> ids,
    Chat target,
  ) async {
    try {
      final n = await store.forwardMessages(
        fromChatId: fromChatId,
        messageIds: ids,
        toChatId: target.id,
      );
      if (mounted) _toast('已转发 $n 条到「${target.title}」');
    } on SessionException catch (e) {
      if (mounted) _toast('转发失败：${e.message}');
    } on Object catch (e) {
      if (mounted) _toast('转发失败：$e');
    }
  }

  /// 多选模式：复制选中的消息（按时间顺序用换行拼起来）。
  Future<void> _copySelected(String chatId) async {
    final store = ref.read(chatStoreProvider);
    if (store == null) return;
    final messages = store.messagesOf(chatId);
    final text = <String>[
      for (final m in messages)
        if (_selected.contains(m.id)) m.displayText,
    ].join('\n');
    if (text.isEmpty) return;
    final label = _selectedCountLabel();
    // 同上：不 await 平台通道
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    if (mounted) {
      setState(() => _selected.clear());
      _toast('已复制 $label');
    }
  }

  String _selectedCountLabel() => '${_selected.length} 条';

  /// 多选模式：删除选中的消息（**仅本地**，逐条确认一次）。
  Future<void> _deleteSelected(String chatId) async {
    final store = ref.read(chatStoreProvider);
    if (store == null) return;
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TelegramColors.bgSidebar,
        title: Text('删除这 $n 条消息？',
            style: TextStyle(color: TelegramColors.textPrimary)),
        content: Text(
          '只删本机上的记录，对方和其他设备都还能看到。',
          style: TextStyle(color: TelegramColors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('ms-delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除', style: TextStyle(color: TelegramColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final ids = _selected.toList();
    for (final id in ids) {
      await store.deleteMessage(chatId, id);
    }
    if (mounted) setState(() => _selected.clear());
  }

  /// 删除单条消息（**仅本地**）：确认一次，删了就找不回来了。
  Future<void> _deleteMessage(
    ChatStore? store,
    String chatId,
    ChatMessage m,
  ) async {
    if (store == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TelegramColors.bgSidebar,
        title:
            Text('删除这条消息？', style: TextStyle(color: TelegramColors.textPrimary)),
        content: Text(
          '只删本机上的这条记录，对方和其他设备都还能看到。\n'
          '要让两边都看不到，请用「撤回」。',
          style: TextStyle(color: TelegramColors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('msg-delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除', style: TextStyle(color: TelegramColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await store.deleteMessage(chatId, m.id);
  }

  /// 撤回：失败要把服务端的原话显示出来（超时/不是自己的/不支持…）。
  Future<void> _recall(
    ChatStore? store,
    String chatId,
    String messageId,
  ) async {
    if (store == null) return;
    try {
      await store.recallMessage(chatId, messageId);
    } on SessionException catch (e) {
      if (mounted) _toast('撤回失败：${e.message}');
    } on Object catch (e) {
      if (mounted) _toast('撤回失败：$e');
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  /// 打开群成员面板（只有协议线在线时才有数据源；别的后端显示原因）。
  Future<void> _openMembers(Chat chat) async {
    final gid = chat.rawId;
    if (gid == null) return;
    await GroupMembersPanel.show(
      context,
      title: chat.title,
      ownerUin: chat.ownerUin,
      loader: () async {
        final svc = ref.read(qq8LoginServiceProvider);
        if (!svc.isOnline) {
          throw const SessionException('当前后端没有成员列表能力（协议线在线才有）');
        }
        final page = await svc.fetchGroupMembers(gid);
        return page.members;
      },
    );
  }

  Widget _chatTile(Chat chat, ChatStore? store) {
    final selected = chat.id == _resolvedChatId;
    // 选中行在亮色下是蓝色底（#3390EC），文字必须跟着翻白——
    // 否则就是黑字压蓝底。暗色的选中底是深紫，白字同样成立。
    final titleColor = selected ? Colors.white : TelegramColors.textPrimary;
    final subColor = selected
        ? Colors.white.withValues(alpha: 0.85)
        : TelegramColors.textSecondary;
    return InkWell(
      key: ValueKey('chat-row-${chat.id}'),
      onTap: () => _openChat(chat),
      onLongPress: () => _showChatActions(chat, store),
      child: Container(
        color: selected ? TelegramColors.bgSelected : Colors.transparent,
        constraints: const BoxConstraints(
          minHeight: TelegramMetrics.chatRowHeight,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Stack(
              children: [
                TelegramAvatar(
                  name: chat.title,
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
            const SizedBox(width: 10),
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
                          style: TextStyle(
                            color: titleColor,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
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
                              color: selected ? Colors.white : TelegramColors.danger,
                              fontSize: 13,
                            ),
                          ),
                          TextSpan(
                            text: chat.draft.replaceAll('\n', ' '),
                            style: TextStyle(color: subColor, fontSize: 13),
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
                      style: TextStyle(
                        color: subColor,
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
                  style: TextStyle(
                    color: subColor,
                    fontSize: TelegramMetrics.fontTimestamp,
                  ),
                ),
                const SizedBox(height: 6),
                if (chat.unreadCount > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      // 选中行整行就是强调色，徽章再刷同色等于看不见——
                      // 翻成白底 + 强调色字（TG 选中会话的未读徽章就是这样）。
                      color: selected
                          ? Colors.white
                          : chat.muted
                              ? TelegramColors.textMuted
                              : TelegramColors.badge,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${chat.unreadCount}',
                      style: TextStyle(
                        color: selected
                            ? TelegramColors.bgSelected
                            : Colors.white,
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

  /// 多选工具条：TG 顶部那条"已选 N 条"。
  Widget _buildSelectionBar(Chat chat) {
    return Container(
      height: TelegramMetrics.headerHeight,
      color: TelegramColors.bgHeader,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('ms-close'),
            onPressed: () => setState(_selected.clear),
            icon: Icon(Icons.close, color: TelegramColors.textSecondary),
            tooltip: '退出多选',
          ),
          Expanded(
            child: Text(
              '已选 ${_selected.length} 条',
              key: const ValueKey('ms-count'),
              style: TextStyle(
                color: TelegramColors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('ms-copy'),
            onPressed: () => _copySelected(chat.id),
            icon: Icon(Icons.copy_outlined, color: TelegramColors.textSecondary),
            tooltip: '复制',
          ),
          IconButton(
            key: const ValueKey('ms-forward'),
            onPressed: () => _forwardMessages(chat.id, _selected.toList()),
            icon: Icon(Icons.forward, color: TelegramColors.textSecondary),
            tooltip: '转发',
          ),
          IconButton(
            key: const ValueKey('ms-delete'),
            onPressed: () => _deleteSelected(chat.id),
            icon: Icon(Icons.delete_outline, color: TelegramColors.danger),
            tooltip: '删除（仅本地）',
          ),
        ],
      ),
    );
  }

  /// 打开搜索页（会话按名字、消息按已加载内容）。
  void _openSearch() {
    final chats = ref.read(chatsProvider).valueOrNull ?? const <Chat>[];
    final store = ref.read(chatStoreProvider);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchPage(
          chats: chats,
          store: store,
          onOpenChat: _openChat,
        ),
      ),
    );
  }

  /// 长按会话：置顶/免打扰/标为未读/归档/删除会话（全是本地操作）。
  void _showChatActions(Chat chat, ChatStore? store) {
    if (store == null) return;
    ChatActionsSheet.show(
      context,
      chat: chat,
      onTogglePinned: () => unawaited(store.setChatPinned(chat.id, !chat.pinned)),
      onToggleMuted: () => unawaited(store.setChatMuted(chat.id, !chat.muted)),
      onToggleArchived: () =>
          unawaited(store.setChatArchived(chat.id, !chat.archived)),
      onMarkUnread: () => unawaited(store.markChatUnread(chat.id)),
      onDelete: () => _confirmDeleteChat(chat, store),
    );
  }

  /// 删除会话要确认一次：本地记录删掉就没了（对方那边不受影响）。
  Future<void> _confirmDeleteChat(Chat chat, ChatStore store) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TelegramColors.bgSidebar,
        title: Text('删除会话？', style: TextStyle(color: TelegramColors.textPrimary)),
        content: Text(
          '只会删掉本机上的「${chat.title}」聊天记录，对方不会收到任何通知。\n'
          '下次对方发消息时这个会话会重新出现。',
          style: TextStyle(color: TelegramColors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('chat-delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              '删除',
              style: TextStyle(color: TelegramColors.danger),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    // 删的是当前打开的会话 → 回到空态，别停在一个已经不存在的会话上
    if (_resolvedChatId == chat.id) {
      setState(() => _selectedChatId = null);
    }
    _opened.remove(chat.id);
    await store.deleteChat(chat.id);
  }

  Widget _buildChatPane(
    List<Chat> chats,
    ChatStore? store, {
    VoidCallback? onBack,
  }) {
    final chatId = _resolvedChatId;
    final chat = chats.where((c) => c.id == chatId).firstOrNull;

    if (chat == null) {
      return _buildEmptyPane(store, onBack: onBack);
    }
    _markReadWhenAtBottom(chat);
    _syncDraft(chat);

    final messages =
        ref.watch(messagesProvider(chat.id)).valueOrNull ??
        const <ChatMessage>[];
    // 群聊里收到的消息才显示小头像（TG 不画自己的头像）
    final items = buildMessageItems(
      messages,
      showAvatars: chat.type == ChatType.group,
      // 未读分隔线的锚点：打开会话时快照下来的那条（store 一清未读就把它推到
      // 末尾了，所以不能现读 chat.lastReadId），见 [_unreadAnchorId]。
      unreadAnchorId: _unreadAnchorId,
    );

    return Column(
      children: [
        _buildHeader(chat, onBack),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  color: TelegramColors.bgChat,
                  child: messages.isEmpty
                      ? _buildMessagesEmpty(store)
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          itemCount: items.length,
                          itemBuilder: (_, i) {
                            final item = items[i];
                            final day = item.day;
                            if (day != null) {
                              return DateChip(day: day);
                            }
                            if (item.isUnread) {
                              return const UnreadDivider();
                            }
                            final m = item.message!;
                            final checked = _selected.contains(m.id);
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                if (_selecting)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                        left: 6, right: 2, bottom: 12),
                                    child: Icon(
                                      checked
                                          ? Icons.check_circle
                                          : Icons.radio_button_unchecked,
                                      key: ValueKey('ms-check-${m.id}'),
                                      size: 20,
                                      color: checked
                                          ? TelegramColors.accent
                                          : TelegramColors.textMuted,
                                    ),
                                  ),
                                if (item.showAvatarSlot)
                                  SizedBox(
                                    width: TelegramMetrics.bubbleAvatarSize + 10,
                                    child: item.showAvatar
                                        ? Padding(
                                            padding: const EdgeInsets.only(
                                              left: 8,
                                              right: 6,
                                            ),
                                            child: TelegramAvatar(
                                              name: m.senderName,
                                              size: TelegramMetrics
                                                  .bubbleAvatarSize,
                                            ),
                                          )
                                        : null,
                                  ),
                                Expanded(
                                  child: GestureDetector(
                                    // 多选模式里点击 = 勾选/取消勾选（长按仍出菜单）
                                    onTap: _selecting
                                        ? () => setState(() => _selected
                                            .contains(m.id)
                                            ? _selected.remove(m.id)
                                            : _selected.add(m.id))
                                        : null,
                                    onLongPress: () =>
                                        _showMessageActions(m, chat.id),
                                    child: MessageBubble(
                                      message: m,
                                      onRetry:
                                          m.isFailed ? () => _retry(m.id) : null,
                                      showSenderName: item.showSenderName,
                                      highlighted:
                                          m.atMe || m.replyToId != null,
                                      onReveal: m.isRecalled
                                          ? () => store?.revealMessage(
                                              chat.id, m.id)
                                          : null,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                ),
              ),
              // "跳到最新"：不在底部时浮在右下角（TG/Nagram 的下箭头按钮）
              if (!_atBottom)
                Positioned(
                  right: 14,
                  bottom: 14,
                  child: JumpToLatestButton(
                    key: const ValueKey('jump-to-latest'),
                    unread: chat.unreadCount,
                    onTap: () => _jumpToLatest(chat.id),
                  ),
                ),
            ],
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
                  icon: Icon(
                    Icons.arrow_back,
                    color: TelegramColors.textSecondary,
                  ),
                ),
              Text(
                'QQ Client',
                style: TextStyle(
                  color: TelegramColors.textPrimary,
                  fontSize: TelegramMetrics.fontTitle,
                  fontWeight: FontWeight.w600,
                ),
              ),
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
                  Text(
                    '选择一个会话开始聊天',
                    style: TextStyle(
                      color: TelegramColors.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                  if (store == null) ...[
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _openConnectPage,
                      child: Text(
                        '去连接设置',
                        style: TextStyle(color: TelegramColors.accent),
                      ),
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
          style: TextStyle(color: TelegramColors.textMuted, fontSize: 13),
        ),
      ),
    );
  }

  Widget _buildHeader(Chat chat, VoidCallback? onBack) {
    // 多选模式：把头换成工具条（已选 N 条 + 复制/转发/删除/退出）
    if (_selecting) return _buildSelectionBar(chat);
    return Container(
      height: TelegramMetrics.headerHeight,
      color: TelegramColors.bgHeader,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              onPressed: onBack,
              icon: Icon(
                Icons.arrow_back,
                color: TelegramColors.textSecondary,
              ),
            ),
          GestureDetector(
            key: const ValueKey('open-members'),
            onTap: chat.isGroup ? () => _openMembers(chat) : null,
            child: TelegramAvatar(name: chat.title, size: 40),
          ),
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
                  style: TextStyle(
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
            icon: Icon(
              Icons.settings,
              color: TelegramColors.textSecondary,
              size: 22,
            ),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyTarget != null) _replyStrip(_replyTarget!),
            Row(
              children: [
                // 📎 发本地图片：上传链路（探图 → PicUp → highway）在适配器里，
                // 这里只问路径
                IconButton(
                  key: const ValueKey('attach-file'),
                  onPressed: () => unawaited(_sendImageFromPath()),
                  icon: Icon(
                    Icons.attach_file,
                    color: TelegramColors.textSecondary,
                    size: 22,
                  ),
                  tooltip: '发送图片',
                ),
                const SizedBox(width: 4),
                // 表情面板：不依赖连接状态（没连线也能先打字/选表情），
                // 点一下把 `/名字` 插到光标处，发送时协议层翻成表情元素。
                IconButton(
                  key: const ValueKey('open-faces'),
                  onPressed: _openFacePicker,
                  icon: Icon(
                    Icons.emoji_emotions_outlined,
                    color: TelegramColors.textSecondary,
                    size: 22,
                  ),
                  tooltip: 'QQ 表情',
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: TelegramColors.bgHover,
                      borderRadius: BorderRadius.circular(
                        TelegramMetrics.inputRadius,
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: TextField(
                      controller: _inputController,
                      enabled: enabled,
                      onSubmitted: (_) => _send(),
                      style: TextStyle(
                        color: TelegramColors.textPrimary,
                        fontSize: 14,
                      ),
                      decoration: InputDecoration(
                        // 提示里带一句 `/微笑`：QQ 表情是打字发的（官方客户端同款约定），
                        // 不写出来没人知道——表情面板留到后面做。
                        hintText: enabled ? '输入消息…（如 /微笑）' : '未连接',
                        hintStyle: TextStyle(
                          color: TelegramColors.textSecondary,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
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
                    child: Icon(
                      Icons.send,
                      color: enabled ? Colors.white : TelegramColors.textMuted,
                      size: 20,
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

  /// 输入框上方的"正在回复"条（点 ✕ 取消）。
  Widget _replyStrip(ChatMessage target) => Container(
    key: const ValueKey('reply-strip'),
    margin: const EdgeInsets.only(bottom: 6),
    padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
    decoration: BoxDecoration(
      color: TelegramColors.bgHover,
      borderRadius: BorderRadius.circular(10),
      border: Border(left: BorderSide(color: TelegramColors.accent, width: 3)),
    ),
    child: Row(
      children: [
        Icon(Icons.reply, size: 16, color: TelegramColors.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '回复 ${target.senderName.isEmpty ? target.senderId : target.senderName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: TelegramColors.accent,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                target.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: TelegramColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          key: const ValueKey('reply-cancel'),
          onPressed: () => setState(() => _replyTarget = null),
          icon: Icon(
            Icons.close,
            size: 18,
            color: TelegramColors.textSecondary,
          ),
          tooltip: '取消回复',
        ),
      ],
    ),
  );
}
