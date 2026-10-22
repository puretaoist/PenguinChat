/// L1 基础设施：媒体缓存（把下载到的字节按内容寻址落盘 + 索引）
///
/// ## 它解决什么问题
///
/// QQ / OneBot 给的媒体引用（直链）**会过期**。不落盘的话，聊天记录里三个月
/// 前的图片只剩一个占位框——这是"日用"级别客户端不能接受的。
///
/// 落盘后：字节进 `<dataDir>/media/<分类>/<内容哈希>`，消息库里只留协议原文，
/// 展示时按"引用 → 哈希"查索引拿本地路径。
///
/// ## 为什么不直接用 [BlobStore]
///
/// `BlobStore` 是给"用户主动保存的文件库"用的（`StorageManager` 的 `library.json`
/// 语义：保存 ≠ 复制），它的目录是 `<root>/blobs/<bucket>/<hash>`。
///
/// 媒体缓存要满足另一条约束：**分类必须在路径的第一级**，因为
/// `ChatStore.storageStats()` 与 `pruneMediaCache()` 都按一级子目录聚合/清理
/// （对齐 TG 的"存储用量"页：照片/视频/文件/语音分开报）。
/// 若套用 `BlobStore` 的 `blobs/` 前缀，分类就全塌成 `blobs` 一个桶。
///
/// 所以这里自带一份更薄的实现：同样的"内容寻址 + tmp 再 rename 原子写"，
/// 但路径是 `media/<分类>/<哈希>`。两者生命周期不同（缓存会被清，文件库不会），
/// 分开是合理的。
///
/// ## 索引
///
/// 引用是 URL，文件名是内容哈希——两者之间必须有一张表才能"下载前查重"。
/// 表落在 `<root>/../media_index.json`（**故意放在 media/ 外面**：清缓存只清
/// media/ 目录，索引留着，靠"文件不存在就丢条目"自愈）。
///
/// 索引条目：`{ "f": 文件名, "c": 分类, "n": 字节数, "a": 最后访问毫秒 }`
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

import '../net/media_fetcher.dart';

/// 媒体缓存。
///
/// 所有方法都不抛异常：缓存是尽力而为的东西，失败只应导致"下次再试"。
class MediaCache {
  /// 媒体目录（`<dataDir>/media`）。
  final Directory root;

  /// 索引文件（`<dataDir>/media_index.json`）。
  final File indexFile;

  /// 字节来源；为 null 时只能命中已有文件，不能下载。
  final MediaFetcher? fetcher;

  /// 同时下载的最大数量。移动网上并发太多只会互相拖慢。
  final int maxConcurrent;

  /// 单个文件上限（透传给 [MediaFetcher.fetch]）。
  final int maxBytes;

  final Map<String, _Entry> _entries = <String, _Entry>{};
  final Map<String, Future<String?>> _inflight = <String, Future<String?>>{};
  int _running = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  Timer? _saveDebounce;
  bool _loaded = false;
  bool _disposed = false;

  MediaCache({
    required this.root,
    required this.indexFile,
    this.fetcher,
    this.maxConcurrent = 3,
    this.maxBytes = kDefaultMediaMaxBytes,
  });

