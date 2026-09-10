/// 存储层单元测试
///
/// 运行：flutter test test/storage_test.dart
///
/// 更完整的验证见 `tool/storage_selftest.dart`（纯 Dart，可在任意环境运行）。
/// 本文件覆盖最关键的两条不变式，作为 CI 的第一道闸门。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/infra/storage/blob_store.dart';
import 'package:qqclient/infra/storage/cache_policy.dart';
import 'package:qqclient/infra/storage/storage_manager.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('qqstore_flutter_test_');
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('BlobStore 内容寻址', () {
    test('相同内容得到相同标识且不重复落盘', () async {
      final store = BlobStore(Directory('${tmp.path}/cas'));
      await store.init();

      final id1 = await store.put(List.filled(500, 0x41));
      final id2 = await store.put(List.filled(500, 0x41));

      expect(id1.value, id2.value);
      expect((await store.listAll()).length, 1);
    });

    test('不同内容得到不同标识', () async {
      final store = BlobStore(Directory('${tmp.path}/cas2'));
      await store.init();

      final a = await store.put(List.filled(100, 1));
      final b = await store.put(List.filled(100, 2));
      expect(a.value, isNot(b.value));
    });

    test('范围读取可用于流式消费', () async {
      final store = BlobStore(Directory('${tmp.path}/cas3'));
      await store.init();
      final id = await store.put(List.generate(1000, (i) => i % 256));

      final slice = await store.getRange(id, 100, 110);
      expect(slice, isNotNull);
      expect(slice!.length, 10);
    });
  });

  group('淘汰策略', () {
    test('未超预算时不淘汰', () {
      const budget = StorageBudget(cacheBytes: 1000 * 1024 * 1024);
      final stats = [
        BlobStat(
          id: BlobId('a'.padRight(64, 'a')),
          bytes: 1024,
          lastAccess: DateTime(2026, 1, 1),
        ),
      ];
      expect(pickEvictionTargets(stats, budget), isEmpty);
    });

    test('超预算时优先淘汰最久未访问的', () {
      const budget = StorageBudget(
        cacheBytes: 3 * 1024 * 1024,
        highWatermark: 0.9,
        lowWatermark: 0.5,
      );
      final stats = [
        for (var i = 0; i < 6; i++)
          BlobStat(
            id: BlobId(i.toString().padLeft(64, '0')),
            bytes: 1024 * 1024,
            // i 越大越新
            lastAccess: DateTime(2026, 1, 1).add(Duration(minutes: i)),
          ),
      ];

      final targets = pickEvictionTargets(stats, budget);
      expect(targets, isNotEmpty);
      // 最旧的（index 0，标识为全 0）必须最先被淘汰
      expect(targets.first.value, '0'.padLeft(64, '0'));
      // 最新的（index 5）不应被淘汰
      expect(targets.map((e) => e.value),
          isNot(contains('5'.padLeft(64, '0'))));
    });

    test('受保护内容不参与淘汰', () {
      const budget = StorageBudget(
        cacheBytes: 2 * 1024 * 1024,
        highWatermark: 0.9,
        lowWatermark: 0.5,
      );
      final oldest = BlobId('0'.padLeft(64, '0'));
      final stats = [
        for (var i = 0; i < 6; i++)
          BlobStat(
            id: BlobId(i.toString().padLeft(64, '0')),
            bytes: 1024 * 1024,
            lastAccess: DateTime(2026, 1, 1).add(Duration(minutes: i)),
          ),
      ];

      final targets = pickEvictionTargets(stats, budget, pinned: {oldest});
      expect(targets, isNot(contains(oldest)));
    });
  });

  group('StorageManager 两级语义', () {
    test('保存到库不产生副本', () async {
      final mgr = StorageManager(root: Directory('${tmp.path}/m1'));
      await mgr.init();

      final id = await mgr.putToCache(List.filled(4000, 0x7A));
      final before = await mgr.stats();
      await mgr.saveToLibrary(id!, 'photo.jpg');
      final after = await mgr.stats();

      expect(after.totalBytes, before.totalBytes);
      expect((await mgr.blobs.listAll()).length, 1);
    });

    test('清缓存不破坏库中的收藏', () async {
      final mgr = StorageManager(root: Directory('${tmp.path}/m2'));
      await mgr.init();

      final id = await mgr.putToCache(List.filled(4000, 0x7A));
      await mgr.saveToLibrary(id!, 'keep.jpg');
      await mgr.clearCache();

      final back = await mgr.readLibrary('keep.jpg');
      expect(back, isNotNull);
      expect(back!.length, 4000);
    });

    test('解除引用后可被回收', () async {
      final mgr = StorageManager(root: Directory('${tmp.path}/m3'));
      await mgr.init();

      final id = await mgr.putToCache(List.filled(4000, 0x7A));
      await mgr.saveToLibrary(id!, 'temp.jpg');
      await mgr.removeFromLibrary('temp.jpg');

      final r = await mgr.clearCache();
      expect(r.evictedCount, 1);
    });

    test('超过阈值的内容不入缓存', () async {
      final mgr = StorageManager(
        root: Directory('${tmp.path}/m4'),
        budget: const StorageBudget(maxCacheableBytes: 100),
      );
      await mgr.init();

      expect(await mgr.putToCache(List.filled(50, 1)), isNotNull);
      expect(await mgr.putToCache(List.filled(500, 1)), isNull);
      expect((await mgr.blobs.listAll()).length, 1);
    });

    test('文件名清洗阻止目录穿越', () {
      expect(StorageManager.sanitizeName('../../../etc/passwd'), 'passwd');
      expect(StorageManager.sanitizeName('a/b/c.txt'), 'c.txt');
      expect(StorageManager.sanitizeName('..'), 'unnamed');
      expect(StorageManager.sanitizeName(''), 'unnamed');
    });

    test('清单跨实例持久化', () async {
      final dir = Directory('${tmp.path}/m5');
      final m1 = StorageManager(root: dir);
      await m1.init();
      final id = await m1.putToCache(List.filled(999, 0x33));
      await m1.saveToLibrary(id!, 'persist.bin');

      final m2 = StorageManager(root: dir);
      await m2.init();
      expect((await m2.listLibrary()).length, 1);
      expect((await m2.readLibrary('persist.bin'))!.length, 999);
      expect(await m2.findDanglingEntries(), isEmpty);
    });
  });
}
