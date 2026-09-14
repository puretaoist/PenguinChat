//! 登录主流程离线自测（Rust 侧），断言口径与 Dart 侧
//! `tool/qq8_login_selftest.dart` 一致。
//!
//! ## 这一组测试的强度说明（不要高估）
//!
//! 登录**响应**没有真实样本（设备流量在 TLS/ECC 之下，抓不到明文），所以
//! 响应解析用的是**往返测试**：用本工程自己的构造器拼一个符合协议格式的
//! 响应，再解析回来。能抓到偏移写错（16 字节头 / 尾部 `0x03` /
//! `u16 ‖ u8 ‖ u16` 前缀）/ TLV 读写不对称 / 加密密钥用错；抓不到"官方真实
//! 响应布局若与推断不符"——那只能等真机联通后用真实响应校准。

#![allow(clippy::unwrap_used)]

use penguin_crypto::tea::{qq_tea_encrypt, qq_tea_pad_len};
use penguin_protocol::device::{AndroidVersion, Device};
use penguin_protocol::login::{
    build, build_slider, build_token, plan, read_tlv, result_type, sub_cmd, LoginConditions,
    LoginError, LoginResponse, SigBundle,
};
use penguin_protocol::profiles::{ApkInfo, QQ_8211, QQ_8950, QQ_9360};
use penguin_protocol::sso::{self, SigInfo, SsoContext};
use penguin_protocol::tlv::{
    body as tlv_body, TlvArg, TlvContext, EXCHANGE_EMP_TLV_ORDER, SLIDER_TLV_ORDER,
};

fn fill(n: usize, v: u8) -> Vec<u8> {
    vec![v; n]
}

fn share_key() -> Vec<u8> {
    fill(16, 0x5a)
}

fn tgtgt_key() -> Vec<u8> {
    hex::decode("ffeeddccbbaa99887766554433221100").unwrap()
}

fn fill_pub() -> Vec<u8> {
    let mut v = vec![0x04u8];
    v.extend_from_slice(&fill(64, 0x42));
    v
}

fn device() -> Device {
    Device {
        product: "MRS4S".into(),
        device: "HIM188MOE".into(),
        board: "MIRAI-YYDS".into(),
        brand: "OICQX".into(),
        model: "Konata 2020".into(),
        bootloader: "U-boot".into(),
        fingerprint: "OICQX/MRS4S/HIM188MOE:10/ABCDEF1234567890/1234567:user/release-keys".into(),
        boot_id: "11111111-2222-3333-4444-555555555555".into(),
        proc_version: "Linux version 4.19.71".into(),
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
        imsi: fill(16, 0x22),
        tgtgt: tgtgt_key(),
        guid: hex::decode("00112233445566778899aabbccddeeff").unwrap(),
    }
}

fn tlv_ctx(apk: ApkInfo, t104: Option<Vec<u8>>) -> TlvContext {
    let mut ctx = TlvContext::new(
        10001,
        apk,
        device(),
        fill(16, 0x11),
        fill(16, 0x33),
        t104.unwrap_or_else(|| hex::decode("0102030405060708").unwrap()),
        hex::decode("aabbccdd").unwrap(),
        hex::decode("1122334455667788").unwrap(),
        hex::decode("99aabbcc").unwrap(),
    )
    .with_seq_id(100);
    ctx.random_bytes = Box::new(|n| fill(n, 0xab));
    ctx.tea_padding = Box::new(|n| fill(n, 0));
    ctx.now_millis = Box::new(|| 1600000000000);
    ctx
}

fn sso_ctx(apk: ApkInfo) -> SsoContext {
    SsoContext {
        uin: 10001,
        apk,
        device: device(),
        session_id: hex::decode("01020304").unwrap(),
        random_key: fill(16, 0x0f),
        ecdh_public_key: fill_pub(),
        ecdh_share_key: share_key(),
        sig: SigInfo {
            tgt: hex::decode("1122334455667788").unwrap(),
            d2: vec![],
            d2key: hex::decode("00112233445566778899aabbccddeeff").unwrap(),
            sig_key: hex::decode("aaaaaaaabbbbbbbbccccccccdddddddd").unwrap(),
            ticket_key: hex::decode("0102030405060708090a0b0c0d0e0f10").unwrap(),
            srm_token: hex::decode("99aabbcc").unwrap(),
        },
        seq_id: 100,
    }
}

fn enc_zero_pad(plain: &[u8], key: &[u8]) -> Vec<u8> {
    let pad = qq_tea_pad_len(plain.len()) + 3;
    qq_tea_encrypt(plain, key, Some(&fill(pad, 0))).unwrap()
}

