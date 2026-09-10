/// 客户端 API 层数据对象
///
/// 对标 TDLib 的 td_api 类型系统：UI 层只与这些对象交互，不感知协议细节。
/// M4 完成后由 kernel 层填充真实数据。
library;

import 'package:flutter/foundation.dart';

@immutable
class Chat {
  final String id;
  final String title;
  final String lastMessage;
  final DateTime? lastTime;
  final int unreadCount;
  final bool online;

  const Chat({
    required this.id,
    required this.title,
    this.lastMessage = '',
    this.lastTime,
    this.unreadCount = 0,
    this.online = false,
  });
}

@immutable
class ChatMessage {
  final String id;
  final String text;
  final DateTime time;
  final bool outgoing;
  final String senderName;

  const ChatMessage({
    required this.id,
    required this.text,
    required this.time,
    required this.outgoing,
    this.senderName = '',
  });
}
