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

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../client_api/chat_store.dart';
import '../../client_api/objects.dart';
import '../../client_api/segment.dart';
import '../../infra/net/media_fetcher.dart';
import '../../kernel/wlogin8/qq8_elem.dart';
import '../theme/telegram_theme.dart';

class MessageContent extends StatelessWidget {
  final ChatMessage message;

  /// 自己发的（右侧气泡）——决定正文与次要元素的取色。
  final bool isOut;

  /// 把"某段媒体的本地路径"解析出来的钩子（来自 [ChatStore.mediaPathOf]）。
  ///
  /// 为 null 时退化成"只用直链"，与加这个钩子之前的行为完全一致——
  /// 老测试因此不用改。
  final String? Function(Segment segment)? localMedia;

  /// 「确保这段媒体已在本地，返回路径」的钩子（来自 [ChatStore.ensureMedia]）。
  ///
  /// 为 null 时图片块只做「本地有就显示 / 没有就直链或占位」，不主动下载。
  /// 传进来之后，图片块在首帧没有本地文件时会自己补一次下载（缺陷3：首屏
  /// 只显示文件名占位卡、非要重启才出图——预取时机错过就再没人触发过）。
  final Future<String?> Function(Segment segment)? ensureMedia;

  /// 取"这段媒体上次失败的原因"的钩子（来自 [ChatStore.mediaFailureOf]）。
  ///
  /// 有它才能把占位分成两态：还在加载（显示文件名）与真的取不到
  /// （「图片链接已过期 · 点按重试」）。为 null 时只有前者。
  final MediaFetchFailureKind? Function(Segment segment)? mediaFailure;

  /// 点按重试的钩子（来自 [ChatStore.retryMedia]）。
  ///
  /// 与 [ensureMedia] 的区别是它会先清掉缓存层的负缓存，否则第二次调用会被
  /// 直接短路成 null，用户点了没反应。
  final Future<String?> Function(Segment segment)? retryMedia;

  /// 点文件块时要做什么（下载/另存）。
  ///
  /// 为 null 时文件块只是静态展示——**气泡自己不做网络请求**：它不知道
  /// 当前后端是不是协议线、也不知道该存到哪。上层接进来才有点击行为。
  final void Function(FileSegment segment)? onOpenFile;

  /// 追加在**最后一行正文末尾**的行内元素（TG 就是这么排时间的：
  /// `ChatMessageCell.java:7381` `backgroundWidth += timeWidth + dp(12)`，
  /// 时间不单独占一行）。只有纯行内内容用得上——有图片/文件这类块级段时
  /// 气泡另起一行画时间（贴在图右下角会被图盖住）。
  final InlineSpan? trailing;

