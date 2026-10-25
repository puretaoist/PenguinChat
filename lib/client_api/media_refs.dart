/// L3 客户端层：把 [Segment] 映射成"可缓存的媒体引用"
///
/// ## 为什么需要这一层
///
/// 缓存需要三样东西：**稳定的键**（重启后还能命中）、**分类**（对齐 TG 的
/// 存储用量页）、**可下载地址**。这三样都只能从 [Segment] 的字段推出来，
/// 但推导规则属于"客户端语义"，不该塞进 L1 的缓存实现，也不该散落在 UI 里。
///
/// ## 键怎么选（这里最容易出错）
///
/// 键必须在**下次启动后仍然一样**，否则每次冷启动都会重下一遍。可选的有三个：
///
/// | 字段 | 稳定性 | 问题 |
/// |---|---|---|
/// | `url` | ❌ | 腾讯的直链带 `rkey`/`term`，几天就换一批 |
/// | `file` | ✅（QQ）| OneBot 后端可能给的是**后端主机**上的路径 |
/// | 内容哈希 | ✅ | 要下载完才知道，没法"下载前查重" |
///
/// 所以规则是：**优先用 `file`，但它必须像"文件名"而不是"路径"**。
/// 像路径的（含 `/`、`\`、`:`）说明它是后端/本机的绝对路径，对缓存无意义
/// （本地路径本来就该直接读文件），此时退回 `url`。
///
/// 已知局限：OneBot 侧若两个不同会话出现同名 `file`，会互相覆盖缓存。
/// 实际影响是"显示成另一张图"，比"永远加载失败"轻，且 NapCat 的 `file`
/// 通常带哈希，重名概率很低。真出问题再在键里掺会话 ID。
library;

import 'segment.dart';

/// 一条可缓存的媒体引用。
class MediaRef {
  /// 缓存键（跨重启稳定）。
  final String key;

  /// 分类，取值必须在 `ChatStore.mediaCategories` 内。
  final String category;

  /// 下载地址（http/https/file/裸路径）。
  final String url;

  /// 备选地址，按优先级排列，**不含** [url]。
  ///
  /// 腾讯的 `rkey` 直链几小时后必失效（服务端回
  /// `{"retcode":-5503007,"retmsg":"download url has expired"}`），但同一张图
  /// 往往还有「按 md5 取」的活地址。多备几个能让一部分老图起死回生，
  /// 而不是永远停在占位框。
  final List<String> altUrls;

  const MediaRef({
    required this.key,
    required this.category,
    required this.url,
    this.altUrls = const <String>[],
  });

  /// 全部候选（首选在前），已去重、已剔除空串。
  List<String> get candidates =>
      _dedupe(<String>[if (url.isNotEmpty) url, ...altUrls]);

  @override
  String toString() => 'MediaRef($category, $key -> $url'
      '${altUrls.isEmpty ? '' : ' +${altUrls.length}'})';
}

List<String> _dedupe(List<String> xs) {
  final seen = <String>{};
  final out = <String>[];
  for (final x in xs) {
    if (x.isEmpty) continue;
    if (seen.add(x)) out.add(x);
  }
  return out;
}

/// 该段是否带媒体（需要落盘）。
bool segmentHasMedia(Segment seg) => switch (seg) {
      ImageSegment() || RecordSegment() || VideoSegment() || FileSegment() =>
        true,
      _ => false,
    };

/// 从 [Segment] 推导缓存引用；推不出来（没有可用地址/键）返回 null。
///
/// 返回 null 的典型情况：`ImageSegment` 既没有 `url` 也没有像样的 `file`
/// （服务端只给了占位符）——这时只能显示占位，缓存无从谈起。
MediaRef? mediaRefOf(Segment seg) {
  final kind = _kindOf(seg);
  if (kind == null) return null;

  final category = _categoryOf(seg);
  final file = _fileOf(seg);
  final url = _urlOf(seg);

  // 地址：能下才值得缓存。`file` 是绝对路径时它自己就是地址。
  final address = url.isNotEmpty
      ? url
      : (file.isNotEmpty && _looksLikePath(file) ? file : '');

  // 键：优先稳定标识（file），但它得像文件名；否则用地址。
  final keyPart =
      (file.isNotEmpty && !_looksLikePath(file)) ? file : address;
  if (keyPart.isEmpty) return null;

  return MediaRef(
    key: '$kind:$keyPart',
    category: category,
    url: address,
    altUrls: _altUrlsOf(seg),
  );
}

