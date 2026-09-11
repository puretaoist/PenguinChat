//! 设备信息的数据模型（对应 Dart `lib/kernel/wlogin8/qq8_device.dart`）。
//!
//! 本轮只移植**数据模型**——信封层用到 `imei`（ksid）与 `guid`。
//! `generate(uin)` 那套派生（Luhn 校验的合成 IMEI、`guid = MD5(imei+mac)`、
//! androidId / bootId / uuid…）随登录 TLV 层一起移植，出处见 Dart 侧同名文件。

/// 安卓版本。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AndroidVersion {
    pub release: String,
    pub codename: String,
    pub incremental: String,
    pub sdk: u32,
}

/// 设备信息（字段与 Dart 侧一一对应）。
#[derive(Debug, Clone)]
pub struct Device {
    pub product: String,
    pub device: String,
    pub board: String,
    pub brand: String,
    pub model: String,
    pub bootloader: String,
    pub fingerprint: String,
    pub boot_id: String,
    pub proc_version: String,
    pub baseband: String,
    pub sim: String,
    pub apn: String,
    pub os_type: String,
    pub mac_address: String,
    pub ip_address: String,
    pub wifi_bssid: String,
    pub wifi_ssid: String,
    pub imei: String,
    pub android_id: String,
    pub version: AndroidVersion,
    /// 16 字节随机种子。
    pub imsi: Vec<u8>,
    /// 16 字节；TLV 0x106 / 0x144 的加密密钥之一。
    pub tgtgt: Vec<u8>,
    /// `MD5(IMEI + MAC)`（派生逻辑随 `generate` 一起移植）。
    pub guid: Vec<u8>,
}
