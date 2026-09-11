//! UNI 包（业务包）——**登录成功之后所有请求的载体**。
//!
//! 对应 Dart 侧 `lib/kernel/wlogin8/qq8_sso.dart` 的 `Qq8Uni`；逐行移植自
//! 参考实现 oicq `lib/core/base-client.ts` 的 `buildUniPkt`。
//!
//! ```text
//! [u32 total（含自身）][u32 0x0B][u8 1][i32 seq][u8 0]
//! [u32 uinLen（含自身 4 字节）][uin ASCII][TEA(sso, d2key)]
//! ```
//!
//! 内层 SSO 块（TEA 解密后；与收包侧 `parseSSO` 对偶）：
//! `[u32 头长-4][u32 cmdLen+4][cmd][u32 8][session(4)][u32 4][u32 bodyLen+4][body]`
//!
//! ⚠️ 官方客户端的包编码在 native（`libcodecwrapperV2.so` 的 JNI），Java 层
//! 不可对照；本层以参考实现 + 服务端实测为准（详见 Dart 侧注释）。

use penguin_crypto::tea::qq_tea_encrypt;

#[derive(Debug, PartialEq)]
pub enum UniError {
    /// session 必须是 4 字节。
    BadSessionLen(usize),
}

impl std::fmt::Display for UniError {
    fn fmt(&self, fmt: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            UniError::BadSessionLen(n) => write!(fmt, "UNI 包的 session 必须是 4 字节（实得 {n}）"),
        }
    }
}

impl std::error::Error for UniError {}

/// 组装一个 UNI 包（自带长度头，可直接写给传输层）。
pub fn build(
    uin: u32,
    cmd: &str,
    body: &[u8],
    seq: u32,
    session: &[u8],
    d2key: &[u8],
) -> Result<Vec<u8>, UniError> {
    if session.len() != 4 {
        return Err(UniError::BadSessionLen(session.len()));
    }
    // 头部（第一个 u32 之后的部分）：cmdLen + 20（与收包侧 headlen 同义）
    let head_len = cmd.len() + 20;

    let mut inner = Vec::new();
    inner.extend_from_slice(&((head_len) as u32).to_be_bytes());
    inner.extend_from_slice(&((cmd.len() + 4) as u32).to_be_bytes());
    inner.extend_from_slice(cmd.as_bytes());
    inner.extend_from_slice(&8u32.to_be_bytes()); // session 字段长度（含自身）
    inner.extend_from_slice(session);
    inner.extend_from_slice(&4u32.to_be_bytes()); // 固定值
    inner.extend_from_slice(&((body.len() + 4) as u32).to_be_bytes());
    inner.extend_from_slice(body);

    let encrypted = qq_tea_encrypt(&inner, d2key, None).expect("TEA");
    let uin_bytes = uin.to_string().into_bytes();

    let mut out = Vec::new();
    out.extend_from_slice(&((encrypted.len() + uin_bytes.len() + 18) as u32).to_be_bytes());
    out.extend_from_slice(&0x0Bu32.to_be_bytes());
    out.push(1);
    out.extend_from_slice(&seq.to_be_bytes());
    out.push(0);
    out.extend_from_slice(&((uin_bytes.len() + 4) as u32).to_be_bytes());
    out.extend_from_slice(&uin_bytes);
    out.extend_from_slice(&encrypted);
    Ok(out)
}

/// 请求序号推进：`1..0x7FFF` 循环（对应 oicq 的 `FN_NEXT_SEQ`）。
pub fn next_seq(current: u32) -> u32 {
    let next = current + 1;
    if next >= 0x8000 {
        1
    } else {
        next
    }
}
