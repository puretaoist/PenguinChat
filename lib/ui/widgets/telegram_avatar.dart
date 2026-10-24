/// Telegram 风格组件：圆形头像（真头像直链，退回首字母色块）
library;

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';

Color _colorFromName(String name) {
  if (name.isEmpty) return TelegramColors.accent;
  final hash = name.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0x7FFFFFFF);
  const palette = [
    Color(0xFFE17076),
    Color(0xFF7BC862),
    Color(0xFFE5CA77),
    Color(0xFF65AADD),
    Color(0xFFEE7AAE),
    Color(0xFFA695E7),
    Color(0xFF6EC9CB),
    Color(0xFFFAA774),
  ];
  return palette[hash % palette.length];
}

class TelegramAvatar extends StatelessWidget {
  final String name;
  final double size;

  /// 头像直链（可空）。拉得到就显示真头像；失败/为空退回首字母色块——
  /// 头像 CDN 在弱网下经常超时，绝不能让整行列表陪着白屏。
  final String? url;

  const TelegramAvatar({
    super.key,
    required this.name,
    this.size = TelegramMetrics.avatarSize,
    this.url,
  });

  @override
  Widget build(BuildContext context) {
    final letter = Container(
      width: size,
      height: size,
      decoration:
          BoxDecoration(color: _colorFromName(name), shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        name.isEmpty ? '?' : name.characters.first,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    if (url == null || url!.isEmpty) return letter;
    return ClipOval(
      child: Image.network(
        url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // CDN 慢是常态：加载中显示首字母色块而不是空白
        frameBuilder: (ctx, child, frame, _) => frame == null ? letter : child,
        errorBuilder: (_, _, _) => letter,
      ),
    );
  }
}
