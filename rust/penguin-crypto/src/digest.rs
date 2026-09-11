//! MD5（guid / ksid 派生等用）。
//!
//! Dart 侧对应实现：`lib/kernel/crypto/digest.dart`（其 `md5Bytes` 与
//! 标准 MD5 一致，标准向量见 `tool/qq8_selftest.dart`）。

use md5::{Digest, Md5};

/// 计算 MD5，返回 16 字节。
pub fn md5_bytes(data: &[u8]) -> [u8; 16] {
    let out = Md5::digest(data);
    let mut arr = [0u8; 16];
    arr.copy_from_slice(&out);
    arr
}

/// 计算 MD5 并转小写 hex（诊断/测试用）。
pub fn md5_hex(data: &[u8]) -> String {
    let mut s = String::with_capacity(32);
    for b in md5_bytes(data) {
        s.push_str(&format!("{b:02x}"));
    }
    s
}
