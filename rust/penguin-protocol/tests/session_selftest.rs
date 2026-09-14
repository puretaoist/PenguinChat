//! 会话层离线自测（Rust 侧），对齐 Dart 侧 `tool/qq8_session_selftest.dart`：
//! 用脚本化传输跑一遍"登录之后"的完整流程（注册 → 校时 → 心跳 → 推送 → 掉线）。

#![allow(clippy::unwrap_used)]

use std::sync::Arc;
use std::time::Duration;

use penguin_crypto::tea::qq_tea_encrypt;
use penguin_protocol::device::{AndroidVersion, Device};
use penguin_protocol::jce::{self, JceValue};
use penguin_protocol::pb::{encode as pb_encode, PbValue};
use penguin_protocol::profiles::QQ_8950;
use penguin_protocol::recv;
use penguin_protocol::session::{Session, SessionParams};
use penguin_protocol::sso::SigInfo;
use penguin_protocol::tran;
use tokio::sync::broadcast;

const D2KEY_HEX: &str = "00112233445566778899aabbccddeeff";

fn hex(s: &str) -> Vec<u8> {
    hex::decode(s).unwrap()
}

fn device() -> Device {
    Device {
        product: "piano".into(),
        device: "piano".into(),
        board: "piano".into(),
        brand: "Xiaomi".into(),
        model: "25091RP04C".into(),
        bootloader: "unknown".into(),
        fingerprint: "Xiaomi/piano/piano:16/BP2A/eng:user/release-keys".into(),
        boot_id: "11111111-2222-3333-4444-555555555555".into(),
        proc_version: "Linux version 5.15.0".into(),
        baseband: String::new(),
        sim: "T-Mobile".into(),
        apn: "wifi".into(),
        os_type: "android".into(),
        mac_address: "00:50:56:C0:00:08".into(),
        ip_address: "10.0.0.1".into(),
        wifi_bssid: "00:50:56:C0:00:08".into(),
        wifi_ssid: "TP-LINK-2711".into(),
        imei: "860000000000001".into(),
        android_id: "ABCDEF1234567890".into(),
        version: AndroidVersion {
            release: "10".into(),
            codename: "REL".into(),
            incremental: "1234567".into(),
            sdk: 29,
        },
        imsi: vec![0; 16],
        tgtgt: vec![0; 16],
        guid: hex("00112233445566778899aabbccddeeff"),
    }
}

/// 造一个真机结构的响应帧：`[外壳(flag=2)][SSO 头][payload]`。
fn frame(seq: i32, cmd: &str, payload: Option<Vec<u8>>) -> Vec<u8> {
    let cmd_bytes = cmd.as_bytes();
    let mut header = Vec::new();
    header.extend_from_slice(&0u32.to_be_bytes()); // headlen 占位
    header.extend_from_slice(&(seq as u32).to_be_bytes());
    header.extend_from_slice(&0u32.to_be_bytes()); // retcode
    header.extend_from_slice(&4u32.to_be_bytes());
    header.extend_from_slice(&((cmd_bytes.len() + 4) as u32).to_be_bytes());
    header.extend_from_slice(cmd_bytes);
    header.extend_from_slice(&8u32.to_be_bytes());
    header.extend_from_slice(&hex("01020304"));
    header.extend_from_slice(&0u32.to_be_bytes());
    let headlen = (header.len() - 4) as u32;
    header[..4].copy_from_slice(&headlen.to_be_bytes());

    let mut plain = header;
    if let Some(p) = payload {
        plain.extend_from_slice(&p);
    }

    let uin_bytes = b"10001";
    let mut out = Vec::new();
    out.extend_from_slice(&0x0Au32.to_be_bytes());
    out.push(2); // TEA 全零密钥
    out.extend_from_slice(&0u32.to_be_bytes()); // d2len
    out.push(4 + uin_bytes.len() as u8);
    out.extend_from_slice(uin_bytes);
    out.extend_from_slice(&qq_tea_encrypt(&plain, &[0u8; 16], None).unwrap());
    out
}

