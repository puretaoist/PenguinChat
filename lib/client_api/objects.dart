/// L3 客户端 API 层数据对象
///
/// 对标 TDLib 的 `td_api` 类型系统：UI 层只与这些对象交互，不感知协议细节。
///
/// ## 分层约束
///
/// 本文件**刻意不依赖 Flutter**（原先为了 `@immutable` 引入了
/// `package:flutter/foundation.dart`，已移除）。原因有两条：
///
///   1. L3 是"稳定高层抽象"，让它绑死 UI 框架会破坏 `STRUCTURE.md` 里
///      「UI 与协议解耦」的约束；
///   2. 纯 Dart 才能在 `tool/*.dart` 里离线自测——本环境的 `flutter.bat`
///      会卡在 SDK 引导检查，`flutter test` 目前不可用。
///
/// 不可变性靠 `final` 字段 + `copyWith` 保证，不依赖注解。
library;

import 'segment.dart';

/// 会话类型。
enum ChatType {
  /// 好友私聊。
  private,

  /// 群聊。
  group;

  static ChatType parse(String? raw) => raw == 'group' ? ChatType.group : ChatType.private;

  String get wireName => name;
}

/// 自己发出的消息的送达状态。
///
/// 存在的理由是**乐观插入**：消息发出即渲染，不等服务端回包
/// （Telegram 的做法）。于是同一条消息在 UI 上会经历三种形态，
/// 而"发送失败但文本必须保留可重试"这条要求需要一个显式状态位来表达，
/// 靠"消息在不在列表里"是表达不出来的。
///
/// 收到的消息一律是 [sent]。
enum MessageSendState {
  /// 已插入本地列表，等待服务端回 message_id。
  sending,

  /// 服务端已接受。
  sent,

  /// 发送失败：文本保留，UI 应给出重试入口，**不得静默丢弃**。
  failed,
}

/// 一个会话（好友或群）。
class Chat {
  /// 复合 ID：`group_123456` / `private_10001`。
  ///
  /// 用复合 ID 而不是裸数字，是因为 OneBot 里 `user_id` 与 `group_id` 是
  /// 两个独立命名空间，裸数字会在私聊和群聊之间撞号。
  final String id;

  /// 显示名（群名 / 好友昵称 / 备注）。
  final String title;

  /// 最近一条消息的文本摘要。
  final String lastMessage;

  /// 最近消息时间。
  final DateTime? lastTime;

  /// 未读数。
  final int unreadCount;

  /// 是否在线（仅私聊有意义）。
  final bool online;

  /// 会话类型。
  final ChatType type;

  /// 裸 ID（群号或 QQ 号），调 OneBot API 时用。
  final int? rawId;

  /// 群成员数（私聊为 0）。
  final int memberCount;

  /// 群主 uin（私聊为 0；成员列表里判"群主"要用它比）。
  final int ownerUin;

  /// 置顶。
  final bool pinned;

  /// 免打扰。
  final bool muted;

  /// 归档（TG/Nagram 的 Archived chats）：列表里收起来，入口在列表顶部。
  final bool archived;

  /// 草稿：没发出去的输入框内容（换会话/重启都还在）。
  final String draft;

  /// 手动"标为未读"（TG 的 Mark as unread）。
  ///
  /// 为什么需要单独一个标志：会话正开着且列表停在底部时，"在底部 = 已读"的
  /// 自动逻辑会把刚标上的未读立刻清掉。这个标志让标记**撑到下次打开会话**为止。
  final bool manualUnread;

  /// 最后一条**已读**消息的 ID（TG 的 `read_inbox_max_id` 在我们这里的等价物）。
  ///
  /// 只用来画"未读消息"分隔线：列表里这条消息之后的都算新的。为 null 表示
  /// 还没读过（或历史数据没有这个字段）——那就**不画**分隔线，别瞎猜位置。
  final String? lastReadId;

  /// 优先级，1（最高）~ 5（最低）。
  ///
  /// 对齐参考实现 Icalingua++ 的 `setRoomPriority(roomId, 1|2|3|4|5)`——
  /// 它把优先级直接放在 Adapter 契约里，说明这是日用刚需而不是锦上添花。
  final int priority;

  const Chat({
    required this.id,
    required this.title,
    this.lastMessage = '',
    this.lastTime,
    this.unreadCount = 0,
    this.online = false,
    this.type = ChatType.private,
    this.rawId,
    this.memberCount = 0,
    this.ownerUin = 0,
    this.pinned = false,
    this.muted = false,
    this.archived = false,
    this.draft = '',
    this.manualUnread = false,
    this.lastReadId,
    this.priority = 3,
  });

  /// 由类型 + 裸 ID 构造复合 ID。
  static String keyOf(ChatType type, int id) =>
      type == ChatType.group ? 'group_$id' : 'private_$id';

