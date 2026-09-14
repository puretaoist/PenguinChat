//! 上线注册（`StatSvc.register`），对应 Dart 侧
//! `lib/kernel/wlogin8/qq8_register.dart`。
//!
//! 登录成功后**必须发的第一个业务请求**：告诉服务器"我上线了"。
//! 信封走登录层（type=1 上线，SSO 层用 d2key 加密），命令字
//! [`CMD`]（= `StatSvc.register`）。
//!
//! ## 请求体结构（40 个槽位，tag 0..39；参考实现里 15/25/35/37 传 null → 不写）
//!
//! 逐槽位对照表见 Dart 侧同名文件（tag0=uin、tag1=注册类型 7、
//! tag16=guid、tag33=pb blob、tag38/39=1000/98…）。
//!
//! 外层是 JCE WUP 包装：service=`PushService`、method=`SvcReqRegister`。
//!
//! ## 出处
//!
//! 参考实现 oicq `lib/core/base-client.ts` 的 `register()`（含信封与响应判读）。
//! ⚠️ 官方对应的 Java 类**尚未定位**（`SvcReqRegister` 字符串在
//! `classes14/18.dex` 可见，但类名混淆）；字段表暂以参考实现为准，
//! **最终裁判是服务端**——发出后看响应 `rsp[9]`。

use crate::device::Device;
use crate::jce::{decode_wrapper, encode_struct, encode_wrapper, JceError, JceValue};
use crate::pb::{encode as pb_encode, PbError, PbValue};

/// 登录层信封的命令字。
pub const CMD: &str = "StatSvc.register";

#[derive(Debug, PartialEq)]
pub enum RegisterError {
    Jce(JceError),
    Pb(PbError),
}

impl std::fmt::Display for RegisterError {
    fn fmt(&self, fmt: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RegisterError::Jce(e) => write!(fmt, "JCE: {e}"),
            RegisterError::Pb(e) => write!(fmt, "protobuf: {e}"),
        }
    }
}

impl std::error::Error for RegisterError {}

impl From<JceError> for RegisterError {
    fn from(e: JceError) -> Self {
        RegisterError::Jce(e)
    }
}

impl From<PbError> for RegisterError {
    fn from(e: PbError) -> Self {
        RegisterError::Pb(e)
    }
}

fn wall_clock_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 组装请求体：JCE 包装（PushService / SvcReqRegister）。
///
/// `now_millis` 供测试注入固定时间戳（pb blob 里带时间）。
pub fn build_body(
    uin: u32,
    device: &Device,
    logout: bool,
    now_millis: Option<i64>,
) -> Result<Vec<u8>, RegisterError> {
    let ts = now_millis.unwrap_or_else(wall_clock_millis);
    let pb_blob = pb_encode(&[(
        1,
        PbValue::List(vec![
            PbValue::Nested(vec![(1, PbValue::Int(46)), (2, PbValue::Int(ts))]),
            PbValue::Nested(vec![(1, PbValue::Int(283)), (2, PbValue::Int(0))]),
        ]),
    )])?;

    let int = JceValue::Int;
    let str_ = |s: &str| JceValue::Str(s.to_string());
    let fields: Vec<(i32, JceValue)> = vec![
        (0, int(uin as i64)),
        (1, int(if logout { 0 } else { 7 })),
        (2, int(0)),
        (3, str_("")),
        (4, int(if logout { 21 } else { 11 })),
        (5, int(0)),
        (6, int(0)),
        (7, int(0)),
        (8, int(0)),
        (9, int(0)),
        (10, int(if logout { 44 } else { 0 })),
        (11, int(device.version.sdk as i64)),
        (12, int(1)),
        (13, str_("")),
        (14, int(0)),
        // 15: null（参考实现不写）
        (16, JceValue::Bytes(device.guid.clone())),
        (17, int(2052)),
        (18, int(0)),
        (19, str_(&device.model)),
        (20, str_(&device.model)),
        (21, str_(&device.version.release)),
        (22, int(1)),
        (23, int(0)),
        (24, int(0)),
        // 25: null
        (26, int(0)),
        (27, int(0)),
        (28, str_("")),
        (29, int(0)),
        (30, str_(&device.brand)),
        (31, str_(&device.brand)),
        (32, str_("")),
        (33, JceValue::Bytes(pb_blob)),
        (34, int(0)),
        // 35: null
        (36, int(0)),
        // 37: null
        (38, int(1000)),
        (39, int(98)),
    ];

    let struct_bytes = encode_struct(&fields)?;
    let attrs = [("SvcReqRegister".to_string(), struct_bytes)];
    Ok(encode_wrapper("PushService", "SvcReqRegister", &attrs)?)
}

/// 判读响应：`decode_wrapper(payload)[9]` 真值 = 注册成功（参考实现同款）。
pub fn parse_response(payload: &[u8]) -> Result<bool, RegisterError> {
    let rsp = decode_wrapper(payload)?;
    // 与 Dart 的 `v != null && v != 0` 同义：非数值类型必然不等于 0。
    Ok(match rsp.get(&9) {
        None => false,
        Some(JceValue::Int(v)) => *v != 0,
        Some(_) => true,
    })
}
