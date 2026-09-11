//! SSO 信封 / UNI 包的黄金向量回归（`vectors/protocol.json`）。
//!
//! 断言口径与 Dart 侧 `tool/qq8_sso_selftest.dart` 完全一致：
//! **明文区逐字节比；TEA 区解密后比明文**（密文含任意填充，不可比），
//! 尾部固定字节（0x03）单独比。

#![allow(clippy::unwrap_used)]

use penguin_crypto::tea::{qq_tea_decrypt, qq_tea_encrypt};
use penguin_protocol::device::{AndroidVersion, Device};
use penguin_protocol::profiles::FIXTURE_SSO_VECTORS;
use penguin_protocol::sso::{self, SigInfo, SsoContext};
use penguin_protocol::uni;
use serde::Deserialize;

#[derive(Deserialize)]
struct Protocol {
    sso: SsoPart,
    uni: UniPart,
}

#[derive(Deserialize)]
struct SsoPart {
    #[serde(rename = "ksidAscii")]
    ksid_ascii: String,
    vectors: Vec<SsoVector>,
}

#[derive(Deserialize)]
struct SsoVector {
    kind: String,
    name: Option<String>,
    emp: Option<bool>,
    #[serde(rename = "type")]
    ty: Option<u8>,
    hex: String,
}

#[derive(Deserialize)]
struct UniPart {
    inputs: UniInputs,
    pkt: String,
}

#[derive(Deserialize)]
struct UniInputs {
    uin: u32,
    cmd: String,
    seq: u32,
    session: String,
    d2key: String,
    body: String,
}

fn load() -> Protocol {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../vectors/protocol.json");
    let raw = std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("读不到 {path}：{e}（先跑 export_protocol_vectors.cjs）"));
    serde_json::from_str(&raw).expect("vectors/protocol.json 解析失败")
}

/// 与 `gen_sso_vectors.cjs` 的 mock 逐字段对齐的夹具。
fn fixture_ctx() -> SsoContext {
    let device = Device {
        product: "piano".into(),
        device: "piano".into(),
        board: "piano".into(),
        brand: "OICQX".into(),
        model: "Konata 2020".into(),
        bootloader: "U-boot".into(),
        fingerprint: "OICQX/MRS4S/HIM188MOE:10/ABCDEF1234567890/1234567:user/release-keys".into(),
        boot_id: "11111111-2222-3333-4444-555555555555".into(),
        proc_version: "Linux version 4.19.71".into(),
        baseband: "".into(),
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
        tgtgt: vec![
            0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22,
            0x11, 0x00,
        ],
        guid: vec![
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd,
            0xee, 0xff,
        ],
    };
    let ecdh_pub = hex::decode(
        "04e48813e656219b4090c282a020f40e07b4e1efd60a3dd17492a1667c5758ee5b760f9b9b1c840b4f4f63ab4043c0537ca29b3512c32e50e56f5e4e8d42d0d31e",
    )
    .unwrap();
    SsoContext {
        uin: 10001,
        apk: FIXTURE_SSO_VECTORS,
        device,
        session_id: vec![0xab; 4],
        random_key: vec![0xab; 16],
        ecdh_public_key: ecdh_pub,
        ecdh_share_key: hex::decode("f3df7dfb6d55b17975d908d8228dee11").unwrap(),
        sig: SigInfo {
            tgt: hex::decode("1122334455667788").unwrap(),
            d2: hex::decode("d2d2d2d2").unwrap(),
            d2key: hex::decode("00112233445566778899aabbccddeeff").unwrap(),
            sig_key: hex::decode("aaaaaaaabbbbbbbbccccccccdddddddd").unwrap(),
            ticket_key: hex::decode("0102030405060708090a0b0c0d0e0f10").unwrap(),
            srm_token: hex::decode("99aabbcc").unwrap(),
        },
        seq_id: 101,
    }
}

/// 明文前缀逐字节比 + 密文区"解密后比明文" + 尾部逐字节比。
fn assert_with_cipher(ours: &[u8], theirs: &[u8], cipher_start: usize, trailer: usize, key: &[u8]) {
    assert_eq!(ours.len(), theirs.len(), "整包长度不一致");
    assert_eq!(
        &ours[..cipher_start],
        &theirs[..cipher_start],
        "明文前缀不一致"
    );
    let ours_ct = &ours[cipher_start..ours.len() - trailer];
    let theirs_ct = &theirs[cipher_start..theirs.len() - trailer];
    let ours_pt = qq_tea_decrypt(ours_ct, key).expect("我方密文解密失败");
    let theirs_pt = qq_tea_decrypt(theirs_ct, key).expect("参考密文解密失败");
    assert_eq!(ours_pt, theirs_pt, "解密后明文不一致");
    assert_eq!(
        &ours[ours.len() - trailer..],
        &theirs[theirs.len() - trailer..],
        "尾部不一致"
    );
}

