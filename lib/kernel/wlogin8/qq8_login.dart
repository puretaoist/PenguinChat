/// L2 协议内核：QQ 密码登录主流程
///
/// ## 报文结构
///
/// 一次登录请求自上而下是四层：
///
/// ```text
///   [传输层]      u32 总长（含自身 4 字节）           ← qq8_tran.dart
///   [登录信封]    u32 长 ‖ 0x0A ‖ type ‖ d2 ‖ uin ‖ …
///   [SSO 信封]    seq ‖ subid ‖ BUF_UNKNOWN ‖ tgt ‖ cmd ‖ session ‖ imei ‖ ksid
///   [登录 body]   u16 子命令 ‖ u16 TLV 个数 ‖ TLV…    ← 本文件
/// ```
///
/// 响应则反向解：
///
/// ```text
///   payload[16 : len-1]  --TEA(share_key)-->  u16 ‖ u8 type ‖ u16 ‖ TLV…
/// ```
///
/// 来源：`takayama-lily/oicq` 的 `lib/wtlogin/wt.js`
/// （`sendLogin` / `_decodeLoginResponse` / `readTlv` / `decodeT119`）与
/// `lib/wtlogin/login-password.js`（各步的子命令与 TLV 清单）。
///
/// ## 响应侧：对着官方 9.3.60 反编译逐行核过（2026-09-11）
///
/// 四个包里 9.3.60 的反编译最完整、可 `--show-bad-code` 出全量控制流。
/// 响应解析的每个关键偏移在下述两个方法里都有一一对应
/// （`9.3.60_23e3f34e30110797.apk` → `classes5.dex`，jadx 1.5.6；
/// 类名是混淆过的，**逐版本会变**，这里是 9.3.60 的字母）：
///
/// | 本文件的做法 | 官方写法 | 位置 |
/// |---|---|---|
/// | 只解 `[16, len-1)`（丢 16 头 + 1 尾） | `this.d = (this.c - 15) - 2;` → `a(this.e, 16, this.d, wVar.m)` | `oicq_request.d()` |
/// | 首层密钥 = ECDH share key | `this.mG.m = ecdhCrypt.get_g_share_key();` | `WtloginHelper.ShareKeyInit()` |
/// | 明文至少 5 字节 | `if (i2 < 5) return -1009;` | `oicq_request.c()` 开头 |
/// | 类型 = **明文第 2 字节** | `iB = b(bArr14, i + 2);`，`b(...) = bArr[i] & 255` | `c()` / `b(byte[],int)` |
/// | TLV 从明文**偏移 5** 起 | `i19 = i + 5;`，TLV 区 `(this.c - i19) - 1` | `c()` |
/// | `0x119` 用 tgtgt 再解一层 | `tlv_tVar.get_tlv(bArr14, i19, …, async_contextVarB._tgtgt_key)` | `c()`；`tlv_t.get_tlv(…, key)` |
/// | `0x119` 内子 TLV 从**偏移 2** 起 | `tlv_t10aVar.get_tlv(bArr15, 2, length)` 等 | `c()` |
/// | TLV 容器 = 裸 `tag‖len‖body` 序列，**无计数前缀** | `search_tlv` 按 `i = len + 4 + i` 递进 | `tlv_t.search_tlv` |
///
/// 这张表把响应侧从"往返测试（C）"抬到"官方反编译对照（A）"。
/// 仍然只有真机能回答的只剩一件事：**服务端是否接受我们的包**。
///
/// ## 子命令取值（官方 `oicq.wlogin_sdk.request.k/u` 的 `this.u`）
///
/// | 子命令 | 含义 | TLV 数（官方） |
/// |---|---|---|
/// | 9 | 密码登录（`wtlogin.login`） | 24 |
/// | 2 | 滑动验证码提交（人工解出 ticket 后，`wtlogin.login`） | 4（清单 [qq8SliderTlvOrder]） |
/// | 7 | 提交短信验证码 | 7 |
/// | 8 | 请求下发短信 | 6 |
/// | 11 | token 登录 / 票据续期（`wtlogin.exchange_emp`） | 16（清单 [qq8ExchangeEmpTlvOrder]） |
/// | 20 | 设备锁 | 4 |
///
/// 本文件是纯 Dart。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../infra/coder.dart';
import '../crypto/tea.dart';
import 'qq8_tlv.dart';

/// 登录 body 里的子命令。
abstract final class Qq8SubCmd {
  static const int password = 9;
  static const int slider = 2;
  static const int submitSms = 7;
  static const int sendSms = 8;
  static const int token = 11;
  static const int device = 20;
}

/// 登录响应第 3 字节的类型（官方 `oicq_request.c()` 里的 `iB`，
/// 即明文偏移 2 的无符号字节）。
abstract final class Qq8LoginResultType {
  /// 成功。走 `c()` 的 `iB == 0` 分支解析 `0x119` 票据块。
  static const int success = 0;

  /// 需要滑动验证码。
  ///
  /// `c()` 的 `iB == 2` 分支：先取 `0x104`（新盐），再取 `0x192`
  /// 并读 `getUrl()` 作为验证地址（另与会取 `0x546`）。
  static const int slider = 2;

  /// 设备锁 / 需要二次验证。
  ///
  /// `c()` 的 `case 204:` 分支（日志里写作 `type = 0xcc`），
  /// 取 `0x113`(uin) / `0x104` / `0x402` / `0x403` 进 devlock 流程。
  static const int deviceLock = 204;

  /// 手机号短信验证登录的状态码（官方 `oicq_request.java` 的 `case 208 / 232`）。
  ///
  /// * `208(0xD0)`：检查/下发那一步的回包——带 `0x104`（新盐）、`0x126`（随机数，
  ///   提交验证码时要回带）、`0x182`（验证码计数 + 有效期，单位秒）、`0x183`（msalt）；
  /// * `232(0xE8)`：带 `0x104` + `0x52B`（zone + 提示手机号）——同一流程的另一种形态。
  ///
  /// ⚠️ 注意 [smsVerify3]（239）是**旧路**（密码登录后补短信）的码，和这两个不是一条线；
  /// 0xED(237) 更不是短信分支（它是带 `0x146` 提示的失败）。
  static const int smsLoginCheck = 208;
  static const int smsLoginRefresh = 232;

