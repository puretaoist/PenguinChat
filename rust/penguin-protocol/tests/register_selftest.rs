//! 上线注册离线自测（Rust 侧），断言口径与 Dart 侧
//! `tool/qq8_register_selftest.dart` 一致：
//! * 整条 body 与 Dart 实现**逐字节**一致（`vectors/register.json`，
//!   生成端 `tool/qq8_register_vectors.dart`）——JCE 按插入序编码，
//!   单独逐槽位比对抓不到"顺序写反"；
//! * 槽位与响应判读的逐项断言。

#![allow(clippy::unwrap_used)]

use penguin_protocol::device::{AndroidVersion, Device};
use penguin_protocol::jce::{self, JceValue};
use penguin_protocol::register;
use serde::Deserialize;

/// 固定时间戳（与 `analysis/scripts/gen_pb_vector.cjs` 一致）。
const TS: i64 = 1700000000000;

/// 黄金向量：`analysis/scripts/gen_pb_vector.cjs` 生成。
const PB_GOLDEN: &str = "0a09082e1080d095ffbc310a05089b021000";

fn device() -> Device {
    Device {
        product: "piano".into(),
        device: "piano".into(),
        board: "piano".into(),
        brand: "Xiaomi".into(),
        model: "25091RP04C".into(),
        bootloader: "unknown".into(),
        fingerprint: "Xiaomi/piano/piano:16/BP2A/eng:user/release-keys".into(),
        boot_id: "11111111-2222-3333-4444-555555555555".into(),
        proc_version: "Linux version 5.15.0".into(),
        baseband: String::new(),
        sim: "T-Mobile".into(),
        apn: "wifi".into(),
        os_type: "android".into(),
        mac_address: "00:50:56:C0:00:08".into(),
        ip_address: "10.0.0.1".into(),
        wifi_bssid: "00:50:56:C0:00:08".into(),
        wifi_ssid: "TP-LINK-2711".into(),
        imei: "860000000000001".into(),
        android_id: "ABCDEF1234567890".into(),
        version: AndroidVersion {
            release: "10".into(),
            codename: "REL".into(),
            incremental: "1234567".into(),
            sdk: 29,
        },
        imsi: vec![0; 16],
        tgtgt: vec![0; 16],
        guid: hex::decode("00112233445566778899aabbccddeeff").unwrap(),
    }
}

fn as_int(v: Option<&JceValue>) -> i64 {
    match v {
        Some(JceValue::Int(i)) => *i,
        other => panic!("期望整数，实际 {other:?}"),
    }
}

fn as_str(v: Option<&JceValue>) -> String {
    match v {
        Some(JceValue::Str(s)) => s.clone(),
        other => panic!("期望字符串，实际 {other:?}"),
    }
}

#[derive(Deserialize)]
struct RegisterVectors {
    #[serde(rename = "onlineHex")]
    online_hex: String,
    #[serde(rename = "logoutHex")]
    logout_hex: String,
}

fn load_vectors() -> RegisterVectors {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../vectors/register.json");
    let raw = std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("读不到 {path}：{e}（先跑 tool/qq8_register_vectors.dart）"));
    serde_json::from_str(&raw).expect("vectors/register.json 解析失败")
}

/// 整条 body 与 Dart 实现逐字节一致（含字段顺序）。
#[test]
fn body_matches_dart_bytes() {
    let v = load_vectors();
    let online = register::build_body(10001, &device(), false, Some(TS)).unwrap();
    assert_eq!(
        hex::encode(&online),
        v.online_hex,
        "上线 body 与 Dart 不一致"
    );
    let logout = register::build_body(10001, &device(), true, Some(TS)).unwrap();
    assert_eq!(
        hex::encode(&logout),
        v.logout_hex,
        "logout body 与 Dart 不一致"
    );
}

#[test]
fn request_body_slots() {
    let body = register::build_body(10001, &device(), false, Some(TS)).unwrap();

    // 外层 WUP 包装：service / method
    let wrapper = jce::decode(&body).unwrap();
    assert_eq!(as_str(wrapper.get(&5)), "PushService");
    assert_eq!(as_str(wrapper.get(&6)), "SvcReqRegister");

    // 内层结构逐槽位
    let f = jce::decode_wrapper(&body).unwrap();
    assert_eq!(as_int(f.get(&0)), 10001, "tag0 = uin");
    assert_eq!(as_int(f.get(&1)), 7, "tag1 = 7（上线）");
    assert_eq!(as_int(f.get(&4)), 11, "tag4 = 11");
    assert_eq!(as_int(f.get(&11)), 29, "tag11 = sdk");
    match f.get(&16) {
        Some(JceValue::Bytes(b)) => {
            assert_eq!(
                hex::encode(b),
                "00112233445566778899aabbccddeeff",
                "tag16 = guid"
            )
        }
        other => panic!("tag16 期望字节串，实际 {other:?}"),
    }
    assert_eq!(as_int(f.get(&17)), 2052, "tag17 = 2052");
    assert_eq!(as_str(f.get(&19)), "25091RP04C");
    assert_eq!(as_str(f.get(&20)), "25091RP04C");
    assert_eq!(as_str(f.get(&21)), "10", "tag21 = release");
    assert_eq!(as_str(f.get(&30)), "Xiaomi");
    assert_eq!(as_str(f.get(&31)), "Xiaomi");
    match f.get(&33) {
        Some(JceValue::Bytes(b)) => assert_eq!(hex::encode(b), PB_GOLDEN, "tag33 = pb blob"),
        other => panic!("tag33 期望字节串，实际 {other:?}"),
    }
    assert_eq!(as_int(f.get(&38)), 1000, "tag38 = 1000");
    assert_eq!(as_int(f.get(&39)), 98, "tag39 = 98");
    for tag in [15, 25, 35, 37] {
        assert!(!f.contains_key(&tag), "null 槽位 {tag} 应被跳过");
    }
    assert_eq!(f.len(), 36, "实发槽位数 36（40 - 4 个 null）");
}

#[test]
fn logout_variant() {
    let body = register::build_body(10001, &device(), true, Some(TS)).unwrap();
    let f = jce::decode_wrapper(&body).unwrap();
    assert_eq!(as_int(f.get(&1)), 0, "logout：tag1 = 0");
    assert_eq!(as_int(f.get(&4)), 21, "logout：tag4 = 21");
    assert_eq!(as_int(f.get(&10)), 44, "logout：tag10 = 44");
}

#[test]
fn response_parsing() {
    // 响应也是 WUP 包装：合成 [sBuffer(7) → 属性表 → SvcRespRegister 结构]，
    // rsp[9]=1 成功 / 0 失败
    let resp_with = |tag9: i64| -> Vec<u8> {
        let struct_bytes =
            jce::encode_struct(&[(0, JceValue::Int(10001)), (9, JceValue::Int(tag9))]).unwrap();
        let attrs = vec![(
            JceValue::Str("SvcRespRegister".into()),
            JceValue::Bytes(struct_bytes),
        )];
        let payload = jce::encode(&[(0, JceValue::Map(attrs))]).unwrap();
        jce::encode(&[(7, JceValue::Bytes(payload))]).unwrap()
    };

    assert!(
        register::parse_response(&resp_with(1)).unwrap(),
        "rsp[9]=1 → 成功"
    );
    assert!(
        !register::parse_response(&resp_with(0)).unwrap(),
        "rsp[9]=0 → 失败"
    );
}
