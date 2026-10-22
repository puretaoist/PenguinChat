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
import 'qq8_protocol_det.dart';
import 'qq8_t544.dart' show qq8T544Sign;

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
///
/// ## 2026-10-22 逐行对齐官方（此前表抄自 oicq，已过时）
///
/// 官方 `oicq/wlogin_sdk/request/m.java` 的 `a(...)` 用一长串 `arraycopy`
/// 拼 body，逐项顺序为：
/// `0x100 → 0x10a → 0x116 → 0x108 → 0x144 → 0x143 → 0x142 → 0x154 →
/// 0x18 → 0x141 → 0x08 → 0x511 → 0x147 → 0x172 → 0x177 → 0x187 →
/// 0x188 → 0x194 → 0x201 → 0x202 → 0x544`。
///
/// 修正三处：
/// 1. **补 0x108（ksid）**：官方在 `bArr2 != null && bArr2.length > 0` 时
///    恒发（`tlv_t108Var.get_tlv_108(bArr2)`，实参为 `t.ac`），位置在 0x116 之后；
/// 2. **补 0x544**：`bArr43 != null` 时追加到**末尾**（`tlv_t544.get_tlv_544(...)`
///    内部走 `ByteData.getCode`，未加载 `libpoxy.so` 时降级为 4 个零字节）；
/// 3. **0x511 位置**：官方在 0x08 之后、0x147 之前（此前误放在末尾）。
///
/// `0x172` / `0x194` / `0x201` 保留位次，靠 `Qq8LoginConditions.applies` 的
/// guard 过滤（对应官方 `if (t.r != null && t.r.length > 0)` 这类判断）。
const List<int> qq8ExchangeEmpTlvOrder = <int>[
  0x100, 0x10A, 0x116, 0x108, 0x144, 0x143, 0x142, 0x154, 0x18,
  0x141, 0x08, 0x511, 0x147, 0x172, 0x177, 0x187, 0x188, 0x194,
  0x201, 0x202, 0x544,
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

/// 滑验证提交的**实际清单**——**以官方三版本反编译为准**(2026-09-15 深挖)。
///
/// 官方构建点（逐行核对）：
///
/// | 版本 | 构建器 | 官方 TLV 序（数组组装序） |
/// |---|---|---|
/// | 8.2.11 | `request/n.java`（jadx-main） | `0x193/0x2 → 0x8 → 0x104 → 0x116 → 0x547`（**5 项**） |
/// | 8.9.50 | `WtloginHelper.java:938-990`（jadx8950） | 同上 + `0x544`（**6 项**） |
/// | 9.3.60/TIM | `WtloginHelper.java:482-531`（**tim-dex**，ssoVer=22 同代） | 再 + `0x544("810_2")` + `0x553("0x2")`（**7 项**） |
///
/// 关键官方语义（全部逐行核对）：
///
/// * **`0x547` 恒在**：`tlv_t547.get_tlv_547(null)` 产出**空 body 的 4 字节
///   TLV**，照发不误。有应答（响应 `0x546` → 同步 `pow.b.b()` 解出 → `t.am`
///   缓存）就发应答；没应答发空 body——不是"没有就不发"。
/// * **`0x193` vs `0x2` 由开关决定**：`n.K`（8.9.50 `n.v`）= true 走
///   `CheckWebsigAndGetSt`（Web/滑块 ticket → 0x193）；false 走
///   `CheckPictureAndGetSt`（传统图片验证码 → 0x2(sig,code)）。我们走滑块。
/// * **`0x544`**：8.9.50 起恒带（`get_tlv_544(uin,"810_2",subcmd)`，
///   安全 SDK 不可用 → 空 body）；8.2.11 的流程里没有它。
/// * **`0x553`**：9.3.60/TIM 特有，`getFeKitAttach(...,"0x810","0x2")`——注意
///   第四参是**子命令 2**，不是密码登录的 "0x9"。此前因 9.3.60 的
///   `WtloginHelper.java` 本体缺失而标"无法核对"；现已由 **TIM 完整反编译**
///   证实：`tim-classes2.dex/WtloginHelper.java:509`（`"0x810","0x2"`）与
///   `:507`（`get_tlv_544(j3,"810_2",subcmd=2)`）逐行对上。
///   降级语义：`tlv_t553.get_tlv_t553(null)` → **空 body**（非单字节 00）；我们
///   档案里的 `tlv553DegradedBody=[0]` 是降级占位（fekit 为 native 计算，拿不到
///   真实值），与官方 `null→空` 差 1 字节——同为无效降级签名，影响可忽略。
/// * **没有 `0x542`！** 8.9.50 的 `get_tlv_542` 只出现在**子命令 8**
///   （请求下发短信，带 174/17a 令牌）的流程里（`WtloginHelper:8501`）。
///   维护版 oicq 把它错位带进了滑块提交——我们此前跟随它发了 542，
///   真机对应 type=1（2026-09-15 官方对照后修正）。
List<int> qq8SliderTlvOrderFor(Qq8ApkInfo apk, {Qq8SliderTicketForm form = Qq8SliderTicketForm.websig}) {
  final order = <int>[
    // 官方 `request/n.java`：`K ? 0x193 : 0x2` —— 首项随 n.K 切换，其余全同。
    form == Qq8SliderTicketForm.picture ? 0x02 : 0x193,
    0x08,
    0x104,
    0x116,
    0x547,
  ];
  if (apk.ssoVer > 12) order.add(0x544);
  // 9.3.60 / TIM：官方滑块提交还带 0x553 —— getFeKitAttach(...,"0x810","0x2")
  // （第二个参数是**子命令 2**）。按档案字段判断：8.2.11/8.9.50 = null 不发。
  if (apk.tlv553DegradedBody != null) order.add(0x553);
  return order;
}

/// 滑验证提交时**首项 TLV 的形态**——官方 `request/n.java` 里的 `n.K` 开关。
///
/// | 值 | 官方入口 | 首项 | 官方语义 |
/// |---|---|---|---|
/// | [websig] | `CheckWebsigAndGetSt` / `MsfCommand.submitPuzzleVerifyCodeTicket` | `0x193` | **Web/滑块 puzzle ticket**（ti.qq.com 那套） |
/// | [picture] | `CheckPictureAndGetSt` / `MsfCommand.submitVerifyCode` | `0x02` | 传统图片验证码（code + 图片签名） |
///
/// ⚠️ **日志无法区分两者**：`WtloginHelper` 的私有主流程里 `LOGI` 字符串是硬编码的
/// `"user:" + uin + " CheckPictureAndGetSt Seq:..."`，`CheckWebsigAndGetSt` 只是先置
/// `n.K = true` 再转调它，所以官方 wlogin 文件日志里**永远只出现 CheckPictureAndGetSt**。
/// 判断依据只能是 TLV 内容本身，不能是日志方法名。
enum Qq8SliderTicketForm {
  /// `n.K = true` → TLV `0x193`（body = 裸 ticket）。oicq 与我们都走这条。
  websig,

  /// `n.K = false` → TLV `0x02`（body = `u16 0 ‖ u16len(ticket) ‖ ticket ‖ u16len(sign) ‖ sign`）。
  picture,
}

/// 密码登录（子命令 9）的**实际清单**：档案的官方顺序表 + 维护版追加的 `0x542`。
///
/// `0x548` 已在官方 37/38 项顺序表内（位于尾部），由
/// [Qq8LoginConditions] + [Qq8TlvContext.t548] 决定是否真正产出；
/// `0x542` 不在官方反编译顺序表里，只在这里按版本追加（ssoVer > 12）。
///
/// 第二轮深逆（2026-09-15，`analysis/QQ-官方三版本登录流程对照.md` §8.3）确认
/// 三条铁证：8.2.11 无 `tlv_t542` 类；8.9.50 `j.java` 37 项 switch 无 1346 case；
/// 官方只在子命令 7/8（短信）与业务层注入（subcmd 23/25 的
/// `extraLoginTLVMap`）构建 0x542。因此这里的 542 是**业务层注入仿真**
/// （官方 `extraLoginTLVMap` 通道，`j.java:95-100` 会并入 TLV 计数），
/// 不是 wlogin_sdk 行为。
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
///
/// ## ⚠ 构造器默认值 ≠ 线上实际值（第三次踩同一个坑）
///
/// 上面表里的 `miscBitmap = 150470524`（`0x08F7FF7C`）是 `WtloginHelper`
/// 构造器赋的初值。但 MSF 在每个密码登录入口都调 `SetUinDeviceToken(true)`，
/// 该开关让 SDK 在发请求前做一次 `miscBitmap |= WLOGIN_DA2`：
///
/// * `com/tencent/mobileqq/msf/core/auth/l.java:247` `e.SetUinDeviceToken(true);`
///   紧贴着 `:248` 的 `e.GetStWithPasswd(...)`（密码登录）
/// * `com/tencent/mobileqq/msf/core/auth/d.java:120` 同调用（换票 / `checkToken`）
/// * `oicq/wlogin_sdk/request/WtloginHelper.java:252` `t.ab = z`
/// * `oicq/wlogin_sdk/request/WtloginHelper.java:1416-1417`
///   `i6 = this.mMiscBitmap; if (t.ab) i6 |= 33554432;`
/// * `33554432` = `SigType.WLOGIN_DA2`（`WtloginHelper.java:85`）
/// * 释放点只在 `com/tencent/mobileqq/msf/core/auth/n.java:192`：
///   登录成功且 `_device_token` 非空才 `SetUinDeviceToken(false)`
///
/// ⇒ **登录请求发出去时这一位一定在**，实发 `150470524 | 33554432 = 184024956`
/// （`0x0AF7FF7C`）。本类保留构造器初值（那是可核验的客观常量），
/// 由 [uinDeviceToken] 开关在 TLV `0x116` 组装时叠加，公式与官方逐位一致。
class Qq8ApkInfo {
  final String id;
  final String ver;
  final String sdkver;

  /// 客户端标识名，参与 `ksid` 派生（SSO 包头用，TLV 不用）。
  final String name;

  final int appid;
  final int subid;

  /// `WtloginHelper` 构造器赋的 `mMiscBitmap` 初值（官方 = `150470524`）。
  ///
  /// **不要直接当线上实发值用**——见 [uinDeviceToken]，线上还要或上
  /// `WLOGIN_DA2`（`33554432`）。
  final int miscBitmap;

  /// `SetUinDeviceToken(true)` 是否已生效（默认 `true`，与 MSF 登录入口一致）。
  ///
  /// 生效时 TLV `0x116` 的 bitmap 字段 = `miscBitmap | 33554432`，
  /// 与官方 `WtloginHelper.java:1416-1417` 的 `i6 |= 33554432` 逐位相同。
  ///
  /// 唯一该关掉的场景是：**登录已成功、已拿到 `_device_token`**——官方在
  /// `com/tencent/mobileqq/msf/core/auth/n.java:192` 才把它复位为 `false`，
  /// 之后走的是换票而不是密码登录。
  final bool uinDeviceToken;

  /// `WLOGIN_DA2 = 33554432`（`WtloginHelper.SigType.WLOGIN_DA2`，`:85`）。
  static const int wloginDa2Bit = 33554432;

  /// TLV `0x116` 实际写入的 bitmap。
  int get effectiveMiscBitmap =>
      uinDeviceToken ? (miscBitmap | wloginDa2Bit) : miscBitmap;

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
    this.uinDeviceToken = true,
    this.name = '',
    this.subSigMap = 66560,
    this.ssoVer = 7,
    this.loginTlvOrder = qq8OfficialLoginTlvOrder,
    this.tlv544DegradedBody = const <int>[0, 0, 0, 0],
    this.tlv553DegradedBody,
    this.qimeiMode = Qq8QimeiMode.md5OfSource,
  });

  /// 复制一份，只改 [uinDeviceToken]。
  Qq8ApkInfo withDeviceToken(bool on) => Qq8ApkInfo(
        id: id,
        ver: ver,
        sdkver: sdkver,
        appid: appid,
        subid: subid,
        miscBitmap: miscBitmap,
        mainSigMap: mainSigMap,
        buildtime: buildtime,
        sign: sign,
        name: name,
        subSigMap: subSigMap,
        ssoVer: ssoVer,
        loginTlvOrder: loginTlvOrder,
        tlv544DegradedBody: tlv544DegradedBody,
        tlv553DegradedBody: tlv553DegradedBody,
        qimeiMode: qimeiMode,
        uinDeviceToken: on,
      );
}

