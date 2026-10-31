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
/// **任何失败都返回 null（或带分类的 [MediaFetchFailed]）**，由调用方决定
/// 要不要下次再试。
///
/// ## 为什么要有失败分类
///
/// 真机实测（16 条历史图片直链）只有 12.5% 能取到：10 条 400
/// `retcode=-5503007 download url has expired`、4 条 404。全都拍平成 null 的
/// 后果是**重试策略只能一刀切**——对过期地址狂重试是白烧流量，对网络抖动
/// 不重试又会让"首屏一片占位"。Telegram 的 `FileLoader.fileDidFailedLoad` 与
/// 官方 `URLDrawable.mRetryCount` 都是先分类再决定，这里对齐它们。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 取图失败的**可处置**分类。
enum MediaFetchFailureKind {
  /// 没有失败。
  none,

  /// 直链过期（服务端明确回 `retcode=-5503007`）。再打同一个地址没有意义，
  /// 但换地址/换通道有意义，所以 UI 要露出"点按重试"。
  expired,

  /// 404/410：资源不在了（死链）。
  missing,

  /// 其他 4xx（rkey/spec 不合法、签名错）。换地址才有意义。
  rejected,

  /// 429/503：限流，等一下就好。
  rateLimited,

  /// 超时、断网、DNS、5xx：最值得自动重试。
  network,

  /// 超过 [kDefaultMediaMaxBytes]。
  tooLarge,

  /// 地址本身不合法（空串 / 未知 scheme）。
  badUrl,

  /// 兜底（`file://` 读不到、非 HTTP 错误）。
  unknown,
}

/// 中文短标签。日志与 UI 占位文案共用，避免两处各写一份而漂移。
String mediaFetchFailureLabel(MediaFetchFailureKind kind) => switch (kind) {
      MediaFetchFailureKind.none => '成功',
      MediaFetchFailureKind.expired => '图片链接已过期',
      MediaFetchFailureKind.missing => '图片已失效',
      MediaFetchFailureKind.rejected => '地址被拒绝',
      MediaFetchFailureKind.rateLimited => '请求过于频繁',
      MediaFetchFailureKind.network => '网络错误',
      MediaFetchFailureKind.tooLarge => '文件过大',
      MediaFetchFailureKind.badUrl => '地址不合法',
      MediaFetchFailureKind.unknown => '加载失败',
    };

/// 取图结果。
sealed class MediaFetchOutcome {
  const MediaFetchOutcome();
}

/// 成功。
class MediaFetchOk extends MediaFetchOutcome {
  final Uint8List bytes;
  const MediaFetchOk(this.bytes);
}

/// 失败（带分类与证据）。
class MediaFetchFailed extends MediaFetchOutcome {
  final MediaFetchFailureKind kind;

  /// HTTP 状态码（非 HTTP 失败为 null）。
  final int? status;

  /// 服务端 retcode（腾讯图片 CDN 在 body 里给，非 HTTP/无 body 为 null）。
  final int? retcode;

  /// 服务端 retmsg（同上）。
  final String? retmsg;

  const MediaFetchFailed(
    this.kind, {
    this.status,
    this.retcode,
    this.retmsg,
  });

  @override
  String toString() =>
      'MediaFetchFailed($kind, status=$status, retcode=$retcode, retmsg=$retmsg)';
}

/// 把媒体引用取成字节。
abstract class MediaFetcher {
  /// 取 [url] 的字节。
  ///
  /// 支持 `http://`、`https://`、`file://` 与裸本地路径。
  /// 失败（网络错误、非 2xx、超过 [maxBytes]、超时）一律返回 null。
  Future<Uint8List?> fetch(String url, {int maxBytes = kDefaultMediaMaxBytes});

  /// 取 [url]，失败时带分类。
  ///
  /// 默认实现退化为 [fetch]（假实现只覆盖 [fetch] 也能用），细节见
  /// [HttpMediaFetcher.fetchOutcome]。
  Future<MediaFetchOutcome> fetchOutcome(String url,
      {int maxBytes = kDefaultMediaMaxBytes}) async {
    final bytes = await fetch(url, maxBytes: maxBytes);
    if (bytes == null) {
      return const MediaFetchFailed(MediaFetchFailureKind.unknown);
    }
    return MediaFetchOk(bytes);
  }

  /// 释放资源（关闭连接池）。默认无事可做。
  void close() {}
}

/// 单个媒体文件的默认上限：64 MiB。
///
/// 与 `StorageBudget.maxCacheableBytes` 同量级——超过这个大小的东西不适合
/// 进缓存（一个 200 MB 的视频会把 512 MB 预算吃掉一半）。
const int kDefaultMediaMaxBytes = 64 * 1024 * 1024;

