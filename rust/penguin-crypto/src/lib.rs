//! penguin-crypto：QQ 协议用到的加密原语（Rust 移植）
//!
//! Dart 侧的对应实现：`lib/kernel/crypto/{tea,digest,ecdh}.dart`。
//! **行为一致性由黄金向量保证**：`vectors/crypto.json`（由
//! `analysis/scripts/export_vectors.cjs` 从可跑的参考实现与 Node crypto
//! 生成），测试见 `tests/vectors.rs`。
//!
//! * [`tea`]：QQ 变体 TEA——「填充 + 双链式 CBC」；规则曾用 oicq 的实际
//!   密文逐字节确认（Dart 侧的历史修正见 `tea.dart` 注释）。
//! * [`digest`]：MD5（guid/ksid 派生等用）。
//! * [`ecdh`]：prime256v1（NIST P-256）上的 ECDH；共享密钥
//!   = `MD5(secret[0..16])`（截断再 MD5）。

pub mod digest;
pub mod ecdh;
pub mod tea;
