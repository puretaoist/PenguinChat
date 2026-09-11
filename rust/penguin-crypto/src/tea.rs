//! QQ 变体 TEA：裸分组 + 「填充 + 双链式 CBC」
//!
//! Dart 侧对应实现：`lib/kernel/crypto/tea.dart`（规则出处与历史修正
//! 都在那份注释里；本文件是其等价移植）。
//!
//! 关键点（不要按"标准 TEA/CBC"想当然）：
//!
//! ```text
//! 填充：pad = (8 - (len + 10) % 8) % 8；总长 = pad + len + 10
//! 布局：[ (rnd0 & 0xF8) | pad ][ pad 字节随机 ][ 2 字节随机 ][ 正文 ][ 7 个 0 ]
//! 加密链：B_i = P_i ^ C_{i-1}；C_i = E(B_i) ^ B_{i-1}   ← 第二项是标准 CBC 没有的
//! 解密链：B_i = D(C_i ^ B_{i-1})；P_i = B_i ^ C_{i-1}
//! ```
//!
//! 参考实现 `lib/algo/tea.js` 里 `(6 - len) >>> 0 再 % 8 + 2` 与上面的
//! `pad` 公式等价（由无符号回绕保证）。

use getrandom::getrandom;

/// TEA 的轮常量（每个分组 16 轮）。
pub const TEA_DELTA: u32 = 0x9E37_79B9;

/// 解密时的 sum 初值 = `TEA_DELTA * 16`。
pub const TEA_SUM_INIT: u32 = 0xE377_9B90;

#[derive(Debug, PartialEq, Eq)]
pub enum TeaError {
    /// 密钥必须是 16 字节。
    BadKeyLen(usize),
    /// 密文长度必须是 8 的倍数且 >= 16。
    BadCipherLen(usize),
    /// 注入的填充字节不够（需 `pad + 3` 字节）。
    PaddingTooShort { need: usize, got: usize },
    /// 尾部 7 字节应全为 0（完整性校验）。
    NonZeroTail,
    /// 填充长度读出来越界（报文损坏）。
    BadPadding,
}

impl std::fmt::Display for TeaError {
    fn fmt(&self, fmt: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TeaError::BadKeyLen(n) => write!(fmt, "TEA 密钥必须是 16 字节，实际 {n}"),
            TeaError::BadCipherLen(n) => {
                write!(fmt, "密文长度必须为 8 的倍数且 >= 16，实际 {n}")
            }
            TeaError::PaddingTooShort { need, got } => {
                write!(fmt, "填充字节不足：需 {need}，得 {got}")
            }
            TeaError::NonZeroTail => write!(fmt, "尾部校验失败：存在非零填充字节"),
            TeaError::BadPadding => write!(fmt, "填充长度非法，报文损坏"),
        }
    }
}

impl std::error::Error for TeaError {}

/// 填充长度：`(8 - (len + 10) % 8) % 8`。
pub fn qq_tea_pad_len(data_len: usize) -> usize {
    let r = (data_len + 10) % 8;
    if r == 0 {
        0
    } else {
        8 - r
    }
}

fn key_ints(key: &[u8]) -> Result<[u32; 4], TeaError> {
    if key.len() != 16 {
        return Err(TeaError::BadKeyLen(key.len()));
    }
    Ok([
        u32::from_be_bytes([key[0], key[1], key[2], key[3]]),
        u32::from_be_bytes([key[4], key[5], key[6], key[7]]),
        u32::from_be_bytes([key[8], key[9], key[10], key[11]]),
        u32::from_be_bytes([key[12], key[13], key[14], key[15]]),
    ])
}

/// 加密一个 64 位分组（16 轮，sum 从 0 起）。
pub fn tea_encrypt_block(v0: u32, v1: u32, k: [u32; 4]) -> (u32, u32) {
    let mut sum: u32 = 0;
    let (mut a, mut b) = (v0, v1);
    for _ in 0..16 {
        sum = sum.wrapping_add(TEA_DELTA);
        a = a.wrapping_add(
            ((b << 4).wrapping_add(k[0])) ^ (b.wrapping_add(sum)) ^ ((b >> 5).wrapping_add(k[1])),
        );
        b = b.wrapping_add(
            ((a << 4).wrapping_add(k[2])) ^ (a.wrapping_add(sum)) ^ ((a >> 5).wrapping_add(k[3])),
        );
    }
    (a, b)
}

/// 解密一个 64 位分组（16 轮，sum 从 `TEA_DELTA * 16` 递减）。
pub fn tea_decrypt_block(v0: u32, v1: u32, k: [u32; 4]) -> (u32, u32) {
    let mut sum: u32 = TEA_SUM_INIT;
    let (mut a, mut b) = (v0, v1);
    for _ in 0..16 {
        b = b.wrapping_sub(
            ((a << 4).wrapping_add(k[2])) ^ (a.wrapping_add(sum)) ^ ((a >> 5).wrapping_add(k[3])),
        );
        a = a.wrapping_sub(
            ((b << 4).wrapping_add(k[0])) ^ (b.wrapping_add(sum)) ^ ((b >> 5).wrapping_add(k[1])),
        );
        sum = sum.wrapping_sub(TEA_DELTA);
    }
    (a, b)
}

