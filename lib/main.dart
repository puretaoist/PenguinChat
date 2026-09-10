/// QQ Client — 应用入口
///
/// 架构（对标 Telegram TDLib 的分层）：
///   L4 ui/          表现层（Flutter）
///   L3 client_api/  客户端 API 层（对标 td_api）
///   L2 kernel/      协议内核（wlogin TLV / trpc / msf / crypto）
///   L1 infra/       基础设施（字节读写器）
library;

import 'package:flutter/material.dart';

import 'ui/pages/home_page.dart';
import 'ui/theme/telegram_theme.dart';

void main() {
  runApp(const QQClientApp());
}

class QQClientApp extends StatelessWidget {
  const QQClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QQ Client',
      debugShowCheckedModeBanner: false,
      theme: buildTelegramTheme(),
      home: const HomePage(),
    );
  }
}
