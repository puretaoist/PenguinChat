/// L2 协议内核：QQ 8.2.11（Play 版）协议参数
///
/// ## 来源
///
/// 全部参数均由反编译 `QQ-com.tencent.mobileqq-play-8.2.11.apk`
/// （构建时间 2020-12-25，arm64-v8a，versionCode 1380）实测提取，
/// 不是从其它项目抄来的估计值：
///
/// | 常量 | 值 | 出处 |
/// |---|---|---|
/// | [appVersion] | `8.2.11.4530` | `com.tencent.common.config.AppSetting` |
/// | [versionName] | `8.2.11` | `AndroidManifest.xml` |
/// | [versionCode] | `1380` | `AndroidManifest.xml` |
/// | [fullVersion] | `8.2.11.4530.2020-12-25.0153f87a.GoogleMarket` | `AppSetting` |
/// | [qua] | `V1_AND_SQ_8.2.11_1380_GM_D` | dex 字符串池 |
/// | [appSign] | `a6b745bf...` | `META-INF/ANDROIDR.RSA` 证书 DER 的 MD5 |
/// | [subAppId] | `537064117` | `AppSetting` |
/// | [miscBitmap] | `150470524` | `WtloginHelper.mMiscBitmap` |
/// | [mainSigMap] | `16724722` | `WtloginHelper.mMainSigMap` |
/// | [subSigMap] | `66560` | `WtloginHelper.mSubSigMap` |
/// | [sdkVersion] | `6.0.0.2423` | dex 字符串池 |
///
/// ## 关于 appSign
///
/// [appSign] 是 **APK 签名证书 DER 的 MD5**。已用 `takayama-lily/oicq`
/// 记录的 8.4.1 值反向验证：两者**逐字节相同**
/// （`a6b745bf24a2c277527716f6f36eb68d`），因为腾讯用同一张证书签发
/// 所有 QQ 版本。因此这个值跨版本稳定，不需要每个版本重新提取。
///
/// ## 这条路线的关键前提
///
/// 8.2.11 的登录链路**不含 native 签名依赖**：
///   - 无 `libfekit.so`（该库自 8.9.50 才出现，9.7MB 混淆）
///   - ECDH/RSA 在 `libwtecdh.so` 里，全部是 OpenSSL 原语，可用纯 Dart 重写
///   - 无需外部签名服务（qsign / T544 是后续版本才引入的）
///
/// 本文件是纯 Dart，不依赖 Flutter。
library;

/// QQ 8.2.11 Play 版的协议参数。
///
/// 全部为编译期常量——这些值在腾讯发新版之前不会变，
/// 且写死比运行期计算更接近官方客户端的行为。
abstract final class Qq8Config {
  // -- 版本标识 ---------------------------------------------------------------

  /// 短版本名，等价于 `AndroidManifest` 的 `versionName`。
  static const String versionName = '8.2.11';

  /// 完整版本号，等价于 `AppSetting` 的版本串主体。
  static const String appVersion = '8.2.11.4530';

  /// `AndroidManifest` 的 `versionCode`。
  static const int versionCode = 1380;

  /// 完整版本标识串（`AppSetting.f2558f`）。
  ///
  /// 格式：`<appVersion>.<日期>.<构建哈希>.<渠道>`。
  /// 渠道为 `GoogleMarket`，这正是"Play 版"的由来。
  static const String fullVersion =
      '8.2.11.4530.2020-12-25.0153f87a.GoogleMarket';

  /// 渠道标识。
  static const String channel = 'GoogleMarket';

  /// 构建日期。
  static const String buildDate = '2020-12-25';

  /// 构建修订号（`AppSetting` 里的 `revision`，dex 中可见 `revision=0153f87a`）。
  static const String revision = '0153f87a';

  /// 客户端标识名，参与 `ksid` 派生（`ksid = "|" + IMEI + "|" + apkName`）。
  ///
  /// 注意**这个串不是从 APK 里提取的**——dex 中没有 `A8.2.11...` 形式的常量。
  /// 它沿用参考实现 oicq 的命名约定：`A` + 完整版本号 + 修订号末 4 位
  /// （oicq 表中 8.4.1 为 `A8.4.1.2703aac4`）。
  static const String apkName = 'A8.2.11.4530f87a';

  /// QUA（QQ User Agent），由 `V1_AND_SQ_<版本>_<versionCode>_<渠道缩写>_D` 构成。
  ///
  /// `GM` = Google Market，即 Play 版。
  static const String qua = 'V1_AND_SQ_8.2.11_1380_GM_D';

