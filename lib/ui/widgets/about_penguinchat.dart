/// L4 「关于」弹窗：**只有这一份**实现。
///
/// 之前设置页和「我的」页各写了一个 `_showAbout`，文案还各说一套（一个写
/// 「两条线路」，一个只写安全声明），用户看到两个不一样的「关于」。
/// 现在两处入口调用同一个函数。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/session_providers.dart';
import '../../infra/device/device_info.dart';
import '../theme/telegram_theme.dart';

Future<void> showAboutPenguinChat(BuildContext context, WidgetRef ref) async {
  final BuildInfo info = await ref.read(deviceInfoProvider).buildInfo();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('关于 PenguinChat'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('版本 ${info.appVersion}', style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          Text(
            '提交 ${info.gitCommit} · 构建 ${info.buildTime}',
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 12),
          const Text(
            '两条线路：日用线走 OneBot（NapCat 等）；研究线是自实现 QQ 协议，'
            '只作课程学习用途。',
            style: TextStyle(fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 6),
          Text(
            '注意：自实现协议线违反 QQ 用户协议，账号可能被永久封禁；'
            '这是刻意保留的设计取舍，不做任何规避（详见 SAFETY.md）。',
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: TelegramColors.danger,
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
