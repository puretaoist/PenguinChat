//! 登录主流程：子命令 body 组装 + 响应解析，对应 Dart 侧
//! `lib/kernel/wlogin8/qq8_login.dart`。
//!
//! ## 报文结构
//!
//! ```text
//!   [传输层]      u32 总长（含自身 4 字节）
//!   [登录信封]    u32 长 ‖ 0x0A ‖ type ‖ d2 ‖ uin ‖ …
//!   [SSO 信封]    seq ‖ subid ‖ BUF_UNKNOWN ‖ tgt ‖ cmd ‖ session ‖ imei ‖ ksid
//!   [登录 body]   u16 子命令 ‖ u16 TLV 个数 ‖ TLV…    ← 本文件
//! ```
//!
//! 响应反向解（外层拆壳见 [`crate::recv`]）：
//!
//! ```text
//!   payload[16 : len-1]  --TEA(share_key)-->  u16 ‖ u8 type ‖ u16 ‖ TLV…
//! ```
//!
//! 来源：oicq `lib/wtlogin/wt.js`（`sendLogin` / `_decodeLoginResponse` /
//! `readTlv` / `decodeT119`）。响应侧每个关键偏移都与官方 9.3.60 反编译
//! 逐行核过（对照表见 Dart 侧同名文件头注释）：只解 `[16, len-1)`、
//! 类型 = 明文第 2 字节、TLV 从明文偏移 5 起、`0x119` 用 tgtgt 再解一层、
//! 其子 TLV 从偏移 2 起、TLV 容器是裸 `tag‖len‖body` 序列。

use crate::tlv::{pack, TlvArg, TlvContext, TlvError, EXCHANGE_EMP_TLV_ORDER, SLIDER_TLV_ORDER};
use penguin_crypto::tea::{qq_tea_decrypt, TeaError};

/// 登录 body 里的子命令（官方 `oicq.wlogin_sdk.request.k/u` 的 `this.u`）。
pub mod sub_cmd {
    pub const PASSWORD: u16 = 9;
    pub const SLIDER: u16 = 2;
    pub const SUBMIT_SMS: u16 = 7;
    pub const SEND_SMS: u16 = 8;
    pub const TOKEN: u16 = 11;
    pub const DEVICE: u16 = 20;
}

/// 登录响应第 3 字节的类型（官方 `oicq_request.c()` 里的 `iB`）。
pub mod result_type {
    /// 成功；走 `c()` 的 `iB == 0` 分支解析 `0x119` 票据块。
    pub const SUCCESS: u8 = 0;
    /// 需要滑动验证码；`iB == 2` 分支取 `0x104`（新盐）与 `0x192`（验证地址）。
    pub const SLIDER: u8 = 2;
    /// 设备锁 / 需要二次验证；`case 204:`（日志里写作 `type = 0xcc`）。
    pub const DEVICE_LOCK: u8 = 204;
}

/// 登录流程错误。
#[derive(Debug, PartialEq)]
pub enum LoginError {
    /// 响应比 `16 头 + 1 尾 + 5 明文` 还短。
    TooShort(usize),
    /// 响应解密失败（密钥不对或报文损坏）。
    Decrypt(TeaError),
    /// 解密后明文短于 5 字节。
    PlainTooShort(usize),
    /// TLV 声明长度超出剩余字节。
    TlvTruncated {
        tag: u16,
        len: u16,
        remaining: usize,
    },
    /// 滑动验证提交缺少盐（`ctx.t104` 为空）。
    MissingSalt,
    /// 滑动验证 ticket 为空。
    EmptyTicket,
    /// 组包期错误（未知 TLV 等）。
    Tlv(TlvError),
}

