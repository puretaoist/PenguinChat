/// L2 协议内核：多版本客户端档案（QQ 8.2.11 / 8.9.50 / 9.3.60 / TIM 4.1.0）
///
/// ## 为什么需要这张表
///
/// 四个客户端的登录组包**绝大部分逐行相同**，差异集中在几个字段上。
/// 把差异做成数据而不是分支，就能用同一份 TLV 代码打不同版本，
/// 真机验证时换个 profile 即可。
///
/// ## 全部数据来自反编译，逐项标注出处
///
/// | 字段 | 出处 |
/// |---|---|
/// | `versionName` / `versionCode` | `AndroidManifest.xml`（AXML 解析） |
/// | `appSettingParams` | `AndroidManifest.xml` 的 `AppSetting_params` meta-data |
/// | `beaconAppKey` | `AndroidManifest.xml` 的 `APPKEY_DENGTA` meta-data |
/// | `qua` | dex 字符串池 `V1_AND_SQ_*` |
/// | `sdkVersion` / `buildTime` | `oicq.wlogin_sdk.tools.util` 的 `SDK_VERSION` / `BUILD_TIME` 常量 |
/// | `apkName` | **不在 APK 里**——按 oicq 约定从 `AppSetting` 构建号串推导（见下） |
/// | `subAppId` | `AppSetting_params` 的 `#` 分隔第 1 段 |
/// | `miscBitmap` / `mainSigMap` / `subSigMap` | `WtloginHelper` 构造器 |
/// | `ssoVer` | `tlv_t100._sso_ver` == `tlv_t106._SSoVer` |
/// | `loginTlvOrder` | `request/j.java`（或 `k`/`l`）里的 `int[]`，DEX payload 头读长度 |
///
/// ## ⚠️ 一条重要更正
///
/// 早先我用"字符串池相邻关系"提取 `APPKEY_DENGTA`，得出 **8.9.50/TIM 的 appkey
/// 与 8.2.11 不同** 的结论——**那是错的**。正确解析 AXML 属性结构后确认：
/// QQ 8.2.11 / 8.9.50 / TIM 4.1.0 的 `APPKEY_DENGTA` **都是 `0S200MNJT807V3GE`**。
///
/// 也就是说 **"appkey 对不上" 不构成换版本的理由**（四者本来就相同）。
///
/// 但**不能反过来推出"QIMEI 通用"**：`APPKEY_DENGTA` 只属于旧 Beacon，
/// 8.9.50 起 QIMEI 换新 SDK、appkey 每 app 一套——见 [qq8ProfileQQ8950] 的更正。
///
/// ## ⚠️ 第二条更正：`apkName` 怎么取
///
/// `apkName` 只出现在 `ksid = "|" + IMEI + "|" + apkName` 里。它**不是 APK 里的
/// 常量**：对四个 APK 逐 entry 扫描（含 .so）0 命中——官方运行时由服务端在
/// 登录响应 TLV 0x108 下发、客户端缓存回填。取值按参考实现 oicq 的样本约定
/// `'A' + <versionName>.<buildNum>`，buildNum 见各版本 `AppSetting` 静态块。
///
/// oicq 的 9 个历史样本里 8 个无后缀（`A5.8.9.3460`、`A8.9.35.10440`…）；
/// 唯一例外 `A8.4.1.2703aac4`（2020 年）来源不可考——早先"修订号末 4 位"
/// 的推断就是被它误导，现已按多数规则修正。
///
/// 本文件是纯 Dart，不依赖 Flutter。
library;

import 'dart:typed_data';

import 'qq8_tlv.dart';

/// 一个客户端版本的完整档案。
class Qq8ClientProfile {
  /// 人类可读标签。
  final String label;

  /// `AndroidManifest` 的 `versionName`。
  final String versionName;

  /// `AndroidManifest` 的 `versionCode`。
  final int versionCode;

  /// `AndroidManifest` 的 `AppSetting_params` 原串（`#` 分隔）。
  ///
  /// 可空：参数若不是来自本地 APK（如 [qq8ProfileQQ8950Yyb] 取自维护版
  /// oicq 档案），没有原串就不许编造——此时 subid 以 [Qq8ApkInfo.subid]
  /// 为准、渠道见 [channelOverride]。
  final String? appSettingParams;

  /// 渠道名覆盖项；[appSettingParams] 为空时使用。
  final String? channelOverride;

  /// 灯塔 appkey（`AndroidManifest` 的 `APPKEY_DENGTA`）。
  ///
  /// QIMEI 按 appkey 签发。四个客户端里 8.2.11 / 8.9.50 / TIM 相同。
  final String beaconAppKey;