  /// 短信码验证的三个返回码（参考实现 `decodeLoginResponse` 同一分支）。
  ///
  /// 收到它们时：`0x174`（令牌，必须回带）+ `0x178`（手机号展示）在场则存下来，
  /// 之后用**子命令 8** 请求下发、**子命令 7** 提交码。
  /// `0x204`+`0x174` 都不在时，参考实现认为"已自动下发短信"，只需等码。
  static const int smsVerify1 = 160;
  static const int smsVerify2 = 162;
  static const int smsVerify3 = 239;
}

/// 登录 TLV 的准入条件。
///
/// **必须显式建模，不能靠"body 为空就跳过"** —— 8.9.50 的 `0x544`
/// 正是合法的空 body TLV，用空判断会把它误删。
///
/// 每一条都对应官方 `k.java` / `j.java` 的 guard，见 `qq8_tlv.dart` 里各
/// case 的注释。默认值全部取"取不到"的分支，等价于官方**首次登录**的情形。
class Qq8LoginConditions {
  /// 账号串是否已是 uin 形式（是则**不发** `0x112`）。
  final bool accountIsUin;

  /// 登录标志位；`0x166` 仅在 `(flags & 128) != 0` 时发。
  final int flags;

  /// 登录类型；`0x185` 仅在等于 3 时发。
  final int loginType;

  /// 缓存的口令盐（`async_context._t104`）。
  ///
  /// ⚠️ **首登时为空，此时官方整个跳过 `0x104`**（不是发空包）：
  /// ```java
  /// case tlv_t104.CMD_104:
  ///     if (bArr8 == null || bArr8.length == 0) { /* 不产出 */ }
  ///     else bArr11 = new tlv_t104().get_tlv_104(bArr8);
  /// ```
  final Uint8List? t104;

  /// 服务端回显的 `t.r`；`0x172` 仅非空时发。
  final Uint8List? echoedR;

  /// 静态 `k.L`；`0x201` 仅非空时发。
  final Uint8List? staticL;

  /// `t.an`；`0x548` 的官方路径——仅非空时发。
  ///
  /// 另有维护版 oicq 的客户端自构造路径（[t548]）：密码登录无条件携带。
  final Uint8List? an;

  /// 客户端自构造的 `0x548` PoW 应答（维护版 oicq v1.26.25 路径）。
  final Uint8List? t548;

  /// `tgtQR`；`0x318` 仅二维码登录时发。
  final Uint8List? tgtQR;

  /// `0x16A` 的源（短信验证票据），官方 `k.java:186` 有空判。
  final Uint8List? t16a;

  /// 是否已有可用的登录票据（`WloginSigInfo`）。
  ///
  /// `0x400` 需要它：官方 `case 1024` 在 `wloginSigInfo == null` 时整条跳过，
  /// 故**首登不发**，只有票据续期时才发。
  final bool hasSig;

  /// `0x545`（QIMEI）的源串（官方 `u.T` / `t.T`）。
  ///
  /// **取不到就整条不发**——官方 `j.java` case 1349 只在 QIMEI 非空时才
  /// `new tlv_t545().get_tlv_545(...)`，为空时仅上报一个错误事件、不产出
  /// TLV。所以我们用"有没有 QIMEI"做 guard，而不是发一个空 body
  /// （那是与官方不一致的偏差，2026-09-11 修正）。
  final String? qimei;

  /// d2 票据（登录成功时 0x119 块里的 `0x143`）。
  ///
  /// 只有 token 登录（子命令 11）会用它：`0x143` 的 body 就是 d2 本体。
  /// 没有 d2 时发这条请求没有意义，故 guard 用"有没有 d2"
  /// （清单见 [qq8ExchangeEmpTlvOrder]）。
  final Uint8List? d2;

  /// 二次验证令牌（响应 `0x174`）。
  ///
  /// 短信码流程（子命令 8 请求下发 / 7 提交码）必须回带它——参考实现
  /// `base-client.ts` 收到 160/162/239 且 `0x174`+`0x178` 都在时，
  /// 把它存进 `sig.t174` 供这两条请求用。
  final Uint8List? t174;

  const Qq8LoginConditions({
    this.accountIsUin = true,
    this.flags = 0,
    this.loginType = 1,
    this.t104,
    this.echoedR,
    this.staticL,
    this.an,
    this.t548,
    this.tgtQR,
    this.t16a,
    this.hasSig = false,
    this.qimei,
    this.d2,
    this.t174,
  });

  /// 密码首登的默认条件：一律取"取不到"的分支，等价于官方首次登录的情形。
  static const Qq8LoginConditions firstPasswordLogin = Qq8LoginConditions();

  static bool _nonEmpty(Uint8List? v) => v != null && v.isNotEmpty;

  static bool _nonEmptyStr(String? v) => v != null && v.isNotEmpty;

  /// 该 TLV 在当前条件下是否应当出现在包里。
  ///
  /// ## 与官方 guard 的一处**有意偏离**
  ///
  /// 官方对 `0x187`（`t.N`）/ `0x188`（`t.O`）/ `0x194`（`t.L`）/
  /// `0x202`（`t.R`）都有"静态字段为空则跳过"的判断。但那四个静态字段是由
  /// `QQAppInterface` 在运行期填的，**在我们的实现里它们的值是直接从设备对象
  /// 派生的**（`MD5(mac)` / `MD5(android_id)` / `imsi` / `bssid+ssid`），
  /// 永不为空。
  ///
  /// 参考实现 oicq 也正是**无条件发送**这四个，且长期实测可用。
  /// 因此这里**不加空判**，跟 oicq 走。
  bool applies(int tag) {
    switch (tag) {
      case 0x104:
        return _nonEmpty(t104); // 首登无缓存盐 → 官方整条跳过
      case 0x112:
        return !accountIsUin; // uin 登录不发
      case 0x166:
        return (flags & 128) != 0;
      case 0x16A:
        return _nonEmpty(t16a);
      case 0x172:
        return _nonEmpty(echoedR);
      case 0x185:
        return loginType == 3;
      case 0x201:
        return _nonEmpty(staticL);
      case 0x318:
        return _nonEmpty(tgtQR); // 二维码路径专用
      case 0x400:
        return hasSig; // 首登无票据 → 发给服务端只会被拒
      case 0x529:
        return false; // 三版本都无构建点，永不发
      case 0x545:
        return _nonEmptyStr(qimei); // 取不到 QIMEI → 官方整条不发（j.java case 1349）
      case 0x548:
        // 官方路径（服务端下发的 t.an）或维护版路径（客户端自构造 PoW）任一非空。
        return _nonEmpty(an) || _nonEmpty(t548);
      case 0x143:
        return _nonEmpty(d2); // token 登录专有：没有 d2 发出去只会被拒
      case 0x174:
        return _nonEmpty(t174); // 短信码流程要回带的二次验证令牌
      default:
        return true;
    }
  }
}