impl std::fmt::Display for LoginError {
    fn fmt(&self, fmt: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LoginError::TooShort(n) => write!(fmt, "响应太短（{n} 字节，至少 22）"),
            LoginError::Decrypt(e) => write!(fmt, "响应解密失败（密钥不对或报文损坏）：{e}"),
            LoginError::PlainTooShort(n) => write!(fmt, "解密后太短（{n} 字节）"),
            LoginError::TlvTruncated {
                tag,
                len,
                remaining,
            } => write!(
                fmt,
                "TLV 0x{tag:x} 声明长度 {len} 超出剩余 {remaining} 字节"
            ),
            LoginError::MissingSalt => write!(
                fmt,
                "滑动验证提交缺少盐（ctx.t104 为空）：盐来自上一条响应（type=2）的 0x104"
            ),
            LoginError::EmptyTicket => write!(fmt, "滑动验证提交的 ticket 为空"),
            LoginError::Tlv(e) => write!(fmt, "{e}"),
        }
    }
}

impl std::error::Error for LoginError {}

impl From<TlvError> for LoginError {
    fn from(e: TlvError) -> Self {
        LoginError::Tlv(e)
    }
}

/// 登录 TLV 的准入条件（对应官方 `k.java` / `j.java` 的 guard）。
///
/// **必须显式建模，不能靠"body 为空就跳过"**——8.9.50 的 `0x544` 正是合法的
/// 空 body TLV，用空判断会把它误删。
#[derive(Debug, Clone)]
pub struct LoginConditions {
    /// 账号串是否已是 uin 形式（是则**不发** `0x112`）。
    pub account_is_uin: bool,
    /// 登录标志位；`0x166` 仅在 `(flags & 128) != 0` 时发。
    pub flags: u32,
    /// 登录类型；`0x185` 仅在等于 3 时发。
    pub login_type: u32,
    /// 缓存的口令盐（`async_context._t104`）；首登为空 → 官方整条跳过。
    pub t104: Option<Vec<u8>>,
    /// 服务端回显的 `t.r`；`0x172` 仅非空时发。
    pub echoed_r: Option<Vec<u8>>,
    /// 静态 `k.L`；`0x201` 仅非空时发。
    pub static_l: Option<Vec<u8>>,
    /// `t.an`；`0x548` 仅非空时发。
    pub an: Option<Vec<u8>>,
    /// `tgtQR`；`0x318` 仅二维码登录时发。
    pub tgt_qr: Option<Vec<u8>>,
    /// `0x16A` 的源（短信验证票据）。
    pub t16a: Option<Vec<u8>>,
    /// 是否已有可用的登录票据；`0x400` 首登不发、续期才发。
    pub has_sig: bool,
    /// `0x545`（QIMEI）的源串；取不到就整条不发（官方 `j.java` case 1349）。
    pub qimei: Option<String>,
    /// d2 票据；token 登录（子命令 11）专有，`0x143` 的 body 就是 d2 本体。
    pub d2: Option<Vec<u8>>,
}

impl Default for LoginConditions {
    /// 密码首登的默认条件：一律取"取不到"的分支，等价于官方首次登录的情形。
    fn default() -> Self {
        Self {
            account_is_uin: true,
            flags: 0,
            login_type: 1,
            t104: None,
            echoed_r: None,
            static_l: None,
            an: None,
            tgt_qr: None,
            t16a: None,
            has_sig: false,
            qimei: None,
            d2: None,
        }
    }
}

fn non_empty(v: &Option<Vec<u8>>) -> bool {
    v.as_ref().is_some_and(|b| !b.is_empty())
}

