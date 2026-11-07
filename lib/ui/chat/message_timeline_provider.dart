import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/session_providers.dart';
import '../widgets/message_list_builder.dart';

/// 与 TG adapter 的行模型职责对应：只依赖消息快照和列表分隔参数，
/// 不依赖键盘、滚动或主题。autoDispose 随会话视图释放派生缓存。
final messageTimelineProvider = Provider.autoDispose
    .family<
      List<MessageListItem>,
      ({String chatId, bool showAvatars, String? unreadAnchorId})
    >((ref, key) {
      final messages =
          ref.watch(messagesProvider(key.chatId)).valueOrNull ?? const [];
      return List.unmodifiable(
        buildMessageItems(
          messages,
          showAvatars: key.showAvatars,
          unreadAnchorId: key.unreadAnchorId,
        ),
      );
    });
