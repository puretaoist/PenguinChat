//! 会话层：登录之后的请求路由、注册与心跳，对应 Dart 侧
//! `lib/kernel/wlogin8/qq8_session.dart`。
//!
//! ## 职责
//!
//! * **seq 分配与配对**：每个请求一个 seq（[`uni::next_seq`]，1..0x7FFF 回绕），
//!   响应由后台路由任务按 SSO 头里的 seq 找回等待者；
//! * **推送**：没有匹配请求的帧进 pushes 广播流（服务端主动下发）；
//! * **两种发送形态**：登录层（[`sso::build_login_packet`]，type 0/1）与
//!   UNI 包（[`uni::build`]，业务请求）；
//! * **注册与心跳三件套**：`register` / `heartbeat_alive` / `correct_time` /
//!   `uni_heartbeat`，以及周期循环 `start_heartbeat`。
//!
//! 收包路径：传输层每帧 → [`recv::unwrap_recv`]（外壳 + SSO 头）→ 按 seq 配对，
//! 否则进推送流。对应参考实现 oicq 的 `packetListener` + `HANDLERS`。
//!
//! ## 为什么要这一层
//!
//! 直连模式下没有 OneBot 后端替你维持连接：登录只解决"拿到票据"，之后要自己
//! 注册上线、按周期心跳、处理主动推送——这一层就是那些事的家。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU16, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::{broadcast, oneshot, RwLock};
use tokio::task::JoinHandle;

use crate::device::Device;
use crate::login::{LoginError, SigBundle};
use crate::pb::{encode as pb_encode, PbValue};
use crate::profiles::ApkInfo;
use crate::recv::{self, RecvError, SsoResponse};
use crate::register;
use crate::sso::{self, login_type, SigInfo, SsoContext};
use crate::tran::{Transport, TransportError, DEFAULT_TIMEOUT};
use crate::uni;

/// 会话层错误。
#[derive(Debug)]
pub enum SessionError {
    Transport(TransportError),
    Recv(RecvError),
    Login(LoginError),
    Register(register::RegisterError),
    Uni(String),
    /// 协议层超时（等待响应）。
    Timeout {
        seq: u32,
        secs: u64,
    },
    /// 还没 `start()`（收包路由未建立）。
    NotStarted,
}

impl std::fmt::Display for SessionError {
    fn fmt(&self, fmt: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SessionError::Transport(e) => write!(fmt, "{e}"),
            SessionError::Recv(e) => write!(fmt, "{e}"),
            SessionError::Login(e) => write!(fmt, "{e}"),
            SessionError::Register(e) => write!(fmt, "{e}"),
            SessionError::Uni(e) => write!(fmt, "UNI 包：{e}"),
            SessionError::Timeout { seq, secs } => {
                write!(fmt, "等待响应超时（seq={seq}，{secs}s）")
            }
            SessionError::NotStarted => write!(fmt, "会话尚未 start()，无法发送"),
        }
    }
}

impl std::error::Error for SessionError {}

impl From<TransportError> for SessionError {
    fn from(e: TransportError) -> Self {
        SessionError::Transport(e)
    }
}

impl From<RecvError> for SessionError {
    fn from(e: RecvError) -> Self {
        SessionError::Recv(e)
    }
}

impl From<LoginError> for SessionError {
    fn from(e: LoginError) -> Self {
        SessionError::Login(e)
    }
}

impl From<register::RegisterError> for SessionError {
    fn from(e: register::RegisterError) -> Self {
        SessionError::Register(e)
    }
}

/// 会话构造参数（字段与 Dart 侧构造器一一对应）。
pub struct SessionParams {
    pub profile: ApkInfo,
    pub uin: u32,
    pub device: Device,
    /// 4 字节会话标识（UNI 包用；登录时生成，之后固定）。
    pub session_id: Vec<u8>,
    /// 本次登录的 ECDH 公钥与共享密钥（登录层信封）。
    pub ecdh_public_key: Vec<u8>,
    pub ecdh_share_key: Vec<u8>,
    /// 票据集合；登录成功后用 [`Session::update_sig`] 填。
    pub sig: SigInfo,
    /// 登录层信封里的随机密钥（oicq 的 `random_key`：登录时生成一次、之后复用）。
    pub random_key: Vec<u8>,
    /// seq 起点（默认 0，下一个请求从 1 开始）。
    pub seq_start: u16,
    /// 单次请求的默认超时（不传 timeout 时用）。
    pub request_timeout: Duration,
}

