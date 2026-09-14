//! 登录 TLV 打包（QQ 8.2.11 体系），对应 Dart 侧
//! `lib/kernel/wlogin8/qq8_tlv.dart`。
//!
//! ```text
//!   +--------+--------+------------------+
//!   | tag    | len    | body             |
//!   | uint16 | uint16 | len 字节          |
//!   +--------+--------+------------------+
//!         全部大端（已由 oicq.wlogin_sdk.tools.util 反编译证实）
//! ```
//!
//! `len` **只计 body**，不含 4 字节头。
//!
//! ## 来源与裁判
//!
//! 逐条移植自参考实现 oicq 的 `lib/wtlogin/tlv.js`（8.2.11 同代协议的开源
//! 实现）。48 条黄金向量由 `analysis/scripts/gen_tlv_vectors.cjs` 用 oicq
//! 原始模块在确定性 mock 下生成，落在 `vectors/tlv.json`；测试
//! `tests/tlv_vectors.rs` 逐字节消费。
//!
//! 官方顺序表（37/38 项）出处：8.2.11 `oicq.wlogin_sdk.request.k` 的
//! `int[]`，9.3.60/TIM 在末尾追加 `0x553`。详见 Dart 侧同名文件的注释与
//! `analysis/QQ-官方三版本登录流程对照.md`。
//!
//! ## 与官方不同、且是**刻意**不同的两处
//!
//! * `0x106` 的 TEA 密钥：官方三版本一律 `MD5(guid(16) ‖ u64(uin 或
//!   msalt)(8))`，oicq 用的是 `MD5(password_md5 ‖ 0000 ‖ u32(uin))`。
//!   本实现按官方。
//! * `0x544` / `0x553`：走官方"安全 SDK 不可用"降级路径（`0x544` =
//!   `00 00 00 00` 或空、`0x553` = `00`），不携带任何腾讯二进制。
//!   代价：服务端仍会把本实现归到 oicq / Lagrange 一档——这是自实现
//!   协议路线的结构性上限。

use crate::device::Device;
use crate::pb::{encode, PbError, PbValue};
use crate::profiles::ApkInfo;
use penguin_crypto::digest::md5_bytes;
use penguin_crypto::tea::{qq_tea_encrypt, qq_tea_pad_len, TeaError};

/// 官方客户端**登录请求**的 TLV 清单与顺序（8.2.11 / 8.9.50 同款，37 项）。
///
/// ⚠️ 顺序表 ≠ 实际发送：官方是「超集清单 + `switch` 条件分派」，未命中的
/// 项直接跳过（8.9.50 的 `j` 里该 `switch` 只有 31 个 `case`），因此发送数
/// 小于 37 是正常的。
pub const LOGIN_TLV_ORDER: [u16; 37] = [
    0x18, 0x01, 0x106, 0x116, 0x100, 0x107, 0x108, 0x104, 0x142, 0x112, 0x144, 0x145, 0x147, 0x166,
    0x16A, 0x154, 0x141, 0x08, 0x511, 0x172, 0x185, 0x400, 0x187, 0x188, 0x194, 0x191, 0x201,
    0x202, 0x177, 0x516, 0x521, 0x525, 0x529, 0x318, 0x544, 0x545, 0x548,
];

/// 9.3.60 / TIM 4.1.0 的顺序表：37 项 + 末尾 `0x553`（38 项）。
pub const LOGIN_TLV_ORDER_WITH_553: [u16; 38] = [
    0x18, 0x01, 0x106, 0x116, 0x100, 0x107, 0x108, 0x104, 0x142, 0x112, 0x144, 0x145, 0x147, 0x166,
    0x16A, 0x154, 0x141, 0x08, 0x511, 0x172, 0x185, 0x400, 0x187, 0x188, 0x194, 0x191, 0x201,
    0x202, 0x177, 0x516, 0x521, 0x525, 0x529, 0x318, 0x544, 0x545, 0x548, 0x553,
];