  /// QUA 串（`V1_AND_SQ_<版本>_<versionCode>_<渠道缩写>_D`）。
  final String qua;

  /// 组装 TLV 所需的 APK 参数。
  final Qq8ApkInfo apk;

  /// **尚未从 APK 中取到、需要真机验证的字段**。
  ///
  /// 留空表示该项已核实。有内容时，实现方必须知道这些值仍是猜的。
  final List<String> unverified;

  const Qq8ClientProfile({
    required this.label,
    required this.versionName,
    required this.versionCode,
    this.appSettingParams,
    this.channelOverride,
    required this.beaconAppKey,
    required this.qua,
    required this.apk,
    this.unverified = const <String>[],
  });

  /// 子应用 ID：优先取 `AppSetting_params` 首段；没有原串时以
  /// [Qq8ApkInfo.subid] 为准（两者在有原串的档案里本就一致）。
  int get subAppId {
    final p = appSettingParams;
    if (p != null && p.isNotEmpty) return int.parse(p.split('#').first);
    return apk.subid;
  }

  /// 渠道名：`AppSetting_params` 第 4 段；无原串时用 [channelOverride]。
  String get channel {
    final p = appSettingParams;
    if (p != null && p.isNotEmpty) {
      final parts = p.split('#');
      if (parts.length > 3) return parts[3];
    }
    return channelOverride ?? '';
  }

  String describe() =>
      '$label  code=$versionCode  ssoVer=${apk.ssoVer}  '
      'subid=$subAppId  channel=$channel  '
      'tlv=${apk.loginTlvOrder.length}项'
      '${unverified.isEmpty ? '' : '  ⚠未验证: ${unverified.join('/')}'}';
}

/// QQ 8.2.11（Play 版）—— 无 fekit，链路最简单。
///
/// * `tlv_t106._SSoVer` = **7**，`tlv_t100._sso_ver` = **7**
/// * 登录 TLV 表 37 项
/// * `0x544` 降级 = `00 00 00 00`（`ByteData.getCode` 返回 `status` 数组）
/// * 无 `0x553`
/// * 无 `libfekit.so`
final Qq8ClientProfile qq8ProfileQQ8211 = Qq8ClientProfile(
  label: 'QQ 8.2.11 (Play)',
  versionName: '8.2.11',
  versionCode: 1380,
  appSettingParams:
      '537064117#DF164B0A8344DA4E#2001#GoogleMarket#fffffffffffffffffffffffff',
  beaconAppKey: '0S200MNJT807V3GE',
  qua: 'V1_AND_SQ_8.2.11_1380_GM_D',
  apk: Qq8ApkInfo(
    id: 'com.tencent.mobileqq',
    ver: '8.2.11',
    sdkver: '6.0.0.2423',
    name: 'A8.2.11.4530', // AppSetting fullVersion 前缀 "8.2.11.4530"
    appid: 16,
    subid: 537064117,
    miscBitmap: 150470524,
    mainSigMap: 16724722,
    subSigMap: 66560,
    buildtime: 1582559746,
    sign: Uint8List.fromList(const <int>[
      0xa6, 0xb7, 0x45, 0xbf, 0x24, 0xa2, 0xc2, 0x77,
      0x52, 0x77, 0x16, 0xf6, 0xf3, 0x6e, 0xb6, 0x8d,
    ]),
    ssoVer: 7,
    loginTlvOrder: qq8OfficialLoginTlvOrder,
    tlv544DegradedBody: const <int>[0, 0, 0, 0],
    tlv553DegradedBody: null,
  ),
);