impl LoginConditions {
    /// 该 TLV 在当前条件下是否应当出现在包里。
    ///
    /// ## 与官方 guard 的一处**有意偏离**
    ///
    /// 官方对 `0x187`/`0x188`/`0x194`/`0x202` 都有"静态字段为空则跳过"的判断，
    /// 但那些字段在本实现里直接从设备对象派生（`MD5(mac)` / `MD5(android_id)` /
    /// `imsi` / `bssid+ssid`），永不为空；参考实现 oicq 也无条件发送这四个。
    /// 故**不加空判**，跟 oicq 走。
    pub fn applies(&self, tag: u16) -> bool {
        match tag {
            0x104 => non_empty(&self.t104), // 首登无缓存盐 → 官方整条跳过
            0x112 => !self.account_is_uin,  // uin 登录不发
            0x166 => (self.flags & 128) != 0,
            0x16A => non_empty(&self.t16a),
            0x172 => non_empty(&self.echoed_r),
            0x185 => self.login_type == 3,
            0x201 => non_empty(&self.static_l),
            0x318 => non_empty(&self.tgt_qr), // 二维码路径专用
            0x400 => self.has_sig,            // 首登无票据 → 发给服务端只会被拒
            0x529 => false,                   // 三版本都无构建点，永不发
            0x545 => self.qimei.as_ref().is_some_and(|s| !s.is_empty()),
            0x548 => non_empty(&self.an),
            0x143 => non_empty(&self.d2), // token 登录专有：没有 d2 发出去只会被拒
            _ => true,
        }
    }
}

/// 组装 `u16 子命令 ‖ u16 TLV 个数 ‖ TLV…`。
///
/// `tags` 是候选顺序（通常取档案的 `apk.login_tlv_order`）；
/// `cond` 会先把不适用的项滤掉；`args` 给需要参数的 TLV 传参。
///
/// 返回的字节可直接交给 [`crate::sso::build_oicq_packet`]。
pub fn build(
    ctx: &TlvContext,
    sub_cmd: u16,
    tags: &[u16],
    cond: &LoginConditions,
    args: &[(u16, Vec<TlvArg>)],
) -> Result<Vec<u8>, LoginError> {
    let mut parts: Vec<Vec<u8>> = Vec::new();
    for &tag in tags {
        if !cond.applies(tag) {
            continue;
        }
        let empty: &[TlvArg] = &[];
        let a = args
            .iter()
            .find(|(t, _)| *t == tag)
            .map(|(_, v)| v.as_slice())
            .unwrap_or(empty);
        parts.push(pack(ctx, tag, a)?);
    }

    let mut out = Vec::new();
    out.extend_from_slice(&sub_cmd.to_be_bytes());
    out.extend_from_slice(&(parts.len() as u16).to_be_bytes());
    for p in &parts {
        out.extend_from_slice(p);
    }
    Ok(out)
}

/// 与 [`build`] 同源，但只返回被采用的 tag 列表（自测/排查用）。
pub fn plan(tags: &[u16], cond: &LoginConditions) -> Vec<u16> {
    tags.iter().copied().filter(|t| cond.applies(*t)).collect()
}

/// token 登录（子命令 11，命令字 [`crate::sso::EXCHANGE_EMP_CMD`]）的便捷入口。
///
/// `d2` 来自上次登录成功时响应 `0x119` 票据块里的 `0x143`（见
/// [`SigBundle::d2`]）；tgt 由 `ctx.tgt` 提供。这条路径**不需要密码**，
/// 是"票据续期"的低风险登录形态。
pub fn build_token(ctx: &TlvContext, d2: &[u8]) -> Result<Vec<u8>, LoginError> {
    let cond = LoginConditions {
        d2: Some(d2.to_vec()),
        ..Default::default()
    };
    let args = vec![(0x143u16, vec![TlvArg::Bytes(d2.to_vec())])];
    build(ctx, sub_cmd::TOKEN, &EXCHANGE_EMP_TLV_ORDER, &cond, &args)
}