/// TLV `0x544`（设备码）发哪种形态。
enum Qq8T544Mode {
  /// 官方降级体：安全 SDK 加载失败时官方自己发的字节串
  /// （8.2.11 = 4 个零字节，出处 `ByteData.getCode` 的 `status` 数组）。
  officialDegraded,

  /// oicq 2.3.1 的纯算法真签名，oicq salt 布局（`lib/core/tlv.ts` 的 0x544）。
  /// 签名 = `qq8T544Sign(curr, salt)`，39 字节，黄金向量见 `vectors/t544.json`。
  oicq,

  /// 同一个纯算法签名，但 salt 用官方 `tlv_t544.java` 的 `bArr3` 布局。
  /// 与 [oicq] 只差 salt 排列——两种布局哪个被服务端接受，只有真机能裁决。
  officialSalt,
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
  /// 所以这里只做承载位、不猜算法：`t547` 为空时 `0x547` 以**空 body** 照发
  /// （官方 `get_tlv_547(null)` 恒在语义，见 [qq8SliderTlvOrderFor]）。
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

  /// TLV `0x544` 的形态（默认官方降级，不改变既有行为）。
  ///
  /// * [Qq8T544Mode.officialDegraded]：官方「安全 SDK 不可用」降级 body
  ///   （`apk.tlv544DegradedBody`，8.2.11 = 4 个零字节）。
  /// * [Qq8T544Mode.oicq]：oicq 2.3.1 的**纯算法真签名**——salt 布局
  ///   `u32(0)‖tlv(guid)‖tlv(sdkver)‖u32(sub)‖u32(0)`，喂 `qq8T544Sign` 发 39 字节。
  /// * [Qq8T544Mode.officialSalt]：官方 `tlv_t544.java` 的 `bArr3` 布局
  ///   （`u32 uin‖u16 len(t.A)‖t.A‖u16 len(sdk)‖sdk‖u32 subcmd`）喂同一个
  ///   `qq8T544Sign`——两种 salt 布局哪个被服务端接受只有真机能裁决。
  ///
  /// 子命令号取 [t544SubCmd]（登录 = 9），curr 取 [t544Curr]（不设用挂钟）。
  final Qq8T544Mode t544Mode;