impl SessionParams {
    pub fn new(
        profile: ApkInfo,
        uin: u32,
        device: Device,
        session_id: Vec<u8>,
        ecdh_public_key: Vec<u8>,
        ecdh_share_key: Vec<u8>,
    ) -> Self {
        Self {
            profile,
            uin,
            device,
            session_id,
            ecdh_public_key,
            ecdh_share_key,
            sig: SigInfo::default(),
            random_key: os_random(16),
            seq_start: 0,
            request_timeout: DEFAULT_TIMEOUT,
        }
    }
}

fn os_random(n: usize) -> Vec<u8> {
    let mut out = vec![0u8; n];
    if getrandom::getrandom(&mut out).is_err() {
        panic!("系统随机源不可用");
    }
    out
}

/// 长连接会话：路由（seq 配对/推送）、注册与心跳。
pub struct Session {
    transport: Transport,
    profile: ApkInfo,
    uin: u32,
    device: Device,
    session_id: Vec<u8>,
    ecdh_public_key: Vec<u8>,
    ecdh_share_key: Vec<u8>,
    random_key: Vec<u8>,
    sig: Arc<RwLock<SigInfo>>,
    time_diff_seconds: Arc<AtomicI64>,
    seq: Arc<AtomicU16>,
    pending: Arc<Mutex<HashMap<i32, oneshot::Sender<SsoResponse>>>>,
    pushes: broadcast::Sender<SsoResponse>,
    errors: broadcast::Sender<RecvError>,
    offline: broadcast::Sender<()>,
    online: Arc<AtomicBool>,
    started: AtomicBool,
    request_timeout: Duration,
}

impl Session {
    pub fn new(transport: Transport, params: SessionParams) -> Session {
        let (pushes, _) = broadcast::channel(64);
        let (errors, _) = broadcast::channel(16);
        let (offline, _) = broadcast::channel(4);
        Session {
            transport,
            profile: params.profile,
            uin: params.uin,
            device: params.device,
            session_id: params.session_id,
            ecdh_public_key: params.ecdh_public_key,
            ecdh_share_key: params.ecdh_share_key,
            random_key: params.random_key,
            sig: Arc::new(RwLock::new(params.sig)),
            time_diff_seconds: Arc::new(AtomicI64::new(0)),
            seq: Arc::new(AtomicU16::new(params.seq_start)),
            pending: Arc::new(Mutex::new(HashMap::new())),
            pushes,
            errors,
            offline,
            online: Arc::new(AtomicBool::new(false)),
            started: AtomicBool::new(false),
            request_timeout: params.request_timeout,
        }
    }

    /// 服务端主动下发的帧（没有匹配请求的那些）。
    pub fn subscribe_pushes(&self) -> broadcast::Receiver<SsoResponse> {
        self.pushes.subscribe()
    }

    /// 收包解析失败（不中断会话）。
    pub fn subscribe_errors(&self) -> broadcast::Receiver<RecvError> {
        self.errors.subscribe()
    }

    /// 心跳连失败两次（视为掉线）时收到一次通知。
    pub fn subscribe_offline(&self) -> broadcast::Receiver<()> {
        self.offline.subscribe()
    }

    /// 是否已注册上线（[Session::start_heartbeat] 成功后为真）。
    pub fn is_online(&self) -> bool {
        self.online.load(Ordering::SeqCst)
    }

    pub fn is_connected(&self) -> bool {
        self.transport.is_connected()
    }

    /// 与服务端的时间差（秒），[Session::correct_time] 之后有值。
    pub fn time_diff_seconds(&self) -> i64 {
        self.time_diff_seconds.load(Ordering::SeqCst)
    }

