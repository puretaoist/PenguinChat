/// L2 协议内核：QQ 8.2.11 的 SSO 包封装
///
/// ## 三个层次
///
/// 每个请求实际是三层嵌套：
///
/// ```text
///   ┌─ 登录信封 (buildLoginPacket)
///   │    ├ 长度前缀
///   │    ├ 0x0A、type、d2、uin
///   │    └─ SSO 负载 ─────────────┐
///   │                             │
///   └─ SSO 信封 (buildLoginPacket 内层)
///        ├ seq / subid ×2 / BUF_UNKNOWN
///        ├ tgt / cmd / session_id / imei / ksid
///        ├ 长度前缀(body)          │
///        └ [type=1 用 d2key 加密；type=2 用全零密钥]
///                                  │
///   └─ OICQ 信封 (buildOicqPacket)
///        ├ 0x02 0x01 / random_key / 0x131 / 0x01
///        ├ ECDH 公钥 (TLV 形式)
///        ├ TEA(body, ecdh.share_key)
///        └ 包头：长度 / 协议版本 8001 / 命令字 0x810 / uin / 加密类型
/// ```
///
/// ## 来源
///
/// 逐行移植自参考实现 `takayama-lily/oicq` 的 `lib/wtlogin/wt.js`
/// （`_buildOICQPacket` 与 `_buildLoginPacket`）。黄金向量由运行该模块
/// 原始代码生成，见 `tool/qq8_sso_selftest.dart`。
///
/// 本文件是纯 Dart。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../infra/coder.dart';
import '../crypto/tea.dart';
import 'qq8_device.dart';
import 'qq8_pb.dart';
import 'qq8_tlv.dart';

/// SSO 包头里的固定未知字段（oicq `BUF_UNKNOWN`）。
///
/// 12 字节，含义未明。**不要"顺手优化"成零** —— 它很可能参与服务端的
/// 版本/分支判定，改了就登不上，而且报错信息不会指向这里。
const List<int> qq8BufUnknown = <int>[
  0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
];

/// SSO 包头里的命令字。
const int qq8CmdWtLogin = 0x810;

/// SSO 包头里的协议版本。
const int qq8ProtocolVersion = 8001;

/// 登录层信封的命令字（[Qq8Sso.buildLoginPacket] 的 `cmd` 参数）。
///
/// 出处（8.9.50 反编译）：密码登录 `request/j.java:14`、
/// 票据续期/设备锁 `request/l.java:9`、扫码取票 `request/d0.java:12`。
/// 三个字符串都在 `oicq_request` 子类的 `f154l` 字段里，与类一一对应。
const String qq8LoginCmd = 'wtlogin.login';

/// 票据续期（token 登录，子命令 11）的命令字。
const String qq8ExchangeEmpCmd = 'wtlogin.exchange_emp';

/// 扫码取票的命令字（code2d 取码/轮询走它，见 `qq8_qrcode.dart`）。
const String qq8TransEmpCmd = 'wtlogin.trans_emp';

/// 登录信封的传输类型。
abstract final class Qq8LoginType {
  /// 心跳。
  static const int heartbeat = 0;

  /// 上线。
  static const int online = 1;

  /// 登录（用全零密钥加密 SSO 层）。
  static const int login = 2;
}

/// 票据集合（对应 oicq 的 `this.sig`）。
///
/// 登录成功后由服务端下发，后续所有请求都要带上。字段名沿用协议内部叫法。
class Qq8SigInfo {
  /// 登录票据。
  final Uint8List tgt;

  /// 会话密钥与其加密密钥。
  final Uint8List d2;
  final Uint8List d2key;

  /// 签名相关的两个密钥（`emp=true` 的包会用到）。
  final Uint8List sigKey;
  final Uint8List ticketKey;

  /// 短信验证票据。
  final Uint8List srmToken;

