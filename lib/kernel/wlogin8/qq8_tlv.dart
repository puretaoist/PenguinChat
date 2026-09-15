/// L2 协议内核：QQ 8.2.11 的 TLV 打包
///
/// ## 结构
///
/// ```text
///   +--------+--------+------------------+
///   | tag    | len    | body             |
///   | uint16 | uint16 | len 字节          |
///   +--------+--------+------------------+
///         全部大端（已由 oicq.wlogin_sdk.tools.util 反编译证实）
/// ```
///
/// `len` **只计 body**，不含 4 字节头。
///
/// ## 来源
///
/// 逐条移植自参考实现 `takayama-lily/oicq` 的 `lib/wtlogin/tlv.js`，
/// 后者是 8.2.11 同代协议的开源实现。48 个 TLV 全部有黄金向量对照
/// （用 oicq 原始模块在 mock 上下文中跑出，见 `tool/qq8_tlv_selftest.dart`）。
///
/// ## 与 `wlogin/tlv.dart`（NT 线）的关系
///
/// 两者结构相同但**编号体系完全不同**：NT 线那套是 9.3.60 的 113 个 TLV 编号，
/// 本文件是 8.2.11 的。刻意分目录存放，避免概念混淆。
///
/// 本文件是纯 Dart。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../infra/coder.dart';
import '../crypto/digest.dart';
import '../crypto/tea.dart';
import 'qq8_device.dart';

/// 官方客户端**登录请求**的 TLV 清单与顺序。
///
/// ## 来源（反编译，权威）
///
/// `oicq.wlogin_sdk.request.k` 的 `int[] iArr`（8.2.11 APK `classes.dex`）。
/// 数组字面量是**十进制**，而 `NotificationUtil.Constants` 里的
/// `NOTIFY_ID_*` 常量被当成了 TLV 编号使用（腾讯拿通知 ID 空间复用为
/// 常量池），替换后得到本表：
///
/// ```java
/// int[] iArr = {24, 1, 262, 278, 256, 263, 264, 260, 322, 274, 324, 325, ...};
/// //            0x18 0x01 0x106 0x116 0x100 0x107 0x108 0x104 0x142 0x112 ...
/// ```
///
/// ## 三版本对照（已核）
///
/// 8.2.11 / 8.9.50 / 9.3.60 各有一份同样的顺序数组：
///
/// * 8.2.11 `oicq.wlogin_sdk.request.k` 与 8.9.50 `...request.j`
///   **37 项、逐项逐序相同**；
/// * 9.3.60 `...request.l` 在末尾**追加** `0x553`，共 38 项
///   （`0x553` 不属于 8.2.11，不必补）。
///
/// 详见 `../analysis/QQ-官方三版本登录流程对照.md`。
///
/// ## ⚠️ 顺序表 ≠ 实际发送
///
/// 官方是「超集清单 + `switch` 条件分派」，未命中的项直接跳过：
/// 8.9.50 的 `j` 里该 `switch` 只有 31 个 `case`。其中
/// `0x201`（当 `w` 非空）、`0x202`（当 `u.R` 非空）、`0x400`（需已有票据，
/// 故仅续期时发）、`0x318`（`tgtQR`，二维码登录专用）都是条件项。
///
/// 因此**发送数 < 37 是正常的**，不是实现缺失。
///
/// ## ⚠️ 与参考实现 oicq 的差异
///
/// oicq 的 `lib/wtlogin/login-password.js` 只发送其中约 23 个。
/// 服务端**期望**的是这份全集，补齐可最大化兼容性。缺的 TLV 结构从官方
/// `tlv_type/tlv_tXXX.java` 移植 —— 8.2.11 自己就有全部 8 个可移植类。
const List<int> qq8OfficialLoginTlvOrder = <int>[
  0x18, 0x01, 0x106, 0x116, 0x100, 0x107, 0x108, 0x104, 0x142, 0x112,
  0x144, 0x145, 0x147, 0x166, 0x16A, 0x154, 0x141, 0x08, 0x511, 0x172,
  0x185, 0x400, 0x187, 0x188, 0x194, 0x191, 0x201, 0x202, 0x177, 0x516,
  0x521, 0x525, 0x529, 0x318, 0x544, 0x545, 0x548,
];

/// 8.2.11 密码登录实际需要、而本模块尚未实现的 TLV。
///
/// ## 为什么是 6 个而不是 10 个
///
/// 逐项核到 8.2.11 的 `oicq/wlogin_sdk/request/k.java` 后发现：官方对这张表
/// 是「超集清单 + `switch` 条件分派」，**首登时自己也不发其中好几项**。
/// 所以"缺 TLV"这个说法本身是错的，正确的说法是"缺条件判断"。
///
/// 供体 = 8.2.11 APK 自身（`jadx-main` 的 `oicq/wlogin_sdk/tlv_type/`，
/// 111 个类，命名未混淆），无需跨版本借用。
///
/// 逐项落地要求（行号出自 8.2.11 `k.java`）：
///
/// * `0x112`（274，`k.java:131`）—— 仅当账号串**不是** uin 形式才发
///   （`!util.check_uin_account(g)`）。uin 登录下官方不发，本模块同构。
/// * `0x166`（358，`k.java:176`）—— 仅当 `(i4 & 128) != 0`；body = `08 01`
///   （`i8(t.x)`，静态 `t.x` 默认 1）。
/// * `0x172`（370，`k.java:196`）—— 仅当 `t.r` 非空；而 `t.r` 是**服务端回显**
///   赋值的（`oicq_request.java:1341`、`aa.java:274`），首登必为空 → 不发。
/// * `0x185`（389，`k.java:211`）—— 仅当 `i3 == 3`；body = `01 01`。
/// * `0x201`（513，`k.java:253`）—— 仅当静态 `k.L` 非空；body 是 4 段
///   `u16len + bytes`：`L, M, "qq", N`。首登多为空 → 不发。
/// * `0x548`（1352，`k.java:394`）—— 仅当 `t.an` 非空，默认空 → 不发。
const List<int> qq8LoginTlvMissing = <int>[
  0x112, 0x166, 0x172, 0x185, 0x201, 0x548,
];

