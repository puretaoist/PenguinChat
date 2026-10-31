/// L4 接线：把「ChatStore 收到新消息」翻译成「一条系统通知」。
///
/// 与 [KeepAliveScope] 同一层、同一个理由：它不需要 BuildContext、不参与布局，
/// 放在 ProviderScope 与 MaterialApp 之间，整个应用只有一个实例。
///
/// `text
///   WidgetsBindingObserver.didChangeAppLifecycleState  ─┐
///   ChatStore.changes (ChatStoreChangeKind.messages)   ─┴→ qq8DecideNotify() → MessageNotifier.notify()
/// `
///
/// 判定逻辑全部在 L3 的 `notify_policy.dart`（纯 Dart、可离线自测），
/// 这里只负责三件事：订阅、取数据、调平台通道。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/chat_store.dart';
import '../../client_api/notify_policy.dart';
import '../../client_api/objects.dart';
import '../../client_api/qq8_login_service.dart';
import '../../client_api/qq8_providers.dart';
import '../../client_api/session_providers.dart';
import '../../infra/log/logger.dart';
import '../platform/message_notifier.dart';
import '../prefs/ui_prefs.dart';

class MessageNotifyScope extends ConsumerStatefulWidget {
  const MessageNotifyScope({super.key, required this.child, this.notifier});

  final Widget child;

  /// 测试时可注入假的平台通道；生产走默认实现。
  final MessageNotifier? notifier;

  @override
  ConsumerState<MessageNotifyScope> createState() => _MessageNotifyScopeState();
}