  /// 全部字段可省略，未提供的按空字节处理（登录前就是这种状态）。
  Qq8SigInfo({
    Uint8List? tgt,
    Uint8List? d2,
    Uint8List? d2key,
    Uint8List? sigKey,
    Uint8List? ticketKey,
    Uint8List? srmToken,
  })  : tgt = tgt ?? _emptyBytes,
        d2 = d2 ?? _emptyBytes,
        d2key = d2key ?? _emptyBytes,
        sigKey = sigKey ?? _emptyBytes,
        ticketKey = ticketKey ?? _emptyBytes,
        srmToken = srmToken ?? _emptyBytes;
}

/// 共享的空字节常量（`Uint8List` 没有 const 构造，只能这样给默认值）。
final Uint8List _emptyBytes = Uint8List(0);

/// SSO 构包上下文。
class Qq8SsoContext {
  final int uin;
  final Qq8ApkInfo apk;
  final Qq8Device device;

  /// 4 字节会话标识。
  final Uint8List sessionId;

  /// 16 字节随机密钥。
  final Uint8List randomKey;

  /// 本次登录的 ECDH 公钥（65 字节未压缩点）。
  final Uint8List ecdhPublicKey;

  /// 由 ECDH 协商出的 16 字节共享密钥。
  final Uint8List ecdhShareKey;

  /// 票据。
  final Qq8SigInfo sig;

  /// 当前序列号。
  final int seqId;

  /// QIMEI36（36 字符）。写进 reserve fields 的 tag 12。
  ///
  /// 服务端在 `StatSvc.register` 这类业务包上会看它——为空也能上线，但
  /// 官方客户端总有值，对齐更安全（null 时该 tag 不写）。
  final String? qimei36;

  /// `reserveFields` 的**整段覆写**（null = 按官方/icqq 规则现算）。
  ///
  /// 唯一用途是黄金向量：oicq 2.3.1 的 `lib/core/base-client.ts:876` 把这一段
  /// 写死成 `.writeU32(4)`（字面 4 个字节 `00 00 00 04`，**没有** length 前缀 +
  /// payload 的结构），而 icqq 0.6.10 与真机实测是 `withLength(protobuf)`
  /// （`buildReserveFields`）。两种形态字节不同，要让旧的 8 条逐字节向量继续
  /// 锁住信封其余部分，就得能按字节精确复现 oicq 那一版。
  ///
  /// 给了值就**原样写入**（不套 [Qq8Sso._withLength]）。
  final Uint8List? reserveFieldsOverride;

  /// SSO 头 ksid 槽里那段版本串的覆写（null = 用 apk.ksidName ?? apk.name）。
  ///
  /// 该槽是明文 ASCII |imei|版本串，服务端判「版本过低」时读的就是它
  /// （官方 8.2.11 发 A8.2.11.0153f87a8.2.11.0153f87a）。做版本二分实验时用它。
  final String? ksidNameOverride;

  Qq8SsoContext({
    required this.uin,
    required this.apk,
    required this.device,
    required this.sessionId,
    required this.randomKey,
    required this.ecdhPublicKey,
    required this.ecdhShareKey,
    Qq8SigInfo? sig,
    this.seqId = 0,
    this.qimei36,
    this.reserveFieldsOverride,
    this.ksidNameOverride,
  }) : sig = sig ?? Qq8SigInfo();