/// 按协议格式构造响应 payload：`[16B 头][TEA(u16 ‖ u8 type ‖ u16 ‖ TLV…, shareKey)][0x03]`。
fn build_response(ty: u8, tlvs: &[(u16, Vec<u8>)]) -> Vec<u8> {
    let mut plain = Vec::new();
    plain.extend_from_slice(&1u16.to_be_bytes());
    plain.push(ty);
    plain.extend_from_slice(&2u16.to_be_bytes());
    for (tag, b) in tlvs {
        plain.extend_from_slice(&tag.to_be_bytes());
        plain.extend_from_slice(&(b.len() as u16).to_be_bytes());
        plain.extend_from_slice(b);
    }
    let enc = enc_zero_pad(&plain, &share_key());
    let mut out = fill(16, 0x77);
    out.extend_from_slice(&enc);
    out.push(0x03);
    out
}

fn put_tlv(out: &mut Vec<u8>, tag: u16, body: &[u8]) {
    out.extend_from_slice(&tag.to_be_bytes());
    out.extend_from_slice(&(body.len() as u16).to_be_bytes());
    out.extend_from_slice(body);
}

// ---------------------------------------------------------------------------
// 1. 条件表
// ---------------------------------------------------------------------------

#[test]
fn conditions_match_official_guards() {
    let first = LoginConditions::default();
    assert!(!first.applies(0x112), "0x112：uin 登录不发");
    assert!(
        LoginConditions {
            account_is_uin: false,
            ..Default::default()
        }
        .applies(0x112),
        "0x112：非 uin 登录才发"
    );
    assert!(!first.applies(0x166), "0x166：flags 未置位时不发");
    assert!(LoginConditions {
        flags: 128,
        ..Default::default()
    }
    .applies(0x166));
    assert!(!first.applies(0x172), "0x172：无回显时不发");
    assert!(LoginConditions {
        echoed_r: Some(vec![0xaa, 0xbb]),
        ..Default::default()
    }
    .applies(0x172));
    assert!(!first.applies(0x185), "0x185：loginType != 3 时不发");
    assert!(LoginConditions {
        login_type: 3,
        ..Default::default()
    }
    .applies(0x185));
    assert!(!first.applies(0x201), "0x201：静态 L 为空时不发");
    assert!(LoginConditions {
        static_l: Some(vec![0xaa, 0xbb, 0xcc]),
        ..Default::default()
    }
    .applies(0x201));
    assert!(!first.applies(0x318), "0x318：永不发（二维码路径专用）");
    assert!(LoginConditions {
        tgt_qr: Some(vec![0xaa, 0xbb]),
        ..Default::default()
    }
    .applies(0x318));
    assert!(!first.applies(0x529), "0x529：恒不发（三版本都无构建点）");
    assert!(!first.applies(0x548), "0x548：an 为空时不发");
    assert!(first.applies(0x106), "0x106：恒发");
    assert!(first.applies(0x544), "0x544：恒发（即使 body 为空）");
    assert!(!first.applies(0x545), "0x545：拿不到 QIMEI → 整条不发");
    assert!(LoginConditions {
        qimei: Some("sample".into()),
        ..Default::default()
    }
    .applies(0x545));
    assert!(
        !first.applies(0x104),
        "0x104：首登无缓存盐 → 官方整条跳过（不是发空包）"
    );
    assert!(LoginConditions {
        t104: Some(vec![1, 2, 3]),
        ..Default::default()
    }
    .applies(0x104));
    assert!(!first.applies(0x16A), "0x16A：源为空时不发");
    assert!(
        first.applies(0x187)
            && first.applies(0x188)
            && first.applies(0x194)
            && first.applies(0x202),
        "0x187/0x188/0x194/0x202：跟 oicq 走，恒发（值从设备派生，不会为空）"
    );
    assert!(!first.applies(0x400), "0x400：首登无票据 → 不发");
    assert!(LoginConditions {
        has_sig: true,
        ..Default::default()
    }
    .applies(0x400));
}

// ---------------------------------------------------------------------------
// 2. body 组装
// ---------------------------------------------------------------------------

