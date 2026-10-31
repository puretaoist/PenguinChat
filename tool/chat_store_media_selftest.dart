/// ChatStore 的媒体落盘集成自测（纯 Dart，不依赖 Flutter 引擎）
///
/// 运行：dart run tool/chat_store_media_selftest.dart
///
/// 单独一个文件而不是塞进 `chat_store_selftest.dart`：那边是 140 项的巨型
/// 用例集，媒体这块要起 HTTP 服务、要等后台任务，混进去会让失败定位变慢。
///
/// 这里验证的是**接线**，不是缓存实现本身（那是 `media_cache_selftest`）：
///   1. 收到消息 -> 自动预取 -> 落盘 -> `mediaPathOf` 能查到
///   2. 直链失效（404）时不炸、不留垃圾
///   3. 清理缓存后 `mediaPathOf` 立刻变 null（不能返回已删的路径）
///   4. 冷启动后从索引恢复（不重下）
// ignore_for_file: avoid_print, avoid_relative_lib_imports
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/client_api/chat_store.dart';
import 'package:qqclient/client_api/objects.dart';
import 'package:qqclient/client_api/segment.dart';
import 'package:qqclient/client_api/session.dart';
import 'package:qqclient/infra/net/media_fetcher.dart';
import 'chat_store_selftest.dart' show FakeSession;

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

// ---------------------------------------------------------------------------
// 复用 chat_store_selftest 里的 FakeSession
// ---------------------------------------------------------------------------

/// 只 show 需要的两个符号：那边还有个同名的 `check`，全量导入会撞。

/// 造一条带指定段的收到消息。
ChatMessage _msgWith(String id, List<Segment> segs) => ChatMessage(
      id: id,
      text: '看图',
      chatId: 'private_10001',
      senderId: '10001',
      senderName: '对方',
      time: DateTime(2026, 10, 22, 12, 0, 0),
      segments: segs,
      outgoing: false,
    );

/// 起一个只服务两张图的本地 HTTP 服务。
Future<HttpServer> _serve() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    if (req.uri.path == '/img/a.jpg') {
      res.add(Uint8List.fromList(List<int>.filled(64, 0xAA)));
    } else if (req.uri.path == '/img/b.jpg') {
      res.add(Uint8List.fromList(List<int>.filled(64, 0xBB)));
    } else if (req.uri.path == '/img/fresh.jpg') {
      // 群图"换链"之后服务端给的新地址
      res.add(Uint8List.fromList(List<int>.filled(64, 0xCC)));
    } else if (req.uri.path == '/expired') {
      res.statusCode = 400;
      res.write('{"retcode":-5503007,"retmsg":"download url has expired"}');
    } else {
      res.statusCode = 404;
    }
    await res.close();
  });
  return server;
}

/// 等条件成立（避免固定 sleep 造成的抖动）。
Future<bool> _waitUntil(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return cond();
}

