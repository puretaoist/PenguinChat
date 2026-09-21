/// L4：应用内滑动验证页（把服务端下发的验证地址在**本应用**的 WebView 里打开）
///
/// ## 为什么要在应用内做（而不是丢给系统浏览器）
///
/// 服务端要验证时给的是 `0x192` 里的一个地址（`ti.qq.com/safe/tools/captcha/…`）。
/// 之前的做法是用 `url_launcher` 丢给**系统浏览器**，解完再让人把验证码抄回来；
/// 而官方是**在应用内**完成验证的。两者在服务端眼里是不同的东西（见
/// `docs/PITFALLS.md` C8 的候选 (a)：验证页所在环境采集到的东西，可能与登录包里
/// 的设备身份对不上），所以本页把这一环搬进应用内，用来把 (a) 与 (b) 切开。
///
/// ## 验证码怎么回来（页面不会告诉应用，只能自己看）
///
/// 页面解完之后，ticket 可能从三条路里任意一条出来，我们**全都要**：
///
/// | 口子 | 观测手段 |
/// |---|---|
/// | 跳转（`location` / 302 / 新窗口） | `onNavigationRequest`/`onPageStarted` + 加载完成后注入的探针钩 `window.open`、`history.pushState` |
/// | 页面里 JS 桥的返回值 | `setOnJavaScriptTextInputDialog`（腾讯系 WebView 桥常用 `prompt` 传参）+ 注入的 JS 通道 |
/// | 页面正文直接把验证码显示出来让人抄 | 定时 `runJavaScriptReturningResult` 取 `location.href` / `innerText` + 探针经 JS 通道上报 |
///
/// 三条路都汇到 `_observe`：用 `qq8FindTicket`（L2）认字符串，认出来就填进输入框、
/// 亮出提交按钮。**不自作主张提交**——提交由人点（AGENTS §1.6：不代替人完成验证，
/// 也不自动解题）。
///
/// 页面上还有一份"捕获记录"（默认折叠）：真机第一次跑时，靠它就能看出 ticket
/// 到底从哪条路回来的；落进文件日志的那份**已打码**（凭据不进日志，AGENTS §1.5）。
///
/// ## 为什么用官方 `webview_flutter` 而不是 `flutter_inappwebview`
///
/// 后者能在**文档开头**注入脚本，本来更适合"钩住页面自己的跳转"；但它的 Android
/// 实现（`flutter_inappwebview_android` 1.1.3，2024-10 之后没再发版）在 AGP 9 上
/// **构建不过**：`getDefaultProguardFile('proguard-android.txt')` 已被 AGP 移除
/// （CI 实测 `:flutter_inappwebview_android` 评估失败）。官方插件与当前工具链同步，
/// 且 `AndroidWebViewController` 恰好提供 `onJsPrompt`/`onJsAlert`/`onConsoleMessage`
/// 这三个观测口——本页只丢掉了"文档开头注入"这一项，用加载完成后注入 + 定时取正文
/// 顶上（验证码是**人滑完之后**才产生的，那时钩子早已装好）。
///
/// ## 刻意没做的两件事
///
/// * **不改 User-Agent**：伪装成官方客户端是硬纪律禁止的（AGENTS §1.6）。
///   本页就是"一个 WebView 打开一个 https 地址"，用系统默认 UA。
/// * **不开无痕**：无痕会丢掉 cookie 与一部分可观测信号，验证页必须用正常模式
///   （验证失败往往是"环境不可信"，而不是"少了某个字段"）。
///
/// 本文件是 Flutter 层（L4）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../infra/log/logger.dart';
import '../../kernel/wlogin8/qq8_captcha.dart';
import '../theme/telegram_theme.dart';

final Logger _log = Log.get('QQ8VERIFY');

/// JS 通道名（与 [_kProbe] 里的 `window.PenguinCaptcha` 必须一致）。
const String _kBridgeName = 'PenguinCaptcha';