  /// 从复合 ID 反解出类型与裸 ID；不合法返回 null。
  static ({ChatType type, int? id})? parseKey(String key) {
    final idx = key.indexOf('_');
    if (idx <= 0) return null;
    final prefix = key.substring(0, idx);
    final rest = key.substring(idx + 1);
    final type = switch (prefix) {
      'group' => ChatType.group,
      'private' => ChatType.private,
      _ => null,
    };
    if (type == null) return null;
    return (type: type, id: int.tryParse(rest));
  }

  /// 是否为群会话。
  bool get isGroup => type == ChatType.group;

  Chat copyWith({
    String? id,
    String? title,
    String? lastMessage,
    DateTime? lastTime,
    int? unreadCount,
    bool? online,
    ChatType? type,
    int? rawId,
    int? memberCount,
    bool? pinned,
    bool? muted,
    bool? archived,
    String? draft,
    bool? manualUnread,
    String? lastReadId,
    int? priority,
  }) =>
      Chat(
        id: id ?? this.id,
        title: title ?? this.title,
        lastMessage: lastMessage ?? this.lastMessage,
        lastTime: lastTime ?? this.lastTime,
        unreadCount: unreadCount ?? this.unreadCount,
        online: online ?? this.online,
        type: type ?? this.type,
        rawId: rawId ?? this.rawId,
        memberCount: memberCount ?? this.memberCount,
        pinned: pinned ?? this.pinned,
        muted: muted ?? this.muted,
        archived: archived ?? this.archived,
        draft: draft ?? this.draft,
        manualUnread: manualUnread ?? this.manualUnread,
        lastReadId: lastReadId ?? this.lastReadId,
        priority: priority ?? this.priority,
      );

  /// 清掉列表摘要（消息被删光时用）。
  ///
  /// 单独一个方法而不是 `copyWith(lastTime: null)`：`copyWith` 的 `??` 语义
  /// 没法把字段置回 null，这里显式重建一次，字段一个不漏。
  Chat clearedPreview() => Chat(
        id: id,
        title: title,
        type: type,
        rawId: rawId,
        memberCount: memberCount,
        ownerUin: ownerUin,
        pinned: pinned,
        muted: muted,
        archived: archived,
        draft: draft,
        manualUnread: manualUnread,
        lastReadId: lastReadId,
        priority: priority,
        unreadCount: unreadCount,
        online: online,
      );

  @override
  String toString() => 'Chat($id, "$title", unread=$unreadCount)';
}

/// 一条消息。
///
/// ## 关于 `text` 与 `segments` 的关系
///
/// `segments` 是**权威数据**，`text` 是它的**纯文本派生摘要**，供三处使用：
///   - 会话列表的 `Chat.lastMessage` 预览
///   - 存储层的全文检索字段（对应 Icalingua++ 独立 FTS5 库里存的内容）
///   - 通知栏文案
///
/// 用 [ChatMessage.fromSegments] 构造会自动派生；直接传 `text` 则两者独立
/// （历史数据、系统消息等场景需要）。
class ChatMessage {
  /// 消息 ID（OneBot 的 `message_id` 字符串化）。
  final String id;

  /// 纯文本摘要。
  final String text;

  /// 结构化消息体。
  final List<Segment> segments;

  final DateTime time;

  /// 是否自己发出。
  final bool outgoing;

  /// 发送者显示名（群聊里 card 优先，回落 nickname）。
  final String senderName;

  /// 发送者 QQ 号（字符串，避免大数精度问题）。
  final String senderId;

  /// 所属会话的复合 ID。
  final String chatId;

  /// 被回复消息的 ID。
  final String? replyToId;

  /// 被回复消息的摘要（用于气泡里显示引用条）。
  final String? replyPreview;

  /// 已撤回。
  ///
  /// 注意：撤回在 OneBot 侧是**打补丁**而不是删除事件（参考 Icalingua++ 的
  /// `renewMessage({deleted:true, reveal:false, recallInfo})`），所以本对象
  /// 保留原位、只置标记，不从列表里移除——这才能支持"撤回后仍可见"。
  final bool deleted;

  /// 撤回附加信息（原始 JSON 字符串，含 `time` / `operator_id`）。
  final String? recallInfo;

  /// 撤回后是否已揭示内容（用户主动点开）。
  final bool revealed;

  /// 是否 @ 了我或 @ 全体。
  final bool atMe;

  /// 是否系统消息（入群提示、撤回提示等）。
  final bool system;

  /// 群头衔 / 发送者角色标记。
  final String? senderTitle;

  /// 送达状态，只对自己发出的消息有意义（收到的恒为 [MessageSendState.sent]）。
  final MessageSendState sendState;