  /// ksid：**服务端下发的 32 位十六进制串**，不是本地派生值。
  ///
  /// ⚠️ 2026-10-22 修正：此前这里写成 `|${IMEI}|${apkName}`，那是照 oicq
  /// 抄的。官方语义完全不同：
  ///
  /// 1. `util.get_ksid(ctx)` 读 SP `WLOGIN_DEVICE_INFO.xml` 的 `ksid` 项；
  /// 2. 该值由**服务端**在响应 TLV `0x108` 里下发，
  ///    `oicq_request.java:1594` 收到后调 `util.set_ksid()` 落盘；
  /// 3. `set_ksid` 的语义是「**只在 SP 为空时写入**」（`if (bArr2 == null ||
  ///    bArr2.length <= 0)`），之后每次登录原样回带；
  /// 4. `k.java` case 264 发 0x108 的条件是 `bArr7 != null && bArr7.length != 0`
  ///    —— 也就是「有 ksid 就发，没有就整条不发」。
  ///
  /// 真机 SP 实测值：`188ca8765de720b5207b0adc6c51d3d7`（32 字符）。
  ///
  /// ## ⚠️ 2026-10-23 修正：这里和 TLV 0x108 **不是**同一个值
  ///
  /// 此前这个 getter 与 `tlv.dart` 的 `case 0x108` 共用了
  /// `qq8KsidBytes(device.ksid, ...)`，于是两处**同时**偏离官方：
  ///
  /// * **SSO 头这个槽**：官方恒为 `|<imei>|<apkName>` 的 ASCII。证据是
  ///   oicq 2.3.1 `lib/core/base-client.ts:865`
  ///   `const ksid = Buffer.from(|${this.device.imei}| + this.apk.name)`
  ///   —— 唯一能登录成功的实现就是这么写的，它是从服务端行为里试出来的
  ///   常量，**不是**从 SP 读的。
  /// * **TLV 0x108 的 body**：官方是 SP `WLOGIN_DEVICE_INFO` 的 `ksid`
  ///   经 `util.string_to_buf` 十六进制解码（`t.java:313`
  ///   `t.ac = util.get_ksid(t)`），为空则**整条不发**（`k.java` case 264）。
  ///
  /// 两者取值规则不同，故这里不再读 `device.ksid`。
  ///
  /// `apkName` 优先取 [Qq8ApkInfo.ksidName]（官方 8.2.11 是 33 字符的
  /// `A8.2.11.0153f87a8.2.11.0153f87a`，不是 `name` 那个 `A8.2.11.4530`）。
  Uint8List get ksid => Uint8List.fromList(
        utf8.encode('|${device.imei}|${ksidNameOverride ?? apk.ksidName ?? apk.name}'),
      );

  /// SSO 头里 imei 槽的**实际内容**。
  ///
  /// ## 2026-10-24 官方抓包定案（决定性）
  ///
  /// 官方 `wtlogin.exchange_emp` 请求（`official-register.pcap` 的
  /// `43918_8080.bin` @328）该槽是 **16 字节 ASCII `25cf6881290b58f7`** ——
  /// 也就是官方 QQ 自己的 `ANDROID_ID`，**不是** IMEI。
  ///
  /// 但同一个包的 ksid 串却是 `||A8.2.11...`（两个竖线 = imei 为空）。
  /// 说明这两个位置取值不同源：槽里放设备标识，串里放 IMEI。
  ///
  /// 这与「`util.java` 里根本没有 `getIMEI`/`getDeviceId`」一致：
  /// 官方在 Android 10+ 拿不到 IMEI，这个槽从来就不是真 IMEI。
  /// oicq 把它叫 `device.imei` 并塞随机 hex，同样能登录（服务端只要非空）。
  ///
  /// 退化顺序：真 IMEI（有就给）→ `ANDROID_ID`（官方实测形态）→ 空。
  Uint8List get imeiSlot {
    if (device.imei.isNotEmpty) {
      return Uint8List.fromList(utf8.encode(device.imei));
    }
    if (device.androidId.isNotEmpty) {
      return Uint8List.fromList(utf8.encode(device.androidId));
    }
    return Uint8List(0);
  }