/// 捕获记录最多留多少条（够看一次验证的关键路径，也不至于吃内存）。
const int _kTraceCap = 120;

/// 轮询间隔：验证页是**会自己变**的（静默验证 / 跳转 / 显示验证码），
/// 而 webview_flutter 没有"DOM 变了"的回调，只能自己定时取一次。
const Duration _kPollInterval = Duration(milliseconds: 1200);

/// 加载完成后注入的探针脚本：只做观测，不改页面行为。
///
/// 钩住"要跳走了"的信号，并把每次触发经 JS 通道报回来。之所以在**加载完成后**
/// （而不是文档开头）注入：官方插件没有文档开头的注入口（见文件头说明）。
/// 这不影响本页的用途——验证码要等人滑完滑块才产生，那时钩子已经装好了。
const String _kProbe = r'''
(function () {
  if (window.__pqProbe) { return; }
  window.__pqProbe = function (kind, text) {
    try {
      window.PenguinCaptcha.postMessage(JSON.stringify({ k: kind, t: String(text) }));
    } catch (e) {}
  };
  try {
    var _open = window.open;
    window.open = function (u) { window.__pqProbe('open', u); return _open ? _open.apply(window, arguments) : null; };
  } catch (e) {}
  try {
    ['pushState', 'replaceState'].forEach(function (m) {
      var f = history[m];
      if (typeof f !== 'function') { return; }
      history[m] = function (s, t, u) { if (u) { window.__pqProbe('history', u); } return f.apply(history, arguments); };
    });
  } catch (e) {}
  try {
    document.addEventListener('click', function (ev) {
      var n = ev.target;
      while (n && n.tagName !== 'A') { n = n.parentNode; }
      if (n && n.href) { window.__pqProbe('click', n.href); }
    }, true);
  } catch (e) {}
  window.__pqProbe('probe', 'installed ' + location.href);
})();
''';

/// 应用内验证页。**返回值**是验证码（没拿到就 pop(null)）。
class Qq8VerifyPage extends StatefulWidget {
  const Qq8VerifyPage({super.key, required this.url});

  /// 服务端下发的验证地址（响应 TLV `0x192` 的原文）。
  final String url;

  @override
  State<Qq8VerifyPage> createState() => _Qq8VerifyPageState();
}

class _Qq8VerifyPageState extends State<Qq8VerifyPage> {
  final TextEditingController _manual = TextEditingController();
  final List<_Trace> _trace = <_Trace>[];

  late final WebViewController _web;
  Timer? _poll;
  int _progress = 0;
  String? _pageError;
  bool _showTrace = false;

  /// 页面是否已经加载过一次（没加载完就取 DOM 只会抛异常）。
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _web = WebViewController.fromPlatformCreationParams(
        const PlatformWebViewControllerCreationParams());
    unawaited(_configure());
    _poll = Timer.periodic(_kPollInterval, (_) => unawaited(_pullFromPage()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _manual.dispose();
    super.dispose();
  }

  Future<void> _configure() async {
    await _web.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _web.setBackgroundColor(TelegramColors.bgApp);
    // 通道名对页面意味着 `window.PenguinCaptcha.postMessage(...)`；
    // 注意它只对**之后加载**的页面生效，所以这里必须早于 loadRequest。
    await _web.addJavaScriptChannel(_kBridgeName,
        onMessageReceived: (JavaScriptMessage message) =>
            _onBridge(message.message));
    await _web.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (NavigationRequest request) {
        final uri = Uri.tryParse(request.url);
        if (uri == null) return NavigationDecision.navigate;
        _observe('nav', request.url, isUrl: true);
        // 非 http(s)（页面想拉起 QQ / 自定义 scheme）在 WebView 里也打不开，
        // 直接拦掉，免得留一个打不开的白页。
        return uri.scheme.startsWith('http')
            ? NavigationDecision.navigate
            : NavigationDecision.prevent;
      },
      onPageStarted: (url) {
        _observe('load', url, isUrl: true);
        if (_pageError != null) setState(() => _pageError = null);
      },
      onPageFinished: (url) async {
        _observe('loaded', url, isUrl: true);
        _loaded = true;
        await _injectProbe();
        await _pullFromPage();
      },
      onProgress: (progress) {
        if (progress != _progress) setState(() => _progress = progress);
      },
      onWebResourceError: (error) {
        // 子资源出错不是致命问题，只有主框架失败才值得弹出来
        if (error.isForMainFrame == false) return;
        setState(() => _pageError = '加载失败：${error.description}');
        _observe('error', error.description);
      },
    ));