fn body_of(name: &str) -> Vec<u8> {
    match name {
        "empty" => Vec::new(),
        "short" => hex::decode("deadbeef").unwrap(),
        "medium" => hex::decode("0123456789abcdef0011223344556677").unwrap(),
        "long" => vec![0xc3; 105],
        other => panic!("未知夹具 body: {other}"),
    }
}

#[test]
fn ksid_matches_reference() {
    let v = load();
    let ctx = fixture_ctx();
    assert_eq!(String::from_utf8(ctx.ksid()).unwrap(), v.sso.ksid_ascii);
}

#[test]
fn oicq_and_login_packets_match_reference() {
    let v = load();
    let ctx = fixture_ctx();
    let mut checked = 0;

    for vec in &v.sso.vectors {
        let theirs = hex::decode(&vec.hex).unwrap();
        match vec.kind.as_str() {
            "oicq" => {
                let name = vec.name.as_deref().unwrap();
                let emp = vec.emp.unwrap_or(false);
                let ours = sso::build_oicq_packet(&ctx, &body_of(name), emp);
                if emp {
                    // [28 头][u16 tlv 长][sigKey 16] 之后是密文，尾部 0x03
                    assert_with_cipher(&ours, &theirs, 28 + 2 + 16, 1, &ctx.sig.ticket_key);
                } else {
                    // [28 头][02 01][randomKey 16][u16 0x131][u16 1][tlv: u16 长 + 65 公钥]
                    assert_with_cipher(
                        &ours,
                        &theirs,
                        28 + 2 + 16 + 2 + 2 + 2 + 65,
                        1,
                        &ctx.ecdh_share_key,
                    );
                }
                checked += 1;
            }
            "login" => {
                let ty = vec.ty.unwrap();
                let ours =
                    sso::build_login_packet(&ctx, "wtlogin.trans_emp", &body_of("medium"), ty);
                if ty == 0 {
                    assert_eq!(ours, theirs, "type=0 明文包应逐字节一致");
                } else {
                    let key: &[u8] = if ty == 1 { &ctx.sig.d2key } else { &[0u8; 16] };
                    // [u32 长][u32 0x0A][u8 type][u32 4+len(d2)=8][d2 4][u8 0]
                    // [u32 4+len(uin)=9][uin 5] 之后是密文
                    assert_with_cipher(&ours, &theirs, 4 + 4 + 1 + 8 + 1 + 9, 0, key);
                }
                checked += 1;
            }
            other => panic!("未知向量 kind: {other}"),
        }
    }
    assert_eq!(checked, 11, "应覆盖 8 条 OICQ + 3 条登录层");
}

#[test]
fn uni_packet_matches_reference() {
    let v = load();
    let i = &v.uni.inputs;
    let theirs = hex::decode(&v.uni.pkt).unwrap();
    let body = hex::decode(&i.body).unwrap();
    let session = hex::decode(&i.session).unwrap();
    let d2key = hex::decode(&i.d2key).unwrap();

    let ours = uni::build(i.uin, &i.cmd, &body, i.seq, &session, &d2key).unwrap();
    let uin_len = i.uin.to_string().len();
    assert_with_cipher(&ours, &theirs, 18 + uin_len, 0, &d2key);

    // 结构自洽（不依赖向量）
    assert_eq!(
        u32::from_be_bytes([ours[0], ours[1], ours[2], ours[3]]) as usize,
        ours.len()
    );
    assert_eq!(
        u32::from_be_bytes([ours[4], ours[5], ours[6], ours[7]]),
        0x0B
    );
    assert_eq!(ours[8], 1);
    assert_eq!(
        u32::from_be_bytes([ours[9], ours[10], ours[11], ours[12]]),
        i.seq
    );
    assert_eq!(ours[13], 0);
    assert_eq!(
        u32::from_be_bytes([ours[14], ours[15], ours[16], ours[17]]) as usize,
        uin_len + 4
    );
    assert_eq!(&ours[18..18 + uin_len], i.uin.to_string().as_bytes());

    // 命令字与 body 可从密文还原出来
    let inner = qq_tea_decrypt(&ours[18 + uin_len..], &d2key).unwrap();
    let head_len = u32::from_be_bytes([inner[0], inner[1], inner[2], inner[3]]) as usize;
    let cmd_len = u32::from_be_bytes([inner[4], inner[5], inner[6], inner[7]]) as usize;
    assert_eq!(head_len, i.cmd.len() + 20);
    assert_eq!(
        String::from_utf8_lossy(&inner[8..8 + cmd_len - 4]),
        i.cmd.as_str()
    );
}

#[test]
fn tea_random_padding_round_trip_here() {
    // 顺带确认本 crate 依赖的 TEA 在新填充下仍旧自洽（避免跨 crate 语义漂移）
    let key = [0x11u8; 16];
    let ct = qq_tea_encrypt(b"hello world", &key, None).unwrap();
    assert_eq!(qq_tea_decrypt(&ct, &key).unwrap(), b"hello world");
}

#[test]
fn next_seq_wraps() {
    assert_eq!(uni::next_seq(1), 2);
    assert_eq!(uni::next_seq(0x7FFF), 1);
}