  /// SSO 头里 **ksid 原始字节槽**（`withLength` 包着的 16 字节裸 hex）。
  ///
  /// ## 2026-10-24 官方抓包定案：这个槽我们整条漏了
  ///
  /// 官方 `@328` 的头部逐槽走查（偏移已核对到字节）：
  /// ```
  /// 28  withLength(76)   tgt 72B
  /// 104 withLength(24)   cmd "wtlogin.exchange_emp"
  /// 128 withLength(4)    session 0B
  /// 132 withLength(20)   imei 槽 → "25cf6881290b58f7"（16 ASCII）
  /// 152 withLength(20)   ★ ksidRaw → 16 字节裸 hex 188ca876…d3d7
  /// 172 u16(35) + "||A8.2.11.0153f87a8.2.11.0153f87a"
  /// 207 withLength(4)    reserve 0B
  /// 211 withLength(1008) payload 1004B
  /// ```
  /// 同抓包的另一条请求 `GrayUinPro.Check`（@2607）头部**逐字节同构**，
  /// 说明这是所有 0x0A 请求的固定形态，不是某个命令的特例。
  ///
  /// 我们此前只写 `u16(len+2)+字符串`，**整个 `withLength(ksidRaw)` 槽不存在**
  /// ⇒ 从该槽起后续所有字段整体前移 20 字节，服务端按官方布局解析时
  /// 长度字段全部错位。
  ///
  /// 取值 = SP `WLOGIN_DEVICE_INFO` 的 `ksid` 经十六进制解码（与服务端
  /// 下发的 TLV `0x108` 同源，见 [qq8KsidBytes]）。没有 ksid 时返回空，
  /// 此时**不写该槽**（官方恒有值，无对照样本，故保持旧形态可比）。
  Uint8List get ksidRaw => qq8KsidBytes(device.ksid);

  /// SSO 头里的「保留字段」（reserve fields），protobuf 编码。
  ///
  /// ## 为什么必须有（2026-10-22 真机实证）
  ///
  /// 此前这里写的是 `..u32(4)` —— 一个长度 4 的**空** blob。用它跑
  /// `StatSvc.register` 时服务端**完全不回包**（等到 10 秒超时），而同一
  /// 连接上 `Heartbeat.Alive` / `Client.CorrectTime` 都正常。补上下面这些
  /// 字段后 register 立即通了。
  ///
  /// 参考实现 icqq `lib/core/base-client.js:361-394` 的 `buildReserveFields`：
  /// ```js
  /// let qImei36 = this.device.qImei36 || this.device.qImei16;
  /// reserveFields = { 9: 1, 12: qImei36, 14: 0, 16: this.uin, 18: 0,
  ///                   19: 1, 20: 1, 21: 0, 24: sec_info, 28: 3 };
  /// ```
  /// （另一个分支 `ssover >= 20 && false` 恒不生效，故只用上面这套。）
  ///
  /// `24`（`sec_info`）在无需签名的命令上是空字节串；`0x544` 的签名结果
  /// 要走这里，但 8.2.11 代际的 `sec_info` 恒空，故先按空处理。
  Uint8List get reserveFields {
    final override = reserveFieldsOverride;
    if (override != null) return override;
    // 8.2.11 这一代**整段不发**（下面 `apk.useReserveFields` 控制）。
    if (!apk.useReserveFields) return Uint8List(0);
    final q = qimei36;
    return Qq8Pb.encode(<int, Object?>{
      9: 1,
      // tag 12（qimei36）按档案门控：9.3.60/TIM 那一代才带，
      // 8.2.11 的 reserve 本身就是空的（见 useReserveFields 的注释）。
      12: (!apk.reserveIncludesQimei36 || q == null || q.isEmpty) ? null : q,
      14: 0,
      16: uin,
      18: 0,
      19: 1,
      20: 1,
      21: 0,
      24: Uint8List(0),
      28: 3,
    });
  }
}

/// SSO 包构建器。
abstract final class Qq8Sso {
  /// 构建 OICQ 层信封，把业务 [body] 包成可直接发送的字节。
  ///
  /// [emp] 为真时走"设备锁/短信验证"分支，使用 [Qq8SigInfo.sigKey] 与
  /// [Qq8SigInfo.ticketKey]；否则用 ECDH 协商密钥。
  static Uint8List buildOicqPacket(
    Qq8SsoContext ctx,
    Uint8List body, {
    bool emp = false,

    /// uin 覆写：二维码取码（`wtlogin.trans_emp`）要求 uin = **0**。
    int? uinOverride,

    /// 命令字覆写：二维码取码用 **0x812**（手 Q 登录是 0x810）。
    int? cmdIdOverride,
  }) {
    final wrapped = emp ? _wrapEmp(ctx, body) : _wrapEcdh(ctx, body);

    return (ByteWriter()
          ..u8(0x02)
          // 长度 = 1(本字节) + 27(固定字段) + body + 1(尾部 0x03)
          ..u16(29 + wrapped.length)
          ..u16(qq8ProtocolVersion)
          ..u16(cmdIdOverride ?? qq8CmdWtLogin)
          ..u16(1) // 常量
          ..u32(uinOverride ?? ctx.uin)
          ..u8(3) // 常量
          ..u8(emp ? 69 : 0x87) // 加密类型：0x87=4，69=设备锁
          ..u8(0) // 常量
          ..u32(2) // 常量
          ..u32(0) // 客户端版本
          ..u32(0) // 常量
          ..raw(wrapped)
          ..u8(0x03))
        .build();
  }