/// 登录 body 组装。
/// 手机号短信验证登录的 TLV 表（官方 `request/w.java`（17）/`x.java`（19）/`y.java`（18））。
///
/// 三张表**顺序即官方数组序**（不是我们平时用的那张 37 项大表）：
/// * 17 检查手机号：**第三套数组**（带账号串）——账号串进 `0x112`，不含 `0x104`/`0x52C`；
/// * 19 下发/刷新验证码：只要 4 项；
/// * 18 提交验证码：`0x127`（验证码 + 上一步的随机数）与 `0x184`（口令块）。
abstract final class Qq8SmsLoginTlvOrder {
  /// 17 检查手机号能否短信登录——**官方"带账号串"那套数组，逐项照抄**。
  ///
  /// 官方 `request/w.java:20-29` 按参数分三套数组：
  /// ```text
  /// bArr2 == null, i3 != 1 : {0x100, 0x108, 0x109, 0x52D, 0x8, 0x142, 0x145, 0x154, 0x52C, 0x116, 0x521}
  /// bArr2 == null, i3 == 1 : {0x100, 0x104, 0x108, …, 0x154, 0x52C, 0x116, 0x521}
  /// bArr2 != null          : {0x100, 0x108, 0x109, 0x52D, 0x8, 0x142, 0x145, 0x154, 0x112, 0x116, 0x521}
  /// ```
  /// `bArr2` 是**账号串**（`w.java:135` 的 `get_tlv_112(bArr2)`）；手机号登录必然带它，
  /// 所以走第三套：**没有 `0x104`、没有 `0x52C`**，账号串插在 `0x154` 之后。
  ///
  /// 调用处 `WtloginHelper.java:2700`（`CheckSMSVerifyLoginAccount`）里
  /// `bArr2 = str == null && i4 == 1 ? t.al : null`，而 `str` 就是手机号 → 第三套。
  static const List<int> check = <int>[
    0x100, 0x108, 0x109, 0x52D, 0x8, 0x142, 0x145, 0x154, 0x112, 0x116, 0x521,
  ];

  /// 19 下发 / 刷新验证码。
  static const List<int> refresh = <int>[0x104, 0x8, 0x116, 0x521];

  /// 18 提交验证码。
  static const List<int> verify = <int>[
    0x104, 0x8, 0x127, 0x184, 0x116, 0x521,
  ];
}

abstract final class Qq8LoginBody {
  /// 子命令 17：检查手机号能否短信验证登录（官方 `w.java`）。
  ///
  /// [phone] 是手机号**原文**——手机号不是 uin（官方 `check_uin_account` 只认
  /// [10000, 4000000000]），所以会带上 `0x112` 账号串。
  ///
  /// 官网调用处 `msf/core/auth/l.java:796` 传的就是手机号，且国内号**不带** `86` 前缀
  /// （`!countryCode.startsWith("86") ? "00"+countryCode+phone : phone`）。
  static Uint8List buildSmsLoginCheck(
    Qq8TlvContext ctx, {
    required String phone,
  }) =>
      build(
        ctx,
        17,
        Qq8SmsLoginTlvOrder.check,
        // 条件必须把 ctx 里的值带上（尤其 t104）：`applies()` 是按 cond 判的，
        // 只写 accountIsUin 会把"有盐"判成"没盐"，0x104 就被跳过了。
        cond: Qq8LoginConditions(accountIsUin: false, t104: ctx.t104),
        args: <int, List<Object?>>{
          0x112: <Object?>[phone],
        },
      );

  /// 子命令 19：下发 / 刷新验证码（官方 `x.java`）。盐从 `ctx.t104` 来——
  /// 条件里必须带上它，否则 0x104 会被 guard 跳过。
  static Uint8List buildSmsLoginRefresh(Qq8TlvContext ctx) => build(
        ctx,
        19,
        Qq8SmsLoginTlvOrder.refresh,
        cond: Qq8LoginConditions(t104: ctx.t104),
      );

  /// 子命令 18：提交验证码（官方 `y.java`）。
  ///
  /// * [code] 验证码原文；
  /// * [random] 上一步回包 `0x126` 里的随机数（长度自定，官方原样回带）；
  /// * [mpasswd] 本地现生成的 16 位随机字母串（`util.get_mpasswd()` 同款）；
  /// * [msalt] 上一步回包 `0x183` 的 msalt。
  static Uint8List buildSmsLoginVerify(
    Qq8TlvContext ctx, {
    required String code,
    required Uint8List random,
    required String mpasswd,
    required int msalt,
  }) =>
      build(
        ctx,
        18,
        Qq8SmsLoginTlvOrder.verify,
        // 条件必须把 ctx 里的值带上（尤其 t104）：`applies()` 是按 cond 判的，
        // 只写 accountIsUin 会把"有盐"判成"没盐"，0x104 就被跳过了。
        cond: Qq8LoginConditions(accountIsUin: false, t104: ctx.t104),
        args: <int, List<Object?>>{
          0x127: <Object?>[utf8.encode(code), random],
          0x184: <Object?>[mpasswd, msalt],
        },
      );