/// `wtlogin.exchange_emp`（子命令 11，token 登录 / 票据续期）的 TLV 顺序表。
///
/// 官方记载该子命令发 16 项；取值与顺序取自 oicq
/// `lib/wtlogin/login-password.js`（`tokenLogin`）。`0x143` 是这条路的灵魂：
/// body 即 d2 本体，没有 d2 时整条不发。
pub const EXCHANGE_EMP_TLV_ORDER: [u16; 16] = [
    0x100, 0x10A, 0x116, 0x144, 0x143, 0x142, 0x154, 0x18, 0x141, 0x08, 0x147, 0x177, 0x187, 0x188,
    0x202, 0x511,
];

/// `wtlogin.login` 子命令 2（滑动验证码提交）的 TLV 顺序表（4 项）。
///
/// 出处：oicq `lib/wtlogin/login-password.js`（`sliderLogin`）。
/// ⚠️ `0x104`（盐）是必需的：没有它整条请求没有意义。
pub const SLIDER_TLV_ORDER: [u16; 4] = [0x193, 0x08, 0x104, 0x116];

/// 8.2.11 密码登录实际需要、而本模块走条件分支（默认不发）的 TLV。
///
/// 官方对顺序表是「超集清单 + `switch` 条件分派」，所以"缺 TLV"的说法
/// 本身是错的，正确说法是"缺条件判断"。各条的行号与条件见 Dart 侧注释。
pub const LOGIN_TLV_CONDITIONAL: [u16; 6] = [0x112, 0x166, 0x172, 0x185, 0x201, 0x548];

/// 依赖 native / 服务端签发、按官方降级路径处理的 TLV（见模块头注释）。
pub const LOGIN_TLV_NATIVE_BOUND: [u16; 2] = [0x544, 0x545];

/// `0x544` 的 8.2.11 降级 body（`ByteData.getCode` → `status = {0,0,0,0}`）。
pub const TLV544_DEGRADED_BODY_8211: [u8; 4] = [0, 0, 0, 0];

/// 出现在顺序表中、但不属于密码登录流程的 TLV。
///
/// * `0x318` —— 泛型包装 `tgtQR`，二维码登录专用；
/// * `0x529` —— 三版本 `tlv_type/` 都没有对应类，列在表里但根本不产生。
pub const LOGIN_TLV_OUT_OF_PASSWORD_FLOW: [u16; 2] = [0x318, 0x529];

/// TLV `0x545`（QIMEI）的取值方式——8.2.11 → 8.9.50 之间真实的协议可见变化。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QimeiMode {
    /// 8.2.11：body = `MD5(qimei 字符串)`，16 字节（`util.java:343`）。
    Md5OfSource,
    /// 8.9.50 起：body = qimei 字符串**原文**的 UTF-8（`util.java:1493`）；
    /// 值由注入的 `QimeiListener` 提供（新 SDK `com.tencent.qimei`）。
    RawSource,
}

// ---------------------------------------------------------------------------
// 上下文
// ---------------------------------------------------------------------------

/// 字节来源（随机数 / TEA 填充）：可注入 ⇒ TLV 输出可复现、可对照。
pub type ByteSource = Box<dyn Fn(usize) -> Vec<u8> + Send + Sync>;
/// 时间源（毫秒）。
pub type Clock = Box<dyn Fn() -> i64 + Send + Sync>;

fn os_random(n: usize) -> Vec<u8> {
    let mut out = vec![0u8; n];
    if getrandom::getrandom(&mut out).is_err() {
        panic!("系统随机源不可用");
    }
    out
}

