//! TCP 传输层（tokio），对应 Dart 侧 `lib/kernel/wlogin8/qq8_tran.dart`。
//!
//! ## 分帧格式
//!
//! ```text
//!   +--------+---------------------------+
//!   | u32    | payload                   |
//!   | total  | total - 4 字节             |
//!   +--------+---------------------------+
//!   total = 4 + payload.length
//! ```
//!
//! 来源：参考实现 oicq `lib/client-net.js` 的 `data` 处理（4 字节大端长度、
//! **长度含自身**、`slice(4, len)` 后的交给上层）。⚠️ 这与 OICQ 信封自己的
//! `0x02` + u16 头是**两层**，不要混。
//!
//! ## 谁负责这个 u32（踩过坑）
//!
//! **发送侧：调用方给的必须是"完整线上包"**——登录包自带这个 u32
//! （[`crate::sso::build_login_packet`] 返回值的第一个字段就是自己的总长），
//! 传输层**原样写出、不再加任何前缀**。
//!
//! ⚠️ 血泪注记：发送侧曾画蛇添足地又套了一次分帧 → 线上多 4 字节，服务端按
//! 错位长度解析、**静默不回**（2026-09-11 真机实测：TCP 连上、1388 字节发出、
//! 15s 无响应）。[`frame_packet`] 只用于构造 mock 服务端的响应帧。
//!
//! ## 结构
//!
//! 传输层做成"句柄 + 后台任务"：`Transport` 持出站/入站两条 channel，读写任务
//! 由 [`Transport::tcp`] 起；[`Transport::scripted`] 用同样两条 channel 回放
//! 预置响应，因此**会话层的离线自测走的是与生产同一条路径**。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

/// 默认登录服务器（与 oicq 的 `default_host` 一致）。
pub const DEFAULT_HOST: &str = "msfwifi.3g.qq.com";
/// 默认端口。
pub const DEFAULT_PORT: u16 = 8080;
/// 单次请求的默认超时。
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug, PartialEq)]
pub enum TransportError {
    /// 帧长度非法（流已错位）。
    IllegalFrameLength(u32),
    Connect(String),
    Write(String),
    Read(String),
    /// 等待响应超时。
    Timeout(String),
    /// 脚本传输的预置响应已用尽。
    ScriptExhausted(usize),
    /// 传输层已关闭。
    Closed,
}

impl std::fmt::Display for TransportError {
    fn fmt(&self, fmt: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TransportError::IllegalFrameLength(n) => write!(
                fmt,
                "非法帧长度 {n}（应在 {}..{} 之间）",
                FrameDecoder::HEADER_LENGTH,
                FrameDecoder::MAX_FRAME_LENGTH
            ),
            TransportError::Connect(s) => write!(fmt, "连接失败：{s}"),
            TransportError::Write(s) => write!(fmt, "发送失败：{s}"),
            TransportError::Read(s) => write!(fmt, "读取失败：{s}"),
            TransportError::Timeout(s) => write!(fmt, "等待响应超时（{s}）"),
            TransportError::ScriptExhausted(n) => {
                write!(fmt, "脚本已用尽（第 {n} 个请求无响应）")
            }
            TransportError::Closed => write!(fmt, "传输层已关闭"),
        }
    }
}

impl std::error::Error for TransportError {}

/// 把 TCP 字节流切成一个个 packet。
///
/// 必须处理两种情况，二者都会真实发生：
/// * **半包** —— 一次读到一部分，要缓存等后续；
/// * **粘包** —— 一次读到多个完整包，要全部吐出。
///
/// 还要能识别**长度非法**的包（服务端返回错误页/被中间设备劫持时会出现），
/// 否则会在等一个永远不来的包时静默卡死。
#[derive(Debug, Default)]
pub struct FrameDecoder {
    buf: Vec<u8>,
}

impl FrameDecoder {
    /// 长度前缀的字节数。
    pub const HEADER_LENGTH: usize = 4;
    /// 单包上限（4 MiB）。超过就认为流已经错位，宁可直接报错也不要无限缓存。
    pub const MAX_FRAME_LENGTH: usize = 1 << 22;

