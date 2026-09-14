//! 响应帧的外层拆壳（raw-TCP 路径）
//!
//! Dart 侧对应实现：`lib/kernel/wlogin8/qq8_recv.dart`——结构由 2026-09-11
//! 真机 dump（716 字节）逐字段核对：
//!
//! ```text
//! ① 外壳：[u32 magic=0x0A][u8 flag][u32 d2len][u8 uinLenField][uin] → 密文
//!          flag: 0=明文 / 1=TEA(d2key) / 2=TEA(全零)
//! ② SSO 头：u32 headlen / i32 seq / i32 retcode（非 0 抛错）
//!          / u32 ? / u32 cmdLen / cmd / u32 sessLen / session / i32 flag
//!          payload 起点 = headlen + 4
//! ```
//!
//! 非空 d2 的字段顺序尚无样本：遇到时显式报错，不猜。

use penguin_crypto::tea::qq_tea_decrypt;

#[derive(Debug, Clone, PartialEq)]
pub enum RecvError {
    TooShort(usize),
    BadMagic(u32),
    UnsupportedD2(usize),
    UnknownFlag(u8),
    MissingD2Key,
    /// SSO 返回码非 0。
    Retcode(i32),
    BadCmdLen(u32),
    UnsupportedCompression(i32),
    BadPayloadStart(u32),
    BadOuterLen {
        at: usize,
        total: usize,
    },
    Tea(String),
}

impl std::fmt::Display for RecvError {
    fn fmt(&self, fmt: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RecvError::TooShort(n) => write!(fmt, "响应太短（{n} 字节）"),
            RecvError::BadMagic(m) => write!(fmt, "响应外壳 magic=0x{m:x}（期望 0x0A）"),
            RecvError::UnsupportedD2(n) => {
                write!(fmt, "外壳里 d2 长度={n}：非空 d2 无样本，不猜")
            }
            RecvError::UnknownFlag(f) => write!(fmt, "未知的响应外壳 flag={f}"),
            RecvError::MissingD2Key => write!(fmt, "外壳 flag=1 需要 d2key，但当前没有"),
            RecvError::Retcode(r) => write!(fmt, "SSO 返回码非 0：retcode={r}"),
            RecvError::BadCmdLen(n) => write!(fmt, "SSO cmd 长度非法：{n}"),
            RecvError::UnsupportedCompression(f) => write!(fmt, "不支持的 SSO 压缩标志 flag={f}"),
            RecvError::BadPayloadStart(h) => write!(fmt, "SSO headlen={h} 使负载起点越界"),
            RecvError::BadOuterLen { at, total } => {
                write!(fmt, "外壳声明的 uin 长度超出报文（{at}/{total}）")
            }
            RecvError::Tea(e) => write!(fmt, "TEA 解密失败：{e}"),
        }
    }
}

impl std::error::Error for RecvError {}

/// 拆壳结果。
#[derive(Debug, Clone, PartialEq)]
pub struct SsoResponse {
    pub flag: u8,
    pub seq: i32,
    pub cmd: String,
    pub retcode: i32,
    pub payload: Vec<u8>,
}

/// 拆掉 ① 外壳 + ② SSO 头，返回可解析的负载。
pub fn unwrap_recv_payload(frame: &[u8], d2key: Option<&[u8]>) -> Result<Vec<u8>, RecvError> {
    Ok(unwrap_recv(frame, d2key)?.payload)
}

/// 与 [`unwrap_recv_payload`] 相同，但返回 SSO 头的元信息（诊断用）。
pub fn unwrap_recv(frame: &[u8], d2key: Option<&[u8]>) -> Result<SsoResponse, RecvError> {
    if frame.len() < 12 {
        return Err(RecvError::TooShort(frame.len()));
    }

    // ---------- ① 外壳 ----------
    let magic = u32::from_be_bytes([frame[0], frame[1], frame[2], frame[3]]);
    if magic != 0x0A {
        return Err(RecvError::BadMagic(magic));
    }
    let flag = frame[4];
    let d2_len = u32::from_be_bytes([frame[5], frame[6], frame[7], frame[8]]) as usize;
    if d2_len != 0 {
        return Err(RecvError::UnsupportedD2(d2_len));
    }
    let uin_len_field = frame[9] as usize;
    let uin_len = if uin_len_field >= 4 {
        uin_len_field - 4
    } else {
        uin_len_field
    };
    let ct_start = 10 + uin_len;
    if ct_start >= frame.len() {
        return Err(RecvError::BadOuterLen {
            at: ct_start,
            total: frame.len(),
        });
    }
    let ct = &frame[ct_start..];

    let plain = match flag {
        0 => ct.to_vec(),
        1 => {
            let key = d2key
                .filter(|k| !k.is_empty())
                .ok_or(RecvError::MissingD2Key)?;
            qq_tea_decrypt(ct, key).map_err(|e| RecvError::Tea(e.to_string()))?
        }
        2 => qq_tea_decrypt(ct, &[0u8; 16]).map_err(|e| RecvError::Tea(e.to_string()))?,
        other => return Err(RecvError::UnknownFlag(other)),
    };

    // ---------- ② SSO 头 ----------
    let u32_at = |off: usize| -> Option<u32> {
        if off + 4 > plain.len() {
            return None;
        }
        Some(u32::from_be_bytes([
            plain[off],
            plain[off + 1],
            plain[off + 2],
            plain[off + 3],
        ]))
    };
    let headlen = u32_at(0).ok_or(RecvError::TooShort(plain.len()))?;
    let seq = u32_at(4).ok_or(RecvError::TooShort(plain.len()))? as i32;
    let retcode = u32_at(8).ok_or(RecvError::TooShort(plain.len()))? as i32;
    if retcode != 0 {
        return Err(RecvError::Retcode(retcode));
    }

    let mut offset = u32_at(12).ok_or(RecvError::TooShort(plain.len()))? as usize + 12;
    let cmd_len = u32_at(offset).ok_or(RecvError::BadCmdLen(0))?;
    if cmd_len < 4 || offset + cmd_len as usize > plain.len() {
        return Err(RecvError::BadCmdLen(cmd_len));
    }
    let cmd = String::from_utf8_lossy(&plain[offset + 4..offset + cmd_len as usize]).into_owned();
    offset += cmd_len as usize;

    let sess_len = u32_at(offset).ok_or(RecvError::TooShort(plain.len()))? as usize;
    offset += sess_len;
    let compressed = u32_at(offset).ok_or(RecvError::TooShort(plain.len()))? as i32;

    let payload_start = match compressed {
        0 => headlen as usize + 4,
        8 => headlen as usize,
        1 => return Err(RecvError::UnsupportedCompression(1)),
        other => return Err(RecvError::UnsupportedCompression(other)),
    };
    if payload_start > plain.len() {
        return Err(RecvError::BadPayloadStart(headlen));
    }

    Ok(SsoResponse {
        flag,
        seq,
        cmd,
        retcode,
        payload: plain[payload_start..].to_vec(),
    })
}
