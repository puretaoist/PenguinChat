//! 设备派生的黄金向量回归（`vectors/device.json`）。
//!
//! 生成端：`tool/qq8_device_vectors.dart`（Dart 侧同一套派生）。
//! 设备派生是"同一账号恒定同一台设备"的前提——两边只要有一处不等，
//! 实现切换时指纹就会漂移，所以这里逐字段比。

#![allow(clippy::unwrap_used)]

use penguin_protocol::device::Device;
use serde::Deserialize;

#[derive(Deserialize)]
struct DeviceVectors {
    #[serde(rename = "randomFill")]
    random_fill: String,
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    uin: u32,
    imei: String,
    #[serde(rename = "macAddress")]
    mac_address: String,
    guid: String,
    #[serde(rename = "androidId")]
    android_id: String,
    #[serde(rename = "bootId")]
    boot_id: String,
    #[serde(rename = "procVersion")]
    proc_version: String,
    #[serde(rename = "ipAddress")]
    ip_address: String,
    #[serde(rename = "wifiSsid")]
    wifi_ssid: String,
    fingerprint: String,
    version: VersionJson,
    imsi: String,
    tgtgt: String,
    product: String,
    device: String,
    board: String,
    brand: String,
    model: String,
    bootloader: String,
    baseband: String,
    sim: String,
    apn: String,
    #[serde(rename = "osType")]
    os_type: String,
    #[serde(rename = "wifiBssid")]
    wifi_bssid: String,
}

#[derive(Deserialize)]
struct VersionJson {
    release: String,
    codename: String,
    incremental: String,
    sdk: u32,
}

fn load() -> DeviceVectors {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../vectors/device.json");
    let raw = std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("读不到 {path}：{e}（先跑 tool/qq8_device_vectors.dart）"));
    serde_json::from_str(&raw).expect("vectors/device.json 解析失败")
}

#[test]
fn device_derivation_matches_dart() {
    let v = load();
    let fill = u8::from_str_radix(&v.random_fill, 16).unwrap();

    for c in &v.cases {
        let mut rnd = |n: usize| vec![fill; n];
        let d = Device::generate_with(c.uin, &mut rnd);

        assert_eq!(d.imei, c.imei, "uin={} imei", c.uin);
        assert_eq!(d.mac_address, c.mac_address, "uin={} mac", c.uin);
        assert_eq!(hex::encode(&d.guid), c.guid, "uin={} guid", c.uin);
        assert_eq!(d.android_id, c.android_id, "uin={} androidId", c.uin);
        assert_eq!(d.boot_id, c.boot_id, "uin={} bootId", c.uin);
        assert_eq!(d.proc_version, c.proc_version, "uin={} procVersion", c.uin);
        assert_eq!(d.ip_address, c.ip_address, "uin={} ip", c.uin);
        assert_eq!(d.wifi_ssid, c.wifi_ssid, "uin={} wifiSsid", c.uin);
        assert_eq!(d.wifi_bssid, c.wifi_bssid, "uin={} wifiBssid", c.uin);
        assert_eq!(d.fingerprint, c.fingerprint, "uin={} fingerprint", c.uin);
        assert_eq!(d.version.release, c.version.release);
        assert_eq!(d.version.codename, c.version.codename);
        assert_eq!(d.version.incremental, c.version.incremental);
        assert_eq!(d.version.sdk, c.version.sdk);
        assert_eq!(hex::encode(&d.imsi), c.imsi, "uin={} imsi", c.uin);
        assert_eq!(hex::encode(&d.tgtgt), c.tgtgt, "uin={} tgtgt", c.uin);
        assert_eq!(d.product, c.product);
        assert_eq!(d.device, c.device);
        assert_eq!(d.board, c.board);
        assert_eq!(d.brand, c.brand);
        assert_eq!(d.model, c.model);
        assert_eq!(d.bootloader, c.bootloader);
        assert_eq!(d.baseband, c.baseband);
        assert_eq!(d.sim, c.sim);
        assert_eq!(d.apn, c.apn);
        assert_eq!(d.os_type, c.os_type);
    }
}

/// 同一 uin 恒定（除随机字段）；不同 uin 不同；guid = MD5(IMEI + MAC)。
#[test]
fn device_derivation_properties() {
    let a1 = Device::generate(10001);
    let a2 = Device::generate(10001);
    let b = Device::generate(10002);

    assert_eq!(a1.imei, a2.imei, "同 uin 两次生成：imei 相同");
    assert_eq!(a1.mac_address, a2.mac_address);
    assert_eq!(a1.guid, a2.guid);
    assert_eq!(a1.android_id, a2.android_id);
    assert_ne!(a1.imei, b.imei, "不同 uin：imei 不同");
    assert_ne!(a1.guid, b.guid, "不同 uin：guid 不同");

    let expect = penguin_crypto::digest::md5_bytes(
        &[a1.imei.as_bytes(), a1.mac_address.as_bytes()].concat(),
    );
    assert_eq!(a1.guid, expect.to_vec(), "guid = MD5(IMEI + MAC)");

    // imei 是 15 位且 Luhn 校验位正确
    assert_eq!(a1.imei.len(), 15, "imei 应 15 位");
    let mut sum = 0i64;
    for (i, ch) in a1.imei.chars().enumerate() {
        let d = ch.to_digit(10).unwrap() as i64;
        if i % 2 == 1 {
            let j = d * 2;
            sum += j % 10 + j / 10;
        } else {
            sum += d;
        }
    }
    assert_eq!(sum % 10, 0, "imei Luhn 校验应通过");

    // with_tgtgt：只换 tgtgt，其余身份字段原样保留
    let t2 = vec![0x5a; 16];
    let c = a1.with_tgtgt(t2.clone());
    assert_eq!(c.tgtgt, t2, "with_tgtgt 后 tgtgt 生效");
    assert_eq!(c.guid, a1.guid, "with_tgtgt 不动 guid");
    assert_eq!(c.imei, a1.imei);
    assert_eq!(c.mac_address, a1.mac_address);
}
