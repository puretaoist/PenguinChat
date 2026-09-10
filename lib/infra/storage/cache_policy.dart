/// L1 存储：容量预算与淘汰策略
///
/// ## 相对官方的关键差异
///
/// 官方 QQ 的缓存配额是**按业务线分配权重**的（配置键 `businessCacheSizeWeight`、
/// `commonCacheMaxSizeRatio`）。问题在于：
///
///   1. 权重之和由谁保证？各业务自行申报，总量不可控
///   2. 业务新增就要改配额，没人回收旧配额
///   3. 用户在设置里只能看到「清理缓存」一个按钮，无法按需控制
///
/// 本实现改为**单一全局预算**：一个数字决定整个缓存区上限，
/// 所有内容（图片/表情/视频/文件）共用同一个池子，按 LRU 竞争。
/// 好处是「总量可证明有界」——不管业务怎么长，占用不会突破预算。
///
/// ## 淘汰规则
///
/// 淘汰单位是**内容**（blob），不是文件路径。因此：
///   - 同一内容被多处引用时只需淘汰一次
///   - 淘汰不影响「已保存到相册」的文件（那是外层硬链接，见 StorageManager）
library;

import 'blob_store.dart';

/// 容量预算。
class StorageBudget {
  /// 缓存区上限（字节）。超出即触发淘汰。
  ///
  /// 默认 512MB —— 参考 Telegram 的默认缓存档位量级。
  /// 这一项就是「用一段时间会不会涨到 10G」的唯一决定因素：
  /// 只要这里是 512MB，占用就不可能超过它。
  final int cacheBytes;

  /// 单文件超过此大小则不进入缓存，只支持按需流式读取。
  ///
  /// 目的：避免一个 2GB 的视频把整个缓存预算挤爆。
  /// 官方 QQ 会把视频整段落盘（`shortvideo/`、`video_story/` 各一份），
  /// 这是体积失控的主要来源之一。
  final int maxCacheableBytes;

  /// 缓存水位：占用超过该比例即开始淘汰（避免每次都跑满才清）。
  final double highWatermark;

  /// 淘汰后降到该比例（一次性多清一些，减少淘汰频率）。
  final double lowWatermark;

  const StorageBudget({
    this.cacheBytes = 512 * 1024 * 1024,
    this.maxCacheableBytes = 64 * 1024 * 1024,
    this.highWatermark = 0.90,
    this.lowWatermark = 0.70,
  }) : assert(highWatermark > lowWatermark, '高水位必须高于低水位');

  /// 便捷构造：以 MB 指定上限。
  factory StorageBudget.mb(int mb) =>
      StorageBudget(cacheBytes: mb * 1024 * 1024);

  int get highMark => (cacheBytes * highWatermark).round();
  int get lowMark => (cacheBytes * lowWatermark).round();
}

/// 淘汰结果，便于上报与测试断言。
class EvictionResult {
  final int evictedCount;
  final int freedBytes;
  final int remainingBytes;

  const EvictionResult({
    required this.evictedCount,
    required this.freedBytes,
    required this.remainingBytes,
  });

  @override
  String toString() => '淘汰 $evictedCount 项，释放 ${_mb(freedBytes)}，'
      '剩余 ${_mb(remainingBytes)}';

  static String _mb(int b) => '${(b / 1024 / 1024).toStringAsFixed(1)}MB';
}

/// LRU 淘汰器。
///
/// 按「最后访问时间」升序淘汰，直到降到低水位。
class LruEvictor {
  final StorageBudget budget;

  /// 受保护的内容（正在播放/正在上传），本轮不参与淘汰。
  final Set<BlobId> pinned = {};

  LruEvictor(this.budget);

  /// 是否需要淘汰。
  bool shouldEvict(int currentBytes) => currentBytes > budget.highMark;

  /// 执行淘汰。
  ///
  /// [stats] 来自 [BlobStore.listAll]。
  /// 返回实际淘汰情况；`freedBytes` 用于上报。
  EvictionResult evict(List<BlobStat> stats) {
    final total = stats.fold<int>(0, (s, e) => s + e.bytes);
    if (!shouldEvict(total)) {
      return EvictionResult(
        evictedCount: 0,
        freedBytes: 0,
        remainingBytes: total,
      );
    }

    // 最久未访问的排前面
    final candidates = stats.where((s) => !pinned.contains(s.id)).toList()
      ..sort((a, b) => a.lastAccess.compareTo(b.lastAccess));

    var freed = 0;
    var count = 0;
    var remaining = total;
    for (final c in candidates) {
      if (remaining <= budget.lowMark) break;
      freed += c.bytes;
      remaining -= c.bytes;
      count++;
    }

    return EvictionResult(
      evictedCount: count,
      freedBytes: freed,
      remainingBytes: remaining,
    );
  }
}

/// 淘汰器需要删掉的那批内容（与 [LruEvictor.evict] 配套使用）。
///
/// 拆成两步是为了让调用方自己决定删除顺序与失败处理，
/// 而不是让淘汰器直接持有 IO 能力——便于单测。
List<BlobId> pickEvictionTargets(
  List<BlobStat> stats,
  StorageBudget budget, {
  Set<BlobId> pinned = const {},
}) {
  final total = stats.fold<int>(0, (s, e) => s + e.bytes);
  if (total <= budget.highMark) return const [];

  final candidates = stats.where((s) => !pinned.contains(s.id)).toList()
    ..sort((a, b) => a.lastAccess.compareTo(b.lastAccess));

  final out = <BlobId>[];
  var remaining = total;
  for (final c in candidates) {
    if (remaining <= budget.lowMark) break;
    out.add(c.id);
    remaining -= c.bytes;
  }
  return out;
}
