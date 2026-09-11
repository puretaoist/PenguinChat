//! SSO 包封装（登录 / 上线层信封），对应 Dart 侧
//! `lib/kernel/wlogin8/qq8_sso.dart`。
//!
//! 结构（三层）：
//!
//! ```text
//! [登录信封]  u32 长 ‖ 0x0A ‖ type ‖ d2 ‖ 0 ‖ uin ‖ [SSO 信封]
//! [SSO 信封]  seq / subid ×2 / BUF_UNKNOWN / tgt / cmd / session / imei / ksid
//!             type=1 用 d2key 加密；type=2 用全零密钥
//! [OICQ 信封] 0x02 ‖ u16 长 ‖ 8001 ‖ 0x810 ‖ 1 ‖ uin ‖ 3 ‖ enc ‖ 0 ‖ 2 ‖ 0 ‖ 0
//!             ‖ 0x02 0x01 ‖ randomKey ‖ 0x131 0x01 ‖ ECDH 公钥(TLV) ‖ TEA(body)
//! ```
//!
//! 逐行移植自参考实现 oicq（`lib/wtlogin/wt.js` 的 `_buildOICQPacket` /
//! `_buildLoginPacket`）；黄金向量见 `vectors/protocol.json`（生成器
//! `analysis/scripts/gen_sso_vectors.cjs`）。"u32 长"这一项**同时是传输层
//! 分帧头**，发送时原样写出（血泪注记见 Dart 侧 `qq8_tran.dart`）。

use crate::device::Device;
use crate::profiles::ApkInfo;
use penguin_crypto::tea::qq_tea_encrypt;

/// SSO 包头里的固定未知字段（oicq `BUF_UNKNOWN`）。
pub const BUF_UNKNOWN: [u8; 12] = [
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
];

pub const CMD_WT_LOGIN: u16 = 0x810;
pub const PROTOCOL_VERSION: u16 = 8001;

/// 登录信封的传输类型。
pub mod login_type {
    pub const HEARTBEAT: u8 = 0;
    pub const ONLINE: u8 = 1;
    pub const LOGIN: u8 = 2;
}

/// 票据集合（对应 oicq 的 `sig`）。
#[derive(Debug, Clone, Default)]
pub struct SigInfo {
    pub tgt: Vec<u8>,
    pub d2: Vec<u8>,
    pub d2key: Vec<u8>,
    pub sig_key: Vec<u8>,
    pub ticket_key: Vec<u8>,
    pub srm_token: Vec<u8>,
}

/// SSO 构包上下文。
#[derive(Debug, Clone)]
pub struct SsoContext {
    pub uin: u32,
    pub apk: ApkInfo,
    pub device: Device,
    pub session_id: Vec<u8>,
    pub random_key: Vec<u8>,
    pub ecdh_public_key: Vec<u8>,
    pub ecdh_share_key: Vec<u8>,
    pub sig: SigInfo,
    pub seq_id: u32,
}

impl SsoContext {
    /// ksid：`|<IMEI>|<apkName>`（**由设备与客户端名派生**，不是随机值）。
    pub fn ksid(&self) -> Vec<u8> {
        format!("|{}|{}", self.device.imei, self.apk.name).into_bytes()
    }
}

/// TLV 写法：**u16 长度（不含自身）+ 内容**（对应参考实现 writeTlv / Dart 侧 bytes16）。
fn tlv(out: &mut Vec<u8>, data: &[u8]) {
    out.extend_from_slice(&(data.len() as u16).to_be_bytes());
    out.extend_from_slice(data);
}

/// 长度前缀字节串，**长度字段包含它自己那 4 字节**。
fn with_length(out: &mut Vec<u8>, data: &[u8]) {
    out.extend_from_slice(&((data.len() + 4) as u32).to_be_bytes());
    out.extend_from_slice(data);
}

