import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/ui/chat/chat_viewport_state.dart';

void main() {
  test('切换会话翻代次并取消息身份锚点，恢复标志不跨会话残留', () {
    final s = ChatViewportState();
    const anchor = ChatScrollAnchor('message-id', -12.5);
    s.anchors['a'] = anchor;
    s.begin('a');
    final old = s.generation;
    expect(s.pendingRestore, same(anchor));
    s.restoringChatId = 'a';
    s.restoringScroll = true;
    s.begin('b');
    expect(s.generation, old + 1);
    expect(s.ownerChatId, 'b');
    expect(s.pendingRestore, isNull);
    expect(s.restoringChatId, isNull);
    expect(s.restoringScroll, isFalse);
    s.begin('a');
    expect(s.pendingRestore?.messageId, 'message-id');
    expect(s.pendingRestore?.offsetFromBottom, -12.5);
  });
  test('更换数据源废弃所有旧锚点和代次', () {
    final s = ChatViewportState()..begin('same');
    s.anchors['same'] = const ChatScrollAnchor('old-account', 20);
    final old = s.generation;
    s.reset();
    expect(s.generation, greaterThan(old));
    expect(s.ownerChatId, isNull);
    expect(s.anchors, isEmpty);
    s.begin('same');
    expect(s.pendingRestore, isNull);
  });
}