  /// 包名。
  static const String packageName = 'com.tencent.mobileqq';

  // -- 登录协议参数 -----------------------------------------------------------

  /// 主应用 ID。WLogin 体系中 QQ Android 恒为 16。
  static const int appId = 16;

  /// 子应用 ID（`AppSetting` 的 `f` 字段，由 `AppSetting.a()` 返回）。
  ///
  /// 注意这是**版本相关**的：oicq 记录的 8.4.1 为 `537064989`，
  /// 8.2.11 为 `537064117`。
  static const int subAppId = 537064117;

  /// APK 签名证书 DER 的 MD5，十六进制。
  ///
  /// 跨版本稳定（腾讯用同一张证书），oicq 记录的 8.4.1 值完全相同。
  static const String appSignHex = 'a6b745bf24a2c277527716f6f36eb68d';

  /// [appSignHex] 的字节形式（16 字节）。
  static const List<int> appSignBytes = <int>[
    0xa6, 0xb7, 0x45, 0xbf, 0x24, 0xa2, 0xc2, 0x77,
    0x52, 0x77, 0x16, 0xf6, 0xf3, 0x6e, 0xb6, 0x8d,
  ];

  /// 杂项能力位（`WtloginHelper.mMiscBitmap`）。
  ///
  /// 声明客户端支持哪些特性。参考实现 oicq 中 aPad 条目同为 `150470524`。
  static const int miscBitmap = 150470524;

  /// 主签名算法位图（`WtloginHelper.mMainSigMap`）。
  ///
  /// 写入 TLV 0x106。
  static const int mainSigMap = 16724722;

  /// 子签名算法位图（`WtloginHelper.mSubSigMap`）。
  ///
  /// 紧跟在 `miscBitmap` 之后写入。参考实现 oicq 把它硬编码为
  /// `0x10400`，与这里的 `66560` 是同一个值。
  static const int subSigMap = 66560;

  /// WLogin SDK 版本号。
  static const String sdkVersion = '6.0.0.2423';

  /// 协议版本号，写入 SSO 包头的 `protocol ver` 字段。
  static const int protocolVersion = 8001;

  // -- 加密常量 ---------------------------------------------------------------

  /// 腾讯服务端的 ECDH 公钥（prime256v1 / secp256r1，未压缩点）。
  ///
  /// 与 `takayama-lily/oicq` 的 `lib/wtlogin/ecdh.js` 中 `OICQ_PUBLIC_KEY`
  /// 逐字节一致。握手流程：
  ///
  /// ```text
  ///   客户端生成临时 EC 密钥对
  ///   share_key = MD5( ECDH(自己的私钥, 这个公钥)[0..16) )
  ///   把自己的公钥写进 TLV 0x128 发给服务端
  /// ```
  ///
  /// 注意派生时截取共享秘密的**前 16 字节**再取 MD5，
  /// 不是对完整共享秘密取 MD5。
  static const List<int> serverEcdhPublicKey = <int>[
    0x04,
    0xEB, 0xCA, 0x94, 0xD7, 0x33, 0xE3, 0x99, 0xB2, 0xDB, 0x96, 0xEA,
    0xCD, 0xD3, 0xF6, 0x9A, 0x8B, 0xB0, 0xF7, 0x42, 0x24, 0xE2, 0xB4,
    0x4E, 0x33, 0x57, 0x81, 0x22, 0x11, 0xD2, 0xE6, 0x2E, 0xFB, 0xC9,
    0x1B, 0xB5, 0x53, 0x09, 0x8E, 0x25, 0xE3, 0x3A, 0x79, 0x9A, 0xDC,
    0x7F, 0x76, 0xFE, 0xB2, 0x08, 0xDA, 0x7C, 0x65, 0x22, 0xCD, 0xB0,
    0x71, 0x9A, 0x30, 0x51, 0x80, 0xCC, 0x54, 0xA8, 0x2E,
  ];

  /// 派生共享密钥时截取的字节数。
  static const int shareKeySeedLength = 16;

  /// 诊断：把关键参数拼成一行，便于日志与排障。
  static String describe() =>
      'QQ $versionName ($appVersion) code=$versionCode '
      'subid=$subAppId misc=0x${miscBitmap.toRadixString(16)} '
      'mainSig=0x${mainSigMap.toRadixString(16)} '
      'subSig=0x${subSigMap.toRadixString(16)}';
}
