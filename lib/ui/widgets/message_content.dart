/// Telegram 风格组件：一条消息的"多元素"内容
///
/// 气泡只负责外壳（颜色、圆角、时间、状态），**内容怎么排**在这里：
///
/// * 行内元素（文本 / 表情 / @）合成一段富文本，`@` 与表情名走强调色；
/// * 块级元素（图片）单独成块，按 QQ 给的原始宽高算占位框比例，
///   拿到直链就加载，加载失败/没有直链时显示占位而不是空白；
/// * 认不出来的段显示它的 [Segment.preview]（例如"富媒体消息"），
///   **不吞内容**——宁可显示得糙，也不要让人以为消息是空的。
///
/// 图片加载失败是常态（直链要真机验证、CDN 可能拒绝），所以
/// [Image.network] 的 errorBuilder 必须给，测试里也靠它兜底。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../client_api/chat_store.dart';
import '../../client_api/objects.dart';
import '../../client_api/segment.dart';
import '../../kernel/wlogin8/qq8_elem.dart';
import '../theme/telegram_theme.dart';

class MessageContent extends StatelessWidget {
  final ChatMessage message;

  /// 自己发的（右侧气泡）——决定正文与次要元素的取色。
  final bool isOut;

  const MessageContent({
    super.key,
    required this.message,
    required this.isOut,
  });

  @override
  Widget build(BuildContext context) {
    final segs = message.segments;
    final bodyColor = isOut
        ? TelegramColors.bubbleOutText
        : TelegramColors.textPrimary;

    if (segs.isEmpty) {
      return _text(message.text, bodyColor);
    }

    final blocks = <Widget>[];
    final spans = <InlineSpan>[];
    // 这"一段行内内容"是不是纯文本：是的话就用普通 Text（不是 Text.rich）——
    // 既省一点渲染开销，也让 `find.text` 这类按 data 匹配的写法照常能用。
    var plain = true;
    void flush() {
      if (spans.isEmpty) return;
      if (plain && spans.length == 1 && spans.first is TextSpan) {
        blocks.add(Text((spans.first as TextSpan).text ?? '',
            style: _base.copyWith(color: bodyColor)));
      } else {
        // children 要传**副本**：下面会 clear() 复用这个列表，
        // 传引用的话刚建好的 TextSpan 会被清空（踩过一次）。
        blocks.add(Text.rich(
          TextSpan(style: _base, children: List<InlineSpan>.of(spans)),
        ));
      }
      spans.clear();
      plain = true;
    }

    for (final s in segs) {
      switch (s) {
        case TextSegment(:final text):
          if (text.isEmpty) break;
          spans.add(TextSpan(
            text: text,
            style: TextStyle(color: bodyColor),
          ));
        case FaceSegment(:final id):
          // 表情名是给人看的（id 是给协议看的）；名字表里没有就退回 [表情]。
          final name = Qq8FaceNames.nameOf(id);
          plain = false;
          spans.add(TextSpan(
            text: name == null ? '[表情]' : '[$name]',
            style: TextStyle(color: _linkColor()),
          ));
        case AtSegment(:final qq, :final name):
          plain = false;
          spans.add(TextSpan(
            text: '@${name ?? (qq == 'all' ? '全体成员' : qq)}',
            style: TextStyle(color: _linkColor()),
          ));
        case ReplySegment():
          break; // 引用由气泡顶部的引用条负责
        case ImageSegment():
          flush();
          blocks.add(_ImageBlock(seg: s, isOut: isOut));
        case RecordSegment():
          flush();
          blocks.add(_MediaRow(
            icon: Icons.mic_none,
            title: '语音',
            detail: _withSize(
              s.seconds == null ? '' : '${s.seconds}″',
              s.size,
            ),
            isOut: isOut,
          ));
        case VideoSegment():
          flush();
          blocks.add(_MediaRow(
            icon: Icons.videocam_outlined,
            title: s.name?.isNotEmpty == true ? s.name! : '视频',
            detail: _withSize(
              s.seconds == null ? '' : '${s.seconds}″',
              s.size,
            ),
            isOut: isOut,
          ));
        case FileSegment():
          flush();
          blocks.add(_MediaRow(
            icon: Icons.insert_drive_file_outlined,
            title: s.name?.isNotEmpty == true ? s.name! : '文件',
            detail: _withSize('', s.size),
            isOut: isOut,
          ));
        case XmlSegment():
        case JsonSegment():
          // 卡片：有摘要就显示摘要（从 XML/JSON 属性里抠的），没有就显示通用文案。
          final summary = _cardSummary(s);
          flush();
          blocks.add(_MediaRow(
            icon: Icons.article_outlined,
            title: summary.isEmpty ? '卡片消息' : summary,
            detail: summary.isEmpty ? '' : '卡片消息',
            isOut: isOut,
          ));
        case PokeSegment():
          // 戳一戳是行内小动作，跟文字排一行
          spans.add(TextSpan(
            text: '[戳一戳]',
            style: TextStyle(color: _linkColor()),
          ));
        default:
          // 其它段（未知类型…）先按摘要显示，别让气泡空着。
          final text = s.preview;
          if (text.isEmpty) break;
          plain = false;
          spans.add(TextSpan(
            text: text,
            style: TextStyle(color: TelegramColors.textSecondary),
          ));
      }
    }
    flush();

    if (blocks.isEmpty) return _text(message.text, bodyColor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: 4),
          blocks[i],
        ],
      ],
    );
  }

  /// 正文基准样式（字号/行高）：子 span 只覆盖颜色。
  static const TextStyle _base = TextStyle(
    fontSize: TelegramMetrics.fontBody,
    height: 1.35,
  );

  /// 卡片摘要（两种卡片都有 [summary]，但类型不同，用模式匹配取）。
  static String _cardSummary(Segment s) => switch (s) {
        XmlSegment(:final summary) => summary,
        JsonSegment(:final summary) => summary,
        _ => '',
      };

  /// 把"主信息 · 体积"拼一行（空的部分自动省掉分隔符）。
  static String _withSize(String primary, int? size) {
    final parts = <String>[
      if (primary.isNotEmpty) primary,
      if (size != null && size > 0) StorageStats.formatBytes(size),
    ];
    return parts.join(' · ');
  }

  /// 行内强调色：自己气泡上不能再用蓝色（亮色下自己是浅绿底），走气泡文字色。
  Color _linkColor() =>
      isOut ? TelegramColors.bubbleOutText : TelegramColors.accent;

  Widget _text(String text, Color color) =>
      Text(text, style: _base.copyWith(color: color));
}

