/// 判定「一条新收到的消息要不要发系统通知」的纯逻辑。
///
/// 为什么放在 client_api（L3）而不是 ui/：它只依赖普通值，不 import Flutter，
/// 因此可以被 `dart run tool/notify_policy_selftest.dart` 离线覆盖。
/// 界面层只负责"把结论变成一次平台调用"，判断本身留在这里。
library;

/// 不通知的原因。
///
/// 用枚举而不是 bool，是为了日志里能说清"为什么没弹"——
/// "该弹没弹"是这类功能最难查的 bug，只留一个 false 等于把证据扔掉。
enum NotifySkip {
  /// 自己发出的消息。
  outgoing,

  /// 系统提示（入群、撤回、管理员变更…）。
  system,

  /// 会话免打扰。
  muted,

  /// 应用在前台：应用内本来就能看见，再弹一次是打扰。
  appVisible,

  /// 太旧的补拉消息（上线补拉 / 断网补齐 / 首次打开历史）。
  ///
  /// 这一类**必须**挡住：一次补拉会带回几十条历史消息，逐条弹通知
  /// 就是通知轰炸；而它们本来就不是"刚刚发生的事"。
  stale,

  /// 没有可显示的内容。
  empty,
}

/// 判定结果。[skip] 只在 [notify] 为 false 时非 null。
class NotifyDecision {
  const NotifyDecision._(this.notify, this.skip);

  const NotifyDecision.yes() : this._(true, null);

  const NotifyDecision.no(NotifySkip reason) : this._(false, reason);

  final bool notify;
  final NotifySkip? skip;

  @override
  String toString() => notify ? 'notify' : 'skip(${skip!.name})';
}

/// 「实时消息」与「补拉历史」的分界线。
///
/// 实测推送→落盘 < 1 s（见 docs/轮询策略调整-推送为主与群窗口短路-20261031.md §6.4），
/// 5 分钟足以覆盖网络抖动、重连补齐这类"其实刚刚发生"的消息，
/// 同时把上线补拉的几十条旧消息全部挡在外面。
const Duration qq8NotifyMaxAge = Duration(minutes: 5);

/// 一条消息值不值得提醒。
///
/// 判定顺序是有讲究的：先排除"不是别人发给我的"（outgoing / system），
/// 再排除"用户明确不想被打扰"（muted），然后才是可见性与时效性。
/// 这样日志里出现的原因永远是最贴近用户意图的那一个。
NotifyDecision qq8DecideNotify({
  required bool outgoing,
  required bool system,
  required bool muted,
  required bool appForeground,
  required String chatId,
  required String? activeChatId,
  required DateTime messageTime,
  required DateTime now,
  required bool hasContent,
}) {
  if (outgoing) return const NotifyDecision.no(NotifySkip.outgoing);
  if (system) return const NotifyDecision.no(NotifySkip.system);
  if (muted) return const NotifyDecision.no(NotifySkip.muted);
  if (!hasContent) return const NotifyDecision.no(NotifySkip.empty);
  // 前台一律不弹：正在看这个会话当然不该弹；在看别的会话时，官方客户端
  // 也只在会话列表里加未读，不会打断用户。（activeChatId 留作将来做
  // "应用内横幅"时的判据，当前两种前台情形结论相同。）
  if (appForeground) return const NotifyDecision.no(NotifySkip.appVisible);
  final age = now.difference(messageTime);
  // 允许少量时钟偏差（负年龄当 0 处理），超过阈值就是补拉的历史。
  if (age > qq8NotifyMaxAge) return const NotifyDecision.no(NotifySkip.stale);
  return const NotifyDecision.yes();
}

/// 通知正文的纯文本摘要。
///
/// QQ 的文本段里已经包含 `[图片]` / `[表情]` 这类占位，直接透传即可；
/// 空文本兜一句「新消息」，免得弹出一条只有标题的通知。
String qq8NotifyPreview(String text, {int maxChars = 120}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '新消息';
  if (trimmed.length <= maxChars) return trimmed;
  return '${trimmed.substring(0, maxChars)}…';
}

/// 通知标题：群聊带群名 + 发言人，私聊就是对方昵称。
///
/// 群消息如果只显示群名，用户看不出是谁说的；只显示发言人又不知道是哪个群。
String qq8NotifyTitle({
  required String chatTitle,
  required bool isGroup,
  required String senderName,
}) {
  if (!isGroup) return chatTitle.isEmpty ? senderName : chatTitle;
  if (senderName.isEmpty) return chatTitle;
  return '$chatTitle · $senderName';
}