Future<void> main() async {
  print('=== ChatStore 媒体落盘集成自测 ===');

  final tmp = Directory.systemTemp.createTempSync('qqcs_media_');
  final server = await _serve();
  final base = 'http://127.0.0.1:${server.port}';
  final session = FakeSession();

  try {
    final dataDir = Directory('${tmp.path}/data');
    final store = ChatStore(
      session: session,
      dataDir: dataDir,
      mediaFetcher: HttpMediaFetcher(),
    );
    await store.bootstrap();

    // -------------------------------------------------------------
    print('\n[收到消息] 自动预取');
    final imgA = ImageSegment('a.jpg', url: '$base/img/a.jpg', width: 100, height: 100);
    session.emit(SessionMessage(_msgWith('m1', [imgA])));
    // 消息要先落到 store 里，UI 才可能去查媒体路径
    await _waitUntil(() => store.messagesOf('private_10001').isNotEmpty);

    final got = await _waitUntil(() => store.mediaPathOf(imgA) != null);
    check('收到图片后自动落盘', got, store.mediaPathOf(imgA));
    final p = store.mediaPathOf(imgA);
    check('路径在 media/photos 下', p != null && p.contains('photos'), p);
    check('文件真的存在', p != null && File(p).existsSync());
    check('内容正确',
        p != null && File(p).readAsBytesSync().every((x) => x == 0xAA));

    // -------------------------------------------------------------
    print('\n[直链失效] 不炸、不留垃圾');
    final bad = ImageSegment('missing.jpg', url: '$base/img/nope.jpg');
    session.emit(SessionMessage(_msgWith('m2', [bad])));
    await _waitUntil(() => store.messagesOf('private_10001').length >= 2);
    // 等一会儿，确认后台任务跑完了
    await Future<void>.delayed(const Duration(milliseconds: 400));
    check('404 的图没有本地路径', store.mediaPathOf(bad) == null);
    check('404 的图不会让媒体目录里多出东西',
        store.mediaCache!.bytes == 64, '${store.mediaCache!.bytes}');

    // -------------------------------------------------------------
    print('\n[手动 ensureMedia]');
    final imgB = ImageSegment('b.jpg', url: '$base/img/b.jpg');
    final pb = await store.ensureMedia(imgB);
    check('ensureMedia 可被主动 await', pb != null && File(pb).existsSync());
    check('ensureMedia 后 mediaPathOf 同步可见',
        store.mediaPathOf(imgB) == pb);

    // -------------------------------------------------------------
    print('\n[没有 url 的段]');
    final noUrl = ImageSegment('only-name.jpg');
    check('无 url 无路径 -> mediaPathOf 为 null',
        store.mediaPathOf(noUrl) == null);
    check('无 url 无路径 -> ensureMedia 返回 null',
        await store.ensureMedia(noUrl) == null);

    // -------------------------------------------------------------
    print('\n[清理缓存] 路径必须立刻失效');
    await store.clearMediaCache();
    check('清空后 mediaPathOf 变 null', store.mediaPathOf(imgA) == null);
    check('清空后 ensureMedia 能重新下载',
        await store.ensureMedia(imgA) != null);

    // -------------------------------------------------------------
    print('\n[冷启动] 从索引恢复，不重下');
    final before = store.mediaPathOf(imgA);
    await store.dispose();

    final session2 = FakeSession();
    final store2 = ChatStore(
      session: session2,
      dataDir: dataDir,
      mediaFetcher: HttpMediaFetcher(),
    );
    await store2.bootstrap();
    // 冷启动时消息从磁盘读回，但媒体路径应当**不需要**再下载就能查到。
    final restored = store2.mediaPathOf(imgA);
    check('冷启动后 mediaPathOf 直接命中（不重下）', restored != null, restored);
    check('恢复的路径与之前一致', restored == before, '$restored vs $before');

    await store2.dispose();

    // -------------------------------------------------------------
    print('\n[群图换链] 直链过期 -> 凭 fileid 换一条 -> 落盘');
    final session3 = FakeSession();
    var resolvedCalls = 0;
    var resolvedGid = 0;
    var resolvedMd5 = '';
    var resolvedFileId = 0;
    final store3 = ChatStore(
      session: session3,
      dataDir: Directory('${tmp.path}/data3'),
      mediaFetcher: HttpMediaFetcher(),
      imageUrlResolver: ({
        required int groupCode,
        required String md5Hex,
        required int fileId,
      }) async {
        resolvedCalls++;
        resolvedGid = groupCode;
        resolvedMd5 = md5Hex;
        resolvedFileId = fileId;
        return '$base/img/fresh.jpg';
      },
    );
    await store3.bootstrap();

    final deadGroupImg = ImageSegment(
      'dead.jpg',
      url: '$base/expired',
      md5: '0123456789abcdef0123456789abcdef',
      fileId: 987654,
      groupCode: 486045673,
    );
    final gotPath = await store3.ensureMedia(deadGroupImg);
    check('过期直链换链后拿到本地路径', gotPath != null, '$gotPath');
    check('换链回调被调用一次', resolvedCalls == 1, '$resolvedCalls');
    check('回调参数：群号', resolvedGid == 486045673, '$resolvedGid');
    check('回调参数：md5', resolvedMd5 == '0123456789abcdef0123456789abcdef',
        resolvedMd5);
    check('回调参数：fileid', resolvedFileId == 987654, '$resolvedFileId');
    check('落盘后 mediaPathOf 命中', store3.mediaPathOf(deadGroupImg) != null);

    // 缺 fileId（老消息没存下来）时不许发请求：注定回 206。
    final noFileId = ImageSegment(
      'old.jpg',
      url: '$base/expired',
      md5: '0123456789abcdef0123456789abcdef',
      groupCode: 486045673,
    );
    final noFileIdPath = await store3.ensureMedia(noFileId);
    check('没有 fileId 时不换链', noFileIdPath == null, '$noFileIdPath');
    check('没有 fileId 时回调没被调用', resolvedCalls == 1, '$resolvedCalls');

    // 私聊图（无群号）同样不换链。
    final privateImg =
        ImageSegment('p.jpg', url: '$base/expired', md5: 'ffffffffffffffffffffffffffffffff');
    await store3.ensureMedia(privateImg);
    check('私聊图不换链', resolvedCalls == 1, '$resolvedCalls');

    await store3.dispose();
    await session3.dispose();
  } finally {
    await server.close(force: true);
    await session.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }

  print('\n=== 结果: $_passed 通过, $_failed 失败 ===');
  if (_failed > 0) exitCode = 1;
}