    /// 建立收包路由（把传输层的入站帧交给后台任务按 seq 派发）。
    pub fn start(&self) -> Result<(), SessionError> {
        if self.started.load(Ordering::SeqCst) {
            return Ok(());
        }
        let mut frames = self
            .transport
            .take_frames()
            .ok_or(SessionError::NotStarted)?;
        let pending = self.pending.clone();
        let pushes = self.pushes.clone();
        let errors = self.errors.clone();
        let sig = self.sig.clone();
        tokio::spawn(async move {
            while let Some(frame) = frames.recv().await {
                let d2key = sig.read().await.d2key.clone();
                match recv::unwrap_recv(&frame, Some(&d2key)) {
                    Ok(r) => {
                        let waiter = pending.lock().unwrap().remove(&r.seq);
                        match waiter {
                            Some(tx) => {
                                let _ = tx.send(r);
                            }
                            None => {
                                let _ = pushes.send(r); // 没人在等 → 推送
                            }
                        }
                    }
                    Err(e) => {
                        let _ = errors.send(e);
                    }
                }
            }
            // 入站流结束（连接断开/传输关闭）：让在等的请求立刻失败，
            // 而不是各自干等到超时。
            pending.lock().unwrap().clear();
        });
        self.started.store(true, Ordering::SeqCst);
        Ok(())
    }

    /// 登录成功后的票据映射（[`SigBundle`] → 会话内 [`SigInfo`]）。
    pub async fn update_sig(&self, bundle: &SigBundle) {
        let mut sig = self.sig.write().await;
        *sig = SigInfo {
            tgt: bundle.tgt.clone().unwrap_or_default(),
            d2: bundle.d2.clone().unwrap_or_default(),
            d2key: bundle.d2key.clone().unwrap_or_default(),
            sig_key: bundle.sig_key.clone().unwrap_or_default(),
            ticket_key: bundle.ticket_key.clone().unwrap_or_default(),
            srm_token: bundle.srm_token.clone().unwrap_or_default(),
        };
    }

    fn next_seq(&self) -> u16 {
        let next = uni::next_seq(self.seq.load(Ordering::SeqCst) as u32) as u16;
        self.seq.store(next, Ordering::SeqCst);
        next
    }

    async fn sso_ctx(&self, seq: u16) -> SsoContext {
        SsoContext {
            uin: self.uin,
            apk: self.profile.clone(),
            device: self.device.clone(),
            session_id: self.session_id.clone(),
            random_key: self.random_key.clone(),
            ecdh_public_key: self.ecdh_public_key.clone(),
            ecdh_share_key: self.ecdh_share_key.clone(),
            sig: self.sig.read().await.clone(),
            seq_id: seq as u32,
        }
    }

    async fn send_and_wait(
        &self,
        seq: u16,
        packet: Vec<u8>,
        timeout: Option<Duration>,
    ) -> Result<SsoResponse, SessionError> {
        if !self.started.load(Ordering::SeqCst) {
            return Err(SessionError::NotStarted);
        }
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(seq as i32, tx);
        if let Err(e) = self.transport.send(&packet).await {
            self.pending.lock().unwrap().remove(&(seq as i32));
            return Err(SessionError::Transport(e));
        }
        let dur = timeout.unwrap_or(self.request_timeout);
        match tokio::time::timeout(dur, rx).await {
            Ok(Ok(resp)) => Ok(resp),
            Ok(Err(_)) => Err(SessionError::Transport(TransportError::Closed)),
            Err(_) => {
                self.pending.lock().unwrap().remove(&(seq as i32));
                Err(SessionError::Timeout {
                    seq: seq as u32,
                    secs: dur.as_secs(),
                })
            }
        }
    }

    /// 登录层请求（命令字 + 信封 type=0/1）。
    ///
    /// type 见 [`login_type`]：心跳类用 0（SSO 层不加密）、上线后用 1
    /// （SSO 层用 d2key 加密）。
    pub async fn send_login_layer(
        &self,
        cmd: &str,
        body: &[u8],
        ty: u8,
        timeout: Option<Duration>,
    ) -> Result<SsoResponse, SessionError> {
        let seq = self.next_seq();
        let ctx = self.sso_ctx(seq).await;
        let oicq = sso::build_oicq_packet(&ctx, body, false);
        let pkt = sso::build_login_packet(&ctx, cmd, &oicq, ty);
        self.send_and_wait(seq, pkt, timeout).await
    }

