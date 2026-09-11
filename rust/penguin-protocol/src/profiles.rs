//! 客户端档案（APK 参数），对应 Dart 侧 `lib/kernel/wlogin8/qq8_profiles.dart`。
//!
//! 本轮只移植**信封层用到的字段**（subid / ssoVer / sdkver / sign …）；
//! `loginTlvOrder`（37/38 项）、`0x544/0x553` 降级 body、`qimeiMode`
//! 这些属于 TLV 层，随 TLV 移植一起补齐（出处见 Dart 侧同名文件）。

/// 一个客户端版本的 APK 参数。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApkInfo {
    /// 包名（如 `com.tencent.mobileqq`）。
    pub id: &'static str,
    /// `AndroidManifest` 的 `versionName`。
    pub ver: &'static str,
    /// WLogin SDK 版本串（`oicq.wlogin_sdk.tools.util.SDK_VERSION`）。
    pub sdkver: &'static str,
    /// 客户端标识名（`ksid` 用；取值约定见 Dart 侧文档）。
    pub name: &'static str,
    pub appid: u32,
    /// 子应用 ID（`AppSetting_params` 的 `#` 分隔第 1 段）。
    pub subid: u32,
    pub misc_bitmap: u32,
    pub main_sig_map: u32,
    pub sub_sig_map: u32,
    /// `util.BUILD_TIME`。
    pub buildtime: u32,
    /// 登录信封里的签名（APK 证书 DER 的 MD5，16 字节）。
    pub sign: [u8; 16],
    /// `tlv_t100._sso_ver` / `tlv_t106._SsoVer`。
    pub sso_ver: u32,
}

/// QQ 三版本共用的签名（腾讯同一张 1024-bit 证书）。
const QQ_SIGN: [u8; 16] = [
    0xa6, 0xb7, 0x45, 0xbf, 0x24, 0xa2, 0xc2, 0x77, 0x52, 0x77, 0x16, 0xf6, 0xf3, 0x6e, 0xb6, 0x8d,
];

/// QQ 8.2.11（Play 版）—— `_SSoVer` = 7。
pub const QQ_8211: ApkInfo = ApkInfo {
    id: "com.tencent.mobileqq",
    ver: "8.2.11",
    sdkver: "6.0.0.2423",
    name: "A8.2.11.4530",
    appid: 16,
    subid: 537064117,
    misc_bitmap: 150470524,
    main_sig_map: 16724722,
    sub_sig_map: 66560,
    buildtime: 1582559746,
    sign: QQ_SIGN,
    sso_ver: 7,
};

/// QQ 8.9.50（应用宝渠道）—— 默认档案，`_SSoVer` = 19。
pub const QQ_8950: ApkInfo = ApkInfo {
    id: "com.tencent.mobileqq",
    ver: "8.9.50",
    sdkver: "6.0.0.2535",
    name: "A8.9.50.10650",
    appid: 16,
    subid: 537155557,
    misc_bitmap: 150470524,
    main_sig_map: 16724722,
    sub_sig_map: 66560,
    buildtime: 1676531414,
    sign: QQ_SIGN,
    sso_ver: 19,
};

/// QQ 9.3.60（应用宝渠道）—— `_SSoVer` = 22。
pub const QQ_9360: ApkInfo = ApkInfo {
    id: "com.tencent.mobileqq",
    ver: "9.3.60",
    sdkver: "6.0.0.2591",
    name: "A9.3.60.41075",
    appid: 16,
    subid: 537389183,
    misc_bitmap: 150470524,
    main_sig_map: 16724722,
    sub_sig_map: 66560,
    buildtime: 1784552169,
    sign: QQ_SIGN,
    sso_ver: 22,
};

/// TIM 4.1.0.4050 —— 另一张证书，`_SSoVer` = 22。
pub const TIM_410: ApkInfo = ApkInfo {
    id: "com.tencent.tim",
    ver: "4.1.0",
    sdkver: "6.0.0.2563",
    name: "A4.1.0.4050",
    appid: 16,
    subid: 537298353,
    misc_bitmap: 150470524,
    main_sig_map: 16724722,
    sub_sig_map: 66560,
    buildtime: 1724313621,
    sign: [
        0x77, 0x5e, 0x69, 0x6d, 0x09, 0x85, 0x68, 0x72, 0xfd, 0xd8, 0xab, 0x4f, 0x3f, 0x06, 0xb1,
        0xe0,
    ],
    sso_ver: 22,
};

/// 供测试用的 8.2.11 夹具——与 `analysis/scripts/gen_sso_vectors.cjs` 的
/// `mockApk` **逐字段一致**（`buildtime` 与 `name` 除外：mock 用的是当时
/// 的占位值，这里用档案里的真实值；两者都不参与信封组包）。
pub const FIXTURE_SSO_VECTORS: ApkInfo = ApkInfo {
    id: "com.tencent.mobileqq",
    ver: "8.2.11",
    sdkver: "6.0.0.2423",
    name: "A8.2.11.4530",
    appid: 16,
    subid: 537064117,
    misc_bitmap: 150470524,
    main_sig_map: 16724722,
    sub_sig_map: 66560,
    buildtime: 1608919008, // ← mock 的原值（不参与 ksid/信封）
    sign: QQ_SIGN,
    sso_ver: 7,
};
