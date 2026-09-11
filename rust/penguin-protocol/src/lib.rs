//! penguin-protocol：QQ 协议内核（Rust 移植）
//!
//! Dart 侧对应实现：`lib/kernel/wlogin8/`。行为一致性由
//! `vectors/protocol.json` + `vectors/crypto.json` 的黄金向量保证
//! （生成器：`analysis/scripts/export_protocol_vectors.cjs`）。
//!
//! 已移植：
//! * [`jce`]：JCE 编解码 + WUP 包装（规则与官方 `JceOutputStream` /
//!   `RequestPacket` 逐条对照，对照表见 Dart 侧 `qq8_jce.dart` 头部）
//! * [`pb`]：最小 protobuf（varint / 长度分隔 / 嵌套 / 重复）
//! * [`recv`]：响应帧的外层拆壳（外壳 + SSO 头 → payload）
//! * [`sso`] / [`uni`]：登录/上线层信封与业务包（UNI 包）
//! * [`profiles`] / [`device`]：档案与设备的数据模型

pub mod device;
pub mod jce;
pub mod pb;
pub mod profiles;
pub mod recv;
pub mod sso;
pub mod uni;