    /// UNI 包请求（业务命令字）。响应按 SSO 头里的 seq 配对。
    pub async fn send_uni(
        &self,
        cmd: &str,
        body: &[u8],
        timeout: Option<Duration>,
    ) -> Result<SsoResponse, SessionError> {
        let seq = self.next_seq();
        let d2key = self.sig.read().await.d2key.clone();
        let pkt = uni::build(self.uin, cmd, body, seq as u32, &self.session_id, &d2key)
            .map_err(|e| SessionError::Uni(e.to_string()))?;
        self.send_and_wait(seq, pkt, timeout).await
    }

    /// 上线注册（`StatSvc.register`）：登录成功后必须发的第一个业务请求。
    pub async fn register(&self, logout: bool) -> Result<bool, SessionError> {
        let body = register::build_body(self.uin, &self.device, logout, None)?;
        let r = self
            .send_login_layer(register::CMD, &body, login_type::ONLINE, None)
            .await?;
        Ok(register::parse_response(&r.payload)?)
    }

    /// `Heartbeat.Alive`：登录层 type=0、空 body。
    pub async fn heartbeat_alive(&self) -> Result<SsoResponse, SessionError> {
        self.send_login_layer("Heartbeat.Alive", &[], login_type::HEARTBEAT, None)
            .await
    }

    /// `Client.CorrectTime`：登录层 type=0、body = 4 个零字节；响应的前 4 字节
    /// 是服务端时间（i32），据此更新会话内的时差。
    pub async fn correct_time(&self) -> Result<i64, SessionError> {
        let r = self
            .send_login_layer("Client.CorrectTime", &[0u8; 4], login_type::HEARTBEAT, None)
            .await?;
        if r.payload.len() < 4 {
            return Err(SessionError::Login(LoginError::PlainTooShort(
                r.payload.len(),
            )));
        }
        let ts =
            i32::from_be_bytes([r.payload[0], r.payload[1], r.payload[2], r.payload[3]]) as i64;
        let now_secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        self.time_diff_seconds
            .store(ts - now_secs, Ordering::SeqCst);
        Ok(ts)
    }

    /// `OidbSvc.0x480_9_IMCore`：UNI 包心跳。
    ///
    /// body = pb `{1: 1152, 2: 9, 4: <9 字节：u32 uin(大端) + 1 字节空洞 + i32 0x19e39>}`。
    pub async fn uni_heartbeat(&self) -> Result<SsoResponse, SessionError> {
        let mut buf = [0u8; 9];
        buf[0..4].copy_from_slice(&self.uin.to_be_bytes());
        buf[5..9].copy_from_slice(&0x19e39i32.to_be_bytes());
        let body = pb_encode(&[
            (1, PbValue::Int(1152)),
            (2, PbValue::Int(9)),
            (4, PbValue::Bytes(buf.to_vec())),
        ])
        .map_err(|e| SessionError::Uni(e.to_string()))?;
        self.send_uni("OidbSvc.0x480_9_IMCore", &body, None).await
    }

    /// 单次心跳：校时（失败不致命）→ `Heartbeat.Alive` → UNI 心跳；
    /// 失败重试一次 UNI 心跳，仍失败则置离线并通知 offline。
    pub async fn heartbeat_once(&self) -> bool {
        let _ = self.correct_time().await;
        if self.heartbeat_alive().await.is_ok() && self.uni_heartbeat().await.is_ok() {
            return true;
        }
        if self.uni_heartbeat().await.is_ok() {
            return true;
        }
        self.online.store(false, Ordering::SeqCst);
        let _ = self.offline.send(());
        false
    }

    /// 开始心跳循环（默认 4.5 分钟，oicq 的 `interval` 量级）。
    ///
    /// 返回循环任务句柄：心跳失败（`heartbeat_once` 返回 false）时循环自行退出，
    /// 调用方也可以 `abort()` 提前停。
    pub fn start_heartbeat(self: &Arc<Self>, interval: Duration) -> JoinHandle<()> {
        self.online.store(true, Ordering::SeqCst);
        let session = self.clone();
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(interval);
            ticker.tick().await; // 第一拍立即到点，跳过
            loop {
                ticker.tick().await;
                if !session.heartbeat_once().await {
                    break;
                }
            }
        })
    }

    /// 结束会话：置离线、关连接。`Arc<Session>` 下也能调用。
    pub async fn close(&self) {
        self.online.store(false, Ordering::SeqCst);
        self.started.store(false, Ordering::SeqCst);
        self.transport.close().await;
    }
}
