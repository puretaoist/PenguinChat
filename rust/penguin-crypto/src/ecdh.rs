//! prime256v1（NIST P-256）上的 ECDH。
//!
//! Dart 侧对应实现：`lib/kernel/crypto/ecdh.dart`。
//!
//! 规则（已由 Node `createECDH('prime256v1')` 的向量确认）：
//!
//! * 公钥 = **未压缩**点（65 字节，首字节 0x04）；
//! * 共享密钥 = `MD5(ECDH 共享秘密的 X 坐标[0..16])`——**截断再 MD5**，
//!   不是"MD5 再截断"（`tool/qq8_selftest.dart` 里有专项断言）。

use md5::{Digest, Md5};
use p256::elliptic_curve::sec1::ToEncodedPoint;

#[derive(Debug, PartialEq, Eq)]
pub enum EcdhError {
    /// 私钥必须是 32 字节且落在曲线阶内。
    BadPrivateKey,
    /// 公钥必须是合法的 SEC1 编码（本项目只接受未压缩 65 字节）。
    BadPublicKey,
}

impl std::fmt::Display for EcdhError {
    fn fmt(&self, fmt: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EcdhError::BadPrivateKey => write!(fmt, "私钥非法（须 32 字节且 < 曲线阶）"),
            EcdhError::BadPublicKey => write!(fmt, "公钥非法（须 SEC1 未压缩 65 字节）"),
        }
    }
}

impl std::error::Error for EcdhError {}

/// 一次 ECDH 交换的结果。
pub struct EcdhResult {
    /// 未压缩公钥（65 字节）。
    pub public_key: Vec<u8>,
    /// 共享密钥（16 字节）：`MD5(secret[0..16])`。
    pub share_key: Vec<u8>,
}

/// 与 [server_pub] 做 ECDH。
///
/// `private_key` 为 `None` 时随机生成（生产路径）；为 `Some` 时使用固定
/// 私钥（测试/向量），须 32 字节。
pub fn ecdh_exchange(
    server_pub: &[u8],
    private_key: Option<&[u8]>,
) -> Result<EcdhResult, EcdhError> {
    let sk = match private_key {
        Some(p) => p256::SecretKey::from_slice(p).map_err(|_| EcdhError::BadPrivateKey)?,
        None => p256::SecretKey::random(&mut rand_core::OsRng),
    };
    let peer = p256::PublicKey::from_sec1_bytes(server_pub).map_err(|_| EcdhError::BadPublicKey)?;

    let shared = p256::ecdh::diffie_hellman(sk.to_nonzero_scalar(), peer.as_affine());
    let secret = shared.raw_secret_bytes();

    let mut hasher = Md5::new();
    hasher.update(&secret[..16]);
    let share_key = hasher.finalize().to_vec();

    Ok(EcdhResult {
        public_key: sk.public_key().to_encoded_point(false).as_bytes().to_vec(),
        share_key,
    })
}