  const ChatMessage({
    required this.id,
    this.text = '',
    this.segments = const [],
    required this.time,
    this.outgoing = false,
    this.senderName = '',
    this.senderId = '',
    this.chatId = '',
    this.replyToId,
    this.replyPreview,
    this.deleted = false,
    this.recallInfo,
    this.revealed = false,
    this.atMe = false,
    this.system = false,
    this.senderTitle,
    this.sendState = MessageSendState.sent,
  });

  /// 从消息段构造，自动派生 [text] 摘要与 [atMe]。
  factory ChatMessage.fromSegments({
    required String id,
    required List<Segment> segments,
    required DateTime time,
    bool outgoing = false,
    String senderName = '',
    String senderId = '',
    String chatId = '',
    String selfId = '',
    bool deleted = false,
    String? recallInfo,
    bool revealed = false,
    bool system = false,
    String? senderTitle,
    String? replyToId,
    String? replyPreview,
    MessageSendState sendState = MessageSendState.sent,
  }) {
    // 回复段既可以放在段数组里，也可以单独传参，这里统一
    var replyId = replyToId;
    var replyText = replyPreview;
    if (replyId == null) {
      for (final s in segments) {
        if (s is ReplySegment) {
          replyId = s.messageId;
          replyText = s.text;
          break;
        }
      }
    }
    return ChatMessage(
      id: id,
      text: Segment.plainText(segments),
      segments: segments,
      time: time,
      outgoing: outgoing,
      senderName: senderName,
      senderId: senderId,
      chatId: chatId,
      replyToId: replyId,
      replyPreview: replyText,
      deleted: deleted,
      recallInfo: recallInfo,
      revealed: revealed,
      atMe: selfId.isNotEmpty && Segment.mentions(segments, selfId: selfId),
      system: system,
      senderTitle: senderTitle,
      sendState: sendState,
    );
  }

  /// 已撤回且尚未揭示 → UI 应显示"消息已撤回"。
  bool get isRecalled => deleted && !revealed;

  /// 还在等服务端回包。
  bool get isSending => sendState == MessageSendState.sending;

  /// 发送失败，UI 应给出重试入口。
  bool get isFailed => sendState == MessageSendState.failed;

  /// 气泡里实际该显示的文本。
  String get displayText => isRecalled ? '[消息已撤回]' : text;

  /// 是否含媒体（决定是否需要走 BlobStore 预取）。
  bool get hasMedia => segments.any((s) => s.hasMedia);

  /// 标记为已撤回。
  ChatMessage recalled({String? recallInfo}) => copyWith(
        deleted: true,
        revealed: false,
        recallInfo: recallInfo ?? this.recallInfo,
      );

  /// 揭示已撤回消息的内容。
  ChatMessage reveal() => copyWith(revealed: true);

  /// 更新纯文本摘要（后端补发或本地重算时用）。
  ChatMessage withDerivedText() =>
      copyWith(text: Segment.plainText(segments));

  ChatMessage copyWith({
    String? id,
    String? text,
    List<Segment>? segments,
    DateTime? time,
    bool? outgoing,
    String? senderName,
    String? senderId,
    String? chatId,
    String? replyToId,
    String? replyPreview,
    bool? deleted,
    String? recallInfo,
    bool? revealed,
    bool? atMe,
    bool? system,
    String? senderTitle,
    MessageSendState? sendState,
  }) =>
      ChatMessage(
        id: id ?? this.id,
        text: text ?? this.text,
        segments: segments ?? this.segments,
        time: time ?? this.time,
        outgoing: outgoing ?? this.outgoing,
        senderName: senderName ?? this.senderName,
        senderId: senderId ?? this.senderId,
        chatId: chatId ?? this.chatId,
        replyToId: replyToId ?? this.replyToId,
        replyPreview: replyPreview ?? this.replyPreview,
        deleted: deleted ?? this.deleted,
        recallInfo: recallInfo ?? this.recallInfo,
        revealed: revealed ?? this.revealed,
        atMe: atMe ?? this.atMe,
        system: system ?? this.system,
        senderTitle: senderTitle ?? this.senderTitle,
        sendState: sendState ?? this.sendState,
      );

  @override
  String toString() =>
      'ChatMessage($id, ${outgoing ? 'out' : 'in'}, "$displayText"'
      '${isRecalled ? ' [recalled]' : ''}${isFailed ? ' [failed]' : ''})';
}

/// 好友 / 群成员信息。
class ChatMember {
  final String id;
  final String nickname;
  final String? card;

  /// 群内显示名：card 优先。
  final String? title;
  final String role;
  final DateTime? joinTime;

  const ChatMember({
    required this.id,
    this.nickname = '',
    this.card,
    this.title,
    this.role = 'member',
    this.joinTime,
  });

  String get displayName => (card != null && card!.isNotEmpty) ? card! : nickname;

  bool get isAdmin => role == 'admin' || role == 'owner';

  @override
  String toString() => 'ChatMember($id, $displayName)';
}