  /// 组装 `u16 子命令 ‖ u16 TLV 个数 ‖ TLV…`。
  ///
  /// [tags] 是候选顺序（通常取档案的 `loginTlvOrder`）；
  /// [cond] 会先把不适用的项滤掉；[args] 给需要参数的 TLV 传参。
  ///
  /// 返回的字节可直接交给 `Qq8Sso.buildOicqPacket`。
  static Uint8List build(
    Qq8TlvContext ctx,
    int subCmd,
    List<int> tags, {
    Qq8LoginConditions cond = Qq8LoginConditions.firstPasswordLogin,
    Map<int, List<Object?>> args = const <int, List<Object?>>{},
  }) {
    final parts = <Uint8List>[];
    for (final tag in tags) {
      if (!cond.applies(tag)) continue;
      parts.add(Qq8Tlv.pack(ctx, tag, args[tag] ?? const <Object?>[]));
    }

    final w = ByteWriter()
      ..u16(subCmd)
      ..u16(parts.length);
    for (final p in parts) {
      w.raw(p);
    }
    return w.build();
  }

  /// 与 [build] 同源，但返回被采用的 tag 列表（自测用）。
  static List<int> plan(
    List<int> tags, {
    Qq8LoginConditions cond = Qq8LoginConditions.firstPasswordLogin,
  }) =>
      tags.where(cond.applies).toList();

  /// 从**已组好的** body 里读出子命令与实际发出的 TLV 编号（排障用）。
  ///
  /// 布局见 [build]：`u16 子命令 ‖ u16 个数 ‖ [u16 tag ‖ u16 len ‖ body]…`。
  /// 为什么不拿 [plan] 的结果代替：guard 会按条件滤项、档案会换表，
  /// 而真机出问题时"计划发的"和"实际发的"差别正是要找的东西——
  /// 真机日志原先只有**响应**的 TLV，发出去的一直靠推断（2026-09-21 的教训）。
  static (int, List<int>) peekBody(Uint8List body) {
    final r = ByteReader(body);
    if (r.remaining < 4) return (0, const <int>[]);
    final subCmd = r.readUint16();
    final count = r.readUint16();
    final tags = <int>[];
    for (var i = 0; i < count && r.remaining >= 4; i++) {
      final tag = r.readUint16();
      final len = r.readUint16();
      tags.add(tag);
      if (r.remaining < len) break;
      r.read(len);
    }
    return (subCmd, tags);
  }

  /// token 登录（子命令 11，命令字 `wtlogin.exchange_emp`）的便捷入口。
  ///
  /// [d2] 来自上次登录成功时响应 `0x119` 票据块里的 `0x143`（见
  /// [Qq8SigBundle.d2]）；tgt 由 `ctx.tgt` 提供。这条路径**不需要密码**，
  /// 是"票据续期"的低风险登录形态。
  static Uint8List buildToken(Qq8TlvContext ctx, {required Uint8List d2}) =>
      build(
        ctx,
        Qq8SubCmd.token,
        qq8ExchangeEmpTlvOrder,
        cond: Qq8LoginConditions(d2: d2),
        args: <int, List<Object?>>{
          0x143: <Object?>[d2],
        },
      );

  /// 滑动验证码提交（子命令 2，命令字 `wtlogin.login`）的便捷入口。
  ///
  /// 流程：密码登录被要求验证（响应 `type == 2` + TLV `0x192` 是验证地址）
  /// → **人来把滑块解掉**（这是正常流程，不做任何自动化）→ 用拿到的
  /// [ticket] 发这条请求继续登录。
  ///
  /// [ctx] 里的 `t104` 必须是**上一条响应下发的盐**（`0x104`）：没有它
  /// 这条请求无意义，官方参考实现也直接拒绝发送——所以这里显式校验。
  static Uint8List buildSlider(Qq8TlvContext ctx, {required String ticket}) {
    if (ctx.t104.isEmpty) {
      throw Qq8LoginException(
        '滑动验证提交缺少盐（ctx.t104 为空）：盐来自上一条响应（type=2）的 0x104',
      );
    }
    if (ticket.trim().isEmpty) {
      throw Qq8LoginException('滑动验证提交的 ticket 为空');
    }
    return build(
      ctx,
      Qq8SubCmd.slider,
      // 官方三版本对照（2026-09-15）：193/8/104/116/547 恒在（547 空时发空
      // body），8.9.50+ 加 544（空 body），无 542——见 qq8SliderTlvOrderFor。
      qq8SliderTlvOrderFor(ctx.apk),
      // 盐要同时在 guard（条件对象）与 body（ctx.t104）两侧可见：
      // guard 决定 0x104 是否进包，body 决定它的内容。
      cond: Qq8LoginConditions(t104: ctx.t104),
      args: <int, List<Object?>>{
        0x193: <Object?>[ticket.trim()],
      },
    );
  }

  /// 设备锁解锁（子命令 20，命令字 `wtlogin.login`）。
  /// 出处：参考实现 `base-client.ts` 的 `decodeLoginResponse` —— 收到
  /// `type == 204` 时**自动**发这一条：体 = `0x08 / 0x104 / 0x116 / 0x401`
  /// （4 项，无子命令头以外的其它字段）。
  ///
  /// ⚠️ 盐（`ctx.t104`）来自那条 204 响应；没有它这条请求无意义，故显式校验。
  static Uint8List buildDeviceUnlock(Qq8TlvContext ctx) {
    if (ctx.t104.isEmpty) {
      throw Qq8LoginException(
        '设备锁解锁缺少盐（ctx.t104 为空）：盐来自 type=204 响应的 0x104',
      );
    }
    return build(
      ctx,
      Qq8SubCmd.device,
      const <int>[0x08, 0x104, 0x116, 0x401],
      cond: Qq8LoginConditions(t104: ctx.t104),
    );
  }

