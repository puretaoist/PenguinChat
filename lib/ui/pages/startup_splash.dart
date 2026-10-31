/// 冷启动品牌页（纯展示，不碰任何 provider —— 这样它能被单独测）。
///
/// 几何/配色照 Telegram 的启动观感：纯背景色 + 圆形标志 + 应用名 + 一行状态，
/// 底部一条 2dp 的细进度条。刻意不放 logo 图片资源：仓里没有品牌资源，
/// 用一个强调色圆底 + 气泡图标就够，换主题时还会自动跟着变。
library;

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';

class StartupSplash extends StatelessWidget {
  const StartupSplash({super.key, this.status = '正在启动…'});

  /// 状态行文案（"正在恢复账号…" / "已恢复，正在进入…"）。
  final String status;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 420ms 的缩放淡入：只播一次，比"直接怼出来"少一点生硬。
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0.88, end: 1),
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutBack,
                builder: (BuildContext _, double value, Widget? child) {
                  final double opacity = ((value - 0.88) / 0.12).clamp(0.0, 1.0);
                  return Opacity(
                    opacity: opacity,
                    child: Transform.scale(scale: value, child: child),
                  );
                },
                child: Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[
                        TelegramColors.accent,
                        TelegramColors.accentHover,
                      ],
                    ),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.chat_bubble_rounded,
                    size: 46,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                'QQ Client',
                style: TextStyle(
                  color: TelegramColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                status,
                key: const ValueKey('startup-status'),
                style: TextStyle(
                  color: TelegramColors.textSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 30),
              SizedBox(
                width: 132,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    backgroundColor: TelegramColors.bgHover,
                    color: TelegramColors.accent,
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