/// `0x544`（1348）—— 走官方"安全 SDK 不可用"降级路径。
///
/// 8.2.11 的 `tlv_t544.java` 里，body 不是自己拼的：
///
/// ```java
/// com.tencent.secprotocol.ByteData.getInstance().init(context);
/// byte[] code = com.tencent.secprotocol.ByteData.getInstance()
///     .getCode(0L, j, i3, 0L, "", str, strBuf_to_string, bArr3);
/// fill_body(code, code.length);
/// ```
///
/// 深挖 `ByteData`（在 `classes3.dex`）后确认：
///
/// * 真正的 native 实现在 **`libpoxy.so`**（`System.loadLibrary("poxy")`），
///   不是 `libQSec.so`；且它**优先加载运行时下载到 `QQProtectQSecLibs/`
///   并通过腾讯签名校验的那份**，APK 自带的只是兜底。
/// * `libpoxy.so` 只有 50KB，导入表是 `socket/connect/getaddrinfo` +
///   `dlopen/dlsym` + `fopen/chmod`，**没有任何加密原语** —— 它是个下载器，
///   真身靠联网取回。8.9.50 / 9.3.60 更是连它都不带了。
///
/// 而 `ByteData.getCode` 有一条明确的降级返回：
///
/// ```java
/// private byte[] status = new byte[]{0, 0, 0, 0};
/// if (this.status[1] != 0 || checkObject(obj4)
///         || !this.mPoxyNativeLoaded || !this.mPoxyInit) {
///     bArr = this.status;              // ← 恰好 00 00 00 00
/// }
/// ```
///
/// `status[1]` 在 `UnsatisfiedLinkError` 时置 1。也就是说：**安全 SDK 没加载
/// 成功时，官方客户端发出去的 0x544 body 就是 4 个零字节。**
///
/// ✅ 因此本模块发 `0x544 = 00 00 00 00`：走的是官方自己的代码路径，报文格式
/// 与官方降级客户端一致，不携带任何腾讯二进制、不产生指纹取件流量。
///
/// ⚠️ 代价：拿不到官方设备指纹，服务端仍会把你归到 oicq / Lagrange 一档。
/// 这是自实现协议路线的**结构性上限**，不是可以补上的缺口。
///
/// ## `0x545`（1349）—— 依赖 `libQimei.so`
///
/// `t.T = util.get_qimei(context)`，取不到就跳过（8.2.11 `k.java:383-393`；
/// 8.9.50 同款在 `j.java` case 1349，为空时只上报错误事件、不产出 TLV）。
/// 官方行为即"取不到不发"，所以本模块同样跳过即可，**不算缺失**——
/// guard 见 `Qq8LoginConditions.applies` 的 `case 0x545`。
const List<int> qq8LoginTlvNativeBound = <int>[0x544, 0x545];

/// `0x544` 的降级 body（4 个零字节），出处见 `qq8LoginTlvNativeBound` 注释。
const List<int> qq8Tlv544DegradedBody = <int>[0, 0, 0, 0];

/// 官方设备指纹栈的定位常量（供排查/文档用，不参与组包）。
///
/// 登录报文里的设备身份分三层，难度递增：
///
/// * **L1 `guid`（0x106）** —— `MD5(android_id ‖ mac)`，纯本地计算
///   （`oicq/wlogin_sdk/tools/util.java:402`）。取不到 android_id 时官方会
///   **随机造 15 位数字**并写入 `WLOGIN_DEVICE_INFO/random_AndroidId`。
///   → 这一层我们算的和官方没区别。
/// * **L2 QIMEI（0x545）** —— body 就是 `MD5(QIMEI_DENGTA)`，值从
///   SharedPreferences `DENGTA_META` 读（`util.java:343`）；取不到就返回空、
///   **官方自己也不发这个 TLV**。而这个字符串本身是腾讯灯塔（Beacon）
///   服务器按上报的设备属性**签发**的。
/// * **L3 设备码（0x544）** —— `libpoxy.so` native + 联网，见上。
const String qq8QimeiSpName = 'DENGTA_META';
const String qq8QimeiSpKey = 'QIMEI_DENGTA';

/// QQ 的灯塔 appkey（`AndroidManifest.xml` 的 `APPKEY_DENGTA`）。
///
/// 它也决定 SD 卡备份文件名：`tencent/beacon/meta_0S200MNJT807V3GE.dat`，
/// 该文件用 `@&(*#HNKJg12!@` 作为 key 加密
/// （`com.tencent.beacon.qimei.d.a()` 把同一个 XOR 跑了两遍，互相抵消）。
const String qq8BeaconAppKey = '0S200MNJT807V3GE';

/// 灯塔上报端点（`com/tencent/beacon/**` 里的字面量）。
///
/// 响应码 `102` 才算拿到 QIMEI（`com.tencent.beacon.qimei.c`）。
const List<String> qq8BeaconEndpoints = <String>[
  'http://oth.eve.mdt.qq.com',
  'http://oth.str.mdt.qq.com',
  'http://strategy.beacon.qq.com/analytics/upload',
  'http://183.36.108.226', // 硬编码 IP 兜底
];

/// 出现在官方顺序表中、但**不属于 8.2.11 密码登录**的 TLV。
///
/// * `0x318` —— 官方没有专用类，是用泛型 `tlv_t(792).set_data(...)` 直接
///   包装 `tgtQR`；`tgtQR` 属二维码登录路径，密码登录下为空，永不发送。
/// * `0x529` —— 三版本的 `tlv_type/` 里都没有对应类，8.9.50 的登录构建器
///   里也没有 `case` / `get_tlv_529` 调用点：列在表里但根本不产生。
const List<int> qq8LoginTlvOutOfPasswordFlow = <int>[0x318, 0x529];

/// 9.3.60 / TIM 4.1.0 的登录 TLV 顺序表：37 项 + 末尾 `0x553`。
///
/// 两者的 DEX `fill-array-data` payload 头读出的长度都是 **38**，
/// 且前 37 项与 [qq8OfficialLoginTlvOrder] 逐项相同——唯一差异是多了 `0x553`。
const List<int> qq8OfficialLoginTlvOrderWith553 = <int>[
  0x18, 0x01, 0x106, 0x116, 0x100, 0x107, 0x108, 0x104, 0x142, 0x112,
  0x144, 0x145, 0x147, 0x166, 0x16A, 0x154, 0x141, 0x08, 0x511, 0x172,
  0x185, 0x400, 0x187, 0x188, 0x194, 0x191, 0x201, 0x202, 0x177, 0x516,
  0x521, 0x525, 0x529, 0x318, 0x544, 0x545, 0x548, 0x553,
];

