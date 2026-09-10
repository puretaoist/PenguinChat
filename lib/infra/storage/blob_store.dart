/// L1 存储：内容寻址存储（CAS）
///
/// ## 为什么用内容寻址
///
/// 官方 QQ 的存储问题不是「缓存太大」，而是**同一份数据被存了多次**：
///
/// | 官方做法 | 后果 |
/// |---|---|
/// | `chatpic/` + `.thumbnails/` + `head/` 各存一份同一张图 | 一张图 3 份 |
/// | `QQfile_recv/emoj` 与 `.tmpsysemotion` 分头存表情 | 一个表情多份 |
/// | `.apollo/image_cache/<UIN>/` 按账号建目录 | N 个账号 = N 份缓存 |
/// | `businessCacheSizeWeight` 各业务独立配额 | 无全局预算，谁也管不住谁 |
///
/// 内容寻址可以一次性消掉前三类问题：
///   - **路径由内容决定**：`files/ab/abcdef…`，同一内容永远同一路径 → 天然去重
///   - **与账号无关**：缓存目录不含 UIN，多账号共享 → 切号不重复下载
///   - **无需人工分类**：不管图片/表情/视频，全都按哈希落盘，不为每类建目录
///
/// 代价是失去可读的文件名。解决方法见 [StorageManager]：
/// 用户主动保存的文件用**硬链接**在外层给一个有名字的入口，
/// 底层数据仍然只有一份。
///
/// 对应 Telegram：TDLib 的 `FileManager` 亦为内容寻址 + 引用计数。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

/// 内容标识：SHA-256 的十六进制小写形式。
extension type const BlobId(String value) {
  /// 分桶前缀（前 2 位十六进制）。
  ///
  /// 目的：避免单目录下堆积几十万文件——ext4/EROFS 在单目录项过多时
  /// 查找会退化为线性扫描。两级分桶把单目录规模压到 1/256。
  String get bucket => value.substring(0, 2);

  /// 人类可读短形式，用于日志。
  String get short => value.substring(0, 12);
}

/// 内容寻址存储。
///
/// 目录布局（[root] 之下）：
/// ```
///   <root>/
///     blobs/ab/abcdef0123…    实际数据，文件名即内容哈希
///     tmp/                    写入中转（先写这里再 rename，保证原子性）
/// ```
class BlobStore {
  final Directory root;

  BlobStore(this.root);

  Directory get _blobDir => Directory('${root.path}/blobs');
  Directory get _tmpDir => Directory('${root.path}/tmp');

  bool _ready = false;

  /// 创建目录结构。幂等。
  Future<void> init() async {
    if (_ready) return;
    await _blobDir.create(recursive: true);
    await _tmpDir.create(recursive: true);
    _ready = true;
  }

  /// 计算内容标识。
  static BlobId hashOf(List<int> data) {
    final d = SHA256Digest();
    final out = d.process(Uint8List.fromList(data));
    final sb = StringBuffer();
    for (final b in out) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return BlobId(sb.toString());
  }

  /// 某内容的落盘路径。
  File fileOf(BlobId id) =>
      File('${_blobDir.path}/${id.bucket}/${id.value}');

  /// 是否已存在。
  Future<bool> contains(BlobId id) => fileOf(id).exists();

  /// 写入数据，返回内容标识。
  ///
  /// 若内容已存在则**不重复写**（去重的关键路径），直接返回。
  ///
  /// 写入采用「先写 tmp 再 rename」：rename 在同一文件系统内是原子的，
  /// 避免进程被杀时留下半截文件被后续读到。
  Future<BlobId> put(List<int> data) async {
    await init();
    final id = hashOf(data);
    final target = fileOf(id);
    if (await target.exists()) return id;

    await target.parent.create(recursive: true);
    final tmp = File(
        '${_tmpDir.path}/${id.value}.${DateTime.now().microsecondsSinceEpoch}.part');
    await tmp.writeAsBytes(data, flush: true);
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      // 并发写入时可能已被别的任务 rename 成功；此时删掉自己的临时文件即可
      if (await target.exists()) {
        await tmp.delete();
        return id;
      }
      rethrow;
    }
    return id;
  }

  /// 读取全部内容。不存在返回 null。
  Future<Uint8List?> get(BlobId id) async {
    final f = fileOf(id);
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  /// 只取一部分（用于流式播放的头几秒、图片渐进显示）。
  Future<Uint8List?> getRange(BlobId id, int start, int end) async {
    final f = fileOf(id);
    if (!await f.exists()) return null;
    final raf = await f.open();
    try {
      await raf.setPosition(start);
      return await raf.read(end - start);
    } finally {
      await raf.close();
    }
  }

  /// 删除某内容。
  Future<void> remove(BlobId id) async {
    final f = fileOf(id);
    if (await f.exists()) await f.delete();
  }

  /// 遍历全部内容，返回 (标识, 字节数, 最后访问时间)。
  ///
  /// 供 [StorageManager] 做容量统计与淘汰决策。
  Future<List<BlobStat>> listAll() async {
    await init();
    final out = <BlobStat>[];
    if (!await _blobDir.exists()) return out;
    await for (final bucket in _blobDir.list()) {
      if (bucket is! Directory) continue;
      await for (final f in bucket.list()) {
        if (f is! File) continue;
        final st = await f.stat();
        out.add(BlobStat(
          id: BlobId(f.uri.pathSegments.last),
          bytes: st.size,
          lastAccess: st.accessed,
        ));
      }
    }
    return out;
  }

  /// 清理中断遗留的临时文件。
  Future<int> sweepTmp({Duration olderThan = const Duration(hours: 1)}) async {
    await init();
    final now = DateTime.now();
    var n = 0;
    await for (final f in _tmpDir.list()) {
      if (f is! File) continue;
      final st = await f.stat();
      if (now.difference(st.modified) > olderThan) {
        await f.delete();
        n++;
      }
    }
    return n;
  }
}

/// 单个内容的统计信息。
class BlobStat {
  final BlobId id;
  final int bytes;
  final DateTime lastAccess;

  const BlobStat({
    required this.id,
    required this.bytes,
    required this.lastAccess,
  });
}