class _MessageNotifyScopeState extends ConsumerState<MessageNotifyScope>
    with WidgetsBindingObserver {
  late final MessageNotifier _notifier;

  /// 应用是否处于「用户看不见」的状态。判据与 [KeepAliveScope] 保持一致：
  /// 分屏/下拉通知栏只是 inactive，进程还在屏幕上，不该弹通知。
  bool _background = false;

  ChatStore? _store;
  StreamSubscription<ChatStoreChange>? _storeSub;
  StreamSubscription<String>? _openSub;

  /// 已经弹过的消息 ID（同一条被重复合并/回填时不再弹）。
  ///
  /// 有上限：这是一个"去重窗口"，不是审计日志。
  final Set<String> _notified = <String>{};
  static const int _notifiedCapacity = 200;

  @override
  void initState() {
    super.initState();
    _notifier = widget.notifier ?? MessageNotifier();
    _notifier.install();
    WidgetsBinding.instance.addObserver(this);
    _background = _isBackground(WidgetsBinding.instance.lifecycleState);
    _openSub = _notifier.opened.listen(_onOpenRequested);
    // 冷启动点通知：原生只暂存，这里主动取一次（不能指望原生在 Dart 就绪前 invoke）。
    unawaited(_consumePendingOpen());
    // 权限要尽早要：Android 13+ 的弹框只能是用户主动看到应用时弹才合规。
    unawaited(_ensurePermission());
    _attach(ref.read(chatStoreProvider));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_storeSub?.cancel());
    unawaited(_openSub?.cancel());
    unawaited(_notifier.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasBackground = _background;
    _background = _isBackground(state);
    // 回到前台 = 用户已经看到消息列表，常驻通知没有意义，全部撤掉。
    if (wasBackground && !_background) unawaited(_notifier.cancelAll());
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ChatStore?>(chatStoreProvider, (_, next) => _attach(next));
    // 用户把「消息通知」关掉：正在挂着的常驻通知要立刻撤掉，
    // 否则开关看着是关的、通知栏里却还留着几条。
    ref.listen<bool>(
      uiPrefsProvider.select((UiPrefs p) => p.notifications),
      (_, bool enabled) {
        if (!enabled) unawaited(_notifier.cancelAll());
      },
    );
    return widget.child;
  }

  Future<void> _ensurePermission() async {
    final granted = await _notifier.ensurePermission();
    Log.get('Notify').i('通知权限: ${granted ? "已授予" : "未授予（消息仍会收，但不弹通知）"}');
  }

  Future<void> _consumePendingOpen() async {
    final chatId = await _notifier.takePendingChatId();
    if (chatId != null) _onOpenRequested(chatId);
  }

  void _attach(ChatStore? store) {
    if (identical(store, _store)) return;
    unawaited(_storeSub?.cancel());
    _store = store;
    _notified.clear();
    _storeSub = store?.changes.listen(_onStoreChange);
  }

  void _onStoreChange(ChatStoreChange change) {
    if (change.kind != ChatStoreChangeKind.messages) return;
    final chatId = change.chatId;
    final store = _store;
    if (chatId == null || store == null) return;
    // 前台收到消息不弹（应用内本来就能看见），省掉后面所有取数。
    if (!_background) return;
    // 设置里的总开关：关了就不弹（消息照收照落盘，只是不打扰）。
    if (!ref.read(uiPrefsProvider).notifications) {
      Log.get('Notify').d('通知开关已关闭，跳过 chat=$chatId');
      return;
    }

    final messages = store.messagesOf(chatId);
    if (messages.isEmpty) return;
    final message = messages.last;

    if (_notified.contains(message.id)) return;

    final chat = store.chats.where((c) => c.id == chatId).firstOrNull;
    final isGroup = chat?.type == ChatType.group;
    final decision = qq8DecideNotify(
      outgoing: message.outgoing,
      system: message.system,
      muted: chat?.muted ?? false,
      appForeground: !_background,
      chatId: chatId,
      activeChatId: store.activeChatId,
      messageTime: message.time,
      now: DateTime.now(),
      hasContent: message.text.trim().isNotEmpty || message.segments.isNotEmpty,
    );
    if (!decision.notify) {
      // 只记 skipped 的原因，方便真机回答"为什么这条没弹"。
      Log.get('Notify').d('不通知 ${message.id}：${decision.skip?.name}');
      return;
    }

    _notified.add(message.id);
    if (_notified.length > _notifiedCapacity) {
      _notified.remove(_notified.first);
    }
    // 发通知是独立的异步动作：群推送常不带昵称，得现拉群成员名单（最多等 3 秒）。
    // 放在这一层（L4）而不是协议推送路径里——推送路径只负责把消息交出去，
    // 不该顺手发网络请求（那会让每条群消息都多一个包，也会打乱自测的脚本时序）。
    unawaited(_emit(chatId, chat, message, isGroup: isGroup));
  }

  /// 名字只是装饰：服务取不到就当没有，绝不能因此丢掉这条通知。
  Qq8LoginService? _namesService() {
    try {
      return ref.read(qq8LoginServiceProvider);
    } catch (_) {
      return null;
    }
  }

  /// 显示名要按会话上下文取：群消息查该群群名片，私聊查好友备注。
  String _resolveSenderLabel(ChatMessage message, Chat? chat) {
    final raw = message.senderName;
    final numeric = raw.isNotEmpty && RegExp(r'^\d+$').hasMatch(raw);
    final uin = int.tryParse(message.senderId);
    final gid = chat?.rawId;
    final svc = _namesService();
    // 缓存优先（备注 / 本群群名片），其次才是消息里的昵称。
    if (uin != null && svc != null) {
      final name = (chat?.type == ChatType.group && gid != null)
          ? svc.groupMemberNameOf(gid, uin)
          : svc.displayNameOf(uin);
      if (name != null) return name;
    }
    if (raw.isNotEmpty && !numeric) return raw;
    // 解析不出来就留空（原生会退成会话名/「群成员」），绝不显示号码。
    return '';
  }

  Future<void> _emit(
    String chatId,
    Chat? chat,
    ChatMessage message, {
    required bool isGroup,
  }) async {
    final gid = chat?.rawId;
    final raw = message.senderName;
    final needName =
        isGroup && gid != null && (raw.isEmpty || RegExp(r'^\d+$').hasMatch(raw));
    if (needName) {
      final svc = _namesService();
      if (svc != null) {
        try {
          // 限流在服务层（同群 10 分钟一次），这里只加个上限别把通知拖太久。
          await svc.ensureGroupNames(gid).timeout(const Duration(seconds: 3));
        } catch (_) {
          // 名字拿不到不影响通知本身。
        }
      }
    }
    final senderName = _resolveSenderLabel(message, chat);
    final title = qq8NotifyTitle(
      chatTitle: chat?.title ?? '',
      isGroup: isGroup,
      senderName: senderName,
    );
    final body = qq8NotifyPreview(message.text);
    Log.get('Notify').i('弹通知 chat=$chatId title=$title');
    await _notifier.notify(
      chatId: chatId,
      title: (chat != null && chat.title.isNotEmpty) ? chat.title : title,
      text: body,
      sender: senderName,
      isGroup: isGroup,
      timeMs: message.time.millisecondsSinceEpoch,
    );
  }

  /// 用户点了通知：记下要打开的会话，由 HomePage 消费（它才是持有选中态的地方）。
  void _onOpenRequested(String chatId) {
    Log.get('Notify').i('用户点击通知 → 打开会话 $chatId');
    ref.read(pendingOpenChatProvider.notifier).state = chatId;
  }

  static bool _isBackground(AppLifecycleState? state) => switch (state) {
        AppLifecycleState.paused ||
        AppLifecycleState.hidden ||
        AppLifecycleState.detached =>
          true,
        _ => false,
      };
}
