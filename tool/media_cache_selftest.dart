/// 媒体缓存自测（纯 Dart，不依赖 Flutter 引擎）
///
/// 运行：dart run tool/media_cache_selftest.dart
///
/// 为什么起一个真的本地 HTTP 服务而不是打桩 [MediaFetcher]：
/// 落盘这条链上最容易出错的恰恰是**网络那一侧**——重定向、非 2xx、chunked、
/// 超大响应、连接被掐。把 fetcher 换成假的就把这些全跳过了，测完还是不知道
/// 真机上会不会崩。所以这里用 `HttpServer.bind(127.0.0.1, 0)` 起真服务，
/// 各路径按需返回，全程不出网。
// ignore_for_file: avoid_print, avoid_relative_lib_imports
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../lib/infra/net/media_fetcher.dart';
import '../lib/infra/storage/media_cache.dart';

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

/// 本地测试服务器。路径即行为：
///   /img/a.jpg   -> 200 + 固定的 100 字节
///   /img/b.jpg   -> 200 + 与 /img/a.jpg **内容相同**（验证按内容去重）
///   /img/c.jpg   -> 200 + 不同内容
///   /404         -> 404
///   /big         -> 声明并返回 2 MiB（验证 maxBytes 拦截）
///   /empty       -> 200 但 0 字节
///   /redirect    -> 302 到 /img/a.jpg
///   /slow        -> 延迟 300ms 后返回（验证并发合并）
int _flakyHits = 0;

Future<HttpServer> _serve() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    switch (req.uri.path) {
      case '/img/a.jpg':
        res.add(Uint8List.fromList(List<int>.filled(100, 0xAA)));
      case '/img/b.jpg':
        res.add(Uint8List.fromList(List<int>.filled(100, 0xAA)));
      case '/img/c.jpg':
        res.add(Uint8List.fromList(List<int>.filled(100, 0xBB)));
      case '/404':
        res.statusCode = 404;
        res.write('nope');
      case '/big':
        res.contentLength = 2 * 1024 * 1024;
        res.add(Uint8List.fromList(List<int>.filled(2 * 1024 * 1024, 1)));
      case '/empty':
        break;
      case '/redirect':
        res.statusCode = 302;
        res.headers.set('location', '/img/a.jpg');
      case '/slow':
        await Future<void>.delayed(const Duration(milliseconds: 300));
        res.add(Uint8List.fromList(List<int>.filled(50, 0xCC)));
      // 真机抓到的那三种拒绝形态 + 限流，用来验失败分类
      case '/expired':
        res.statusCode = 400;
        res.write('{"retcode":-5503007,"retmsg":"download url has expired"}');
      case '/rejected':
        res.statusCode = 400;
        res.write('{"retcode":-5503010,"retmsg":"invalid rkey"}');
      case '/rate':
        res.statusCode = 429;
        res.write('slow down');
      case '/flaky':
        // 前两次 500，第三次 200：验网络错误的退避重试
        _flakyHits++;
        if (_flakyHits <= 2) {
          res.statusCode = 500;
          res.write('boom');
        } else {
          res.add(Uint8List.fromList(List<int>.filled(77, 0xDD)));
        }
      default:
        res.statusCode = 404;
    }
    await res.close();
  });
  return server;
}

/// 计数用的包装，验证"同一个 key 并发只下载一次"。
class _CountingFetcher extends MediaFetcher {
  final MediaFetcher inner;
  int calls = 0;
  bool closed = false;
  _CountingFetcher(this.inner);

  @override
  Future<Uint8List?> fetch(String url, {int maxBytes = kDefaultMediaMaxBytes}) {
    calls++;
    return inner.fetch(url, maxBytes: maxBytes);
  }

  @override
  void close() {
    closed = true;
    inner.close();
  }
}

/// 计数的 fetchOutcome 包装：验证"负缓存命中时不再发请求"。
///
/// 注意必须覆盖 [fetchOutcome] 而不是只覆盖 [fetch] —— MediaCache 只调前者，
/// 只覆盖 fetch 的包装会让每次调用都落到基类默认实现（分类恒为 unknown）。
class _OutcomeCounter extends MediaFetcher {
  final MediaFetcher inner;
  int calls = 0;
  final List<String> urls = [];
  _OutcomeCounter(this.inner);

