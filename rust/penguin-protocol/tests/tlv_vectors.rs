//! 登录 TLV 的黄金向量回归（`vectors/tlv.json`）。
//!
//! 断言口径与 Dart 侧 `tool/qq8_tlv_selftest.dart` 一致：
//! * 46 条明文 TLV **逐字节**比；
//! * `0x106` 的密文**不可比**（官方密钥派生与参考实现不同 + TEA 填充任意），
//!   改为比「官方密钥公式 + 解密后的明文」；
//! * `0x144` 密钥两实现一致、填充也固定为 0 ⇒ 密文可逐字节比，
//!   另外解密后比明文、并用本实现解参考密文。
//!
//! 向量的生成器：`analysis/scripts/gen_tlv_vectors.cjs`。

#![allow(clippy::unwrap_used)]

use penguin_crypto::digest::md5_bytes;
use penguin_crypto::tea::{qq_tea_decrypt, qq_tea_pad_len};
use penguin_protocol::device::{AndroidVersion, Device};
use penguin_protocol::profiles::ApkInfo;
use penguin_protocol::tlv::{body, pack, QimeiMode, TlvArg, TlvContext, TlvError, LOGIN_TLV_ORDER};
use serde::Deserialize;

// ---------------------------------------------------------------------------
// 向量文件
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct TlvFile {
    now: i64,
    ctx: CtxJson,
    vectors: Vec<Vector>,
    #[serde(rename = "teaRefs")]
    tea_refs: TeaRefs,
}

#[derive(Deserialize)]
struct CtxJson {
    uin: u32,
    #[serde(rename = "passwordMd5")]
    password_md5: String,
    ksid: String,
    t104: String,
    t174: String,
    tgt: String,
    #[serde(rename = "srmToken")]
    srm_token: String,
    #[serde(rename = "seqId")]
    seq_id: u32,
    #[serde(rename = "randomFill")]
    random_fill: String,
    #[serde(rename = "teaPaddingFill")]
    tea_padding_fill: String,
}

#[derive(Deserialize)]
struct Vector {
    tag: u16,
    args: Vec<serde_json::Value>,
    hex: String,
}

#[derive(Deserialize)]
struct TeaRefs {
    t106: TeaRef,
    t144: TeaRef,
}

#[derive(Deserialize)]
struct TeaRef {
    #[serde(rename = "oicqKey")]
    oicq_key: Option<String>,
    #[serde(rename = "officialKey")]
    official_key: Option<String>,
    key: Option<String>,
    plain: String,
}

fn load() -> TlvFile {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../vectors/tlv.json");
    let raw = std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("读不到 {path}：{e}（先跑 gen_tlv_vectors.cjs）"));
    serde_json::from_str(&raw).expect("vectors/tlv.json 解析失败")
}

// ---------------------------------------------------------------------------
// 夹具（与 tlv.json 的 ctx 逐字段一致；apk 的 TLV 相关字段取 8.2.11 真值）
// ---------------------------------------------------------------------------

fn fixture_device() -> Device {
    Device {
        product: "MRS4S".into(),
        device: "HIM188MOE".into(),
        board: "MIRAI-YYDS".into(),
        brand: "OICQX".into(),
        model: "Konata 2020".into(),
        bootloader: "U-boot".into(),
        fingerprint: "OICQX/MRS4S/HIM188MOE:10/ABCDEF1234567890/1234567:user/release-keys".into(),
        boot_id: "11111111-2222-3333-4444-555555555555".into(),
        proc_version: "Linux version 4.19.71".into(),
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
        imsi: vec![0x22; 16],
        tgtgt: hex::decode("ffeeddccbbaa99887766554433221100").unwrap(),
        guid: hex::decode("00112233445566778899aabbccddeeff").unwrap(),
    }
}

fn fixture_apk() -> ApkInfo {
    ApkInfo {
        id: "com.tencent.mobileqq",
        ver: "8.2.11",
        sdkver: "6.0.0.2423",
        name: "A8.2.11.4530",
        appid: 16,
        subid: 537064117,
        misc_bitmap: 150470524,
        main_sig_map: 16724722,
        sub_sig_map: 66560,
        buildtime: 1608919008,
        sign: hex::decode("a6b745bf24a2c277527716f6f36eb68d")
            .unwrap()
            .try_into()
            .unwrap(),
        sso_ver: 7,
        login_tlv_order: &LOGIN_TLV_ORDER,
        tlv544_degraded_body: &[0, 0, 0, 0],
        tlv553_degraded_body: None,
        qimei_mode: QimeiMode::Md5OfSource,
    }
}

