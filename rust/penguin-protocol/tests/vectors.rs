//! 协议层黄金向量回归：`vectors/protocol.json` + `vectors/crypto.json` 的
//! recv 部分（生成器：`analysis/scripts/export_protocol_vectors.cjs`）。
//!
//! 断言口径与 Dart 侧自测一致：**能逐字节比的都逐字节比**；
//! 结构体走"解码 → 再编码 → 与参考字节一致"的往返。

#![allow(clippy::unwrap_used)]

use penguin_protocol::jce::{self, JceValue};
use penguin_protocol::pb::{self, PbValue};
use penguin_protocol::recv;
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Deserialize)]
struct Protocol {
    jce: JcePart,
    pb: PbPart,
    recv: Option<RecvPart>,
}

#[derive(Deserialize)]
struct JcePart {
    golden: JceGolden,
    diff: Vec<DiffCase>,
}

#[derive(Deserialize)]
struct JceGolden {
    #[serde(rename = "structA")]
    struct_a: String,
    #[serde(rename = "wrapperB")]
    wrapper_b: String,
}

#[derive(Deserialize)]
struct DiffCase {
    name: String,
    hex: String,
}

#[derive(Deserialize)]
struct PbPart {
    ts: i64,
    blob: String,
}

#[derive(Deserialize)]
struct RecvPart {
    frame: String,
}

fn load() -> Protocol {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../vectors/protocol.json");
    let raw = std::fs::read_to_string(path).unwrap_or_else(|e| {
        panic!("读不到 {path}：{e}（先跑 analysis/scripts/export_protocol_vectors.cjs）")
    });
    serde_json::from_str(&raw).expect("vectors/protocol.json 解析失败")
}

fn to_fields(v: &JceValue) -> BTreeMap<i32, JceValue> {
    match v {
        JceValue::Struct(s) => s.clone(),
        _ => panic!("期望结构体"),
    }
}

/// BTreeMap → 有序字段表（编码入口要 `&[(i32, JceValue)]`）。
fn as_fields(m: &BTreeMap<i32, JceValue>) -> Vec<(i32, JceValue)> {
    m.iter().map(|(k, v)| (*k, v.clone())).collect()
}

#[test]
fn jce_struct_decode_and_round_trip() {
    let v = load();
    let bytes = hex::decode(&v.jce.golden.struct_a).unwrap();
    let top = jce::decode(&bytes).unwrap();
    let fields = to_fields(top.get(&0).expect("顶层应是 tag0 结构体"));

    // 逐字段核对（与 Dart 侧自测同一批断言）
    assert_eq!(fields[&1], JceValue::Int(0));
    assert_eq!(fields[&2], JceValue::Int(1));
    assert_eq!(fields[&3], JceValue::Int(-1));
    assert_eq!(fields[&4], JceValue::Int(200));
    assert_eq!(fields[&5], JceValue::Int(70000));
    assert_eq!(fields[&6], JceValue::Int(5000000000));
    assert_eq!(fields[&7], JceValue::Str("hello".into()));
    match &fields[&8] {
        JceValue::Str(s) => assert_eq!(s.len(), 300, "STRING4 长度"),
        other => panic!("字段 8 应为字符串，实为 {other:?}"),
    }
    assert_eq!(fields[&9], JceValue::Bytes(vec![1, 2, 3]));
    match &fields[&10] {
        JceValue::List(items) => {
            assert_eq!(items.len(), 3);
            assert_eq!(items[0], JceValue::Int(1));
            assert_eq!(items[1], JceValue::Str("a".into()));
            assert_eq!(items[2], JceValue::Bytes(vec![9]));
        }
        other => panic!("字段 10 应为列表，实为 {other:?}"),
    }
    match &fields[&11] {
        JceValue::Map(entries) => {
            assert_eq!(entries.len(), 2);
            assert_eq!(entries[0].0, JceValue::Str("0".into()));
            assert_eq!(entries[0].1, JceValue::Str("zero".into()));
            assert_eq!(entries[1].0, JceValue::Str("1".into()));
            assert_eq!(entries[1].1, JceValue::Int(2));
        }
        other => panic!("字段 11 应为映射，实为 {other:?}"),
    }
    assert!(!fields.contains_key(&12), "null 字段不应出现在解码结果里");
    assert_eq!(fields[&13], JceValue::Double(3.5));

    // 往返：解码 → 再编码逐字节一致
    let re = jce::encode_struct(&as_fields(&fields)).unwrap();
    assert_eq!(
        hex::encode(&re),
        v.jce.golden.struct_a,
        "结构体往返字节不一致"
    );

    // 独立校验：Dart 侧同为 382 字节
    assert_eq!(bytes.len(), 382);
}

