/// L1 存储：统一存储管理器
///
/// ## 设计要点
///
/// ### 1. 两级语义，一份数据
///
/// ```
///   data/      ← 内容寻址的实际数据（CAS，全应用唯一一份）
///   library/   ← 引用清单：可读名 -> 内容标识（只有几百字节的 JSON）
/// ```
///
/// 关键点：**「保存」不复制数据**。`saveToLibrary` 只往清单里加一条映射，
/// 数据仍只有 `data/` 里的那一份。
///
/// 这一点直接针对官方 QQ 的病灶——官方在 `QQfile_recv/` 收一份、
/// 业务目录再存一份、用户另存到相册又要一份，同一内容最多 3 份。
///
/// 只有用户**显式导出到系统相册/下载目录**时才复制，那是用户主动要求的行为。
///
/// ### 2. 为什么用清单而不是 inode
///
/// 曾考虑用硬链接 + inode 计数来判断「哪些内容还被引用」。
/// 放弃的原因：
///   - Dart 的 `FileStat` 不暴露 inode（`dart:io` 未提供）
///   - 即便调平台接口拿到 inode，跨文件系统硬链接会失败
///   - Android scoped storage 下行为不一致
///
/// 显式清单没有这些问题：可移植、可测试、语义明确。
/// 清单文件很小（每条约 80 字节），一万个条目也不到 1MB。
///
/// ### 3. 缓存与账号解耦
///
/// 路径与清单都不含 UIN。多账号切换时同一份图片/表情只存一份，
/// 不像官方 `.apollo/image_cache/<UIN>/` 那样按账号复制。
///
/// ### 4. 大文件不进缓存
///
/// 超过 [StorageBudget.maxCacheableBytes] 的内容不落盘，只支持流式读取。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'blob_store.dart';
import 'cache_policy.dart';

/// 库中的一条引用。
class LibraryEntry {
  /// 内容标识
  final BlobId id;

  /// 用户可读名
  final String name;

  /// 加入时间
  final DateTime addedAt;

  const LibraryEntry({
    required this.id,
    required this.name,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id.value,
        'name': name,
        'at': addedAt.toIso8601String(),
      };

  static LibraryEntry fromJson(Map<String, dynamic> j) => LibraryEntry(
        id: BlobId(j['id'] as String),
        name: j['name'] as String,
        addedAt: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
      );
}

/// 存储占用快照，用于设置页展示与上报。
class StorageStats {
  /// 缓存区（未被库引用，可回收）字节数。
  final int cacheBytes;

  /// 库区（被库引用，不可自动回收）字节数。
  final int libraryBytes;

  /// 缓存区上限。
  final int budgetBytes;

  /// 去重后的内容条目数。
  final int blobCount;

  /// 库中引用条数。
  final int libraryCount;

  int get totalBytes => cacheBytes + libraryBytes;

  double get usage => budgetBytes == 0 ? 0 : cacheBytes / budgetBytes;

  const StorageStats({
    required this.cacheBytes,
    required this.libraryBytes,
    required this.budgetBytes,
    required this.blobCount,
    required this.libraryCount,
  });

  @override
  String toString() {
    String mb(int b) => '${(b / 1024 / 1024).toStringAsFixed(1)}MB';
    return 'StorageStats(缓存 ${mb(cacheBytes)}/${mb(budgetBytes)} '
        '(${(usage * 100).toStringAsFixed(0)}%), '
        '库 ${mb(libraryBytes)} ($libraryCount 项), '
        '内容 $blobCount 项)';
  }
}

/// 统一存储管理器。
class StorageManager {
  final BlobStore blobs;
  final StorageBudget budget;
  final Directory root;

  StorageManager({
    required this.root,
    StorageBudget? budget,
  })  : budget = budget ?? const StorageBudget(),
        blobs = BlobStore(Directory('${root.path}/data'));

  File get _manifestFile => File('${root.path}/library.json');

  /// 内存中的清单缓存。
  Map<String, LibraryEntry>? _manifest;