  /// ECDH 分支的 body 包装。
  static Uint8List _wrapEcdh(Qq8SsoContext ctx, Uint8List body) {
    return (ByteWriter()
          ..u8(0x02)
          ..u8(0x01)
          ..raw(ctx.randomKey)
          ..u16(0x131)
          ..u16(0x01)
          ..bytes16(ctx.ecdhPublicKey) // writeTlv
          ..raw(qqTeaEncrypt(body, ctx.ecdhShareKey)))
        .build();
  }

  /// 设备锁 / 短信验证分支的 body 包装。
  static Uint8List _wrapEmp(Qq8SsoContext ctx, Uint8List body) {
    return (ByteWriter()
          ..bytes16(ctx.sig.sigKey)
          ..raw(qqTeaEncrypt(body, ctx.sig.ticketKey)))
        .build();
  }

  /// 构建登录层信封。
  ///
  /// [cmd] 是 SSO 命令字（如 `wtlogin.trans_emp`）；[type] 见 [Qq8LoginType]。
  static Uint8List buildLoginPacket(
    Qq8SsoContext ctx,
    String cmd,
    Uint8List body,
    int type, {

    /// uin 覆写：二维码取码（`wtlogin.trans_emp`）信封里 uin 写 **0**。
    int? uinOverride,

    /// SSO 头 subid 覆写：二维码取码用手表档案（537065138）。
    int? subIdOverride,
  }) {
    final ksid = ctx.ksid;
    final subId = subIdOverride ?? ctx.apk.subid;
    final uin = uinOverride ?? ctx.uin;

    // 内层：SSO 信封
    var sso = (ByteWriter()
          ..u32(ctx.seqId)
          ..u32(subId)
          ..u32(subId)
          ..raw(qq8BufUnknown)
          ..let((w) => _withLength(w, ctx.sig.tgt))
          ..let((w) => _withLength(w, utf8.encode(cmd)))
          ..let((w) => _withLength(w, ctx.sessionId))
          ..let((w) => _withLength(w, ctx.imeiSlot))
          // ksid 原始字节槽。没有 ksid 时写 withLength(空) = `00 00 00 04`，
          // 与 oicq 2.3.1 的 `.writeU32(4)` 逐字节相同（那正是空载荷形态）。
          ..let((w) => _withLength(w, ctx.ksidRaw))
          ..u16(ksid.length + 2)
          ..raw(ksid)
          ..let((w) => _writeReserveFields(w, ctx)))
        .build();

    sso = (ByteWriter()
          ..let((w) => _withLength(w, sso))
          ..let((w) => _withLength(w, body)))
        .build();

    if (type == Qq8LoginType.online) {
      sso = qqTeaEncrypt(sso, ctx.sig.d2key);
    } else if (type == Qq8LoginType.login) {
      sso = qqTeaEncrypt(sso, Uint8List(16)); // 全零密钥
    }

    // 外层：登录信封
    final outer = (ByteWriter()
          ..u32(0x0A)
          ..u8(type)
          ..let((w) => _withLength(w, ctx.sig.d2))
          ..u8(0)
          ..let((w) => _withLength(w, utf8.encode('$uin')))
          ..raw(sso))
        .build();

    return (ByteWriter()..let((w) => _withLength(w, outer))).build();
  }
}