/// QQ 8.9.50（应用宝渠道）—— **推荐目标**。
///
/// * `tlv_t106._SSoVer` = **19**，`tlv_t100._sso_ver` = **19**
/// * 登录 TLV 表 **37 项，与 8.2.11 逐项逐序相同** → 组包代码不用改
/// * `0x544` 降级 = **空 body**（`liteSign` 初值 `new byte[0]`）
/// * 无 `0x553`（`0x553` 是 9.3.60/TIM 才加的）
/// * 代价：带 `libfekit.so`（9.7MB），但 `0x544` 对它是优雅降级的
///
/// `sign` 已核实：`META-INF/ANDROIDR.RSA` 里那张 599 字节证书的 DER MD5
/// = `a6b745bf…`，与 8.2.11 / 9.3.60 **完全相同**（腾讯同一张证书）。
///
/// ## ⚠️ 关于 QIMEI 的一处更正
///
/// 早先用"manifest 的 `APPKEY_DENGTA` 相同"推断"TIM 的 QIMEI 可直接用"，**不成立**。
/// 实机取证（见 `QQ-官方三版本登录流程对照.md` 5.8(13)）后确认：
///
/// * `APPKEY_DENGTA`（`0S200MNJT807V3GE`）只属于**旧 Beacon**；
/// * 8.9.50 起 QIMEI 走**新独立 SDK** `com.tencent.qimei`，
///   它的 appkey 是**每个 app 一套**的 `0AND0*` 形态 ——
///   TIM 的是 `0AND063BSR94DSGA`，而 **QQ 8.9.50 的 dex 里根本没有这个 key**。
///
/// 所以 **TIM 的 QIMEI 不能用于 QQ 客户端**。本档案的 `0x545` 走"拿不到就发空"
/// 的官方降级路径。
final Qq8ClientProfile qq8ProfileQQ8950 = Qq8ClientProfile(
  label: 'QQ 8.9.50',
  versionName: '8.9.50',
  versionCode: 3898,
  appSettingParams:
      '537155557#4C6F23140CE449B9#2008#ALYY#fffffffffffffffffffffffffffffffff',
  beaconAppKey: '0S200MNJT807V3GE',
  qua: 'V1_AND_SQ_8.9.50_3898_YYB_D',
  apk: Qq8ApkInfo(
    id: 'com.tencent.mobileqq',
    ver: '8.9.50',
    sdkver: '6.0.0.2535',
    // AppSetting m = "8.9.50.10650"（buildNum；不是 versionCode 3898，
    // 也不是 QUA 里的 100084）。
    name: 'A8.9.50.10650',
    appid: 16,
    subid: 537155557,
    miscBitmap: 150470524,
    mainSigMap: 16724722,
    subSigMap: 66560,
    buildtime: 1676531414,
    sign: Uint8List.fromList(const <int>[
      0xa6, 0xb7, 0x45, 0xbf, 0x24, 0xa2, 0xc2, 0x77,
      0x52, 0x77, 0x16, 0xf6, 0xf3, 0x6e, 0xb6, 0x8d,
    ]),
    ssoVer: 19,
    loginTlvOrder: qq8OfficialLoginTlvOrder,
    tlv544DegradedBody: const <int>[],
    tlv553DegradedBody: null,
    qimeiMode: Qq8QimeiMode.rawSource,
  ),
);

/// QQ 8.9.50 **应用宝（YYB）渠道** —— 2026-09 真机对齐用档案。
///
/// ## 为什么在 ALYY 档案之外再加一份
///
/// 上方 [qq8ProfileQQ8950] 的参数全部反编译自本机的 ALYY 渠道包
/// （subid=537155557），但 `qua` 沿用了 oicq 历史样本的 YYB 串——
/// **subid 与 qua 渠道不一致**。真机结果：密码登录能拿到 type=2，
/// 滑块提交却回 type=45「下载最新版 QQ」（客户端身份/版本门）。
///
/// 对照 **2026-09-04 仍在发布** 的维护版 oicq（`oicq-icalingua-plus-plus`
/// v1.26.25，Icalingua++ 的实际内核）`lib/device.js` 的默认 Android 档案，
/// 它是一整套**自洽的 YYB 身份**，8.9.50/ssover=19 与本档案同代：
///
/// | 字段 | ALYY 包反编译 | YYB（本档案，维护版默认值） |
/// |---|---|---|
/// | subid | 537155557 | **537155551** |
/// | qua | `…_3898_YYB_D`（串渠道） | `…_3898_YYB_D`（一致） |
/// | sigmap（TLV 0x100） | 16724722 | **34869472** |
/// | sdkver / buildtime / code / sign | 6.0.0.2535 / 1676531414 / 3898 / a6b7…（全部相同） |
///
/// 维护版默认 `0x544` 同样发**空 body**（`force_algo_T544` 关闭），
/// 证明 type=45 的差异不在签名，而在身份与登录清单（另补 `0x542` /
/// `0x548`，见 `qq8PasswordTlvOrderFor` / `qq8SliderTlvOrderFor`）。
///
/// `appSettingParams` 留空：本机没有 YYB 渠道 APK，hash 段不许编造；
/// 该串在组包中只消费 subid（已显式给出）与渠道（[channelOverride]）。
final Qq8ClientProfile qq8ProfileQQ8950Yyb = Qq8ClientProfile(
  label: 'QQ 8.9.50 (YYB)',
  versionName: '8.9.50',
  versionCode: 3898,
  channelOverride: 'YYB',
  beaconAppKey: '0S200MNJT807V3GE',
  qua: 'V1_AND_SQ_8.9.50_3898_YYB_D',
  apk: Qq8ApkInfo(
    id: 'com.tencent.mobileqq',
    ver: '8.9.50',
    sdkver: '6.0.0.2535',
    name: 'A8.9.50.10650',
    appid: 16,
    // 出处：维护版 oicq v1.26.25 lib/device.js `DEFAULT_ANDROID_APK_INFO.subid`。
    subid: 537155551,
    miscBitmap: 150470524,
    // 出处同上 `sigmap`；写入 TLV 0x100（ALYY 档案的 16724722 来自
    // WtloginHelper 构造器，两个值对应不同渠道构建）。
    mainSigMap: 34869472,
    subSigMap: 66560,
    buildtime: 1676531414,
    sign: Uint8List.fromList(const <int>[
      0xa6, 0xb7, 0x45, 0xbf, 0x24, 0xa2, 0xc2, 0x77,
      0x52, 0x77, 0x16, 0xf6, 0xf3, 0x6e, 0xb6, 0x8d,
    ]),
    ssoVer: 19,
    loginTlvOrder: qq8OfficialLoginTlvOrder,
    tlv544DegradedBody: const <int>[],
    tlv553DegradedBody: null,
    qimeiMode: Qq8QimeiMode.rawSource,
  ),
);

