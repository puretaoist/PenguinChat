import 'dart:convert';
import 'dart:typed_data';

/// 登录成功后官方必发的两个 JCE 检查，以及它们的请求体。
///
/// ## 为什么要有这个文件
///
/// 官方 8.2.11 冷启动登录成功后，抢在一切业务之前先发两个检查：
///
/// ```
/// [14:41:5x] 0x0A flag=2 seq=50001 cmd=PhSigLcId.Check      payload 138B
/// [14:41:5x] 0x0A flag=2 seq=50002 cmd=PhSigLcId.Check      payload 138B
/// [14:41:5x] 0x0A flag=2 seq=17729 cmd=GrayUinPro.Check     payload 116B
/// ```
///
/// 两条都是 **flag=2**（全零密钥加密 SSO 层），所以抓包可直接解——这是
/// 官方登录后唯一能明文读到的一批请求，也是我们唯一能照抄的「前置握手」。
///
/// 我们此前从不发它们，于是服务端只推 `ConfigPushSvc.*` / `StatSvc.QueryHB`
/// 这类配置类推送，`OnlinePush.PbPushGroupMsg` / `MessageSvc.PushNotify`
/// 一条都不来（真机全量日志 0 命中）。这两个检查的语义分别是
/// 「上报签名信息」（`KQQConfig.SignatureReq/Resp`）与「查灰度名单」
/// （`KQQConfig.GrayUinCheckResp`），官方先过这两关，之后才收得到消息推送。
///
/// ## 为什么是「字节回放」
///
/// 请求体里的字段我们只解得出外壳（`Qq8Jce.decodeWrapper` 解出
/// `PhSigLcId` = `{1: ['be910af3…'], 2: 537064117, 3: [3499239040], 4: 0}`，
/// `GrayUinPro` = `{1: 537064117, 2: '3499239040', 3: '', 4: '627864465254787270'}`），
/// 但那个 32 位十六进制串与尾部的 `2002f2b5…`、`8c980ca8` 是谁的摘要、按什么
/// 规则算的并不知道。硬猜一个只会被服务端判成「签名不符」，比不发更糟。
///
/// 所以这里先做**同一账号、同一档案下的字节回放**：抓包来自就是本机
/// `3499239040` + `A8.2.11.4530` 这套档案，uin 与 subAppId 都一致。唯一
/// 会变的是 uin 的十进制字节——[payload] 会把它按调用方给的 uin 替换掉。
///
/// 先看服务端认不认（响应我们同样能解），再决定要不要把摘要算法也逆出来。
abstract final class Qq8OnlineCheck {
  /// `KQQConfig.SignatureReq` 的宿主命令（官方 `BaseConstants` 里叫
  /// `CMD_REQ_CHECKSIGNATURE`）。
  static const String cmdPhSigLcId = 'PhSigLcId.Check';

  /// 灰度名单查询（`KQQConfig.GrayUinCheckResp`）。
  static const String cmdGrayUinPro = 'GrayUinPro.Check';

  /// 抓包原样（2026-10-25 14:41，官方 8.2.11，uin=3499239040）。
  static const String _phSigLcIdHex =
      '10022c3c4c56094b5151436f6e666967660c5369676e61747572655265717d000063'
      '080001060372657118000106164b5151436f6e6669672e5369676e61747572655265'
      '711d00003c0a19000106206265393130616633396132366134613939326336666430'
      '316131343365643139222002f2b5390001060a333439393233393034304c0b8c980c'
      'a80c';

  static const String _grayUinProHex =
      '10032c3c41454056224b51512e436f6e666967536572766963652e436f6e6669'
      '6753657276616e744f626a6609436c69656e745265717d000035080001060372'
      '65711d0000290a122002f2b5260a333439393233393034303600461236323738'
      '36343436353235343738373237300b8c980ca80c';

  /// 抓包时的 uin，替换用（十进制 ASCII 10 位）。
  static const String _capturedUin = '3499239040';

  /// `PhSigLcId.Check` 的请求体。
  static Uint8List phSigLcIdPayload(int uin) => _replay(_phSigLcIdHex, uin);

  /// `GrayUinPro.Check` 的请求体。
  static Uint8List grayUinProPayload(int uin) => _replay(_grayUinProHex, uin);

  /// 把回放体里的 uin 十进制串换成 [uin]。
  ///
  /// 只替换第一处出现的 `_capturedUin`：两个请求体里 uin 都只出现一次，
  /// 而 `2002f2b5…`、`8c980ca8` 这些尾巴里若碰巧含同样数字串也不该动。
  /// 位数不同会改变长度，但 JCE 的字符串字段自带长度前缀——**这里刻意不做
  /// 长度改写**：一旦 uin 位数变化，字段长度就不匹配了，宁可整体不替换，
  /// 让服务端明确拒绝（日志里能看出来），也不要送一个自相矛盾的包。
  static Uint8List _replay(String hex, int uin) {
    final bytes = Uint8List.fromList(List<int>.generate(
      hex.length ~/ 2,
      (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
    ));
    final want = '$uin';
    if (want.length != _capturedUin.length) return bytes;
    final needle = ascii.encode(_capturedUin);
    final replacement = ascii.encode(want);
    for (var i = 0; i + needle.length <= bytes.length; i++) {
      var hit = true;
      for (var k = 0; k < needle.length; k++) {
        if (bytes[i + k] != needle[k]) {
          hit = false;
          break;
        }
      }
      if (!hit) continue;
      bytes.setRange(i, i + replacement.length, replacement);
      break;
    }
    return bytes;
  }
}