/// OICQ 层信封。
pub fn build_oicq_packet(ctx: &SsoContext, body: &[u8], emp: bool) -> Vec<u8> {
    let wrapped = if emp {
        // 设备锁 / 短信验证分支：TLV(sigKey) + TEA(body, ticketKey)
        let mut w = Vec::new();
        tlv(&mut w, &ctx.sig.sig_key);
        w.extend_from_slice(&qq_tea_encrypt(body, &ctx.sig.ticket_key, None).expect("TEA"));
        w
    } else {
        let mut w = Vec::new();
        w.push(0x02);
        w.push(0x01);
        w.extend_from_slice(&ctx.random_key);
        w.extend_from_slice(&0x131u16.to_be_bytes());
        w.extend_from_slice(&1u16.to_be_bytes());
        tlv(&mut w, &ctx.ecdh_public_key); // writeTlv
        w.extend_from_slice(&qq_tea_encrypt(body, &ctx.ecdh_share_key, None).expect("TEA"));
        w
    };

    let mut out = Vec::with_capacity(29 + wrapped.len() + 2 + 4);
    out.push(0x02);
    out.extend_from_slice(&((29 + wrapped.len()) as u16).to_be_bytes());
    out.extend_from_slice(&PROTOCOL_VERSION.to_be_bytes());
    out.extend_from_slice(&CMD_WT_LOGIN.to_be_bytes());
    out.extend_from_slice(&1u16.to_be_bytes()); // 常量
    out.extend_from_slice(&ctx.uin.to_be_bytes());
    out.push(3); // 常量
    out.push(if emp { 69 } else { 0x87 }); // 加密类型
    out.push(0); // 常量
    out.extend_from_slice(&2u32.to_be_bytes()); // 常量
    out.extend_from_slice(&0u32.to_be_bytes()); // 客户端版本
    out.extend_from_slice(&0u32.to_be_bytes()); // 常量
    out.extend_from_slice(&wrapped);
    out.push(0x03);
    out
}

/// 登录层信封（cmd 如 `wtlogin.login`；`ty` 见 [`login_type`]）。
pub fn build_login_packet(ctx: &SsoContext, cmd: &str, body: &[u8], ty: u8) -> Vec<u8> {
    let ksid = ctx.ksid();

    // 内层：SSO 信封
    let mut sso = Vec::new();
    sso.extend_from_slice(&ctx.seq_id.to_be_bytes());
    sso.extend_from_slice(&ctx.apk.subid.to_be_bytes());
    sso.extend_from_slice(&ctx.apk.subid.to_be_bytes());
    sso.extend_from_slice(&BUF_UNKNOWN);
    with_length(&mut sso, &ctx.sig.tgt);
    with_length(&mut sso, cmd.as_bytes());
    with_length(&mut sso, &ctx.session_id);
    with_length(&mut sso, ctx.device.imei.as_bytes());
    sso.extend_from_slice(&4u32.to_be_bytes());
    sso.extend_from_slice(&((ksid.len() + 2) as u16).to_be_bytes());
    sso.extend_from_slice(&ksid);
    sso.extend_from_slice(&4u32.to_be_bytes());

    let mut outer_sso = Vec::new();
    with_length(&mut outer_sso, &sso);
    with_length(&mut outer_sso, body);

    let mut sso = outer_sso;
    if ty == login_type::ONLINE {
        sso = qq_tea_encrypt(&sso, &ctx.sig.d2key, None).expect("TEA");
    } else if ty == login_type::LOGIN {
        sso = qq_tea_encrypt(&sso, &[0u8; 16], None).expect("TEA");
    }

    // 外层：登录信封
    let mut outer = Vec::new();
    outer.extend_from_slice(&0x0Au32.to_be_bytes());
    outer.push(ty);
    with_length(&mut outer, &ctx.sig.d2);
    outer.push(0);
    with_length(&mut outer, ctx.uin.to_string().as_bytes());
    outer.extend_from_slice(&sso);

    let mut out = Vec::new();
    with_length(&mut out, &outer);
    out
}