/// QQ 9.3.60（应用宝渠道，versionCode 16070）—— 比 8.9.50 多一个 fekit 块。
///
/// * `_SSoVer` = **22**
/// * 登录 TLV 表 **38 项 = 8.2.11 的 37 项 + `0x553`**
/// * `0x553 = QSec.getFeKitAttach(ctx, uin, "0x810", "0x9")`，降级 = `00`
final Qq8ClientProfile qq8ProfileQQ9360 = Qq8ClientProfile(
  label: 'QQ 9.3.60',
  versionName: '9.3.60',
  versionCode: 16070,
  appSettingParams:
      '537389183#1BD2FCF3B7A70889#2017#GuanWang#fffffffffffffffffffffffffffff',
  beaconAppKey: '', // manifest 里没有，运行时下发
  qua: 'V1_AND_SQ_9.3.60_16070_YYB_D',
  apk: Qq8ApkInfo(
    id: 'com.tencent.mobileqq',
    ver: '9.3.60',
    sdkver: '6.0.0.2591',
    name: 'A9.3.60.41075', // AppSetting n = "9.3.60.41075"
    appid: 16,
    subid: 537389183,
    miscBitmap: 150470524,
    mainSigMap: 16724722,
    subSigMap: 66560,
    buildtime: 1784552169, // util.BUILD_TIME（2026-07-20）
    sign: Uint8List.fromList(const <int>[
      0xa6, 0xb7, 0x45, 0xbf, 0x24, 0xa2, 0xc2, 0x77,
      0x52, 0x77, 0x16, 0xf6, 0xf3, 0x6e, 0xb6, 0x8d,
    ]),
    ssoVer: 22,
    loginTlvOrder: qq8OfficialLoginTlvOrderWith553,
    tlv544DegradedBody: const <int>[],
    tlv553DegradedBody: const <int>[0],
    qimeiMode: Qq8QimeiMode.rawSource,
  ),
);

/// TIM 4.1.0.4050 —— 与 9.3.60 同构（TLV 表 38 项、`_SSoVer` = 22）。
///
/// 注意它自带 `libmatrix-*` 反 hook 全家桶，**不适合作为 hook 宿主**；
/// 它的价值是**指纹源**：与本档案共享同一个灯塔 appkey。
final Qq8ClientProfile qq8ProfileTim410 = Qq8ClientProfile(
  label: 'TIM 4.1.0.4050',
  versionName: '4.1.0',
  versionCode: 4050,
  appSettingParams:
      '537298353#84856344DE59E952#2017#GuanWang#fffffffffffffffffffffffffffff',
  beaconAppKey: '0S200MNJT807V3GE',
  qua: 'V1_AND_SQ_9.0.95_4050_TIM_D',
  apk: Qq8ApkInfo(
    id: 'com.tencent.tim',
    ver: '4.1.0',
    sdkver: '6.0.0.2563',
    // AppSetting m = "4.1.0.4050"（versionName 段，不是 QUA 里的 9.0.95）。
    name: 'A4.1.0.4050',
    appid: 16,
    subid: 537298353,
    miscBitmap: 150470524,
    mainSigMap: 16724722,
    subSigMap: 66560,
    buildtime: 1724313621, // util.BUILD_TIME（2024-08-22）
    // ⚠️ TIM **不用** QQ 那张证书：`META-INF/TIM_QQ_C.RSA` 里是 873 字节的
    // 2048-bit 证书，DER MD5 = 775e696d09856872fdd8ab4f3f06b1e0；
    // QQ 三版本则是 599 字节的 1024-bit 证书，MD5 = a6b745bf…
    sign: Uint8List.fromList(const <int>[
      0x77, 0x5e, 0x69, 0x6d, 0x09, 0x85, 0x68, 0x72,
      0xfd, 0xd8, 0xab, 0x4f, 0x3f, 0x06, 0xb1, 0xe0,
    ]),
    ssoVer: 22,
    loginTlvOrder: qq8OfficialLoginTlvOrderWith553,
    tlv544DegradedBody: const <int>[],
    tlv553DegradedBody: const <int>[0],
    qimeiMode: Qq8QimeiMode.rawSource,
  ),
);

