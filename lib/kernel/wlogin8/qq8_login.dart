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
/// | 2 | 滑动验证码 | 4 |
/// | 7 | 提交短信验证码 | 7 |
/// | 8 | 请求下发短信 | 6 |
/// | 11 | token 登录 / 票据续期（`wtlogin.exchange_emp`） | 16（清单 [qq8ExchangeEmpTlvOrder]） |
/// | 20 | 设备锁 | 4 |
///
/// 本文件是纯 Dart。
library;

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

  /// `t.an`；`0x548` 仅非空时发。
  final Uint8List? an;

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

  const Qq8LoginConditions({
    this.accountIsUin = true,
    this.flags = 0,
    this.loginType = 1,
    this.t104,
    this.echoedR,
    this.staticL,
    this.an,
    this.tgtQR,
    this.t16a,
    this.hasSig = false,
    this.qimei,
    this.d2,
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
        return _nonEmpty(an);
      case 0x143:
        return _nonEmpty(d2); // token 登录专有：没有 d2 发出去只会被拒
      default:
        return true;
    }
  }
}

/// 登录 body 组装。
abstract final class Qq8LoginBody {
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
  bool get needsSlider => type == Qq8LoginResultType.slider;
  bool get needsDeviceLock => type == Qq8LoginResultType.deviceLock;

  /// 滑动验证地址（仅 `type == 2` 且有 `0x192` 时有值）。
  String? get sliderUrl {
    final b = tlvs[0x192];
    if (b == null) return null;
    return String.fromCharCodes(b);
  }

  /// 票据块 `0x119`（仅成功时有值）。
  Uint8List? get t119 => tlvs[0x119];

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
    if (payload.length < 16 + 1 + 5) {
      throw Qq8LoginException(
        '响应太短（${payload.length} 字节，至少 22）',
      );
    }
    final body = Uint8List.sublistView(payload, 16, payload.length - 1);

    // TEA 自带填充完整性校验：密钥不对时**会**抛 FormatException。
    // 统一包成 Qq8LoginException，让调用方只处理一种错误类型。
    final Uint8List plain;
    try {
      plain = qqTeaDecrypt(body, shareKey);
    } on Qq8LoginException {
      rethrow;
    } on Object catch (e) {
      throw Qq8LoginException('响应解密失败（密钥不对或报文损坏）：$e');
    }

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
