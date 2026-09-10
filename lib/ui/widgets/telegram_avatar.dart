/// Telegram 风格组件：圆形头像（首字母）
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

  const TelegramAvatar({super.key, required this.name, this.size = TelegramMetrics.avatarSize});

  @override
  Widget build(BuildContext context) {
    final color = _colorFromName(name);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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
  }
}
