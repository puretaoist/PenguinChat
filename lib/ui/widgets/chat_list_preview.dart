import 'package:flutter/material.dart';

import '../prefs/ui_prefs.dart';
import '../theme/telegram_theme.dart';
import 'message_bubble.dart' show formatTime;
import 'telegram_avatar.dart';

/// 设置页里的「聊天列表」实时预览条。
///
/// 抄 exteraGram 的 `ChatListPreviewCell` / `AvatarCornersPreviewCell`
/// （TMessagesProj/src/main/java/com/exteragram/messenger/…）：设置页当场画
/// 一条真实会话行，拖动滑块或拨开关时立刻重绘——用户不用返回列表去确认
/// 「圆角 30 到底多圆」「关掉分隔线长什么样」。
///
/// 纯展示组件，不读 Riverpod：宿主把当前 [prefs] 快照传进来。
class ChatListPreview extends StatelessWidget {
  const ChatListPreview({super.key, this.prefs = const UiPrefs()});

  final UiPrefs prefs;

  /// 样例时间固定成 10:42:07，开「时间带秒」时能看到 :07 出现。
  static final DateTime _sampleTime = DateTime(2026, 1, 1, 10, 42, 7);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: TelegramColors.bgSidebar,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _row(
                title: 'Alice',
                preview: '晚点一起吃饭？',
                unread: 1234,
                online: true,
              ),
              if (!prefs.disableDividers)
                Container(
                  height: 1,
                  margin: const EdgeInsets.only(left: 72),
                  color: TelegramColors.divider,
                ),
              _row(title: 'Bob', preview: '收到，明天见', unread: 0, online: false),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row({
    required String title,
    required String preview,
    required int unread,
    required bool online,
  }) {
    return SizedBox(
      height: TelegramMetrics.chatRowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: TelegramMetrics.chatRowPadding,
          vertical: 9,
        ),
        child: Row(
          children: [
            SizedBox(
              width: TelegramMetrics.avatarSize,
              height: TelegramMetrics.avatarSize,
              child: Stack(
                children: [
                  TelegramAvatar(
                    name: title,
                    size: TelegramMetrics.avatarSize,
                    corners: prefs.avatarCorners,
                  ),
                  if (online)
                    Positioned(
                      right: 1,
                      bottom: 1,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: TelegramColors.online,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: TelegramColors.bgSidebar,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: TelegramMetrics.chatAvatarGap),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: TelegramColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      color: TelegramColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatTime(_sampleTime, withSeconds: prefs.timeWithSeconds),
                  style: TextStyle(
                    fontSize: 12,
                    color: TelegramColors.textMuted,
                  ),
                ),
                const SizedBox(height: 6),
                if (unread > 0)
                  Container(
                    height: 22,
                    constraints: const BoxConstraints(minWidth: 22),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: TelegramColors.accent,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Text(
                      formatUnreadCount(
                        unread,
                        noRounding: prefs.disableNumberRounding,
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