#[test]
fn jce_wrapper_round_trip() {
    let v = load();
    let bytes = hex::decode(&v.jce.golden.wrapper_b).unwrap();

    let wrapper = jce::decode(&bytes).unwrap();
    assert_eq!(wrapper[&5], JceValue::Str("PushService".into()));
    assert_eq!(wrapper[&6], JceValue::Str("SvcReqRegister".into()));

    // 属性名从包装里读出来（而不是硬编码）
    let payload = match &wrapper[&7] {
        JceValue::Bytes(b) => b.clone(),
        other => panic!("field 7 应为字节数组，实为 {other:?}"),
    };
    let attrs = jce::decode(&payload).unwrap();
    let (name, struct_bytes) = match &attrs[&0] {
        JceValue::Map(entries) => match (&entries[0].0, &entries[0].1) {
            (JceValue::Str(n), JceValue::Bytes(b)) => (n.clone(), b.clone()),
            other => panic!("属性表元素异常：{other:?}"),
        },
        other => panic!("属性表应为映射，实为 {other:?}"),
    };
    assert_eq!(name, "SvcReqRegister");

    // 往返：把解出来的结构再包一遍，逐字节还原
    let fields = to_fields(
        jce::decode(&struct_bytes)
            .unwrap()
            .get(&0)
            .expect("属性结构应为 tag0"),
    );
    let struct_again = jce::encode_struct(&as_fields(&fields)).unwrap();
    let wrapper_again =
        jce::encode_wrapper("PushService", "SvcReqRegister", &[(name, struct_again)]).unwrap();
    assert_eq!(
        hex::encode(&wrapper_again),
        v.jce.golden.wrapper_b,
        "WUP 包装往返字节不一致"
    );

    // decode_wrapper 也应拿到同一批字段
    let via_helper = jce::decode_wrapper(&bytes).unwrap();
    assert_eq!(via_helper[&7], JceValue::Str("hello".into()));
}

#[test]
fn jce_diff_cases_round_trip() {
    let v = load();
    for c in &v.jce.diff {
        let bytes = hex::decode(&c.hex).unwrap();
        let top = jce::decode(&bytes).unwrap_or_else(|e| panic!("{}: 解码失败 {e}", c.name));
        let fields = to_fields(top.get(&0).unwrap_or_else(|| panic!("{}: 缺 tag0", c.name)));
        let re = jce::encode_struct(&as_fields(&fields)).unwrap();
        assert_eq!(hex::encode(&re), c.hex, "{}：往返字节不一致", c.name);
    }
}

#[test]
fn pb_register_blob_matches_reference() {
    let v = load();
    let buf9 = {
        // 参考实现的 hb480 同款构造：9 字节 [u32 uin][1 字节空洞][u32 0x19e39]
        let mut b = vec![0u8; 9];
        b[0..4].copy_from_slice(&10001u32.to_be_bytes());
        b[5..9].copy_from_slice(&0x19e39u32.to_be_bytes());
        b
    };
    // 注册体里的那个 blob：{1: [{1:46, 2:ts}, {1:283, 2:0}]}
    let blob = pb::encode(&[(
        1,
        PbValue::List(vec![
            PbValue::Nested(vec![(1, PbValue::Int(46)), (2, PbValue::Int(v.pb.ts))]),
            PbValue::Nested(vec![(1, PbValue::Int(283)), (2, PbValue::Int(0))]),
        ]),
    )])
    .unwrap();
    assert_eq!(hex::encode(&blob), v.pb.blob, "pb blob 与参考实现不一致");
    assert_eq!(blob.len(), 18);

    // 顺带把心跳 body 的形状也验一遍（pb {1:1152, 2:9, 4:buf}）
    let hb = pb::encode(&[
        (1, PbValue::Int(1152)),
        (2, PbValue::Int(9)),
        (4, PbValue::Bytes(buf9.clone())),
    ])
    .unwrap();
    assert_eq!(hb[0], 0x08, "field1 wiretype 0 的 key 字节");
    assert_eq!(hb[1], 0x80);
    assert_eq!(hb[2], 0x09, "1152 的 varint 第二字节");
}

#[test]
fn recv_unwraps_real_dump() {
    let v = load();
    let recv_part = v.recv.expect("protocol.json 里应有 recv（脱敏真机响应）");
    let frame = hex::decode(&recv_part.frame).unwrap();
    assert_eq!(frame.len(), 711, "脱敏版长度");

    let r = recv::unwrap_recv(&frame, None).unwrap();
    assert_eq!(r.flag, 2, "外壳 flag（TEA 全零）");
    assert_eq!(r.seq, 32150, "SSO seq 与真机一致");
    assert_eq!(r.cmd, "wtlogin.login");
    assert_eq!(r.retcode, 0);
    assert_eq!(r.payload.len(), 617);
    assert_eq!((r.payload.len() - 17) % 8, 0, "内层密文 8 对齐");
    assert_eq!(
        hex::encode(&r.payload[0..9]),
        "0202691f4108100001",
        "负载头部前 9 字节"
    );
    assert_eq!(
        r.payload[13] as u32 * 256 + r.payload[14] as u32,
        0,
        "rsp flag"
    );
    assert_eq!(*r.payload.last().unwrap(), 3, "负载尾字节");
}

#[test]
fn recv_rejects_bad_frames() {
    // 太短
    assert!(recv::unwrap_recv(&[0u8; 8], None).is_err());
    // magic 不对
    let mut bad = vec![0u8; 32];
    bad[3] = 0x0B;
    assert!(matches!(
        recv::unwrap_recv(&bad, None),
        Err(recv::RecvError::BadMagic(_))
    ));
    // 非空 d2：显式拒绝
    let mut with_d2 = vec![0u8; 32];
    with_d2[3] = 0x0A;
    with_d2[8] = 1;
    assert!(matches!(
        recv::unwrap_recv(&with_d2, None),
        Err(recv::RecvError::UnsupportedD2(1))
    ));
}

#[allow(dead_code)]
fn _assert_types(_: BTreeMap<i32, JceValue>) {}
