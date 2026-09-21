/// L2 内核：滑动验证的**识别**（只在文本里认字符串，不联网、不自动化）
///
/// ## 为什么单独一个文件
///
/// 服务端要求验证时（响应 `type=2`，`0x192` 是验证地址），ticket 可能从好几个
/// 口子出来：页面跳转的 URL、页面里 JS 桥的返回值、页面正文自己显示的一段字符串。
/// 这些口子由 L4 的应用内 WebView（`lib/ui/pages/qq8_verify_page.dart`）去开，
/// 但"在一堆文本里认出哪个是 ticket"是**纯字符串逻辑**——放在内核层就能用
/// `tool/qq8_captcha_selftest.dart` 离线测，不必上真机。
///
/// ## ticket 长什么样（拿真东西说话，不猜格式）
///
/// 本仓库真机记录（8.2.11 提交子命令 2 时用的那个，214 字符）：
///
/// ```text
/// t03tserverRRr8TObw-HxcXUWcM4uOcrRwqMIxzKU2FTbA_Oki_eikHb3SrUPwkVLDYTG8xbgVQtgdU
/// Kim4xadWtwg4t3_lEhFZZnJ77M3V6rF1g411c6d9cgmzBHUKEmwEsdzv06z-rQf68D2mnGWd46946t
/// VqIR9y2o4Se1kZETB90_FqpF3ozMg--ARhCqF0nCITjEaR5dq56D4Uss*
/// ```
///
/// 三条特征很稳定，本文件就按这几条认：
///
/// 1. **以 `t0` 开头**；
/// 2. **以 `*` 结尾**（URL 里出现时常被编码成 `%2A`，见下）；
/// 3. 中间是 base64url 字符集，总长 200 上下（判据取宽松的 30+）。
///
/// ## 不做什么
///
/// **不自动解题、不代替人操作**（AGENTS §1.6 的"不做规避风控的事"）：
/// 本文件只认字符串；认出来之后要不要提交、什么时候提交，由人点按钮决定。
library;

import '../../infra/log/logger.dart';

/// 强判据：`t0` + base64url 主体 + 结尾的 `*`。
final RegExp _strong = RegExp(r't0[A-Za-z0-9_+/\-]{30,}\*');

/// 弱判据（只在强判据全落空时用）：没有结尾 `*`，但主体足够长。
///
/// 之所以留这一手：有的环节会把 ticket 掐掉尾部的 `*` 再塞进别的文本里，
/// 而 60 个连续 base64url 字符紧跟在 `t0` 后面，误报概率可以忽略。
final RegExp _weak = RegExp(r't0[A-Za-z0-9_+/\-]{60,}');

/// 在一段文本里找 ticket；找不到返回 null；多个候选取**最长**的一个。
///
/// 之所以"取最长"而不是"取第一个"：真 ticket 200+ 字符，页面里更短的同形串
/// （比如被截断的日志、示例文本）几乎一定不是我们要的。
String? qq8FindTicket(String text) {
  final candidates = qq8TicketCandidates(text);
  if (candidates.isEmpty) return null;
  var best = candidates.first;
  for (final c in candidates) {
    if (c.length > best.length) best = c;
  }
  return best;
}

/// 列出文本里所有看起来像 ticket 的串（去重，保持出现顺序）。
///
/// 判定顺序：先按强判据扫原文；没有就试一次百分号解码（URL 里 `*` 写成 `%2A`）；
/// 仍然没有才退到弱判据——**不叠加**，避免把同一个 ticket 的两种形态都收进来。
List<String> qq8TicketCandidates(String text) {
  final found = <String>[];

  void scan(RegExp re, String s) {
    for (final m in re.allMatches(s)) {
      final v = m.group(0);
      if (v != null && !found.contains(v)) found.add(v);
    }
  }

  scan(_strong, text);
  if (found.isEmpty && text.contains('%')) {
    // 百分号解码可能失败（页面文本里常有裸的 % 号），失败就当作"没这条线索"。
    try {
      scan(_strong, Uri.decodeComponent(text));
    } on ArgumentError {
      // 忽略：不是合法编码，继续走弱判据
    }
  }
  if (found.isEmpty) scan(_weak, text);
  return found;
}

/// 把 URL 的查询串按 [Redact] 的**敏感键名单**打码：命中的键只留 `<len N>`。
///
/// 为什么要打码：验证地址里的 `sig` / `ticket` / `pskey` 一类参数是能顶替身份用的
/// 凭据（AGENTS §1.5），而排障只需要知道"跳到哪个域、带了哪些参数名、值有多长"
/// ——这正好也是判断"ticket 是不是从 URL 里回来的"所需的全部信息。
///
/// 不敏感的参数原样保留；但超过 [maxValue] 字符的一律截断——名单认不出来的长串
/// 同样不该整段落进日志。
String qq8RedactUrl(String url, {int maxValue = 40}) {
  final q = url.indexOf('?');
  if (q < 0) return url;
  final head = url.substring(0, q);
  final parts = url.substring(q + 1).split('&');
  final rendered = <String>[];
  for (final p in parts) {
    final eq = p.indexOf('=');
    if (eq < 0) {
      rendered.add(p);
      continue;
    }
    final key = p.substring(0, eq);
    final value = p.substring(eq + 1);
    if (Redact.isSensitive(key)) {
      rendered.add('$key=<len ${value.length}>');
    } else if (value.length > maxValue) {
      rendered.add('$key=${value.substring(0, maxValue)}…');
    } else {
      rendered.add(p);
    }
  }
  return '$head?${rendered.join('&')}';
}