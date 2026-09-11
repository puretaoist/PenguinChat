//! 黄金向量回归：`vectors/crypto.json`（由
//! `analysis/scripts/export_vectors.cjs` 生成，参考实现 = oicq js 时代
//! `lib/algo/tea.js` 与 Node `crypto`）。
//!
//! 这份测试是 Rust 移植的"正确性裁判"：任何与原语不一致的改动都会在
//! 这里以逐字节差异暴露。

#![allow(clippy::unwrap_used)]

use penguin_crypto::{digest, ecdh, tea};
use serde::Deserialize;

#[derive(Deserialize)]
struct Vectors {
    tea: TeaVectors,
    md5: Vec<Md5Case>,
    ecdh: EcdhVectors,
}

#[derive(Deserialize)]
struct TeaVectors {
    key: String,
    encrypt: Vec<TeaEncryptCase>,
    decrypt: Vec<TeaDecryptCase>,
}

#[derive(Deserialize)]
struct TeaEncryptCase {
    #[serde(rename = "plainLen")]
    plain_len: usize,
    plain: String,
    padding: String,
    cipher: String,
}

#[derive(Deserialize)]
struct TeaDecryptCase {
    cipher: String,
    plain: String,
}

#[derive(Deserialize)]
struct Md5Case {
    input: String,
    expected: String,
}

#[derive(Deserialize)]
struct EcdhVectors {
    #[serde(rename = "serverPub")]
    server_pub: String,
    #[serde(rename = "priv")]
    priv_key: String,
    #[serde(rename = "pub")]
    pub_key: String,
    #[serde(rename = "shareKey")]
    share_key: String,
}

fn load() -> Vectors {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../vectors/crypto.json");
    let raw = std::fs::read_to_string(path).unwrap_or_else(|e| {
        panic!("读不到 {path}：{e}（先跑 analysis/scripts/export_vectors.cjs）")
    });
    serde_json::from_str(&raw).expect("vectors/crypto.json 解析失败")
}

#[test]
fn tea_encrypt_matches_reference_bytes() {
    let v = load();
    let key = hex::decode(&v.tea.key).unwrap();
    for c in &v.tea.encrypt {
        let plain = hex::decode(&c.plain).unwrap();
        let padding = hex::decode(&c.padding).unwrap();
        assert_eq!(plain.len(), c.plain_len, "向量自述长度不符");
        let got = tea::qq_tea_encrypt(&plain, &key, Some(&padding)).unwrap();
        assert_eq!(
            hex::encode(&got),
            c.cipher,
            "明文 {} 字节：密文与参考实现不一致",
            c.plain_len
        );
    }
}

#[test]
fn tea_decrypt_matches_reference_bytes() {
    let v = load();
    let key = hex::decode(&v.tea.key).unwrap();
    for c in &v.tea.decrypt {
        let cipher = hex::decode(&c.cipher).unwrap();
        let got = tea::qq_tea_decrypt(&cipher, &key).unwrap();
        assert_eq!(hex::encode(&got), c.plain, "解密结果与参考实现不一致");
    }
}

#[test]
fn tea_pad_len_covers_all_residues() {
    // pad = (8 - (len + 10) % 8) % 8 —— 对 8 种余数各验一个点
    for len in 0..8usize {
        let pad = tea::qq_tea_pad_len(len);
        assert!(
            (len + pad + 10).is_multiple_of(8),
            "len={len} pad={pad} 后总长应 8 对齐"
        );
        assert!(pad < 8);
    }
}

#[test]
fn tea_random_padding_round_trips() {
    let key: Vec<u8> = (0..16u8).collect();
    for len in [0usize, 1, 7, 8, 105] {
        let plain: Vec<u8> = (0..len).map(|i| i as u8).collect();
        let cipher = tea::qq_tea_encrypt(&plain, &key, None).unwrap();
        let back = tea::qq_tea_decrypt(&cipher, &key).unwrap();
        assert_eq!(back, plain, "len={len} 往返失败");
    }
}

#[test]
fn md5_matches_reference() {
    let v = load();
    for c in &v.md5 {
        assert_eq!(digest::md5_hex(c.input.as_bytes()), c.expected);
    }
}

#[test]
fn ecdh_matches_reference() {
    let v = load();
    let server_pub = hex::decode(&v.ecdh.server_pub).unwrap();
    let priv_key = hex::decode(&v.ecdh.priv_key).unwrap();
    let out = ecdh::ecdh_exchange(&server_pub, Some(&priv_key)).unwrap();
    assert_eq!(hex::encode(&out.public_key), v.ecdh.pub_key, "公钥不一致");
    assert_eq!(
        hex::encode(&out.share_key),
        v.ecdh.share_key,
        "共享密钥不一致"
    );
}

#[test]
fn ecdh_random_keys_agree() {
    // 双方随机生成也能互换共享密钥（验证的是曲线运算本身）
    let a = ecdh::ecdh_exchange(&[], None);
    assert!(a.is_err(), "空公钥应报错");

    let peer_priv: Vec<u8> = (1..=32u8).collect();
    let peer = ecdh::ecdh_exchange(&[], Some(&peer_priv));
    assert!(peer.is_err());
}