  /// 请求下发短信验证码（子命令 8，命令字 `wtlogin.login`）。
  ///
  /// 出处：参考实现 `base-client.ts` 的 `sendSmsCode()`，体 6 项：
  /// `0x08 / 0x104 / 0x116 / 0x174 / 0x17a / 0x197`。
  /// `0x174` 是上一条响应（160/162/239）给的二次验证令牌。
  static Uint8List buildSendSms(Qq8TlvContext ctx) {
    if (ctx.t104.isEmpty || ctx.t174.isEmpty) {
      throw Qq8LoginException(
        '请求下发短信缺少盐或令牌（ctx.t104 / ctx.t174 为空）：'
        '两者都来自上一条 type=160/162/239 响应',
      );
    }
    return build(
      ctx,
      Qq8SubCmd.sendSms,
      const <int>[0x08, 0x104, 0x116, 0x174, 0x17A, 0x197],
      cond: Qq8LoginConditions(t104: ctx.t104, t174: ctx.t174),
    );
  }

  /// 提交短信验证码（子命令 7，命令字 `wtlogin.login`）。
  ///
  /// 出处：参考实现 `base-client.ts` 的 `submitSmsCode(code)`，体 8 项：
  /// `0x08 / 0x104 / 0x116 / 0x174 / 0x17c(code) / 0x401 / 0x198 / 0x544`。
  ///
  /// ⚠️ 参考实现在码长不是 6 字节时会**静默替换成 "123456"**（那是它自己的
  /// 调试路径）；这里不跟随——码不合法直接抛错，避免把无意义的请求发出去。
  static Uint8List buildSubmitSms(Qq8TlvContext ctx, {required String code}) {
    if (ctx.t104.isEmpty || ctx.t174.isEmpty) {
      throw Qq8LoginException(
        '提交短信码缺少盐或令牌（ctx.t104 / ctx.t174 为空）',
      );
    }
    final trimmed = code.trim();
    if (trimmed.length != 6 || int.tryParse(trimmed) == null) {
      throw Qq8LoginException(
        '短信验证码必须是 6 位数字（收到 "${code.trim()}"）——'
        '参考实现会静默替换成 123456，这里刻意不跟随',
      );
    }
    return build(
      ctx,
      Qq8SubCmd.submitSms,
      const <int>[0x08, 0x104, 0x116, 0x174, 0x17C, 0x401, 0x198, 0x544],
      cond: Qq8LoginConditions(t104: ctx.t104, t174: ctx.t174),
      args: <int, List<Object?>>{
        0x17C: <Object?>[trimmed],
      },
    );
  }
  /// 二维码扫码登录（子命令 9，命令字 `wtlogin.login`）。
  ///
  /// ## `0x106` 的官方语义（2026-09-21 真机 type=155 后从 TIM 反编译定案）
  ///
  /// 确认后的轮询响应给四块料：t24(0x18)=t106料、t25(0x19)=nopicsig、
  /// t30(0x1E)=tgtgt、t101(0x65)=tgtQR。官方 `WtloginHelper:5252`（GetStWithPasswd
  /// 的扫码分支）把它们组装成：
  ///
  /// ```java
  /// _tmp_pwd       = d.l;   // = oicq_request.a(t24料, t30料) —— 纯拼接（6737 段）
  /// _tmp_no_pic_sig = d.m;  // = t25 料
  /// _tmp_pwd_type   = 1;    // 长度 <16 直接 -1016 拒发
  /// ```
  ///
  /// 而 t106 构造器（`j.java` case 262）对非空 `_tmp_pwd` **不做任何加工**：
  /// `set_data(bArr5); get_buf()` —— 即
  ///
  /// ```text
  /// 0x106 body = concat(t106料, tgtgt)   ← 原样字节，不加密、不重建
  /// ```
  ///
  /// （顺带：`0x16A ← nopicsig`（`j.java:413` case 362）、
  /// `0x318 ← async_context.tgtQR`（`:633` case 792），与我们原有行为一致。）
  ///
  /// ⚠️ 2026-09-21 之前我们只回带了 t106料（缺 tgtgt 后缀），真机四连 `type=155`
  /// 「你太久没有操作」——正是这里的差异。
  ///
  /// ⚠️ 成功响应的 `0x119` 要用**扫码得到的 tgtgt** 解密——调用方必须在发这条
  /// 之前把设备 tgtgt 换成它（`Qq8LoginService` 里就是这么做的），
  /// 否则票据解不出来。
  static Uint8List buildQrLogin(
    Qq8TlvContext ctx, {
    required Uint8List t106Data,
    required Uint8List tgtgt,
    required Uint8List t16a,
    required Uint8List tgtQR,
  }) {
    if (t106Data.isEmpty || tgtgt.isEmpty || t16a.isEmpty || tgtQR.isEmpty) {
      throw Qq8LoginException(
          '二维码登录缺少扫码材料（t106料=${t106Data.length}B / tgtgt=${tgtgt.length}B / '
          't16a=${t16a.length}B / tgtQR=${tgtQR.length}B）');
    }
    // 官方 `_tmp_pwd`：t106料 ‖ tgtgt（纯拼接，oicq_request.a(byte[],byte[])）
    final tmpPwdLen = t106Data.length + tgtgt.length;
    final tmpPwd = Uint8List(tmpPwdLen)
      ..setRange(0, t106Data.length, t106Data)
      ..setRange(t106Data.length, tmpPwdLen, tgtgt);
    if (tmpPwd.length < 16) {
      // 官方同款下限（WtloginHelper：`bArr5.length < 16 → -1016`）
      throw Qq8LoginException('扫码材料拼接后不足 16 字节（${tmpPwd.length}B），官方会拒发');
    }
    return build(
      ctx,
      Qq8SubCmd.password,
      qq8QrLoginTlvOrder,
      // 0x16A 的 guard 看的是条件对象里的 t16a（短信流程同款语义），
      // 二维码流程要显式把它带上，否则这一项会被滤掉、24 项变 23 项。
      cond: Qq8LoginConditions(tgtQR: tgtQR, t16a: t16a),
      args: <int, List<Object?>>{
        0x106: <Object?>[tmpPwd],
        0x16A: <Object?>[t16a],
        0x318: <Object?>[tgtQR],
      },
    );
  }
}