  const MessageContent({
    super.key,
    required this.message,
    required this.isOut,
    this.localMedia,
    this.ensureMedia,
    this.mediaFailure,
    this.retryMedia,
    this.onOpenFile,
    this.trailing,
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
      final tail = trailing;
      if (tail == null &&
          plain &&
          spans.length == 1 &&
          spans.first is TextSpan) {
        blocks.add(Text((spans.first as TextSpan).text ?? '',
            style: _base.copyWith(color: bodyColor)));
      } else {
        // children 要传**副本**：下面会 clear() 复用这个列表，
        // 传引用的话刚建好的 TextSpan 会被清空（踩过一次）。
        blocks.add(Text.rich(
          TextSpan(style: _base, children: [
            ...List<InlineSpan>.of(spans),
            // 时间/对勾贴着最后一行正文：空间不够时整块折行，不会压到文字上。
            // 注意 ?? 这里用的是 null-aware element（Dart 3.8 的 `?tail`），
            // 没有尾巴时等于什么都没加。
            ?tail,
          ]),
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
          blocks.add(_ImageBlock(
            seg: s,
            isOut: isOut,
            localMedia: localMedia,
            ensureMedia: ensureMedia,
            mediaFailure: mediaFailure,
            retryMedia: retryMedia,
          ));
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
          final open = onOpenFile;
          blocks.add(_MediaRow(
            icon: Icons.insert_drive_file_outlined,
            title: s.name?.isNotEmpty == true ? s.name! : '文件',
            detail: _withSize('', s.size),
            isOut: isOut,
            onTap: open == null ? null : () => open(s),
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

  Widget _text(String text, Color color) {
    final style = _base.copyWith(color: color);
    final tail = trailing;
    // 纯文本消息（segments 为空、正文在 message.text 里）也要能贴时间。
    if (tail == null) return Text(text, style: style);
    return Text.rich(TextSpan(style: style, children: [
      TextSpan(text: text),
      tail,
    ]));
  }

  /// 这条消息里有没有块级段（图片 / 语音 / 视频 / 文件 / 卡片）。
  ///
  /// 有的话气泡的"最后一行"不是文本行，时间得单独占一行——否则会贴到块级
  /// 内容（比如图片）的右下角，被图盖住或悬在图片外面。
  static bool hasBlockSegments(ChatMessage message) => message.segments.any((s) =>
      s is ImageSegment ||
      s is RecordSegment ||
      s is VideoSegment ||
      s is FileSegment ||
      s is XmlSegment ||
      s is JsonSegment);
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

  /// 可点时才套一层手势（语音/视频现在没有可点的动作，传 null 就不加）。
  final VoidCallback? onTap;

  const _MediaRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.isOut,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final body = isOut
        ? TelegramColors.bubbleOutText
        : TelegramColors.textPrimary;
    final row = Container(
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
    final tap = onTap;
    if (tap == null) return row;
    return InkWell(
      key: const ValueKey('open-file'),
      onTap: tap,
      borderRadius: BorderRadius.circular(10),
      child: row,
    );
  }
}

/// 图片块：能加载就显示，不能就显示占位（带文件名与尺寸，便于排查）。
///
/// 有 [ensureMedia] 时会在首帧补一次下载（每条媒体只补一次）：
/// 预取（[ChatStore._prefetchMedia]）是尽力而为的，插入时机不对——比如消息
/// 在缓存索引就绪之前就落库——那一次失败之后再没人重试，表现就是「首屏
/// 只有文件名占位卡，重启才出图」（真机缺陷3）。补这一次，气泡自己就自愈了。
class _ImageBlock extends StatefulWidget {
  final ImageSegment seg;
  final bool isOut;
  final String? Function(Segment segment)? localMedia;
  final Future<String?> Function(Segment segment)? ensureMedia;
  final MediaFetchFailureKind? Function(Segment segment)? mediaFailure;
  final Future<String?> Function(Segment segment)? retryMedia;

  const _ImageBlock({
    required this.seg,
    required this.isOut,
    this.localMedia,
    this.ensureMedia,
    this.mediaFailure,
    this.retryMedia,
  });

  @override
  State<_ImageBlock> createState() => _ImageBlockState();
}

class _ImageBlockState extends State<_ImageBlock> {
  ImageSegment get seg => widget.seg;
  bool get isOut => widget.isOut;
  String? Function(Segment segment)? get localMedia => widget.localMedia;
  Future<String?> Function(Segment segment)? get ensureMedia =>
      widget.ensureMedia;

  /// 当前仍然有效的失败分类（来自缓存层）；null = 没试过/成功/已过 TTL。
  MediaFetchFailureKind? get _failure {
    try {
      return widget.mediaFailure?.call(seg);
    } catch (_) {
      return null;
    }
  }

  /// 已经补过下载的那条媒体的键；同一个键只补一次，失败也不无限重试。
  String? _ensureTried;
  bool _ensureInFlight = false;

  String get _mediaKey => seg.file.isNotEmpty ? seg.file : (seg.url ?? '');

  @override
  void initState() {
    super.initState();
    _scheduleEnsure();
  }

  @override
  void didUpdateWidget(covariant _ImageBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seg.file != widget.seg.file) {
      _ensureTried = null;
      _ensureInFlight = false;
    }
    _scheduleEnsure();
  }

  /// 首帧没有本地文件时补一次下载。放在帧后跑：`initState` 里不能直接拿
  /// 异步结果，而且 `build` 必须保持同步。
  void _scheduleEnsure() {
    // 优先用 retryMedia：它会先清负缓存，与"首次尝试"语义等价（清一个不存在
    // 的负缓存是空操作），但用户点按重试时是它救命的唯一路径。
    final ensure = widget.retryMedia ?? ensureMedia;
    if (ensure == null || seg.flash) return;
    if (_ensureInFlight || _ensureTried == _mediaKey) return;
    // 已知失败（链接过期/已失效）：等用户点按，不自动刷流量。
    if (_failure != null) return;
    if (_localPath() != null) return;
    final key = _mediaKey;
    _ensureInFlight = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _ensureInFlight = false;
        return;
      }
      // 失败也算试过：缓存里确实没有就是没有，重建一次重试一次会把
      // CDN 404 刷成流量。
      ensure(seg).whenComplete(() {
        if (!mounted) return;
        setState(() {
          _ensureInFlight = false;
          _ensureTried = key;
        });
      });
    });
  }

  /// 用户点按重试：清掉负缓存后重新下一次。
  ///
  /// 不走 [_scheduleEnsure]：那里会因为"已知失败"直接返回，而重试恰恰要覆盖
  /// 那个判断。
  void _retry() {
    final retry = widget.retryMedia ?? ensureMedia;
    if (retry == null) return;
    final key = _mediaKey;
    setState(() {
      _ensureInFlight = true;
      _ensureTried = null;
    });
    retry(seg).whenComplete(() {
      if (!mounted) return;
      setState(() {
        _ensureInFlight = false;
        _ensureTried = key;
      });
    });
  }

  /// 点按：失败态先重试，其余看大图。
  void _onTap(BuildContext context) {
    if (!seg.flash && _failure != null) {
      _retry();
      return;
    }
    _openLarge(context);
  }

  /// 已经落到本地的文件路径（没有或已不存在则为 null）。
  ///
  /// 存在性检查不能省：清理缓存后索引会自愈，但 `build` 可能先于自愈跑，
  /// 那时路径还在、文件已经没了，`Image.file` 会抛异常刷屏。
  String? _localPath() {
    try {
      final p = localMedia?.call(seg);
      if (p == null || p.isEmpty) return null;
      return File(p).existsSync() ? p : null;
    } catch (_) {
      return null;
    }
  }

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
          onTap: () => _onTap(context),
          child: _imageOrPlaceholder(context),
        ),
      ),
    );
  }

  Widget _imageOrPlaceholder(BuildContext context) {
    if (seg.flash) return _placeholder('闪照 · 点击查看');

    // 本地优先：直链几天就过期，本地文件不会。这条路径同时也是"离线可看"。
    final local = _localPath();
    if (local != null) {
      return Image.file(
        File(local),
        fit: BoxFit.cover,
        // 按显示尺寸解码（TG ImageLoader 的 downsampling 等价物）：
        // 相机原图 4000px 解码到 240px 档，内存与解码耗时都是数量级差别。
        cacheWidth: _decodeWidth(context, _maxWidth),
        errorBuilder: (_, _, _) => _failedPlaceholder(),
      );
    }

    // 已知取不到：说清原因并让人点按重试，而不是永远转圈。
    final failure = _failure;
    if (failure != null) return _failedPlaceholder(failure);

    // 其余（正在下 / 没有可用地址）显示文件名与尺寸，便于排查。
    //
    // **刻意不再走 Image.network**：直链几小时就过期，绕过 MediaCache 直接打
    // CDN 的结果就是"永远转圈的破图"，还会重复下载、失败后无法重试。所有
    // 字节都必须经过缓存层（这也是 Telegram ImageLoader 的做法：只认
    // memCache / 磁盘缓存 / FileLoader，不让控件自己发请求）。
    return _placeholder(_hint());
  }

  /// 失败占位：文案 = 失败原因 + 点按重试。
  Widget _failedPlaceholder([MediaFetchFailureKind? kind]) {
    final label = kind == null ? '加载失败' : mediaFetchFailureLabel(kind);
    return _placeholder('$label · 点按重试');
  }

  /// 解码目标宽（物理像素）。取整到 256 的倍数可以复用 ImageCache 的键，
  /// 否则每个略不同的屏宽都会各解码一份。
  static int _decodeWidth(BuildContext context, double logical) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;
    final px = (logical * dpr) ~/ 256 * 256;
    return px < 256 ? 256 : px;
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
    final localLarge = _localPath();
    final ar = seg.aspectRatio ?? 1.0;
    // sizeOf：键盘动画帧（viewInsets）不触发重建
    final maxH = math.min(MediaQuery.sizeOf(context).height * 0.7, 640.0);
    final maxW = math.min(MediaQuery.sizeOf(context).width * 0.9, 900.0);
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
                child: localLarge == null && (seg.url == null || seg.flash)
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
                    : localLarge != null
                        ? Image.file(
                            File(localLarge),
                            cacheWidth: _decodeWidth(
                                context, MediaQuery.sizeOf(context).width),
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => Container(
                              color: Colors.black87,
                              alignment: Alignment.center,
                              child: const Text(
                                '本地文件读不出来了（可能刚被缓存清理删掉）',
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 12.5),
                              ),
                            ),
                          )
                        : Image.network(
                        seg.url!,
                        cacheWidth: _decodeWidth(
                            context, MediaQuery.sizeOf(context).width),
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