/// `wtlogin.exchange_emp`（子命令 11，token 登录 / 票据续期）的 TLV 顺序表。
///
/// 命令字出处：官方 8.9.50 `request/l.java:9`（`wtlogin.exchange_emp`；
/// 密码登录是 `request/j.java:14` 的 `wtlogin.login`）。官方记载该子命令
/// 发 **16 项**（早先从 `k/u` 的 `this.u` 表记录），与下表数目一致。
///
/// 16 项的**取值与顺序**取自参考实现 oicq 的
/// `lib/wtlogin/login-password.js`（`tokenLogin`）——它对旧版本实测可通；
/// 并用官方 `l.java` 的构建序列核过 tag 词汇：`get_tlv_100` / `10a` / `116` /
/// `145` / `142` / `154` / `18` / `141` / `8` / `147` / `177` / `144` /
/// `544("810_a")` 加条件项 `108`/`172`/`187`/`188`/`194`/`201`/`202`/`511`。
///
/// ⚠️ 已知与官方的两处出入（**待逐行核对官方实发顺序**，现在以 oicq 为准）：
/// * 官方 `l.java` 的序列里可见 `0x145`，本表没有；
/// * 官方分支里 `0x143`（d2）在 jadx 重复块中读序不清，本表按 oicq 放在 `0x144` 之后。
///
/// `0x143` 是这条路的灵魂：body 即 d2 本体；没有 d2 时整条不发
/// （guard 见 `Qq8LoginConditions.applies` 的 `case 0x143`）。
const List<int> qq8ExchangeEmpTlvOrder = <int>[
  0x100, 0x10A, 0x116, 0x144, 0x143, 0x142, 0x154, 0x18,
  0x141, 0x08, 0x147, 0x177, 0x187, 0x188, 0x202, 0x511,
];

/// `wtlogin.login` 子命令 2（滑动验证码提交）的 TLV 顺序表。
///
/// 官方记载该子命令发 **4 项**，与下表数目一致。取值与顺序出自参考实现
/// oicq 的 `lib/wtlogin/login-password.js`（`sliderLogin`）：
///
/// ```js
/// const body = new Writer().writeU16(2).writeU16(4)
///     .writeBytes(t(0x193, ticket))   // ← 人工解出的票据
///     .writeBytes(t(0x8))
///     .writeBytes(t(0x104))           // ← 上一条响应里下发的新盐
///     .writeBytes(t(0x116))
///     .read();
/// ```
///
/// ⚠️ `0x104`（盐）是**必需**的：没有它整条请求没有意义（oicq 在
/// `!this.t104` 时直接拒绝发送）。[Qq8LoginBody.buildSlider] 会显式校验。
const List<int> qq8SliderTlvOrder = <int>[0x193, 0x08, 0x104, 0x116];

/// 滑验证提交的**实际清单**：基础 4 项，按版本与是否有 PoW 应答追加。
///
/// 三个参考实现分属不同世代，规则合起来是这样：
///
/// | 参考 | 写法 |
/// |---|---|
/// | js 时代 `login-password.js`（8.2.11 同代） | 恒定 4 项：`0x193 0x08 0x104 0x116` |
/// | 新版 `base-client.ts` | `0x193 0x08 0x104 0x116 [0x547] 0x544`，且 `ssover<=12` 时少一项 |
/// | 维护版 v1.26.25（2026-09 仍在用） | `0x542` **无条件**收尾（`t(0x542)` 在 ssover 分支外） |
///
/// 后两者对 `_sso_ver <= 12`（8.2.11 = 7）的结论一致：**不发 0x544**。
/// 而 8.9.50（19）/ 9.3.60（22）按新版要带 `0x544`（走降级空 body，与 8.9.50
/// 登录清单里 `0x544` 本身就是空体一致）。
///
/// ⚠️ 2026-09-15 更正：早先只在 `ssoVer > 12` 时追加 `0x542`——**看漏了维护版
/// 的 `t(0x542)` 在 if 块外面**。真机后果：8.2.11 的滑块提交一直缺这个 4 字节
/// 能力位，提交回 type=1「账号或密码错误」（密码包能到 type=2，说明不是密码
/// 问题；两次会话复用实验一次 237 一次 1，包缺项是唯一恒定差异）。
///
/// ⚠️ `0x547` 需要 `0x546` 的本地应答（PoW）——真机样本已拿到且能解
/// （`qq8_pow.dart`，typ=2 在第 9046 次迭代撞上），但仍**只在
/// [Qq8TlvContext.t547] 非空时追加**：解不出时宁可不发，也不编造答案。
List<int> qq8SliderTlvOrderFor(Qq8ApkInfo apk, {required bool hasT547}) {
  final order = <int>[0x193, 0x08, 0x104, 0x116];
  if (hasT547) order.add(0x547);
  if (apk.ssoVer > 12) order.add(0x544);
  // 维护版 oicq v1.26.25 的 sliderLogin：0x542 无条件收尾（553 无票据不发）。
  order.add(0x542);
  return order;
}

/// 密码登录（子命令 9）的**实际清单**：档案的官方顺序表 + 维护版追加的 `0x542`。
///
/// `0x548` 已在官方 37/38 项顺序表内（位于尾部），由
/// [Qq8LoginConditions] + [Qq8TlvContext.t548] 决定是否真正产出；
/// `0x542` 不在官方反编译顺序表里，只在这里按版本追加（ssoVer > 12）。
///
/// ⚠️ 已知与维护版的差异（**刻意保留**）：维护版 `passwordLogin` 的
/// `0x548 / 0x545 / 0x542` 对 8.2.11 也是无条件发的，而这里 ssoVer=7 时不追加
/// 0x542、0x548 由官方 guard（t.an / 自构造 PoW）控制。密码包已实测稳定到
/// type=2（服务端放行到验证环节），说明 8.2.11 密码包缺 542 **不被拒**——
/// 滑块提交那次 type=1 才是它的报文（2026-09-15 改 `qq8SliderTlvOrderFor`）。
/// 若日后 8.2.11 密码包也被拒，第一个要试的就是把 0x542 无条件加进来。
List<int> qq8PasswordTlvOrderFor(Qq8ApkInfo apk) {
  return <int>[
    ...apk.loginTlvOrder,
    if (apk.ssoVer > 12) 0x542,
  ];
}

/// TLV `0x545`（QIMEI）的取值方式。
///
/// **这是 8.2.11 → 8.9.50 之间一个真实的协议可见变化**，不是实现细节：
///
/// ```java
/// // 8.2.11  oicq/wlogin_sdk/tools/util.java:343
/// String s = sp.getString("QIMEI_DENGTA", "");     // SP: DENGTA_META
/// if (!TextUtils.isEmpty(s)) return MD5.toMD5Byte(s.getBytes());   // ← 16 字节
/// return new byte[0];
///
/// // 8.9.50  oicq/wlogin_sdk/tools/util.java:1493
/// QimeiListener l = qimeiListener;
/// if (l == null) return new byte[0];
/// String qimei = l.getQimei(context);
/// if (TextUtils.isEmpty(qimei)) return new byte[0];
/// return qimei.getBytes();                                          // ← 原文，不哈希
/// ```
///
/// 8.9.50 起 QIMEI 由**注入的监听器**提供（`WtloginHelper.setQimeiListener`），
/// 底层是新版独立 SDK `com.tencent.qimei`（不再走 Beacon）。
enum Qq8QimeiMode {
  /// 8.2.11：body = `MD5(qimei 字符串)`，16 字节。
  md5OfSource,

