/// L3 客户端 API 层：会话契约（内核接缝）
///
/// ## 为什么契约放在 L3 而不是 `lib/kernel/`
///
/// 目标里写的是"在 `lib/kernel/` 下建立可替换的 Session 抽象"。实现时发现
/// 放那里会破坏 `STRUCTURE.md` 里「单向依赖 L4 → L3 → L2 → L1，绝不反向」：
/// 因为 [Session] 的返回类型是 [Chat] / [ChatMessage] / [Segment]，
/// 把契约放进 L2 就等于让 L2 依赖 L3（反向）。
///
/// 放在 L3 则是标准的**依赖倒置**：
///
/// ```
///   L3 定义契约（本文件）           ← 不依赖任何人
///        ▲
///        │ implements
///   L2 实现契约（OneBotSession）     ← 依赖 L3 的契约类型，不依赖 L3 的逻辑
/// ```
///
/// 内核整体可替换（`OneBotSession` / `MsfSession`）而 L4 UI 零改动——这正是
/// 目标里"双内核"要的效果，且不产生反向依赖。
///
/// ## 为什么不采用"内核返回原始 Map、L3 再归一化"
///
/// Icalingua++ 和 Stapxs 都是这个路子（bridge 出原始结构，渲染层再提取）。
/// 对本项目是重复劳动：**字段归一化已经在后端适配表里做完了**
/// （见 `kernel/onebot/backend_profile.dart`），让 L2 直接产出 L3 对象
/// 才是单次转换。
///
/// 本文件是纯 Dart，不依赖 Flutter，可在 `tool/*.dart` 里离线自测。
library;

import 'objects.dart';
import 'segment.dart';

/// 会话状态。
enum SessionState {
  /// 未连接。
  disconnected,

  /// 正在建连 / 握手。
  connecting,

  /// 已连接且后端信息就绪，可收发。
  ready,

  /// 断线重连中。
  reconnecting,

  /// 已主动关闭。
  closed,
}

/// 当前登录账号与后端信息。
class AccountInfo {
  /// 登录的 QQ 号。
  final String uin;

  /// 昵称。
  final String nickname;

  /// 后端上报的 `app_name`（如 `NapCat.Onebot` / `Lagrange.OneBot`）。
  ///
  /// 决定用哪张适配表，也是日志排障的第一手信息。
  final String? backendName;

  final String? backendVersion;
  final String? protocolVersion;

  const AccountInfo({
    required this.uin,
    this.nickname = '',
    this.backendName,
    this.backendVersion,
    this.protocolVersion,
  });

  @override
  String toString() => 'AccountInfo($uin, "$nickname", backend=$backendName)';
}

/// 历史消息翻页游标。
///
/// 各后端分页语义不同（适配表里的 `pager`：`full` / `incremental` / `none`），
/// 因此游标同时保留 `messageId` 与 `seq` 两种定位方式，由实现按后端选择。
class HistoryCursor {
  final String? messageId;

  /// 群消息序号（NapCat 的 `real_seq`）。
  final int? seq;

  /// 时间戳，`pager: none` 的后端只能靠时间过滤。
  final DateTime? time;

  const HistoryCursor({this.messageId, this.seq, this.time});

  @override
  String toString() => 'HistoryCursor($messageId, seq=$seq)';
}

/// 一页历史消息。
class HistoryPage {
  final List<ChatMessage> messages;

  /// 继续往前翻的游标；null 表示没有更多。
  final HistoryCursor? next;

  const HistoryPage(this.messages, {this.next});

  bool get hasMore => next != null;

  static const empty = HistoryPage([]);

  @override
  String toString() => 'HistoryPage(${messages.length} 条, hasMore=$hasMore)';
}

// ---------------------------------------------------------------------------
// 事件
// ---------------------------------------------------------------------------

/// 会话层事件。
sealed class SessionEvent {
  const SessionEvent();
}

/// 状态变化。
class SessionStateChanged extends SessionEvent {
  final SessionState state;
  final String? reason;
  const SessionStateChanged(this.state, {this.reason});
}