fn wall_clock_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// TLV 打包上下文（字段与 Dart 侧 `Qq8TlvContext` 一一对应）。
///
/// 随机源与时间源均可注入——**这是让 TLV 输出可复现、可对照参考实现的前提**
/// （`0x01` / `0x106` / `0x400` / `0x401` 含随机字节，`0x01` / `0x106` /
/// `0x400` 含时间戳）。
pub struct TlvContext {
    pub uin: u32,
    pub apk: ApkInfo,
    pub device: Device,
    /// 口令的 MD5（16 字节）。
    pub password_md5: Vec<u8>,
    /// 当前序列号。
    pub seq_id: u32,
    /// 会话密钥材料。
    pub ksid: Vec<u8>,
    /// 缓存的 TLV `0x104` body。
    pub t104: Vec<u8>,
    /// 缓存的 TLV `0x174` body。
    pub t174: Vec<u8>,
    /// 票据。
    pub tgt: Vec<u8>,
    pub srm_token: Vec<u8>,
    /// 口令盐（官方 `async_context._msalt`）：非 0 时替代 uin 写入 `0x106`
    /// 密钥种子的后 8 字节。
    pub msalt: u64,
    pub random_bytes: ByteSource,
    /// TEA 填充字节的来源。QQ 的 TEA 会在明文头部垫入随机字节，服务端解密时
    /// 直接丢弃——因此**密文本身不可复现**，做成可注入纯粹为了自测确定性。
    pub tea_padding: ByteSource,
    pub now_millis: Clock,
}

impl TlvContext {
    /// 生产路径：随机源 = 系统熵，时间 = 墙钟。
    // 参数与 Dart 侧具名参数一一对应；9 个都是必需字段，不为此再加一层 builder。
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        uin: u32,
        apk: ApkInfo,
        device: Device,
        password_md5: Vec<u8>,
        ksid: Vec<u8>,
        t104: Vec<u8>,
        t174: Vec<u8>,
        tgt: Vec<u8>,
        srm_token: Vec<u8>,
    ) -> Self {
        Self {
            uin,
            apk,
            device,
            password_md5,
            seq_id: 0,
            ksid,
            t104,
            t174,
            tgt,
            srm_token,
            msalt: 0,
            random_bytes: Box::new(os_random),
            tea_padding: Box::new(os_random),
            now_millis: Box::new(wall_clock_millis),
        }
    }

    pub fn with_seq_id(mut self, seq_id: u32) -> Self {
        self.seq_id = seq_id;
        self
    }

    pub fn with_msalt(mut self, msalt: u64) -> Self {
        self.msalt = msalt;
        self
    }
}

// ---------------------------------------------------------------------------
// 参数与错误
// ---------------------------------------------------------------------------

/// TLV 函数的可变参数（对应 oicq 里 TLV 函数的入参）。
#[derive(Debug, Clone, PartialEq)]
pub enum TlvArg {
    /// 数值（如 `0x100` 的 `emp`）。
    Uint(u64),
    /// 文本（如 `0x112` 的账号串、`0x17C` 的 code）。
    Str(String),
    /// 字节串（如 `0x143` 的 d2、`0x193` 的 ticket）。
    Bytes(Vec<u8>),
}

#[derive(Debug, PartialEq)]
pub enum TlvError {
    /// 8.2.11 表内无此项。
    UnknownTag(u16),
    Tea(TeaError),
    Pb(PbError),
}

impl std::fmt::Display for TlvError {
    fn fmt(&self, fmt: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TlvError::UnknownTag(tag) => {
                write!(fmt, "未知 TLV 编号 0x{tag:x}（8.2.11 表内无此项）")
            }
            TlvError::Tea(e) => write!(fmt, "TEA: {e}"),
            TlvError::Pb(e) => write!(fmt, "protobuf: {e}"),
        }
    }
}

impl std::error::Error for TlvError {}

impl From<TeaError> for TlvError {
    fn from(e: TeaError) -> Self {
        TlvError::Tea(e)
    }
}

impl From<PbError> for TlvError {
    fn from(e: PbError) -> Self {
        TlvError::Pb(e)
    }
}

// ---------------------------------------------------------------------------
// 写入工具
// ---------------------------------------------------------------------------

fn u8b(out: &mut Vec<u8>, v: u8) {
    out.push(v);
}
fn u16b(out: &mut Vec<u8>, v: u16) {
    out.extend_from_slice(&v.to_be_bytes());
}
fn u32b(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_be_bytes());
}
fn u64b(out: &mut Vec<u8>, v: u64) {
    out.extend_from_slice(&v.to_be_bytes());
}

/// `writeTlv`：uint16 长度前缀 + 内容。
fn tlv(out: &mut Vec<u8>, data: &[u8]) {
    u16b(out, data.len() as u16);
    out.extend_from_slice(data);
}