/// 语音 / 视频 / 文件 / 卡片这类"块级但没图可画"的消息：图标 + 标题 + 副信息。
///
/// 刻意做得克制：**不假装能播放**。语音要 silk 解码、视频要下载解码，都还没做，
/// 所以这里只把元数据（时长/体积/文件名）摆出来，用户至少知道收到的是什么、
/// 有多大——而不是看着一个空气泡。
class _MediaRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final bool isOut;

  const _MediaRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.isOut,
  });

  @override
  Widget build(BuildContext context) {
    final body = isOut
        ? TelegramColors.bubbleOutText
        : TelegramColors.textPrimary;
    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isOut
            ? TelegramColors.bubbleOutText.withValues(alpha: 0.10)
            : TelegramColors.bgHover,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22, color: TelegramColors.accent),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: body, fontSize: 13.5),
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    style: TextStyle(
                      color: TelegramColors.textSecondary,
                      fontSize: 11.5,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 图片块：能加载就显示，不能就显示占位（带文件名与尺寸，便于排查）。
class _ImageBlock extends StatelessWidget {
  final ImageSegment seg;
  final bool isOut;

  const _ImageBlock({required this.seg, required this.isOut});

  /// 占位/显示的最大宽度（气泡本身最大也就屏宽的 78%）。
  static const double _maxWidth = 240;

  @override
  Widget build(BuildContext context) {
    final ar = seg.aspectRatio ?? 1.0;
    final w = _maxWidth;
    final h = (w / ar).clamp(90.0, 320.0);
    final radius = BorderRadius.circular(10);

    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        width: w,
        height: h,
        child: GestureDetector(
          onTap: () => _openLarge(context),
          child: _imageOrPlaceholder(context),
        ),
      ),
    );
  }

  Widget _imageOrPlaceholder(BuildContext context) {
    if (seg.flash) return _placeholder('闪照 · 点击查看');
    final src = seg.url;
    if (src == null || src.isEmpty) {
      return _placeholder(_hint());
    }
    return Image.network(
      src,
      fit: BoxFit.cover,
      // 加载中与失败都必须有东西显示：CDN 拒绝是常态，不能留白。
      loadingBuilder: (_, child, progress) =>
          progress == null ? child : _placeholder('加载中…'),
      errorBuilder: (_, _, _) => _placeholder(_hint()),
    );
  }

  String _hint() {
    final name = seg.file.isEmpty ? seg.preview : seg.file;
    final size = seg.width != null && seg.height != null
        ? ' · ${seg.width}×${seg.height}'
        : '';
    return '$name$size';
  }

  Widget _placeholder(String text) => Container(
        color: isOut
            ? TelegramColors.bubbleOutText.withValues(alpha: 0.10)
            : TelegramColors.bgHover,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              seg.flash ? Icons.visibility_off : Icons.image_outlined,
              size: 22,
              color: TelegramColors.textSecondary,
            ),
            const SizedBox(height: 6),
            Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: TelegramColors.textSecondary,
                fontSize: 11.5,
              ),
            ),
          ],
        ),
      );

  /// 点开看大图。没有直链时就只把文件名/尺寸摊开，便于对着日志排查。
  void _openLarge(BuildContext context) {
    final ar = seg.aspectRatio ?? 1.0;
    final maxH = math.min(MediaQuery.of(context).size.height * 0.7, 640.0);
    final maxW = math.min(MediaQuery.of(context).size.width * 0.9, 900.0);
    final h = maxH;
    final w = (h * ar).clamp(120.0, maxW);

    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: w,
                height: h,
                child: seg.url == null || seg.flash
                    ? Container(
                        color: Colors.black87,
                        alignment: Alignment.center,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                seg.flash
                                    ? Icons.visibility_off
                                    : Icons.link_off,
                                color: Colors.white70,
                                size: 28,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                seg.flash
                                    ? '闪照：协议线还没做"看完即焚"，这里只显示摘要'
                                    : '没有可用的直链，无法加载原图',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12.5),
                              ),
                              const SizedBox(height: 10),
                              SelectableText(
                                '${seg.file}\n'
                                '${seg.width ?? '?'}×${seg.height ?? '?'}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 11.5),
                              ),
                            ],
                          ),
                        ),
                      )
                    : Image.network(
                        seg.url!,
                        fit: BoxFit.contain,
                        loadingBuilder: (_, child, p) =>
                            p == null ? child : const _Spinner(),
                        errorBuilder: (_, _, _) => Container(
                          color: Colors.black87,
                          alignment: Alignment.center,
                          child: const Text('原图加载失败',
                              style: TextStyle(color: Colors.white70)),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: Colors.black87,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
}
