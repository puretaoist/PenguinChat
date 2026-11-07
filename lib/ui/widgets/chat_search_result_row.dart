/// 会话内搜索的结果行——官方 `ui/Adapters/MessagesSearchAdapter.java` 那套紧凑行。
///
/// 为什么不用气泡：官方这里根本不画气泡，是固定 48dp 的列表行，一屏能看八条；
/// 用 `MessageBubble` 渲染的话长消息能撑到 200dp 以上，翻起来很难受。
///
/// 几何（`MessagesSearchAdapter.java`）：
/// * 行高 **48** —— `onMeasure` 里 `MeasureSpec.makeMeasureSpec(dp(48), EXACTLY)`（`:364`）
/// * 头像区 **75×48**、头像 **22**（`:336-339` `avatarsDrawable.setSize(dp(22))`）
/// * 标题 **14dp**、`createFrame(..., TOP, 76, 7, 40, 0)`（`:345-347`）
/// * 副标题 **12dp**、`createFrame(..., TOP, 76, 26.33, 40, 0)`（`:351-353`）
/// * 右侧箭头 **24×24**、`CENTER_VERTICAL|RIGHT`、right **8.66**（`:359`）
///
/// 进出视口时文字往左滑 **62dp** 并淡出（`:424-460`
/// `setTranslationX(lerp(0, -dp(62), transitValue))`），[cut] 就是那个
/// `transitValue`：0 = 完整可见，1 = 完全被裁掉。头像不参与这个位移。
library;

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';
import 'telegram_avatar.dart';

class ChatSearchResultRow extends StatelessWidget {
  const ChatSearchResultRow({
    super.key,
    required this.senderName,
    required this.text,
    required this.cut,
    this.onTap,
    this.showAvatar = true,
  });

  /// 行高：`MessagesSearchAdapter.java:364` 的 `dp(48)`。
  static const double height = 48;

  final String senderName;
  final String text;

  /// 被视口裁掉的比例，0..1。
  final double cut;

  final VoidCallback? onTap;

  /// 私聊里没有发送者名要区分时可以关掉头像。
  final bool showAvatar;

  /// 文字滑出距离：`MessagesSearchAdapter.java:424` 的 `dp(62)`。
  static const double _slide = 62;

  @override
  Widget build(BuildContext context) {
    final double t = cut.clamp(0.0, 1.0);
    final Widget textBlock = Transform.translate(
      offset: Offset(-_slide * t, 0),
      child: Opacity(opacity: 1 - t, child: _texts()),
    );

    return SizedBox(
      height: height,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            children: <Widget>[
              // 头像区 75×48，头像本身 22。
              if (showAvatar)
                Positioned(
                  left: 0,
                  top: 0,
                  width: 75,
                  height: height,
                  child: Center(
                    // 官方这里是圆形头像（直径 22），
                    // `TelegramAvatar` 的 corners 默认 30 就是正圆。
                    child: TelegramAvatar(name: senderName, size: 22),
                  ),
                ),
              Positioned.fill(
                child: Padding(
                  // 左 76 / 右 40 是文字区，扣掉头像区后不再叠 padding。
                  padding: const EdgeInsets.only(left: 76, right: 40),
                  child: textBlock,
                ),
              ),
              // 右侧箭头 24×24、右 8.66（`:359`）。
              Positioned(
                right: 8.66,
                top: 0,
                bottom: 0,
                width: 24,
                child: Icon(
                  Icons.chevron_right,
                  size: 24,
                  color: TelegramColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _texts() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 标题 top 7（`:345`）。用高度占位而不是绝对定位，
        // 让 48 高的行里两行文字自然排在 7 / 26.33 的位置
        // （14sp 那行约 19.6 高，7 + 19.6 ≈ 26.6）。
        const SizedBox(height: 6.5),
        Text(
          senderName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: TelegramColors.textPrimary, fontSize: 14),
        ),
        Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: TelegramColors.textSecondary, fontSize: 12),
        ),
      ],
    );
  }
}
