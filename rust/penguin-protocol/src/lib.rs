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
//! * [`tlv`]：登录 TLV（48 条黄金向量，见 `vectors/tlv.json`）
//! * [`login`]：登录子命令 body 组装 + 响应解析（`0x119` 票据块）
//! * [`register`]：上线注册（`StatSvc.register`，JCE WUP 包装）
//! * [`tran`] / [`session`]：TCP 传输（tokio，4 字节分帧）与会话层（seq 配对、
//!   推送、注册与心跳）
//! * [`profiles`] / [`device`]：档案与设备（含按 uin 派生，`vectors/device.json`）

pub mod device;
pub mod jce;
pub mod login;
pub mod pb;
pub mod profiles;
pub mod recv;
pub mod register;
pub mod session;
pub mod sso;
pub mod tlv;
pub mod tran;
pub mod uni;