/// 注册响应（WUP 包装，`rsp[9]` 为结果码）。
fn register_resp(result: i64) -> Vec<u8> {
    let struct_bytes =
        jce::encode_struct(&[(0, JceValue::Int(10001)), (9, JceValue::Int(result))]).unwrap();
    let attrs = vec![(
        JceValue::Str("SvcRespRegister".into()),
        JceValue::Bytes(struct_bytes),
    )];
    let payload = jce::encode(&[(0, JceValue::Map(attrs))]).unwrap();
    jce::encode(&[(7, JceValue::Bytes(payload))]).unwrap()
}

/// 从 UNI 包里拆出命令字与 body（测试断言用）。
fn uni_parts(pkt: &[u8], d2key: &[u8]) -> (String, Vec<u8>) {
    // [u32 total][u32 0x0B][u8 1][i32 seq][u8 0][u32 uinLen][uin][TEA(sso)]
    let mut pos = 14;
    let uin_len = u32::from_be_bytes([pkt[pos], pkt[pos + 1], pkt[pos + 2], pkt[pos + 3]]) as usize;
    pos += uin_len;
    let sso = penguin_crypto::tea::qq_tea_decrypt(&pkt[pos..], d2key).unwrap();

    let cmd_len = u32::from_be_bytes([sso[4], sso[5], sso[6], sso[7]]) as usize;
    let cmd = String::from_utf8(sso[8..8 + cmd_len - 4].to_vec()).unwrap();
    let mut p = 8 + cmd_len - 4;
    p += 4; // session 长度字段
    p += 4; // session
    p += 4; // 固定 4
    let body_len = u32::from_be_bytes([sso[p], sso[p + 1], sso[p + 2], sso[p + 3]]) as usize;
    let body = sso[p + 4..p + body_len].to_vec();
    (cmd, body)
}

fn session_with(transport: tran::Transport) -> Session {
    let mut params = SessionParams::new(
        QQ_8950,
        10001,
        device(),
        hex("01020304"),
        hex(&format!("04{}", "11".repeat(64))),
        hex("f3df7dfb6d55b17975d908d8228dee11"),
    );
    params.sig = SigInfo {
        d2key: hex(D2KEY_HEX),
        tgt: hex("1122334455667788"),
        ..Default::default()
    };
    params.random_key = hex("0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f");
    params.seq_start = 100;
    params.request_timeout = Duration::from_millis(200); // 离线自测不等 15s
    Session::new(transport, params)
}

