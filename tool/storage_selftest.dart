/// 存储层自测（纯 Dart，不依赖 Flutter 引擎）
///
/// 运行：dart run tool/storage_selftest.dart
///
/// 重点验证两条「官方 QQ 没做住」的约束：
///   1. 同一内容不重复存储（含多账号场景）
///   2. 淘汰不会破坏用户收藏（库引用受保护）
// ignore_for_file: avoid_print, avoid_relative_lib_imports
library;

import 'dart:io';
import 'dart:typed_data';

import '../lib/infra/storage/blob_store.dart';
import '../lib/infra/storage/cache_policy.dart';
import '../lib/infra/storage/storage_manager.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    print('  [OK] $name');
  } else {
    _failed++;
    print('  [FAIL] $name${detail == null ? '' : ' -> $detail'}');
  }
}

Future<void> main() async {
  print('=== 存储层自测 ===');

  final tmp = Directory.systemTemp.createTempSync('qqstore_test_');
  print('临时目录: ${tmp.path}\n');

  try {
    // ---------------------------------------------------------------
    print('[CAS] 内容寻址与去重');
    {
      final store = BlobStore(Directory('${tmp.path}/cas'));
      await store.init();

      final a = Uint8List.fromList(List.filled(1000, 0x41));
      final b = Uint8List.fromList(List.filled(1000, 0x41)); // 内容相同
      final c = Uint8List.fromList(List.filled(1000, 0x42)); // 内容不同

      final idA = await store.put(a);
      final idB = await store.put(b);
      final idC = await store.put(c);

      check('相同内容 -> 相同标识', idA.value == idB.value);
      check('不同内容 -> 不同标识', idA.value != idC.value);
      check('标识为 64 位十六进制（SHA-256）', idA.value.length == 64);
      check('分桶前缀为前 2 位', idA.bucket == idA.value.substring(0, 2));

      final all = await store.listAll();
      check('去重生效：两个不同内容只有 2 个文件', all.length == 2,
          '实际 ${all.length}');

      final back = await store.get(idA);
      check('内容可完整取回', back != null && back.length == 1000);

      final part = await store.getRange(idA, 10, 20);
      check('范围读取长度正确', part != null && part.length == 10);
      check('范围读取内容正确', part != null && part.every((x) => x == 0x41));

      final stale = File('${tmp.path}/cas/tmp/leftover.part');
      await stale.writeAsBytes([1, 2, 3]);
      // 用修改时间而非访问时间：access time 在多数文件系统上被 noatime 挂载项忽略
      await stale.setLastModified(
          DateTime.now().subtract(const Duration(hours: 2)));
      final fresh = File('${tmp.path}/cas/tmp/fresh.part');
      await fresh.writeAsBytes([4, 5, 6]);

      final swept = await store.sweepTmp();
      check('清理过期临时文件', swept == 1, '清理 $swept 个');
      check('未过期的临时文件保留', await fresh.exists());
      check('过期临时文件已删除', !await stale.exists());
    }

    // ---------------------------------------------------------------
    print('\n[预算] 全局单一预算与 LRU 淘汰');
    {
      final stats = <BlobStat>[];
      for (var i = 0; i < 10; i++) {
        stats.add(BlobStat(
          id: BlobId(i.toString().padLeft(64, '0')),
          bytes: 1024 * 1024,
          lastAccess: DateTime(2026, 1, 1).add(Duration(minutes: i)),
        ));
      }

      final budget = StorageBudget(
        cacheBytes: 5 * 1024 * 1024,
        highWatermark: 0.9,
        lowWatermark: 0.7,
      );

      check('高水位 = 90%', budget.highMark == (5 * 1024 * 1024 * 0.9).round());
      check('低水位 = 70%', budget.lowMark == (5 * 1024 * 1024 * 0.7).round());

      final evictor = LruEvictor(budget);
      check('10MB > 高水位，需要淘汰', evictor.shouldEvict(10 * 1024 * 1024));
      check('4MB < 高水位，无需淘汰', !evictor.shouldEvict(4 * 1024 * 1024));

      final targets = pickEvictionTargets(stats, budget);
      check('淘汰目标非空', targets.isNotEmpty);

      final kept = stats.where((s) => !targets.contains(s.id)).length;
      check('淘汰后降到低水位以内', kept * 1024 * 1024 <= budget.lowMark,
          '保留 ${kept}MB，低水位 ${budget.lowMark ~/ 1024 ~/ 1024}MB');

      final pinned = {stats.first.id};
      final t2 = pickEvictionTargets(stats, budget, pinned: pinned);
      check('受保护项不出现在淘汰列表', !t2.contains(stats.first.id));

      final r = evictor.evict(stats);
      check('淘汰结果可读', r.toString().contains('淘汰'));
    }

    // ---------------------------------------------------------------
    print('\n[两级] 库引用：保存不复制数据');
    {
      final mgr = StorageManager(
        root: Directory('${tmp.path}/mgr'),
        budget: const StorageBudget(cacheBytes: 10 * 1024 * 1024),
      );
      await mgr.init();

      final data = Uint8List.fromList(List.filled(5000, 0x7A));
      final id = await mgr.putToCache(data);
      check('存入缓存成功', id != null);

      final before = await mgr.stats();
      final name = await mgr.saveToLibrary(id!, '我的照片.jpg');
      final after = await mgr.stats();

      check('保存返回可读名', name == '我的照片.jpg', name);
      check('保存后条目数 +1', after.libraryCount == before.libraryCount + 1);
      check('保存后总字节数不变（未复制）',
          after.totalBytes == before.totalBytes,
          '${before.totalBytes} -> ${after.totalBytes}');

      // 磁盘上仍只有 1 个数据文件
      final files = await mgr.blobs.listAll();
      check('磁盘上仍只有 1 份数据', files.length == 1, '实际 ${files.length}');

      // 按可读名能取回
      final back = await mgr.readLibrary('我的照片.jpg');
      check('按可读名取回内容', back != null && back.length == 5000);

      // 关键：清缓存不能破坏用户收藏
      final cleared = await mgr.clearCache();
      check('清缓存跳过被库引用的内容', cleared.evictedCount == 0,
          '误删 ${cleared.evictedCount} 项');
      final stillThere = await mgr.readLibrary('我的照片.jpg');
      check('收藏内容仍可读', stillThere != null && stillThere.length == 5000);

      // 解除引用后才会被清掉
      await mgr.removeFromLibrary('我的照片.jpg');
      final cleared2 = await mgr.clearCache();
      check('解除引用后可被清理', cleared2.evictedCount == 1,
          '清理 ${cleared2.evictedCount} 项');

      // 文件名清洗（内容已在上一步被清理，重新存一份）
      final id2 = await mgr.putToCache(data);
      final tricky = await mgr.saveToLibrary(id2!, '../../../etc/passwd');
      check('目录穿越被清洗',
          !tricky.contains('..') && tricky == 'passwd', tricky);
    }

    // ---------------------------------------------------------------
    print('\n[去重] 多账号/多次收到同一内容');
    {
      final mgr = StorageManager(root: Directory('${tmp.path}/acct'));
      await mgr.init();
      final img = Uint8List.fromList(List.filled(2048, 0x11));

      final idA = await mgr.putToCache(img);
      final idB = await mgr.putToCache(img);

      check('同一图片两次入库 -> 一个标识', idA!.value == idB!.value);
      final all = await mgr.blobs.listAll();
      check('磁盘上只有 1 份', all.length == 1, '实际 ${all.length}');

      final st = await mgr.stats();
      check('统计条目数为 1', st.blobCount == 1);
      check('统计字符串可读', st.toString().contains('StorageStats'));
    }

    // ---------------------------------------------------------------
    print('\n[大文件] 不落盘，只允许流式');
    {
      final mgr = StorageManager(
        root: Directory('${tmp.path}/big'),
        budget: const StorageBudget(
          cacheBytes: 10 * 1024 * 1024,
          maxCacheableBytes: 1024,
        ),
      );
      await mgr.init();

      final small = await mgr.putToCache(List.filled(500, 1));
      check('小文件可入缓存', small != null);

      final big = await mgr.putToCache(List.filled(2000, 1));
      check('大文件被拒绝入缓存（返回 null）', big == null);

      final all = await mgr.blobs.listAll();
      check('大文件确实未落盘', all.length == 1, '实际 ${all.length}');
    }

    // ---------------------------------------------------------------
    print('\n[统计] 缓存与库的划分');
    {
      final mgr = StorageManager(root: Directory('${tmp.path}/stats'));
      await mgr.init();

      final cached = await mgr.putToCache(List.filled(1000, 0x01));
      final saved = await mgr.putToCache(List.filled(2000, 0x02));
      await mgr.saveToLibrary(saved!, 'saved.bin');

      final st = await mgr.stats();
      check('库区字节数 = 被引用内容大小', st.libraryBytes == 2000,
          '${st.libraryBytes}');
      check('缓存区字节数 = 未引用内容大小', st.cacheBytes == 1000,
          '${st.cacheBytes}');
      check('总量 = 缓存 + 库', st.totalBytes == 3000, '${st.totalBytes}');
      check('使用率在 0~1', st.usage >= 0 && st.usage <= 1);
      check('缓存未引用项仍在', await mgr.has(cached!));
    }

    // ---------------------------------------------------------------
    print('\n[持久化] 清单跨重启保持');
    {
      final dir = Directory('${tmp.path}/persist');
      final m1 = StorageManager(root: dir);
      await m1.init();
      final id = await m1.putToCache(List.filled(777, 0x33));
      await m1.saveToLibrary(id!, 'persist.bin');

      // 模拟重启：新建实例读同一目录
      final m2 = StorageManager(root: dir);
      await m2.init();
      final list = await m2.listLibrary();
      check('重启后清单仍在', list.length == 1, '${list.length}');
      check('重启后条目名正确', list.first.name == 'persist.bin');
      check('重启后内容可读',
          (await m2.readLibrary('persist.bin'))?.length == 777);

      final dangling = await m2.findDanglingEntries();
      check('无悬空引用', dangling.isEmpty, dangling.join(','));
    }

    // ---------------------------------------------------------------
    print('\n[导出] 显式导出才复制');
    {
      final mgr = StorageManager(root: Directory('${tmp.path}/export'));
      await mgr.init();
      final id = await mgr.putToCache(List.filled(300, 0x55));

      final out = '${tmp.path}/export_target/out.bin';
      await mgr.exportTo(id!, out);
      check('导出文件存在', await File(out).exists());
      check('导出内容长度正确', (await File(out).length()) == 300);

      final st = await mgr.stats();
      check('导出不影响内部统计（内部仍 1 份）', st.blobCount == 1);
    }
  } finally {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  }

  print('\n=== 结果: $_passed 通过, $_failed 失败 ===');
  if (_failed > 0) {
    throw StateError('存在失败用例');
  }
  print('全部通过 ✓ 存储层可用');
}
