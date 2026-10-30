/// Telegram 风格组件：消息气泡
///
/// 对齐现行 Telegram 的气泡形态：
/// * 自己靠右（紫色）、对方靠左（深灰），三个角大圆角、贴底那侧小圆角；
/// * 时间戳与送达对勾贴在右下角，颜色跟气泡走（自己气泡 = 白 60%）；
/// * **回复引用条**：气泡顶部一条竖线 + 引用原文（最多两行）；
/// * **@我/回复我**：气泡左侧一条 accent 竖线（TG 在群聊里就是这么标的）；
/// * 发送失败：红色感叹号 + 「点此重试」（文本必须还在，不得静默丢弃）；
/// * 撤回：显示占位文案而不是把气泡删掉；**内容一直留着**，点「查看」就地
///   揭示原文（Nagram/NekoX 系的"反撤回"，靠 `ChatMessage.deleted/revealed`）。
///
/// 「同一个人连续发言只显示一次名字/头像」由调用方（消息列表）决定，
/// 通过 [showSenderName] 传进来——分组逻辑属于列表，不属于单个气泡。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../client_api/objects.dart';
import '../../client_api/segment.dart';
import '../theme/telegram_theme.dart';
import 'message_content.dart';

String formatTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  /// 发送失败时的重试入口。为 null 表示不提供重试（例如收到的消息）。
  final VoidCallback? onRetry;

  /// 是否显示发送者名（群聊里同一人的第一条）。
  final bool showSenderName;

  /// 是否被 @（或回复到我）：左侧画一条 accent 竖线。
  final bool highlighted;

  /// 已撤回消息的「查看」入口（揭示原文）。为 null 表示不提供。
  final VoidCallback? onReveal;

  /// 把"某段媒体的本地路径"解析出来的钩子。
  ///
  /// 由上层（`home_page.dart`）从 [ChatStore.mediaPathOf] 接进来。做成回调
  /// 而不是让气泡自己去取 store：气泡是纯展示组件，它不该知道 Riverpod 的
  /// 存在，测试里也就能直接传一个假的解析器。
  final String? Function(Segment segment)? localMedia;

  /// 点文件块时的动作（下载/另存）。为 null = 只展示，不可点。
  final void Function(FileSegment segment)? onOpenFile;

  const MessageBubble({
    super.key,
    required this.message,
    this.onRetry,
    this.showSenderName = true,
    this.highlighted = false,
    this.onReveal,
    this.localMedia,
    this.onOpenFile,
  });

  @override
  Widget build(BuildContext context) {
    // 气泡宽度要听**父级给的实际宽度**，不能只看屏宽：桌面端把窗口拉窄、
    // 或侧栏占掉一半时，按屏宽算出来的 78% 会超出可用空间，Row 直接溢出
    // （widget 测试在 800px 宽的窗口下抓到过）。
    return LayoutBuilder(
      builder: (context, constraints) {
        // sizeOf：键盘动画帧（viewInsets）不触发重建
        final mediaLimit = MediaQuery.sizeOf(context).width * 0.78;
        // 还要扣掉同一行里的兄弟：外层 Padding 的 8x2，以及高亮竖条（3 宽 + 4 外边距）。
        // 不扣的话 Row 会溢出——widget 测试在 800px 宽的窗口下抓到了这 16px。
        final chrome = 16.0 + (highlighted ? 7.0 : 0.0);
        final avail = math.max(constraints.maxWidth - chrome, 0.0);
        final maxWidth =
            constraints.maxWidth.isFinite ? math.min(mediaLimit, avail) : mediaLimit;
        return _build(context, maxWidth);
      },
    );
  }

  Widget _build(BuildContext context, double maxWidth) {
    final isOut = message.outgoing;
    final body = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: maxWidth,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: isOut ? TelegramColors.bubbleOut : TelegramColors.bubbleIn,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(TelegramMetrics.bubbleRadius),
            topRight: const Radius.circular(TelegramMetrics.bubbleRadius),
            bottomLeft: Radius.circular(isOut
                ? TelegramMetrics.bubbleRadius
                : TelegramMetrics.bubbleTailRadius),
            bottomRight: Radius.circular(isOut
                ? TelegramMetrics.bubbleTailRadius
                : TelegramMetrics.bubbleRadius),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 气泡宽度必须由「最宽的子项」决定（TG 的气泡随正文收缩）。
            // 关键：Align 默认撑满父宽，所以这层给 widthFactor: 1 让它 hug；
            // 发送者名/引用/正文/撤回行全部塞进同一个 start 对齐的内层 Column，
            // 这样谁最宽谁定宽度，其余子项都跟着 hug，不会被顶到右边。
            Align(
              alignment: Alignment.centerLeft,
              widthFactor: 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isOut && showSenderName && message.senderName.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        message.senderName,
                        style: TextStyle(
                          color: TelegramColors.accent,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (message.replyPreview != null && message.replyPreview!.isNotEmpty)
                    _replyQuote(isOut),
                  if (message.isRecalled && !message.revealed)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          message.displayText,
                          style: TextStyle(
                            color: isOut
                                ? TelegramColors.bubbleOutTime
                                : TelegramColors.textSecondary,
                            fontStyle: FontStyle.italic,
                            fontSize: TelegramMetrics.fontBody,
                            height: 1.35,
                          ),
                        ),
                        if (onReveal != null) ...[
                          const SizedBox(width: 6),
                          GestureDetector(
                            key: const ValueKey('msg-reveal'),
                            onTap: onReveal,
                            child: Text(
                              '查看',
                              style: TextStyle(
                                color: isOut
                                    ? TelegramColors.bubbleOutText
                                    : TelegramColors.accent,
                                fontSize: TelegramMetrics.fontTimestamp + 1,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    )
                  else ...[
                    // 正文交给 MessageContent：文本/表情/@ 行内排，图片单独成块。
                    // 揭示后的撤回消息也走这里——反撤回要能看到**原样**的内容，
                    // 包括图片；"已撤回 · 内容已保留"那行注释负责说明它是被撤回的。
                    MessageContent(
                      message: message,
                      isOut: isOut,
                      localMedia: localMedia,
                      onOpenFile: onOpenFile,
                      trailing: _inlineMeta ? _metaInline(isOut) : null,
                    ),
                    if (message.deleted)
                      Text(
                        '已撤回 · 内容已保留',
                        key: const ValueKey('msg-recalled-note'),
                        style: TextStyle(
                          color: isOut
                              ? TelegramColors.bubbleOutTime
                              : TelegramColors.textMuted,
                          fontSize: TelegramMetrics.fontTimestamp,
                        ),
                      ),
                  ],
                ],
              ),
            ),
            // 时间/状态能贴正文就贴（TG 的排法，见 [_inlineMeta]），贴不了
            // 才单独占一行——否则每个气泡都白多出一行高度，短消息看着特别空。
            if (!_inlineMeta) ...[const SizedBox(height: 2), _metaRow(isOut)],
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Row(
        mainAxisAlignment:
            isOut ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (highlighted) ...[
            Container(
              width: 3,
              height: 28,
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: TelegramColors.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
          body,
        ],
      ),
    );
  }

  /// 引用条：竖线 + 引用原文（最多两行）。
  Widget _replyQuote(bool isOut) {
    final quoteColor =
        isOut ? TelegramColors.bubbleOutTime : TelegramColors.textSecondary;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: isOut ? TelegramColors.bubbleOutText : TelegramColors.accent,
            width: 2,
          ),
        ),
      ),
      child: Text(
        message.replyPreview!,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: quoteColor, fontSize: 13),
      ),
    );
  }

  /// 时间/送达状态能不能排进最后一行正文。
  ///
  /// 三种例外要单独占一行：
  /// * 发送失败——那行是**可点的**「点此重试」，挤进正文里点不准；
  /// * 未揭示的撤回——内容那行本身就是「已撤回 + 查看」的行内结构；
  /// * 有块级段（图片/语音/文件/卡片）——行内尾巴会被块级内容顶到下一行。
  bool get _inlineMeta =>
      !(message.isFailed && onRetry != null) &&
      !(message.isRecalled && !message.revealed) &&
      !MessageContent.hasBlockSegments(message);

  /// 贴在最后一行正文末尾的时间（自己气泡再加送达对勾）。
  ///
  /// 用 WidgetSpan 塞进文本流里（`PlaceholderAlignment.bottom` 让它贴着行底，
  /// 不参与基线——Row 没有基线，用 baseline 对齐会断言失败）。
  InlineSpan _metaInline(bool isOut) {
    final timeColor =
        isOut ? TelegramColors.bubbleOutTime : TelegramColors.textSecondary;
    return WidgetSpan(
      alignment: PlaceholderAlignment.bottom,
      child: Padding(
        padding: const EdgeInsets.only(left: 8, top: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatTime(message.time),
              style: TextStyle(
                color: timeColor,
                fontSize: TelegramMetrics.fontTimestamp,
              ),
            ),
            if (isOut) ...[
              const SizedBox(width: 4),
              Icon(
                message.isFailed
                    ? Icons.error_outline
                    : message.isSending
                        ? Icons.schedule
                        : Icons.done_all,
                size: 14,
                color: message.isFailed
                    ? TelegramColors.danger
                    : TelegramColors.bubbleOutTime,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 右下角：失败提示 + 时间 + 送达状态。
  Widget _metaRow(bool isOut) {
    final timeColor =
        isOut ? TelegramColors.bubbleOutTime : TelegramColors.textSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message.isFailed && onRetry != null) ...[
          GestureDetector(
            onTap: onRetry,
            child: Text(
              '发送失败，点此重试',
              style: TextStyle(
                color: TelegramColors.danger,
                fontSize: TelegramMetrics.fontTimestamp,
              ),
            ),
          ),
          const SizedBox(width: 6),
        ],
        Text(
          formatTime(message.time),
          style: TextStyle(
            color: timeColor,
            fontSize: TelegramMetrics.fontTimestamp,
          ),
        ),
        if (isOut) ...[
          const SizedBox(width: 4),
          Icon(
            message.isFailed
                ? Icons.error_outline
                : message.isSending
                    ? Icons.schedule
                    : Icons.done_all,
            size: 14,
            color: message.isFailed
                ? TelegramColors.danger
                : TelegramColors.bubbleOutTime,
          ),
        ],
      ],
    );
  }
}

/// "未读消息"分隔线。
///
/// 形态照 Nagram 的 `ChatUnreadCell`：**通栏**一条（左右不留边，横贯列表宽度），
/// 文字居中加粗，右端一个向下的箭头。颜色不写死：底 = 强调色打薄、字与箭头 =
/// 强调色本身——亮色（`#3390EC` 压浅蓝）与暗色（`#8774E1` 压紫）都成立，
/// 所以不需要再往调色板里加两个字段。
class UnreadDivider extends StatelessWidget {
  const UnreadDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final accent = TelegramColors.accent;
    return Container(
      height: 28,
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: accent.withValues(alpha: 0.18),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '未读消息',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: accent,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Icon(Icons.arrow_downward, size: 16, color: accent),
        ],
      ),
    );
  }
}

/// 日期分隔胶囊（TG 的"今天/昨天/日期"）。
class DateChip extends StatelessWidget {
  final DateTime day;

  /// "今天/昨天"的判定基准（默认取当前时间）。
  ///
  /// ⚠️ 金样测试必须传固定值：`label` 依赖当前日期，跨零点会让金样变红
  /// （踩过一次——09-12 生成的金样，09-13 一跑就成了"昨天"，差 0.15% 像素）。
  final DateTime? now;

  const DateChip({super.key, required this.day, this.now});

  /// 给人看的日期文案：今天 / 昨天 / `M月d日` / `yyyy年M月d日`。
  static String label(DateTime day, {DateTime? now}) {
    final today = now ?? DateTime.now();
    final d = DateTime(day.year, day.month, day.day);
    final t = DateTime(today.year, today.month, today.day);
    final diff = t.difference(d).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    if (d.year == t.year) return '${d.month}月${d.day}日';
    return '${d.year}年${d.month}月${d.day}日';
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(TelegramMetrics.dateChipRadius),
        ),
        child: Text(
          label(day, now: now),
          style: TextStyle(
            color: Colors.white,
            fontSize: TelegramMetrics.fontDateChip,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