/// 滑动验证码提交（子命令 2，命令字 [`crate::sso::LOGIN_CMD`]）的便捷入口。
///
/// 流程：密码登录被要求验证（响应 `type == 2` + TLV `0x192` 是验证地址）
/// → **人来把滑块解掉**（正常流程，不做任何自动化）→ 用拿到的 ticket
/// 发这条请求继续登录。
///
/// `ctx.t104` 必须是**上一条响应下发的盐**（`0x104`）：没有它这条请求没有
/// 意义，官方参考实现也直接拒绝发送——所以这里显式校验。
pub fn build_slider(ctx: &TlvContext, ticket: &str) -> Result<Vec<u8>, LoginError> {
    if ctx.t104.is_empty() {
        return Err(LoginError::MissingSalt);
    }
    let ticket = ticket.trim();
    if ticket.is_empty() {
        return Err(LoginError::EmptyTicket);
    }
    // 盐要同时在 guard（条件对象）与 body（ctx.t104）两侧可见：
    // guard 决定 0x104 是否进包，body 决定它的内容。
    let cond = LoginConditions {
        t104: Some(ctx.t104.clone()),
        ..Default::default()
    };
    let args = vec![(0x193u16, vec![TlvArg::Str(ticket.to_string())])];
    build(ctx, sub_cmd::SLIDER, &SLIDER_TLV_ORDER, &cond, &args)
}

/// 解析出的 TLV 表：**保持首次出现的位置**（对应 Dart 侧 `Map` 的插入序）。
///
/// 顺序在登录场景是语义的一部分（要按档案顺序发送），所以不能用按 tag 排序的
/// `BTreeMap`。同 tag 重复出现时值取后者——与 Dart `Map` 的覆盖语义一致。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TlvMap {
    entries: Vec<(u16, Vec<u8>)>,
}

impl TlvMap {
    pub fn insert(&mut self, tag: u16, body: Vec<u8>) {
        match self.entries.iter_mut().find(|(t, _)| *t == tag) {
            Some(e) => e.1 = body,
            None => self.entries.push((tag, body)),
        }
    }

    pub fn get(&self, tag: u16) -> Option<&Vec<u8>> {
        self.entries.iter().find(|(t, _)| *t == tag).map(|(_, v)| v)
    }

    pub fn contains_key(&self, tag: u16) -> bool {
        self.entries.iter().any(|(t, _)| *t == tag)
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// 按出现顺序返回全部 tag。
    pub fn keys(&self) -> impl Iterator<Item = u16> + '_ {
        self.entries.iter().map(|(t, _)| *t)
    }

    pub fn iter(&self) -> impl Iterator<Item = &(u16, Vec<u8>)> {
        self.entries.iter()
    }
}

/// 读一段 TLV 序列，返回 `tag → body`（保序，见 [`TlvMap`]）。
///
/// 对应 oicq 的 `readTlv`；官方对应 `tlv_t.search_tlv`——同样是**无计数
/// 前缀**的裸序列，按 `i = len + 4 + i` 递进。
///
/// `tolerate_truncated` 为真时，尾部不完整的 TLV 被忽略而不是报错——服务端
/// 响应里常带一些我们不需要的尾部字段。
pub fn read_tlv(
    data: &[u8],
    offset: usize,
    tolerate_truncated: bool,
) -> Result<TlvMap, LoginError> {
    let mut out = TlvMap::default();
    let mut i = offset;
    while i + 4 <= data.len() {
        let tag = u16::from_be_bytes([data[i], data[i + 1]]);
        let len = u16::from_be_bytes([data[i + 2], data[i + 3]]);
        let start = i + 4;
        let end = start + len as usize;
        if end > data.len() {
            if tolerate_truncated {
                break;
            }
            return Err(LoginError::TlvTruncated {
                tag,
                len,
                remaining: data.len() - start,
            });
        }
        out.insert(tag, data[start..end].to_vec());
        i = end;
    }
    Ok(out)
}

/// 登录响应（解析自传输层拿回的 payload，**已去掉 u32 分帧头**）。
#[derive(Debug, Clone)]
pub struct LoginResponse {
    /// 响应类型，见 [`result_type`]。
    pub ty: u8,
    /// 解密后的 TLV 表（保序，见 [`TlvMap`]）。
    pub tlvs: TlvMap,
    /// 解密后的明文（排查用）。
    pub plain: Vec<u8>,
}

impl LoginResponse {
    pub fn is_success(&self) -> bool {
        self.ty == result_type::SUCCESS
    }

