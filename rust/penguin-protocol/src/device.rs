//! 设备信息的数据模型（对应 Dart `lib/kernel/wlogin8/qq8_device.dart`）。
//!
//! ## 关于"设备指纹"
//!
//! [`Device::generate`] 按参考实现 oicq `lib/device.js` 的做法，**由账号
//! （uin）确定性派生设备信息，而不是采集真实设备**（那套值一眼是梗名：
//! `MRS4S` / `HIM188MOE` / `Konata 2020`…，说明 8.2.11 时代服务端不校验
//! 设备信息真实性）。本项目沿用同样的合成方式，理由有二：
//!
//! 1. 不采集用户真实设备信息，隐私上更干净；
//! 2. 同一账号始终得到同一设备，避免"设备频繁变化"这个明显的风控信号。
//!
//! ⚠️ 这是**协议层的数据构造**，不是设备指纹伪造或反检测手段；本模块不含
//! 任何规避风控的机制，也不提供真实机型伪装。
//!
//! 派生结果对同一 `uin` 恒定（除 `imsi` / `tgtgt` 两个随机字段外），黄金向量
//! 见 `vectors/device.json`（生成端 `tool/qq8_device_vectors.dart`）。

use penguin_crypto::digest::md5_bytes;

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
    /// 16 字节随机字段。
    pub imsi: Vec<u8>,
    /// 16 字节；TLV 0x106 / 0x144 的加密密钥之一。
    pub tgtgt: Vec<u8>,
    /// `MD5(IMEI + MAC)`。
    pub guid: Vec<u8>,
}

fn os_random(n: usize) -> Vec<u8> {
    let mut out = vec![0u8; n];
    if getrandom::getrandom(&mut out).is_err() {
        panic!("系统随机源不可用");
    }
    out
}

impl Device {
    /// 由账号确定性派生一份设备信息（生产路径：随机源 = 系统熵）。
    pub fn generate(uin: u32) -> Device {
        Self::generate_with(uin, &mut os_random)
    }

    /// 同 [`Device::generate`]，但可注入随机源（测试/向量用）。
    pub fn generate_with(uin: u32, random: &mut dyn FnMut(usize) -> Vec<u8>) -> Device {
        let hash = md5_bytes(uin.to_string().as_bytes());
        let imei = synthetic_imei(uin);
        let mac = synthetic_mac(&hash);
        let guid = md5_bytes(&[imei.as_bytes(), mac.as_bytes()].concat());
        let android_id = android_id(uin, &hash);
        let incremental = u32_at(&hash, 12).to_string();

        Device {
            product: "MRS4S".into(),
            device: "HIM188MOE".into(),
            board: "MIRAI-YYDS".into(),
            brand: "OICQX".into(),
            model: "Konata 2020".into(),
            bootloader: "U-boot".into(),
            fingerprint: format!(
                "OICQX/MRS4S/HIM188MOE:10/{android_id}/{incremental}:user/release-keys"
            ),
            boot_id: uuid_from(&hash),
            proc_version: format!(
                "Linux version 4.19.71-{} (konata@takayama.github.com)",
                u16_at(&hash, 4)
            ),
            baseband: String::new(),
            sim: "T-Mobile".into(),
            apn: "wifi".into(),
            os_type: "android".into(),
            mac_address: mac.clone(),
            ip_address: format!("10.0.{}.{}", hash[10], hash[11]),
            wifi_bssid: mac,
            wifi_ssid: format!("TP-LINK-{uin:x}"),
            imei,
            android_id,
            version: AndroidVersion {
                release: "10".into(),
                codename: "REL".into(),
                incremental,
                sdk: 29,
            },
            imsi: random(16),
            tgtgt: random(16),
            guid: guid.to_vec(),
        }
    }

    /// 复制一份设备，只替换 `tgtgt`。
    ///
    /// token 续期路径要求 `tgtgt = MD5(d2key)`：没有密码就没法用 t106 派生新的
    /// tgtgt，只能沿用这个约定值。其余字段（imei/guid/mac…）必须保持与上次登录
    /// 一致，否则"同一账号同一设备"的前提就破了。
    pub fn with_tgtgt(&self, new_tgtgt: Vec<u8>) -> Device {
        Device {
            tgtgt: new_tgtgt,
            ..self.clone()
        }
    }
}

// ---------------------------------------------------------------------------
// 派生细节（与 oicq `lib/device.js` / Dart 侧逐行对应）
// ---------------------------------------------------------------------------

/// `_genIMEI`：由 uin 派生一个格式合法的 IMEI（含 Luhn 校验位）。
fn synthetic_imei(uin: u32) -> String {
    let mut p = if uin % 2 == 1 { "86" } else { "35" }.to_string();
    let buf = uin.to_be_bytes();
    let s = uin.to_string();

    let mut a = ((buf[0] as u64) << 8) | buf[1] as u64;
    let mut b = ((buf[1] as u64) << 16) | ((buf[2] as u64) << 8) | buf[3] as u64;

    if a > 9999 {
        a /= 10;
    } else if a < 1000 {
        a = s[..s.len().min(4)].parse().unwrap();
    }
    while b > 9_999_999 {
        b >>= 1;
    }
    if b < 1_000_000 {
        b = format!("{}{}", &s[..s.len().min(4)], &s[..s.len().min(3)])
            .parse()
            .unwrap();
    }
    p.push_str(&format!("{a}0{b}"));

    // Luhn 校验位
    let mut sum = 0i64;
    for (i, ch) in p.chars().enumerate() {
        let d = ch.to_digit(10).unwrap() as i64;
        if i % 2 == 1 {
            let j = d * 2;
            sum += j % 10 + j / 10;
        } else {
            sum += d;
        }
    }
    format!("{p}{}", (100 - sum).rem_euclid(10))
}

fn synthetic_mac(hash: &[u8; 16]) -> String {
    format!(
        "00:50:{:02X}:{:02X}:{:02X}:{:02X}",
        hash[6], hash[7], hash[8], hash[9]
    )
}

fn android_id(uin: u32, hash: &[u8; 16]) -> String {
    let s = uin.to_string();
    format!(
        "OICQX.{}{}.{}{}",
        u16_at(hash, 0),
        hash[2],
        hash[3],
        &s[..1]
    )
}

fn uuid_from(hash: &[u8; 16]) -> String {
    let h: String = hash.iter().map(|b| format!("{b:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &h[0..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..32]
    )
}

fn u16_at(b: &[u8], off: usize) -> u16 {
    ((b[off] as u16) << 8) | b[off + 1] as u16
}

fn u32_at(b: &[u8], off: usize) -> u32 {
    ((b[off] as u32) << 24)
        | ((b[off + 1] as u32) << 16)
        | ((b[off + 2] as u32) << 8)
        | b[off + 3] as u32
}