  /// 8.9.50 及以后：body = qimei 字符串**原文**的 UTF-8 字节。
  rawSource,
}

/// APK 参数（对应 oicq 的 `this.apk`）。
///
/// ## 版本差异都在这里
///
/// 8.2.11 / 8.9.50 / 9.3.60 / TIM 4.1.0 的登录组包差异**只有下面这几个字段**，
/// 其余（0x106 主体、0x144、0x145、0x147…）逐行相同：
///
/// | 字段 | 8.2.11 | 8.9.50 | 9.3.60 / TIM |
/// |---|---|---|---|
/// | [ssoVer] | 7 | **19** | **22** |
/// | [loginTlvOrder] | 37 项 | 37 项（**同上**） | 38 项（**+0x553**） |
/// | [tlv544DegradedBody] | `00000000` | **空** | **空** |
/// | [tlv553DegradedBody] | `null`（不发） | `null`（不发） | `[0]` |
///
/// `subSigMap` / `miscBitmap` / `mainSigMap` 三代**完全相同**
/// （`WtloginHelper` 里都是 66560 / 150470524 / 16724722）。
class Qq8ApkInfo {
  final String id;
  final String ver;
  final String sdkver;

  /// 客户端标识名，参与 `ksid` 派生（SSO 包头用，TLV 不用）。
  final String name;

  final int appid;
  final int subid;
  final int miscBitmap;
  final int mainSigMap;
  final int subSigMap;
  final int buildtime;
  final Uint8List sign;

  /// SSO 协议版本，同时写入 TLV `0x100._sso_ver` 与 `0x106._SSoVer`。
  ///
  /// 官方两个类里的值是**同步变化**的：8.2.11 = 7、8.9.50 = 19、9.3.60/TIM = 22。
  final int ssoVer;

  /// 该版本的登录 TLV 顺序表（官方 `request/k|j|l` 里的 `int[]`）。
  final List<int> loginTlvOrder;

  /// 安全 SDK 不可用时 TLV `0x544` 的 body。
  ///
  /// 8.2.11 的 `ByteData.getCode` 降级返回 `status = {0,0,0,0}`；
  /// 8.9.50 / TIM 的 `liteSign` 初值是 `new byte[0]`，故为空。
  final List<int> tlv544DegradedBody;

  /// TLV `0x553` 的降级 body；`null` 表示**该版本不发这个 TLV**。
  ///
  /// 9.3.60 / TIM 的 `0x553 = QSec.getFeKitAttach(...)`，fekit 不可用时
  /// 返回 `new byte[]{0}`；8.2.11 / 8.9.50 的顺序表里没有 0x553。
  final List<int>? tlv553DegradedBody;

  /// TLV `0x545` 的取值方式，见 [Qq8QimeiMode]。
  final Qq8QimeiMode qimeiMode;

  const Qq8ApkInfo({
    required this.id,
    required this.ver,
    required this.sdkver,
    required this.appid,
    required this.subid,
    required this.miscBitmap,
    required this.mainSigMap,
    required this.buildtime,
    required this.sign,
    this.name = '',
    this.subSigMap = 66560,
    this.ssoVer = 7,
    this.loginTlvOrder = qq8OfficialLoginTlvOrder,
    this.tlv544DegradedBody = const <int>[0, 0, 0, 0],
    this.tlv553DegradedBody,
    this.qimeiMode = Qq8QimeiMode.md5OfSource,
  });
}

/// TLV 打包所需的上下文。
///
/// 随机源与时间源均可注入——**这是让 TLV 输出可复现、可对照参考实现的前提**
/// （0x01 / 0x106 / 0x400 / 0x401 都含随机字节，0x01 / 0x106 / 0x400 含时间戳）。
class Qq8TlvContext {
  final int uin;
  final Qq8ApkInfo apk;
  final Qq8Device device;

  /// 口令的 MD5（16 字节）。
  final Uint8List passwordMd5;

  /// 当前序列号。
  final int seqId;

  /// 会话密钥材料。
  final Uint8List ksid;

  /// 缓存的 TLV 0x104 body 与 0x174 body。
  final Uint8List t104;
  final Uint8List t174;

  /// 票据。
  final Uint8List tgt;
  final Uint8List srmToken;

  /// 防刷计算题（TLV `0x546`）的应答，供滑验证提交里的 `0x547` 使用。
  ///
  /// 参考实现：响应里若带 `0x546`，本地算出 `t547` 后随子命令 2 一起提交
  /// （`base-client.ts` 的 `calcPoW`）。**我们目前没有可核对的 `0x546` 样本**，
  /// 所以这里只做承载位、不猜算法：拿到真样本前 `t547` 为空 ⇒ 清单里没有
  /// `0x547`（见 [qq8SliderTlvOrderFor]）。
  final Uint8List? t547;

  /// 客户端自构造防刷块（TLV `0x548`）的应答 body。
  ///
  /// 与服务端下发的 [t547] 不同：`0x548` 是客户端自造挑战、自解的 PoW
  /// （构造见 `qq8_pow.dart` 的 `qq8BuildClientPow548`，出处为 2026-09 仍在
  /// 维护的 oicq 分支 `lib/wtlogin/tlv.js` 的 `0x548`）。密码登录包携带。
  final Uint8List? t548;

  /// 随机源（用于 TLV 内的随机字段，如 0x01 的 4 字节、0x400 的 16 字节）。
  final Uint8List Function(int n) randomBytes;

  /// TEA 填充字节的来源。
  ///
  /// QQ 的 TEA 会在明文头部垫入随机字节，服务端解密时**直接丢弃**，
  /// 内容不参与任何协议语义。两个参考实现用的源都不一样：
  ///
  /// | 实现 | 填充来源 |
  /// |---|---|
  /// | 官方客户端 | `java.util.Random`（线性同余，可预测） |
  /// | oicq | `Buffer.allocUnsafe`（未初始化内存） |
  ///
  /// 因此密文本身**不可复现**，这是算法特性而非实现缺陷。做成可注入
  /// 纯粹是为了让自测能产出确定性密文并与参考实现逐字节比对。
  final Uint8List Function(int n) teaPadding;

  /// 口令盐（官方 `async_context._msalt`）。
  ///
  /// 参与 TLV 0x106 的 TEA 密钥派生：**非 0 时用它替代 uin** 写入密钥种子
  /// 的后 8 字节。oicq 的 0x106 里没有这个概念，是官方较新的做法。
  final int msalt;

  /// 0x106 里的登录类型：`1` = 口令登录，`3` = **短信验证登录后的那次登录**
  /// （官方 `WtloginHelper.java:2310`：`int i4 = _isSmslogin ? 3 : 1;`，同处
  /// `:1439` 设 `_isSmslogin`，`:1489` 把口令换成 `_mpasswd`）。
  final int loginType;

