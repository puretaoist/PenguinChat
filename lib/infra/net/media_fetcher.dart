/// L1 基础设施：媒体字节的获取（只负责"拿到字节"，不负责存哪儿）
///
/// ## 为什么单独一层
///
/// 收到图片/语音/视频/文件时，协议层能给的只有**引用**（QQ 是拼出来的直链，
/// OneBot 是后端给的 URL 或 `file://` 路径）。把引用变成字节是网络活，与
/// 协议无关、与 Flutter 无关，所以放 L1。
///
/// 上层（[MediaCache]）只依赖本文件的 [MediaFetcher] 抽象，测试里换成假实现
/// 就能完全离线跑——这是本项目一贯的做法（见 `docs/PITFALLS.md` 关于
/// "黄金向量必须由参考实现生成"的同一条思路：能被替身的边界才测得动）。
///
/// ## 为什么不抛异常
///
/// 调用方全是后台任务（收到消息后顺手缓存），失败是常态：直链会过期、CDN
/// 会拒绝、手机会断网。抛异常只会变成未捕获的异步错误。所以约定：
/// **任何失败都返回 null**，由调用方决定要不要下次再试。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// 把媒体引用取成字节。
abstract class MediaFetcher {
  /// 取 [url] 的字节。
  ///
  /// 支持 `http://`、`https://`、`file://` 与裸本地路径。
  /// 失败（网络错误、非 2xx、超过 [maxBytes]、超时）一律返回 null。
  Future<Uint8List?> fetch(String url, {int maxBytes = kDefaultMediaMaxBytes});

  /// 释放资源（关闭连接池）。默认无事可做。
  void close() {}
}

/// 单个媒体文件的默认上限：64 MiB。
///
/// 与 `StorageBudget.maxCacheableBytes` 同量级——超过这个大小的东西不适合
/// 进缓存（一个 200 MB 的视频会把 512 MB 预算吃掉一半）。
const int kDefaultMediaMaxBytes = 64 * 1024 * 1024;

/// 基于 `dart:io` 的默认实现。
///
/// 刻意不引 dio：本项目的 HTTP 现状是直接用 `HttpClient`
/// （见 `lib/kernel/wlogin8/qq8_qimei.dart`），保持一种写法比多一个依赖好。
class HttpMediaFetcher implements MediaFetcher {
  /// 连接超时。腾讯的图片 CDN 在移动网下偶尔要 3–5 秒才握手。
  final Duration connectTimeout;

  /// 整体超时。大图 + 慢网要留够余量，但不能无限挂着。
  final Duration totalTimeout;

  /// 允许跟随的重定向次数。CDN 常有 1–2 跳。
  final int maxRedirects;

  HttpClient? _client;

  HttpMediaFetcher({
    this.connectTimeout = const Duration(seconds: 10),
    this.totalTimeout = const Duration(seconds: 30),
    this.maxRedirects = 4,
  });

  HttpClient get _http => _client ??= HttpClient()
    ..connectionTimeout = connectTimeout
    ..autoUncompress = true
    ..userAgent = 'Mozilla/5.0 (Linux; Android 13) qqclient/0.1';

  @override
  Future<Uint8List?> fetch(String url,
      {int maxBytes = kDefaultMediaMaxBytes}) async {
    if (url.isEmpty) return null;
    try {
      if (url.startsWith('file://')) {
        return await _readFile(Uri.parse(url).toFilePath(), maxBytes);
      }
      if (url.startsWith('http://') || url.startsWith('https://')) {
        return await _get(Uri.parse(url), maxBytes);
      }
      // 裸路径（OneBot 后端常直接给 /data/... 或 C:\...）
      if (!url.contains('://')) return await _readFile(url, maxBytes);
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _readFile(String path, int maxBytes) async {
    final f = File(path);
    if (!f.existsSync()) return null;
    final len = f.lengthSync();
    if (len <= 0 || len > maxBytes) return null;
    return f.readAsBytes();
  }

  Future<Uint8List?> _get(Uri uri, int maxBytes) async {
    final req = await _http.getUrl(uri).timeout(totalTimeout);
    req.followRedirects = true;
    req.maxRedirects = maxRedirects;

    final resp = await req.close().timeout(totalTimeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      // 必须把 body 抽干，否则连接不会回池。
      await resp.drain<void>().catchError((_) {});
      return null;
    }
    if (resp.contentLength > maxBytes) {
      await resp.drain<void>().catchError((_) {});
      return null;
    }

    final out = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in resp.timeout(totalTimeout)) {
      total += chunk.length;
      // contentLength 可能为 -1（chunked），所以边收边判。
      if (total > maxBytes) return null;
      out.add(chunk);
    }
    if (total == 0) return null;
    return out.takeBytes();
  }

  @override
  void close() {
    _client?.close(force: true);
    _client = null;
  }
}