#[tokio::test]
async fn session_flow_offline() {
    const FIXED_TS: i64 = 1800000000; // 0x6b49d200

    let (transport, control) = tran::Transport::scripted(vec![
        frame(101, "StatSvc.register", Some(register_resp(1))),
        frame(102, "Client.CorrectTime", Some(hex("6b49d200"))),
        frame(103, "Heartbeat.Alive", None),
        frame(104, "OidbSvc.0x480_9_IMCore", Some(hex("0a00"))),
    ]);

    let session = session_with(transport);
    let mut errors = session.subscribe_errors();
    let mut offline = session.subscribe_offline();
    let mut pushes = session.subscribe_pushes();
    session.start().unwrap();

    // 1. 注册（seq 101）
    assert!(session.register(false).await.unwrap(), "register() = true");
    assert!(errors.try_recv().is_err(), "收包不应有解析错误");
    let sent = control.sent();
    assert_eq!(&sent[0][4..8], &[0, 0, 0, 0x0a][..], "发的是登录层包");

    // 2. 校时（seq 102）
    let ts = session.correct_time().await.unwrap();
    assert_eq!(ts, FIXED_TS, "返回服务端时间");
    let expect = FIXED_TS
        - std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
    assert!(
        (session.time_diff_seconds() - expect).abs() <= 5,
        "timeDiffSeconds 与本地时钟的差应在 ±5 秒内（实得 {}）",
        session.time_diff_seconds()
    );

    // 3. Heartbeat.Alive（seq 103）
    let hb = session.heartbeat_alive().await.unwrap();
    assert_eq!(hb.payload.len(), 0, "空闲响应");
    assert!(
        String::from_utf8_lossy(&control.sent()[2]).contains("Heartbeat.Alive"),
        "帧里应带命令字 Heartbeat.Alive"
    );

    // 4. UNI 心跳（seq 104）
    let uni = session.uni_heartbeat().await.unwrap();
    assert_eq!(uni.cmd, "OidbSvc.0x480_9_IMCore");
    let (cmd, body) = uni_parts(&control.sent()[3], &hex(D2KEY_HEX));
    assert_eq!(cmd, "OidbSvc.0x480_9_IMCore", "UNI 包命令字");
    let mut buf = [0u8; 9];
    buf[0..4].copy_from_slice(&10001u32.to_be_bytes());
    buf[5..9].copy_from_slice(&0x19e39i32.to_be_bytes());
    let expect_body = pb_encode(&[
        (1, PbValue::Int(1152)),
        (2, PbValue::Int(9)),
        (4, PbValue::Bytes(buf.to_vec())),
    ])
    .unwrap();
    assert_eq!(body, expect_body, "UNI 心跳 body = pb {{1:1152,2:9,4:…}}");

    // 5. 主动推送路由：seq 不匹配任何请求 → 进 pushes 流
    control.emit(frame(999, "MessageSvc.PushNotify", Some(hex("cafe"))));
    let push = tokio::time::timeout(Duration::from_secs(2), pushes.recv())
        .await
        .expect("2s 内应收到推送")
        .unwrap();
    assert_eq!(push.seq, 999);
    assert_eq!(push.cmd, "MessageSvc.PushNotify");
    assert_eq!(push.payload, hex("cafe"));

    // 6. 心跳失败的降级：脚本已用尽 → 请求超时 → 心跳返回 false 且通知 offline
    assert!(!session.heartbeat_once().await, "脚本用尽 → 一轮心跳失败");
    assert!(
        tokio::time::timeout(Duration::from_secs(1), offline.recv())
            .await
            .is_ok(),
        "应触发 offline 通知"
    );
    assert!(!session.is_online(), "失败后置离线");

    session.close().await;
    assert!(!session.is_online());
}

/// 拆壳层的真实帧回归：本测试构造的帧能被 [`recv::unwrap_recv`] 解回原 payload。
#[test]
fn constructed_frames_are_decodable() {
    let f = frame(7, "Test.Cmd", Some(vec![1, 2, 3]));
    let r = recv::unwrap_recv(&f, None).unwrap();
    assert_eq!(r.seq, 7);
    assert_eq!(r.cmd, "Test.Cmd");
    assert_eq!(r.payload, vec![1, 2, 3]);
    assert_eq!(r.flag, 2);
}

/// `Arc<Session>` 下也能起心跳循环并关会话（CLI 的用法）。
#[tokio::test]
async fn heartbeat_loop_on_arc_session() {
    let (transport, _control) = tran::Transport::scripted(vec![]);
    let session = Arc::new(session_with(transport));
    session.start().unwrap();

    let task = session.start_heartbeat(Duration::from_millis(50));
    assert!(session.is_online(), "start_heartbeat 后应为在线");

    // 脚本为空 → 第一拍心跳就失败 → 循环自行退出
    tokio::time::timeout(Duration::from_secs(3), task)
        .await
        .expect("心跳循环应在失败后退出")
        .unwrap();
    assert!(!session.is_online(), "心跳失败后应置离线");

    session.close().await;
}

/// broadcast 通道未订阅时发送不应 panic（会话可能在无人监听时收到推送）。
#[test]
fn broadcast_without_subscriber() {
    let (tx, _) = broadcast::channel::<u8>(4);
    assert!(
        tx.send(1).is_err(),
        "无订阅者时 send 返回 Err，但不应 panic"
    );
}