  /// TLV `0x544` 签名里的子命令号（密码登录 = 9，滑块 = 2，短信 = 7/8）。
  final int? t544SubCmd;

  /// TLV `0x544` 签名的 curr（毫秒时间戳；`sign()` 内部只取 `% 1000000`）。
  final int? t544Curr;

  /// TLV `0x128` 的 guid 来源旗：true = 本次为「现算 guid」（首登语义，官方 guid src 17，
  /// U=1 / Z=0x11000000）；false = 复用设备 guid 文件（U=0 / Z=0x01000000）。
  /// 出处：t.java:230-283（t.d() 设 X/V）+ 官方日志 wtlogin_20260919.txt:20 `guid src 17`。
  final bool guidNew;

  /// 当前时间（毫秒）。
  final int Function() nowMillis;

  /// TLV `0x525` 内嵌 `0x536` 的 body（官方 `ProtocolDet.getLoginExtraData`）。
  ///
  /// 由 [Qq8ProtocolDet.encode] 产出；为空时 `0x525` 退回官方空形态 `01 00`。
  /// 见 `qq8_protocol_det.dart` 顶部关于「为何必须实现」的说明。
  final Uint8List? protocolDet;

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
    this.t544Mode = Qq8T544Mode.officialDegraded,
    this.t544SubCmd,
    this.t544Curr,
    this.protocolDet,
    this.guidNew = true,
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

/// oicq 布局的 0x544 salt（`sign()` 的输入）。
///
/// 出处 oicq 2.3.1 `lib/core/tlv.ts` 的 `0x544` packer：
/// `v == 2`（密码登录）时 `u32(0) ‖ writeTlv(guid) ‖ writeTlv(sdkver) ‖
/// u32(sub) ‖ u32(0)`，其余形态没有最后的 `u32(0)`。`writeTlv` = u16 长度 +
/// 内容，与 TLV 头同款（`len` 只计内容）。
Uint8List _t544SaltOicq(
  Qq8TlvContext ctx, {
  required int t544SubCmd,
  bool form2 = true,
}) {
  final w = ByteWriter();
  w.u32(0);
  _writeU16Prefixed(w, ctx.device.guid);
  _writeU16Prefixed(w, Uint8List.fromList(utf8.encode(ctx.apk.sdkver)));
  w.u32(t544SubCmd);
  if (form2) {
    w.u32(0);
  }
  return w.build();
}

/// 官方布局的 0x544 salt（`tlv_t544.java` 交给 `ByteData.getCode` 的 `bArr3`）。
///
/// 布局 `u32 uin ‖ u16 len(t.A) ‖ t.A ‖ u16 len(sdk) ‖ sdk ‖ u32 subcmd`。
/// `t.A` 是官方在 `T.SingleTon` 里维护的可选附加块——**首登时为空**（长度 0），
/// 所以这里留空；若日后真机抓到非空样本，再加 ctx 字段承载。
Uint8List _t544SaltOfficial(Qq8TlvContext ctx, {required int t544SubCmd}) {
  final w = ByteWriter();
  w.u32(ctx.uin);
  _writeU16Prefixed(w, Uint8List(0)); // t.A：首登为空
  _writeU16Prefixed(w, Uint8List.fromList(utf8.encode(ctx.apk.sdkver)));
  w.u32(t544SubCmd);
  return w.build();
}

/// u16 长度前缀 + 内容（TLV 头同款；oicq `writeTlv` / 官方 `make_byte`）。
void _writeU16Prefixed(ByteWriter w, List<int> body) {
  w.u16(body.length);
  w.raw(Uint8List.fromList(body));
}

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

