//! JCE 编解码（WUP 的数据层）
//!
//! Dart 侧对应实现：`lib/kernel/wlogin8/qq8_jce.dart`——规则与官方 8.9.50
//! `com.qq.taf.jce.JceOutputStream` / `com.qq.taf.RequestPacket` 逐条对照过
//! （对照表在那份注释里，本文件是其等价移植）。
//!
//! 值模型比 Dart 版多一个 [`JceValue::Struct`]（Dart 用 Map 兼表结构体，
//! 导致"解码后再编码"在结构体层会退化成 MAP；这里区分开，往返更精确）。

use std::collections::BTreeMap;

pub const T_INT8: u8 = 0;
pub const T_INT16: u8 = 1;
pub const T_INT32: u8 = 2;
pub const T_INT64: u8 = 3;
pub const T_FLOAT: u8 = 4;
pub const T_DOUBLE: u8 = 5;
pub const T_STRING1: u8 = 6;
pub const T_STRING4: u8 = 7;
pub const T_MAP: u8 = 8;
pub const T_LIST: u8 = 9;
pub const T_STRUCT_BEGIN: u8 = 10;
pub const T_STRUCT_END: u8 = 11;
pub const T_ZERO: u8 = 12;
pub const T_SIMPLE_LIST: u8 = 13;

#[derive(Debug, PartialEq)]
pub enum JceError {
    /// tag 超出 255（官方上限）。
    TagTooLarge(i32),
    /// 不支持的值类型。
    UnsupportedValue(String),
    /// 解码越界。
    Truncated,
    /// 未知类型标签。
    UnknownType(u8),
    /// 应为结构体结束符却没读到。
    MissingStructEnd,
}

impl std::fmt::Display for JceError {
    fn fmt(&self, fmt: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            JceError::TagTooLarge(t) => write!(fmt, "tag 超出范围: {t}（官方上限 255）"),
            JceError::UnsupportedValue(s) => write!(fmt, "不支持的值: {s}"),
            JceError::Truncated => write!(fmt, "解码越界：报文不完整"),
            JceError::UnknownType(t) => write!(fmt, "未知的 JCE 类型: {t}"),
            JceError::MissingStructEnd => write!(fmt, "结构体缺少结束符"),
        }
    }
}

impl std::error::Error for JceError {}

/// JCE 值。
#[derive(Debug, Clone, PartialEq)]
pub enum JceValue {
    Int(i64),
    Double(f64),
    Str(String),
    Bytes(Vec<u8>),
    List(Vec<JceValue>),
    /// 映射（键值对按插入顺序保留）。
    Map(Vec<(JceValue, JceValue)>),
    /// 结构体（tag → 值；解码 STRUCT_BEGIN…END 得到）。
    Struct(BTreeMap<i32, JceValue>),
    /// 嵌套结构体的原始字节（编码用：写成 BEGIN…END）。
    Nested(Vec<u8>),
}

/// 有序字段表（tag → 值）。调用方不插入即等于 Dart 侧的 `null`（跳过）。
pub type JceStruct = Vec<(i32, JceValue)>;

fn write_head(out: &mut Vec<u8>, ty: u8, tag: i32) -> Result<(), JceError> {
    if tag < 15 {
        out.push(ty | ((tag as u8) << 4));
    } else if tag < 256 {
        out.push(ty | 0xF0);
        out.push(tag as u8);
    } else {
        return Err(JceError::TagTooLarge(tag));
    }
    Ok(())
}

