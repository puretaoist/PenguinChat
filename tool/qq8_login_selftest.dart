/// QQ 登录主流程离线自测
///
/// **不需要网络、不需要 QQ 账号、不碰真实服务器。**
///
/// ## 这一组测试的强度说明（不要高估）
///
/// 登录**响应**目前没有真实样本——设备上的流量在 TLS/ECC 之下，
/// 抓不到明文。所以响应解析用的是**往返测试**：用本工程自己的构造器
/// 拼一个符合协议格式的响应，再解析回来。
///
/// 往返测试能抓到：
/// * 偏移写错（16 字节头 / 尾部 `0x03` / `u16 ‖ u8 ‖ u16` 前缀）
/// * TLV 读写不对称
/// * 加密密钥用错
///
/// 往返测试**抓不到**：官方真实的响应布局若与推断不符。
/// 这一点只能等真机联通后用真实响应校准，届时把真实响应补成黄金向量。
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/qq8_login_selftest.dart
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/infra/coder.dart';
import 'package:qqclient/kernel/crypto/tea.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_login.dart';
import 'package:qqclient/kernel/wlogin8/qq8_profiles.dart';
import 'package:qqclient/kernel/wlogin8/qq8_sso.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tlv.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tran.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  ✓ $name');
  } else {
    _failed++;
    stdout.writeln('  ✗ $name${detail == null ? '' : '  ($detail)'}');
  }
}