      // 传统图片验证码提交（官方 `tlv_t2.get_tlv_2(byte[] bArr, byte[] bArr2)`）。
      //
      // 出处：`jadx-main/sources/oicq/wlogin_sdk/tlv_type/tlv_t2.java`（8.2.11）。
      // `_cmd = 2`、`_sigVer = 0`；body 布局逐字节为
      //
      //     u16 _sigVer(0) ‖ u16 len(bArr) ‖ bArr ‖ u16 len(bArr2) ‖ bArr2
      //
      // 调用点 `request/n.java` 里 `bArr`=ticket、`bArr2`=`async_context._t105.get_sign()`
      // （图片签名，无 0x105 挑战时为空数组 → 尾段退化成 `0000`）。
      //
      // 与 `case 0x193` 的关系：官方 `request/n.java` 用 `n.K` 在两者间二选一——
      // `K=true`（`CheckWebsigAndGetSt` / `submitPuzzleVerifyCodeTicket`）→ 0x193；
      // `K=false`（`CheckPictureAndGetSt`）→ 本 case。⚠️ 两个包装器**都**会打印
      // 同一句 `user:<uin> CheckPictureAndGetSt Seq:...` 日志（私有主流程里硬编码的
      // 字符串），所以日志文本**不能**用来判断官方实际走了哪条。
      case 0x02:
        w.u16(0); // _sigVer
        _writeU16Prefixed(w, _bytesArg(args, 0)); // ticket
        _writeU16Prefixed(w, _bytesArg(args, 1)); // t105 图片签名（通常为空）

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
        // TEA 密钥种子 = 口令MD5(16) ‖ u64(msalt 非 0 时用 msalt，否则用 uin)(8)
        //
        // ⚠️ 2026-10-16 修正：此前误把密钥种子写成 guid(16)‖u64(...)，导致
        // 服务端永远解不开 0x106，真机登录全部回 type=1「账号或密码错误」。
        //
        // 官方调用链（反编译逐参核对）：
        //   WtloginHelper.java:1512 `async_contextVarB._tmp_pwd = MD5.toMD5Byte(str2)`
        //   → 1539 `kVar2.a(..., async_contextVarB._tmp_pwd, ...)`（第 8 参）
        //   → k.java:48 的 26 参 a() 形参 bArr3
        //   → k.java:110 case 262 `get_tlv_106(..., bArr3, _msalt, ...)`
        //   → tlv_t106.java `bArr9[0..16]=bArr3; u64@16 = (j4==0 ? j3 : j4)`
        //     （j4=_msalt，j3=uin）；`key = MD5(bArr9)`。
        //   bArr3 同时被拷进明文 body（u8 save-password 之后），guid（t.A）
        //   只进 body 的 16 字节槽位、**不参与密钥**。
        //
        // oicq（lib/core/tlv.ts:107）的公式 `MD5(md5pass ‖ 0x00000000 ‖ u32be(uin))`
        // 在 msalt=0 时与官方逐字节等价 —— oicq 一直是对的。
        final seed = Uint8List(24);
        final pwdLen = ctx.passwordMd5.length < 16 ? ctx.passwordMd5.length : 16;
        seed.setRange(0, pwdLen, ctx.passwordMd5);
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
        // 内容按 ssoVer 分两档（同文件）：ssoVer ≥ 20 发 6 字节 `4A 04 60 01 78 01`，
        // 其余发 4 字节 `4A 02 60 01`。
        //
        // 只在**密码路径**追加（[qq8PasswordTlvOrderFor] 对 ssoVer>12）：官方
        // 三版本的**滑块提交都不带 0x542**——8.9.50 的 `get_tlv_542` 只出现在
        // 子命令 8（下发短信）流程（`WtloginHelper:8501`），此前跟随维护版把它
        // 带进滑块提交，真机对应 type=1（2026-09-15 官方对照后修正）。
        // 8.2.11 的官方顺序表里也没有它，因此它不进官方反编译顺序表。
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
        // `WtloginHelper.java:1416-1417`：`i6 = mMiscBitmap; if (t.ab) i6 |= 33554432;`
        // MSF 密码登录入口（`msf/core/auth/l.java:247`）恒开 `t.ab`，故实发
        // `0x0AF7FF7C`（184024956）而不是构造器初值 `0x08F7FF7C`（150470524）。
        w.u32(ctx.apk.effectiveMiscBitmap);
        w.u32(ctx.apk.subSigMap); // 0x10400，三代相同
        w.u8(1); // app id list 长度
        w.u32(1600000226); // app id list[0]