#[test]
fn password_body_per_profile() {
    for apk in [QQ_8211, QQ_8950, QQ_9360] {
        let order = apk.login_tlv_order;
        let name = apk.name;
        let ctx = tlv_ctx(apk, None);
        let built = build(
            &ctx,
            sub_cmd::PASSWORD,
            order,
            &LoginConditions::default(),
            &[],
        )
        .unwrap();

        assert_eq!(
            u16::from_be_bytes([built[0], built[1]]),
            sub_cmd::PASSWORD,
            "前 2 字节应是子命令 9"
        );
        let count = u16::from_be_bytes([built[2], built[3]]);
        assert!(count > 0, "TLV 个数应大于 0");

        let tlvs = read_tlv(&built, 4, false).unwrap();
        assert_eq!(tlvs.len(), count as usize, "声明个数与实际解析应一致");
        assert!(tlvs.contains_key(0x106), "0x106 应在包里");
        for tag in [0x104u16, 0x112, 0x172, 0x185, 0x201, 0x545, 0x548, 0x529] {
            assert!(!tlvs.contains_key(tag), "0x{tag:x} 应被滤掉");
        }
        // 每个 TLV body 必须与单独打包一致
        for (tag, got) in tlvs.iter() {
            let single = tlv_body(&ctx, *tag, &[]).unwrap();
            assert_eq!(got, &single, "0x{tag:x} 与单独打包不一致");
        }
        // 顺序与档案（滤后）一致
        let expected = plan(order, &LoginConditions::default());
        let actual: Vec<u16> = tlvs.keys().collect();
        assert_eq!(actual, expected, "{name} 实际顺序与 plan 不一致");
    }
}

#[test]
fn profile_specific_tlvs() {
    // 8.9.50 的 0x544 是空 body，但**必须仍然出现**
    let ctx = tlv_ctx(QQ_8950, None);
    let built = build(
        &ctx,
        sub_cmd::PASSWORD,
        QQ_8950.login_tlv_order,
        &LoginConditions::default(),
        &[],
    )
    .unwrap();
    let tlvs = read_tlv(&built, 4, false).unwrap();
    assert_eq!(
        tlvs.get(0x544).map(|v| v.len()),
        Some(0),
        "8.9.50：0x544 存在但 body 为空"
    );
    assert!(!tlvs.contains_key(0x553), "8.9.50：0x553 不在包里");

    // 给出 QIMEI 时 0x545 必须真的进包（guard 与 body 两侧都要接上）
    let sample = "3F2A9C8B1D4E6075A1B2C3D4E5F60718ABCD";
    let cond = LoginConditions {
        qimei: Some(sample.into()),
        ..Default::default()
    };
    let args = vec![(0x545u16, vec![TlvArg::Str(sample.into())])];
    let built = build(
        &ctx,
        sub_cmd::PASSWORD,
        QQ_8950.login_tlv_order,
        &cond,
        &args,
    )
    .unwrap();
    let tlvs = read_tlv(&built, 4, false).unwrap();
    assert_eq!(
        tlvs.get(0x545)
            .map(|v| String::from_utf8(v.clone()).unwrap()),
        Some(sample.to_string()),
        "8.9.50：0x545 = 原文（rawSource）"
    );

    // 9.3.60 的 0x553 是 1 字节
    let ctx = tlv_ctx(QQ_9360, None);
    let built = build(
        &ctx,
        sub_cmd::PASSWORD,
        QQ_9360.login_tlv_order,
        &LoginConditions::default(),
        &[],
    )
    .unwrap();
    let tlvs = read_tlv(&built, 4, false).unwrap();
    assert_eq!(
        tlvs.get(0x553).map(|v| v.as_slice()),
        Some([0u8].as_slice()),
        "9.3.60：0x553 = 单字节 00"
    );

    // 8.2.11 的 0x545 是 MD5(原文)
    let ctx = tlv_ctx(QQ_8211, None);
    let args = vec![(0x545u16, vec![TlvArg::Str(sample.into())])];
    let cond = LoginConditions {
        qimei: Some(sample.into()),
        ..Default::default()
    };
    let built = build(
        &ctx,
        sub_cmd::PASSWORD,
        QQ_8211.login_tlv_order,
        &cond,
        &args,
    )
    .unwrap();
    let tlvs = read_tlv(&built, 4, false).unwrap();
    assert_eq!(
        tlvs.get(0x545).map(|v| v.len()),
        Some(16),
        "8.2.11：0x545 = MD5(原文)"
    );
}

// ---------------------------------------------------------------------------
// 3. token / slider 便捷入口
// ---------------------------------------------------------------------------