/// 手表平台档案（`com.tencent.qqlite` 2.0.8）——**只服务二维码登录**。
///
/// 出处：参考实现 `analysis/_ref/oicq-src/lib/core/device.ts` 的 `watch`。
/// 二维码取码（`wtlogin.trans_emp` / code2d）在信封层与 0x16 里都用它：
/// * SSO 头 subid = 537065138（不是 QQ 手 Q 的 537155557）；
/// * 取码请求里 `0x16` 的 body 用它的 appid/subid/版本/sign。
///
/// ⚠️ 与手 Q 档案的 `0x16`（js 时代那套固定值 `16/537067759/4.0.2`，
/// 见 `qq8_tlv.dart` 的 case 0x16 与本工程 48 条黄金向量）**不同**；
/// 这里按新版参考实现的手表取值，只在二维码流程里用。
final Qq8ApkInfo qq8ApkWatch = Qq8ApkInfo(
  id: 'com.tencent.qqlite',
  ver: '2.0.8',
  sdkver: '6.0.0.2365',
  name: 'A2.0.8',
  appid: 16,
  subid: 537065138,
  miscBitmap: 16252796,
  mainSigMap: 16724722,
  subSigMap: 66560,
  buildtime: 1559564731,
  sign: Uint8List.fromList(const <int>[
    0xa6, 0xb7, 0x45, 0xbf, 0x24, 0xa2, 0xc2, 0x77,
    0x52, 0x77, 0x16, 0xf6, 0xf3, 0x6e, 0xb6, 0x8d,
  ]),
  ssoVer: 5,
);

/// 全部档案，按推荐顺序排列。
///
/// 不是 `const` —— [Qq8ApkInfo.sign] 是 `Uint8List`，构造需要运行期转换。
final Map<String, Qq8ClientProfile> qq8ClientProfiles =
    <String, Qq8ClientProfile>{
  '8.2.11': qq8ProfileQQ8211,
  '8.9.50': qq8ProfileQQ8950,
  '8.9.50-yyb': qq8ProfileQQ8950Yyb,
  '9.3.60': qq8ProfileQQ9360,
  'tim4.1.0': qq8ProfileTim410,
};

/// 默认档案：**9.3.60**。
///
/// 2026-09-21 真机改的（原来是 8.9.50）。依据是服务端给的原话：
/// 滑块提交后回 `type=45` + `0x146`「禁止登录 / 登录失败，请前往QQ官网 im.qq.com
/// 下载最新版QQ后重试」——这是**版本门**，而 8.9.50 与 8.2.11 都低于门槛
/// （国内版本 < 9.1.30 一律被这条挡住，见 `docs/PITFALLS.md` C8）。
/// 手头能拿到的最高版本就是 9.3.60（ssoVer 22、登录表 38 项、常数全部来自
/// 本机 9.3.60 包 + TIM 反编译），所以默认换成它。
///
/// 与 8.9.50 的差别（组包侧已实现，不是这次改的）：
/// 1. 登录 TLV 表多一项 `0x553`（fekit 门控，降级 [Qq8ApkInfo.tlv553DegradedBody]）；
/// 2. 滑块提交清单因此是 `193/08/104/116/547/544/553`（见 `qq8SliderTlvOrderFor`）；
/// 3. `0x544` 仍是显式优雅降级（空 body）。
///
/// ⚠️ 待验证：9.1.30+ 可能开始**强校验** `0x544` 真签名（我们发的是降级占位）。
/// 若换成 9.3.60 后服务端改口要签名（而不是版本），那就回到"C8 候选 (b)：
/// native + 联网"的结论，该收手了。
///
/// 想切回别的档案：命令行用 `--profile=8.9.50`（`tool/qq8_live_smoke.dart`），
/// App 侧改这一个常量即可（档案表见 [qq8ClientProfiles]）。
final Qq8ClientProfile qq8DefaultProfile = qq8ProfileQQ9360;