  /// 读索引。可重复调用，只生效一次。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!indexFile.existsSync()) return;
      final raw = jsonDecode(await indexFile.readAsString());
      if (raw is! Map) return;
      final entries = raw['entries'];
      if (entries is! Map) return;
      entries.forEach((k, v) {
        if (k is! String || v is! Map) return;
        final f = v['f'];
        final c = v['c'];
        if (f is! String || c is! String) return;
        _entries[k] = _Entry(
          file: f,
          category: c,
          bytes: (v['n'] is num) ? (v['n'] as num).toInt() : 0,
          accessMs: (v['a'] is num) ? (v['a'] as num).toInt() : 0,
        );
      });
    } catch (_) {
      // 索引坏了就当空表：文件还在，只是查不到，会被 prune 当孤儿清掉。
      _entries.clear();
    }
  }

  /// 本地路径（不存在则 null）。命中时刷新访问时间（LRU 依据）。
  String? pathFor(String key) {
    final e = _entries[key];
    if (e == null) return null;
    final f = File('${root.path}${Platform.pathSeparator}${e.category}'
        '${Platform.pathSeparator}${e.file}');
    if (!f.existsSync()) {
      // 自愈：文件被外部删了（清缓存/用户手删），条目立即作废。
      _entries.remove(key);
      _scheduleSave();
      return null;
    }
    e.accessMs = DateTime.now().millisecondsSinceEpoch;
    _scheduleSave();
    return f.path;
  }

  /// 确保 [key] 对应的字节在本地，返回本地路径。
  ///
  /// 命中直接返回；未命中则用 [url] 下载后落盘。同一个 key 的并发请求会合并
  /// 成一个下载（否则列表快速滚动时会重复拉同一张图）。
  Future<String?> ensure({
    required String key,
    required String category,
    required String url,
  }) {
    if (_disposed) return Future<String?>.value();
    final hit = pathFor(key);
    if (hit != null) return Future<String?>.value(hit);
    final running = _inflight[key];
    if (running != null) return running;

    final task = _download(key, category, url).whenComplete(() {
      _inflight.remove(key);
    });
    _inflight[key] = task;
    return task;
  }

  Future<String?> _download(String key, String category, String url) async {
    final f = fetcher;
    if (f == null) return null;
    await _acquire();
    try {
      final bytes = await f.fetch(url, maxBytes: maxBytes);
      if (bytes == null || bytes.isEmpty || _disposed) return null;
      return await _store(key, category, url, bytes);
    } finally {
      _release();
    }
  }

  Future<String?> _store(
      String key, String category, String url, Uint8List bytes) async {
    // 内容寻址：同样的字节在同一分类里只会有一份。
    final hash = _sha256Hex(bytes);
    final ext = _extOf(url);
    final name = '$hash$ext';
    final dir = Directory('${root.path}${Platform.pathSeparator}$category');
    final target = File('${dir.path}${Platform.pathSeparator}$name');

    if (!target.existsSync()) {
      try {
        dir.createSync(recursive: true);
        // 先写临时文件再 rename：中途被杀不会留下半个文件冒充完整缓存。
        final tmp = File('${target.path}.${DateTime.now().microsecondsSinceEpoch}.part');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(target.path);
      } on FileSystemException {
        // 并发下另一个任务可能刚写完同名文件——存在即成功。
        if (!target.existsSync()) return null;
      }
    }

    _entries[key] = _Entry(
      file: name,
      category: category,
      bytes: bytes.length,
      accessMs: DateTime.now().millisecondsSinceEpoch,
    );
    // **新条目立即落盘，不走防抖。**
    //
    // 防抖只适合"访问时间变了"这种丢了也无所谓的信息。新条目不同：文件已经
    // 写进磁盘了，索引没跟上就等于给自己造了一个孤儿——进程被杀、用户强退
    // 之后，这块空间要等下一次 prune 才会被回收，而且期间它无法被任何消息
    // 引用到（等于白下载）。一次索引写只有几百字节，值得同步等。
    await _saveNow();
    return target.path;
  }

  /// 按 LRU 清理到预算内；[keep] 非 null 时先删过期。
  ///
  /// 不在索引里的文件（孤儿）一律删——它们已经无法被任何消息引用到。
  Future<int> prune({Duration? keep, required int maxCacheBytes}) async {
    await load();
    if (!root.existsSync()) return 0;
    var freed = 0;
    final now = DateTime.now();

    // 1) 过期
    if (keep != null) {
      for (final key in _entries.keys.toList()) {
        final e = _entries[key]!;
        final age = now.difference(
            DateTime.fromMillisecondsSinceEpoch(e.accessMs == 0 ? 0 : e.accessMs));
        if (e.accessMs != 0 && age > keep) {
          freed += _deleteFile(e);
          _entries.remove(key);
        }
      }
    }

    // 2) 孤儿（磁盘上有、索引里没有）
    final known = <String>{
      for (final e in _entries.values) '${e.category}${Platform.pathSeparator}${e.file}',
    };
    for (final f in root.listSync(recursive: true)) {
      if (f is! File) continue;
      final rel = f.path.substring(root.path.length + 1);
      if (!known.contains(rel)) {
        freed += _deleteQuietly(f);
      }
    }

    // 3) 超预算：从最久未访问的开始删
    var total = bytes;
    if (total > maxCacheBytes) {
      // 按「文件」排序而不是按「条目」：一个文件被多条引用指向时只该删一次，
      // 且删掉后要把所有指向它的条目一起作废。
      final byFile = _distinctFiles();
      final ordered = byFile.values.toList()
        ..sort((a, b) => a.accessMs.compareTo(b.accessMs));
      for (final e in ordered) {
        if (total <= maxCacheBytes) break;
        freed += _deleteFile(e);
        total -= e.bytes;
        _entries.removeWhere((_, v) => v.file == e.file && v.category == e.category);
      }
    }

    await _saveNow();
    return freed;
  }

  /// 丢掉"文件已不在磁盘上"的索引条目。
  ///
  /// `ChatStore` 有自己的清理逻辑（按保留期/上限遍历目录删文件），它不知道
  /// 索引的存在。清完之后索引会虚报占用，这里把它对齐回真实状态。
  ///
  /// 不抛异常、不写盘——调用方（通常是 prune 之后）自己决定何时 flush。
  int reconcile() {
    var dropped = 0;
    final keys = _entries.keys.toList();
    for (final k in keys) {
      final e = _entries[k]!;
      final f = File('${root.path}${Platform.pathSeparator}${e.category}'
          '${Platform.pathSeparator}${e.file}');
      if (!f.existsSync()) {
        _entries.remove(k);
        dropped++;
      }
    }
    if (dropped > 0) _scheduleSave();
    return dropped;
  }

  /// 清空全部缓存（含索引）。
  Future<int> clear() async {
    var freed = 0;
    if (root.existsSync()) {
      for (final f in root.listSync(recursive: true)) {
        if (f is File) freed += _deleteQuietly(f);
      }
    }
    _entries.clear();
    await _saveNow();
    return freed;
  }

  /// 当前缓存的字节数。
  ///
  /// **按磁盘文件去重**：同一个内容可能被多个 URL 引用（转发、重复发送），
  /// 索引里就有多条指向同一个文件。直接累加条目会把占用虚报成两倍。
  int get bytes => _distinctFiles().values.fold<int>(0, (s, e) => s + e.bytes);

  /// 按分类的字节数（键即 `ChatStore.mediaCategories`）。
  Map<String, int> get bytesByCategory {
    final out = <String, int>{};
    for (final e in _distinctFiles().values) {
      out[e.category] = (out[e.category] ?? 0) + e.bytes;
    }
    return out;
  }

  /// 去重后的文件表：`"<分类>/<文件名>" -> 条目`。
  Map<String, _Entry> _distinctFiles() {
    final out = <String, _Entry>{};
    for (final e in _entries.values) {
      out.putIfAbsent('${e.category}/${e.file}', () => e);
    }
    return out;
  }

  /// 立刻把索引刷到磁盘（测试与退出前用）。
  Future<void> flush() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    await _saveNow();
  }

  void dispose() {
    _disposed = true;
    _saveDebounce?.cancel();
    _saveDebounce = null;
    fetcher?.close();
  }

  // -------------------------------------------------------------------------
  // 内部
  // -------------------------------------------------------------------------

  int _deleteFile(_Entry e) {
    final f = File('${root.path}${Platform.pathSeparator}${e.category}'
        '${Platform.pathSeparator}${e.file}');
    return _deleteQuietly(f);
  }

  int _deleteQuietly(File f) {
    try {
      if (!f.existsSync()) return 0;
      final n = f.lengthSync();
      f.deleteSync();
      return n;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _acquire() async {
    if (_running < maxConcurrent) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _waiters.add(c);
    await c.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _running--;
    }
  }

  void _scheduleSave() {
    if (_disposed) return;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(_saveNow());
    });
  }

  Future<void> _saveNow() async {
    try {
      indexFile.parent.createSync(recursive: true);
      final entries = <String, Object?>{};
      _entries.forEach((k, e) {
        entries[k] = <String, Object?>{
          'f': e.file,
          'c': e.category,
          'n': e.bytes,
          'a': e.accessMs,
        };
      });
      await indexFile.writeAsString(
        jsonEncode(<String, Object?>{'version': 1, 'entries': entries}),
        flush: true,
      );
    } catch (_) {
      // 索引写不进去不该影响聊天。
    }
  }

  /// 扩展名（含点）。URL 末段没有像样扩展名时返回空串。
  ///
  /// 只用于让 `Image.file` / 播放器 / `url_launcher` 有个提示；内容本身靠魔数识别。
  static String _extOf(String url) {
    var path = url;
    final q = path.indexOf('?');
    if (q >= 0) path = path.substring(0, q);
    final slash = path.lastIndexOf('/');
    if (slash >= 0) path = path.substring(slash + 1);
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return '';
    final ext = path.substring(dot + 1).toLowerCase();
    if (ext.length > 5) return '';
    if (!RegExp(r'^[a-z0-9]+$').hasMatch(ext)) return '';
    return '.$ext';
  }

  static String _sha256Hex(List<int> data) {
    // 复用 BlobStore 的哈希（同一套实现，避免两处不一致）。
    return _sha256(data);
  }
}

class _Entry {
  final String file;
  final String category;
  final int bytes;
  int accessMs;

  _Entry({
    required this.file,
    required this.category,
    required this.bytes,
    required this.accessMs,
  });
}

/// SHA-256（十六进制小写）。
///
/// 与 `BlobStore.hashOf` 逐行同款（同一个 pointycastle 实现）。**不要手写哈希**：
/// 手写版出错时表现为"同一个文件算出两个名字"，只会让缓存慢慢长胖，不报错。
String _sha256(List<int> data) {
  final out = SHA256Digest().process(Uint8List.fromList(data));
  final sb = StringBuffer();
  for (final b in out) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