fn tlv_str(out: &mut Vec<u8>, s: &str) {
    tlv(out, s.as_bytes());
}

/// 按 UTF-16 码元截断（与 JS 的 `String.prototype.slice` 行为一致；
/// 对 ASCII 等价于按字节截断）。
fn cut(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        s.to_string()
    } else {
        s.chars().take(n).collect()
    }
}

fn cut_bytes(b: &[u8], n: usize) -> &[u8] {
    if b.len() <= n {
        b
    } else {
        &b[..n]
    }
}

fn arg_bytes(args: &[TlvArg], i: usize) -> &[u8] {
    match args.get(i) {
        Some(TlvArg::Bytes(b)) => b,
        Some(TlvArg::Str(s)) => s.as_bytes(),
        _ => &[],
    }
}

fn arg_str(args: &[TlvArg], i: usize) -> &str {
    match args.get(i) {
        Some(TlvArg::Str(s)) => s,
        _ => "",
    }
}

fn arg_uint(args: &[TlvArg], i: usize) -> u64 {
    match args.get(i) {
        Some(TlvArg::Uint(v)) => *v,
        _ => 0,
    }
}

// ---------------------------------------------------------------------------
// 打包
// ---------------------------------------------------------------------------

/// 打包：`[tag][len][body]`。
pub fn pack(ctx: &TlvContext, tag: u16, args: &[TlvArg]) -> Result<Vec<u8>, TlvError> {
    let b = body(ctx, tag, args)?;
    let mut out = Vec::with_capacity(b.len() + 4);
    u16b(&mut out, tag);
    u16b(&mut out, b.len() as u16);
    out.extend_from_slice(&b);
    Ok(out)
}

