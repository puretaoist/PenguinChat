/// L4 组件：存储与缓存（对齐 TG 的「设置 → 数据与存储 → 存储用量」）
///
/// 只做两件事，都是 TG 有的：
/// 1. **按类别显示用量**：聊天记录（数据库）与媒体缓存分开报——用户才知道
///    清哪个有用；
/// 2. **两个清理入口**：清媒体缓存（Clear cache）、清空聊天记录（Clear history）。
///
/// 拆成"哑对话框"（统计 + 回调）是为了能离线测：真机上点一次就会把本地缓存
/// 删掉，这类破坏性操作不该只能靠手测。
library;

import 'package:flutter/material.dart';

import '../../client_api/chat_store.dart';
import '../theme/telegram_theme.dart';

class StorageDialog extends StatelessWidget {
  final StorageStats stats;

  /// 上限与保留期的一句话说明（来自 store 的配置）。
  final String? limitsNote;

  final VoidCallback? onClearCache;
  final VoidCallback? onClearHistory;

  const StorageDialog({
    super.key,
    required this.stats,
    this.limitsNote,
    this.onClearCache,
    this.onClearHistory,
  });

  /// 弹出对话框（调用方负责取统计）。
  static Future<void> show(
    BuildContext context, {
    required StorageStats stats,
    String? limitsNote,
    VoidCallback? onClearCache,
    VoidCallback? onClearHistory,
  }) =>
      showDialog<void>(
        context: context,
        builder: (_) => StorageDialog(
          stats: stats,
          limitsNote: limitsNote,
          onClearCache: onClearCache,
          onClearHistory: onClearHistory,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final size = StorageStats.formatBytes;
    return AlertDialog(
      backgroundColor: TelegramColors.bgSidebar,
      title: Text('存储与缓存',
          style: TextStyle(color: TelegramColors.textPrimary, fontSize: 16)),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _row('聊天记录', size(stats.dbBytes),
                key: const ValueKey('storage-db')),
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 10),
              child: Text(
                '${stats.chatCount} 个会话 · 内存里 ${stats.messageCount} 条消息',
                style: TextStyle(
                    color: TelegramColors.textMuted, fontSize: 12),
              ),
            ),
            _row('媒体缓存', size(stats.cacheBytes),
                key: const ValueKey('storage-cache')),
            for (final e in stats.cacheByCategory.entries)
              Padding(
                padding: const EdgeInsets.only(left: 12, top: 4),
                child: Text(
                  '${_categoryLabel(e.key)} ${size(e.value)}',
                  style: TextStyle(
                      color: TelegramColors.textSecondary, fontSize: 12.5),
                ),
              ),
            if (limitsNote != null) ...[
              const SizedBox(height: 12),
              Text(limitsNote!,
                  style: TextStyle(
                      color: TelegramColors.textMuted, fontSize: 12)),
            ],
            const SizedBox(height: 6),
            Text('聊天记录不会被自动清理；媒体缓存按上面的保留期与上限自动清理。',
                style:
                    TextStyle(color: TelegramColors.textMuted, fontSize: 12)),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey('storage-clear-cache'),
          onPressed: onClearCache == null
              ? null
              : () {
                  onClearCache!();
                  Navigator.of(context).pop();
                },
          child: Text('清理媒体缓存'),
        ),
        TextButton(
          key: const ValueKey('storage-clear-history'),
          onPressed: onClearHistory == null
              ? null
              : () {
                  onClearHistory!();
                  Navigator.of(context).pop();
                },
          child: Text('清空聊天记录',
              style: TextStyle(color: TelegramColors.danger)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('关闭'),
        ),
      ],
    );
  }

  Widget _row(String label, String value, {Key? key}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          key: key,
          children: <Widget>[
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      color: TelegramColors.textPrimary, fontSize: 14)),
            ),
            Text(value,
                style: TextStyle(
                    color: TelegramColors.textSecondary, fontSize: 13)),
          ],
        ),
      );

  static String _categoryLabel(String dir) => switch (dir) {
        'photos' => '图片',
        'videos' => '视频',
        'files' => '文件',
        'voices' => '语音',
        _ => '其它',
      };
}