Uint8List _fill(int n, int v) => Uint8List.fromList(List<int>.filled(n, v));

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hexOf(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join(' ');

const int _fixedNow = 1600000000000;

final Uint8List _shareKey = _fill(16, 0x5a);
final Uint8List _tgtgtKey = _hex('ffeeddccbbaa99887766554433221100');

Qq8Device _device() => Qq8Device(
      product: 'MRS4S',
      device: 'HIM188MOE',
      board: 'MIRAI-YYDS',
      brand: 'OICQX',
      model: 'Konata 2020',
      bootloader: 'U-boot',
      fingerprint: 'OICQX/MRS4S/HIM188MOE:10/ABCDEF1234567890/1234567'
          ':user/release-keys',
      bootId: '11111111-2222-3333-4444-555555555555',
      procVersion: 'Linux version 4.19.71',
      baseband: '',
      sim: 'T-Mobile',
      apn: 'wifi',
      osType: 'android',
      macAddress: '00:50:56:C0:00:08',
      ipAddress: '10.0.0.1',
      wifiBssid: '00:50:56:C0:00:08',
      wifiSsid: 'TP-LINK-2711',
      imei: '860000000000001',
      androidId: 'ABCDEF1234567890',
      version: const Qq8AndroidVersion(
        release: '10',
        codename: 'REL',
        incremental: '1234567',
        sdk: 29,
      ),
      imsi: _fill(16, 0x22),
      tgtgt: _tgtgtKey,
      guid: _hex('00112233445566778899aabbccddeeff'),
    );

Qq8TlvContext _tlvCtx(Qq8ClientProfile p, {Uint8List? t104}) => Qq8TlvContext(
      uin: 10001,
      apk: p.apk,
      device: _device(),
      passwordMd5: _fill(16, 0x11),
      seqId: 100,
      ksid: _fill(16, 0x33),
      t104: t104 ?? _hex('0102030405060708'),
      t174: _hex('aabbccdd'),
      tgt: _hex('1122334455667788'),
      srmToken: _hex('99aabbcc'),
      randomBytes: (n) => _fill(n, 0xab),
      teaPadding: (n) => _fill(n, 0),
      nowMillis: () => _fixedNow,
    );

Qq8SsoContext _ssoCtx(Qq8ClientProfile p) => Qq8SsoContext(
      uin: 10001,
      apk: p.apk,
      device: _device(),
      sessionId: _hex('01020304'),
      randomKey: _fill(16, 0x0f),
      ecdhPublicKey: Uint8List.fromList(<int>[0x04, ...List<int>.filled(64, 0x42)]),
      ecdhShareKey: _shareKey,
      seqId: 100,
    );

/// 用零填充加密（填充长度必须够，否则 qqTeaEncrypt 会拒绝）。
Uint8List _encZeroPad(Uint8List plain, Uint8List key) {
  final pad = qqTeaPadLength(plain.length) + 3;
  return qqTeaEncrypt(plain, key, paddingBytes: _fill(pad, 0));
}

/// 按协议格式构造一个响应 payload：
/// `[16B 头][TEA(u16 ‖ u8 type ‖ u16 ‖ TLV…, shareKey)][0x03]`
Uint8List _buildResponse(int type, Map<int, List<int>> tlvs) {
  final w = ByteWriter()..u16(0x0001)..u8(type)..u16(0x0002);
  tlvs.forEach((tag, body) {
    w.u16(tag);
    w.u16(body.length);
    w.raw(body);
  });
  final enc = _encZeroPad(w.build(), _shareKey);

  final out = ByteWriter()
    ..raw(_fill(16, 0x77)) // 被跳过的 16 字节头
    ..raw(enc)
    ..u8(0x03); // 末尾 1 字节
  return out.build();
}

Future<void> main() async {
  stdout.writeln('=' * 66);
  stdout.writeln('QQ 登录主流程自测');
  stdout.writeln('=' * 66);

  // -- 1. 条件表 ---------------------------------------------------------
  stdout.writeln('\n【1】TLV 准入条件（对应官方 k.java 的 guard）');
  const first = Qq8LoginConditions.firstPasswordLogin;
  check('0x112：uin 登录不发', !first.applies(0x112));
  check(
    '0x112：非 uin 登录才发',
    const Qq8LoginConditions(accountIsUin: false).applies(0x112),
  );
  check('0x166：flags 未置位时不发', !first.applies(0x166));
  check(
    '0x166：flags & 128 时发',
    const Qq8LoginConditions(flags: 128).applies(0x166),
  );
  check('0x172：无回显时不发', !first.applies(0x172));
  check(
    '0x172：有回显时发',
    Qq8LoginConditions(echoedR: _hex('aabb')).applies(0x172),
  );
  check('0x185：loginType != 3 时不发', !first.applies(0x185));
  check(
    '0x185：loginType == 3 时发',
    const Qq8LoginConditions(loginType: 3).applies(0x185),
  );
  check('0x201：静态 L 为空时不发', !first.applies(0x201));
  check(
    '0x201：L 非空时发',
    Qq8LoginConditions(staticL: _hex('aabbcc')).applies(0x201),
  );
  check('0x318：永不发（二维码路径专用）', !first.applies(0x318));
  check(
    '0x318：有 tgtQR 才发',
    Qq8LoginConditions(tgtQR: _hex('aabb')).applies(0x318),
  );
  check('0x529：恒不发（三版本都无构建点）', !first.applies(0x529));
  check('0x548：an 为空时不发', !first.applies(0x548));
  check('0x106：恒发', first.applies(0x106));
  check('0x544：恒发（即使 body 为空，见 8.9.50）', first.applies(0x544));
  check(
    '0x545：拿不到 QIMEI → 整条不发（官方 8.9.50 j.java case 1349 同）',
    !first.applies(0x545),
  );
  check(
    '0x545：拿到 QIMEI 才发',
    const Qq8LoginConditions(qimei: 'sample').applies(0x545),
  );
  check(
    '0x104：首登无缓存盐 → 官方整条跳过（不是发空包）',
    !first.applies(0x104),
  );
  check(
    '0x104：有缓存盐时才发',
    Qq8LoginConditions(t104: _hex('0102030405060708')).applies(0x104),
  );
  check('0x16A：源为空时不发', !first.applies(0x16A));
  check(
    '0x187/0x188/0x194/0x202：跟 oicq 走，恒发（值从设备派生，不会为空）',
    first.applies(0x187) &&
        first.applies(0x188) &&
        first.applies(0x194) &&
        first.applies(0x202),
  );
  check('0x400：首登无票据 → 不发', !first.applies(0x400));
  check(
    '0x400：有票据时才发',
    const Qq8LoginConditions(hasSig: true).applies(0x400),
  );

  // -- 2. body 组装 ------------------------------------------------------
  stdout.writeln('\n【2】登录 body 组装（u16 子命令 ‖ u16 个数 ‖ TLV…）');
  for (final p in <Qq8ClientProfile>[
    qq8ProfileQQ8211,
    qq8ProfileQQ8950,
    qq8ProfileQQ9360,
  ]) {
    final ctx = _tlvCtx(p);
    final body = Qq8LoginBody.build(
      ctx,
      Qq8SubCmd.password,
      p.apk.loginTlvOrder,
    );

    check(
      '${p.label}：前 2 字节是子命令 ${Qq8SubCmd.password}',
      (body[0] << 8 | body[1]) == Qq8SubCmd.password,
      '${(body[0] << 8 | body[1])}',
    );

    final count = body[2] << 8 | body[3];
    check(
      '${p.label}：第 3-4 字节是 TLV 个数',
      count > 0,
      count.toString(),
    );

    final tlvs = qq8ReadTlv(body, offset: 4);
    check(
      '${p.label}：声明的个数与实际解析出的一致（$count）',
      tlvs.length == count,
      '声明 $count / 实际 ${tlvs.length}',
    );

    check(
      '${p.label}：0x106 在包里',
      tlvs.containsKey(0x106),
    );
    check(
      '${p.label}：0x104 / 0x112 / 0x172 / 0x185 / 0x201 / 0x545 / 0x548 被正确滤掉',
      !tlvs.containsKey(0x104) &&
          !tlvs.containsKey(0x112) &&
          !tlvs.containsKey(0x172) &&
          !tlvs.containsKey(0x185) &&
          !tlvs.containsKey(0x201) &&
          !tlvs.containsKey(0x545) &&
          !tlvs.containsKey(0x548),
    );
    check(
      '${p.label}：0x529 被正确滤掉',
      !tlvs.containsKey(0x529),
    );

    // 每个 TLV body 必须与单独打包的结果一致
    var mismatch = <String>[];
    tlvs.forEach((tag, got) {
      final single = Qq8Tlv.body(ctx, tag);
      if (got.join(',') != single.join(',')) mismatch.add('0x${tag.toRadixString(16)}');
    });
    check(
      '${p.label}：每个 TLV 与单独打包逐字节一致',
      mismatch.isEmpty,
      mismatch.join(','),
    );

    // 顺序必须与档案一致（滤掉之后仍是子序列）
    final plan = Qq8LoginBody.plan(p.apk.loginTlvOrder);
    check(
      '${p.label}：实际顺序与 plan 一致',
      tlvs.keys.join(',') == plan.join(','),
      tlvs.keys.map((t) => t.toRadixString(16)).join(','),
    );
  }

  // 8.9.50 的 0x544 是空 body，但**必须仍然出现**
  {
    final ctx = _tlvCtx(qq8ProfileQQ8950);
    final body = Qq8LoginBody.build(
      ctx,
      Qq8SubCmd.password,
      qq8ProfileQQ8950.apk.loginTlvOrder,
    );
    final tlvs = qq8ReadTlv(body, offset: 4);
    check(
      '8.9.50：0x544 存在但 body 为空（不能因空被滤掉）',
      tlvs.containsKey(0x544) && tlvs[0x544]!.isEmpty,
      'len=${tlvs[0x544]?.length}',
    );
    check(
      '8.9.50：0x553 不在包里（该版本顺序表没有它）',
      !tlvs.containsKey(0x553),
    );
  }
  // 给出 QIMEI 时 0x545 必须真的进包（guard 与 body 两侧都要接上）
  {
    const sample = '3F2A9C8B1D4E6075A1B2C3D4E5F60718ABCD';
    final ctx = _tlvCtx(qq8ProfileQQ8950);
    final body = Qq8LoginBody.build(
      ctx,
      Qq8SubCmd.password,
      qq8ProfileQQ8950.apk.loginTlvOrder,
      cond: const Qq8LoginConditions(qimei: sample),
      args: const <int, List<Object?>>{
        0x545: <Object?>[sample],
      },
    );
    final tlvs = qq8ReadTlv(body, offset: 4);
    check(
      '8.9.50：给出 QIMEI → 0x545 进包且 body = 原文（rawSource）',
      tlvs[0x545] != null &&
          String.fromCharCodes(tlvs[0x545]!) == sample,
      'len=${tlvs[0x545]?.length}',
    );
  }
  // 9.3.60 的 0x553 是 1 字节
  {
    final ctx = _tlvCtx(qq8ProfileQQ9360);
    final body = Qq8LoginBody.build(
      ctx,
      Qq8SubCmd.password,
      qq8ProfileQQ9360.apk.loginTlvOrder,
    );
    final tlvs = qq8ReadTlv(body, offset: 4);
    check(
      '9.3.60：0x553 存在且为单字节 00',
      tlvs.containsKey(0x553) &&
          tlvs[0x553]!.length == 1 &&
          tlvs[0x553]![0] == 0,
      'len=${tlvs[0x553]?.length}',
    );
  }

  // -- 2c. token 登录（子命令 11，wtlogin.exchange_emp）-------------------
  stdout.writeln('\n【2c】token 登录（票据续期）body');
  {
    final d2 = _hex('d2d2d2d2');
    final ctx = _tlvCtx(qq8ProfileQQ8950);
    final body = Qq8LoginBody.buildToken(ctx, d2: d2);
    final tlvs = qq8ReadTlv(body, offset: 4);

    check(
      'token：前 2 字节是子命令 11',
      (body[0] << 8 | body[1]) == Qq8SubCmd.token,
      '${(body[0] << 8 | body[1])}',
    );
    check(
      'token：共 16 项、顺序与清单一致（官方记载同为 16）',
      tlvs.length == 16 &&
          tlvs.keys.join(',') == qq8ExchangeEmpTlvOrder.join(','),
      '${tlvs.length} 项',
    );
    check(
      'token：0x143 = d2 本体',
      tlvs[0x143] != null && tlvs[0x143]!.join(',') == d2.join(','),
      'len=${tlvs[0x143]?.length}',
    );
    check(
      'token：0x10a = tgt（来自 ctx.tgt）',
      tlvs[0x10A] != null && tlvs[0x10A]!.join(',') == ctx.tgt.join(','),
      'len=${tlvs[0x10A]?.length}',
    );
    check(
      'token：没有 d2 时 0x143 被 guard 滤掉（整条不发）',
      !Qq8LoginConditions.firstPasswordLogin.applies(0x143),
    );
    check(
      'token：有 d2 时才发',
      Qq8LoginConditions(d2: d2).applies(0x143),
    );
    check(
      'token：命令字常量与官方一致',
      qq8ExchangeEmpCmd == 'wtlogin.exchange_emp',
      qq8ExchangeEmpCmd,
    );
  }

  // -- 2d. 滑动验证码提交（子命令 2）------------------------------------
  stdout.writeln('\n【2d】滑动验证码提交 body');
  {
    const ticket = 't0305ABCDEF0123456789';
    final ctx = _tlvCtx(qq8ProfileQQ8950);
    final body = Qq8LoginBody.buildSlider(ctx, ticket: ticket);
    final tlvs = qq8ReadTlv(body, offset: 4);

    check(
      'slider：前 2 字节是子命令 2',
      (body[0] << 8 | body[1]) == Qq8SubCmd.slider,
      '${(body[0] << 8 | body[1])}',
    );
    check(
      'slider：共 4 项、顺序与清单一致（官方记载同为 4）',
      tlvs.length == 4 && tlvs.keys.join(',') == qq8SliderTlvOrder.join(','),
      '${tlvs.length} 项',
    );
    check(
      'slider：0x193 = ticket 原文（trim 后）',
      tlvs[0x193] != null && String.fromCharCodes(tlvs[0x193]!) == ticket,
      'len=${tlvs[0x193]?.length}',
    );
    check(
      'slider：0x104 = 响应下发的盐',
      tlvs[0x104] != null && tlvs[0x104]!.join(',') == ctx.t104.join(','),
      'len=${tlvs[0x104]?.length}',
    );

    // 没有盐时必须显式拒绝（官方参考在 !t104 时直接不发）
    var noSaltRejected = false;
    try {
      Qq8LoginBody.buildSlider(
        _tlvCtx(qq8ProfileQQ8950, t104: Uint8List(0)),
        ticket: ticket,
      );
    } on Qq8LoginException {
      noSaltRejected = true;
    }
    check('slider：盐缺失（type=2 响应里没 0x104）时显式拒绝', noSaltRejected);

    var emptyTicketRejected = false;
    try {
      Qq8LoginBody.buildSlider(ctx, ticket: '  ');
    } on Qq8LoginException {
      emptyTicketRejected = true;
    }
    check('slider：ticket 为空时显式拒绝', emptyTicketRejected);
  }

  // -- 3. 响应解析（往返） ------------------------------------------------
  stdout.writeln('\n【3】响应解析（往返构造）');
  {
    final payload = _buildResponse(Qq8LoginResultType.success, <int, List<int>>{
      0x119: <int>[0xde, 0xad, 0xbe, 0xef],
      0x16a: <int>[1, 2, 3],
    });
    final r = Qq8LoginResponse.parse(payload, _shareKey);
    check('type 解出为 0（成功）', r.isSuccess, '${r.type}');
    check('0x119 解出', r.t119?.join(',') == '222,173,190,239', _hexOf(r.t119 ?? const []));
    check('0x16a 解出', r.tlvs[0x16a]?.join(',') == '1,2,3');
    check('是成功态', r.isSuccess && !r.needsSlider && !r.needsDeviceLock);
  }
  {
    final url = 'https://captcha.qq.com/tcap?session=x';
    final payload = _buildResponse(Qq8LoginResultType.slider, <int, List<int>>{
      0x104: <int>[9, 9],
      0x192: url.codeUnits,
    });
    final r = Qq8LoginResponse.parse(payload, _shareKey);
    check('type 解出为 2（滑动验证）', r.needsSlider, '${r.type}');
    check('0x192 解出为地址', r.sliderUrl == url, r.sliderUrl);
    check('0x104 也解出', r.tlvs[0x104]?.join(',') == '9,9');
  }
  {
    final payload =
        _buildResponse(Qq8LoginResultType.deviceLock, <int, List<int>>{
      0x104: <int>[1],
    });
    final r = Qq8LoginResponse.parse(payload, _shareKey);
    check('type 解出为 204（设备锁）', r.needsDeviceLock, '${r.type}');
  }
  {
    var threw = false;
    try {
      Qq8LoginResponse.parse(_fill(10, 0), _shareKey);
    } on Qq8LoginException {
      threw = true;
    }
    check('过短的响应报错而不是越界', threw);
  }
  {
    // 用错密钥：解出来的是垃圾。要求它"要么抛异常，要么 TLV 表里没有
    // 我们期望的 0x119"，总之不能静默给出看似正确的结果。
    final payload = _buildResponse(0, <int, List<int>>{0x119: <int>[1, 2, 3]});
    var safe = false;
    try {
      final r = Qq8LoginResponse.parse(payload, _fill(16, 0x99));
      safe = !r.isSuccess || !r.tlvs.containsKey(0x119);
    } on Qq8LoginException {
      safe = true;
    }
    check('密钥错时不会静默给出看似正确的结果', safe);
  }

  // -- 4. 0x119 票据 ------------------------------------------------------
  stdout.writeln('\n【4】票据 TLV 0x119（用 tgtgt 再解一层）');
  {
    final w = ByteWriter()..u16(0x0001);
    void put(int tag, List<int> body) {
      w.u16(tag);
      w.u16(body.length);
      w.raw(body);
    }

    put(0x10a, _fill(56, 0xa1)); // tgt
    put(0x143, _fill(64, 0xa2)); // d2
    put(0x305, _fill(16, 0xa3)); // d2key
    put(0x133, _fill(48, 0xa4)); // sig_key
    put(0x134, _fill(16, 0xa5)); // ticket_key
    put(0x16a, _fill(56, 0xa6)); // srm_token
    put(0x106, _fill(4, 0xa7));

    final enc = _encZeroPad(w.build(), _tgtgtKey);
    final bundle = Qq8SigBundle.parse(enc, _tgtgtKey);

    check('tgt 解出 56 字节', bundle.tgt?.length == 56, '${bundle.tgt?.length}');
    check('d2 解出 64 字节', bundle.d2?.length == 64, '${bundle.d2?.length}');
    check('d2key 解出 16 字节', bundle.d2key?.length == 16, '${bundle.d2key?.length}');
    check('sig_key 解出 48 字节', bundle.sigKey?.length == 48, '${bundle.sigKey?.length}');
    check('ticket_key 解出 16 字节', bundle.ticketKey?.length == 16, '${bundle.ticketKey?.length}');
    check('srm_token 解出 56 字节', bundle.srmToken?.length == 56, '${bundle.srmToken?.length}');
    check('0x106 解出', bundle.t106?.length == 4);
    check('未出现的 0x120 为 null', bundle.skey == null);
  }

  // -- 5. 全链路（脚本传输） ----------------------------------------------
  stdout.writeln('\n【5】全链路：TLV → OICQ 包 → 登录包 → 传输 → 解析');
  {
    final p = qq8ProfileQQ8950;
    final tlvCtx = _tlvCtx(p);
    final ssoCtx = _ssoCtx(p);

    final body = Qq8LoginBody.build(
      tlvCtx,
      Qq8SubCmd.password,
      p.apk.loginTlvOrder,
    );
    final oicq = Qq8Sso.buildOicqPacket(ssoCtx, body);
    final loginPkt = Qq8Sso.buildLoginPacket(
      ssoCtx,
      'wtlogin.login',
      oicq,
      Qq8LoginType.login,
    );

    check('登录包非空', loginPkt.isNotEmpty);
    check(
      '登录包以 u32 长度开头（含自身）',
      (loginPkt[0] << 24 | loginPkt[1] << 16 | loginPkt[2] << 8 | loginPkt[3]) ==
          loginPkt.length,
      '头=${loginPkt[0]},${loginPkt[1]},${loginPkt[2]},${loginPkt[3]} 实际=${loginPkt.length}',
    );

    // 构造一个成功的响应
    final w = ByteWriter()..u16(0x0001);
    w.u16(0x119);
    final inner = ByteWriter()..u16(0x0001);
    inner.u16(0x10a);
    inner.u16(56);
    inner.raw(_fill(56, 0xc1));
    final innerEnc =
        _encZeroPad(inner.build(), _tgtgtKey);
    w.u16(innerEnc.length);
    w.raw(innerEnc);
    final payload = _buildResponse(0, <int, List<int>>{
      0x119: qq8ReadTlv(w.build(), offset: 2)[0x119]!.toList(),
    });

    final tran = Qq8ScriptedTransport(<Uint8List>[payload]);
    final resp = await tran.send(loginPkt);

    final parsed = Qq8LoginResponse.parse(resp, _shareKey);
    check('全链路解析出成功态', parsed.isSuccess, 'type=${parsed.type}');
    check('传输层收到 1 个请求', tran.sent.length == 1);
    check(
      '传输层收到的就是登录包',
      tran.sent.first.join(',') == loginPkt.join(','),
    );

    final sig = Qq8SigBundle.parse(parsed.t119!, _tgtgtKey);
    check('票据 tgt 解出', sig.tgt?.length == 56, '${sig.tgt?.length}');
  }

  // -- 汇总 --------------------------------------------------------------
  stdout.writeln('\n${'=' * 66}');
  stdout.writeln('通过 $_passed 项，失败 $_failed 项');
  if (_failed == 0) {
    stdout.writeln('登录主流程可用 ✓');
  }
  exit(_failed == 0 ? 0 : 1);
}