/// 只产出 body（不含 tag/len 头）。
pub fn body(ctx: &TlvContext, tag: u16, args: &[TlvArg]) -> Result<Vec<u8>, TlvError> {
    let mut w: Vec<u8> = Vec::new();
    let now = (ctx.now_millis)();
    let now32 = (now as u64 & 0xFFFF_FFFF) as u32;
    let d = &ctx.device;
    let random = |n: usize| (ctx.random_bytes)(n);

    match tag {
        0x01 => {
            u16b(&mut w, 1); // ip ver
            w.extend_from_slice(&random(4));
            u32b(&mut w, ctx.uin);
            u32b(&mut w, now32);
            w.extend_from_slice(&[0u8; 4]); // ip
            u16b(&mut w, 0);
        }

        0x08 => {
            u16b(&mut w, 0);
            u32b(&mut w, 2052);
            u16b(&mut w, 0);
        }

        0x16 => {
            u32b(&mut w, 7);
            u32b(&mut w, 16);
            u32b(&mut w, 537067759);
            w.extend_from_slice(&d.guid);
            tlv_str(&mut w, "com.tencent.qqlite");
            tlv_str(&mut w, "4.0.2");
            tlv(&mut w, &ctx.apk.sign);
        }

        0x18 => {
            u16b(&mut w, 1); // ping ver
            u32b(&mut w, 1536);
            u32b(&mut w, ctx.apk.appid);
            u32b(&mut w, 0);
            u32b(&mut w, ctx.uin);
            u16b(&mut w, 0);
            u16b(&mut w, 0);
        }

        0x1B => {
            u32b(&mut w, 0);
            u32b(&mut w, 0);
            u32b(&mut w, 3);
            u32b(&mut w, 4);
            u32b(&mut w, 72);
            u32b(&mut w, 2);
            u32b(&mut w, 2);
            u16b(&mut w, 0);
        }

        0x1D => {
            u8b(&mut w, 1);
            u32b(&mut w, 184024956);
            u32b(&mut w, 0);
            u8b(&mut w, 0);
            u32b(&mut w, 0);
        }

        0x1F => {
            u8b(&mut w, 0);
            tlv_str(&mut w, "android");
            tlv_str(&mut w, "7.1.2");
            u16b(&mut w, 2);
            tlv_str(&mut w, "China Mobile GSM");
            tlv(&mut w, &[]);
            tlv_str(&mut w, "wifi");
        }

        0x33 => {
            w.extend_from_slice(&d.guid);
        }

        0x35 => {
            u32b(&mut w, 8);
        }

        0x100 => {
            let emp = arg_uint(args, 0) != 0;
            u16b(&mut w, 1); // db buf ver
            u32b(&mut w, ctx.apk.sso_ver); // _sso_ver：8.2.11=7 / 8.9.50=19 / 9.3.60=22
            u32b(&mut w, ctx.apk.appid);
            u32b(&mut w, if emp { 2 } else { ctx.apk.subid });
            u32b(&mut w, 0);
            u32b(&mut w, ctx.apk.main_sig_map);
        }

        0x104 => {
            w.extend_from_slice(&ctx.t104);
        }

        0x106 => {
            let mut inner: Vec<u8> = Vec::new();
            u16b(&mut inner, 4); // tgtgt ver
            inner.extend_from_slice(&random(4));
            u32b(&mut inner, ctx.apk.sso_ver); // _SSoVer
            u32b(&mut inner, ctx.apk.appid);
            u32b(&mut inner, 0);
            u64b(&mut inner, ctx.uin as u64);
            u32b(&mut inner, now32);
            inner.extend_from_slice(&[0u8; 4]); // dummy ip
            u8b(&mut inner, 1); // save password
            inner.extend_from_slice(&ctx.password_md5);
            inner.extend_from_slice(&d.tgtgt);
            u32b(&mut inner, 0);
            u8b(&mut inner, 1); // guid available
            inner.extend_from_slice(&d.guid);
            u32b(&mut inner, ctx.apk.subid);
            u32b(&mut inner, 1); // login type: password
            tlv_str(&mut inner, &ctx.uin.to_string());
            u16b(&mut inner, 0);

            // 密钥种子 = guid(16) ‖ u64(msalt 非 0 时用 msalt，否则用 uin)。
            // ⚠️ 官方三版本的 tlv_t106 逐行一致，均用本公式；oicq 用的是
            // MD5(password_md5 ‖ 0000 ‖ uin_u32be)，与官方不符。以官方为准。
            let mut seed = [0u8; 24];
            let n = d.guid.len().min(16);
            seed[..n].copy_from_slice(&d.guid[..n]);
            seed[16..].copy_from_slice(
                &(if ctx.msalt != 0 {
                    ctx.msalt
                } else {
                    ctx.uin as u64
                })
                .to_be_bytes(),
            );
            let key = md5_bytes(&seed);

            let pad = qq_tea_pad_len(inner.len());
            let padding = (ctx.tea_padding)(pad + 3);
            w.extend_from_slice(&qq_tea_encrypt(&inner, &key, Some(&padding))?);
        }

        0x107 => {
            u16b(&mut w, 0); // pic type
            u8b(&mut w, 0); // captcha type
            u16b(&mut w, 0); // pic size
            u8b(&mut w, 1); // ret type
        }

        0x108 => {
            w.extend_from_slice(&ctx.ksid);
        }

        0x109 => {
            w.extend_from_slice(&md5_bytes(d.imei.as_bytes()));
        }

        0x10A => {
            w.extend_from_slice(&ctx.tgt);
        }

        // 官方 8.2.11 `k.java:131`：仅当账号串不是 uin 形式才发；uin 登录下不发。
        0x112 => {
            let acc = arg_str(args, 0);
            if !acc.is_empty() {
                w.extend_from_slice(acc.as_bytes());
            }
        }

        // 官方 8.2.11 `k.java:176`：仅当 (i4 & 128) != 0；body = 静态 t.x 默认 1。
        0x166 => {
            u8b(&mut w, 1);
        }

        // 官方 8.2.11 `k.java:196`：仅当 `t.r` 非空；`t.r` 是服务端回显赋值，
        // 首登必为空 → 官方自己也不发。
        0x172 => {
            let r = arg_bytes(args, 0);
            if !r.is_empty() {
                w.extend_from_slice(r);
            }
        }

        // 官方 8.2.11 `k.java:211`：仅当 i3 == 3。body = [0x01, 0x01]。
        0x185 => {
            u8b(&mut w, 1);
            u8b(&mut w, 1);
        }

        // 官方 8.2.11 `k.java:253`：仅当静态 `k.L` 非空；body = 4 段
        // `u16len + bytes`：L, M, "qq", N。
        0x201 => {
            let l = arg_bytes(args, 0);
            if !l.is_empty() {
                let m = arg_bytes(args, 1);
                let n = arg_bytes(args, 2);
                for seg in [l, m, b"qq".as_slice(), n] {
                    tlv(&mut w, seg);
                }
            }
        }

        // 官方 8.2.11 `k.java:394`：仅当 `t.an` 非空，默认空 → 不发。
        0x548 => {
            let an = arg_bytes(args, 0);
            if !an.is_empty() {
                w.extend_from_slice(an);
            }
        }

        0x116 => {
            u8b(&mut w, 0);
            u32b(&mut w, ctx.apk.misc_bitmap);
            u32b(&mut w, ctx.apk.sub_sig_map); // 0x10400，三代相同
            u8b(&mut w, 1); // app id list 长度
            u32b(&mut w, 1600000226); // app id list[0]
        }

        // 安全 SDK 不可用时的降级 body（官方代码路径：8.2.11 status={0,0,0,0}；
        // 8.9.50 liteSign = new byte[0]）。不是伪造。
        0x544 => {
            w.extend_from_slice(ctx.apk.tlv544_degraded_body);
        }

        // QIMEI。⚠️ 拿不到时官方**整条不发**（滤除由调用方的 guard 负责），
        // 这里不该产出空 body。
        0x545 => {
            let qimei = arg_str(args, 0);
            if !qimei.is_empty() {
                let raw = qimei.as_bytes();
                match ctx.apk.qimei_mode {
                    QimeiMode::Md5OfSource => w.extend_from_slice(&md5_bytes(raw)),
                    QimeiMode::RawSource => w.extend_from_slice(raw),
                }
            }
        }

        // 仅 9.3.60 / TIM 的顺序表里有。官方 = QSec.getFeKitAttach(...)，
        // fekit 不可用时返回 new byte[]{0}。
        0x553 => {
            if let Some(b553) = ctx.apk.tlv553_degraded_body {
                w.extend_from_slice(b553);
            }
        }

        0x124 => {
            tlv_str(&mut w, &cut(&d.os_type, 16));
            tlv_str(&mut w, &cut(&d.version.release, 16));
            u16b(&mut w, 2); // network type
            tlv_str(&mut w, &cut(&d.sim, 16));
            u16b(&mut w, 0);
            tlv_str(&mut w, &cut(&d.apn, 16));
        }

        0x128 => {
            u16b(&mut w, 0);
            u8b(&mut w, 0); // guid new
            u8b(&mut w, 1); // guid available
            u8b(&mut w, 0); // guid changed
            u32b(&mut w, 16777216); // guid flag
            tlv_str(&mut w, &cut(&d.model, 32));
            tlv(&mut w, cut_bytes(&d.guid, 16));
            tlv_str(&mut w, &cut(&d.brand, 16));
        }

        0x141 => {
            u16b(&mut w, 1); // ver
            tlv_str(&mut w, &d.sim);
            u16b(&mut w, 2); // network type
            tlv_str(&mut w, &d.apn);
        }

        0x142 => {
            u16b(&mut w, 0);
            tlv_str(&mut w, &cut(ctx.apk.id, 32));
        }

        0x143 => {
            w.extend_from_slice(arg_bytes(args, 0));
        }

        0x144 => {
            let mut inner: Vec<u8> = Vec::new();
            u16b(&mut inner, 5); // tlv 计数
            inner.extend_from_slice(&pack(ctx, 0x109, &[])?);
            inner.extend_from_slice(&pack(ctx, 0x52D, &[])?);
            inner.extend_from_slice(&pack(ctx, 0x124, &[])?);
            inner.extend_from_slice(&pack(ctx, 0x128, &[])?);
            inner.extend_from_slice(&pack(ctx, 0x16E, &[])?);

            let pad = qq_tea_pad_len(inner.len());
            let padding = (ctx.tea_padding)(pad + 3);
            w.extend_from_slice(&qq_tea_encrypt(&inner, &d.tgtgt, Some(&padding))?);
        }

        0x145 => {
            w.extend_from_slice(&d.guid);
        }

        0x147 => {
            u32b(&mut w, ctx.apk.appid);
            tlv_str(&mut w, &cut(ctx.apk.ver, 5));
            tlv(&mut w, &ctx.apk.sign);
        }

        0x154 => {
            u32b(&mut w, ctx.seq_id + 1);
        }

        0x16A => {
            w.extend_from_slice(&ctx.srm_token);
        }

        0x16E => {
            w.extend_from_slice(d.model.as_bytes());
        }

        0x174 => {
            w.extend_from_slice(&ctx.t174);
        }

        0x177 => {
            u8b(&mut w, 0x01);
            u32b(&mut w, ctx.apk.buildtime);
            tlv_str(&mut w, ctx.apk.sdkver);
        }

        0x17A => {
            u32b(&mut w, 9);
        }

        0x17C => {
            tlv_str(&mut w, arg_str(args, 0));
        }

        0x187 => {
            w.extend_from_slice(&md5_bytes(d.mac_address.as_bytes()));
        }

        0x188 => {
            w.extend_from_slice(&md5_bytes(d.android_id.as_bytes()));
        }

        0x191 => {
            u8b(&mut w, 0x82);
        }

        0x193 => {
            w.extend_from_slice(arg_bytes(args, 0));
        }

        0x194 => {
            w.extend_from_slice(&d.imsi);
        }

        0x197 | 0x198 => {
            tlv(&mut w, &[0u8]);
        }

        0x202 => {
            tlv_str(&mut w, &cut(&d.wifi_bssid, 16));
            tlv_str(&mut w, &cut(&d.wifi_ssid, 32));
        }

        0x400 => {
            u16b(&mut w, 1);
            u64b(&mut w, ctx.uin as u64);
            w.extend_from_slice(&d.guid);
            w.extend_from_slice(&random(16));
            u32b(&mut w, 1);
            u32b(&mut w, 16);
            u32b(&mut w, now32);
        }

        0x401 => {
            w.extend_from_slice(&random(16));
        }

        0x511 => {
            const DOMAINS: [&str; 14] = [
                "tenpay.com",
                "openmobile.qq.com",
                "docs.qq.com",
                "connect.qq.com",
                "qzone.qq.com",
                "vip.qq.com",
                "qun.qq.com",
                "game.qq.com",
                "qqweb.qq.com",
                "office.qq.com",
                "ti.qq.com",
                "mail.qq.com",
                "gamecenter.qq.com",
                "mma.qq.com",
            ];
            u16b(&mut w, DOMAINS.len() as u16);
            for v in DOMAINS {
                u8b(&mut w, 0x01);
                tlv_str(&mut w, v);
            }
        }

        0x516 => {
            u32b(&mut w, 0);
        }

        0x521 => {
            u32b(&mut w, 0); // product type
            u16b(&mut w, 0);
        }

        0x525 => {
            u16b(&mut w, 1); // tlv 计数
            u16b(&mut w, 0x536);
            tlv(&mut w, &[0x01, 0x00]);
        }

        0x52D => {
            let fields: [(i32, PbValue); 9] = [
                (1, PbValue::Str(d.bootloader.clone())),
                (2, PbValue::Str(d.proc_version.clone())),
                (3, PbValue::Str(d.version.codename.clone())),
                (4, PbValue::Str(d.version.incremental.clone())),
                (5, PbValue::Str(d.fingerprint.clone())),
                (6, PbValue::Str(d.boot_id.clone())),
                (7, PbValue::Str(d.android_id.clone())),
                (8, PbValue::Str(d.baseband.clone())),
                (9, PbValue::Str(d.version.incremental.clone())),
            ];
            w.extend_from_slice(&encode(&fields)?);
        }

        _ => return Err(TlvError::UnknownTag(tag)),
    }
    Ok(w)
}