    pub fn needs_slider(&self) -> bool {
        self.ty == result_type::SLIDER
    }

    pub fn needs_device_lock(&self) -> bool {
        self.ty == result_type::DEVICE_LOCK
    }

    /// 滑动验证地址（仅 `type == 2` 且有 `0x192` 时有值）。
    pub fn slider_url(&self) -> Option<String> {
        self.tlvs
            .get(0x192)
            .and_then(|b| String::from_utf8(b.clone()).ok())
    }

    /// 票据块 `0x119`（仅成功时有值）。
    pub fn t119(&self) -> Option<&[u8]> {
        self.tlvs.get(0x119).map(|v| v.as_slice())
    }

    /// 解析响应：`payload[16 : len-1]` 用 ECDH share key 解密，得到
    /// `u16 ‖ u8 type ‖ u16 ‖ TLV…`。
    ///
    /// 开头 16 字节是 OICQ 信封头，末尾 1 字节是 `0x03` 尾——都不参与解密。
    pub fn parse(payload: &[u8], share_key: &[u8]) -> Result<LoginResponse, LoginError> {
        if payload.len() < 16 + 1 + 5 {
            return Err(LoginError::TooShort(payload.len()));
        }
        let body = &payload[16..payload.len() - 1];
        let plain = qq_tea_decrypt(body, share_key).map_err(LoginError::Decrypt)?;
        if plain.len() < 5 {
            return Err(LoginError::PlainTooShort(plain.len()));
        }
        let ty = plain[2];
        let tlvs = read_tlv(&plain, 5, true)?;
        Ok(LoginResponse { ty, tlvs, plain })
    }
}

/// 票据集合（来自响应 TLV `0x119`，需用 tgtgt 密钥再解一层）。
///
/// 对应 oicq 的 `decodeT119` 与官方 9.3.60 `oicq_request.c()` 成功分支：
/// `0x119` 的 body 用 tgtgt 密钥 TEA 解密，子 TLV 一律**从偏移 2 起**搜
/// （`0x10a`=tgt / `0x143`=d2 / `0x305`=d2key / `0x106`=新 tgtgt 材料…）。
#[derive(Debug, Clone)]
pub struct SigBundle {
    pub t106: Option<Vec<u8>>,
    pub tgt: Option<Vec<u8>>,
    pub d2: Option<Vec<u8>>,
    pub d2key: Option<Vec<u8>>,
    pub sig_key: Option<Vec<u8>>,
    pub ticket_key: Option<Vec<u8>>,
    pub srm_token: Option<Vec<u8>>,
    pub skey: Option<Vec<u8>>,
    pub st_web_sig: Option<Vec<u8>>,
    pub device_token: Option<Vec<u8>>,
    pub t11a: Option<Vec<u8>>,
    pub t512: Option<Vec<u8>>,
    /// 全部 TLV（保序，见 [`TlvMap`]）。
    pub all: TlvMap,
}

impl SigBundle {
    /// 用 `tgtgt_key` 解开 `0x119` 并抽出票据。
    pub fn parse(t119: &[u8], tgtgt_key: &[u8]) -> Result<SigBundle, LoginError> {
        let plain = qq_tea_decrypt(t119, tgtgt_key).map_err(LoginError::Decrypt)?;
        if plain.len() < 2 {
            return Err(LoginError::PlainTooShort(plain.len()));
        }
        let tlvs = read_tlv(&plain, 2, true)?;
        let get = |tag: u16| tlvs.get(tag).cloned();
        Ok(SigBundle {
            t106: get(0x106),
            tgt: get(0x10A),
            d2: get(0x143),
            d2key: get(0x305),
            sig_key: get(0x133),
            ticket_key: get(0x134),
            srm_token: get(0x16A),
            skey: get(0x120),
            st_web_sig: get(0x103),
            device_token: get(0x322),
            t11a: get(0x11A),
            t512: get(0x512),
            all: tlvs,
        })
    }
}
