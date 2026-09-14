/// "跳到最新"浮动按钮（TG / Nagram 消息列表右下角那个下箭头）
///
/// [unread] > 0 时右上角挂一个计数徽章——那是"你在翻看旧消息时新进来的条数"，
/// 点一下才清。是否显示、点了做什么由调用方决定（见 `home_page.dart` 的
/// `_onScroll` / `_jumpToLatest`）：这里只是个哑组件，方便单独测。
library;

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';

class JumpToLatestButton extends StatelessWidget {
  /// 未读条数（0 = 不显示徽章）。
  final int unread;

  final VoidCallback onTap;

  const JumpToLatestButton({
    super.key,
    required this.unread,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: TelegramColors.bgHeader,
      elevation: 3,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
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
                      border: Border.all(color: TelegramColors.bgChat, width: 2),
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