#[test]
fn token_login_body() {
    let d2 = hex::decode("d2d2d2d2").unwrap();
    let ctx = tlv_ctx(QQ_8950, None);
    let built = build_token(&ctx, &d2).unwrap();
    let tlvs = read_tlv(&built, 4, false).unwrap();

    assert_eq!(
        u16::from_be_bytes([built[0], built[1]]),
        sub_cmd::TOKEN,
        "子命令 11"
    );
    let expected: Vec<u16> = EXCHANGE_EMP_TLV_ORDER.to_vec();
    assert_eq!(
        tlvs.keys().collect::<Vec<u16>>(),
        expected,
        "顺序与清单一致"
    );
    assert_eq!(tlvs.len(), 16, "官方记载同为 16 项");
    assert_eq!(
        tlvs.get(0x143).map(|v| v.as_slice()),
        Some(d2.as_slice()),
        "0x143 = d2 本体"
    );
    assert_eq!(
        tlvs.get(0x10A).map(|v| v.as_slice()),
        Some(ctx.tgt.as_slice()),
        "0x10a = tgt（来自 ctx.tgt）"
    );
    assert!(
        !LoginConditions::default().applies(0x143),
        "没有 d2 时 0x143 被 guard 滤掉"
    );
    assert!(
        LoginConditions {
            d2: Some(d2.clone()),
            ..Default::default()
        }
        .applies(0x143),
        "有 d2 时才发"
    );
    assert_eq!(
        sso::EXCHANGE_EMP_CMD,
        "wtlogin.exchange_emp",
        "命令字常量与官方一致"
    );
}

#[test]
fn slider_login_body() {
    let ticket = "t0305ABCDEF0123456789";
    let ctx = tlv_ctx(QQ_8950, None);
    let built = build_slider(&ctx, ticket).unwrap();
    let tlvs = read_tlv(&built, 4, false).unwrap();

    assert_eq!(
        u16::from_be_bytes([built[0], built[1]]),
        sub_cmd::SLIDER,
        "子命令 2"
    );
    let expected: Vec<u16> = SLIDER_TLV_ORDER.to_vec();
    assert_eq!(
        tlvs.keys().collect::<Vec<u16>>(),
        expected,
        "顺序与清单一致"
    );
    assert_eq!(tlvs.len(), 4, "官方记载同为 4 项");
    assert_eq!(
        tlvs.get(0x193)
            .map(|v| String::from_utf8(v.clone()).unwrap()),
        Some(ticket.to_string()),
        "0x193 = ticket 原文"
    );
    assert_eq!(
        tlvs.get(0x104).map(|v| v.as_slice()),
        Some(ctx.t104.as_slice()),
        "0x104 = 盐"
    );

    // 没有盐必须显式拒绝（官方参考在 !t104 时直接不发）
    let no_salt = tlv_ctx(QQ_8950, Some(vec![]));
    assert_eq!(build_slider(&no_salt, ticket), Err(LoginError::MissingSalt));
    assert_eq!(build_slider(&ctx, "  "), Err(LoginError::EmptyTicket));
}

// ---------------------------------------------------------------------------
// 4. 响应解析（往返）
// ---------------------------------------------------------------------------

#[test]
fn response_parse_round_trip() {
    let payload = build_response(
        result_type::SUCCESS,
        &[
            (0x119, vec![0xde, 0xad, 0xbe, 0xef]),
            (0x16A, vec![1, 2, 3]),
        ],
    );
    let r = LoginResponse::parse(&payload, &share_key()).unwrap();
    assert!(r.is_success() && !r.needs_slider() && !r.needs_device_lock());
    assert_eq!(
        r.t119(),
        Some([0xde, 0xad, 0xbe, 0xef].as_slice()),
        "0x119 解出"
    );
    assert_eq!(
        r.tlvs.get(0x16A).map(|v| v.as_slice()),
        Some([1u8, 2, 3].as_slice()),
        "0x16a 解出"
    );

    let url = "https://captcha.qq.com/tcap?session=x";
    let payload = build_response(
        result_type::SLIDER,
        &[(0x104, vec![9, 9]), (0x192, url.as_bytes().to_vec())],
    );
    let r = LoginResponse::parse(&payload, &share_key()).unwrap();
    assert!(r.needs_slider());
    assert_eq!(r.slider_url().as_deref(), Some(url), "0x192 解出为地址");
    assert_eq!(
        r.tlvs.get(0x104).map(|v| v.as_slice()),
        Some([9u8, 9].as_slice())
    );

    let payload = build_response(result_type::DEVICE_LOCK, &[(0x104, vec![1])]);
    let r = LoginResponse::parse(&payload, &share_key()).unwrap();
    assert!(r.needs_device_lock());

    // 过短的响应报错而不是越界
    assert!(matches!(
        LoginResponse::parse(&fill(10, 0), &share_key()),
        Err(LoginError::TooShort(10))
    ));

    // 用错密钥：要么抛异常，要么 TLV 表里没有我们期望的 0x119——总之不能静默
    // 给出看似正确的结果。
    let payload = build_response(0, &[(0x119, vec![1, 2, 3])]);
    let safe = match LoginResponse::parse(&payload, &fill(16, 0x99)) {
        Ok(r) => !r.is_success() || !r.tlvs.contains_key(0x119),
        Err(_) => true,
    };
    assert!(safe, "密钥错时不能静默给出看似正确的结果");
}