    final platform = _web.platform;
    if (platform is AndroidWebViewController) {
      await platform.setMediaPlaybackRequiresUserGesture(false);
      await platform
          .setOnConsoleMessage((m) => _observe('console', m.message));
      // 腾讯系 WebView 桥常用 prompt 传参：内容必须看得到。官方插件在没有回调时
      // 会把 prompt 直接吃掉（返回空串），所以这里接管并记账。
      await platform.setOnJavaScriptTextInputDialog((request) async {
        _observe('prompt', '${request.message} | ${request.defaultText}');
        return '';
      });
      await platform.setOnJavaScriptAlertDialog((request) async {
        _observe('alert', request.message);
      });
    }

    await _web.loadRequest(Uri.parse(widget.url));
  }

  /// 所有观测口子的汇合点：认验证码 → 填进输入框 → 记账。
  ///
  /// [isUrl] 为 true 时把内容当选址处理（按域名+参数名记账，值打码）；
  /// 为 false（页面正文、JS 桥回值）时**只记长度**，正文本身不进日志——
  /// 它很可能整段包含验证码。
  void _observe(String kind, String text, {bool isUrl = false}) {
    if (text.isEmpty) return;
    final ticket = qq8FindTicket(text);
    if (ticket != null && _manual.text != ticket) {
      _log.i('捕获到验证码（来源 $kind，${ticket.length} 字符）');
      _manual.text = ticket;
    }
    final line = isUrl ? qq8RedactUrl(text) : text;
    _log.i('验证事件 $kind len=${text.length}'
        '${ticket == null ? '' : ' 含验证码'}' //
        '${isUrl ? ' $line' : ''}');
    if (!mounted) return;
    setState(() {
      _trace.add(_Trace(kind, line));
      if (_trace.length > _kTraceCap) _trace.removeAt(0);
    });
  }

  /// JS 通道回值（探针发过来的 `{k, t}` JSON）。
  void _onBridge(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final kind = '${decoded['k']}';
        _observe(kind, '${decoded['t']}',
            isUrl: const <String>{'open', 'history', 'click', 'submit'}
                .contains(kind));
        return;
      }
    } on FormatException {
      // 不是 JSON 也照样看一眼：桥可能被页面当普通函数用。
    }
    _observe('bridge', raw);
  }

  /// 注入探针（每次导航完成后都装一遍；页面自己带 `__pqProbe` 就跳过）。
  Future<void> _injectProbe() async {
    try {
      await _web.runJavaScript(_kProbe);
    } on Object catch (e) {
      _log.d('注入探针失败：$e');
    }
  }

  /// 定时取页面状态：地址 + 正文（兜底通道，探针失效时全靠它）。
  Future<void> _pullFromPage() async {
    if (!_loaded) return;
    try {
      final href = _jsString(await _web.runJavaScriptReturningResult(
          'location.href'));
      _observe('href', href, isUrl: true);
      final text = _jsString(await _web.runJavaScriptReturningResult(
          'document.body ? document.body.innerText : ""'));
      _observe('text', text);
    } on Object catch (e) {
      _log.d('取页面状态失败：$e');
    }
  }

  /// `runJavaScriptReturningResult` 的返回值是 JSON 编码的字符串（Android 实现），
  /// 这里把最外层引号去掉，拿回人看到的文本。
  String _jsString(Object? raw) {
    final s = raw?.toString() ?? '';
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      try {
        final decoded = jsonDecode(s);
        if (decoded is String) return decoded;
      } on FormatException {
        // 保持原样
      }
    }
    return s;
  }

  /// 提交验证码：把码交回登录页（由它接着走子命令 2）。
  void _submit() {
    final ticket = _manual.text.trim();
    if (ticket.isEmpty) return;
    Navigator.of(context).pop(ticket);
  }

  Future<void> _reload() async {
    setState(() {
      _pageError = null;
      _loaded = false;
    });
    await _web.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('完成验证'),
        actions: <Widget>[
          IconButton(
            key: const ValueKey('qq8-verify-trace'),
            tooltip: '捕获记录',
            onPressed: () => setState(() => _showTrace = !_showTrace),
            icon: Icon(_showTrace ? Icons.list_alt : Icons.article_outlined),
          ),
          IconButton(
            key: const ValueKey('qq8-verify-reload'),
            tooltip: '重新加载',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            key: const ValueKey('qq8-verify-external'),
            tooltip: '用系统浏览器打开同一地址',
            onPressed: () => launchUrl(Uri.parse(widget.url),
                mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (_progress < 100) LinearProgressIndicator(value: _progress / 100),
          if (_pageError != null)
            Container(
              width: double.infinity,
              color: const Color(0x33E05252),
              padding: const EdgeInsets.all(8),
              child: Text(_pageError!,
                  style: const TextStyle(fontSize: 12, height: 1.35)),
            ),
          Expanded(child: WebViewWidget(controller: _web)),
          _bottomPanel(context),
        ],
      ),
    );
  }

  /// 底部：识别结果 + 手动兜底 + 捕获记录。
  Widget _bottomPanel(BuildContext context) {
    final ticket = _manual.text.trim();
    final hasTicket = ticket.isNotEmpty;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: TelegramColors.bgInput,
        border: Border(top: BorderSide(color: TelegramColors.divider)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            hasTicket
                ? '已识别到验证码（${ticket.length} 字符），可直接提交继续登录。'
                : '在上面的页面里完成验证。识别到验证码会自动填到下面；'
                    '若一直没识别到，把页面上的验证码复制到这里。',
            style: TextStyle(
              color: hasTicket
                  ? TelegramColors.online
                  : TelegramColors.textSecondary,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('qq8-verify-ticket'),
            controller: _manual,
            onChanged: (_) => setState(() {}),
            maxLines: 2,
            minLines: 1,
            style: const TextStyle(fontSize: 12),
            decoration: const InputDecoration(
              isDense: true,
              labelText: '验证码（ticket）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton(
                  key: const ValueKey('qq8-verify-submit'),
                  onPressed: hasTicket ? _submit : null,
                  child: const Text('提交验证码并继续登录'),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: const ValueKey('qq8-verify-cancel'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
            ],
          ),
          if (_showTrace) ...<Widget>[
            const SizedBox(height: 8),
            SizedBox(
              height: 150,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: TelegramColors.bgSidebar,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: _trace.isEmpty
                    ? const Center(
                        child: Text('（还没有捕获到任何事件）',
                            style: TextStyle(fontSize: 12)))
                    : ListView.builder(
                        key: const ValueKey('qq8-verify-trace-list'),
                        padding: const EdgeInsets.all(6),
                        itemCount: _trace.length,
                        itemBuilder: (context, i) {
                          final t = _trace[i];
                          return Text(
                            '${t.kind}  ${t.text}',
                            style: const TextStyle(fontSize: 11, height: 1.35),
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                          );
                        },
                      ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '地址类事件的值已按长度打码（凭据不进日志）；这段记录在导出的日志里也能看到。',
              style: TextStyle(color: TelegramColors.textMuted, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一条捕获记录（`kind` 是来源，`text` 已按需打码）。
class _Trace {
  _Trace(this.kind, this.text);

  final String kind;
  final String text;
}