/// QQ TEA 加密（填充 + 双链式 CBC）。
///
/// `padding` 为 `Some` 时使用注入的确定性填充（测试/向量用，长度须为
/// `pad + 3`，首字节决定首字节高位——参考实现写死 `0xF8 | pad`）；
/// 为 `None` 时用系统随机源（生产路径）。
pub fn qq_tea_encrypt(
    plain: &[u8],
    key: &[u8],
    padding: Option<&[u8]>,
) -> Result<Vec<u8>, TeaError> {
    let k = key_ints(key)?;
    let len = plain.len();
    let pad = qq_tea_pad_len(len);
    let total = pad + len + 10;

    let mut buf = vec![0u8; total];
    let need = pad + 3;
    match padding {
        Some(p) => {
            if p.len() < need {
                return Err(TeaError::PaddingTooShort { need, got: p.len() });
            }
            buf[0] = (p[0] & 0xF8) | ((pad as u8) & 0x07);
            buf[1..=pad].copy_from_slice(&p[1..=pad]);
            buf[pad + 1] = p[pad + 1];
            buf[pad + 2] = p[pad + 2];
        }
        None => {
            let mut rnd = vec![0u8; need];
            getrandom(&mut rnd).expect("系统随机源不可用");
            buf[0] = (rnd[0] & 0xF8) | ((pad as u8) & 0x07);
            buf[1..=pad].copy_from_slice(&rnd[1..=pad]);
            buf[pad + 1] = rnd[pad + 1];
            buf[pad + 2] = rnd[pad + 2];
        }
    }
    buf[pad + 3..pad + 3 + len].copy_from_slice(plain);
    // 末尾 7 字节保持 0

    let mut out = vec![0u8; total];
    let (mut b_prev0, mut b_prev1) = (0u32, 0u32);
    let (mut c_prev0, mut c_prev1) = (0u32, 0u32);
    for off in (0..total).step_by(8) {
        let p0 = u32::from_be_bytes([buf[off], buf[off + 1], buf[off + 2], buf[off + 3]]);
        let p1 = u32::from_be_bytes([buf[off + 4], buf[off + 5], buf[off + 6], buf[off + 7]]);
        let b0 = p0 ^ c_prev0;
        let b1 = p1 ^ c_prev1;
        let (e0, e1) = tea_encrypt_block(b0, b1, k);
        let c0 = e0 ^ b_prev0;
        let c1 = e1 ^ b_prev1;
        out[off..off + 4].copy_from_slice(&c0.to_be_bytes());
        out[off + 4..off + 8].copy_from_slice(&c1.to_be_bytes());
        b_prev0 = b0;
        b_prev1 = b1;
        c_prev0 = c0;
        c_prev1 = c1;
    }
    Ok(out)
}

/// QQ TEA 解密。填充不合法或尾部校验失败时返回错误。
pub fn qq_tea_decrypt(cipher: &[u8], key: &[u8]) -> Result<Vec<u8>, TeaError> {
    let k = key_ints(key)?;
    let total = cipher.len();
    if !total.is_multiple_of(8) || total < 16 {
        return Err(TeaError::BadCipherLen(total));
    }

    // 先解首块取填充长度（首块的 B/C 前驱都是 0）
    let first0 = u32::from_be_bytes([cipher[0], cipher[1], cipher[2], cipher[3]]);
    let first1 = u32::from_be_bytes([cipher[4], cipher[5], cipher[6], cipher[7]]);
    let (f0, _f1) = tea_decrypt_block(first0, first1, k);
    let pad = (f0.to_be_bytes()[0] & 0x07) as usize;
    if total < pad + 10 {
        return Err(TeaError::BadPadding);
    }
    let data_len = total - pad - 10;

    let mut plain = vec![0u8; total];
    let (mut b_prev0, mut b_prev1) = (0u32, 0u32);
    let (mut c_prev0, mut c_prev1) = (0u32, 0u32);
    for off in (0..total).step_by(8) {
        let c0 = u32::from_be_bytes([
            cipher[off],
            cipher[off + 1],
            cipher[off + 2],
            cipher[off + 3],
        ]);
        let c1 = u32::from_be_bytes([
            cipher[off + 4],
            cipher[off + 5],
            cipher[off + 6],
            cipher[off + 7],
        ]);
        let (d0, d1) = tea_decrypt_block(c0 ^ b_prev0, c1 ^ b_prev1, k);
        let p0 = d0 ^ c_prev0;
        let p1 = d1 ^ c_prev1;
        plain[off..off + 4].copy_from_slice(&p0.to_be_bytes());
        plain[off + 4..off + 8].copy_from_slice(&p1.to_be_bytes());
        b_prev0 = d0;
        b_prev1 = d1;
        c_prev0 = c0;
        c_prev1 = c1;
    }

    // 尾部 7 字节必须为 0
    for &b in &plain[pad + 3 + data_len..total] {
        if b != 0 {
            return Err(TeaError::NonZeroTail);
        }
    }

    Ok(plain[pad + 3..pad + 3 + data_len].to_vec())
}