  /// 账号串（官方 `t.g`）。写进 0x106 尾部的长度前缀字段——uin 登录时就是
  /// uin 的十进制串，手机号登录时是手机号；为空则退回 `'$uin'`。
  final String? account;

  /// TLV `0x544` 的形态开关（**实验字段**，null = 官方降级路径）。
  ///
  /// * `null`：发官方的"安全 SDK 不可用"降级 body（`apk.tlv544DegradedBody`）。
  /// * 非 null：发**参考实现 oicq 的 v==2 结构**，值就是当前的子命令号：
  ///   `u32(0) ‖ tlv(guid) ‖ tlv(sdkver) ‖ u32(子命令) ‖ u32(0)`
  ///   （oicq `lib/core/tlv.ts` 的 `0x544` 打包函数，密码登录传 `(2, 9)`）。
  ///
  /// 为什么要有它：官方那份是真签名（来自安全 SDK），我们发不出来；oicq 用
  /// 结构占位在实测里能过。两种形态哪个被服务端接受，只有真机能回答——
  /// 默认仍是官方降级（不改变既有行为），实验时显式打开。
  final int? t544SubCmd;

  /// 当前时间（毫秒）。
  final int Function() nowMillis;

  const Qq8TlvContext({
    required this.uin,
    required this.apk,
    required this.device,
    required this.passwordMd5,
    required this.ksid,
    required this.t104,
    required this.t174,
    required this.tgt,
    required this.srmToken,
    this.t547,
    this.t548,
    this.msalt = 0,
    this.loginType = 1,
    this.account,
    this.t544SubCmd,
    this.seqId = 0,
    this.randomBytes = _secureRandomImpl,
    this.teaPadding = _secureRandomImpl,
    this.nowMillis = _wallClockImpl,
  });
}