/// 备选下载地址。
///
/// 目前只有一种可用规律：**QQ 图片的 `file` 前 32 位就是 md5**，据此可以拼
/// 出「按 md5 取图」的兜底直链（`gchatpic_new/0/0-0-<MD5>/0`）。实测这种
/// 兜底对一部分图有效（约 20%），失败的返回 404 —— 所以它只作备选，
/// 首选永远是消息里带的那个直链。
List<String> _altUrlsOf(Segment seg) {
  if (seg is! ImageSegment) return const <String>[];
  final md5 = _md5OfFile(seg.file);
  if (md5 == null) return const <String>[];
  final upper = md5.toUpperCase();
  return <String>['https://gchat.qpic.cn/gchatpic_new/0/0-0-$upper/0'];
}

final _md5Prefix = RegExp(r'^[0-9a-fA-F]{32}');

/// 从 QQ 图片文件名里抠出 md5（`{md5}{size}-{w}-{h}.{ext}`）；不是这种
/// 形态（OneBot 给的是别的名字/路径）就返回 null。
String? _md5OfFile(String file) {
  final m = _md5Prefix.firstMatch(file);
  return m?.group(0)?.toLowerCase();
}

String? _kindOf(Segment seg) => switch (seg) {
      ImageSegment() => 'img',
      RecordSegment() => 'voice',
      VideoSegment() => 'video',
      FileSegment() => 'file',
      _ => null,
    };

/// 分类。与 `ChatStore.mediaCategories`（photos/videos/files/voices/other）
/// 一一对应——那个列表是存储用量页的展示顺序，别在这里发明新名字。
String _categoryOf(Segment seg) => switch (seg) {
      ImageSegment() => 'photos',
      VideoSegment() => 'videos',
      RecordSegment() => 'voices',
      FileSegment() => 'files',
      _ => 'other',
    };

String _fileOf(Segment seg) => switch (seg) {
      ImageSegment(:final file) => file,
      RecordSegment(:final file) => file,
      VideoSegment(:final file) => file,
      FileSegment(:final file) => file,
      _ => '',
    };

String _urlOf(Segment seg) {
  String? raw;
  switch (seg) {
    case ImageSegment(:final url):
      raw = url;
    case RecordSegment(:final url):
      raw = url;
    case VideoSegment(:final url):
      raw = url;
    // FileSegment 没有 url 字段：OneBot 的文件要么给本地路径，要么得走
    // 后端 API 下载，当前没有实现，所以这里返回空。
    default:
      return '';
  }
  return usableMediaUrl(raw) ? (raw ?? '') : '';
}

/// 这个地址值不值得拿去下载。
///
/// 历史消息里存着已修复前的坏 URL（`https://gchat.qpic.cn&rkey=…`，主机名被
/// 拼成了 `gchat.qpic.cn&rkey=…`）。直接用它只会白跑一次 DNS 失败，
/// 不如当场判掉、让候选链走到 md5 兜底。
///
/// 判据刻意宽松：只要求 `http(s)://主机[/…]`，且**主机里不能有 `&`、`?`**
/// ——这两个字符出现在主机段就说明是把 query 拼上去了。
bool usableMediaUrl(String? url) {
  if (url == null || url.isEmpty) return true; // 空不是"坏"，是"没有"
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    // file:// 与裸路径都交给 fetcher 自己判断。
    return !url.startsWith('http');
  }
  final host = uri.host;
  return host.isNotEmpty && !host.contains('&') && !host.contains('?');
}

/// 是不是"路径"而不是"文件名"。
///
/// Windows 盘符（`C:`）、Unix 绝对路径（`/data/...`）、相对路径（`./x`）
/// 都算；QQ 的图片名 `{md5}{size}-{w}-{h}.jpg` 与 OneBot 的 `abc.image` 不算。
bool _looksLikePath(String s) =>
    s.contains('/') || s.contains('\\') || s.contains(':');