/// 业务包（UNI 包）——**登录成功之后所有请求的载体**。
///
/// 逐行移植自参考实现 oicq `lib/core/base-client.ts` 的 `buildUniPkt`；
/// 黄金向量由 `../analysis/scripts/gen_uni_vector.cjs` 生成（同一份参考
/// 源码转写 + js 时代 tea），见 `tool/qq8_sso_selftest.dart` 第 5 节。
///
/// ## 证据等级（为什么不是"官方反编译逐行对照"）
///
/// 官方客户端的包编码**不在 Java 层**：`com.tencent.qphone.base.util.CodecWarpper`
/// 的 `encodeRequest(...)` 等方法全是 `native` 声明，实现落在
/// `libcodecwrapperV2.so`（8.9.50：218KB，`.text` 118KB，导出 22 个 JNI 函数
/// 含 `encodeRequest`——体检脚本 `../analysis/scripts/inspect_codecwrapper.py`）。
/// 且官方在该端口上走的是 MSF 形态（native 编码），与 raw-TCP 的这层报文
/// 不直接对应——所以**没有可逐行对照的官方 Java 实现**。
/// 本层结构以 oicq 参考实现为准，最终裁判是**服务端实测**：
/// 登录信封/三层响应已被真机 dump 逐字段确认；UNI 包的确认点是"注册"请求。
///
/// ```text
/// [u32 total（含自身）]
/// [u32 0x0B]                 ← 服务类型标记
/// [u8  1]
/// [i32 seq]                  ← 1..0x7FFF 循环，见 [Qq8Uni.nextSeq]
/// [u8  0]
/// [u32 uinLen（含自身 4 字节）]
/// [uin ASCII]
/// [TEA(sso, d2key)]          ← 内层 SSO 块
/// ```
///
/// 内层 SSO 块（TEA 解密后；布局与收包侧的 `parseSSO` 对偶）：
/// ```text
/// [u32 头长-4][u32 cmdLen+4][cmd][u32 8][session(4)][u32 4][u32 bodyLen+4][body]
/// ```
///
/// 返回的字节自带长度头，可直接交给传输层 `send`（原样写出）。
abstract final class Qq8Uni {
  /// 组装一个 UNI 包。
  static Uint8List build({
    required int uin,
    required String cmd,
    required Uint8List body,
    required int seq,
    required Uint8List session,
    required Uint8List d2key,
  }) {
    if (session.length != 4) {
      throw ArgumentError.value(session.length, 'session', 'UNI 包的 session 必须是 4 字节');
    }
    final cmdBytes = utf8.encode(cmd);
    // 头部（第一个 u32 之后的部分）：cmdLen + 20 —— 与收包侧 parseSSO 的
    // `headlen`（= 头总长 - 4）同义。
    final headLen = cmdBytes.length + 20;
    final inner = (ByteWriter()
          ..u32(headLen)
          ..u32(cmdBytes.length + 4)
          ..raw(cmdBytes)
          ..u32(8) // session 字段长度（含自身 4 字节）
          ..raw(session)
          ..u32(4) // 固定值
          ..u32(body.length + 4)
          ..raw(body))
        .build();
    final encrypted = qqTeaEncrypt(inner, d2key);
    final uinBytes = utf8.encode('$uin');
    return (ByteWriter()
          ..u32(encrypted.length + uinBytes.length + 18)
          ..u32(0x0B)
          ..u8(1)
          ..u32(seq)
          ..u8(0)
          ..u32(uinBytes.length + 4)
          ..raw(Uint8List.fromList(uinBytes))
          ..raw(encrypted))
        .build();
  }

  /// 请求序号推进：`1..0x7FFF` 循环（对应 oicq 的 `FN_NEXT_SEQ`：
  /// `if (++seq >= 0x8000) seq = 1`）。
  static int nextSeq(int current) {
    final next = current + 1;
    return next >= 0x8000 ? 1 : next;
  }
}