/// HTTP 状态码 + 服务端 retcode → 失败分类。**纯函数**，自测直接打。
///
/// 阈值都来自真机实测（见 docs/图片加载-官方对照与改造方案-20261031.md §1）：
/// 400 + `-5503007` = 直链过期是压倒性多数；`-5503010/-5503011/-5503037` 是
/// "rkey/spec/format 不合法"，属于换地址才可能好的一类。
MediaFetchFailureKind classifyMediaHttpFailure(int status, int? retcode) {
  if (status == 404 || status == 410) return MediaFetchFailureKind.missing;
  if (status == 429 || status == 503) return MediaFetchFailureKind.rateLimited;
  // 5xx 是服务端临时问题，值得退避重试（与 4xx 的"换个地址"不同）。
  if (status >= 500) return MediaFetchFailureKind.network;
  if (retcode == -5503007) return MediaFetchFailureKind.expired;
  if (retcode == -5503010 ||
      retcode == -5503011 ||
      retcode == -5503037) {
    return MediaFetchFailureKind.rejected;
  }
  if (status >= 400) return MediaFetchFailureKind.rejected;
  return MediaFetchFailureKind.unknown;
}

final RegExp _retcodeRe = RegExp(r'retcode[^0-9\-]{0,6}(-?\d+)');
final RegExp _retmsgRe = RegExp(r'retmsg"?\s*[:=]\s*"([^"]{0,160})');

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
    final outcome = await fetchOutcome(url, maxBytes: maxBytes);
    return outcome is MediaFetchOk ? outcome.bytes : null;
  }

  @override
  Future<MediaFetchOutcome> fetchOutcome(String url,
      {int maxBytes = kDefaultMediaMaxBytes}) async {
    if (url.isEmpty) {
      return const MediaFetchFailed(MediaFetchFailureKind.badUrl);
    }
    try {
      if (url.startsWith('file://')) {
        return await _readFileOutcome(Uri.parse(url).toFilePath(), maxBytes);
      }
      if (url.startsWith('http://') || url.startsWith('https://')) {
        return await _getOutcome(Uri.parse(url), maxBytes);
      }
      // 裸路径（OneBot 后端常直接给 /data/... 或 Windows 盘符路径）
      if (!url.contains('://')) return await _readFileOutcome(url, maxBytes);
      return const MediaFetchFailed(MediaFetchFailureKind.badUrl);
    } on TimeoutException {
      return const MediaFetchFailed(MediaFetchFailureKind.network);
    } on SocketException {
      return const MediaFetchFailed(MediaFetchFailureKind.network);
    } on HandshakeException {
      return const MediaFetchFailed(MediaFetchFailureKind.network);
    } on HttpException {
      return const MediaFetchFailed(MediaFetchFailureKind.network);
    } catch (_) {
      return const MediaFetchFailed(MediaFetchFailureKind.unknown);
    }
  }

  Future<MediaFetchOutcome> _readFileOutcome(String path, int maxBytes) async {
    final f = File(path);
    if (!f.existsSync()) {
      return const MediaFetchFailed(MediaFetchFailureKind.missing);
    }
    final len = f.lengthSync();
    if (len <= 0) return const MediaFetchFailed(MediaFetchFailureKind.unknown);
    if (len > maxBytes) {
      return const MediaFetchFailed(MediaFetchFailureKind.tooLarge);
    }
    return MediaFetchOk(await f.readAsBytes());
  }

  Future<MediaFetchOutcome> _getOutcome(Uri uri, int maxBytes) async {
    final req = await _http.getUrl(uri).timeout(totalTimeout);
    req.followRedirects = true;
    req.maxRedirects = maxRedirects;

    final resp = await req.close().timeout(totalTimeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      // 腾讯图片 CDN 把原因放在 body 里（约 70 字节）：
      //   {"retcode":-5503007,"retmsg":"download url has expired"}
      // 不读它就只能知道"400"，分不出"过期"和"参数错"。
      int? retcode;
      String? retmsg;
      try {
        final buf = BytesBuilder(copy: false);
        var n = 0;
        await for (final chunk in resp.timeout(const Duration(seconds: 2))) {
          buf.add(chunk);
          n += chunk.length;
          if (n >= 512) break;
        }
        final text = utf8.decode(buf.takeBytes(), allowMalformed: true);
        final m = _retcodeRe.firstMatch(text);
        if (m != null) retcode = int.tryParse(m.group(1)!);
        final r = _retmsgRe.firstMatch(text);
        if (r != null) retmsg = r.group(1);
      } catch (_) {
        // 读不到 body 不影响分类（按状态码兜底）。
      }
      // 上面 break 掉之后必须把 body 抽干，否则连接不回池。
      try {
        await resp.drain<void>();
      } catch (_) {}
      return MediaFetchFailed(
        classifyMediaHttpFailure(resp.statusCode, retcode),
        status: resp.statusCode,
        retcode: retcode,
        retmsg: retmsg,
      );
    }
    if (resp.contentLength > maxBytes) {
      await resp.drain<void>().catchError((_) {});
      return const MediaFetchFailed(MediaFetchFailureKind.tooLarge);
    }

    final out = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in resp.timeout(totalTimeout)) {
      total += chunk.length;
      // contentLength 可能为 -1（chunked），所以边收边判。
      if (total > maxBytes) {
        return const MediaFetchFailed(MediaFetchFailureKind.tooLarge);
      }
      out.add(chunk);
    }
    if (total == 0) {
      // 200 但 0 字节：没有缓存价值，按"资源异常"记（不当成网络抖动重试）。
      return const MediaFetchFailed(MediaFetchFailureKind.unknown);
    }
    return MediaFetchOk(out.takeBytes());
  }

  @override
  void close() {
    _client?.close(force: true);
    _client = null;
  }
}
