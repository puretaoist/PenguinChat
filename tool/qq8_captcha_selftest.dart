/// 滑动验证码「识别」离线自测（纯 Dart，不联网、不碰 WebView）
///
/// 覆盖 `lib/kernel/wlogin8/qq8_captcha.dart`：在一堆文本里认出 ticket，
/// 以及排障用的 URL 打码。用**真机真值**当样本（8.2.11 那次提交子命令 2 用的
/// 214 字符 ticket），所以这个自测同时也是"字符集没写窄"的回归防线——
/// 一旦正则漏掉 `-` / `_`，真值就会被截断，这里立刻红。
///
/// 关于这条真值：它是**一次性、早已过期**的验证码（那个会话当时就被服务端拒了，
/// `type=1`），留在这里只作向量——没有真值就证明不了字符集宽度。除此之外本工程
/// 不落任何票据（凭据一律 `Redact` / 打码，见 AGENTS §1.5）。
///
/// 运行：
/// ```bash
/// dart run tool/qq8_captcha_selftest.dart
/// ```
library;

import 'dart:io';

import 'package:qqclient/kernel/wlogin8/qq8_captcha.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✓ $name${detail == null ? '' : '   ($detail)'}');
  } else {
    _fail++;
    stdout.writeln('  ✗ $name${detail == null ? '' : '  ($detail)'}');
  }
}

void section(String t) => stdout.writeln('\n$t');

/// 真机 ticket（2026-09-21 8.2.11 提交时用的那个），**逐字符照抄**。
const String _realTicket = 't03tserverRRr8TObw-HxcXUWcM4uOcrRwqMIxzKU2FTbA_Oki_eikHb3SrUPwkV'
    'LDYTG8xbgVQtgdUKim4xadWtwg4t3_lEhFZZnJ77M3V6rF1g411c6d9cgmzBHUKEmwEsdzv06z'
    '-rQf68D2mnGWd46946tVqIR9y2o4Se1kZETB90_FqpF3ozMg--ARhCqF0nCITjEaR5dq56D4Uss*';

void main() {
  stdout.writeln('=== 滑动验证码识别自测 ===');

  section('[1] 真值：那个 214 字符的 ticket 必须原样认出来');
  {
    check('真值长度正是 214（确认样本没抄错/抄漏）', _realTicket.length == 214,
        'len=${_realTicket.length}');
    check('裸 ticket 命中且逐字符一致', qq8FindTicket(_realTicket) == _realTicket,
        'len=${qq8FindTicket(_realTicket)?.length}');

    final inUrl = 'https://example.invalid/done?ticket=$_realTicket&ret=0';
    check('URL 查询参数里的 ticket 能认出',
        qq8FindTicket(inUrl) == _realTicket);

    final encoded = Uri.encodeComponent(_realTicket);
    check('百分号编码形态（* -> %2A）能认出',
        qq8FindTicket('https://example.invalid/done?ticket=$encoded') ==
            _realTicket);

    final page = '验证成功\n请勿关闭页面\n验证码：$_realTicket\n（有效期 5 分钟）';
    check('夹在页面正文里能认出', qq8FindTicket(page) == _realTicket);
  }

  section('[2] 不该误伤：没有 ticket 的文本一律返回 null');
  {
    check('空串', qq8FindTicket('') == null);
    check('普通中文提示', qq8FindTicket('请拖动滑块完成拼图') == null);
    // 长得像但不是：没有 t0 前缀的长 base64（比如 pskey、图片数据）
    final notTicket = 'A' * 300;
    check('无 t0 前缀的长串', qq8FindTicket(notTicket) == null);
    check('t0 但主体太短', qq8FindTicket('t0abc') == null);
    check('t0 + 短主体 + 结尾星号', qq8FindTicket('t0shortbody*') == null);
  }

  section('[3] 兜底：缺结尾 `*` 时用弱判据');
  {
    final noStar = _realTicket.substring(0, _realTicket.length - 1);
    check('缺结尾 `*` 也能认出（弱判据）', qq8FindTicket(noStar) == noStar);
    // 强判据命中时不应该再叠加弱判据的结果（否则同一个码会出现两个候选）
    final candidates = qq8TicketCandidates('$_realTicket 以及残缺形态 $noStar');
    check('强判据命中时不叠加弱判据', candidates.length == 1,
        'candidates=${candidates.length}');
  }

  section('[4] 多个候选取最长（真 ticket 200+，短的多半是同形噪音）');
  {
    const short = 't03tserverSHORT-ButStillLongEnoughToMatchTheWeakRule*';
    final got = qq8FindTicket('$short\n$_realTicket');
    check('选最长的一个', got == _realTicket, 'len=${got?.length}');
  }

  section('[5] 排障用的 URL 打码：保留域名/参数名，值按长度打码');
  {
    const url =
        'https://ti.qq.com/safe/tools/captcha/sms-verify-login?uin=10001'
        '&sig=0123456789abcdef&_wv=1027';
    final red = qq8RedactUrl(url);
    check('保留域名与路径',
        red.startsWith('https://ti.qq.com/safe/tools/captcha/sms-verify-login?'),
        red);
    check('敏感键（sig）只留长度', red.contains('sig=<len 16>'), red);
    check('不敏感参数（uin/_wv）原样保留',
        red.contains('uin=10001') && red.contains('_wv=1027'), red);
    check('敏感值原文不出现', !red.contains('0123456789abcdef'));
    const longUnknown =
        'https://a.invalid/x?blob=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH';
    final redLong = qq8RedactUrl(longUnknown);
    check('名单认不出的超长值也截断', redLong.contains('…') && redLong.length < 90,
        redLong);
    check('无查询串的 URL 原样返回',
        qq8RedactUrl('https://ti.qq.com/safe') == 'https://ti.qq.com/safe');
  }

  section('[6] 日志打码：把 ticket 换成占位，其余文字原样保留');
  {
    const prose = '验证成功，请返回 QQ 继续登录';
    check('无 ticket 的文本原样返回', qq8MaskTickets(prose) == prose);
    final masked = qq8MaskTickets('验证成功 ticket=$_realTicket 有效');
    check('ticket 被换成占位', masked.contains('<ticket 214>'), masked);
    check('ticket 原文不出现', !masked.contains('t03tserver'));
    check('周围的文字保留', masked.contains('验证成功') && masked.contains('有效'),
        masked);
    check('多处 ticket 都打码',
        qq8MaskTickets('$_realTicket|$_realTicket').split('<ticket').length == 3);
  }

  stdout.writeln('\n=== 结果: $_pass 通过, $_fail 失败 ===');
  exit(_fail == 0 ? 0 : 1);
}