fn write_value(out: &mut Vec<u8>, tag: i32, v: &JceValue) -> Result<(), JceError> {
    match v {
        JceValue::Nested(data) => {
            write_head(out, T_STRUCT_BEGIN, tag)?;
            out.extend_from_slice(data);
            write_head(out, T_STRUCT_END, 0)?;
        }
        JceValue::Int(i) => {
            let i = *i;
            if i == 0 {
                write_head(out, T_ZERO, tag)?;
            } else if (-128..=127).contains(&i) {
                write_head(out, T_INT8, tag)?;
                out.push((i & 0xFF) as u8);
            } else if (-32768..=32767).contains(&i) {
                write_head(out, T_INT16, tag)?;
                out.extend_from_slice(&((i & 0xFFFF) as u16).to_be_bytes());
            } else if (-2147483648..=2147483647).contains(&i) {
                write_head(out, T_INT32, tag)?;
                out.extend_from_slice(&((i & 0xFFFFFFFF) as u32).to_be_bytes());
            } else {
                write_head(out, T_INT64, tag)?;
                out.extend_from_slice(&(i as u64).to_be_bytes());
            }
        }
        JceValue::Double(d) => {
            write_head(out, T_DOUBLE, tag)?;
            out.extend_from_slice(&d.to_be_bytes());
        }
        JceValue::Str(s) => {
            let b = s.as_bytes();
            if b.len() > 0xFF {
                write_head(out, T_STRING4, tag)?;
                out.extend_from_slice(&(b.len() as u32).to_be_bytes());
            } else {
                write_head(out, T_STRING1, tag)?;
                out.push(b.len() as u8);
            }
            out.extend_from_slice(b);
        }
        JceValue::Bytes(b) => {
            write_head(out, T_SIMPLE_LIST, tag)?;
            write_head(out, 0, 0)?;
            write_value(out, 0, &JceValue::Int(b.len() as i64))?;
            out.extend_from_slice(b);
        }
        JceValue::List(items) => {
            write_head(out, T_LIST, tag)?;
            write_value(out, 0, &JceValue::Int(items.len() as i64))?;
            for item in items {
                write_value(out, 0, item)?;
            }
        }
        JceValue::Map(entries) => {
            write_head(out, T_MAP, tag)?;
            write_value(out, 0, &JceValue::Int(entries.len() as i64))?;
            for (k, val) in entries {
                write_value(out, 0, k)?;
                write_value(out, 1, val)?;
            }
        }
        JceValue::Struct(fields) => {
            // 与 Dart 版一致：直接当 MAP 写（结构体语义由 Nested 承担）
            let entries: Vec<(JceValue, JceValue)> = fields
                .iter()
                .map(|(k, val)| (JceValue::Int(*k as i64), val.clone()))
                .collect();
            write_value(out, tag, &JceValue::Map(entries))?;
        }
    }
    Ok(())
}

/// 编码有序字段表（不写 `null`——调用方不插入即可）。
pub fn encode(fields: &[(i32, JceValue)]) -> Result<Vec<u8>, JceError> {
    let mut out = Vec::new();
    for (tag, v) in fields {
        write_value(&mut out, *tag, v)?;
    }
    Ok(out)
}

/// 编码结构体：tag 0 的 `STRUCT_BEGIN … STRUCT_END`。
pub fn encode_struct(fields: &[(i32, JceValue)]) -> Result<Vec<u8>, JceError> {
    let inner = encode(fields)?;
    encode(&[(0, JceValue::Nested(inner))])
}

/// WUP 请求包装（官方 `RequestPacket.writeTo` 的十字段）。
pub fn encode_wrapper(
    service: &str,
    method: &str,
    attributes: &[(String, Vec<u8>)],
) -> Result<Vec<u8>, JceError> {
    let attr_entries: Vec<(JceValue, JceValue)> = attributes
        .iter()
        .map(|(k, v)| (JceValue::Str(k.clone()), JceValue::Bytes(v.clone())))
        .collect();
    let payload = encode(&[(0, JceValue::Map(attr_entries))])?;
    encode(&[
        (1, JceValue::Int(3)), // iVersion
        (2, JceValue::Int(0)), // cPacketType
        (3, JceValue::Int(0)), // iMessageType
        (4, JceValue::Int(0)), // iRequestId
        (5, JceValue::Str(service.to_string())),
        (6, JceValue::Str(method.to_string())),
        (7, JceValue::Bytes(payload)),
        (8, JceValue::Int(0)),
        (9, JceValue::Map(Vec::new())),
        (10, JceValue::Map(Vec::new())),
    ])
}

// ------------------------------------------------------------------
// 解码
// ------------------------------------------------------------------

struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], JceError> {
        if self.pos + n > self.buf.len() {
            return Err(JceError::Truncated);
        }
        let s = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }

    fn u8(&mut self) -> Result<u8, JceError> {
        Ok(self.take(1)?[0])
    }

    /// 读头（类型 + tag）；SIMPLE_LIST 的内层标记位也用它（只读头不读体）。
    fn head(&mut self) -> Result<(u8, i32), JceError> {
        let b = self.u8()?;
        let ty = b & 0x0F;
        let mut tag = ((b & 0xF0) >> 4) as i32;
        if tag == 15 {
            tag = self.u8()? as i32;
        }
        Ok((ty, tag))
    }

    fn body(&mut self, ty: u8) -> Result<JceValue, JceError> {
        match ty {
            T_ZERO => Ok(JceValue::Int(0)),
            T_INT8 => Ok(JceValue::Int(self.u8()? as i8 as i64)),
            T_INT16 => {
                let b = self.take(2)?;
                Ok(JceValue::Int(i16::from_be_bytes([b[0], b[1]]) as i64))
            }
            T_INT32 => {
                let b = self.take(4)?;
                Ok(JceValue::Int(
                    i32::from_be_bytes([b[0], b[1], b[2], b[3]]) as i64
                ))
            }
            T_INT64 => {
                let b = self.take(8)?;
                Ok(JceValue::Int(i64::from_be_bytes([
                    b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                ])))
            }
            T_FLOAT => {
                let b = self.take(4)?;
                Ok(JceValue::Double(
                    f32::from_be_bytes([b[0], b[1], b[2], b[3]]) as f64,
                ))
            }
            T_DOUBLE => {
                let b = self.take(8)?;
                Ok(JceValue::Double(f64::from_be_bytes([
                    b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                ])))
            }
            T_STRING1 => {
                let n = self.u8()? as usize;
                let b = self.take(n)?;
                Ok(JceValue::Str(String::from_utf8_lossy(b).into_owned()))
            }
            T_STRING4 => {
                let b = self.take(4)?;
                let n = u32::from_be_bytes([b[0], b[1], b[2], b[3]]) as usize;
                let s = self.take(n)?;
                Ok(JceValue::Str(String::from_utf8_lossy(s).into_owned()))
            }
            T_SIMPLE_LIST => {
                let _ = self.head()?; // 内层标记位（类型 0、tag 0，无体）
                let n = match self.element()?.1 {
                    JceValue::Int(i) => i as usize,
                    _ => return Err(JceError::Truncated),
                };
                Ok(JceValue::Bytes(self.take(n)?.to_vec()))
            }
            T_LIST => {
                let n = match self.element()?.1 {
                    JceValue::Int(i) => i as usize,
                    _ => return Err(JceError::Truncated),
                };
                let mut items = Vec::with_capacity(n);
                for _ in 0..n {
                    items.push(self.element()?.1);
                }
                Ok(JceValue::List(items))
            }
            T_MAP => {
                let n = match self.element()?.1 {
                    JceValue::Int(i) => i as usize,
                    _ => return Err(JceError::Truncated),
                };
                let mut entries = Vec::with_capacity(n);
                for _ in 0..n {
                    let k = self.element()?.1;
                    let v = self.element()?.1;
                    entries.push((k, v));
                }
                Ok(JceValue::Map(entries))
            }
            T_STRUCT_BEGIN => {
                let mut fields = BTreeMap::new();
                loop {
                    let (ty, tag) = self.head()?;
                    if ty == T_STRUCT_END {
                        break;
                    }
                    fields.insert(tag, self.body(ty)?);
                }
                Ok(JceValue::Struct(fields))
            }
            T_STRUCT_END => Err(JceError::MissingStructEnd),
            other => Err(JceError::UnknownType(other)),
        }
    }

    fn element(&mut self) -> Result<(i32, JceValue), JceError> {
        let (ty, tag) = self.head()?;
        Ok((tag, self.body(ty)?))
    }
}

/// 解码为 `tag → 值`。
pub fn decode(blob: &[u8]) -> Result<BTreeMap<i32, JceValue>, JceError> {
    let mut r = Reader { buf: blob, pos: 0 };
    let mut out = BTreeMap::new();
    while r.pos < blob.len() {
        let (tag, v) = r.element()?;
        out.insert(tag, v);
    }
    Ok(out)
}

/// 响应侧便捷解码：WUP 包装 → `sBuffer(7)` → 属性表 → 第一个属性 → 结构字段。
pub fn decode_wrapper(blob: &[u8]) -> Result<BTreeMap<i32, JceValue>, JceError> {
    let wrapper = decode(blob)?;
    let payload = match wrapper.get(&7) {
        Some(JceValue::Bytes(b)) => b.clone(),
        _ => {
            return Err(JceError::UnsupportedValue(
                "WUP 包装里没有 sBuffer(7)".into(),
            ))
        }
    };
    let attrs = decode(&payload)?;
    let attr_map = match attrs.get(&0) {
        Some(JceValue::Map(m)) if !m.is_empty() => m.clone(),
        _ => {
            return Err(JceError::UnsupportedValue(
                "WUP 属性表为空或类型不对".into(),
            ))
        }
    };
    let mut nested = attr_map[0].1.clone();
    if let JceValue::Map(m) = &nested {
        if !m.is_empty() {
            nested = m[0].1.clone();
        }
    }
    let nested_bytes = match nested {
        JceValue::Bytes(b) => b,
        _ => {
            return Err(JceError::UnsupportedValue(
                "属性表里的结构不是字节数组".into(),
            ))
        }
    };
    let fields = decode(&nested_bytes)?;
    Ok(match fields.get(&0) {
        Some(JceValue::Struct(s)) => s.clone(),
        _ => fields,
    })
}
