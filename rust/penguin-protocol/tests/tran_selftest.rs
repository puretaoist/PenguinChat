//! 传输层离线自测（Rust 侧），对齐 Dart 侧 `tool/qq8_tran_selftest.dart`：
//! 分帧解码（半包/粘包/非法长度）+ 真实 TCP 回环（含"发送不加前缀"的回归）。

#![allow(clippy::unwrap_used)]

use std::time::Duration;

use penguin_protocol::tran::{frame_packet, FrameDecoder, Transport, TransportError};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// 套上 4 字节长度头后，长度字段**含自身**。
#[test]
fn frame_packet_layout() {
    let f = frame_packet(&[0xaa, 0xbb]);
    assert_eq!(f, vec![0, 0, 0, 6, 0xaa, 0xbb], "u32 长度应含自身 4 字节");
    let f = frame_packet(&[]);
    assert_eq!(f, vec![0, 0, 0, 4]);
}

#[test]
fn decoder_single_half_glued() {
    // 单包
    let d = &mut FrameDecoder::new();
    let out = d.add(&frame_packet(&[1, 2, 3])).unwrap();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0], vec![1, 2, 3]);
    assert_eq!(d.buffered_bytes(), 0, "缓冲应清空");

    // 半包：先给 3 字节，不出帧；补齐后出 1 帧
    let d = &mut FrameDecoder::new();
    let framed = frame_packet(&[9, 9, 9, 9]);
    assert!(d.add(&framed[..3]).unwrap().is_empty(), "半包不应出帧");
    assert_eq!(d.buffered_bytes(), 3, "半包应被缓存");
    let second = d.add(&framed[3..]).unwrap();
    assert_eq!(second.len(), 1);
    assert_eq!(second[0], vec![9, 9, 9, 9]);
    assert_eq!(d.buffered_bytes(), 0);

    // 粘包：一次给 3 个完整包
    let d = &mut FrameDecoder::new();
    let mut glued = Vec::new();
    glued.extend_from_slice(&frame_packet(&[1]));
    glued.extend_from_slice(&frame_packet(&[2, 2]));
    glued.extend_from_slice(&frame_packet(&[3, 3, 3]));
    let out = d.add(&glued).unwrap();
    assert_eq!(out.len(), 3, "粘包应全部吐出");
    assert_eq!(out[0], vec![1]);
    assert_eq!(out[1], vec![2, 2]);
    assert_eq!(out[2], vec![3, 3, 3]);
    assert_eq!(d.buffered_bytes(), 0);
}

#[test]
fn decoder_rejects_illegal_lengths() {
    // 长度 < 4：报错而不是卡死，且清空缓冲避免重复报同一个错
    let d = &mut FrameDecoder::new();
    let err = d.add(&[0, 0, 0, 2, 0xff, 0xff]).unwrap_err();
    assert_eq!(err, TransportError::IllegalFrameLength(2));
    assert_eq!(d.buffered_bytes(), 0, "报错后缓冲应清空");

    // 长度超上限
    let d = &mut FrameDecoder::new();
    let big = ((FrameDecoder::MAX_FRAME_LENGTH + 1) as u32).to_be_bytes();
    let err = d.add(&big).unwrap_err();
    assert!(matches!(err, TransportError::IllegalFrameLength(_)));
    assert_eq!(d.buffered_bytes(), 0);
}

/// 真实 TCP 回环：确认发送的是"原样字节"（不再加任何分帧前缀），
/// 且半包/粘包都能解出来。
#[tokio::test]
async fn tcp_loopback_roundtrip() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    let server = tokio::spawn(async move {
        let (mut sock, _) = listener.accept().await.unwrap();
        // 收两段请求（第二段故意分成两次写）
        let mut buf = vec![0u8; 4096];
        let n = sock.read(&mut buf).await.unwrap();
        let first = buf[..n].to_vec();
        let resp = frame_packet(&[0xde, 0xad, 0xbe, 0xef]);
        let mid = resp.len() / 2;
        sock.write_all(&resp[..mid]).await.unwrap();
        tokio::time::sleep(Duration::from_millis(20)).await;
        sock.write_all(&resp[mid..]).await.unwrap();
        first
    });

    let transport = Transport::tcp("127.0.0.1", addr.port()).await.unwrap();
    assert!(transport.is_connected());
    let mut frames = transport.take_frames().expect("入站帧接收端");
    transport.send(&frame_packet(&[1, 2, 3])).await.unwrap();

    let frame = tokio::time::timeout(Duration::from_secs(2), frames.recv())
        .await
        .unwrap()
        .expect("应收到帧");
    assert_eq!(frame, vec![0xde, 0xad, 0xbe, 0xef], "响应字节应完全一致");

    // 服务端看到的请求就是"原样字节"：4 字节头 + 3 字节 payload，没有多前缀
    let seen = server.await.unwrap();
    assert_eq!(seen, frame_packet(&[1, 2, 3]), "发送不得额外套分帧");

    transport.close().await;
    assert!(!transport.is_connected(), "关闭后 is_connected = false");
}