/// 默认随机源（顶层函数，其 tear-off 是编译期常量，可作默认参数）。
Uint8List _secureRandomImpl(int n) {
  final r = math.Random.secure();
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

/// 默认时间源。
int _wallClockImpl() => DateTime.now().millisecondsSinceEpoch;

/// TLV 打包器。
abstract final class Qq8Tlv {
  /// 打包：`[tag][len][body]`。
  ///
  /// [args] 对应 oicq 里 TLV 函数的可变参数（如 0x100 的 `emp`、0x17c 的 `code`）。
  static Uint8List pack(
    Qq8TlvContext ctx,
    int tag, [
    List<Object?> args = const [],
  ]) {
    final b = body(ctx, tag, args);
    return (ByteWriter()
          ..u16(tag)
          ..u16(b.length)
          ..raw(b))
        .build();
  }

  /// 只产出 body（不含 tag/len 头）。
  static Uint8List body(
    Qq8TlvContext ctx,
    int tag, [
    List<Object?> args = const [],
  ]) {
    final w = ByteWriter();
    final rnd = ctx.randomBytes;
    final now = ctx.nowMillis();
    final d = ctx.device;

    switch (tag) {
      case 0x01:
        w.u16(1); // ip ver
        w.raw(rnd(4));
        w.u32(ctx.uin);
        w.u32(now & 0xFFFFFFFF);
        w.raw(Uint8List(4)); // ip
        w.u16(0);

      case 0x08:
        w.u16(0);
        w.u32(2052);
        w.u16(0);

      case 0x16:
        w.u32(7);
        w.u32(16);
        w.u32(537067759);
        w.raw(d.guid);
        _tlv(w, 'com.tencent.qqlite');
        _tlv(w, '4.0.2');
        _tlv(w, ctx.apk.sign);

      case 0x18:
        w.u16(1); // ping ver
        w.u32(1536);
        w.u32(ctx.apk.appid);
        w.u32(0);
        w.u32(ctx.uin);
        w.u16(0);
        w.u16(0);

      case 0x1B:
        w.u32(0);
        w.u32(0);
        w.u32(3);
        w.u32(4);
        w.u32(72);
        w.u32(2);
        w.u32(2);
        w.u16(0);

      case 0x1D:
        w.u8(1);
        w.u32(184024956);
        w.u32(0);
        w.u8(0);
        w.u32(0);

      case 0x1F:
        w.u8(0);
        _tlv(w, 'android');
        _tlv(w, '7.1.2');
        w.u16(2);
        _tlv(w, 'China Mobile GSM');
        _tlv(w, Uint8List(0));
        _tlv(w, 'wifi');

      case 0x33:
        w.raw(d.guid);

      case 0x35:
        w.u32(8);

      case 0x100:
        final emp = args.isNotEmpty && (args[0] as num? ?? 0) != 0;
        w.u16(1); // db buf ver
        w.u32(ctx.apk.ssoVer); // _sso_ver：8.2.11=7 / 8.9.50=19 / 9.3.60=22
        w.u32(ctx.apk.appid);
        w.u32(emp ? 2 : ctx.apk.subid);
        w.u32(0);
        w.u32(ctx.apk.mainSigMap);

      case 0x104:
        w.raw(ctx.t104);

      case 0x106:
        // 二维码扫码登录时，服务端把扫到的 t106 **整块**给客户端，登录包要原样回带
        // （参考实现 `writeU16(0x106) + writeTlv(t106)`）⇒ 有注入就直接用，不重新生成。
        final injected106 = args.isNotEmpty ? args[0] : null;
        if (injected106 is List<int> && injected106.isNotEmpty) {
          w.raw(injected106);
          break;
        }
        final inner = ByteWriter()
          ..u16(4) // tgtgt ver
          ..raw(rnd(4))
          ..u32(ctx.apk.ssoVer) // _SSoVer：8.2.11=7 / 8.9.50=19 / 9.3.60=22
          ..u32(ctx.apk.appid)
          ..u32(0)
          ..u64(ctx.uin)
          ..u32(now & 0xFFFFFFFF)
          ..raw(Uint8List(4)) // dummy ip
          ..u8(1) // save password
          ..raw(ctx.passwordMd5)
          ..raw(d.tgtgt)
          ..u32(0)
          ..u8(1) // guid available
          ..raw(d.guid)
          ..u32(ctx.apk.subid)
          ..u32(ctx.loginType) // 1 = 口令登录 / 3 = 短信验证登录后的那次
          ..raw((ByteWriter()
                  ..bytes16(utf8.encode(ctx.account ?? '${ctx.uin}')))
              .build())
          ..u16(0);
        // TEA 密钥种子 = guid(16) ‖ u64(msalt 非 0 时用 msalt，否则用 uin)(8)
        //
        // ⚠️ 这里**刻意与参考实现 oicq 不同**。
        //
        //   oicq：MD5(password_md5 ‖ 0x00000000 ‖ uin_u32be)
        //   官方：MD5(guid(16) ‖ u64(uin 或 msalt)(8))
        //
        // 官方三个版本（8.2.11 / 8.9.50 / 9.3.60）的 tlv_t106 逐行对比后
        // **完全一致**（只有 _SSoVer 从 7 → 19 → 22 递增），而 oicq 的公式
        // 与三者都不符——见 ../analysis/ 下的对照文档与反编译产物。
        // 以官方为准。
        final seed = Uint8List(24);
        final guidLen = d.guid.length < 16 ? d.guid.length : 16;
        seed.setRange(0, guidLen, d.guid);
        seed.setRange(
          16,
          24,
          (ByteWriter()..u64(ctx.msalt != 0 ? ctx.msalt : ctx.uin)).build(),
        );
        final key = md5Bytes(seed);
        final innerBytes = inner.build();
        w.raw(qqTeaEncrypt(
          innerBytes,
          key,
          paddingBytes: ctx.teaPadding(qqTeaPadLength(innerBytes.length) + 3),
        ));

      case 0x107:
        w.u16(0); // pic type
        w.u8(0); // captcha type
        w.u16(0); // pic size
        w.u8(1); // ret type

      case 0x108:
        w.raw(ctx.ksid);

      case 0x109:
        w.raw(md5Bytes(utf8.encode(d.imei)));

      case 0x10A:
        w.raw(ctx.tgt);

      case 0x112:
        // 账号串原文。官方 8.2.11 `k.java:131`：
        //   if (x.g == null || check_uin_account(x.g)) 跳过
        // 即 **uin 登录时官方不发**；只有手机号/邮箱登录才发。
        // 本工程按 uin 登录，故默认走不到这里（由 login 层的 guard 决定）。
        final acc = args.isNotEmpty ? args[0] : null;
        if (acc is String && acc.isNotEmpty) {
          w.raw(Uint8List.fromList(utf8.encode(acc)));
        }

      case 0x166:
        // 官方 8.2.11 `k.java:176`：仅当 (i4 & 128) != 0。
        // body = i8(t.x)，静态 t.x 默认 1 → 恒定 [0x01]。
        w.u8(1);

      case 0x172:
        // 官方 8.2.11 `k.java:196`：仅当 `t.r` 非空。
        // 而 `t.r` 是**服务端回显**赋值的（`oicq_request.java:1341`），
        // 首登必为空 → 官方自己也不发。
        final r = args.isNotEmpty ? args[0] : null;
        if (r is List<int> && r.isNotEmpty) w.raw(r);

      case 0x185:
        // 官方 8.2.11 `k.java:211`：仅当 i3 == 3。
        // body = [0x01, i8(1)]。
        w.u8(1);
        w.u8(1);

      case 0x201:
        // 官方 8.2.11 `k.java:253`：仅当静态 `k.L` 非空。
        // body 是 4 段 `u16 长度 + 字节`：L, M, "qq", N。
        final l = args.isNotEmpty ? args[0] : null;
        if (l is List<int> && l.isNotEmpty) {
          final m = args.length > 1 && args[1] is List<int>
              ? args[1] as List<int>
              : const <int>[];
          final n = args.length > 2 && args[2] is List<int>
              ? args[2] as List<int>
              : const <int>[];
          for (final seg in <List<int>>[l, m, utf8.encode('qq'), n]) {
            w.u16(seg.length);
            w.raw(seg);
          }
        }

      case 0x542:
        // 活跃能力位 TLV（维护版 oicq v1.26.25 `lib/wtlogin/tlv.js` 的 0x542）。
        //
        // 该分支在密码 / 滑块提交 / 扫码登录的包尾**无条件**追加，内容按 ssoVer
        // 分两档（同文件）：ssoVer ≥ 20 发 6 字节 `4A 04 60 01 78 01`，
        // 其余发 4 字节 `4A 02 60 01`。
        //
        // 8.2.11 的官方顺序表里没有这个 TLV，因此它只出现在
        // [qq8PasswordTlvOrderFor] / [qq8SliderTlvOrderFor] 对 ssoVer>12 的
        // 追加段里，不进官方反编译顺序表。
        if (ctx.apk.ssoVer >= 20) {
          w.raw(const <int>[0x4A, 0x04, 0x60, 0x01, 0x78, 0x01]);
        } else {
          w.raw(const <int>[0x4A, 0x02, 0x60, 0x01]);
        }

      case 0x548:
        // 两条来源：
        // * 官方 8.2.11 `k.java:394`：仅当服务端下发的 `t.an` 非空才发，
        //   首登为空 → 不发（由 args/an 路径保留）；
        // * 维护版 oicq v1.26.25：密码登录无条件发客户端自构造 PoW 应答，
        //   body 在 [Qq8TlvContext.t548]（见 `qq8BuildClientPow548`）。
        final t548 = ctx.t548;
        if (t548 != null && t548.isNotEmpty) {
          w.raw(t548);
          break;
        }
        final an = args.isNotEmpty ? args[0] : null;
        if (an is List<int> && an.isNotEmpty) w.raw(an);

      case 0x116:
        w.u8(0);
        w.u32(ctx.apk.miscBitmap);
        w.u32(ctx.apk.subSigMap); // 0x10400，三代相同
        w.u8(1); // app id list 长度
        w.u32(1600000226); // app id list[0]

      case 0x544:
        // 安全 SDK 不可用时官方的降级 body（默认路径，出处见上方文档）。
        //
        // 实验开关：`ctx.t544SubCmd` 非空时改发参考实现 oicq 的 v==2 结构
        //   u32(0) ‖ tlv(guid) ‖ tlv(sdkver) ‖ u32(子命令) ‖ u32(0)
        // （oicq `tlv.ts` 的 `0x544`；它没有真正的签名，只是把格式填满。
        //   哪个形态服务端认，只有真机能回答——见 ctx 字段的注释。）
        final t544Sub = ctx.t544SubCmd;
        if (t544Sub == null) {
          w.raw(Uint8List.fromList(ctx.apk.tlv544DegradedBody));
        } else {
          w.u32(0);
          _tlv(w, ctx.device.guid);
          _tlv(w, utf8.encode(ctx.apk.sdkver));
          w.u32(t544Sub);
          w.u32(0);
        }

      case 0x545:
        // QIMEI。取值方式随版本变（见 Qq8QimeiMode）：
        //   8.2.11  body = MD5(qimei 字符串)        —— 16 字节
        //   8.9.50+ body = qimei 字符串原文的 UTF-8
        //
        // ⚠️ 拿不到 QIMEI 时官方**整条不发**（8.9.50 `j.java` case 1349 /
        // 8.2.11 `k.java` case 1349 都只在非空时才组 TLV），滤除由
        // `Qq8LoginConditions.qimei` 的 guard 负责——这里不该产出空 body
        // （那是与官方不一致的偏差，2026-09-11 修正）。
        final qimeiArg = args.isNotEmpty ? args[0] : null;
        final qimei = qimeiArg is String && qimeiArg.isNotEmpty ? qimeiArg : null;
        if (qimei != null) {
          final raw = Uint8List.fromList(utf8.encode(qimei));
          w.raw(
            switch (ctx.apk.qimeiMode) {
              Qq8QimeiMode.md5OfSource => md5Bytes(raw),
              Qq8QimeiMode.rawSource => raw,
            },
          );
        }

      case 0x547:
        // 防刷计算题（0x546）的应答。仅在算得出时才进清单（见 Qq8TlvContext.t547）；
        // 空 body 没有意义，所以这里显式抛错，避免发出一个空壳。
        final t547 = ctx.t547;
        if (t547 == null || t547.isEmpty) {
          throw ArgumentError(
              'TLV 0x547 需要 ctx.t547（0x546 的应答），当前为空——不该把它进清单');
        }
        w.raw(t547);

      case 0x553:
        // 仅 9.3.60 / TIM 的顺序表里有。官方 =
        //   QSec.getFeKitAttach(ctx, uin, "0x810", "0x9")，
        // fekit 不可用时返回 new byte[]{0}。
        final b553 = ctx.apk.tlv553DegradedBody;
        if (b553 != null) {
          w.raw(Uint8List.fromList(b553));
        }

      case 0x124:
        _tlv(w, _cut(d.osType, 16));
        _tlv(w, _cut(d.version.release, 16));
        w.u16(2); // network type
        _tlv(w, _cut(d.sim, 16));
        w.u16(0);
        _tlv(w, _cut(d.apn, 16));

      case 0x128:
        w.u16(0);
        w.u8(0); // guid new
        w.u8(1); // guid available
        w.u8(0); // guid changed
        w.u32(16777216); // guid flag
        _tlv(w, _cut(d.model, 32));
        _tlv(w, _cutBytes(d.guid, 16));
        _tlv(w, _cut(d.brand, 16));

      case 0x141:
        w.u16(1); // ver
        _tlv(w, d.sim);
        w.u16(2); // network type
        _tlv(w, d.apn);

      case 0x142:
        w.u16(0);
        _tlv(w, _cut(ctx.apk.id, 32));

      case 0x143:
        w.raw(_bytesArg(args, 0));

      case 0x144:
        final inner = ByteWriter()
          ..u16(5) // tlv 计数
          ..raw(pack(ctx, 0x109))
          ..raw(pack(ctx, 0x52D))
          ..raw(pack(ctx, 0x124))
          ..raw(pack(ctx, 0x128))
          ..raw(pack(ctx, 0x16E));
        final innerBytes = inner.build();
        w.raw(qqTeaEncrypt(
          innerBytes,
          d.tgtgt,
          paddingBytes:
              ctx.teaPadding(qqTeaPadLength(innerBytes.length) + 3),
        ));

      case 0x145:
        w.raw(d.guid);

      case 0x147:
        w.u32(ctx.apk.appid);
        _tlv(w, _cut(ctx.apk.ver, 5));
        _tlv(w, ctx.apk.sign);

      case 0x127:
        // 短信验证码（官方 `tlv_t127.get_tlv_127(code, random)`）：
        //   u16 version(该字段默认 0) ‖ u16 len(code) ‖ code
        //   ‖ u16 len(random) ‖ random
        // `random` 来自**检查手机号那一步回包里 0x126 的 get_random()**。
        final code127 = args.isNotEmpty ? args[0] : null;
        final rand127 = args.length > 1 ? args[1] : null;
        w.u16(0);
        w.u16(code127 is List<int> ? code127.length : 0);
        if (code127 is List<int>) w.raw(code127);
        w.u16(rand127 is List<int> ? rand127.length : 0);
        if (rand127 is List<int>) w.raw(rand127);

      case 0x184:
        // 短信验证登录第二步的"口令校验块"（官方 `tlv_t184.get_tlv_184(msalt, mpasswd)`）：
        //   body = MD5( MD5(mpasswd 的字节) ‖ u64(msalt) )
        // —— 官方代码里 fill_body 前又做了一次 MD5（tlv_t184.java:27-36），所以最终
        // 就是 16 字节；`mpasswd` 是**本地每次现生成的 16 位随机字母串**
        // （tools/util.java:200-212），不用跟服务端要。
        final mpasswd184 = args.isNotEmpty && args[0] is String ? args[0] as String : '';
        final msalt184 = args.length > 1 && args[1] is int ? args[1] as int : 0;
        final inner = <int>[
          ...md5Bytes(utf8.encode(mpasswd184)),
          for (var i = 7; i >= 0; i--) (msalt184 >> (8 * i)) & 0xFF,
        ];
        w.raw(md5Bytes(inner));

      case 0x148:
        // 设备信息 + 三个时间戳（官方 `tlv_t148.get_tlv_148(guid, t1, t2, t3, a, b)`）：
        //   u16 len(≤32) ‖ guid ‖ u32(t1) ‖ u32(t2) ‖ u32(t3) ‖ u16 len ‖ a ‖ u16 len ‖ b
        // 官方用 `int64_to_buf32`（**只写低 4 字节**），所以三个时间戳是 u32。
        // ⚠️ 各参数的具体语义（哪三个时间、a/b 是什么）要看**子命令 13 的调用处**
        // —— 目前只有 13（短信验证登录）会用到它，接入那条流程时再定值，
        // 这里先把结构做对，不要凭猜填。
        final a148 = args.isNotEmpty ? args[0] : null;
        final b148 = args.length > 1 ? args[1] : null;
        final c148 = args.length > 2 ? args[2] : null;
        w.u16(a148 is List<int> ? (a148.length > 32 ? 32 : a148.length) : 0);
        if (a148 is List<int>) w.raw(a148.sublist(0, a148.length > 32 ? 32 : a148.length));
        w.u32(args.length > 3 && args[3] is int ? args[3] as int : 0);
        w.u32(args.length > 4 && args[4] is int ? args[4] as int : 0);
        w.u32(args.length > 5 && args[5] is int ? args[5] as int : 0);
        w.u16(b148 is List<int> ? b148.length : 0);
        if (b148 is List<int>) w.raw(b148);
        w.u16(c148 is List<int> ? c148.length : 0);
        if (c148 is List<int>) w.raw(c148);

      case 0x153:
        // root 标记（官方 `tlv_t153.get_tlv_153(i)` = 一个 u16）。
        w.u16(args.isNotEmpty && args[0] is int ? args[0] as int : 0);

      case 0x154:
        w.u32(ctx.seqId + 1);

      case 0x16A:
        // 与 0x106 同理：二维码登录要回带扫码拿到的 t16a；平时用 ctx 里的票据。
        final injected16A = args.isNotEmpty ? args[0] : null;
        if (injected16A is List<int> && injected16A.isNotEmpty) {
          w.raw(injected16A);
        } else {
          w.raw(ctx.srmToken);
        }

      case 0x318:
        // `tgtQR`：二维码登录专用。官方没有专用类，是用泛型 `tlv_t(792)` 直接包
        // 服务端返回的那块字节（`writeU16(0x318) + writeTlv(tgtQR)`）。
        // 密码登录下 `applies(0x318)` 恒为假，永远不会走到这里。
        final tgtQr = args.isNotEmpty ? args[0] : null;
        if (tgtQr is! List<int> || tgtQr.isEmpty) {
          throw ArgumentError('TLV 0x318 需要 tgtQR 字节（来自扫码结果），当前为空');
        }
        w.raw(tgtQr);

      case 0x16E:
        w.raw(utf8.encode(d.model));

      case 0x174:
        w.raw(ctx.t174);

      case 0x177:
        w.u8(0x01);
        w.u32(ctx.apk.buildtime);
        _tlv(w, ctx.apk.sdkver);

      case 0x17A:
        w.u32(9);

      case 0x17C:
        _tlv(w, args.isNotEmpty ? args[0]! : '');

      case 0x187:
        w.raw(md5Bytes(utf8.encode(d.macAddress)));

      case 0x188:
        w.raw(md5Bytes(utf8.encode(d.androidId)));

      case 0x191:
        w.u8(0x82);

      case 0x193:
        w.raw(_bytesArg(args, 0));

      case 0x194:
        w.raw(d.imsi);

      case 0x197:
      case 0x198:
        _tlv(w, Uint8List(1));

      case 0x202:
        _tlv(w, _cut(d.wifiBssid, 16));
        _tlv(w, _cut(d.wifiSsid, 32));

      case 0x400:
        w.u16(1);
        w.u64(ctx.uin);
        w.raw(d.guid);
        w.raw(rnd(16));
        w.u32(1);
        w.u32(16);
        w.u32(now & 0xFFFFFFFF);
        w.raw(Uint8List(0));

      case 0x401:
        w.raw(rnd(16));

      case 0x511:
        const domains = <String>[
          'tenpay.com', 'openmobile.qq.com', 'docs.qq.com', 'connect.qq.com',
          'qzone.qq.com', 'vip.qq.com', 'qun.qq.com', 'game.qq.com',
          'qqweb.qq.com', 'office.qq.com', 'ti.qq.com', 'mail.qq.com',
          'gamecenter.qq.com', 'mma.qq.com',
        ];
        w.u16(domains.length);
        for (final v in domains) {
          w.u8(0x01);
          _tlv(w, v);
        }

      case 0x516:
        w.u32(0);

      case 0x521:
        w.u32(0); // product type
        w.u16(0);

      case 0x525:
        w.u16(1); // tlv 计数
        w.u16(0x536);
        _tlv(w, Uint8List.fromList(const [0x01, 0x00]));

      case 0x52C:
        // 短信验证登录的"额外验证标志 + 额外 uin"（官方 `tlv_t52c.get_tlv_52c(i, j)` =
        // u8(i) ‖ u64(j)）。官方便捷重载 `CheckSMSVerifyLoginAccount(appid, subappid,
        // account, sigInfo)` 传的就是 `extraFlag=1, extraUin=-1`（WtloginHelper.java:2674），
        // 所以手机号登录这条默认 (1, 0xFFFF...FFFF)。
        final flag52c = args.isNotEmpty && args[0] is int ? args[0] as int : 1;
        final uin52c = args.length > 1 && args[1] is int
            ? args[1] as int
            : -1; // = 0xFFFFFFFFFFFFFFFF
        w.u8(flag52c & 0xFF);
        for (var i = 7; i >= 0; i--) {
          w.u8((uin52c >> (8 * i)) & 0xFF);
        }

      case 0x52D:
        w.raw(protoEncode(<int, Object?>{
          1: d.bootloader,
          2: d.procVersion,
          3: d.version.codename,
          4: d.version.incremental,
          5: d.fingerprint,
          6: d.bootId,
          7: d.androidId,
          8: d.baseband,
          9: d.version.incremental,
        }));

      default:
        throw ArgumentError(
            '未知 TLV 编号 0x${tag.toRadixString(16)}（8.2.11 表内无此项）');
    }
    return w.build();
  }

  // -- 内部工具 -------------------------------------------------------------

  /// `writeTlv`：uint16 长度前缀 + 内容。
  static void _tlv(ByteWriter w, Object v) {
    final bytes = v is String ? utf8.encode(v) : (v as List<int>);
    w.u16(bytes.length);
    w.raw(bytes);
  }

  static Uint8List _bytesArg(List<Object?> args, int i) {
    if (args.length <= i) return Uint8List(0);
    final v = args[i];
    if (v is Uint8List) return v;
    if (v is List<int>) return Uint8List.fromList(v);
    if (v is String) return Uint8List.fromList(utf8.encode(v));
    return Uint8List(0);
  }

  /// 按 UTF-16 码元截断（与 JS 的 `String.prototype.slice` 行为一致）。
  ///
  /// 参考实现用的是 JS 字符串切片，对 ASCII 等价于按字节截断。
  /// 这里显式按码元截断再编码，避免非 ASCII 情况下与参考实现不一致。
  static String _cut(String s, int n) =>
      s.length <= n ? s : s.substring(0, n);

  static Uint8List _cutBytes(Uint8List b, int n) =>
      b.length <= n ? b : Uint8List.sublistView(b, 0, n);
}

// ---------------------------------------------------------------------------
// 最小 protobuf 编码器
//
// 只服务 TLV 0x52d（安卓构建信息），字段全是字符串（wire type 2）。
// 不引入 protobuf 依赖——为这一个消息装一整套 proto 运行时不合算。
// ---------------------------------------------------------------------------

/// 编码一个简单消息。值为 `int` 时用 varint，其余按长度前缀字节串。
Uint8List protoEncode(Map<int, Object?> fields) {
  final w = ByteWriter();
  for (final e in fields.entries) {
    final v = e.value;
    if (v == null) continue;
    if (v is int) {
      _varint(w, (e.key << 3) | 0);
      _varint(w, v);
    } else {
      final bytes = v is String ? utf8.encode(v) : (v as List<int>);
      _varint(w, (e.key << 3) | 2);
      _varint(w, bytes.length);
      w.raw(bytes);
    }
  }
  return w.build();
}

/// LEB128 变长整数。
void _varint(ByteWriter w, int v) {
  var n = v;
  while (n >= 0x80) {
    w.u8((n & 0x7F) | 0x80);
    n >>= 7;
  }
  w.u8(n & 0x7F);
}
