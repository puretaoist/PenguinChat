//! 最小 protobuf 编码（QQ 业务里用到的子集）
//!
//! Dart 侧对应实现：`lib/kernel/wlogin8/qq8_pb.dart`——规则对照参考实现
//! oicq `lib/algo/pb.js`（varint key + wiretype 0/1/2；列表=重复字段）。
//! 未覆盖 wiretype 1（fixed64）：现有业务里没有非整数，遇到时显式报错。

#[derive(Debug, PartialEq)]
pub enum PbError {
    UnsupportedValue(String),
}

impl std::fmt::Display for PbError {
    fn fmt(&self, fmt: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PbError::UnsupportedValue(s) => write!(fmt, "未支持的值: {s}"),
        }
    }
}

impl std::error::Error for PbError {}

/// protobuf 值。
#[derive(Debug, Clone, PartialEq)]
pub enum PbValue {
    Int(i64),
    Bool(bool),
    Str(String),
    Bytes(Vec<u8>),
    /// 重复字段（同一 tag 多次出现）。
    List(Vec<PbValue>),
    /// 嵌套消息。
    Nested(Vec<(i32, PbValue)>),
}

fn varint(out: &mut Vec<u8>, mut v: u64) {
    loop {
        let byte = (v & 0x7F) as u8;
        v >>= 7;
        if v == 0 {
            out.push(byte);
            return;
        }
        out.push(byte | 0x80);
    }
}

fn key(out: &mut Vec<u8>, tag: i32, wire: u8) {
    varint(out, ((tag as u64) << 3) | wire as u64);
}

fn write_value(out: &mut Vec<u8>, tag: i32, v: &PbValue) -> Result<(), PbError> {
    match v {
        PbValue::Bool(b) => write_value(out, tag, &PbValue::Int(if *b { 1 } else { 0 })),
        PbValue::Int(i) => {
            key(out, tag, 0);
            varint(out, *i as u64);
            Ok(())
        }
        PbValue::Str(s) => {
            key(out, tag, 2);
            varint(out, s.len() as u64);
            out.extend_from_slice(s.as_bytes());
            Ok(())
        }
        PbValue::Bytes(b) => {
            key(out, tag, 2);
            varint(out, b.len() as u64);
            out.extend_from_slice(b);
            Ok(())
        }
        PbValue::Nested(fields) => {
            let nested = encode(fields)?;
            key(out, tag, 2);
            varint(out, nested.len() as u64);
            out.extend_from_slice(&nested);
            Ok(())
        }
        PbValue::List(items) => {
            for item in items {
                write_value(out, tag, item)?;
            }
            Ok(())
        }
    }
}

/// 编码有序字段表（列表按重复字段展开）。
pub fn encode(fields: &[(i32, PbValue)]) -> Result<Vec<u8>, PbError> {
    let mut out = Vec::new();
    for (tag, v) in fields {
        write_value(&mut out, *tag, v)?;
    }
    Ok(out)
}