fn fixture_ctx(v: &TlvFile) -> TlvContext {
    let fill = |s: &str| hex::decode(s).unwrap()[0];
    let mut ctx = TlvContext::new(
        v.ctx.uin,
        fixture_apk(),
        fixture_device(),
        hex::decode(&v.ctx.password_md5).unwrap(),
        hex::decode(&v.ctx.ksid).unwrap(),
        hex::decode(&v.ctx.t104).unwrap(),
        hex::decode(&v.ctx.t174).unwrap(),
        hex::decode(&v.ctx.tgt).unwrap(),
        hex::decode(&v.ctx.srm_token).unwrap(),
    )
    .with_seq_id(v.ctx.seq_id);
    let rnd = fill(&v.ctx.random_fill);
    let pad_fill = fill(&v.ctx.tea_padding_fill);
    ctx.random_bytes = Box::new(move |n| vec![rnd; n]);
    // TEA 填充按参考实现的写法重建：首字节 = pad | 0xF8，其余 = fill。
    // （低 3 位是 pad，高位服务端不解码——oicq 写死 0xF8，官方是随机高位。）
    ctx.tea_padding = Box::new(move |n| {
        let mut out = vec![pad_fill; n];
        out[0] = ((n - 3) as u8) | 0xF8;
        out
    });
    let now = v.now;
    ctx.now_millis = Box::new(move || now);
    ctx
}

fn args_of(v: &Vector) -> Vec<TlvArg> {
    v.args
        .iter()
        .map(|a| match a {
            serde_json::Value::Number(n) => TlvArg::Uint(n.as_u64().unwrap()),
            serde_json::Value::String(s) => TlvArg::Str(s.clone()),
            other => panic!("未知参数类型: {other}"),
        })
        .collect()
}