/// 收到一条消息（对方的，或自己从别处发的）。
class SessionMessage extends SessionEvent {
  final ChatMessage message;
  const SessionMessage(this.message);

  /// 是否为多端同步（自己在别的客户端发的）。
  bool get isEcho => message.outgoing;
}

/// 消息被撤回。
///
/// **不携带"删除"语义**：上层应把对应消息标记为已撤回而不是移除，
/// 以支持"撤回后仍可查看"。
class SessionMessageRecalled extends SessionEvent {
  final String chatId;
  final String messageId;
  final String? operatorId;
  final DateTime? time;

  const SessionMessageRecalled(
    this.chatId,
    this.messageId, {
    this.operatorId,
    this.time,
  });
}

/// 通知类事件（戳一戳 / 成员变动 / 禁言 / 群文件上传…）。
class SessionNotice extends SessionEvent {
  /// 归一化后的类别：`poke` / `member_increase` / `member_decrease` /
  /// `admin_change` / `ban` / `upload` / `title_change` / `unknown`。
  final String kind;

  final String chatId;
  final String? userId;
  final String? operatorId;
  final Map<String, dynamic> raw;

  const SessionNotice(this.kind, this.chatId, {this.userId, this.operatorId, this.raw = const {}});
}

/// 请求类事件（加好友 / 加群）。
class SessionRequest extends SessionEvent {
  /// `friend` 或 `group`。
  final String kind;

  /// 回应该请求时要用。
  final String flag;

  final String userId;
  final String? chatId;
  final String? comment;

  const SessionRequest(this.kind, this.flag, this.userId, {this.chatId, this.comment});
}

/// 传输层错误。
class SessionFailure extends SessionEvent {
  final Object error;
  final StackTrace? stackTrace;
  const SessionFailure(this.error, [this.stackTrace]);
}

/// 会话层操作失败。
class SessionException implements Exception {
  final String message;
  final Object? cause;
  const SessionException(this.message, {this.cause});

  @override
  String toString() => 'SessionException: $message${cause == null ? '' : ' (cause: $cause)'}';
}

// ---------------------------------------------------------------------------
// 契约
// ---------------------------------------------------------------------------

/// 可替换的内核接缝。
///
/// 实现约定：
///   - [connect] 幂等；握手失败抛 [SessionException]
///   - 所有方法在未 [SessionState.ready] 时快速失败，不挂起
///   - [events] 是广播流，可多订阅
///   - 后端不支持的能力通过 [supports] 显式暴露，而不是抛异常
abstract class Session {
  /// 当前状态。
  SessionState get state;

  /// 事件流。
  Stream<SessionEvent> get events;

  /// 当前账号信息；未握手完成时为 null。
  AccountInfo? get account;

  /// 后端标识（`app_name`），用于选适配表与排障。
  String? get backendName;

  /// 建连并完成握手（探版本 → 选适配表 → 取登录信息）。
  Future<void> connect();

  /// 关闭并释放资源；之后不再自动重连。
  Future<void> close();

  /// 拉取全部会话（好友 + 群）。
  Future<List<Chat>> listChats();

  /// 拉取历史消息，按时间倒序（最新在前）。
  Future<HistoryPage> fetchHistory(
    String chatId, {
    int count = 20,
    HistoryCursor? before,
  });

  /// 发送一条消息，返回服务端的消息 ID（部分后端可能返回 null）。
  Future<String?> sendMessage(String chatId, List<Segment> segments);

  /// 撤回消息。
  Future<void> recall(String chatId, String messageId);

  /// 上报已读。
  Future<void> markRead(String chatId, String messageId);

  /// 戳一戳。
  Future<void> sendPoke(String chatId, String userId);

  /// 查询后端是否具备某项能力（逻辑 API 名，如 `set_message_read`）。
  ///
  /// 各 OneBot 实现的 API 覆盖不同（实测：`set_group_name` 只有 Lagrange 有，
  /// `mark_group_msg_as_read` 只有 NapCat 有），调用方应先问再做。
  bool supports(String capability);

  /// 关闭。
  Future<void> dispose();
}