    pub fn new() -> FrameDecoder {
        FrameDecoder { buf: Vec::new() }
    }

    /// 已缓存但尚未成帧的字节数。
    pub fn buffered_bytes(&self) -> usize {
        self.buf.len()
    }

    /// 送入一批字节，返回其中所有**完整**的 payload（不含长度头）。
    pub fn add(&mut self, chunk: &[u8]) -> Result<Vec<Vec<u8>>, TransportError> {
        let mut out = Vec::new();
        self.buf.extend_from_slice(chunk);

        let mut cursor = 0usize;
        while self.buf.len() - cursor >= Self::HEADER_LENGTH {
            let total = u32::from_be_bytes([
                self.buf[cursor],
                self.buf[cursor + 1],
                self.buf[cursor + 2],
                self.buf[cursor + 3],
            ]);
            if (total as usize) < Self::HEADER_LENGTH || total as usize > Self::MAX_FRAME_LENGTH {
                // 流已经错位。把缓冲清掉，避免后续每一轮都报同一个错。
                self.buf.clear();
                return Err(TransportError::IllegalFrameLength(total));
            }
            if self.buf.len() - cursor < total as usize {
                break; // 半包，等下一批
            }
            out.push(self.buf[cursor + Self::HEADER_LENGTH..cursor + total as usize].to_vec());
            cursor += total as usize;
        }

        if cursor > 0 {
            self.buf.drain(..cursor);
        }
        Ok(out)
    }

    /// 清空缓冲（重连时用）。
    pub fn reset(&mut self) {
        self.buf.clear();
    }
}

/// 给 payload 套上 4 字节长度头，得到**线上字节**。
///
/// 只用于构造/模拟线上的帧（自测里的 mock 服务端、脚本传输）——**生产发送
/// 路径不调用它**（见文件头"谁负责这个 u32"）。
pub fn frame_packet(payload: &[u8]) -> Vec<u8> {
    let total = (4 + payload.len()) as u32;
    let mut out = Vec::with_capacity(total as usize);
    out.extend_from_slice(&total.to_be_bytes());
    out.extend_from_slice(payload);
    out
}

/// 传输层句柄：出站走 [`Transport::send`]，入站帧从 [`Transport::take_frames`]
/// 拿到（会话层在后台任务里按 seq 路由）。
///
/// 全部方法取 `&self`（内部可变）——会话层会在 `Arc<Session>` 下调用。
pub struct Transport {
    tx: Mutex<Option<mpsc::UnboundedSender<Vec<u8>>>>,
    frames: Mutex<Option<mpsc::UnboundedReceiver<Vec<u8>>>>,
    connected: Arc<AtomicBool>,
    write_task: Mutex<Option<JoinHandle<()>>>,
}

