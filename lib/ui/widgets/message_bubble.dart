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
import 'package:flutter/rendering.dart';

import '../../client_api/objects.dart';
import '../../client_api/segment.dart';
import '../../infra/net/media_fetcher.dart';
import '../platform/app_breakpoints.dart';
import '../theme/telegram_theme.dart';
import 'message_content.dart';

/// 时分（`12:05`）。[withSeconds] 打开后补上秒（抄 exteraGram 的
/// `ExteraConfig.formatTimeWithSeconds`，列表与气泡共用同一格式化）。
String formatTime(DateTime t, {bool withSeconds = false}) {
  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');
  if (!withSeconds) return '$hh:$mm';
  return '$hh:$mm:${t.second.toString().padLeft(2, '0')}';
}

class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  /// 发送失败时的重试入口。为 null 表示不提供重试（例如收到的消息）。
  final VoidCallback? onRetry;

  /// 气泡圆角；null = 走 [TelegramMetrics.bubbleRadius]（17）。
  final double? bubbleRadius;

  /// 是否显示发送者名（群聊里同一人的第一条）。
  final bool showSenderName;

  /// 是否为本组的第一条（同方向 + 同发送者 + 5 分钟内）。
  ///
  /// TG 的连续消息堆只把**最上面**那条的顶角画满圆，中间几条的"外侧"顶角
  /// 收成 6dp（ChatMessageCell 里 cornerRadius 按 isFirstInGroup 改），
  /// 这样一叠消息看起来是连在一起的一坨，而不是一串独立胶囊。
  final bool firstInGroup;

  /// 发言人显示名的覆盖值（可选）。
  ///
  /// 消息体里带的 senderName 经常是空的、或（旧数据）是 QQ 号；上层能从
  /// 名字缓存里解析出网名/备注时用这个覆盖，气泡自己不去查任何东西。
  final String? senderLabel;

  /// 是否被 @（或回复到我）：左侧画一条 accent 竖线。
  final bool highlighted;

  /// 这个会话是否**有头像列**（群聊为 true、私聊为 false）。
  ///
  /// TG 私聊也画头像，所以入站气泡一律从 dp(48+3) 起；本项目私聊不画头像
  /// （见 home_page 的 showAvatars），若照搬 3dp 就会贴着屏幕左边，所以在
  /// 没有头像列时保留 8dp 的呼吸位。
  final bool showAvatarColumn;

  /// 这一行左侧是否画了头像。TG 的可用气泡宽度在画头像时会再扣 52dp
  /// （`messenger/MessageObject.java:8527-8531`：`parentWidth - dp(80)`，
  /// 再在 `needDrawAvatarInternal() && !isOutOwner()` 时 `- dp(52)`）。
  final bool avatarVisible;

  /// 已撤回消息的「查看」入口（揭示原文）。为 null 表示不提供。
  final VoidCallback? onReveal;

  /// 把"某段媒体的本地路径"解析出来的钩子。
  ///
  /// 由上层（`home_page.dart`）从 [ChatStore.mediaPathOf] 接进来。做成回调
  /// 而不是让气泡自己去取 store：气泡是纯展示组件，它不该知道 Riverpod 的
  /// 存在，测试里也就能直接传一个假的解析器。
  final String? Function(Segment segment)? localMedia;

  /// 「确保这段媒体在本地」的钩子（[ChatStore.ensureMedia]）。
  ///
  /// 与 [localMedia] 配套：拿不到本地文件时由图片块补一次下载（缺陷3）。
  final Future<String?> Function(Segment segment)? ensureMedia;

  /// 「这段媒体上次为什么失败」的钩子（[ChatStore.mediaFailureOf]）。
  /// 有它才能把图片占位分成"还在加载"与"确实取不到，可点按重试"。
  final MediaFetchFailureKind? Function(Segment segment)? mediaFailure;

  /// 点按重试的钩子（[ChatStore.retryMedia]）：清负缓存后重新下。
  final Future<String?> Function(Segment segment)? retryMedia;

  /// 点文件块时的动作（下载/另存）。为 null = 只展示，不可点。
  final void Function(FileSegment segment)? onOpenFile;

  /// 把**气泡自己**（不含左右各 8dp 的行内留白）的 RenderBox 交给调用方。
  ///
  /// 单击气泡要贴着气泡弹菜单（TG 的 popup），而本组件的根是 Padding+Row，
  /// 宽高是整行——直接拿它的 RenderBox 会把菜单钉到屏幕边上。
  /// 交出 RenderBox 而不是 Rect：Rect 是布局时的快照，滚动后不重排就会过期，
  /// 调用方在点击那一刻 localToGlobal 才永远是最新位置。
  final void Function(RenderBox box)? onBubbleBox;

  /// 气泡从树上摘下来时回调，把那份引用传回去，让调用方按**身份**删掉
  /// 自己记的那一条（否则会记住已经脱离树的 RenderBox；只按消息 id 删会
  /// 在切会话、id 重复时误删新气泡的那份引用）。
  final ValueChanged<RenderBox>? onBubbleBoxGone;

  const MessageBubble({
    super.key,
    required this.message,
    this.onRetry,

    /// 气泡圆角（null = 用 TelegramMetrics.bubbleRadius 的默认 17）。
    /// 由消息列表按用户偏好传下来，组件本身不依赖 riverpod，
    /// 这样金样测试/单独使用都不必包 ProviderScope。
    this.bubbleRadius,
    this.showSenderName = true,
    this.firstInGroup = true,
    this.senderLabel,
    this.highlighted = false,
    this.showAvatarColumn = false,
    this.avatarVisible = false,
    this.onReveal,
    this.localMedia,
    this.ensureMedia,
    this.mediaFailure,
    this.retryMedia,
    this.onOpenFile,
    this.onBubbleBox,
    this.onBubbleBoxGone,
  });

  @override
  Widget build(BuildContext context) {
    // 气泡宽度要听**父级给的实际宽度**，不能只看屏宽：桌面端把窗口拉窄、
    // 或侧栏占掉一半时，按屏宽算出来的 78% 会超出可用空间，Row 直接溢出
    // （widget 测试在 800px 宽的窗口下抓到过）。
    return LayoutBuilder(
      builder: (context, constraints) {
        // sizeOf：键盘动画帧（viewInsets）不触发重建
        final mediaLimit = math.min(
          MediaQuery.sizeOf(context).width * 0.78,
          AppBreakpoints.bubbleMaxWidth,
        );
        // 扣掉同一行里的兄弟：外层 Padding 靠屏那一侧最多 8dp（另一侧 0）。
        // 余量给 Row 两端与取整误差，避免 800px 窗口下溢出。
        const chrome = 8.0;
        // 宽度按 TG 的算法收：父宽 -80，画头像的那一侧再 -52
        // （messenger/MessageObject.java:8527-8531）。本组件拿到的
        // constraints 已经扣掉了头像槽（44dp），所以这里只补 20（= 80 - 44 - 16
        // 里的差值）与头像那 52。短屏上比以前窄 18dp 左右，正是 TG 的留白。
        final avatarInset = avatarVisible ? 56.0 : 0.0;
        final avail = math.max(
          constraints.maxWidth - chrome - 16 - avatarInset,
          0.0,
        );
        final maxWidth = constraints.maxWidth.isFinite
            ? math.min(mediaLimit, avail)
            : mediaLimit;
        return _build(context, maxWidth);
      },
    );
  }

  Widget _build(BuildContext context, double maxWidth) {
    final isOut = message.outgoing;
    // 单图（没有别的块级段）时把时间画进图片右下角（TG ChatMessageCell.java
    // 24015-24060 的 media 分支），气泡不再为时间另留一行；没有文字说明的
    // 纯图还要四边贴边（连内边距一起去掉）。
    final imageOnly =
        MessageContent.singleImageBlock(message) &&
        !message.isFailed &&
        !(message.isRecalled && !message.revealed);
    final pureImage =
        imageOnly &&
        message.text.trim().isEmpty &&
        message.replyPreview == null;
    final double radius = bubbleRadius ?? TelegramMetrics.bubbleRadius;
    // 外侧（靠头像/靠屏幕边的那一侧）顶角：组内非首条收成 6dp。
    const double tight = 6.0;
    final double outerTop = firstInGroup ? radius : tight;
    final bubbleShape = BorderRadius.only(
      topLeft: Radius.circular(isOut ? radius : outerTop),
      topRight: Radius.circular(isOut ? outerTop : radius),
      bottomLeft: Radius.circular(
        isOut ? radius : TelegramMetrics.bubbleTailRadius,
      ),
      bottomRight: Radius.circular(
        isOut ? TelegramMetrics.bubbleTailRadius : radius,
      ),
    );
    final inner = Container(
      decoration: BoxDecoration(
        // @我 的入站气泡：底色掺 12% 强调色（TG 用强调色表达"有人在叫我"，
        // 但**不画气泡外的东西**）。以前这里在气泡外面挂了一根 3x28 的紫色
        // 竖条，用户反馈"聊天气泡外部左侧的竖条是什么，怎么有的有有的没有"
        // ——那根条只在 @我/回复 的消息上出现，纯属自造视觉。
        color: isOut
            ? TelegramColors.bubbleOut
            : (highlighted
                  ? Color.alphaBlend(
                      TelegramColors.accent.withValues(alpha: 0.12),
                      TelegramColors.bubbleIn,
                    )
                  : TelegramColors.bubbleIn),
        borderRadius: bubbleShape,
      ),
      // 内边距不是四边等宽：TG layoutTextXY 16626-16651 自己 +11、对方 +17
      // （给对方头像留空隙），上 8、右 12、下 6。
      padding: pureImage
          ? EdgeInsets.zero
          : EdgeInsets.fromLTRB(isOut ? 11 : 17, 8, 12, 6),
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
                if (!isOut &&
                    showSenderName &&
                    (senderLabel ?? message.senderName).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      senderLabel ?? message.senderName,
                      style: TextStyle(
                        // TG 按 user.id % 7 轮转七色（UserObject.java:212-216），
                        // 不是统一强调色。
                        color: TelegramColors.nameColorFor(message.senderId),
                        // TG `Theme.java:8399` namePaint = dp((2*16+10)/3) = 14。
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (message.replyPreview != null &&
                    message.replyPreview!.isNotEmpty)
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
                    ensureMedia: ensureMedia,
                    mediaFailure: mediaFailure,
                    retryMedia: retryMedia,
                    onOpenFile: onOpenFile,
                    imageMeta: imageOnly ? _imageTimeBadge(isOut) : null,
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
          // 单图的时间已经画在图片右下角（imageOnly），不再占一行。
          if (!_inlineMeta && !imageOnly) ...[
            const SizedBox(height: 2),
            _metaRow(isOut),
          ],
        ],
      ),
    );
    final body = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      // 纯图要贴满四角：Container 的 decoration 不裁剪子级，必须自己 Clip。
      child: pureImage
          ? ClipRRect(borderRadius: bubbleShape, child: inner)
          : inner,
    );

    // 交出自己的 RenderBox（弹菜单定位用）。用回调而不是 GlobalKey：
    // 每屏有几十个气泡，调用方得逐个建 key 再逐个清理，回调省掉这一层。
    final bubble = onBubbleBox == null
        ? body
        : BubbleBoxReporter(
            onBox: onBubbleBox!,
            onGone: onBubbleBoxGone,
            child: body,
          );
    // 靠屏一侧的留白照 TG 收窄到 3dp（媒体 9dp，`ChatMessageCell.java:20595`
    // 入站 / 20515 出站），原来左右一律 8dp，整列气泡比 TG 多缩进 5dp，看着更窄。
    // 垂直方向按"是否组首"分档：TG 组间空隙大、组内几乎贴紧（名字行本身也
    // 占高度），原来一律 1dp 让所有消息糊成一坨，且组与组之间分不开。
    final double outEdge = imageOnly ? 9 : 3;
    // 入站靠左的留白：有头像列（群聊）时照 TG 的 3dp，没头像列（私聊）留 8dp。
    final double inEdge = imageOnly ? 9 : (showAvatarColumn ? 3 : 8);
    return Padding(
      padding: EdgeInsets.only(
        left: isOut ? 0 : inEdge,
        right: isOut ? outEdge : 0,
        top: firstInGroup ? 7 : 2,
        bottom: 2,
      ),
      child: Row(
        mainAxisAlignment: isOut
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [bubble],
      ),
    );
  }

  /// 图片右下角的时间块（TG media 分支：黑 52% 底、圆角 8、白字 12）。
  ///
  /// 图片四边贴气泡，时间只能叠在图上——否则会像以前那样在图片下面白多一行。
  Widget _imageTimeBadge(bool isOut) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.52),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatTime(message.time),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11.5,
              height: 1.2,
            ),
          ),
          if (isOut) ...[
            const SizedBox(width: 3),
            // 单勾 = 服务端已接受。双勾（已读）需要对方的已读回执，
            // QQ 官方协议不给普通消息这个信息（见 docs/已读回执-可行性-20261101.md）。
            Icon(
              message.isFailed
                  ? Icons.error_outline
                  : message.isSending
                  ? Icons.schedule
                  : Icons.done,
              size: 12,
              color: Colors.white70,
            ),
          ],
        ],
      ),
    );
  }

  /// 引用条：竖线 + 引用原文（最多两行）。
  Widget _replyQuote(bool isOut) {
    final quoteColor = isOut
        ? TelegramColors.bubbleOutTime
        : TelegramColors.textSecondary;
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
    final timeColor = isOut
        ? TelegramColors.bubbleOutTime
        : TelegramColors.textSecondary;
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
                    : Icons.done,
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
    final timeColor = isOut
        ? TelegramColors.bubbleOutTime
        : TelegramColors.textSecondary;
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
                : Icons.done,
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
    // 几何照 TG 的 ChatUnreadCell：
    // - 整个 cell 高 40（ChatUnreadCell.java:73 `makeMeasureSpec(dp(40), EXACTLY)`）
    // - 色带 newmsg_divider 高 27、距顶 7（:39 `createFrame(MATCH_PARENT, 27, TOP, 0, 7, 0, 0)`）
    // - 文案 14 号粗体、居中、左右各 32 边距（:49-52）
    // - 右侧下箭头 ic_ab_new、右边距 10（:41-45）
    final accent = TelegramColors.accent;
    return SizedBox(
      height: 40,
      child: Stack(
        children: [
          Positioned(
            top: 7,
            left: 0,
            right: 0,
            height: 27,
            child: Container(
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          Center(
            child: Text(
              '未读消息',
              style: TextStyle(
                color: accent,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Positioned(
            right: 10,
            top: 7,
            height: 27,
            child: Center(
              child: Icon(Icons.arrow_downward, size: 18, color: accent),
            ),
          ),
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
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          // 暗色是黑底白字；亮色反过来——TG 亮色的日期胶囊是比聊天背景
          // 略深的浅灰底 + 深灰字，白字压在浅色背景上根本看不清。
          color: TelegramColors.isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.black.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(TelegramMetrics.dateChipRadius),
        ),
        child: Text(
          label(day, now: now),
          style: TextStyle(
            color: TelegramColors.isDark
                ? Colors.white.withValues(alpha: 0.85)
                : TelegramColors.textSecondary,
            fontSize: TelegramMetrics.fontDateChip,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// 把子级（气泡）自己的 RenderBox 交给调用方，并在摘树时通知回收。
///
/// 这里必须用 RenderObject 而不是 Builder：Builder 拿到的 context 位于
/// 父级（Row）之下，取到的是撑满整行的 box，气泡宽度反而拿不到。
class BubbleBoxReporter extends SingleChildRenderObjectWidget {
  const BubbleBoxReporter({
    super.key,
    required this.onBox,
    this.onGone,
    required super.child,
  });

  final ValueChanged<RenderBox> onBox;
  final ValueChanged<RenderBox>? onGone;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _BubbleBoxRender(onBox, onGone);

  @override
  void updateRenderObject(BuildContext context, RenderBox renderObject) {
    final r = renderObject as _BubbleBoxRender;
    r
      ..onBox = onBox
      ..onGone = onGone;
  }
}

class _BubbleBoxRender extends RenderProxyBox {
  _BubbleBoxRender(this.onBox, this.onGone);

  ValueChanged<RenderBox> onBox;
  ValueChanged<RenderBox>? onGone;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    onBox(this);
  }

  @override
  void detach() {
    onGone?.call(this);
    super.detach();
  }
}