  @override
  Future<Uint8List?> fetch(String url, {int maxBytes = kDefaultMediaMaxBytes}) =>
      inner.fetch(url, maxBytes: maxBytes);

  @override
  Future<MediaFetchOutcome> fetchOutcome(String url,
      {int maxBytes = kDefaultMediaMaxBytes}) {
    calls++;
    urls.add(url);
    return inner.fetchOutcome(url, maxBytes: maxBytes);
  }

  @override
  void close() => inner.close();
}

Future<void> main() async {
  print('=== 媒体缓存自测 ===');

  final tmp = Directory.systemTemp.createTempSync('qqmedia_test_');
  print('临时目录: ${tmp.path}\n');
  final server = await _serve();
  final base = 'http://127.0.0.1:${server.port}';

  try {
    // ---------------------------------------------------------------
    print('[fetcher] HTTP 取字节');
    {
      final f = HttpMediaFetcher();
      final a = await f.fetch('$base/img/a.jpg');
      check('200 -> 拿到字节', a != null && a.length == 100, '${a?.length}');
      check('内容正确', a != null && a.every((x) => x == 0xAA));

      final missing = await f.fetch('$base/404');
      check('404 -> null（不抛）', missing == null);

      final empty = await f.fetch('$base/empty');
      check('0 字节 -> null（空文件没有缓存价值）', empty == null);

      final redirected = await f.fetch('$base/redirect');
      check('302 跟随重定向', redirected != null && redirected.length == 100,
          '${redirected?.length}');

      final big = await f.fetch('$base/big', maxBytes: 1024);
      check('超过 maxBytes -> null（声明长度就拦）', big == null);

      final unreachable = await f.fetch('http://127.0.0.1:1/x');
      check('连不上 -> null（不抛）', unreachable == null);

      check('空串 -> null', await f.fetch('') == null);
      check('未知协议 -> null', await f.fetch('ftp://x/y') == null);
      f.close();
    }

    // ---------------------------------------------------------------
    print('\n[fetcher] 本地文件');
    {
      final f = HttpMediaFetcher();
      final local = File('${tmp.path}/local.bin')
        ..writeAsBytesSync(List<int>.filled(42, 7));
      final byPath = await f.fetch(local.path);
      check('裸路径可读', byPath != null && byPath.length == 42);
      final byUri = await f.fetch(Uri.file(local.path).toString());
      check('file:// 可读', byUri != null && byUri.length == 42);
      check('不存在的路径 -> null', await f.fetch('${tmp.path}/nope.bin') == null);
      f.close();
    }

    // ---------------------------------------------------------------
    print('\n[MediaCache] 下载与命中');
    final mediaRoot = Directory('${tmp.path}/media');
    final indexFile = File('${tmp.path}/media_index.json');
    final counting = _CountingFetcher(HttpMediaFetcher());
    final cache = MediaCache(
      root: mediaRoot,
      indexFile: indexFile,
      fetcher: counting,
    );
    await cache.load();
    {
      final p1 = await cache.ensure(
          key: 'k-a', category: 'photos', url: '$base/img/a.jpg');
      check('首次 ensure 下载并返回本地路径', p1 != null && File(p1).existsSync(),
          p1);
      check('落盘路径带分类目录', p1 != null && p1.contains('photos'));
      check('一次下载只发一次请求', counting.calls == 1, '${counting.calls}');

      final p2 = await cache.ensure(
          key: 'k-a', category: 'photos', url: '$base/img/a.jpg');
      check('二次 ensure 命中缓存，路径相同', p1 == p2);
      check('命中不重复下载', counting.calls == 1, '${counting.calls}');

      check('pathFor 命中', cache.pathFor('k-a') == p1);
      check('未知 key 的 pathFor 为 null', cache.pathFor('nope') == null);

      // 并发合并：同一个 key 同时来 5 个请求
      final before = counting.calls;
      final burst = await Future.wait(List.generate(
          5,
          (_) => cache.ensure(
              key: 'k-c', category: 'photos', url: '$base/img/c.jpg')));
      check('并发 5 个 ensure 全部成功',
          burst.every((p) => p != null && File(p).existsSync()));
      check('并发合并：只下载 1 次', counting.calls == before + 1,
          'calls=${counting.calls} before=$before');
      check('并发结果路径一致', burst.toSet().length == 1);
    }

    // ---------------------------------------------------------------
    print('\n[MediaCache] 内容去重');
    {
      final pA = cache.pathFor('k-a');
      await cache.ensure(
          key: 'k-b', category: 'photos', url: '$base/img/b.jpg');
      final pB = cache.pathFor('k-b');
      check('不同 URL 但内容相同 -> 同一个文件', pA == pB, '$pA vs $pB');
      final files = mediaRoot
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.jpg') || f.path.contains('photos'))
          .toList();
      check('磁盘上只有一个物理文件（a.jpg 与 c.jpg 各一份）', files.length == 2,
          '实际 ${files.length}: ${files.map((f) => f.path.split(Platform.pathSeparator).last)}');
      check('字节数按文件去重（2 个文件 100+100）', cache.bytes == 200,
          '${cache.bytes}');
      check('按分类统计', cache.bytesByCategory['photos'] == 200,
          '${cache.bytesByCategory}');
    }

    // ---------------------------------------------------------------
    print('\n[MediaCache] 索引持久化');
    {
      await cache.flush();
      final reloaded = MediaCache(
        root: mediaRoot,
        indexFile: indexFile,
        fetcher: null, // 刻意不给 fetcher：只能靠索引 + 磁盘
      );
      await reloaded.load();
      check('新实例从索引恢复', reloaded.pathFor('k-a') != null);
      check('新实例字节数一致', reloaded.bytes == 200, '${reloaded.bytes}');
      check('没有 fetcher 时未命中项返回 null',
          await reloaded.ensure(
                  key: 'k-zzz', category: 'photos', url: '$base/img/a.jpg') ==
              null);
      reloaded.dispose();
    }

    // ---------------------------------------------------------------
    print('\n[MediaCache] 失败与边界');
    {
      final miss = await cache.ensure(
          key: 'k-404', category: 'photos', url: '$base/404');
      check('404 不落盘、返回 null', miss == null);
      check('失败不留索引条目', cache.pathFor('k-404') == null);

      // ⚠️ 必须用 maxBytes 很小的实例：cache 的默认上限是 64 MiB，
      // 2 MiB 的响应根本不会被拦（我第一版就写错成用 cache，结果它真下载了
      // 2 MiB 并落盘，后面「超预算清理」用例因此全崩）。
      final tiny = MediaCache(
        root: Directory('${tmp.path}/media_tiny'),
        indexFile: File('${tmp.path}/media_tiny_index.json'),
        fetcher: HttpMediaFetcher(),
        maxBytes: 1024,
      );
      await tiny.load();
      final tooBig = await tiny.ensure(
          key: 'k-big', category: 'videos', url: '$base/big');
      check('超上限不落盘', tooBig == null);
      check('超上限不留索引条目', tiny.pathFor('k-big') == null);
      check('超上限不占字节', tiny.bytes == 0, '${tiny.bytes}');
      tiny.dispose();
    }

    // ---------------------------------------------------------------
    print('\n[MediaCache] 备选地址（直链过期后的第二选择）');
    {
      final altRoot = Directory('${tmp.path}/media_alt/photos');
      final altCache = MediaCache(
        root: Directory('${tmp.path}/media_alt'),
        indexFile: File('${tmp.path}/media_alt_index.json'),
        fetcher: _CountingFetcher(HttpMediaFetcher()),
      );
      await altCache.load();

      // 首选 404、备选活的 —— 真机上「rkey 过期但 md5 直链还在」就是这个形状。
      final p = await altCache.ensure(
        key: 'k-alt',
        category: 'photos',
        url: '$base/404',
        altUrls: <String>['$base/img/a.jpg'],
      );
      check('首选失败时用备选地址成功', p != null && File(p).existsSync(), p);
      check('备选成功也写进索引', altCache.pathFor('k-alt') == p);

      // 首选与备选都失败。
      final none = await altCache.ensure(
        key: 'k-none',
        category: 'photos',
        url: '$base/404',
        altUrls: <String>['$base/404?x=1'],
      );
      check('全部候选失败返回 null', none == null);
      check('全部失败不留索引条目', altCache.pathFor('k-none') == null);

      // 首选成功时不该去碰备选（省一次请求）。
      final counting2 = _CountingFetcher(HttpMediaFetcher());
      final alt2 = MediaCache(
        root: Directory('${tmp.path}/media_alt2'),
        indexFile: File('${tmp.path}/media_alt2_index.json'),
        fetcher: counting2,
      );
      await alt2.load();
      await alt2.ensure(
        key: 'k-first',
        category: 'photos',
        url: '$base/img/c.jpg',
        altUrls: <String>['$base/img/a.jpg'],
      );
      check('首选成功只发 1 次请求', counting2.calls == 1, '${counting2.calls}');

      // 命中缓存后备选根本不该被读。
      final before = counting2.calls;
      await alt2.ensure(
        key: 'k-first',
        category: 'photos',
        url: '$base/404',
        altUrls: <String>['$base/404'],
      );
      check('命中缓存不碰任何候选', counting2.calls == before,
          '${counting2.calls} vs $before');

      altCache.dispose();
      alt2.dispose();
      if (altRoot.existsSync()) altRoot.deleteSync(recursive: true);
    }

    // ---------------------------------------------------------------
    print('\n[MediaCache] 清理');
    {
      check('进入清理前：索引里有 200 字节（2 个文件）', cache.bytes == 200,
          '${cache.bytes}');
      // 造一个孤儿文件（磁盘有、索引没有）
      final orphan = File('${mediaRoot.path}/photos/orphan.bin')
        ..writeAsBytesSync(List<int>.filled(10, 9));
      final freedOrphan = await cache.prune(maxCacheBytes: 1024 * 1024);
      check('孤儿文件被清掉', freedOrphan >= 10 && !orphan.existsSync(),
          'freed=$freedOrphan');
      check('孤儿清理不动有效条目（预算充足时）', cache.bytes == 200,
          '${cache.bytes}');

      // 预算清理：上限设成 100，200 字节应当被删到 <=100
      final freed = await cache.prune(maxCacheBytes: 100);
      check('超预算时清理', freed > 0 && cache.bytes <= 100,
          'freed=$freed bytes=${cache.bytes}');

      // 保留期清理：把某文件访问时间改老
      final keepCache = MediaCache(
          root: mediaRoot, indexFile: indexFile, fetcher: HttpMediaFetcher());
      await keepCache.load();
      await keepCache.ensure(
          key: 'k-keep', category: 'files', url: '$base/img/c.jpg');
      final keptPath = keepCache.pathFor('k-keep');
      check('重新放入一个文件', keptPath != null);
      final freed2 = await keepCache.prune(
          keep: const Duration(days: 7), maxCacheBytes: 10 * 1024 * 1024);
      check('未过期文件不被保留期清掉', freed2 == 0 && File(keptPath!).existsSync(),
          'freed=$freed2');

      final cleared = await keepCache.clear();
      check('clear 释放字节', cleared > 0, '$cleared');
      check('clear 后磁盘为空',
          !mediaRoot.existsSync() ||
              mediaRoot.listSync(recursive: true).whereType<File>().isEmpty);
      check('clear 后索引为空', keepCache.bytes == 0);
      check('clear 后 pathFor 返回 null', keepCache.pathFor('k-keep') == null);
      keepCache.dispose();
    }

    // ---------------------------------------------------------------
    print('\n[MediaCache] 文件被外部删除时自愈');
    {
      final root2 = Directory('${tmp.path}/media2');
      final idx2 = File('${tmp.path}/media2_index.json');
      final c2 = MediaCache(
          root: root2, indexFile: idx2, fetcher: HttpMediaFetcher());
      await c2.load();
      final p = await c2.ensure(
          key: 'k1', category: 'photos', url: '$base/img/a.jpg');
      check('放入一个文件', p != null);
      File(p!).deleteSync();
      check('文件被外部删掉后 pathFor 立即返回 null', c2.pathFor('k1') == null);
      check('索引条目被就地作废（不会虚报占用）', c2.bytes == 0, '${c2.bytes}');
      final again = await c2.ensure(
          key: 'k1', category: 'photos', url: '$base/img/a.jpg');
      check('下次 ensure 会重新下载', again != null && File(again).existsSync());
      c2.dispose();
    }

    // ---------------------------------------------------------------
    print('\n[MediaCache] 扩展名推断');
    {
      final root3 = Directory('${tmp.path}/media3');
      final c3 = MediaCache(
          root: root3,
          indexFile: File('${tmp.path}/media3_index.json'),
          fetcher: HttpMediaFetcher());
      await c3.load();
      final p = await c3.ensure(
          key: 'q', category: 'photos', url: '$base/img/a.jpg?v=1&x=2');
      check('带 query 的 URL 也能取到扩展名', p != null && p.endsWith('.jpg'), p);
      final p2 = await c3.ensure(
          key: 'q2', category: 'photos', url: '$base/img/a.jpg');
      check('同内容不同 query -> 同一文件', p == p2);
      c3.dispose();
    }

    // ---------------------------------------------------------------
    print('\n[MediaCache] 并发上限');
    {
      final root4 = Directory('${tmp.path}/media4');
      final c4 = MediaCache(
        root: root4,
        indexFile: File('${tmp.path}/media4_index.json'),
        fetcher: HttpMediaFetcher(),
        maxConcurrent: 2,
      );
      await c4.load();
      final sw = Stopwatch()..start();
      await Future.wait(List.generate(
          6,
          (i) => c4.ensure(
              key: 'slow-$i', category: 'photos', url: '$base/slow')));
      sw.stop();
      // 6 个请求、并发 2、每个 300ms -> 至少 3 批 = 900ms
      check('并发上限生效（6 个 300ms 请求至少 3 批）',
          sw.elapsedMilliseconds >= 850, '${sw.elapsedMilliseconds}ms');
      check('全部成功', c4.bytes > 0, '${c4.bytes}');
      c4.dispose();
    }

    // ---------------------------------------------------------------
    print('\n[失败分类] classifyMediaHttpFailure（纯函数）');
    {
      MediaFetchFailureKind k(int s, int? rc) => classifyMediaHttpFailure(s, rc);
      check('404 -> missing', k(404, null) == MediaFetchFailureKind.missing);
      check('410 -> missing', k(410, null) == MediaFetchFailureKind.missing);
      check('429 -> rateLimited', k(429, null) == MediaFetchFailureKind.rateLimited);
      check('503 -> rateLimited', k(503, null) == MediaFetchFailureKind.rateLimited);
      check('500 -> network', k(500, null) == MediaFetchFailureKind.network);
      check('400 + -5503007 -> expired',
          k(400, -5503007) == MediaFetchFailureKind.expired);
      check('400 + -5503010 -> rejected',
          k(400, -5503010) == MediaFetchFailureKind.rejected);
      check('400 + -5503037 -> rejected',
          k(400, -5503037) == MediaFetchFailureKind.rejected);
      check('400 无 retcode -> rejected',
          k(400, null) == MediaFetchFailureKind.rejected);
    }

    print('\n[fetcher] fetchOutcome 的落点');
    {
      final f = HttpMediaFetcher();
      final e = await f.fetchOutcome('$base/expired');
      check('400+过期码 -> expired 且抠出 retcode',
          e is MediaFetchFailed &&
              e.kind == MediaFetchFailureKind.expired &&
              e.retcode == -5503007,
          e is MediaFetchFailed ? '${e.kind} ${e.retcode}' : '$e');
      check('retmsg 也抠出来了',
          e is MediaFetchFailed && (e.retmsg ?? '').contains('expired'),
          e is MediaFetchFailed ? '${e.retmsg}' : '');
      final m = await f.fetchOutcome('$base/404');
      check('404 -> missing 且 status=404',
          m is MediaFetchFailed &&
              m.kind == MediaFetchFailureKind.missing &&
              m.status == 404);
      final rj = await f.fetchOutcome('$base/rejected');
      check('400+rkey 错 -> rejected',
          rj is MediaFetchFailed && rj.kind == MediaFetchFailureKind.rejected);
      final rl = await f.fetchOutcome('$base/rate');
      check('429 -> rateLimited',
          rl is MediaFetchFailed && rl.kind == MediaFetchFailureKind.rateLimited);
      final big = await f.fetchOutcome('$base/big', maxBytes: 1024);
      check('声明超 maxBytes -> tooLarge',
          big is MediaFetchFailed && big.kind == MediaFetchFailureKind.tooLarge);
      // 裸路径按本地文件处理（OneBot 后端会给 /data/...），所以用别的协议试
      final bad = await f.fetchOutcome('ftp://example.com/a.jpg');
      check('不支持的协议 -> badUrl',
          bad is MediaFetchFailed && bad.kind == MediaFetchFailureKind.badUrl);
      final ok = await f.fetchOutcome('$base/img/a.jpg');
      check('正常 -> MediaFetchOk 且字节数对',
          ok is MediaFetchOk && ok.bytes.length == 100);
      f.close();
    }

    print('\n[MediaCache] 负缓存（失败后不再自动刷请求）');
    {
      final counter = _OutcomeCounter(HttpMediaFetcher());
      final c5 = MediaCache(
          root: Directory('${tmp.path}/media5'),
          indexFile: File('${tmp.path}/media5_index.json'),
          fetcher: counter);
      await c5.load();
      final p1 = await c5.ensure(
          key: 'x', category: 'photos', url: '$base/expired');
      check('过期链接第一次 -> null', p1 == null);
      check('失败被记下（expired）',
          c5.failureOf('x') == MediaFetchFailureKind.expired,
          '${c5.failureOf('x')}');
      final p2 = await c5.ensure(
          key: 'x', category: 'photos', url: '$base/expired');
      check('负缓存命中 -> 直接 null 且不再发请求',
          p2 == null && counter.calls == 1, 'calls=${counter.calls}');
      c5.forgetFailure('x');
      check('forgetFailure 清掉分类', c5.failureOf('x') == null);
      final p3 = await c5.ensure(
          key: 'x', category: 'photos', url: '$base/expired');
      check('清掉后重试会真的再发一次',
          p3 == null && counter.calls == 2, 'calls=${counter.calls}');
      c5.dispose();
    }

    print('\n[MediaCache] 网络错误退避重试');
    {
      final counter = _OutcomeCounter(HttpMediaFetcher());
      final c6 = MediaCache(
          root: Directory('${tmp.path}/media6'),
          indexFile: File('${tmp.path}/media6_index.json'),
          fetcher: counter);
      await c6.load();
      final sw = Stopwatch()..start();
      final p = await c6.ensure(
          key: 'flaky', category: 'photos', url: '$base/flaky');
      sw.stop();
      check('两次 500 后第三次成功', p != null, '$p');
      check('一共发了 3 次（1 次原始 + 2 次退避重试）', counter.calls == 3,
          'calls=${counter.calls}');
      check('退避确实等了（0.5s + 2s）', sw.elapsedMilliseconds >= 2300,
          '${sw.elapsedMilliseconds}ms');
      final p2 = await c6.ensure(
          key: 'flaky', category: 'photos', url: '$base/flaky');
      check('成功结果进缓存，第二次不再发请求',
          p2 == p && counter.calls == 3, 'calls=${counter.calls}');
      c6.dispose();
    }

    print('\n[MediaCache] 候选回退（第一个地址死了换下一个）');
    {
      final c7 = MediaCache(
          root: Directory('${tmp.path}/media7'),
          indexFile: File('${tmp.path}/media7_index.json'),
          fetcher: HttpMediaFetcher());
      await c7.load();
      final p = await c7.ensure(
          key: 'fb',
          category: 'photos',
          url: '$base/404',
          altUrls: ['$base/img/a.jpg']);
      check('首个候选 404 -> 用备用地址成功', p != null && p.endsWith('.jpg'), '$p');
      c7.dispose();
    }

    print('\n[MediaCache] 按分类的并发上限');
    {
      final c8 = MediaCache(
        root: Directory('${tmp.path}/media8'),
        indexFile: File('${tmp.path}/media8_index.json'),
        fetcher: HttpMediaFetcher(),
        maxConcurrent: 8,
        categoryLimits: const <String, int>{'photos': 1},
      );
      await c8.load();
      final sw = Stopwatch()..start();
      await Future.wait(List.generate(
          4,
          (i) => c8.ensure(
              key: 'p-$i', category: 'photos', url: '$base/slow')));
      sw.stop();
      // 4 个 300ms、分类上限 1 -> 串行，至少 1.1s（全局上限 8 不构成瓶颈）
      check('分类上限 1 时串行执行', sw.elapsedMilliseconds >= 1100,
          '${sw.elapsedMilliseconds}ms');
      final sw2 = Stopwatch()..start();
      await Future.wait(List.generate(
          4,
          (i) => c8.ensure(
              key: 'v-$i', category: 'voices', url: '$base/slow')));
      sw2.stop();
      check('别的分类不受影响（voices 走全局 8，并行）',
          sw2.elapsedMilliseconds < 900, '${sw2.elapsedMilliseconds}ms');
      c8.dispose();
    }

    counting.close();
    check('dispose 会关闭 fetcher', counting.closed);
  } finally {
    await server.close(force: true);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }

  print('\n=== 结果: $_passed 通过, $_failed 失败 ===');
  if (_failed > 0) exitCode = 1;
}