/// 长度前缀字节串，其中**长度字段包含它自己那 4 字节**。
///
/// 对应参考实现的 `Writer.writeWithLength`：
/// ```js
/// writeWithLength(v) { return this.writeU32(Buffer.byteLength(v) + 4).writeBytes(v); }
/// ```
///
/// ⚠️ 与 `ByteWriter.bytes32` 不同：后者写入的是**裸长度**（不含自身）。
/// 本协议这一层的多个字段（tgt / cmd / session_id / imei / d2 / uin）
/// 用的都是**含自身**的写法，不要混用——写错了服务端只会回一个含糊的
/// 登录失败码，极难定位。
void _withLength(ByteWriter w, List<int> data) {
  final bytes = data is Uint8List ? data : Uint8List.fromList(data);
  w.u32(bytes.length + 4);
  w.raw(bytes);
}

/// 写 SSO 头的 reserve fields 段。
///
/// 给了 [Qq8SsoContext.reserveFieldsOverride] 就**原样写入**（那是 oicq 2.3.1
/// 的 `writeU32(4)` 形态，供黄金向量复现）；否则按 `withLength(protobuf)`
/// 写 icqq / 官方真机的形态。
void _writeReserveFields(ByteWriter w, Qq8SsoContext ctx) {
  final override = ctx.reserveFieldsOverride;
  if (override != null) {
    w.raw(override);
    return;
  }
  _withLength(w, ctx.reserveFields);
}

/// 让链式写法保持可读的小工具。
extension _ChainLet on ByteWriter {
  ByteWriter let(void Function(ByteWriter w) fn) {
    fn(this);
    return this;
  }
}

/// `ksid` 的字节形态。工具脚本与服务层共用这一份，避免三处各写一遍。
///
/// 官方语义（`jadx-main/sources/oicq/wlogin_sdk/tools/util.java`）：
/// - `:286-294` `string_to_buf(String)`：SP 里的十六进制串按**两字符一字节**解码；
/// - `:238-248` `buf_to_string(byte[])`：它的逆运算，`set_ksid` 落盘时用；
/// - `:683-690` `set_ksid` 只在 SP 为空时写入；
/// - `:692-698` `get_ksid` 读 SP 后走 `string_to_buf`。
///
/// ⚠️ 2026-10-22 修正：此前把注入的 `188ca8765de720b5207b0adc6c51d3d7`
/// 直接 `utf8.encode` 成 **32 字节**，而官方送进 SSO 头与 `0x108` 的是
/// `string_to_buf` 解出的 **16 字节**。真机 SP `WLOGIN_DEVICE_INFO.xml`
/// 里的 `ksid` 就是 32 字符的十六进制串。
///
/// ## ⚠️ 2026-10-23 修正：单一职责化，去掉 `|<imei>|<apkName>` fallback
///
/// 此前是「注入为空就拼 `|<imei>|<apkName>`」，于是**两个语义不同的位置**
/// 都拿到了这串编造值：
///
/// * SSO 头那个槽本来就该是 `|<imei>|<apkName>`（正确）——现在由
///   `Qq8SsoContext.ksid` getter 直接写，不再经过本函数。
/// * TLV 0x108 的 body 在官方是「SP ksid 解码，为空则整条不发」——我们却
///   发了一条约 30 字节的编造值，而官方同状态下整条不发。
///
/// 现在本函数只做一件事：十六进制解码（官方 `util.string_to_buf`）。
/// **空进空出**，由调用方决定「空」意味着什么。
Uint8List qq8KsidBytes(String injected) {
  if (injected.isEmpty) {
    return Uint8List(0);
  }
  final n = injected.length ~/ 2;
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = (_qq8HexNibble(injected.codeUnitAt(i * 2)) << 4) |
        _qq8HexNibble(injected.codeUnitAt(i * 2 + 1));
  }
  return out;
}

/// 官方 `util.get_char(byte)`（`:273-283`）：非法字符一律返回 0。
int _qq8HexNibble(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30; // '0'..'9'
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10; // 'a'..'f'
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10; // 'A'..'F'
  return 0;
}
