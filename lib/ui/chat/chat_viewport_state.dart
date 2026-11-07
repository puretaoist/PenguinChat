/// TG 的“消息身份+相对视口偏移”锚点，不与某次列表像素长度绑定。
class ChatScrollAnchor {
  const ChatScrollAnchor(this.messageId, this.offsetFromBottom);
  final String messageId;
  final double offsetFromBottom;
}

/// 只管理会话归属、代次和定位记忆；RenderBox测量与jumpTo仍由视图执行。
/// 不持有ChatStore，数据源变化由宿主显式reset，避免位置跨账号复用。
class ChatViewportState {
  final Map<String, ChatScrollAnchor> anchors = {};
  String? ownerChatId;
  int generation = 0;
  String? restoringChatId;
  ChatScrollAnchor? pendingRestore;
  bool restoringScroll = false;

  void begin(String chatId) {
    generation++;
    ownerChatId = chatId;
    pendingRestore = anchors[chatId];
    restoringChatId = null;
    restoringScroll = false;
  }

  void reset() {
    generation++;
    ownerChatId = null;
    anchors.clear();
    pendingRestore = null;
    restoringChatId = null;
    restoringScroll = false;
  }
}