impl Transport {
    /// 真实 TCP：起一个写任务（出站 channel → socket）与一个读任务
    /// （socket → 分帧 → 入站 channel）。
    pub async fn tcp(host: &str, port: u16) -> Result<Transport, TransportError> {
        let stream = TcpStream::connect((host, port))
            .await
            .map_err(|e| TransportError::Connect(format!("{host}:{port}: {e}")))?;
        let _ = stream.set_nodelay(true);

        let (tx, mut out_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let (frames_tx, frames_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let connected = Arc::new(AtomicBool::new(true));
        let (mut rd, mut wr) = stream.into_split();

        let write_task = tokio::spawn(async move {
            while let Some(pkt) = out_rx.recv().await {
                if wr.write_all(&pkt).await.is_err() {
                    break;
                }
            }
            // 出站 channel 关闭（或写失败）→ 关掉写半边。
            let _ = wr.shutdown().await;
        });

        let conn = connected.clone();
        tokio::spawn(async move {
            let mut decoder = FrameDecoder::new();
            let mut buf = vec![0u8; 8192];
            loop {
                match rd.read(&mut buf).await {
                    Ok(0) => break, // 对端关闭
                    Ok(n) => match decoder.add(&buf[..n]) {
                        Ok(frames) => {
                            for f in frames {
                                if frames_tx.send(f).is_err() {
                                    break;
                                }
                            }
                        }
                        Err(_) => break, // 流错位：断开，让上层看到超时/关闭
                    },
                    Err(_) => break,
                }
            }
            conn.store(false, Ordering::SeqCst);
        });

        Ok(Transport {
            tx: Mutex::new(Some(tx)),
            frames: Mutex::new(Some(frames_rx)),
            connected,
            write_task: Mutex::new(Some(write_task)),
        })
    }

    /// 脚本化传输（离线自测）：每收到一个请求，按序回一个预置响应帧。
    pub fn scripted(responses: Vec<Vec<u8>>) -> (Transport, ScriptedControl) {
        let (tx, mut out_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let (frames_tx, frames_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let connected = Arc::new(AtomicBool::new(true));
        let sent: Arc<Mutex<Vec<Vec<u8>>>> = Arc::new(Mutex::new(Vec::new()));

        let sent_log = sent.clone();
        let frames = frames_tx.clone();
        tokio::spawn(async move {
            let mut cursor = 0usize;
            while let Some(pkt) = out_rx.recv().await {
                sent_log.lock().unwrap().push(pkt);
                if cursor >= responses.len() {
                    // 与 Dart 侧一致：脚本用尽时不再回帧，由上层超时/失败兜底。
                    continue;
                }
                if frames.send(responses[cursor].clone()).is_err() {
                    break;
                }
                cursor += 1;
            }
        });

        let transport = Transport {
            tx: Mutex::new(Some(tx)),
            frames: Mutex::new(Some(frames_rx)),
            connected: connected.clone(),
            write_task: Mutex::new(None),
        };
        (
            transport,
            ScriptedControl {
                sent,
                frames_tx,
                connected,
            },
        )
    }

    /// 发一个**完整线上包**（自带 u32 分帧头，原样写出）。
    pub async fn send(&self, packet: &[u8]) -> Result<(), TransportError> {
        let tx = self
            .tx
            .lock()
            .unwrap()
            .clone()
            .ok_or(TransportError::Closed)?;
        tx.send(packet.to_vec()).map_err(|_| TransportError::Closed)
    }

    /// 取走入站帧的接收端（只能取一次）。
    ///
    /// 两种消费方式都从这里开始：会话层把它交给路由任务；单发工具直接
    /// 在返回的接收端上 `recv().await`。（不做 `&self` 上的 `recv()`——
    /// 那会把锁守卫跨过 await 点，clippy 已拦。）
    pub fn take_frames(&self) -> Option<mpsc::UnboundedReceiver<Vec<u8>>> {
        self.frames.lock().unwrap().take()
    }

    pub fn is_connected(&self) -> bool {
        self.connected.load(Ordering::SeqCst)
    }

    /// 关闭：关掉出站 channel（写任务随之结束并关写半边），置未连接。
    pub async fn close(&self) {
        self.tx.lock().unwrap().take();
        self.frames.lock().unwrap().take();
        self.connected.store(false, Ordering::SeqCst);
        if let Some(t) = self.write_task.lock().unwrap().take() {
            t.abort();
        }
    }
}

/// 脚本传输的控制面（测试用）：查已收到的请求、手动投递推送帧。
pub struct ScriptedControl {
    sent: Arc<Mutex<Vec<Vec<u8>>>>,
    frames_tx: mpsc::UnboundedSender<Vec<u8>>,
    connected: Arc<AtomicBool>,
}

impl ScriptedControl {
    /// 已收到的请求（按顺序）。
    pub fn sent(&self) -> Vec<Vec<u8>> {
        self.sent.lock().unwrap().clone()
    }

    /// 手动投递一个帧（模拟服务端主动推送）。
    pub fn emit(&self, frame: Vec<u8>) {
        let _ = self.frames_tx.send(frame);
    }

    pub fn is_connected(&self) -> bool {
        self.connected.load(Ordering::SeqCst)
    }
}
