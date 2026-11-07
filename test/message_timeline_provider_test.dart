import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/client_api/objects.dart';
import 'package:penguinchat/client_api/segment.dart';
import 'package:penguinchat/client_api/session_providers.dart';
import 'package:penguinchat/ui/chat/message_timeline_provider.dart';

void main() {
  test('派生行模型复用缓存，分隔参数改变时独立计算且不可修改', () async {
    final t = DateTime(2026, 11, 6);
    final messages = List.generate(
      2,
      (i) => ChatMessage(
        id: '$i',
        chatId: 'a',
        text: '消息',
        segments: [TextSegment('消息')],
        time: t,
        outgoing: false,
        senderId: 'sender',
        senderName: '名字',
      ),
    );
    final container = ProviderContainer(
      overrides: [
        messagesProvider('a').overrideWith((ref) => Stream.value(messages)),
      ],
    );
    addTearDown(container.dispose);
    final provider = messageTimelineProvider((
      chatId: 'a',
      showAvatars: true,
      unreadAnchorId: null,
    ));
    final sub = container.listen(provider, (_, next) {});
    addTearDown(sub.close);
    await container.read(messagesProvider('a').future);
    final first = container.read(provider);
    expect(identical(first, container.read(provider)), isTrue);
    expect(first.where((i) => i.message != null).map((i) => i.lastInGroup), [
      false,
      true,
    ]);
    expect(() => first.clear(), throwsUnsupportedError);
    final divided = container.read(
      messageTimelineProvider((
        chatId: 'a',
        showAvatars: true,
        unreadAnchorId: '0',
      )),
    );
    expect(divided.where((i) => i.isUnread).length, 1);
    expect(
      divided.where((i) => i.message != null).every((i) => i.lastInGroup),
      isTrue,
    );
  });
}