  bool _inited = false;

  Future<void> init() async {
    if (_inited) return;
    await root.create(recursive: true);
    await blobs.init();
    await _loadManifest();
    await blobs.sweepTmp();
    _inited = true;
  }

  // ---------------------------------------------------------------
  //  清单读写
  // ---------------------------------------------------------------

  Future<Map<String, LibraryEntry>> _loadManifest() async {
    if (_manifest != null) return _manifest!;
    final out = <String, LibraryEntry>{};
    if (await _manifestFile.exists()) {
      try {
        final raw = await _manifestFile.readAsString();
        final list = jsonDecode(raw) as List<dynamic>;
        for (final item in list) {
          final e = LibraryEntry.fromJson(item as Map<String, dynamic>);
          out[e.name] = e;
        }
      } on FormatException {
        // 清单损坏：重建为空，不阻塞应用启动
        out.clear();
      }
    }
    _manifest = out;
    return out;
  }

  Future<void> _saveManifest() async {
    final m = _manifest ?? {};
    final list = m.values.map((e) => e.toJson()).toList();
    await _manifestFile
        .writeAsString(jsonEncode(list), flush: true);
  }

  // ---------------------------------------------------------------
  //  写入
  // ---------------------------------------------------------------

  /// 存入缓存（可回收）。返回内容标识。
  ///
  /// 超过 [StorageBudget.maxCacheableBytes] 的内容不落盘，返回 null——
  /// 调用方应改为流式读取（[readRange] / [open]）。
  Future<BlobId?> putToCache(List<int> data) async {
    await init();
    if (data.length > budget.maxCacheableBytes) return null;
    final id = await blobs.put(data);
    await evictIfNeeded();
    return id;
  }

  /// 保存到库（用户主动动作，永不自动回收）。
  ///
  /// **不复制数据**，只登记一条引用。
  /// 返回可读名（同名会被覆盖，即重新指向新内容）。
  Future<String> saveToLibrary(BlobId id, String readableName) async {
    await init();
    if (!await blobs.contains(id)) {
      throw StateError('内容不存在：${id.short}');
    }
    final m = await _loadManifest();
    final safe = sanitizeName(readableName);
    m[safe] = LibraryEntry(id: id, name: safe, addedAt: DateTime.now());
    await _saveManifest();
    return safe;
  }

  /// 从库中移除引用。
  ///
  /// 只解除引用，不删数据——数据是否回收交给缓存淘汰决定
  /// （若不再被任何地方引用，后续 LRU 自然会清掉）。
  Future<bool> removeFromLibrary(String name) async {
    await init();
    final m = await _loadManifest();
    final removed = m.remove(name) != null;
    if (removed) await _saveManifest();
    return removed;
  }

  // ---------------------------------------------------------------
  //  读取
  // ---------------------------------------------------------------

  Future<Uint8List?> read(BlobId id) => blobs.get(id);

  /// 按范围读取（流式播放用），不落盘。
  Future<Uint8List?> readRange(BlobId id, int start, int end) =>
      blobs.getRange(id, start, end);

  Future<bool> has(BlobId id) => blobs.contains(id);

  /// 打开文件句柄，供解码器/播放器直接消费，避免整块读入内存。
  Future<File?> open(BlobId id) async {
    final f = blobs.fileOf(id);
    return await f.exists() ? f : null;
  }

  /// 按可读名取内容。
  Future<Uint8List?> readLibrary(String name) async {
    await init();
    final m = await _loadManifest();
    final e = m[name];
    if (e == null) return null;
    return blobs.get(e.id);
  }

  /// 列出库中全部条目（按加入时间倒序）。
  Future<List<LibraryEntry>> listLibrary() async {
    await init();
    final m = await _loadManifest();
    return m.values.toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
  }

  /// 把内容导出到外部路径（用户显式动作，此时才发生真正的复制）。
  ///
  /// 用于「另存到相册 / 下载目录」。返回目标路径。
  Future<String> exportTo(BlobId id, String targetPath) async {
    await init();
    final src = blobs.fileOf(id);
    if (!await src.exists()) {
      throw StateError('内容不存在：${id.short}');
    }
    final dst = File(targetPath);
    await dst.parent.create(recursive: true);
    await src.copy(dst.path);
    return dst.path;
  }