// ---------------------------------------------------------------------------
// 5. 0x119 票据块
// ---------------------------------------------------------------------------

#[test]
fn sig_bundle_parse() {
    let mut inner = Vec::new();
    inner.extend_from_slice(&1u16.to_be_bytes());
    put_tlv(&mut inner, 0x10A, &fill(56, 0xa1)); // tgt
    put_tlv(&mut inner, 0x143, &fill(64, 0xa2)); // d2
    put_tlv(&mut inner, 0x305, &fill(16, 0xa3)); // d2key
    put_tlv(&mut inner, 0x133, &fill(48, 0xa4)); // sig_key
    put_tlv(&mut inner, 0x134, &fill(16, 0xa5)); // ticket_key
    put_tlv(&mut inner, 0x16A, &fill(56, 0xa6)); // srm_token
    put_tlv(&mut inner, 0x106, &fill(4, 0xa7));

    let enc = enc_zero_pad(&inner, &tgtgt_key());
    let sig = SigBundle::parse(&enc, &tgtgt_key()).unwrap();

    assert_eq!(sig.tgt.as_ref().map(|v| v.len()), Some(56));
    assert_eq!(sig.d2.as_ref().map(|v| v.len()), Some(64));
    assert_eq!(sig.d2key.as_ref().map(|v| v.len()), Some(16));
    assert_eq!(sig.sig_key.as_ref().map(|v| v.len()), Some(48));
    assert_eq!(sig.ticket_key.as_ref().map(|v| v.len()), Some(16));
    assert_eq!(sig.srm_token.as_ref().map(|v| v.len()), Some(56));
    assert_eq!(sig.t106.as_ref().map(|v| v.len()), Some(4));
    assert_eq!(sig.skey, None, "未出现的 0x120 应为 None");

    // 密钥不对要报错，不能返回垃圾
    assert!(matches!(
        SigBundle::parse(&enc, &fill(16, 0x00)),
        Err(LoginError::Decrypt(_))
    ));
}

// ---------------------------------------------------------------------------
// 6. 全链路：TLV → OICQ 包 → 登录包 → 解析
// ---------------------------------------------------------------------------

#[test]
fn full_chain_offline() {
    let apk = QQ_8950;
    let order = apk.login_tlv_order;
    let tctx = tlv_ctx(apk.clone(), None);
    let sctx = sso_ctx(apk);

    let body = build(
        &tctx,
        sub_cmd::PASSWORD,
        order,
        &LoginConditions::default(),
        &[],
    )
    .unwrap();
    let oicq = sso::build_oicq_packet(&sctx, &body, false);
    let login_pkt = sso::build_login_packet(&sctx, sso::LOGIN_CMD, &oicq, sso::login_type::LOGIN);

    assert!(!login_pkt.is_empty());
    let declared = u32::from_be_bytes([login_pkt[0], login_pkt[1], login_pkt[2], login_pkt[3]]);
    assert_eq!(
        declared as usize,
        login_pkt.len(),
        "登录包以 u32 长度开头（含自身）"
    );

    // 构造一个成功的响应（0x119 内嵌一层 tgtgt 加密）
    let mut inner = Vec::new();
    inner.extend_from_slice(&1u16.to_be_bytes());
    put_tlv(&mut inner, 0x10A, &fill(56, 0xc1));
    let inner_enc = enc_zero_pad(&inner, &tgtgt_key());
    let payload = build_response(0, &[(0x119, inner_enc)]);

    let parsed = LoginResponse::parse(&payload, &share_key()).unwrap();
    assert!(parsed.is_success(), "全链路解析出成功态");
    let sig = SigBundle::parse(parsed.t119().unwrap(), &tgtgt_key()).unwrap();
    assert_eq!(sig.tgt.as_ref().map(|v| v.len()), Some(56), "票据 tgt 解出");
}
