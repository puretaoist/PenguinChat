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
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../client_api/chat_store.dart';
import '../../client_api/objects.dart';
import '../../client_api/segment.dart';
import '../../client_api/qq8_login_service.dart';
import '../../client_api/qq8_providers.dart';
import '../../client_api/session.dart';
import '../../infra/audio/silk_encoder.dart';
import '../../infra/media/image_compress.dart';
import '../../infra/log/logger.dart';
import '../../kernel/wlogin8/qq8_file.dart';
import '../../kernel/wlogin8/qq8_gfs.dart';
import '../../kernel/wlogin8/qq8_list.dart';
import '../../client_api/session_providers.dart';
import '../platform/app_breakpoints.dart';
import '../platform/wide_tab_state.dart';
import '../widgets/glass_sheet.dart';
import '../widgets/horizontal_pager.dart';
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
import '../widgets/message_action_popup.dart';
import '../widgets/message_actions.dart';
import '../widgets/jump_to_latest.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/chat_list_panel.dart';
import '../widgets/chat_wallpaper.dart';
import '../widgets/message_list_builder.dart';
import '../widgets/telegram_avatar.dart';
import '../widgets/pressable_scale.dart';
import 'connect_page.dart';
import 'contacts_page.dart';
import 'my_profile_page.dart';
import 'qq8_connect_page.dart';
import 'search_page.dart';
import 'settings_page.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({
    super.key,
    this.connecting = false,
    this.previewChats = const <Chat>[],
    this.onChatPaneVisibilityChanged,
    this.reverseMessageList = true,
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

  /// 窄屏下"是否正在看对话"（true=对话页，false=列表页）。
  ///
  /// 外壳（HomeShell）据此决定底栏显隐：进对话要让位给输入栏。
  final ValueChanged<bool>? onChatPaneVisibilityChanged;

  /// 消息列表是否反向排（原型开关，**默认开**：Telegram 默认也是反向）。
  ///
  /// 反向 = [ListView.reverse] + items 倒序取：序号 0 在视口底部，新消息天然
  /// 长在当前视角下方，滚动 offset 0 就等于"贴最新"。Telegram 也是同一个
  /// 布尔量控制朝向（ChatActivity:2660 `reversed`，:6553 `!reversed` 传给
  /// LinearLayoutManager），没有第二套 adapter——这里同理，只翻朝向与取数顺序。
  ///
  /// 为什么先做成构造参数而不进 uiPrefs：原型阶段要能在测试里逐例开关；
  /// 落盘偏好等真机验过滚动手感再谈（见 qqclient-scroll-audit-handoff.md）。
  final bool reverseMessageList;

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

  /// 会话列表的滚动控制器（宽屏左栏用；"点当前 tab 回顶"要能命令它）。
  final _chatListController = ScrollController();

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

  /// 已经触发过"补群成员名字"的会话。ensureGroupNames 命中冷却时立即返回，
  /// 其回调又会 setState——不记一笔就会 build→触发→setState 无限转。
  final Set<String> _groupNamesWarmed = <String>{};
  ChatStore? _openedForStore;

  /// 未读分隔线的锚点（= 打开会话那一刻的 `Chat.lastReadId`）。
  ///
  /// 为什么快照：`openChat` 会立刻把 `lastReadId` 推到最新一条（那是"已读位置"
  /// 的正确语义），但分隔线要留在**当初开始未读的地方**——不然一进会话线就没了。
  /// 换会话时清空，所以它只在本次会话里存活，和 TG/Nagram 的行为一致。
  String? _unreadAnchorId;

  /// 消息列表是不是贴在底部（决定要不要显示"跳到最新"按钮）。
  bool _atBottom = true;

  /// 每个会话记住的滚动**锚点**（消息 id + 距视口底的距离）。
  ///
  /// 为什么不再存像素 offset：像素只在"列表长度与行高都没变"时才对得上。
  /// 离开一个会话期间来了新消息、图片/语音解码完把行撑高、或者上面翻出更早的
  /// 历史，都会让同一个 pixels 指向另一条消息——表现就是"回来位置不对"。
  ///
  /// 换成 {msgId, offsetFromBottom} 就与"有没有新消息"解耦：锚的是消息本身，
  /// 恢复时按它的实际渲染位置反算 pixels。Telegram 就是这么存的
  /// （ChatActivity:24157-24163：findFirstVisibleItemPosition +
  /// scrollToOffsetOnRecreate = height - itemView.getBottom() - paddingBottom）。
  ///
  /// 键不存在 = 上次离开时贴着底部（等价于 null 锚点 → 直接贴最新）。
  final Map<String, _ScrollAnchor> _scrollAnchors = <String, _ScrollAnchor>{};

  /// 当前 _scrollController 记录的是哪个会话的位置。
  String? _scrollOwnerChatId;

  /// 会话代次：owner 每变一次 +1（见 [_beginChatAttempt]）。
  ///
  /// 所有异步 open/恢复/钉底回调都把发起时的代次带回来，对不上就整段放弃。
  /// 没有它，A 会话慢完成的 openChat 会把已切到 B 的视口按 A 的目标改写，
  /// 还会顺手清掉 B 正在进行的恢复守卫（审计第 1、2 条）。
  int _chatGeneration = 0;

  /// 正在还原/贴底定位的会话：这期间滚动回调不许写缓存（否则把中间值记进去）。
  String? _restoringChatId;

  /// 正在把列表钉在底部（打开会话/发送后的一小段时间）。
  bool _pinningBottom = false;

  /// 正在跑"滚到最新"的动画。
  ///
  /// [_pinTick] 每帧都会 jumpTo(底部)，那会把动画的下一帧直接覆盖掉——动画
  /// 等于不存在（改造前真机上就是这样，220ms 的 animateTo 实际是瞬移）。
  /// 动画期间让钉底只观测不跳，收尾再由 [_scrollToBottom] 补一次精确落位。
  bool _bottomAnimating = false;

  /// 本次钉底所属的会话代次（-1 = 没有激活的钉底）。
  int _pinGeneration = -1;

  /// 连续"内容没长高且在底部"的帧数，用来提前结束钉底。
  int _pinStable = 0;

  /// 上一帧的 maxScrollExtent，用于判断内容是否还在长高。
  double _pinLastMax = -1;

  /// 钉底的绝对时间上限（不是帧数：120Hz 下 90 帧只有 0.75s）。
  DateTime _pinDeadline = DateTime.fromMillisecondsSinceEpoch(0);

  /// 切会话时要还原到的锚点（null = 没有记录 → 贴底）。
  _ScrollAnchor? _pendingRestore;

  /// 正在程序化还原位置：此时 _onScroll 的写回要跳过，否则会把中间值
  /// 覆盖进记录，下次再回来就偏了。
  bool _restoringScroll = false;

  /// 当前输入框里装着哪个会话的草稿（换会话时要靠它判断"要不要先存上一份"）。
  String? _draftChatId;
  Timer? _draftTimer;

  /// 缓存的 store 引用：`dispose()` 里 **不能再碰 `ref`**（Riverpod 会抛
  /// "Cannot use ref after the widget was disposed"），而退出前还想把草稿写回去，
  /// 所以每次 build 时把 store 记在这里，[flushDraft] 只用这个字段。
  ChatStore? _draftStore;

  /// 多选模式里选中的消息 id（空 = 不在多选模式）。
  final Set<String> _selected = <String>{};

  /// 每个气泡自己的 RenderBox（消息 id → box），由 [MessageBubble.onBubbleBox]
  /// 在挂树时写入、摘树时删除。单击气泡弹菜单要贴着**气泡**，而不是整行或
  /// 屏幕边；存 box 而不是 Rect，点击那一刻再算位置才不会因滚动而过期。
  final Map<String, RenderBox> _bubbleBoxes = <String, RenderBox>{};

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

  /// 正在翻页的会话集合（按会话隔离）。原来是全局 bool，A 会话翻页时
  /// B 会话的翻页请求会被直接丢掉（审计第 5 条）。
  final Set<String> _loadingMoreChats = <String>{};

  /// 用户是否正用手指拖动列表：区分"用户想看历史"和"程序在贴底"。
  bool _userDragging = false;

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
    _saveScrollAnchor();
    _flushDraft();
    _draftTimer?.cancel();
    _stopBottomPin();
    _scrollController.removeListener(_onScroll);
    _inputController.removeListener(_onInputChanged);
    _inputController.dispose();
    _scrollController.dispose();
    _chatListController.dispose();
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
    final pos = _safePosition;
    if (pos == null) return;
    final atBottom = _isAtBottom(pos);
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
    if (atBottom) _markReadIfUnread();
    // 钉底期间位置被拉离底部 = 用户自己往上翻了：立刻放开，别跟他抢。
    // （内容长高不会改变 pixels，所以这里不会误判。）
    if (_pinningBottom && !atBottom) _stopBottomPin();

    // 锚点不在这里记：抓锚要遍历可见气泡的 RenderBox，拖着列表时每帧都做
    // 是白花钱。真正用到它的时刻只有"离开会话"，而那几处（切会话 / 返回
    // 列表 / dispose）都会显式调 [_saveScrollAnchor]；滚动结束时再补记一次。

    // 只有用户主动往历史那一端拖才翻页：程序性 jumpTo（贴底/恢复/锚点补偿）
    // 落在尽头也不该触发分页（审计第 5 条）。
    if (_userDragging && _nearHistoryEnd(pos)) {
      unawaited(_loadMore());
    }
  }

  /// 恰好一个 position 时才返回，否则 null。
  ///
  /// AnimatedSwitcher 交叉淡入的 220ms 里同一 controller 可能同时挂着新旧两个
  /// 列表；`.position` 在两个 position 时会直接抛
  /// "ScrollController attached to multiple scroll views"。过渡帧里宁可不动。
  ScrollPosition? get _safePosition {
    final c = _scrollController;
    if (!c.hasClients || c.positions.length != 1) return null;
    return c.positions.first;
  }

  /// 用户一动手就放弃程序性贴底/恢复。
  ///
  /// 只有 ScrollStartNotification 带 dragDetails 才是手指拖动（惯性滑动不带），
  /// 这是审计第 3 条要求补的真实输入信号——旧实现只在离底 40px 时停，
  /// 起手与前 40px 仍会被 jumpTo 抢走。
  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _userDragging = true;
      _stopBottomPin();
      _restoringChatId = null;
      _restoringScroll = false;
      // 滚动时收起键盘（设置 → 聊天 → 滚动时收起键盘，抄
      // ExteraConfig.hideKeyboardOnScroll）。只认手指拖动，程序性贴底不收。
      if (ref.read(uiPrefsProvider).hideKeyboardOnScroll) {
        FocusScope.of(context).unfocus();
      }
    } else if (n is ScrollEndNotification) {
      _userDragging = false;
      // 手势滚完补记一次锚点：用户滚到半路直接被杀/被切走时也有个像样的记录。
      _saveScrollAnchor();
    }
    return false;
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
    if (_loadingMoreChats.contains(chatId) || !store.hasMore(chatId)) return;
    final pos = _safePosition;
    final double? oldPixels = pos?.pixels;
    final double? oldMax = pos?.maxScrollExtent;
    final int gen = _chatGeneration;
    _loadingMoreChats.add(chatId);
    try {
      await store.loadMore(chatId);
    } finally {
      _loadingMoreChats.remove(chatId);
    }
    // 反向列表天然不需要补偿：前插的更早消息落在列表另一端（离 offset 0
    // 最远的地方），当前视口在 offset 0 附近，一个像素都不会动。
    if (_reverseList) return;
    // 历史是【前插】到顶部的：插入后 maxScrollExtent 变大，原来的 pixels
    // 对应的就是另一条消息了。按 max 的增量平移 pixels，让屏幕上的同一条
    // 消息保持同一偏移（审计第 5 条的核心）。
    if (oldPixels == null || oldMax == null) return;
    if (gen != _chatGeneration || _resolvedChatId != chatId) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || gen != _chatGeneration) return;
      final p = _safePosition;
      if (p == null) return;
      final double delta = p.maxScrollExtent - oldMax;
      if (delta == 0) return;
      final double goal = (oldPixels + delta).clamp(0.0, p.maxScrollExtent);
      _restoringScroll = true;
      p.jumpTo(goal);
      _restoringScroll = false;
    });
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
    // 名字缓存、消息昵称、成员名单全都没有 → 返回空，气泡上不画名字。
    // 不退回 QQ 号：真机 m05843 装机后整群名字全变成一串数字（3152301865…），
    // 比空白更难认；名单是异步补的（_openChat 里 ensureGroupNames + setState），
    // 通常一两秒后就变成网名，加载期间宁可空着。
    return '';
  }

  void _openChat(Chat chat) {
    // 预览期（store 还没建好）点会话没有意义：没有历史可拉、也发不出去。
    // 让这一下"什么都没发生"，比切到一个空对话面板更像话。
    if (ref.read(chatStoreProvider) == null) return;
    // 先把上一个会话的位置存下来，再把"这次要还原到哪"定好。
    _saveScrollAnchor();
    _beginChatAttempt(chat.id);
    setState(() {
      _selectedChatId = chat.id;
      _showChatList = false;
    });
    widget.onChatPaneVisibilityChanged?.call(true);
    unawaited(_ensureOpened(chat.id));
    // 每次主动点开都允许重试一次（上次可能因为没上线 / 接口失败而没拉到）。
    _groupNamesWarmed.remove(chat.id);
    _warmGroupNames(chat);
  }

  /// 补群成员名字（群名片优先、退到昵称）。
  ///
  /// 群消息体里经常不带昵称，成员名单是唯一的名字来源。**进群的两条路都要走这里**：
  /// 窄屏点开走 [_openChat]，宽屏自动选中走 build 里的分支——只补前者的话，
  /// 平板冷启动那一屏只有消息自带昵称的人有名字（真机 m06603：「只有 净凾 显示」）。
  /// 服务层有 10 分钟冷却，这里再用 [_groupNamesWarmed] 保证每个会话只触发一次，
  /// 否则回调里的 setState 会让 build → 触发 → setState 无限转。
  void _warmGroupNames(Chat chat) {
    final gid = chat.rawId;
    final names = _namesService();
    if (chat.type != ChatType.group || gid == null || names == null) return;
    if (!_groupNamesWarmed.add(chat.id)) return;
    unawaited(
      names.ensureGroupNames(gid).then((_) {
        // 名字是异步补的，补到就重画一次，气泡上的发言人才能立刻变成网名。
        if (mounted) setState(() {});
      }),
    );
  }

  /// 切到 [chatId]：翻代次、认领 owner、取回上次位置。
  ///
  /// 所有"这次打开会话"的入口都必须走这里：代次不翻，旧的异步回调还能
  /// 认领新会话的视口（审计第 1 条）。
  void _beginChatAttempt(String chatId) {
    _chatGeneration++;
    _scrollOwnerChatId = chatId;
    _pendingRestore = _scrollAnchors[chatId];
    // 旧链的钉底/恢复立即作废
    _pinningBottom = false;
    _pinGeneration = -1;
    _restoringChatId = null;
    _restoringScroll = false;
  }

  /// 打开会话：首次会拉历史并清未读。
  ///
  /// 重复调用由 [ChatStore] 自己挡（`_historyFetched`），但**锚点每次都要重算**，
  /// 所以要放在 `_opened` 守卫之外——否则重回同一个会话会留着上次的未读线。
  Future<void> _ensureOpened(String chatId) async {
    final store = ref.read(chatStoreProvider);
    if (store == null) return;
    final int gen = _chatGeneration;
    final chat = store.chats.where((c) => c.id == chatId).firstOrNull;
    _unreadAnchorId = (chat != null && chat.unreadCount > 0)
        ? chat.lastReadId
        : null;
    if (!_opened.add(chatId)) {
      // 会话早就打开过（数据在内存里）：直接还原上次的位置，不重拉历史。
      if (gen == _chatGeneration && _scrollOwnerChatId == chatId) {
        _restoreScroll(gen);
      }
      return;
    }
    await store.openChat(chatId);
    // 慢完成：期间用户已经切走（或切回又切走）→ 这次的结果不再属于当前视口。
    if (!mounted || gen != _chatGeneration || _scrollOwnerChatId != chatId) {
      return;
    }
    // 第一次打开：有记录就还原，没有就贴底。
    _restoreScroll(gen);
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

  /// 📎「发送图片」：打开系统相册（image_picker 的系统 Photo Picker）。
  ///
  /// 为什么走相册而不是"填路径"：手机上没有"文件树"这个概念，用户脑子里
  /// 就是相册缩略图。Android 13+ 走 Photo Picker、低版本走
  /// ACTION_GET_CONTENT，都**不需要** READ_MEDIA_IMAGES 权限。
  ///
  /// 桌面/精简 ROM 上没有实现时回落到"填路径"对话框，保证任何环境都能发图。
  Future<void> _pickAndSendImages() async {
    final store = ref.read(chatStoreProvider);
    final chatId = _resolvedChatId;
    if (store == null || chatId == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    List<String> paths = const <String>[];
    try {
      final picked = await ImagePicker().pickMultiImage(limit: 9);
      paths = <String>[for (final x in picked) x.path];
    } on Object catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('打不开相册（$e），改用路径发送')));
      await _sendImageFromPath();
      return;
    }
    if (paths.isEmpty) return; // 用户取消
    await _sendImageFiles(store: store, chatId: chatId, paths: paths);
  }

  /// 逐张发送本地图片：每条消息一张图。
  ///
  /// 多选 N 张就是发 N 条消息（和微信/QQ 的相册多选一致）。"一条消息带多张
  /// 图"的渲染在官方客户端上没实测过，不拿用户的消息去冒险；协议层虽然支持
  /// 拼多个图片元素，这里仍按一条一张发。
  ///
  /// 输入框里已经打了字时，文字并入**第一条**图片消息（同一条里图文混排），
  /// 发完清空输入框——这是"先打字再点 + 号"的自然预期。
  Future<void> _sendImageFiles({
    required ChatStore store,
    required String chatId,
    required List<String> paths,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final typed = _inputController.text.trim();
    final total = paths.length;
    var ok = 0;
    final failures = <String>[];
    for (var i = 0; i < total; i++) {
      final raw = paths[i];
      final name = raw.split(RegExp(r'[\\/]')).last;
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            duration: const Duration(minutes: 2),
            content: Text(total > 1 ? '发送图片 ${i + 1}/$total …' : '发送图片…'),
          ),
        );
      try {
        final prepared = await _prepareImageForSend(raw);
        final segs = <Segment>[
          if (i == 0 && typed.isNotEmpty) TextSegment(typed),
          ImageSegment(
            prepared.path,
            width: prepared.width,
            height: prepared.height,
          ),
        ];
        await store.send(chatId, segs);
        if (i == 0 && typed.isNotEmpty) _inputController.clear();
        ok++;
      } on Object catch (e) {
        failures.add('$name：$e');
      }
    }
    messenger?.hideCurrentSnackBar();
    if (failures.isEmpty) {
      messenger?.showSnackBar(
        SnackBar(content: Text(total > 1 ? '已发送 $ok 张图片' : '图片已发送')),
      );
      return;
    }
    messenger?.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text('$ok 张成功，${failures.length} 张失败：${failures.join('；')}'),
      ),
    );
  }

  /// 读文件 → 压缩（>5 MiB 或长边 >2560 才真压）→ 需要时落到临时文件。
  ///
  /// 为什么要落盘：协议层按"路径"读图（[ImageSegment.file]），而压缩后的
  /// 字节不在原文件里。临时文件放在系统临时目录的子目录，不主动删——气泡
  /// 渲染要靠它（媒体缓存把它拷进 `<dataDir>/media/photos` 之后才算落地），
  /// 而系统临时目录本身会被 OS 定期清理，不值得为几十 KB 做引用计数。
  Future<_PreparedSend> _prepareImageForSend(String path) async {
    final prepared = await ImageCompressor.prepareFile(
      path,
      name: path.split(RegExp(r'[\\/]')).last,
    );
    var outPath = path;
    if (prepared.changed) {
      final dir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}penguin_send',
      );
      await dir.create(recursive: true);
      final ext = prepared.format == 'png' ? 'png' : 'jpg';
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final out = File('${dir.path}${Platform.pathSeparator}$stamp.$ext');
      await out.writeAsBytes(prepared.bytes, flush: true);
      outPath = out.path;
      Log.get('Home').i('图片压缩：${prepared.note}');
    }
    return _PreparedSend(
      path: outPath,
      width: prepared.width,
      height: prepared.height,
    );
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
            const Text(
              '发送时先上传到 QQ 图床（服务端已有同一张图就免传），'
              '再把 fid 填进消息发出去。',
              style: TextStyle(fontSize: 12),
            ),
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
    await _sendImageFiles(store: store, chatId: chatId, paths: <String>[path]);
  }

  /// 🎤：录完的语音（裸 PCM）→ 编成 SILK v3 → 交给协议层上传发送。
  ///
  /// 编码放在 L1（[SilkVoiceEncoder]）而不是这里：UI 只负责把"录到了什么"
  /// 交出去。编码失败/发不出去都只弹一条提示，不打断会话。
  Future<void> _sendVoice(
    String pcmPath,
    int durationMs,
    List<double> waveform,
  ) async {
    final store = ref.read(chatStoreProvider);
    final chatId = _resolvedChatId;
    if (store == null || chatId == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final encoder = SilkVoiceEncoder();
    String? slk;
    try {
      slk = await encoder.encodeFile(pcmPath);
    } finally {
      encoder.dispose();
    }
    if (slk == null) {
      messenger?.showSnackBar(const SnackBar(content: Text('语音编码失败，没发出去')));
      return;
    }
    final seconds = (durationMs / 1000).round().clamp(1, 60);
    final size = File(slk).lengthSync();
    try {
      await store.send(chatId, <Segment>[
        RecordSegment('', localPath: slk, seconds: seconds, size: size),
      ]);
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('语音发送失败：$e')));
    }
  }

  /// 📄：发本地**文件**（离线文件）。同样用"填路径"的对话框，读文件在适配器里做。
  ///
  /// 只支持私聊：群文件是另一套命令、还有目录概念（适配器会明确抛错）。
  Future<void> _sendFileFromPath() async {
    final store = ref.read(chatStoreProvider);
    final chatId = _resolvedChatId;
    if (store == null || chatId == null) return;
    if (Chat.parseKey(chatId)?.type != ChatType.private) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('群文件还没接，先用私聊发文件')));
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
              onSubmitted: (_) =>
                  Navigator.of(ctx)
                      .pop(<String>[pathCtl.text.trim(), nameCtl.text.trim()]),
            ),
            const SizedBox(height: 8),
            const Text(
              '发送时先传到 QQ 的离线文件通道（服务端已有同 md5 就免传），'
              '再把文件 id 填进消息发出去。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('send-file-ok'),
            onPressed: () =>
                Navigator.of(ctx)
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

  /// 视口是不是贴在最"新"的一端（决定"跳到最新"按钮显不显示、要不要清未读）。
  ///
  /// 非反向列表最新在底（maxScrollExtent），反向列表最新在顶（offset 0）。
  /// 所有"离底多远"的判断都必须走这里，否则一开反向开关整套语义就反了。
  bool _isAtBottom(ScrollPosition pos) => _distToBottom(pos) <= 40;

  /// 距离"最新那一端"还有多少像素。
  double _distToBottom(ScrollPosition pos) =>
      _reverseList ? pos.pixels : pos.maxScrollExtent - pos.pixels;

  /// 贴最新消息时应该滚到的 offset（反向列表是 0，否则是 maxScrollExtent）。
  double _bottomOffset(ScrollPosition pos) =>
      _reverseList ? 0.0 : pos.maxScrollExtent;

  /// 历史那一端是不是快到了（到尽头就该翻页）。
  bool _nearHistoryEnd(ScrollPosition pos) =>
      _reverseList ? pos.maxScrollExtent - pos.pixels <= 24 : pos.pixels <= 24;

  /// 原型开关：消息列表反向排（默认关，见 HomePage.reverseMessageList）。
  bool get _reverseList => widget.reverseMessageList;

  /// 消息视口的全局矩形，用来把气泡坐标换算成"距视口底多远"。
  Rect? _viewportRectOf(ScrollPosition pos) {
    final ro = pos.context.storageContext.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
    return ro.localToGlobal(Offset.zero) & ro.size;
  }

  /// 抓当前视口的锚点：**第一条可见消息** + 它底边距视口底的距离。
  ///
  /// 为什么取第一条而不是最后一条：最后一条常被视口底截断，底边跑到视口外，
  /// 存下来的偏移是负的、恢复时只能贴底；第一条几乎总是完整可见的，偏移稳定。
  /// Telegram 取 findFirstVisibleItemPosition 也是这个道理。
  _ScrollAnchor? _captureAnchor() {
    final pos = _safePosition;
    if (pos == null) return null;
    final vp = _viewportRectOf(pos);
    if (vp == null) return null;
    String? bestId;
    double bestTop = double.infinity;
    double bestBottom = 0;
    for (final e in _bubbleBoxes.entries) {
      final b = e.value;
      if (!b.attached || !b.hasSize) continue;
      final r = b.localToGlobal(Offset.zero) & b.size;
      // 与视口有交集才算可见：完全落在上下缓冲区的行不能当锚点。
      if (r.bottom <= vp.top || r.top >= vp.bottom) continue;
      if (r.top < bestTop) {
        bestTop = r.top;
        bestBottom = r.bottom;
        bestId = e.key;
      }
    }
    if (bestId == null) return null;
    return _ScrollAnchor(bestId, vp.bottom - bestBottom);
  }

  /// 把当前会话的滚动锚点存进 map（切会话 / 返回列表 / dispose 前调用）。
  void _saveScrollAnchor() {
    final owner = _scrollOwnerChatId;
    if (owner == null || _restoringScroll || _restoringChatId != null) return;
    final pos = _safePosition;
    if (pos == null) return;
    // 停在底部 = 不留锚点：还原时直接贴最新。存一条具体消息会在"离开后又有
    // 新消息"时停在旧消息上（明明该看最新），是另一类"记忆不对"。
    if (_isAtBottom(pos)) {
      _scrollAnchors.remove(owner);
      return;
    }
    final anchor = _captureAnchor();
    if (anchor == null) {
      _scrollAnchors.remove(owner);
      return;
    }
    _scrollAnchors[owner] = anchor;
  }

  /// 切回会话时按锚点还原位置；没有记录就贴底。
  ///
  /// 为什么用 jumpTo 而不是 animateTo：还原是"回到原样"，不是一次滚动动作；
  /// 动画会让用户先看到底部再被拉上去。
  ///
  /// 为什么要连续几帧（而不是算一次 jumpTo）：会话刚打开时消息可能还没上树
  /// （空列表画的是占位），也可能上树了但 maxScrollExtent 还是估算值；锚点
  /// 消息甚至可能还没被构建（离视口太远）。所以每帧看一次，先粗跳再精修。
  void _restoreScroll(int gen) {
    if (gen != _chatGeneration) return;
    final anchor = _pendingRestore;
    _pendingRestore = null;
    _restoringChatId = _scrollOwnerChatId;
    _anchorStep(anchor, gen, 0);
  }

  /// 一帧一步地逼近锚点。
  ///
  /// 流程：锚点消息已在树上 → 按几何差精确校正（一帧到位）；不在 → 用"屏幕
  /// 最上面那条消息的下标"与锚点下标算出差多少条，乘平均行高，一步跳过去。
  /// 这个"按 index 估算 + 按 RenderBox 校正"对应 Telegram 的
  /// scrollToPositionWithOffset（ChatActivity:18594-18597）：Flutter 没有按
  /// index 定位的 API，只能先估 pixels 再按实际布局修正。
  /// 为什么不能只跳一次：maxScrollExtent 是 Flutter 按"已构建项平均高度"外推
  /// 的估算值，真机上图片多，误差能到 20%，所以要多迭代几帧直到差 < 0.5px。
  void _anchorStep(_ScrollAnchor? anchor, int gen, int tries) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || gen != _chatGeneration) return;
      final pos = _safePosition;
      if (pos == null) {
        // 列表还没上树（消息为空时画的是占位）或正处于两页交叉淡入。
        if (tries < 20) {
          _anchorStep(anchor, gen, tries + 1);
        } else {
          _restoringChatId = null;
        }
        return;
      }
      if (anchor == null) {
        // 没有记录 → 贴最新。贴底不能只做一次 jumpTo（max 是估算值，
        // 图片/语音解码完还会长高），交给带代次与稳定判定的钉底。
        _restoringChatId = null;
        _startBottomPin(gen);
        return;
      }
      if (pos.maxScrollExtent <= 0 && tries < 20) {
        // 列表在，但内容还没铺开：任何 clamp 都会落到 0，等下一帧。
        _anchorStep(anchor, gen, tries + 1);
        return;
      }
      final box = _bubbleBoxes[anchor.messageId];
      final vp = _viewportRectOf(pos);
      if (box != null && box.attached && box.hasSize && vp != null) {
        final r = box.localToGlobal(Offset.zero) & box.size;
        final double desiredBottom = vp.bottom - anchor.offsetFromBottom;
        final double delta = r.bottom - desiredBottom;
        // 反向列表里 pixels 增大 = 内容整体下移（非反向是上移），校正方向要翻。
        final double correction = _reverseList ? -delta : delta;
        if (correction.abs() > 0.5 && tries < 60) {
          _restoringScroll = true;
          pos.jumpTo(
            _clampPixels(pos.pixels + correction, pos.maxScrollExtent),
          );
          _restoringScroll = false;
          _anchorStep(anchor, gen, tries + 1);
          return;
        }
        _restoringChatId = null;
        final bool atBottom = _isAtBottom(pos);
        if (atBottom != _atBottom && mounted) {
          setState(() => _atBottom = atBottom);
        }
        return;
      }
      if (tries >= 60) {
        // 锚点消息一直没出现（被删了/被过滤了）→ 放弃精修，保持当前视口。
        // 宁可停在近似位置，也不硬拽到底部（那会把用户刚看的地方顶掉）。
        _restoringChatId = null;
        return;
      }
      final chatId = _scrollOwnerChatId;
      final msgs = chatId == null
          ? const <ChatMessage>[]
          : (ref.read(messagesProvider(chatId)).valueOrNull ??
                const <ChatMessage>[]);
      final int anchorIdx = msgs.indexWhere((m) => m.id == anchor.messageId);
      if (anchorIdx < 0) {
        // 锚点消息已经不在会话里（被删/被过滤）→ 保持当前视口，不硬拽。
        _restoringChatId = null;
        return;
      }
      // 当前屏幕最上面那条消息的下标：没有它就没法判断该往哪个方向找锚点。
      int curIdx = -1;
      for (final e in _bubbleBoxes.entries) {
        final int i = msgs.indexWhere((m) => m.id == e.key);
        if (i < 0) continue;
        if (curIdx < 0 || i < curIdx) curIdx = i;
      }
      double next;
      if (curIdx < 0) {
        // 一条气泡都没布局出来（空列表/过渡帧）：只能按平均行高粗估一次。
        final int indexFromEnd = msgs.length - 1 - anchorIdx;
        final double avg =
            (pos.maxScrollExtent + pos.viewportDimension) /
            (msgs.isEmpty ? 1 : msgs.length);
        next = _clampPixels(
          _reverseList
              ? indexFromEnd * avg
              : pos.maxScrollExtent - indexFromEnd * avg,
          pos.maxScrollExtent,
        );
      } else {
        // 锚点还没挂树：按"下标差 × 平均行高"估算要移动多远，一步跳过去。
        // 原来每帧只走 0.45 屏、tries 上限 24（最远约 10 屏），真机上图片多、
        // 消息多的会话锚点常在几十屏之外，走不到（真机验收踩到）。
        // 方向按朝向翻：非反向列表 pixels 增 = 看到更晚，反向列表反过来。
        final int gap = anchorIdx - curIdx; // 正 = 锚点更晚（更靠最新）
        if (gap == 0) {
          // 锚点理应就在屏上却没有它的 RenderBox：布局还没稳定，放弃精修。
          _restoringChatId = null;
          return;
        }
        final double avg = msgs.isEmpty
            ? 0.0
            : pos.maxScrollExtent / msgs.length;
        final double minStep = pos.viewportDimension * 0.45;
        final double guess = gap * avg;
        final double step = guess.abs() < minStep
            ? (guess.isNegative ? -minStep : minStep)
            : guess;
        final double dir = _reverseList ? -1.0 : 1.0;
        next = _clampPixels(pos.pixels + dir * step, pos.maxScrollExtent);
        if ((next - pos.pixels).abs() < 0.5) {
          // 已经顶到头，锚点仍没出现：放弃，保持当前视口。
          _restoringChatId = null;
          return;
        }
      }
      _restoringScroll = true;
      pos.jumpTo(next);
      _restoringScroll = false;
      _anchorStep(anchor, gen, tries + 1);
    });
    // postFrame 回调只在下一次出帧时才跑。没有别的 UI 事件时，它要一直等到
    // 下一次被动出帧（真机上见过几百毫秒的空档，期间停在粗跳位置）。主动要一帧。
    WidgetsBinding.instance.scheduleFrame();
  }

  /// 把 pixels 夹进 0..max（clamp 返回 num，这里固定成 double）。
  double _clampPixels(double v, double max) =>
      v < 0 ? 0.0 : (v > max ? max : v);

  /// 钉住底部，直到内容稳定、超时或用户动手。
  ///
  /// 为什么需要"连续"：打开会话那一刻只布局了可见的十几行，maxScrollExtent
  /// 是按平均行高外推的；图片/语音/长文本解码完，真实高度才会长出来。
  /// 时间上限 1.5s（**不是帧数**：120Hz 下 90 帧只有 0.75s，审计第 2 条）。
  /// 连续 [_pinStableTarget] 帧 max 不变且已在底部 = 内容稳定，提前收工。
  void _startBottomPin(int gen) {
    _stopBottomPin();
    if (gen != _chatGeneration) return;
    _pinningBottom = true;
    _pinGeneration = gen;
    _pinStable = 0;
    _pinLastMax = -1;
    _pinDeadline = DateTime.now().add(const Duration(milliseconds: 1500));
    WidgetsBinding.instance.addPostFrameCallback((_) => _pinTick());
    WidgetsBinding.instance.scheduleFrame();
  }

  static const int _pinStableTarget = 8;

  void _pinTick() {
    if (!mounted || !_pinningBottom || _pinGeneration != _chatGeneration) {
      _stopBottomPin();
      return;
    }
    if (_userDragging) {
      _stopBottomPin();
      return;
    }
    final pos = _safePosition;
    if (pos == null) {
      if (DateTime.now().isBefore(_pinDeadline)) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _pinTick());
        WidgetsBinding.instance.scheduleFrame();
      } else {
        _stopBottomPin();
      }
      return;
    }
    final double max = pos.maxScrollExtent;
    final double goal = _bottomOffset(pos);
    // 动画期间不要抢跳：jumpTo 会覆盖掉动画的下一帧，动画就退化成瞬移。
    if (!_bottomAnimating && (pos.pixels - goal).abs() > 1) pos.jumpTo(goal);
    if (max == _pinLastMax && _distToBottom(pos).abs() <= 1) {
      _pinStable++;
    } else {
      _pinStable = 0;
      _pinLastMax = max;
    }
    final bool timeUp = !DateTime.now().isBefore(_pinDeadline);
    if (!timeUp && _pinStable < _pinStableTarget) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pinTick());
      WidgetsBinding.instance.scheduleFrame();
      return;
    }
    final bool atBottom = _isAtBottom(pos);
    _stopBottomPin();
    if (atBottom != _atBottom && mounted) setState(() => _atBottom = atBottom);
  }

  void _stopBottomPin() {
    _pinningBottom = false;
    _pinGeneration = -1;
    _pinStable = 0;
    _pinLastMax = -1;
  }

  /// 滚到最新：打开会话、发送后、点"跳到最新"都走这里。
  ///
  /// 动画参数照抄 Telegram：
  /// - 时长 `clamp((距离/视口 + 1) * 200ms, 300ms, 1300ms)`
  ///   （Components/RecyclerAnimationScrollHelper.java:339-343）；
  /// - 曲线 EASE_OUT_QUINT → Flutter `Curves.easeOutQuint`（同上 :347）；
  ///   近距离的 LinearSmoothScrollerCustom 用 DecelerateInterpolator(1.5)
  ///   （= 1-(1-t)^3，同样是"起步快、收尾慢"），时长 `max(400, 距离×0.0568/0.3356)`
  ///   （ui/recyclerview/LinearSmoothScrollerCustom.java:onTargetFound）。
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pos = _safePosition;
      if (pos == null) return;
      _startBottomPin(_chatGeneration);
      final double goal = _bottomOffset(pos);
      final double dist = (goal - pos.pixels).abs();
      if (dist < 1) return;
      if (dist > pos.viewportDimension * _maxAnimatedJumpScreens) {
        // 距离几十屏时不真滚：那样每帧都要新建几十个气泡，必然掉帧。
        // Telegram 的等效做法也只把"当前这一屏"平移出去
        // （RecyclerAnimationScrollHelper 的 scrollLength 就是一屏量级），
        // 观感上同样是一次换屏，所以这里直接落位。
        pos.jumpTo(goal);
        return;
      }
      _bottomAnimating = true;
      unawaited(
        _scrollController
            .animateTo(
              goal,
              duration: _jumpDuration(pos, dist),
              curve: Curves.easeOutQuint,
            )
            .whenComplete(() {
              _bottomAnimating = false;
              if (!mounted) return;
              final p = _safePosition;
              if (p == null) return;
              // 动画期间内容可能又长高了（图片解码），收尾补一次精确落位。
              final double target = _bottomOffset(p);
              if ((p.pixels - target).abs() > 1) p.jumpTo(target);
            }),
      );
    });
  }

  /// 超过几屏就不做"真滚动"动画（见 [_scrollToBottom]）。
  static const double _maxAnimatedJumpScreens = 3.0;

  /// Telegram 的跳转时长：`clamp((距离/视口 + 1) * 200ms, 300ms, 1300ms)`。
  Duration _jumpDuration(ScrollPosition pos, double distance) {
    final double vp = pos.viewportDimension;
    final double ratio = vp <= 0 ? 0.0 : distance / vp;
    final int ms = ((ratio + 1) * 200).clamp(300.0, 1300.0).round();
    return Duration(milliseconds: ms);
  }

  void _openConnectPage() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const ConnectPage()));
  }

  /// 协议线（QQ 自实现协议）登录直达入口。
  void _openQq8Login() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const Qq8ConnectPage()));
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
    // 宽屏当前 tab：HomeShell 画胶囊、这里画左栏内容，两边共用一个 provider
    // （见 wide_tab_state.dart）。窄屏不用它。
    final int wideTab = ref.watch(wideTabProvider);
    // 宽屏"点当前 tab 回顶"（MainTabsActivity.java:334-349）：外壳自增一次，
    // 这里把会话列表滚回顶部。
    ref.listen<int>(chatListToTopProvider, (int? prev, int next) {
      if (_chatListController.hasClients) {
        _chatListController.animateTo(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
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
      // 换号/重连后名单缓存可能已换，允许重新补一次。
      _groupNamesWarmed.clear();
    }

    _resolvedChatId = previewOnly ? null : _resolveSelected(chats);
    if (_resolvedChatId != null && store != null) {
      // 宽屏自动选中的会话也要认领 owner：原实现只有 _openChat 设 owner，
      // 首次自动进入的会话永远不写位置，也就没有记忆（审计第 7 条）。
      if (_scrollOwnerChatId != _resolvedChatId) {
        _beginChatAttempt(_resolvedChatId!);
      }
      if (!_opened.contains(_resolvedChatId)) {
        // 首屏自动选中的会话也要拉历史，否则宽屏下右侧是一片空白。
        unawaited(_ensureOpened(_resolvedChatId!));
      }
      // 群成员名字同样要补：宽屏自动选中不经过 _openChat，漏了这一步就只有
      // 消息自带昵称的人有名字（真机 m06603：「只有 净凾 显示」）。
      _warmGroupNames(chats.firstWhere((c) => c.id == _resolvedChatId));
    }

    // 用 sizeOf 而不是 of：of 订阅整个 MediaQuery（含 viewInsets），
    // 键盘每一帧动画都会把整个主页（列表+消息+头像）重建一遍——
    // 这就是「键盘呼出变卡」的来源。sizeOf 只在窗口尺寸真变时重建。
    final wide = AppBreakpoints.isTablet(MediaQuery.sizeOf(context).width);

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
      // 界面偏好里和列表有关的项（头像圆角/分隔线/时间带秒/未读数缩写）
      // 由宿主传快照：ChatListPanel 是哑视图，不自己 watch Riverpod。
      prefs: ref.watch(uiPrefsProvider),
      controller: _chatListController,
      // 左滑归档 / 右滑静音（TG Android 的滑动动作）。
      onArchiveChat: (chat) async {
        final s = ref.read(chatStoreProvider);
        if (s == null) return;
        await s.setChatArchived(chat.id, true);
        if (mounted) _toast('已归档');
      },
      onToggleMuteChat: (chat) async {
        final s = ref.read(chatStoreProvider);
        if (s == null) return;
        await s.setChatMuted(chat.id, !chat.muted);
        if (mounted) _toast(chat.muted ? '已取消静音' : '已静音');
      },
    );

    // 顶部/左右安全区在**根布局**统一消费一次（缺陷5：竖屏时聊天标题
    // 会和系统状态栏的时间/日期叠在一起）。底部不在这里管——输入栏自己
    // 有 SafeArea(top:false)，两层都加会把底部留白算两遍。
    // 状态栏高度：聊天页的顶栏玻璃要盖到状态栏后面（官方 contentView
    // setOccupyStatusBar(true)，壁纸与模糊整段延伸到状态栏下），但本页在
    // SafeArea 内部、padding 已被抹成 0，所以在外层先取一次真实值传下去。
    final double topInset = MediaQuery.paddingOf(context).top;
    if (wide) {
      // 平板（官方 MainTabsActivity 只占左栏，LaunchActivity.java:949-953）：
      // 左栏 = 当前 tab 的列表页，右栏 = 对话面板且**不随 tab 切换**（换 tab
      // 只换左栏，右栏仍是当前会话 —— 这是官方平板与手机最大的结构差异）。
      return Scaffold(
        backgroundColor: TelegramColors.bgApp,
        body: SafeArea(
          bottom: false,
          child: Row(
            children: [
              SizedBox(
                width: AppBreakpoints.sidebarWidthFor(
                  MediaQuery.sizeOf(context).width,
                ),
                // 宽屏的胶囊 tab 只占左侧栏，左栏内容要让出 72dp（+手势条），
                // 否则最后一条会话会被胶囊压住。
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom:
                        AppBreakpoints.sidebarTabBarReserve +
                        MediaQuery.paddingOf(context).bottom,
                  ),
                  child: _wideLeftPane(wideTab, sidebar),
                ),
              ),
              Container(width: 1, color: TelegramColors.divider),
              Expanded(child: _buildChatPane(chats, store, topInset: topInset)),
            ],
          ),
        ),
      );
    }
    // 窄屏（手机）：列表与对话二选一。
    // 系统返回键：在对话页时先回列表，别直接退出应用（canPop=false 拦下）。
    return PopScope(
      canPop: _showChatList,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _backToChatList();
      },
      child: Scaffold(
        backgroundColor: TelegramColors.bgApp,
        body: SafeArea(
          bottom: false,
          child: AnimatedSwitcher(
            // Telegram 的开页转场：150ms + DecelerateInterpolator(1.5)。
            // 出处 ActionBarLayout.startLayoutAnimation 的非预览分支
            // （duration :1061、decelerateInterpolator :318）；
            // 这两处在 AyuGram 里与 TG 原版逐字相同（TG :1830 / :614），
            // 所以「抄 AyuGram」= 抄 TG 这套参数。
            duration: _kChatSwitchDuration,
            transitionBuilder: _chatSwitchTransition,
            // 两页都是全屏尺寸：用 Stack 叠着做交叉淡入。默认 layoutBuilder
            // 会把新旧子树各自按内容大小居中排，手机上会看到位置跳一下。
            layoutBuilder: (current, previous) =>
                Stack(fit: StackFit.expand, children: [...previous, ?current]),
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
                      onBack: _backToChatList,
                      topInset: topInset,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  /// 列表 ↔ 对话页的转场（Telegram 的 ActionBarLayout 语义）。
  ///
  /// Telegram 里只有「新打开的那一页」参与动画，下层页面完全静止：
  /// - 进入对话：containerView.alpha 0→1、translationX 48dp→0（:1088-1106）；
  /// - 返回列表：同一段代码反向跑，对话页淡出并右移 48dp（:1107-1121）；
  /// - 会话列表在下层一动不动（containerViewBack 只在关闭时动）。
  ///
  /// AnimatedSwitcher 给进入者的 animation 是 0→1、给离开者的是 1→0，
  /// 所以下面这段对两个方向天然对称，不用分支判断方向。
  /// 列表页直接原样返回，就实现了「下层静止」。
  Widget _chatSwitchTransition(Widget child, Animation<double> animation) {
    final key = child.key;
    if (key is! ValueKey<String> || key.value != 'chat-pane') {
      return child;
    }
    // 不用 CurvedAnimation：transitionBuilder 每次 build 都会新建实例，
    // 没有地方 dispose，直接用 drive 链更干净。
    final Animation<double> curved = animation.drive(
      CurveTween(curve: const _Decelerate15()),
    );
    final Animation<double> shift = curved.drive(
      Tween<double>(begin: _kChatSwitchSlide, end: 0),
    );
    return FadeTransition(
      opacity: curved,
      child: AnimatedBuilder(
        animation: shift,
        builder: (_, Widget? inner) =>
            Transform.translate(offset: Offset(shift.value, 0), child: inner),
        child: child,
      ),
    );
  }

  /// 对话页返回列表：同时告诉外壳"对话关了"，底栏重新出现。
  void _backToChatList() {
    _saveScrollAnchor();
    _stopBottomPin();
    setState(() => _showChatList = true);
    widget.onChatPaneVisibilityChanged?.call(false);
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
    showGlassSheet<void>(
      context: context,
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
                          name: chat.title,
                          url: chat.avatarUrl,
                          size: 52,
                        ),
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

  /// 单击气泡：在气泡旁弹出操作菜单（TG 的 popup）。
  ///
  /// 锚点是气泡自己的 RenderBox；万一拿不到（理论上不会）就退回屏幕中心，
  /// 绝不因为定位失败就不弹菜单。
  Future<void> _showMessagePopup(
    BuildContext bubbleCtx,
    ChatMessage m,
    String chatId,
  ) async {
    final store = ref.read(chatStoreProvider);
    final session = ref.read(sessionProvider);
    // 菜单项可见性（设置 → 聊天 → 长按菜单）：用户在偏好里关掉的项不出现。
    final uiPrefs = ref.read(uiPrefsProvider);
    final canRecall =
        m.outgoing &&
        !m.isRecalled &&
        (session?.supports('recall') ?? false) &&
        uiPrefs.menuShowRecall;
    // 戳一戳：对面发的消息才能戳（要拿对方 uin）；后端得承认这个能力。
    final canPoke =
        !m.outgoing &&
        m.senderId.isNotEmpty &&
        (session?.supports('poke') ?? false);

    final box = bubbleCtx.findRenderObject();
    final size = MediaQuery.sizeOf(context);
    // 优先用气泡自己的 box（点击这一刻现算，滚动过也不会飘）；拿不到才退回
    // 外层 Box（整行宽，会把菜单顶到屏幕边），最后才退屏幕中心。
    final bubbleBox = _bubbleBoxes[m.id];
    Rect? bubbleRect;
    if (bubbleBox != null && bubbleBox.attached && bubbleBox.hasSize) {
      bubbleRect = bubbleBox.localToGlobal(Offset.zero) & bubbleBox.size;
    }
    final anchor =
        bubbleRect ??
        (box is RenderBox && box.hasSize
            ? box.localToGlobal(Offset.zero) & box.size
            : Rect.fromLTWH(size.width / 2, size.height / 2, 1, 1));

    await showMessageActionPopup(
      context,
      anchor: anchor,
      outgoing: m.outgoing,
      // 「多选」不作为弹层项：TG 里多选是长按进入的独立模式。
      items: MessageActionsSheet.itemsFor(
        context,
        message: m,
        canRecall: canRecall,
        includeSelect: false,
        includeCopy: uiPrefs.menuShowCopy,
        includeForward: uiPrefs.menuShowForward,
        includeDelete: uiPrefs.menuShowDelete,
        // popup 里不放「取消」：点空白遮罩即可关，TG 也没有这一行。
        includeCancel: false,
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
      ),
    );
  }

  /// 长按气泡 → 进多选并选中这一条（TG 的 action mode，没有菜单过渡）。
  void _enterMessageSelection(ChatMessage m) {
    // TG 单次多选上限 100 条（ActionMode 的常量），超了就提示而不是静默失败。
    if (!_selected.contains(m.id) && _selected.length >= 100) {
      _toast('一次最多选 100 条');
      return;
    }
    unawaited(HapticFeedback.mediumImpact());
    setState(() => _selected.add(m.id));
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
        title: Text(
          '删除这 $n 条消息？',
          style: TextStyle(color: TelegramColors.textPrimary),
        ),
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
        title: Text(
          '删除这条消息？',
          style: TextStyle(color: TelegramColors.textPrimary),
        ),
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

    final name = (seg.name ?? '').trim().isEmpty
        ? 'file-$fid'
        : seg.name!.trim();
    messenger.showSnackBar(SnackBar(content: Text('开始下载：$name…')));
    try {
      final bytes = await svc.downloadFile(fid: fid);
      final dir = Directory(
        '${store.dataDir.path}${Platform.pathSeparator}downloads',
      );
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final out = File(
        '${dir.path}${Platform.pathSeparator}${_safeFileName(name)}',
      );
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
          fontWeight: FontWeight.w600,
        ),
      ),
      items: <ActionSheetItem>[
        ActionSheetItem(
          key: const ValueKey('member-menu-mute'),
          icon: Icons.volume_off_rounded,
          label: '禁言 10 分钟',
          onTap: () => choice = 'mute',
        ),
        ActionSheetItem(
          key: const ValueKey('member-menu-unmute'),
          icon: Icons.volume_up_rounded,
          label: '解除禁言',
          onTap: () => choice = 'unmute',
        ),
        if (!isOwner)
          ActionSheetItem(
            key: const ValueKey('member-menu-admin'),
            icon: Icons.shield_rounded,
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
            gid: gid,
            uid: m.uin,
            enable: !m.admin,
          );
          _toast(
            r.ok
                ? (m.admin ? '已取消管理员' : '已设为管理员')
                : '操作未确认：${r.message ?? r.code}',
          );
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
            '拉群文件失败：${page.message ?? '服务端返回 ${page.code}'}',
          );
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
          '${store.dataDir.path}${Platform.pathSeparator}downloads',
        );
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final out = File(
          '${dir.path}${Platform.pathSeparator}${_safeFileName(link.name)}',
        );
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
          throw SessionException('建文件夹失败：${r.message ?? '服务端返回 ${r.code}'}');
        }
      },
      onRename: (Qq8GfsEntry entry, String name) async {
        final svc = ref.read(qq8LoginServiceProvider);
        if (!svc.isOnline) {
          throw const SessionException('改名要协议线在线');
        }
        final r = await svc.renameGroupEntry(
          gid: gid,
          entry: entry,
          name: name,
        );
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
          throw SessionException('删文件失败：${r.message ?? '服务端返回 ${r.code}'}');
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
        title: Text(
          '上传到群文件',
          style: TextStyle(color: TelegramColors.textPrimary),
        ),
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
              onSubmitted: (_) =>
                  Navigator.of(ctx)
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
            onPressed: () =>
                Navigator.of(ctx)
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
            icon: Icon(
              Icons.copy_outlined,
              color: TelegramColors.textSecondary,
            ),
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
        builder: (_) =>
            SearchPage(chats: chats, store: store, onOpenChat: _openChat),
      ),
    );
  }

  /// 长按会话：置顶/免打扰/标为未读/归档/删除会话（全是本地操作）。
  void _showChatActions(Chat chat, ChatStore? store) {
    if (store == null) return;
    ChatActionsSheet.show(
      context,
      chat: chat,
      onTogglePinned: () =>
          unawaited(store.setChatPinned(chat.id, !chat.pinned)),
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
        title: Text(
          '删除会话？',
          style: TextStyle(color: TelegramColors.textPrimary),
        ),
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
            child: Text('删除', style: TextStyle(color: TelegramColors.danger)),
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

  /// 宽屏左栏内容：按 tab 索引选页。官方平板上点 tab 只换左栏
  /// （LaunchActivity.java:949-953 + MainTabsActivity 的 viewPager 只占左栏），
  /// 右栏对话面板保持不动。手机上的四页由 HomeShell 的 HorizontalPager 承载。
  ///
  /// 这里同样用 HorizontalPager（320ms 水平滑动，与主 tab 同一节拍），四页始终
  /// 常驻树中，非当前页只是 Offstage——所以反复切 tab 后联系人/设置页的滚动位置
  /// 等状态不会丢。
  Widget _wideLeftPane(int wideTab, Widget sidebar) {
    return HorizontalPager(
      index: wideTab,
      children: <Widget>[
        sidebar,
        ContactsPage(
          key: const ValueKey<String>('wide-left-contacts'),
          onOpenChats: () => ref.read(wideTabProvider.notifier).state = 0,
        ),
        const SettingsPage(
          key: ValueKey<String>('wide-left-pane-2'),
          embedded: true,
        ),
        MyProfilePage(
          key: const ValueKey<String>('wide-left-profile'),
          onOpenSettings: () => ref.read(wideTabProvider.notifier).state = 2,
        ),
      ],
    );
  }

  Widget _buildChatPane(
    List<Chat> chats,
    ChatStore? store, {
    VoidCallback? onBack,
    double topInset = 0,
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

    // 头部做成**浮层**：官方 ChatActivity 的 ActionBar 就是半透明压在消息
    // 列表上，滚动的消息从它下面穿过并被玻璃模糊。列表用 padding.top 让出
    // 头部高度——正是这个"让位"让顶栏后面有内容可模糊。
    // 顶栏是浮层：官方 ActionBar 是三块悬浮胶囊压在消息列表上
    // （ActionBar.java:2233-2280 dispatchDraw），消息从胶囊下穿过并被玻璃模糊；
    // 列表用 padding.top 让出「胶囊高度 58 + 8dp 间隔」。
    const double headerH = 58.0;
    return Stack(
      children: [
        Positioned.fill(
          child: Stack(
            children: [
              // 壁纸向上溢出一个状态栏高度：官方壁纸是整屏的（状态栏透明
              // 压在壁纸/模糊上），否则状态栏后面永远是 Scaffold 纯色，会和
              // 下面的顶栏玻璃之间显出一条色差带。
              Positioned(
                top: -topInset,
                left: 0,
                right: 0,
                bottom: 0,
                child: ChatWallpaperBackground(
                  wallpaperId: ref.watch(
                    uiPrefsProvider.select((UiPrefs p) => p.wallpaperId),
                  ),
                  child: messages.isEmpty
                      ? _buildMessagesEmpty(store)
                      : NotificationListener<ScrollNotification>(
                          onNotification: _onScrollNotification,
                          child: ListView.builder(
                            key: ValueKey<String>('msglist-${chat.id}'),
                            controller: _scrollController,
                            // 原型开关：反向列表把"最新"放在 offset 0 一端，
                            // 新消息天然长在视野下方，不依赖贴底补偿（默认关）。
                            reverse: _reverseList,
                            padding: EdgeInsets.only(
                              // 让出浮层头部：消息要能滚到玻璃底下去
                              top: headerH + 8,
                              bottom: ChatInputBar.reserve(context) + 8,
                            ),
                            // 行组件无状态：自动 keepalive 只在浪费（TG 的
                            // RecyclerListView 也只对真正带状态的行保活）。
                            addAutomaticKeepAlives: false,
                            // 离屏 400px 预解码窗口：图片进屏前解码已在进行，
                            // 等价于 RecyclerView 的 prefetch。
                            // ignore: deprecated_member_use
                            cacheExtent: 400,
                            itemCount: items.length,
                            itemBuilder: (_, i) {
                              // 反向列表要从尾部取数：序号 0 必须是**最新**那条。
                              final item = _reverseList
                                  ? items[items.length - 1 - i]
                                  : items[i];
                              final day = item.day;
                              if (day != null) {
                                return DateChip(day: day);
                              }
                              if (item.isUnread) {
                                return const UnreadDivider();
                              }
                              final m = item.message!;
                              final checked = _selected.contains(m.id);
                              // 新消息气泡淡入 + 上浮 + 0.9→1 缩放（TG 的 appear 动画）。
                              // 缩放轴心按气泡水平中心，所以按发送方给 alignment：
                              // 我方气泡靠右（轴心也靠右），对方靠左。
                              return BubbleEntrance(
                                key: ValueKey<String>('bubble-${m.id}'),
                                animate: _shouldAnimateBubble(m),
                                alignment: Alignment(
                                  m.outgoing ? 0.6 : -0.6,
                                  0,
                                ),
                                // 自己发的消息走「从输入栏飞上来」那一套
                                // （TextMessageEnterTransition）：位移和缩放
                                // 都比"收到的新消息"大一档。
                                slideBegin: m.outgoing
                                    ? const Offset(0, 0.32)
                                    : const Offset(0, 0.06),
                                scaleBegin: m.outgoing ? 0.72 : 0.9,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    if (_selecting)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          left: 6,
                                          right: 2,
                                          bottom: 12,
                                        ),
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
                                        width:
                                            TelegramMetrics.bubbleAvatarSize +
                                            14,
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
                                                  url:
                                                      int.tryParse(
                                                            m.senderId,
                                                          ) ==
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
                                      // Builder 只为拿到气泡自己的 RenderBox：单击
                                      // 弹菜单要贴着气泡定位（TG 的 popup 锚在气泡
                                      // 边上，不是屏幕正中）。
                                      child: Builder(
                                        builder: (bubbleCtx) => GestureDetector(
                                          // 多选模式里单击 = 勾选/取消勾选；非多选时
                                          // 单击弹气泡旁的操作菜单（TG 的 popup）。
                                          onTap: _selecting
                                              ? () => setState(
                                                  () => _selected.contains(m.id)
                                                      ? _selected.remove(m.id)
                                                      : _selected.add(m.id),
                                                )
                                              : () => _showMessagePopup(
                                                  bubbleCtx,
                                                  m,
                                                  chat.id,
                                                ),
                                          // 长按直接进多选（TG：长按 = 多选，不弹菜单）。
                                          onLongPress: () =>
                                              _enterMessageSelection(m),
                                          // 按住气泡轻微缩小（0.97）：TG 的按下反馈
                                          // 主要靠整行高亮，这里给暗色气泡一点手感。
                                          // PressableScale 用 Listener，不抢上面的
                                          // onTap/onLongPress。
                                          child: PressableScale(
                                            child: MessageBubble(
                                              message: m,
                                              bubbleRadius: ref.watch(
                                                uiPrefsProvider.select(
                                                  (UiPrefs p) => p.bubbleRadius,
                                                ),
                                              ),
                                              localMedia: store?.mediaPathOf,
                                              ensureMedia: store?.ensureMedia,
                                              mediaFailure:
                                                  store?.mediaFailureOf,
                                              retryMedia: store?.retryMedia,
                                              onOpenFile: (seg) => unawaited(
                                                _downloadFileMessage(seg),
                                              ),
                                              onRetry: m.isFailed
                                                  ? () => _retry(m.id)
                                                  : null,
                                              // 私聊不显示发送者名：TG 只有群聊
                                              // 在气泡上方画名字（ChatMessageCell
                                              // 的 namesOffset 由 isChat 决定）。
                                              showSenderName:
                                                  item.showSenderName &&
                                                  chat.type == ChatType.group,
                                              // 分组只管群聊的发送者名，圆角按同一套分组标记收。
                                              firstInGroup: item.showSenderName,
                                              senderLabel: _senderLabelOf(
                                                m,
                                                chat,
                                              ),
                                              onBubbleBox: (b) =>
                                                  _bubbleBoxes[m.id] = b,
                                              onBubbleBoxGone: (b) {
                                                if (identical(
                                                  _bubbleBoxes[m.id],
                                                  b,
                                                )) {
                                                  _bubbleBoxes.remove(m.id);
                                                }
                                              },
                                              showAvatarColumn:
                                                  item.showAvatarSlot,
                                              avatarVisible: item.showAvatar,
                                              highlighted:
                                                  m.atMe || m.replyToId != null,
                                              onReveal: m.isRecalled
                                                  ? () => store?.revealMessage(
                                                      chat.id,
                                                      m.id,
                                                    )
                                                  : null,
                                            ),
                                          ),
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
              ),
              // "跳到最新"：不在底部时浮在右下角（TG/Nagram 的下箭头按钮）
              if (!_atBottom)
                Positioned(
                  right: 14,
                  bottom: ChatInputBar.reserve(context) + 8,
                  child: JumpToLatestButton(
                    key: const ValueKey('jump-to-latest'),
                    unread: chat.unreadCount,
                    onTap: () => _jumpToLatest(chat.id),
                  ),
                ),
              // 输入栏是**浮层**（不占独立横带）：TG 的输入胶囊就是这样压在
              // 消息列表之上、底部渐隐，看起来像飘在聊天背景上。列表底部已按
              // ChatInputBar.overlayHeight 留白，最后一条不会被压住。
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ChatInputBar(
                  enabled: store != null,
                  controller: _inputController,
                  replyTarget: _replyTarget,
                  onSend: _send,
                  onAttachImage: () => unawaited(_pickAndSendImages()),
                  onAttachImagePath: () => unawaited(_sendImageFromPath()),
                  onAttachFile: () => unawaited(_sendFileFromPath()),
                  onOpenFaces: _openFacePicker,
                  onCancelReply: _cancelReply,
                  onVoiceRecorded: _sendVoice,
                ),
              ),
            ],
          ),
        ),
        // 头部内容（文字/图标）浮在玻璃之上
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: AnimatedSwitcher(
            // 普通头 ↔ 多选工具条交叉淡化 150ms：两者同高（56），直接替换
            // 会像屏幕闪了一下；TG 的 ActionMode 出现时也是淡入。
            duration: const Duration(milliseconds: 150),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: KeyedSubtree(
              key: ValueKey<bool>(_selecting),
              child: _buildHeader(chat, onBack),
            ),
          ),
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
                'PenguinChat',
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
          // 未选会话时也要和聊天页一样把输入栏**浮**在壁纸上：之前这里把
          // ChatInputBar 当成 Column 的最后一项（会占掉自己的一段高度、把
          // 壁纸截断），宽屏分栏一进来默认就是"未选会话"，于是平板上看到的是
          // 一条贴在底部、与手机端悬浮输入栏长得不一样的横条——这就是用户
          // m05841 说的"平板没有悬浮底栏"。
          child: Stack(
            children: [
              Positioned.fill(
                child: ChatWallpaperBackground(
                  wallpaperId: ref.watch(
                    uiPrefsProvider.select((UiPrefs p) => p.wallpaperId),
                  ),
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: ChatInputBar.reserve(context) + 8,
                    ),
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
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ChatInputBar(
                  enabled: false,
                  controller: _inputController,
                  onSend: _send,
                  onAttachImage: () => unawaited(_pickAndSendImages()),
                  onAttachImagePath: () => unawaited(_sendImageFromPath()),
                  onAttachFile: () => unawaited(_sendFileFromPath()),
                  onOpenFaces: _openFacePicker,
                  onCancelReply: _cancelReply,
                ),
              ),
            ],
          ),
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
    final uiPrefs = ref.watch(uiPrefsProvider);
    return ChatHeader(
      chat: chat,
      onBack: onBack,
      hideStatus: uiPrefs.hideHeaderStatus,
      centerTitle: uiPrefs.centerTitle,
      onOpenMembers: () => unawaited(_openMembers(chat)),
      onOpenGroupFiles: () => unawaited(_openGroupFiles(chat)),
      onOpenGroupSettings: () => unawaited(_openGroupSettings(chat)),
      onOpenSettings: _openSettings,
      onSearch: _openSearch,
    );
  }
}

/// 会话滚动锚点：一条消息 + 它底边距视口底的距离（像素，可为负 = 被底部截断）。
///
/// 纯视图状态，不值得单开文件；放在页面旁边，测试只通过行为观察它。
@immutable
class _ScrollAnchor {
  const _ScrollAnchor(this.messageId, this.offsetFromBottom);

  /// 锚定的消息 id。消息被删/被过滤时只能放弃精修
  /// （见 _HomePageState._anchorStep 的 tries >= 24 分支）。
  final String messageId;

  /// 这条消息底边到视口底边的像素距离；0 = 正贴着视口底。
  final double offsetFromBottom;
}

/// 列表 ↔ 对话页转场的时长：Telegram 150ms
/// （ActionBarLayout.java :1061 非预览分支 `duration = preview && open ? 190 : 150`）。
const Duration _kChatSwitchDuration = Duration(milliseconds: 150);

/// 开页时从右侧滑入的距离，逻辑像素（= Android 48dp，
/// ActionBarLayout.java :1105 `setTranslationX(dp(48) * (1 - t))`）。
const double _kChatSwitchSlide = 48.0;

/// Android 的 `DecelerateInterpolator(1.5f)`：`1 - (1 - t)^1.5`。
///
/// 不用 Flutter 自带的 [Curves.decelerate]：那是三次贝塞尔近似，尾段
/// 收得比 Telegram 更拖；Telegram 用的是幂函数，直接照抄公式。
class _Decelerate15 extends Curve {
  const _Decelerate15();

  @override
  double transformInternal(double t) => 1 - math.pow(1 - t, 1.5).toDouble();
}

/// 一张待发送图片的最终形态：本地路径 + 压缩后的宽高（给气泡算占位比）。
class _PreparedSend {
  const _PreparedSend({required this.path, this.width, this.height});

  final String path;
  final int? width;
  final int? height;
}