      case 0x544:
        // 三种形态，由 `ctx.t544Mode` 选择（见 Qq8T544Mode 的注释）：
        //
        //   official —— 官方降级体 `tlv544DegradedBody`（8.2.11 = 4 个零字节，
        //               出处 ByteData.getCode 的 `status`；SDK 正常时它发的才是
        //               真签名，但那个值来自 libpoxy native + 联网，拿不到）。
        //
        //   oicq     —— oicq 2.3.1 的纯算法签名（`lib/core/tlv.ts:334` 的
        //               `0x544` packer）：salt 布局 `u32(0)‖tlv(guid)‖tlv(sdkver)‖
        //               u32(sub)‖u32(0)`（v==2），再整体喂 `sign(curr, salt)`，
        //               发 39 字节签名。**2026-10-16 之前我们只发了 salt 本身**
        //               （那正是 sign() 的输入，不是输出）——本次补上真正的
        //               `qq8T544Sign` 调用，黄金向量 9/9 逐字节复现
        //               （`tool/qq8_t544_selftest.dart`）。
        //
        //   officialSalt —— 官方 `tlv_t544.java` 喂给 `ByteData.getCode` 的
        //               `bArr3` 布局（`u32 uin‖u16 len(t.A)‖t.A‖u16 len(sdk)‖
        //               sdk‖u32 subcmd`）也喂同一个 `sign()`——oicq 与官方的
        //               salt 布局不同，哪个被服务端接受只有真机能裁决，所以
        //               两种布局都留了向量（`vectors/t544.json` 的
        //               `official-*` 条目）。
        final t544Mode = ctx.t544Mode;
        switch (t544Mode) {
          case Qq8T544Mode.officialDegraded:
            w.raw(Uint8List.fromList(ctx.apk.tlv544DegradedBody));
          case Qq8T544Mode.oicq:
            final salt =
                _t544SaltOicq(ctx, t544SubCmd: ctx.t544SubCmd ?? 0);
            w.raw(qq8T544Sign(ctx.t544Curr ?? ctx.nowMillis(), salt));
          case Qq8T544Mode.officialSalt:
            final salt = _t544SaltOfficial(ctx, t544SubCmd: ctx.t544SubCmd ?? 0);
            w.raw(qq8T544Sign(ctx.t544Curr ?? ctx.nowMillis(), salt));
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
        // 防刷计算题（0x546）的应答——**官方语义是"恒在"**（2026-09-15 官方对照
        // 修正，构建点见 [qq8SliderTlvOrderFor] 的表格）：
        //
        // ```java
        // // 8.2.11 tlv_t547.java —— get_tlv_547(null) 照样产出 TLV：
        // byte[] bArr2 = new byte[bArr.length];   // 空 → 空 body
        // fill_head(this._cmd); fill_body(bArr2, length); set_length();
        // ```
        //
        // 即：有应答（响应 0x546 → pow.b.b 同步解 → t.am/u.k0 缓存）发应答；
        // 没应答发**空 body 的 4 字节 TLV**（u16 0x547 + u16 0），照发不误。
        // 早先"空就抛错不发"是跟随 oicq 的 `if (sig.t547.length)` 推断——官方不是。
        final t547 = ctx.t547;
        if (t547 != null && t547.isNotEmpty) {
          w.raw(t547);
        }

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
        // 官方 get_tlv_128(t.U, t.V, t.W, t.Z, t.I, t.A, t.P)（k.java case 324）：
        //   u16(0) ‖ u8 U(guid new) ‖ u8 V(guid available) ‖ u8 W(guid changed) ‖ u32 Z(guid flag) ‖ model ‖ guid ‖ brand
        // Z = (X<<24)|(Y<<8)，X = guid 来源：文件命中=1 / 现算=17 / 占位=20（t.java t.d()）。
        // 官方 09-19 真机日志 wtlogin_20260919.txt:20 `guid src 17`（首登现算，无 wlogin_device.dat）
        // ⇒ U=1,V=1,W=0,Z=0x11000000；旧 guid 文件复用才是 U=0,V=1,W=0,Z=0x01000000。
        // 默认按「现算」（首登语义）发，与 identity 注入（无设备 guid 文件）对齐；
        // ctx.guidNew=false 可切回文件命中形态。出处：t.java:230-283 + 官方日志 L20。
        w.u16(0);
        w.u8(ctx.guidNew ? 1 : 0); // U: 现算=1 / 文件复用=0
        w.u8(1); // V: guid available
        w.u8(0); // W: guid changed（首登无旧值可比）
        w.u32(ctx.guidNew ? 0x11000000 : 0x01000000); // Z = (X<<24)：X=17 现算 / X=1 文件
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
        // 官方 `tlv_t147.get_tlv_147(long appid, byte[] apkVersion, byte[] pkgSig)`
        // （8.2.11 `tlv_type/tlv_t147.java:10-32`）：
        //   u32(appid) ‖ u16len ‖ apkVersion ‖ u16len ‖ pkgSig，**两段都 limit_len(..., 32)**。
        //
        // ⚠️ 修正记录（2026-09-15 第二轮深逆）：此处曾照抄 oicq 的 `ver.slice(0, 5)`。
        // oicq 自己的 `apk.ver` 是 5 字符（"8.4.1"）⇒ slice 恒不生效；而我们的档案
        // 是 "8.2.11"/"8.9.50"/"9.3.60"（均 6 字符）⇒ 会真的截成 "8.2.1"，
        // 与官方报文（整串 versionName，上限 32）差一个字节。
        // 第一参语义也已核实是 **appid**：官方调用链 GetStWithPasswd(account, appid,
        // mainSigMap, subDstAppid, …) → `k.a(appid, subDstAppid, uin, …)`
        // → `get_tlv_147(appid, t.G=APK versionName, t.H=pkgSig)`
        // （`request/WtloginHelper.java:1536` → `request/k.java:166`；t.G 见 `request/t.java:315`）。
        w.u32(ctx.apk.appid);
        _tlv(w, _cut(ctx.apk.ver, 32));
        _tlv(w, _cutBytes(ctx.apk.sign, 32));

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
          // 域名清单与顺序 = 官方 App 层 com/tencent/mobileqq/msf/core/auth/l.java:30-46
          // （auth/l.b() 填充，15 项含 qun.qq.com 重复——保持逐项一致）。
          'game.qq.com', 'mail.qq.com', 'qzone.qq.com', 'qun.qq.com',
          'openmobile.qq.com', 'tenpay.com', 'connect.qq.com', 'qun.qq.com',
          'qqweb.qq.com', 'office.qq.com', 'ti.qq.com', 'mma.qq.com',
          'docs.qq.com', 'vip.qq.com', 'gamecenter.qq.com',
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
        // 官方 `k.java:331-347` case 1317：
        //   内层 = `tlv_t(1334)`，body = `ProtocolDet.getLoginExtraData(ctx)`
        //   外层 = `u16(1)`（TLV 计数）‖ `0x536` TLV
        // `getLoginExtraData` 取不到数据时返回 `packExtraData(null)` = `01 00`，
        // **不是不打包**——所以外层永远发；内层长度才是变量。
        //
        // 2026-10-21 修正：此前把内层硬编码成 `01 00`（等价于「零条历史出口」）。
        // 对照官方真机日志，密码登录**成功**那次（`qq8211/wtlogin_20260930.txt:375`）
        // 内层是 65 字节 = `01 03` + 3 条 21 字节记录。恒发 2 字节等于每次
        // 都告诉服务端「我是全新环境」，与老账号老地方登录的事实相悖。
        // 现在由 [Qq8TlvContext.protocolDet] 承载；为空时退回官方的 `01 00`。
        final det525 = ctx.protocolDet;
        w.u16(1); // tlv 计数
        w.u16(0x536);
        _tlv(
          w,
          det525 == null || det525.isEmpty ? Qq8ProtocolDet.emptyBody : det525,
        );

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
        // 官方 `util.get_android_dev_info(context)`（jadx-main util.java:957-999）
        // 组装 `device_report.DeviceReport` 的 9 个 bytes 字段，顺序由
        // `oicq/wlogin_sdk/pb/device_report.java:9` 的 `__fieldMap__` 定死：
        //   1 bytes_bootloader   2 bytes_version     3 bytes_codename
        //   4 bytes_incremental  5 bytes_fingerprint 6 bytes_boot_id
        //   7 bytes_android_id   8 bytes_baseband    9 **bytes_inner_ver**
        // ⚠️ 字段 9 是 `util.getInnerVersion()`（DISPLAY 含 INCREMENTAL 则取
        //    DISPLAY，否则取 INCREMENTAL），**不是** incremental 的重复。
        //    此处曾误写成 `d.version.incremental`，使字段 4 与 9 恒等。
        w.raw(protoEncode(<int, Object?>{
          1: d.bootloader,
          2: d.procVersion,
          3: d.version.codename,
          4: d.version.incremental,
          5: d.fingerprint,
          6: d.bootId,
          7: d.androidId,
          8: d.baseband,
          9: d.version.innerVersion,
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