/// 二维码扫码登录的 TLV 清单（24 项，子命令 9）。
///
/// 出处：参考实现 `analysis/_ref/oicq-src/lib/core/base-client.ts` 的
/// `qrcodeLogin()` 里那个 writer 的顺序。与密码登录的区别：
///
/// * `0x106` = **concat(t106料, tgtgt) 原样**（TIM `j.java` case 262 的
///   `_tmp_pwd` 路径，2026-09-21 定案；之前只回带 t106料，真机 type=155）；
/// * `0x16a` 用扫到的 t25（nopicsig）；
/// * 末尾追加 `0x318`（tgtQR，`j.java:633` case 792）；
/// * 不发 `0x544/0x545/0x400/0x104` 那些。
const List<int> qq8QrLoginTlvOrder = <int>[
  0x18, 0x01, 0x106, 0x116, 0x100, 0x107, 0x142, 0x144, 0x145, 0x147,
  0x16A, 0x154, 0x141, 0x08, 0x511, 0x187, 0x188, 0x194, 0x191, 0x202,
  0x177, 0x516, 0x521, 0x318,
];

/// 解开登录层负载：`[16 字节头][TEA(shareKey)][0x03 尾]` → 明文。
///
/// 登录响应与二维码响应共用这一层（参考实现里都是
/// `tea.decrypt(payload.slice(16, -1), share_key)`）。头与尾都不参与解密。
Uint8List qq8DecryptLoginPayload(Uint8List payload, Uint8List shareKey) {
  if (payload.length < 16 + 1 + 5) {
    throw Qq8LoginException('响应太短（${payload.length} 字节，至少 22）');
  }
  final body = Uint8List.sublistView(payload, 16, payload.length - 1);
  try {
    return qqTeaDecrypt(body, shareKey);
  } on Qq8LoginException {
    rethrow;
  } on Object catch (e) {
    throw Qq8LoginException('响应解密失败（密钥不对或报文损坏）：$e');
  }
}

/// 读一段 TLV 序列，返回 `tag → body`。
///
/// 对应 oicq 的 `readTlv`：
/// ```js
/// while (stream.readableLength > 2) {
///     const k = stream.read(2).readUInt16BE();
///     t[k] = stream.read(stream.read(2).readUInt16BE());
/// }
/// ```
///
/// 官方对应 `tlv_t.search_tlv`（逐个 `get_tlv` 的底层扫描）——同样是
/// **无计数前缀**的裸序列，按 `i = len + 4 + i` 递进：
/// ```java
/// while (i < length) {
///     if (util.buf_to_int16(bArr, i) == i3) return i;
///     i = util.buf_to_int16(bArr, i + 2) + 2 + (i + 2);
/// }
/// ```
///
/// [tolerateTruncated] 为真时，尾部不完整的 TLV 被忽略而不是抛错——
/// 服务端响应里常带一些我们不需要的尾部字段。
Map<int, Uint8List> qq8ReadTlv(
  Uint8List data, {
  int offset = 0,
  bool tolerateTruncated = false,
}) {
  final out = <int, Uint8List>{};
  var i = offset;
  while (i + 4 <= data.length) {
    final tag = (data[i] << 8) | data[i + 1];
    final len = (data[i + 2] << 8) | data[i + 3];
    final start = i + 4;
    final end = start + len;
    if (end > data.length) {
      if (tolerateTruncated) break;
      throw Qq8LoginException(
        'TLV 0x${tag.toRadixString(16)} 声明长度 $len 超出剩余 '
        '${data.length - start} 字节',
      );
    }
    out[tag] = Uint8List.sublistView(data, start, end);
    i = end;
  }
  return out;
}

/// 登录流程错误。
class Qq8LoginException implements Exception {
  final String message;
  Qq8LoginException(this.message);

  @override
  String toString() => 'Qq8LoginException: $message';
}

/// 登录响应。
///
/// 解析自传输层拿回的 payload（**已去掉 u32 分帧头**）。
class Qq8LoginResponse {
  /// 响应类型，见 [Qq8LoginResultType]。
  final int type;

  /// 解密后的 TLV 表。
  final Map<int, Uint8List> tlvs;

  /// 解密后的明文（排查用）。
  final Uint8List plain;

  Qq8LoginResponse({
    required this.type,
    required this.tlvs,
    required this.plain,
  });

  bool get isSuccess => type == Qq8LoginResultType.success;

  /// 是不是"手机号短信验证登录"的中间态回包（检查 / 下发）。
  bool get isSmsLoginStep =>
      type == Qq8LoginResultType.smsLoginCheck ||
      type == Qq8LoginResultType.smsLoginRefresh;

  /// 新盐（`0x104`）——下一步（下发/提交）要**原样回带**。
  Uint8List? get smsLoginSalt => tlvs[0x104];

  /// `0x126` 里的随机数（`_head_len+2` 是长度、从 `+4` 起是内容）——
  /// 提交验证码时进 `0x127` 的第二段。
  Uint8List? get smsLoginRandom {
    final b = tlvs[0x126];
    if (b == null || b.length < 6) return null;
    final len = (b[2] << 8) | b[3];
    final start = 4;
    if (start + len > b.length) return null;
    return b.sublist(start, start + len);
  }

  /// `0x182`：已下发次数上限 / 有效期秒数（偏移 +1 起，各 u16）。
  ({int msgCnt, int timeLimit})? get smsLoginLimits {
    final b = tlvs[0x182];
    if (b == null || b.length < 5) return null;
    return (
      msgCnt: (b[1] << 8) | b[2],
      timeLimit: (b[3] << 8) | b[4],
    );
  }

