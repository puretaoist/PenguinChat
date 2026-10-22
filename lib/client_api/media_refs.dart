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

  const MediaRef({
    required this.key,
    required this.category,
    required this.url,
  });

  @override
  String toString() => 'MediaRef($category, $key -> $url)';
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
  );
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

String _urlOf(Segment seg) => switch (seg) {
      ImageSegment(:final url) => url ?? '',
      RecordSegment(:final url) => url ?? '',
      VideoSegment(:final url) => url ?? '',
      // FileSegment 没有 url 字段：OneBot 的文件要么给本地路径，要么得走
      // 后端 API 下载，当前没有实现，所以这里返回空。
      FileSegment() => '',
      _ => '',
    };

/// 是不是"路径"而不是"文件名"。
///
/// Windows 盘符（`C:`）、Unix 绝对路径（`/data/...`）、相对路径（`./x`）
/// 都算；QQ 的图片名 `{md5}{size}-{w}-{h}.jpg` 与 OneBot 的 `abc.image` 不算。
bool _looksLikePath(String s) =>
    s.contains('/') || s.contains('\\') || s.contains(':');
