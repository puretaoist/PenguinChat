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
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/chat_store.dart';
import '../../client_api/objects.dart';
import '../../client_api/segment.dart';
import '../../client_api/qq8_login_service.dart';
import '../../client_api/qq8_providers.dart';
import '../../client_api/session.dart';
import '../../infra/log/logger.dart';
import '../../kernel/wlogin8/qq8_file.dart';
import '../../kernel/wlogin8/qq8_gfs.dart';
import '../../kernel/wlogin8/qq8_list.dart';
import '../../client_api/session_providers.dart';
import '../prefs/ui_prefs.dart';
import '../theme/telegram_theme.dart';
import '../theme/theme_mode.dart';
import '../widgets/bubble_entrance.dart';
import '../widgets/message_bubble.dart';
import '../widgets/chat_actions.dart';
import '../widgets/face_panel.dart';
import '../widgets/forward_picker.dart';
import '../widgets/group_files_panel.dart';
import '../widgets/group_members_panel.dart';
import '../widgets/group_settings_panel.dart';
import '../widgets/action_sheet.dart';
import '../widgets/telegram_list_item.dart';
import '../widgets/chat_header.dart';
import '../widgets/message_actions.dart';
import '../widgets/jump_to_latest.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/chat_list_panel.dart';
import '../widgets/message_list_builder.dart';
import '../widgets/telegram_avatar.dart';
import 'connect_page.dart';
import 'qq8_connect_page.dart';
import 'search_page.dart';
import 'settings_page.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({
    super.key,
    this.connecting = false,
    this.previewChats = const <Chat>[],
  });

  /// 冷启动时从磁盘索引读出的会话快照（见 `chat_index_preview.dart`）。
  ///
  /// 只为"第一帧就有列表"存在：真实 store 还没建好（要等登录）时先画它，
  /// store 一到就自动换成 store 的数据。两者用的是同一份 `chats.json` 和
  /// 同一个排序函数，所以换过去**不会有任何视觉跳动**。
  final List<Chat> previewChats;

  /// 账号恢复还没结论时为 true（冷启动壳在 maximumWait 到点后先放人进主界面）。
  ///
  /// 只影响会话栏空态文案：显示「正在连接…」而不是「未连接后端」。由冷启动壳
  /// 传入并随登录状态更新（它 watch 了 qq8LoginStateProvider，本页不 watch，
  /// 因为 widget 测试的 provider override 里没有协议线的依赖）。
  final bool connecting;

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

  /// 通知点击要打开的会话（可能比会话列表先到：冷启动时点通知，
  /// 登录/会话加载还没完成）。等 chats 到位后再消费，见 [_tryConsumePendingOpen]。
  String? _pendingOpenChatId;

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

  /// 已经播过入场动画的消息 id。
  ///
  /// ListView.builder 的行在滚动时会重建，若每次重建都放动画，往回滚就会
  /// 整屏气泡一起淡入——只有"首次出现在视野里的新消息"才该动。
  /// 上限 400 条：只防长会话无界增长，删最老的（动画早已结束，删了也不影响）。
  final Set<String> _entered = <String>{};

  /// 这条消息该不该播入场动画：开关关 / 已播过 / 不是"新"消息 → 不动画。
  ///
  /// "新"= 消息时间距现在 8 秒内。冷启动从磁盘载入历史时所有气泡都是旧的，
  /// 靠这条把它们挡在动画之外；反过来推送刚到的消息必然在 8 秒内。
  bool _shouldAnimateBubble(ChatMessage m) {
    if (!ref.read(uiPrefsProvider).messageAnimations) return false;
    if (_entered.contains(m.id)) return false;
    final age = DateTime.now().difference(m.time);
    if (age.isNegative || age > const Duration(seconds: 8)) {
      _entered.add(m.id);
      return false;
    }
    _entered.add(m.id);
    if (_entered.length > 400) {
      _entered.remove(_entered.first);
    }
    return true;
  }

  bool get _selecting => _selected.isNotEmpty;

  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _inputController.addListener(_onInputChanged);
    // 冷启动预热协议线：构造控制器即触发「票据自动登录」——
    // 有保存票据时装新包/重启都不用再走密码→滑块→短信那一套。
    // 只读一次（构造是幂等的，Riverpod 会复用同一个实例）。
    // 测试环境没有 override 协议线的 DI 时这里会抛——捕获吞掉，测试照常。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        ref.read(qq8ConnectControllerProvider.notifier);
      } on Object {
        // 协议线 DI 未注入（单测/纯 OneBot 场景）：预热失败不影响任何功能
      }
    });
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

  /// 把"通知点击要打开的会话"落地。会话还没加载出来就先留着，
  /// 等下一次 build（chats 变了会重建）再试；列表已加载却找不到才放弃。
  void _tryConsumePendingOpen() {
    final chatId = _pendingOpenChatId;
    if (chatId == null || !mounted) return;
    final chats = ref.read(chatsProvider).valueOrNull ?? const <Chat>[];
    final target = chats.where((c) => c.id == chatId).firstOrNull;
    if (target == null) {
      if (chats.isNotEmpty) {
        Log.get('Notify').w('通知指向的会话不存在，忽略：$chatId');
        _pendingOpenChatId = null;
        ref.read(pendingOpenChatProvider.notifier).state = null;
      }
      return;
    }
    _pendingOpenChatId = null;
    ref.read(pendingOpenChatProvider.notifier).state = null;
    _openChat(target);
  }

  /// 发言人显示名：优先消息里带的昵称，其次服务层名字缓存（备注/群名片）。
  ///
  /// 群消息体里的昵称经常为空、旧数据里甚至直接是 QQ 号；显示号码比留空更糟，
  /// 所以解析不出来时返回空串（气泡就不画名字），不回落成号码。
  /// 取名字服务（协议线登录服务）。组件测试里没有注入数据目录，读这个 provider 会抛
  /// UnimplementedError；名字只是装饰，取不到就当没有，绝不能因此崩掉界面。
  Qq8LoginService? _namesService() {
    try {
      return ref.read(qq8LoginServiceProvider);
    } catch (_) {
      return null;
    }
  }

  /// 取这条消息的发送者显示名。**必须带会话上下文**：同一个人在群里叫群名片、
  /// 私聊叫备注，混用一张全局表就会在私聊里显示出对方群名片（真机 m45402）。
  String _senderLabelOf(ChatMessage m, Chat chat) {
    final raw = m.senderName;
    final numeric = raw.isNotEmpty && RegExp(r'^\d+$').hasMatch(raw);
    final uin = int.tryParse(m.senderId);
    final svc = _namesService();
    // 缓存（备注 / 本群群名片）优先：它比消息里存的旧名字新，也能纠正历史数据里
    // 被写错的群名片（真机 m45402：私聊那条存的是对方群名片）。
    if (uin != null && svc != null) {
      final gid = chat.rawId;
      final cached = (chat.type == ChatType.group && gid != null)
          ? svc.groupMemberNameOf(gid, uin)
          : svc.displayNameOf(uin);
      if (cached != null) return cached;
    }
    if (raw.isNotEmpty && !numeric) return raw;
    return numeric ? '' : raw;
  }

  void _openChat(Chat chat) {
    // 预览期（store 还没建好）点会话没有意义：没有历史可拉、也发不出去。
    // 让这一下"什么都没发生"，比切到一个空对话面板更像话。
    if (ref.read(chatStoreProvider) == null) return;
    setState(() {
      _selectedChatId = chat.id;
      _showChatList = false;
    });
    unawaited(_ensureOpened(chat.id));
    // 打开群会话顺手把成员名字补上（服务层 10 分钟限流）：群消息体里经常没有昵称，
    // 不补就只剩 QQ 号。失败静默，不影响打开会话。
    final gid = chat.rawId;
    final names = _namesService();
    if (chat.type == ChatType.group && gid != null && names != null) {
      unawaited(names.ensureGroupNames(gid).then((_) {
        // 名字是异步补的，补到就重画一次，气泡上的发言人才能立刻变成网名。
        if (mounted) setState(() {});
      }));
    }
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

  /// 📄：发本地**文件**（离线文件）。同样用"填路径"的对话框，读文件在适配器里做。
  ///
  /// 只支持私聊：群文件是另一套命令、还有目录概念（适配器会明确抛错）。
  Future<void> _sendFileFromPath() async {
    final store = ref.read(chatStoreProvider);
    final chatId = _resolvedChatId;
    if (store == null || chatId == null) return;
    if (Chat.parseKey(chatId)?.type != ChatType.private) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('群文件还没接，先用私聊发文件')),
      );
      return;
    }
    final pathCtl = TextEditingController();
    final nameCtl = TextEditingController();
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('send-file-dialog'),
        title: const Text('发送文件'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('填本地文件路径（任意类型，建议 ≤ 100 MiB）：'),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('send-file-path'),
              controller: pathCtl,
              autofocus: true,
              decoration: const InputDecoration(hintText: r'C:文档说明.pdf'),
            ),
            const SizedBox(height: 12),
            const Text('对方看到的文件名（留空 = 用原文件名）：'),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('send-file-name'),
              controller: nameCtl,
              decoration: const InputDecoration(hintText: '说明.pdf'),
              onSubmitted: (_) => Navigator.of(ctx)
                  .pop(<String>[pathCtl.text.trim(), nameCtl.text.trim()]),
            ),
            const SizedBox(height: 8),
            const Text('发送时先传到 QQ 的离线文件通道（服务端已有同 md5 就免传），'
                '再把文件 id 填进消息发出去。',
                style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('send-file-ok'),
            onPressed: () => Navigator.of(ctx)
                .pop(<String>[pathCtl.text.trim(), nameCtl.text.trim()]),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || result.first.isEmpty) return;
    await store.send(chatId, <Segment>[
      FileSegment(result.first, name: result.last.isEmpty ? null : result.last),
    ]);
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

  /// 取消"正在回复"（输入栏 ✕ 的回调；状态在宿主，视图只上报）。
  void _cancelReply() {
    setState(() => _replyTarget = null);
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

  /// 协议线（QQ 自实现协议）登录直达入口。
  void _openQq8Login() {
    Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const Qq8ConnectPage()));
  }

  /// 设置页：把散在顶栏/空态的二级入口收进一个页面（TG 同构）。
  void _openSettings() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
  }

  // ---------------------------------------------------------------
  //  构建
  // ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // 只为"换主题时整页重画"而 watch：颜色是静态 getter（见 telegram_theme.dart），
    // 本方法不重建就不会重读新的调色板。
    applyThemePalette(ref);
    final live = ref.watch(chatsProvider).valueOrNull ?? const <Chat>[];
    final store = ref.watch(chatStoreProvider);
    // store 还没建好（登录中）但磁盘上有索引 → 先画预览，别让用户看空态。
    // store 一接管就用它的数据（live 此时非空）。
    final chats = live.isNotEmpty ? live : widget.previewChats;
    // 预览里的会话不可交互（没有 store 就没有 openChat/发送/长按菜单），
    // 所以预览期间不解析"选中会话"，右侧对话面板保持空。
    final bool previewOnly = store == null && widget.previewChats.isNotEmpty;
    _draftStore = store; // 给 dispose() 里的草稿收尾用（那时不能再碰 ref）

    // 点系统通知 → 打开对应会话。通知由 [MessageNotifyScope] 发出，
    // 它拿不到选中态（选中态只在这里），所以只能走这个状态口。
    // 排到下一帧：listener 可能在 build 期间触发，直接 setState 会报错。
    ref.listen<String?>(pendingOpenChatProvider, (_, chatId) {
      if (chatId == null) return;
      _pendingOpenChatId = chatId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tryConsumePendingOpen();
      });
    });
    // 冷启动点通知的情形：事件在 HomePage 第一次 build 之前就到了，ref.listen
    // 收不到"历史值"，只有在 build 里主动读一次才不会丢。
    final pendingNow = ref.read(pendingOpenChatProvider);
    if (pendingNow != null) _pendingOpenChatId = pendingNow;
    if (_pendingOpenChatId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tryConsumePendingOpen();
      });
    }

    // 换了 store（重连会新建）就忘掉"已打开"记录，否则新 store 的历史拉不下来。
    if (!identical(_openedForStore, store)) {
      _openedForStore = store;
      _opened.clear();
    }

    _resolvedChatId = previewOnly ? null : _resolveSelected(chats);
    if (_resolvedChatId != null &&
        store != null &&
        !_opened.contains(_resolvedChatId)) {
      // 首屏自动选中的会话也要拉历史，否则宽屏下右侧是一片空白。
      unawaited(_ensureOpened(_resolvedChatId!));
    }

    // 用 sizeOf 而不是 of：of 订阅整个 MediaQuery（含 viewInsets），
    // 键盘每一帧动画都会把整个主页（列表+消息+头像）重建一遍——
    // 这就是「键盘呼出变卡」的来源。sizeOf 只在窗口尺寸真变时重建。
    final wide = MediaQuery.sizeOf(context).width >= 720;

    // 侧栏抽成哑视图（ChatListPanel）：build 里组装一次，宽窄两态共用。
    // 窄屏只有"列表/对话二选一"，列表页不存在"当前打开的会话"，所以不传
    // 选中项——否则第一个会话会常年挂着一层选中底色，看起来像误选中。
    final sidebar = ChatListPanel(
      chats: chats,
      store: store,
      connecting: widget.connecting,
      selectedChatId: wide ? _resolvedChatId : null,
      onOpenChat: _openChat,
      onLongPressChat: _showChatActions,
      onRefresh: _refreshChats,
      onOpenSearch: _openSearch,
      onToggleTheme: _toggleTheme,
      onOpenSettings: _openSettings,
      onOpenArchive: _openArchiveSheet,
      onOpenConnect: _openConnectPage,
      onOpenQq8Login: _openQq8Login,
    );

    // 顶部/左右安全区在**根布局**统一消费一次（缺陷5：竖屏时聊天标题
    // 会和系统状态栏的时间/日期叠在一起）。底部不在这里管——输入栏自己
    // 有 SafeArea(top:false)，两层都加会把底部留白算两遍。
    if (wide) {
      return Scaffold(
        backgroundColor: TelegramColors.bgApp,
        body: SafeArea(
          bottom: false,
          child: Row(
            children: [
              SizedBox(
                width: TelegramMetrics.sidebarWidth,
                child: sidebar,
              ),
              Container(width: 1, color: TelegramColors.divider),
              Expanded(child: _buildChatPane(chats, store)),
            ],
          ),
        ),
      );
    }
    // 窄屏（手机）：列表与对话二选一
    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      body: SafeArea(
        bottom: false,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          // 两页都是全屏尺寸：用 Stack 叠着做交叉淡入。默认 layoutBuilder
          // 会把新旧子树各自按内容大小居中排，手机上会看到位置跳一下。
          layoutBuilder: (current, previous) => Stack(
            fit: StackFit.expand,
            children: [
              ...previous,
              ?current,
            ],
          ),
          child: _showChatList
              ? KeyedSubtree(
                  key: const ValueKey<String>('chat-list'),
                  child: sidebar,
                )
              : KeyedSubtree(
                  key: const ValueKey<String>('chat-pane'),
                  child: _buildChatPane(
                    chats,
                    store,
                    onBack: () => setState(() => _showChatList = true),
                  ),
                ),
        ),
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
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      // 归档列表也走 DialogCell 几何（70 / 52 / 17 / 16 / 分隔线 72）
                      TgChatRow(
                        key: ValueKey('archived-${chat.id}'),
                        leading: TelegramAvatar(
                            name: chat.title, url: chat.avatarUrl, size: 52),
                        title: chat.title,
                        subtitle: chat.lastMessage,
                        onTap: () {
                          Navigator.of(sheetCtx).pop();
                          _openChat(chat);
                        },
                        onLongPress: () {
                          Navigator.of(sheetCtx).pop();
                          unawaited(store?.setChatArchived(chat.id, false));
                        },
                      ),
                      if (i != archived.length - 1)
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
          ],
        ),
      ),
    );
  }

  /// 亮 ↔ 暗。根组件（main.dart）会跟着换成另一套调色板与 ThemeData，
  /// 本页因为 watch 了同一个 provider 也整页重画；选择落盘在
  /// `<dataDir>/ui_settings.json`，下次启动照旧。
  void _toggleTheme() {
    unawaited(ref.read(themeModeProvider.notifier).toggle());
  }

  /// 长按消息：复制 / 查看原文 / 撤回（只放真能用的动作）。
  Future<void> _showMessageActions(ChatMessage m, String chatId) async {
    final store = ref.read(chatStoreProvider);
    final session = ref.read(sessionProvider);
    final canRecall =
        m.outgoing && !m.isRecalled && (session?.supports('recall') ?? false);
    // 戳一戳：对面发的消息才能戳（要拿对方 uin）；后端得承认这个能力。
    final canPoke = !m.outgoing &&
        m.senderId.isNotEmpty &&
        (session?.supports('poke') ?? false);
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
      onPoke: canPoke ? () => _poke(m) : null,
      onDelete: () => _deleteMessage(store, chatId, m),
      onForward: () => _forwardMessages(chatId, <String>[m.id]),
      onSelect: () => setState(() => _selected.add(m.id)),
    );
  }

  /// 戳一戳这条消息的发送者（群戳对方 uin，私聊戳会话对端）。
  Future<void> _poke(ChatMessage m) async {
    final session = ref.read(sessionProvider);
    if (session == null) return;
    try {
      await session.sendPoke(m.chatId, m.senderId);
      if (mounted) _toast('已戳一戳');
    } on SessionException catch (e) {
      if (mounted) _toast('戳一戳失败：${e.message}');
    } on Object catch (e) {
      if (mounted) _toast('戳一戳失败：$e');
    }
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

  /// 合并转发：同样是先挑目标会话，再让 store 打包成一张"聊天记录"卡片。
  Future<void> _forwardAsCard(String fromChatId, List<String> ids) async {
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
      onPick: (target) => _doForwardAsCard(store, fromChatId, ids, target),
    );
  }

  Future<void> _doForwardAsCard(
    ChatStore store,
    String fromChatId,
    List<String> ids,
    Chat target,
  ) async {
    try {
      final n = await store.forwardMessagesAsCard(
        fromChatId: fromChatId,
        messageIds: ids,
        toChatId: target.id,
      );
      if (mounted) _toast('已合并转发 $n 条到「${target.title}」');
    } on SessionException catch (e) {
      if (mounted) _toast('合并转发失败：${e.message}');
    } on Object catch (e) {
      if (mounted) _toast('合并转发失败：$e');
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

  /// 点文件气泡：把离线文件下载到 `<dataDir>/downloads/` 并提示路径。
  ///
  /// 只在协议线在线时可用（离线文件走 1200 取直链 + HTTP GET，其他后端没有
  /// 这套命令）。下载是**显式动作**——不在打开会话时自动拉，避免手一滑就
  /// 把几十 MB 的东西吸下来。
  Future<void> _downloadFileMessage(FileSegment seg) async {
    final store = ref.read(chatStoreProvider);
    final fid = (seg.fileId ?? '').trim().isNotEmpty
        ? seg.fileId!.trim()
        : seg.file.trim();
    if (store == null || fid.isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);
    const offlineHint = SnackBar(content: Text('需要协议线在线才能下载文件'));
    // provider 本身就取不到（比如没注入数据目录 / 当前是别的后端）时也算「不在线」，
    // 别把 provider 的异常抛到 UI 上——用户只需要知道这条现在下载不了。
    final Qq8LoginService svc;
    try {
      svc = ref.read(qq8LoginServiceProvider);
    } catch (_) {
      messenger.showSnackBar(offlineHint);
      return;
    }
    if (!svc.isOnline) {
      messenger.showSnackBar(offlineHint);
      return;
    }

    final name =
        (seg.name ?? '').trim().isEmpty ? 'file-$fid' : seg.name!.trim();
    messenger.showSnackBar(SnackBar(content: Text('开始下载：$name…')));
    try {
      final bytes = await svc.downloadFile(fid: fid);
      final dir = Directory(
          '${store.dataDir.path}${Platform.pathSeparator}downloads');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final out =
          File('${dir.path}${Platform.pathSeparator}${_safeFileName(name)}');
      await out.writeAsBytes(bytes, flush: true);
      messenger.showSnackBar(SnackBar(content: Text('已保存到 ${out.path}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('下载失败：$e')));
    }
  }

  /// 文件名消毒：去掉路径分隔符与 Windows 不认的字符（下载后落盘用）。
  static String _safeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? 'download.bin' : cleaned;
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
      onMemberMenu: (Qq8GroupMember m) => unawaited(_memberMenu(chat, m)),
    );
  }

  /// 群设置面板：改群名 / 发群公告 / 全员禁言。
  Future<void> _openGroupSettings(Chat chat) async {
    final gid = chat.rawId;
    if (gid == null) return;
    await GroupSettingsPanel.show(
      context,
      title: chat.title,
      initialName: chat.title,
      onRename: (String name) async {
        final svc = ref.read(qq8LoginServiceProvider);
        if (!svc.isOnline) {
          throw const SessionException('改群名要协议线在线');
        }
        if (name.isEmpty) throw const SessionException('群名不能为空');
        final r = await svc.setGroupName(gid: gid, name: name);
        return r.ok;
      },
      onAnnounce: (String content) async {
        final svc = ref.read(qq8LoginServiceProvider);
        if (!svc.isOnline) {
          throw const SessionException('发公告要协议线在线');
        }
        if (content.isEmpty) throw const SessionException('公告不能为空');
        final r = await svc.setGroupAnnounce(gid: gid, content: content);
        return r.ok;
      },
      onWholeMute: (bool enable) async {
        final svc = ref.read(qq8LoginServiceProvider);
        if (!svc.isOnline) {
          throw const SessionException('全员禁言要协议线在线');
        }
        final r = await svc.setGroupWholeMute(gid: gid, enable: enable);
        return r.ok;
      },
    );
  }

  /// 成员管理菜单：禁言 10 分钟 / 解除禁言 / 踢出 / 设(取消)管理员。
  Future<void> _memberMenu(Chat chat, Qq8GroupMember m) async {
    final gid = chat.rawId;
    if (gid == null) return;
    final isOwner = chat.ownerUin != 0 && m.uin == chat.ownerUin;
    String? choice;
    await ActionSheet.show(
      context,
      preview: Text(
        m.displayName,
        key: const ValueKey('member-menu-title'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            color: TelegramColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w600),
      ),
      items: <ActionSheetItem>[
        ActionSheetItem(
          key: const ValueKey('member-menu-mute'),
          icon: Icons.volume_off_outlined,
          label: '禁言 10 分钟',
          onTap: () => choice = 'mute',
        ),
        ActionSheetItem(
          key: const ValueKey('member-menu-unmute'),
          icon: Icons.volume_up_outlined,
          label: '解除禁言',
          onTap: () => choice = 'unmute',
        ),
        if (!isOwner)
          ActionSheetItem(
            key: const ValueKey('member-menu-admin'),
            icon: Icons.shield_outlined,
            label: m.admin ? '取消管理员' : '设为管理员',
            onTap: () => choice = 'admin',
          ),
        if (!isOwner)
          ActionSheetItem(
            key: const ValueKey('member-menu-kick'),
            icon: Icons.person_remove_outlined,
            label: '踢出群聊',
            danger: true,
            onTap: () => choice = 'kick',
          ),
        ActionSheetItem(
          key: const ValueKey('member-menu-cancel'),
          icon: Icons.close,
          label: '取消',
        ),
      ],
    );
    if (choice == null || !mounted) return;
    if (choice == null || !mounted) return;
    final svc = ref.read(qq8LoginServiceProvider);
    if (!svc.isOnline) {
      _toast('群成员管理要协议线在线');
      return;
    }
    try {
      switch (choice) {
        case 'mute':
          final r = await svc.muteGroupMember(gid: gid, uid: m.uin);
          _toast(r.ok ? '已禁言 10 分钟' : '禁言未确认：${r.message ?? r.code}');
        case 'unmute':
          final r = await svc.muteGroupMember(gid: gid, uid: m.uin, seconds: 0);
          _toast(r.ok ? '已解除禁言' : '解除未确认：${r.message ?? r.code}');
        case 'admin':
          final r = await svc.setGroupAdmin(
              gid: gid, uid: m.uin, enable: !m.admin);
          _toast(r.ok
              ? (m.admin ? '已取消管理员' : '已设为管理员')
              : '操作未确认：${r.message ?? r.code}');
        case 'kick':
          final confirmed = await _confirmKick(m.displayName);
          if (!confirmed) return;
          final r = await svc.kickGroupMember(gid: gid, uid: m.uin);
          _toast(r.ok ? '已踢出' : '踢出未确认：${r.message ?? r.code}');
      }
    } on Object catch (e) {
      _toast('操作失败：$e');
    }
  }

  Future<bool> _confirmKick(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        key: const ValueKey('member-kick-dialog'),
        backgroundColor: TelegramColors.bgSidebar,
        title: const Text('踢出群聊'),
        content: Text('确定把 $name 移出本群？'),
        actions: <Widget>[
          TextButton(
            key: const ValueKey('member-kick-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('member-kick-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('踢出', style: TextStyle(color: TelegramColors.danger)),
          ),
        ],
      ),
    );
    return ok ?? false;
  }


  /// 打开群文件面板：列目录 / 下载 / 上传 / 删除全走协议线
  /// （`OidbSvc.0x6d8_1` 列目录、`0x6d6_0` 申请上传、`0x6d6_2` 取下载直链、
  /// `0x6d6_3` 删文件，上传本体走 highway 的 GroupFile=71）。
  ///
  /// 面板是哑的：这里把「怎么拉、怎么存」注入进去，面板只管画。
  Future<void> _openGroupFiles(Chat chat) async {
    final gid = chat.rawId;
    if (gid == null) return;
    final store = ref.read(chatStoreProvider);
    await GroupFilesPanel.show(
      context,
      title: '${chat.title} · 群文件',
      loader: (String pid) async {
        final svc = ref.read(qq8LoginServiceProvider);
        if (!svc.isOnline) {
          throw const SessionException('当前后端没有群文件能力（协议线在线才有）');
        }
        final page = await svc.fetchGroupFiles(gid, pid: pid);
        if (page.code != 0) {
          throw SessionException(
              '拉群文件失败：${page.message ?? '服务端返回 ${page.code}'}');
        }
        return page.entries;
      },
      onDownload: (Qq8GfsEntry file) async {
        final svc = ref.read(qq8LoginServiceProvider);
        if (!svc.isOnline) {
          throw const SessionException('群文件要协议线在线才能下载');
        }
        final link = await svc.groupFileDownloadUrl(gid, file.fid);
        final bytes = await Qq8File.downloadHttp(url: link.url);
        if (store == null) {
          throw const SessionException('拿不到数据目录，没法落盘');
        }
        final dir = Directory(
            '${store.dataDir.path}${Platform.pathSeparator}downloads');
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final out = File(
            '${dir.path}${Platform.pathSeparator}${_safeFileName(link.name)}');
        await out.writeAsBytes(bytes, flush: true);
        return out.path;
      },
      onUpload: () => _uploadGroupFile(gid),
      onCreateDir: (String name) async {
        final svc = ref.read(qq8LoginServiceProvider);
        if (!svc.isOnline) {
          throw const SessionException('建群文件夹要协议线在线');
        }
        final r = await svc.createGroupDir(gid: gid, name: name);
        if (r.code != 0) {
          throw SessionException(
              '建文件夹失败：${r.message ?? '服务端返回 ${r.code}'}');
        }
      },
      onRename: (Qq8GfsEntry entry, String name) async {
        final svc = ref.read(qq8LoginServiceProvider);
        if (!svc.isOnline) {
          throw const SessionException('改名要协议线在线');
        }
        final r = await svc.renameGroupEntry(gid: gid, entry: entry, name: name);
        if (r.code != 0) {
          throw SessionException('改名失败：${r.message ?? '服务端返回 ${r.code}'}');
        }
      },
      onDelete: (Qq8GfsEntry file) async {
        final svc = ref.read(qq8LoginServiceProvider);
        if (!svc.isOnline) {
          throw const SessionException('群文件要协议线在线才能删除');
        }
        final r = await svc.deleteGroupFile(gid: gid, file: file);
        if (r.code != 0) {
          throw SessionException(
              '删文件失败：${r.message ?? '服务端返回 ${r.code}'}');
        }
      },
    );
  }

  /// 上传到群文件：先填本地路径 → 申请上传（服务端已有同 md5 就秒传）→
  /// highway 传本体 → 0x6d9_4 回执。面板拿到返回后会自己重列。
  Future<void> _uploadGroupFile(int gid) async {
    final pathCtl = TextEditingController();
    final nameCtl = TextEditingController();
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('gf-upload-dialog'),
        backgroundColor: TelegramColors.bgSidebar,
        title: Text('上传到群文件',
            style: TextStyle(color: TelegramColors.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('填本地文件路径（任意类型，建议 ≤ 100 MiB）：'),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('gf-upload-path'),
              controller: pathCtl,
              autofocus: true,
              decoration: const InputDecoration(hintText: r'C:文档说明.pdf'),
            ),
            const SizedBox(height: 12),
            const Text('群里的文件名（留空 = 用原文件名）：'),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('gf-upload-name'),
              controller: nameCtl,
              decoration: const InputDecoration(hintText: '说明.pdf'),
              onSubmitted: (_) => Navigator.of(ctx)
                  .pop(<String>[pathCtl.text.trim(), nameCtl.text.trim()]),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('gf-upload-ok'),
            onPressed: () => Navigator.of(ctx)
                .pop(<String>[pathCtl.text.trim(), nameCtl.text.trim()]),
            child: const Text('上传'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || result.first.isEmpty) return;
    final path = result.first;
    final file = File(path);
    if (!file.existsSync()) {
      throw SessionException('找不到文件：$path');
    }
    final bytes = await file.readAsBytes();
    final fallback = path.split(RegExp(r'[\\/]')).last;
    final name = result.last.isEmpty ? fallback : result.last;
    final svc = ref.read(qq8LoginServiceProvider);
    if (!svc.isOnline) {
      throw const SessionException('群文件要协议线在线才能上传');
    }
    if (mounted) _toast('上传中：$name（${bytes.length} 字节）…');
    await svc.uploadGroupFile(gid: gid, name: name, bytes: bytes);
    if (mounted) _toast('已上传：$name');
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
            key: const ValueKey('ms-merge-forward'),
            onPressed: () => _forwardAsCard(chat.id, _selected.toList()),
            icon: Icon(Icons.merge_type, color: TelegramColors.textSecondary),
            tooltip: '合并转发',
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
                          // 行组件无状态：自动 keepalive 只在浪费（TG 的
                          // RecyclerListView 也只对真正带状态的行保活）。
                          addAutomaticKeepAlives: false,
                          // 离屏 400px 预解码窗口：图片进屏前解码已在进行，
                          // 等价于 RecyclerView 的 prefetch。
                          // ignore: deprecated_member_use
                          cacheExtent: 400,
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
                            // 新消息气泡淡入 + 轻微上浮（TG 的 appear 动画）。
                            return BubbleEntrance(
                              key: ValueKey<String>('bubble-${m.id}'),
                              animate: _shouldAnimateBubble(m),
                              child: Row(
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
                                  // 槽宽必须 >= 头像尺寸 + 左右内边距（8+6）。
                                  // 早先是 +10：44 减掉 14 只剩 30，头像被压成
                                  // 30x34 —— ClipOval/BoxShape.circle 在非正方盒里
                                  // 画出来就是椭圆，群里看着"不是正圆"。
                                  SizedBox(
                                    width: TelegramMetrics.bubbleAvatarSize + 14,
                                    child: item.showAvatar
                                        ? Padding(
                                            padding: const EdgeInsets.only(
                                              left: 8,
                                              right: 6,
                                            ),
                                            child: TelegramAvatar(
                                              name: _senderLabelOf(m, chat),
                                              // 群聊里 senderId 就是说话人的
                                              // uin；非数字（OneBot 旧数据）
                                              // 时退回首字母。
                                              url: int.tryParse(m.senderId) ==
                                                      null
                                                  ? null
                                                  : 'https://q1.qlogo.cn/g?b=qq&nk=${m.senderId}&s=100',
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
                                      localMedia: store?.mediaPathOf,
                                      ensureMedia: store?.ensureMedia,
                                      onOpenFile: (seg) =>
                                          unawaited(_downloadFileMessage(seg)),
                                      onRetry:
                                          m.isFailed ? () => _retry(m.id) : null,
                                      showSenderName: item.showSenderName,
                                      senderLabel: _senderLabelOf(m, chat),
                                      avatarVisible: item.showAvatar,
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
                              ),
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
        ChatInputBar(
          enabled: store != null,
          controller: _inputController,
          replyTarget: _replyTarget,
          onSend: _send,
          onAttachImage: () => unawaited(_sendImageFromPath()),
          onAttachFile: () => unawaited(_sendFileFromPath()),
          onOpenFaces: _openFacePicker,
          onCancelReply: _cancelReply,
        ),
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
        ChatInputBar(
          enabled: false,
          controller: _inputController,
          onSend: _send,
          onAttachImage: () => unawaited(_sendImageFromPath()),
          onAttachFile: () => unawaited(_sendFileFromPath()),
          onOpenFaces: _openFacePicker,
          onCancelReply: _cancelReply,
        ),
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
    // 头部抽成公共组件（lib/ui/widgets/chat_header.dart），几何见 ChatAvatarContainer.java
    return ChatHeader(
      chat: chat,
      onBack: onBack,
      onOpenMembers: () => unawaited(_openMembers(chat)),
      onOpenGroupFiles: () => unawaited(_openGroupFiles(chat)),
      onOpenGroupSettings: () => unawaited(_openGroupSettings(chat)),
      onOpenSettings: _openSettings,
    );
  }

}