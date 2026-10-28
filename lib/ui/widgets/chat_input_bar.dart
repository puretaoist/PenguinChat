/// L4 表现层：聊天输入栏（回复条 + 附件/表情/文本框/发送钮）。
///
/// 从 home_page.dart 抽出的**纯哑视图**：输入控制器与回调由 [HomePage]
/// 注入，本组件不读 provider、不发网络。附件与表情不依赖连接状态
/// （没连线也能选图/选表情），只有文本框与发送钮受 [enabled] 控制。
library;

import 'package:flutter/material.dart';

import '../../client_api/objects.dart';
import '../theme/telegram_theme.dart';

/// 聊天输入栏。[replyTarget] 非空时在输入行上方显示"正在回复"条。
class ChatInputBar extends StatelessWidget {
  const ChatInputBar({
    super.key,
    required this.enabled,
    required this.controller,
    this.replyTarget,
    required this.onSend,
    required this.onAttachImage,
    required this.onAttachFile,
    required this.onOpenFaces,
    required this.onCancelReply,
  });

  /// false = 未连接：输入框禁用、发送钮变灰（提示文案换成"未连接"）。
  final bool enabled;
  final TextEditingController controller;

  /// 正在回复的消息；null = 不显示回复条。
  final ChatMessage? replyTarget;
  final VoidCallback onSend;
  final VoidCallback onAttachImage;
  final VoidCallback onAttachFile;
  final VoidCallback onOpenFaces;
  final VoidCallback onCancelReply;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: TelegramColors.bgInput,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyTarget != null) _replyStrip(replyTarget!),
            Row(
              children: [
                // 📎 发本地图片：上传链路（探图 → PicUp → highway）在适配器里，
                // 这里只问路径
                IconButton(
                  key: const ValueKey('attach-file'),
                  onPressed: onAttachImage,
                  icon: Icon(
                    Icons.attach_file,
                    color: TelegramColors.textSecondary,
                    size: 22,
                  ),
                  tooltip: '发送图片',
                ),
                // 📄 发本地文件：走离线文件链路（申请 → HTTP 上传 → 声明完成 →
                // 消息体），只在私聊里支持（群文件是另一套命令）。
                IconButton(
                  key: const ValueKey('attach-local-file'),
                  onPressed: onAttachFile,
                  icon: Icon(
                    Icons.insert_drive_file_outlined,
                    color: TelegramColors.textSecondary,
                    size: 22,
                  ),
                  tooltip: '发送文件',
                ),
                const SizedBox(width: 4),
                // 表情面板：不依赖连接状态（没连线也能先打字/选表情），
                // 点一下把 `/名字` 插到光标处，发送时协议层翻成表情元素。
                IconButton(
                  key: const ValueKey('open-faces'),
                  onPressed: onOpenFaces,
                  icon: Icon(
                    Icons.emoji_emotions_outlined,
                    color: TelegramColors.textSecondary,
                    size: 22,
                  ),
                  tooltip: 'QQ 表情',
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: TelegramColors.bgHover,
                      borderRadius: BorderRadius.circular(
                        TelegramMetrics.inputRadius,
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: TextField(
                      controller: controller,
                      enabled: enabled,
                      onSubmitted: (_) => onSend(),
                      style: TextStyle(
                        color: TelegramColors.textPrimary,
                        fontSize: 14,
                      ),
                      decoration: InputDecoration(
                        // 提示里带一句 `/微笑`：QQ 表情是打字发的（官方客户端同款约定），
                        // 不写出来没人知道——表情面板留到后面做。
                        hintText: enabled ? '输入消息…（如 /微笑）' : '未连接',
                        hintStyle: TextStyle(
                          color: TelegramColors.textSecondary,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: enabled ? onSend : null,
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: enabled
                          ? TelegramColors.accent
                          : TelegramColors.bgHover,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.send,
                      color: enabled ? Colors.white : TelegramColors.textMuted,
                      size: 20,
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

  /// 输入框上方的"正在回复"条（点 ✕ 取消）。
  Widget _replyStrip(ChatMessage target) => Container(
    key: const ValueKey('reply-strip'),
    margin: const EdgeInsets.only(bottom: 6),
    padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
    decoration: BoxDecoration(
      color: TelegramColors.bgHover,
      borderRadius: BorderRadius.circular(10),
      border: Border(left: BorderSide(color: TelegramColors.accent, width: 3)),
    ),
    child: Row(
      children: [
        Icon(Icons.reply, size: 16, color: TelegramColors.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '回复 ${target.senderName.isEmpty ? target.senderId : target.senderName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: TelegramColors.accent,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                target.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: TelegramColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          key: const ValueKey('reply-cancel'),
          onPressed: onCancelReply,
          icon: Icon(
            Icons.close,
            size: 18,
            color: TelegramColors.textSecondary,
          ),
          tooltip: '取消回复',
        ),
      ],
    ),
  );
}