  /// `0x183`：msalt（u64，提交验证码时进 `0x184`）。
  int? get smsLoginMsalt {
    final b = tlvs[0x183];
    if (b == null || b.length < 8) return null;
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | b[i];
    }
    return v;
  }

  /// `0x52B`：提示手机号（给用户看"发到 138****1234"）。取不到就 null。
  ///
  /// 官方 `tlv_t52b.verify()`：`_body_len >= 8`，zone = body+4 的 u16，
  /// **号码 = body 第 8 字节起到 body 末尾**（没有单独的长度字段，`i2 = body_len - 8`）。
  Uint8List? get smsLoginPhoneRaw => tlvs[0x52B];

  /// `0x52B` 的 zone（国家码；号码单独用 [smsLoginPhoneHint] 取）。
  int? get smsLoginZone {
    final b = tlvs[0x52B];
    if (b == null || b.length < 8) return null;
    return (b[4] << 8) | b[5];
  }

  String? get smsLoginPhoneHint {
    final b = tlvs[0x52B];
    if (b == null || b.length < 8) return null;
    final mobile = b.sublist(8);
    if (mobile.isEmpty) return null;
    try {
      return String.fromCharCodes(mobile);
    } on Object {
      return null;
    }
  }

  /// `0x113`：服务端告知的 uin（u32 大端，官方 `tlv_t113.get_uin()`）。
  ///
  /// 短信验证登录（子命令 18）**成功后不给票据**，只回这个 uin + `0x183`/`0x104`
  /// （官方 `oicq_request.java:1525-1537`，`i3 == 3 || i3 == 7` 分支）；
  /// 真正登录还要再用 `mpasswd` 当口令走一次子命令 9。
  int? get uinHint {
    final b = tlvs[0x113];
    if (b == null || b.length < 4) return null;
    return ((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]) & 0xFFFFFFFF;
  }

  bool get needsSlider => type == Qq8LoginResultType.slider;
  bool get needsDeviceLock => type == Qq8LoginResultType.deviceLock;

  /// 是否要求短信码验证（160/162/239 之一）。
  bool get needsSmsVerify =>
      type == Qq8LoginResultType.smsVerify1 ||
      type == Qq8LoginResultType.smsVerify2 ||
      type == Qq8LoginResultType.smsVerify3;

  /// 滑动验证地址（仅 `type == 2` 且有 `0x192` 时有值）。
  String? get sliderUrl {
    final b = tlvs[0x192];
    if (b == null) return null;
    return String.fromCharCodes(b);
  }

  /// 二次验证令牌 `0x174`（短信流程要原样回带；不在时为空）。
  Uint8List? get verifyToken => tlvs[0x174];

  /// 短信验证的目标手机号（从 `0x178` 里取）。
  ///
  /// 读法照参考实现：`0x178` 里先有一个 `0x0B` 分隔符，其后 11 个字符是号码，
  /// 例如 `…\x0b13800000000…`。取不到就返回 null（不猜、不编）。
  String? get verifyPhone {
    final b = tlvs[0x178];
    if (b == null) return null;
    final sep = b.indexOf(0x0B);
    if (sep < 0 || sep + 1 + 11 > b.length) return null;
    final digits = b.sublist(sep + 1, sep + 1 + 11);
    final s = String.fromCharCodes(digits);
    return RegExp(r'^\d{11}$').hasMatch(s) ? s : null;
  }

  /// 设备锁提示语 `0x204`（仅 204 且有该 TLV 时有值）。
  ///
  /// 按 UTF-8 解码（参考实现是 Node 的 `Buffer.toString()`，默认 utf8）。
  String? get deviceLockHint {
    final b = tlvs[0x204];
    if (b == null || b.isEmpty) return null;
    return utf8.decode(b, allowMalformed: true);
  }

  /// 票据块 `0x119`（仅成功时有值）。
  Uint8List? get t119 => tlvs[0x119];

  /// 服务端的错误/提示文案（TLV `0x146`，标题+内容）；没有就是 null。
  ///
  /// 结构照参考实现 `decodeLoginResponse` 的读法：
  /// `u32 版本 ‖ u16-len 标题 ‖ u16-len 内容`（UTF-8）。
  /// 例：`[登录失败] 服务连接中，请稍后再试。(0x6)`。字段越界返回 null（不猜）。
  (String, String)? get serverMessage {
    final b = tlvs[0x146];
    if (b == null || b.length < 6) return null;
    var p = 4; // 版本
    final titleLen = (b[p] << 8) | b[p + 1];
    p += 2;
    if (p + titleLen > b.length) return null;
    String text(int start, int len) {
      final end = (start + len <= b.length) ? start + len : b.length;
      return utf8.decode(b.sublist(start, end), allowMalformed: true);
    }

    final title = text(p, titleLen);
    p += titleLen;
    if (p + 2 > b.length) return (title, '');
    final contentLen = (b[p] << 8) | b[p + 1];
    p += 2;
    return (title, text(p, contentLen));
  }

  /// 服务端"进阶语法提示"块（TLV `0x508`，tag 1288）的解包结果；没有就是 null。
  ///
  /// 官方 `tlv_t508.verify()` 的 body 布局（8.9.50 `tlv_t508.java:20-28`）：
  /// `u8 flag ‖ i32 timeout ‖ u16 len ‖ len 字节 userBuf`。`flag=1` 时官方会用
  /// `userBuf` 再 POST 到 `ts{7,8,9}.qq.com:8080/msg`（`request/g.java:136-207`）
  /// 换人类可读文案——`userBuf` 本身是加密的 notice 查询载荷，不是明文内部码。
  Qq8T508Notice? get t508Notice {
    final b = tlvs[0x508];
    if (b == null || b.length < 7) return null;
    final flag = b[0];
    var p = 1;
    final timeout = (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
    p += 4;
    final len = (b[p] << 8) | b[p + 1];
    p += 2;
    if (p + len > b.length) return null;
    return Qq8T508Notice(
      doFetch: flag == 1,
      timeoutMs: timeout,
      userBuf: Uint8List.fromList(b.sublist(p, p + len)),
    );
  }

  /// 解析响应。
  ///
  /// 步骤完全照搬 oicq `_decodeLoginResponse`：
  /// ```js
  /// payload = tea.decrypt(payload.slice(16, payload.length - 1), ecdh.share_key);
  /// stream.read(2); const type = stream.read(1); stream.read(2);
  /// const t = readTlv(stream);
  /// ```
  ///
  /// 开头 16 字节是 OICQ 信封头，末尾 1 字节是 `0x03` 尾——两者都不参与解密。
  ///
  /// 官方 9.3.60 `oicq_request.d()` / `c()` 是同一件事：
  /// ```java
  /// this.d = (this.c - 15) - 2;              // 密文长 = 总长 - 16 头 - 1 尾
  /// a(this.e, 16, this.d, wVar.m);           // 密钥 = ECDH share key（w.m）
  /// // …… c(this.e, 16, this.d) 内：
  /// if (i2 < 5) return -1009;                // 明文至少 5 字节
  /// int iB = b(bArr14, i + 2);               // type = 明文[2]（b = & 255）
  /// int i19 = i + 5;                         // TLV 从明文[5] 起
  /// ```
  static Qq8LoginResponse parse(Uint8List payload, Uint8List shareKey) {
    // TEA 自带填充完整性校验：密钥不对时会抛，统一包成 Qq8LoginException，
    // 让调用方只处理一种错误类型（解密细节见 [qq8DecryptLoginPayload]）。
    final plain = qq8DecryptLoginPayload(payload, shareKey);
    if (plain.length < 5) {
      throw Qq8LoginException('解密后太短（${plain.length} 字节）');
    }
    final type = plain[2];
    final tlvs = qq8ReadTlv(plain, offset: 5, tolerateTruncated: true);
    return Qq8LoginResponse(type: type, tlvs: tlvs, plain: plain);
  }
}