fn tag_name(tag: u16) -> String {
    format!("0x{tag:03x}")
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

/// 46 条明文 TLV 逐字节（`0x106` / `0x144` 见各自的专项测试）。
#[test]
fn plain_tlv_vectors_byte_exact() {
    let v = load();
    let ctx = fixture_ctx(&v);
    let mut checked = 0;
    for vec in &v.vectors {
        if vec.tag == 0x106 || vec.tag == 0x144 {
            continue;
        }
        let got = hex::encode(pack(&ctx, vec.tag, &args_of(vec)).unwrap());
        assert_eq!(
            got,
            vec.hex,
            "{} args={:?} 不匹配\n  期望 {}\n  实际 {}",
            tag_name(vec.tag),
            vec.args,
            vec.hex,
            got
        );
        checked += 1;
    }
    assert_eq!(checked, 46, "明文向量条数应为 46");
}

/// `0x106`：官方密钥派生 `MD5(guid ‖ u64(uin 或 msalt))` + 解密后明文一致。
///
/// 密文本身**不比**：密钥已按官方修正（与 oicq 不同），且 TEA 头部填充任意。
#[test]
fn tlv106_official_key_and_plaintext() {
    let v = load();
    let ctx = fixture_ctx(&v);
    let refs = &v.tea_refs.t106;

    let mut uin64 = [0u8; 8];
    uin64.copy_from_slice(&(ctx.uin as u64).to_be_bytes());
    let official = md5_bytes(&[ctx.device.guid.as_slice(), &uin64].concat());
    assert_eq!(
        hex::encode(official),
        refs.official_key.clone().unwrap(),
        "官方密钥公式不符"
    );

    // 同时确认与 oicq 的公式（password_md5 ‖ 0000 ‖ u32(uin)）确实不同
    let oicq_ref = refs.oicq_key.clone().unwrap();
    let mut oicq_seed = ctx.password_md5.clone();
    oicq_seed.extend_from_slice(&[0u8; 4]);
    oicq_seed.extend_from_slice(&ctx.uin.to_be_bytes());
    let oicq = md5_bytes(&oicq_seed);
    assert_eq!(hex::encode(oicq), oicq_ref, "oicq 公式复算不符");
    assert_ne!(hex::encode(official), oicq_ref, "两公式不应相同");

    let packed = pack(&ctx, 0x106, &[]).unwrap();
    let plain = qq_tea_decrypt(&packed[4..], &official).unwrap();
    assert_eq!(hex::encode(&plain), refs.plain, "0x106 明文不符");
}

/// `0x144`：密钥两实现一致且填充固定 ⇒ 密文可逐字节比；再解明文交叉验证。
#[test]
fn tlv144_ciphertext_and_plaintext() {
    let v = load();
    let ctx = fixture_ctx(&v);
    let refs = &v.tea_refs.t144;

    assert_eq!(
        hex::encode(&ctx.device.tgtgt),
        refs.key.clone().unwrap(),
        "0x144 密钥应即 device.tgtgt"
    );

    let vec = v.vectors.iter().find(|x| x.tag == 0x144).unwrap();
    let packed = pack(&ctx, 0x144, &[]).unwrap();
    assert_eq!(hex::encode(&packed), vec.hex, "0x144 密文不匹配");

    let plain = qq_tea_decrypt(&packed[4..], &ctx.device.tgtgt).unwrap();
    assert_eq!(hex::encode(&plain), refs.plain, "0x144 明文不符");

    // 用本实现解参考实现的密文
    let ref_body = hex::decode(&vec.hex).unwrap()[4..].to_vec();
    let dec = qq_tea_decrypt(&ref_body, &ctx.device.tgtgt).unwrap();
    assert_eq!(hex::encode(&dec), refs.plain, "解参考密文 0x144 明文不符");
}

/// `[tag][len][body]` 帧结构自洽 + 未知编号报错。
#[test]
fn framing_self_consistent() {
    let v = load();
    let ctx = fixture_ctx(&v);
    for vec in &v.vectors {
        let packed = pack(&ctx, vec.tag, &args_of(vec)).unwrap();
        let tag = u16::from_be_bytes([packed[0], packed[1]]);
        let len = u16::from_be_bytes([packed[2], packed[3]]);
        assert_eq!(tag, vec.tag);
        assert_eq!(
            len as usize,
            packed.len() - 4,
            "{} len 只应计 body",
            tag_name(vec.tag)
        );
    }
    assert_eq!(pack(&ctx, 0x9999, &[]), Err(TlvError::UnknownTag(0x9999)));
}

/// 嵌套与加密结构的完整性：`0x144` 的 5 个子 TLV、`0x52d` 的 9 个 pb 字段。
#[test]
fn nested_integrity() {
    let v = load();
    let ctx = fixture_ctx(&v);

    let t144 = pack(&ctx, 0x144, &[]).unwrap();
    let inner = qq_tea_decrypt(&t144[4..], &ctx.device.tgtgt).unwrap();
    assert_eq!(u16::from_be_bytes([inner[0], inner[1]]), 5, "子 TLV 计数");

    let mut pos = 2;
    let mut tags = Vec::new();
    while pos < inner.len() {
        let t = u16::from_be_bytes([inner[pos], inner[pos + 1]]);
        let l = u16::from_be_bytes([inner[pos + 2], inner[pos + 3]]) as usize;
        tags.push(t);
        pos += 4 + l;
    }
    assert_eq!(tags, vec![0x109, 0x52d, 0x124, 0x128, 0x16e]);

    let t52d = body(&ctx, 0x52D, &[]).unwrap();
    assert_eq!(count_pb_fields(&t52d), 9, "0x52d 应为 9 字段 protobuf");

    let t16 = pack(&ctx, 0x16, &[]).unwrap();
    assert!(
        hex::encode(&t16).ends_with(&hex::encode(ctx.apk.sign)),
        "0x16 内嵌的 sign 应与 apk.sign 一致"
    );

    // TEA 填充长度取 `pad + 3`（TlvContext 注入源按此长度被调用）
    let t = pack(&ctx, 0x401, &[]).unwrap();
    assert_eq!(t.len(), 4 + 16);
    let _ = qq_tea_pad_len(0);
}

/// 简单 protobuf 字段计数（只处理 wire type 0 与 2，够用）。
fn count_pb_fields(data: &[u8]) -> usize {
    let mut pos = 0usize;
    let mut count = 0usize;
    let read_varint = |pos: &mut usize| -> u64 {
        let mut v = 0u64;
        let mut shift = 0u32;
        while *pos < data.len() {
            let b = data[*pos];
            *pos += 1;
            v |= ((b & 0x7F) as u64) << shift;
            if b & 0x80 == 0 {
                break;
            }
            shift += 7;
        }
        v
    };
    while pos < data.len() {
        let key = read_varint(&mut pos);
        count += 1;
        match key & 7 {
            0 => {
                read_varint(&mut pos);
            }
            2 => {
                let len = read_varint(&mut pos) as usize;
                pos += len;
            }
            _ => break,
        }
    }
    count
}