  // ---------------------------------------------------------------
  //  回收
  // ---------------------------------------------------------------

  /// 当前被库引用的内容集合（淘汰时必须跳过）。
  Future<Set<BlobId>> protectedIds() async {
    await init();
    final m = await _loadManifest();
    return m.values.map((e) => e.id).toSet();
  }

  /// 检查是否超预算，超则淘汰。返回本次淘汰情况。
  Future<EvictionResult> evictIfNeeded() async {
    await init();
    final list = await blobs.listAll();
    final total = list.fold<int>(0, (s, e) => s + e.bytes);
    if (total <= budget.highMark) {
      return EvictionResult(
        evictedCount: 0,
        freedBytes: 0,
        remainingBytes: total,
      );
    }

    final pinned = await protectedIds();
    final targets = pickEvictionTargets(list, budget, pinned: pinned);

    var freed = 0;
    var affected = 0;
    for (final id in targets) {
      final f = blobs.fileOf(id);
      if (!await f.exists()) continue;
      final size = await f.length();
      try {
        await f.delete();
        freed += size;
        affected++;
      } on FileSystemException {
        // 被占用，跳过，下一轮再试
        continue;
      }
    }

    return EvictionResult(
      evictedCount: affected,
      freedBytes: freed,
      remainingBytes: total - freed,
    );
  }

  /// 清空缓存区（设置页的「清理缓存」）。
  ///
  /// 只清**未被库引用**的内容。被库引用的必须保留，否则用户的收藏会消失。
  Future<EvictionResult> clearCache() async {
    await init();
    final list = await blobs.listAll();
    final pinned = await protectedIds();

    var freed = 0;
    var count = 0;
    var kept = 0;
    for (final s in list) {
      if (pinned.contains(s.id)) {
        kept += s.bytes;
        continue;
      }
      final f = blobs.fileOf(s.id);
      if (!await f.exists()) continue;
      try {
        await f.delete();
        freed += s.bytes;
        count++;
      } on FileSystemException {
        kept += s.bytes;
        continue;
      }
    }
    return EvictionResult(
      evictedCount: count,
      freedBytes: freed,
      remainingBytes: kept,
    );
  }

  // ---------------------------------------------------------------
  //  统计
  // ---------------------------------------------------------------

  Future<StorageStats> stats() async {
    await init();
    final list = await blobs.listAll();
    final pinned = await protectedIds();
    final m = await _loadManifest();

    // 同一份数据要么算缓存、要么算库，不重复计入
    var cacheBytes = 0;
    var libraryBytes = 0;
    for (final s in list) {
      if (pinned.contains(s.id)) {
        libraryBytes += s.bytes;
      } else {
        cacheBytes += s.bytes;
      }
    }

    return StorageStats(
      cacheBytes: cacheBytes,
      libraryBytes: libraryBytes,
      budgetBytes: budget.cacheBytes,
      blobCount: list.length,
      libraryCount: m.length,
    );
  }

  /// 校验清单完整性：指出指向已不存在内容的条目。
  ///
  /// 正常不该出现（淘汰会跳过被引用的内容），但清单被外部改动过时可能发生。
  /// 提供这个方法便于自检与修复。
  Future<List<String>> findDanglingEntries() async {
    await init();
    final m = await _loadManifest();
    final out = <String>[];
    for (final e in m.values) {
      if (!await blobs.contains(e.id)) out.add(e.name);
    }
    return out;
  }

  /// 清洗用户提供的文件名，防目录穿越。
  static String sanitizeName(String name) {
    final base = name.split(RegExp(r'[/\\]')).last;
    final cleaned = base.replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_');
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return 'unnamed';
    }
    return cleaned.length > 120 ? cleaned.substring(0, 120) : cleaned;
  }
}