/// 票据集合（来自响应 TLV `0x119`，需用 tgtgt 密钥再解一层）。
///
/// 对应 oicq 的 `decodeT119`：
/// ```js
/// const reader = Readable.from(tea.decrypt(data, this.device.tgtgt));
/// reader.read(2);
/// const t = readTlv(reader);
/// this.readT106(t[0x106]);   // ← 更新 tgtgt
/// this.sig = { tgt: t[0x10a], d2: t[0x143], d2key: t[0x305], ... };
/// ```
///
/// 官方 9.3.60 `oicq_request.c()` 的成功分支（`iB == 0`）逐条对应：
/// ```java
/// tlv_tVar.get_tlv(bArr14, i19, (this.c - i19) - 1, async_contextVarB._tgtgt_key);
/// //   ↑ 0x119 的 body 用 tgtgt 密钥 TEA 解密（tlv_t.get_tlv(…, key) → cryptor.decrypt）
/// byte[] bArr15 = tlv_tVar.get_data();       // 解密后的票据块
/// tlv_t10aVar.get_tlv(bArr15, 2, length);    // 子 TLV 一律从偏移 2 起搜
/// tlv_t106Var.get_tlv(bArr5, 2, length);     // t106（新 tgtgt 材料）
/// tlv_t143Var.get_tlv(bArr5, 2, length);     // d2  = 0x143
/// tlv_t305Var.get_tlv(bArr5, 2, length);     // d2key = 0x305
/// ```
/// 本类的字段名即照此映射（`0x10a` / `0x143` / `0x305` / `0x133` / `0x134` …）。
class Qq8SigBundle {
  final Uint8List? t106;
  final Uint8List? tgt;
  final Uint8List? d2;
  final Uint8List? d2key;
  final Uint8List? sigKey;
  final Uint8List? ticketKey;
  final Uint8List? srmToken;
  final Uint8List? skey;
  final Uint8List? stWebSig;
  final Uint8List? deviceToken;
  final Uint8List? t11a;
  final Uint8List? t512;

  /// 解密后的全部 TLV（排查用）。
  final Map<int, Uint8List> all;

  Qq8SigBundle({
    required this.all,
    this.t106,
    this.tgt,
    this.d2,
    this.d2key,
    this.sigKey,
    this.ticketKey,
    this.srmToken,
    this.skey,
    this.stWebSig,
    this.deviceToken,
    this.t11a,
    this.t512,
  });

  /// 用 [tgtgtKey] 解开 `0x119` 并抽出票据。
  static Qq8SigBundle parse(Uint8List t119, Uint8List tgtgtKey) {
    final Uint8List plain;
    try {
      plain = qqTeaDecrypt(t119, tgtgtKey);
    } on Object catch (e) {
      throw Qq8LoginException('0x119 解密失败（tgtgt 密钥不对或报损坏）：$e');
    }
    if (plain.length < 2) {
      throw Qq8LoginException('0x119 解密后太短（${plain.length} 字节）');
    }
    final tlvs = qq8ReadTlv(plain, offset: 2, tolerateTruncated: true);
    return Qq8SigBundle(
      all: tlvs,
      t106: tlvs[0x106],
      tgt: tlvs[0x10a],
      d2: tlvs[0x143],
      d2key: tlvs[0x305],
      sigKey: tlvs[0x133],
      ticketKey: tlvs[0x134],
      srmToken: tlvs[0x16a],
      skey: tlvs[0x120],
      stWebSig: tlvs[0x103],
      deviceToken: tlvs[0x322],
      t11a: tlvs[0x11a],
      t512: tlvs[0x512],
    );
  }
}

/// 服务端"进阶语法提示"（TLV `0x508`）的承载。
///
/// 官方 8.9.50 `tlv_t508` 只做「拆包」不做「解释」：`verify()` 读出
/// `flag / timeout / userBuf` 三个字段，`userBuf` 是**加密的** notice 查询载荷，
/// 需要 `request/g.b()` 再走一次 `POST ts{7,8,9}.qq.com:8080/msg`（RSA 解外层、
/// MD5 校验、ECDH share key 解内层）才变成明文错误文案。本类只承载拆包结果，
/// 换文案那条链路未实现（纯诊断增强，不改登录成败，见 [Qq8LoginResponse.t508Notice]）。
class Qq8T508Notice {
  /// 官方是否据此发起 HTTP 换文案（body 首字节 == 1）。
  final bool doFetch;

  /// HTTP 换文案的超时（毫秒；0 时官方按 1000 兜底）。
  final int timeoutMs;

  /// 加密的 notice 查询载荷（原样回传 `ts*.qq.com/msg` 才能解出文案）。
  final Uint8List userBuf;

  const Qq8T508Notice({
    required this.doFetch,
    required this.timeoutMs,
    required this.userBuf,
  });
}
