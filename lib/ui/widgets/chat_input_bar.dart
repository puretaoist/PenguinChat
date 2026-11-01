/// L4 表现层：聊天输入栏（回复条 + 表情/附件/文本框/发送钮）。
///
/// 从 home_page.dart 抽出的**纯哑视图**：输入控制器与回调由 [HomePage]
/// 注入，本组件不读 provider、不发网络。附件与表情不依赖连接状态
/// （没连线也能选图/选表情），只有文本框与发送钮受 [enabled] 控制。
library;

import 'package:flutter/material.dart';

import '../../client_api/objects.dart';
import '../theme/telegram_theme.dart';
import 'voice_record_button.dart';

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
    this.onVoiceRecorded,
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

  /// 录音完成（裸 PCM 文件路径 + 时长 + 波形）。为空时麦克风键只提示"按住说话"，
  /// 不做任何上行——widget 测试与未接线的场景都走这条路。
  final Future<void> Function(
    String pcmPath,
    int durationMs,
    List<double> waveform,
  )? onVoiceRecorded;

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
              // 输入框长高时（最多 6 行）图标与发送键贴着底边——同 TG：
              // 键盘弹起、正文变高时按钮不跟着浮到中间。
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // 表情面板放在最左——TG 的 ChatActivityEnterView 就是
                // emoji 键贴在输入框左边，附件键在它右侧。
                // 不依赖连接状态（没连线也能先打字/选表情），点一下把
                // `/名字` 插到光标处，发送时协议层翻成表情元素。
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
                // 📎 附件：TG 只有一个回形针，点开是底部 ActionSheet 让你选
                // 图片还是文件。原来我们并排两个图标，比官方多占一格。
                IconButton(
                  key: const ValueKey('attach'),
                  onPressed: () => _pickAttachment(context),
                  icon: Icon(
                    Icons.attach_file,
                    color: TelegramColors.textSecondary,
                    size: 22,
                  ),
                  tooltip: '附件',
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
                      // 输入框随内容长高，最多 6 行后内部滚动——TG 的
                      // `ChatActivityEnterView.java:5812` 就是
                      // `messageEditText.setMaxLines(6)`。单行的话长文本会被挤成
                      // 横向滚动，手机上改起来非常难受。
                      minLines: 1,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.send,
                      style: TextStyle(
                        color: TelegramColors.textPrimary,
                        fontSize: TelegramMetrics.fontBody,
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
                // 右侧：有字才是发送（纸飞机，accent 底）；空输入时是麦克风
                // ——TG 的 ChatActivityEnterView 同样按输入内容在 send/mic
                // 之间切换，空输入给一个假的发送键会让人以为发出去了。
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) {
                    final hasText = value.text.trim().isNotEmpty;
                    if (!hasText) {
                      // 空输入 = 麦克风（按住说话），同 TG。
                      final onVoice = onVoiceRecorded;
                      return VoiceRecordButton(
                        key: const ValueKey('send-or-mic'),
                        enabled: enabled,
                        onRecorded: (pcm, waveform) async {
                          if (onVoice == null) return;
                          await onVoice(pcm.path, pcm.durationMs, waveform);
                        },
                        onError: (message) {
                          final messenger = ScaffoldMessenger.maybeOf(context);
                          messenger?.showSnackBar(
                            SnackBar(
                              content: Text(message),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        },
                      );
                    }
                    final active = enabled;
                    return GestureDetector(
                      key: const ValueKey('send-or-mic'),
                      onTap: active ? onSend : null,
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: active
                              ? TelegramColors.accent
                              : TelegramColors.bgHover,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.send,
                          color: active
                              ? Colors.white
                              : TelegramColors.textMuted,
                          size: 20,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 附件入口：TG 的点回形针 = 底部弹出「图片 / 文件」两项。
  Future<void> _pickAttachment(BuildContext context) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: TelegramColors.bgInput,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('attach-file'),
              leading: Icon(
                Icons.image_outlined,
                color: TelegramColors.textSecondary,
              ),
              title: Text(
                '发送图片',
                style: TextStyle(color: TelegramColors.textPrimary),
              ),
              onTap: () => Navigator.of(sheetContext).pop('image'),
            ),
            ListTile(
              key: const ValueKey('attach-local-file'),
              leading: Icon(
                Icons.insert_drive_file_outlined,
                color: TelegramColors.textSecondary,
              ),
              title: Text(
                '发送文件',
                style: TextStyle(color: TelegramColors.textPrimary),
              ),
              onTap: () => Navigator.of(sheetContext).pop('file'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (picked == 'image') onAttachImage();
    if (picked == 'file') onAttachFile();
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
