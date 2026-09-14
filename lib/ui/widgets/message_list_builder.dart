/// L4 表现层：消息列表的"渲染项"整理（日期分隔 + 分组）
///
/// 现行 Telegram 的消息列表有两层整理，都不属于单个气泡：
///
/// 1. **日期分隔**：跨天处插一个"今天/昨天/日期"胶囊；
/// 2. **分组**：同方向 + 同发送者 + 间隔 < 5 分钟 + 同一天 → 同一组；
///    发送者名在**组的第一条**上（贴着气泡左上），头像在**组的最后一条**上
///    （TG 的排法：名字在顶、头像在底，两者都只出现一次）。
///
/// 抽成纯函数（不依赖 provider/widget）是为了能直接测：这类"看起来只是排版"
/// 的规则最容易在改动里悄悄坏掉，而肉眼很难发现。
library;

import '../../client_api/objects.dart';

/// 消息列表的一项：日期分隔 / 未读分隔 / 一条消息（带分组标记）。
class MessageListItem {
  /// 非 null = 这一项是日期分隔。
  final DateTime? day;

  /// 非 null = 这一项是一条消息。
  final ChatMessage? message;

  /// true = 这一项是"未读消息"分隔线（TG/Nagram 的 unread divider）。
  final bool unread;

  /// 是否显示发送者名（同组第一条）。
  final bool showSenderName;

  /// 是否真的画头像（收到的、且是本组最后一条）。
  final bool showAvatar;

  /// 是否为头像留位置（收到的消息都留，保证气泡左边缘对齐）。
  final bool showAvatarSlot;

  const MessageListItem._({
    this.day,
    this.message,
    this.unread = false,
    this.showSenderName = false,
    this.showAvatar = false,
    this.showAvatarSlot = false,
  });

  bool get isDay => day != null;

  bool get isUnread => unread;

  @override
  String toString() => isDay
      ? 'Day(${day!.month}/${day!.day})'
      : isUnread
          ? 'Unread'
          : 'Msg(${message!.id.isNotEmpty ? message!.id : message!.text})'
              '${showSenderName ? ' +name' : ''}${showAvatar ? ' +avatar' : ''}';
}

/// 同一条消息是否与下一条属于同一组（TG 的 5 分钟规则）。
bool sameGroup(ChatMessage a, ChatMessage b) =>
    !a.system &&
    !b.system &&
    a.outgoing == b.outgoing &&
    a.senderId == b.senderId &&
    b.time.difference(a.time).inMinutes.abs() < 5 &&
    a.time.year == b.time.year &&
    a.time.month == b.time.month &&
    a.time.day == b.time.day;

/// 把消息摊成渲染项。[showAvatars] 一般只在群聊里为 true。
///
/// [unreadAnchorId] = **最后一条已读消息**的 ID（`Chat.lastReadId`）。给它就
/// 在那条之后插一条"未读消息"分隔线（TG/Nagram 的 unread divider）：
/// * 分隔线同时**切断分组**——否则会出现"头像在分隔线上面、名字在下面"这种错位；
/// * 锚点不在这一页里（或它就是最后一条）→ 不画，位置不明时宁可没有。
List<MessageListItem> buildMessageItems(
  List<ChatMessage> messages, {
  required bool showAvatars,
  String? unreadAnchorId,
}) {
  var anchorIndex = -1;
  if (unreadAnchorId != null && unreadAnchorId.isNotEmpty) {
    for (var i = 0; i < messages.length - 1; i++) {
      if (messages[i].id == unreadAnchorId) {
        anchorIndex = i;
        break;
      }
    }
  }

  final items = <MessageListItem>[];
  DateTime? lastDay;
  for (var i = 0; i < messages.length; i++) {
    final m = messages[i];
    final day = DateTime(m.time.year, m.time.month, m.time.day);
    if (lastDay == null || day.difference(lastDay).inDays.abs() > 0) {
      items.add(MessageListItem._(day: day));
      lastDay = day;
    }
    final sameAsPrev =
        i > 0 && anchorIndex != i - 1 && sameGroup(messages[i - 1], m);
    final sameAsNext =
        i + 1 < messages.length &&
            anchorIndex != i &&
            sameGroup(m, messages[i + 1]);
    items.add(MessageListItem._(
      message: m,
      showSenderName: !sameAsPrev,
      showAvatar: showAvatars && !m.outgoing && !sameAsNext,
      showAvatarSlot: showAvatars && !m.outgoing,
    ));
    if (i == anchorIndex) items.add(const MessageListItem._(unread: true));
  }
  return items;
}
