/// "跳到最新"浮动按钮（TG / Nagram 消息列表右下角那个下箭头）
///
/// [unread] > 0 时右上角挂一个计数徽章——那是"你在翻看旧消息时新进来的条数"，
/// 点一下才清。是否显示、点了做什么由调用方决定（见 `home_page.dart` 的
/// `_onScroll` / `_jumpToLatest`）：这里只是个哑组件，方便单独测。
library;

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';

class JumpToLatestButton extends StatefulWidget {
  /// 未读条数（0 = 不显示徽章）。
  final int unread;

  final VoidCallback onTap;

  const JumpToLatestButton({
    super.key,
    required this.unread,
    required this.onTap,
  });

  @override
  State<JumpToLatestButton> createState() => _JumpToLatestButtonState();
}

class _JumpToLatestButtonState extends State<JumpToLatestButton>
    with SingleTickerProviderStateMixin {
  /// 出现时从 0.8 弹到 1 并淡入（TG 的 chat_go_down 是"淡入 + 轻微放大"，
  /// 不是硬生生蹦出来）。180ms 收得干净，不拖沓。
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..forward();

  late final Animation<double> _curve = CurvedAnimation(
    parent: _enter,
    curve: Curves.easeOutCubic,
  );

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unread = widget.unread;
    return FadeTransition(
      opacity: _curve,
      child: ScaleTransition(
        scale: _curve.drive(Tween<double>(begin: 0.8, end: 1)),
        child: _buildButton(unread),
      ),
    );
  }

  Widget _buildButton(int unread) {
    return Material(
      color: TelegramColors.bgHeader,
      elevation: 3,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: widget.onTap,
        child: SizedBox(
          // TG 的 chat_go_down 按钮直径 dp(46)
          width: 46,
          height: 46,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Icon(
                Icons.keyboard_arrow_down,
                size: 26,
                color: TelegramColors.textSecondary,
              ),
              if (unread > 0)
                Positioned(
                  right: -6,
                  top: -4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: TelegramColors.badge,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: TelegramColors.bgChat,
                        width: 2,
                      ),
                    ),
                    child: Text(
                      '$unread',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
