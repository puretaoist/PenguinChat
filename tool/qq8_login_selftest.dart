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

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/infra/coder.dart';
import 'package:qqclient/kernel/crypto/tea.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/crypto/digest.dart';
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

String _hexCompact(List<int> b) => _hexOf(b).replaceAll(' ', '');

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

Qq8TlvContext _tlvCtx(Qq8ClientProfile p,
        {Uint8List? t104, Uint8List? t174, Uint8List? t547, Uint8List? t548}) =>
    Qq8TlvContext(
      uin: 10001,
      apk: p.apk,
      device: _device(),
      passwordMd5: _fill(16, 0x11),
      seqId: 100,
      ksid: _fill(16, 0x33),
      t104: t104 ?? _hex('0102030405060708'),
      t174: t174 ?? _hex('aabbccdd'),
      tgt: _hex('1122334455667788'),
      srmToken: _hex('99aabbcc'),
      t547: t547,
      t548: t548,
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

int _subOf(Uint8List body) => (body[0] << 8) | body[1];

List<int> _tagsOf(Uint8List body) {
  final n = (body[2] << 8) | body[3];
  final tags = <int>[];
  var i = 4;
  for (var k = 0; k < n && i + 4 <= body.length; k++) {
    final tag = (body[i] << 8) | body[i + 1];
    final len = (body[i + 2] << 8) | body[i + 3];
    tags.add(tag);
    i += 4 + len;
  }
  return tags;
}

Uint8List? _tlvBody(Uint8List body, int want) {
  final n = (body[2] << 8) | body[3];
  var i = 4;
  for (var k = 0; k < n && i + 4 <= body.length; k++) {
    final tag = (body[i] << 8) | body[i + 1];
    final len = (body[i + 2] << 8) | body[i + 3];
    if (tag == want) return body.sublist(i + 4, i + 4 + len);
    i += 4 + len;
  }
  return null;
}

String _hx(int v) => '0x${v.toRadixString(16)}';

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
    final sliderOrder = qq8SliderTlvOrderFor(qq8ProfileQQ8950.apk);
    check(
      'slider（8.9.50，ssoVer=19）：6 项 = 193/8/104/116/547/544（官方 Helper:938）',
      tlvs.length == 6 && tlvs.keys.join(',') == sliderOrder.join(',') &&
          sliderOrder[4] == 0x547 && sliderOrder[5] == 0x544,
      '${tlvs.length} 项: ${tlvs.keys.map((t) => '0x${t.toRadixString(16)}').join(' ')}',
    );
    check(
      'slider（8.9.50）：0x547 无应答时为空 body（官方恒在语义）',
      tlvs.containsKey(0x547) && tlvs[0x547]!.isEmpty,
      'len=${tlvs[0x547]?.length}',
    );
    check(
      'slider（8.9.50）：0x544 是合法空体（不能因空被滤掉）',
      tlvs.containsKey(0x544) && tlvs[0x544]!.isEmpty,
      'len=${tlvs[0x544]?.length}',
    );
    check(
      'slider（8.9.50）：收尾 0x544，**没有 0x542**（官方滑块提交无此项）',
      sliderOrder.last == 0x544 && !sliderOrder.contains(0x542),
      sliderOrder.map((t) => '0x${t.toRadixString(16)}').join(' '),
    );

    // 8.2.11（ssoVer=7）：官方 n.java = 193/8/104/116/547（空 body），无 544/542
    {
      final ctx7 = _tlvCtx(qq8ProfileQQ8211);
      final b7 = Qq8LoginBody.buildSlider(ctx7, ticket: ticket);
      final t7 = qq8ReadTlv(b7, offset: 4);
      final o7 = qq8SliderTlvOrderFor(qq8ProfileQQ8211.apk);
      check(
        'slider（8.2.11，ssoVer=7）：5 项 = 193/8/104/116/547(空)，无 544/542',
        t7.length == 5 &&
            o7.join(',') == <int>[...qq8SliderTlvOrder, 0x547].join(',') &&
            t7.keys.join(',') == o7.join(',') &&
            !t7.containsKey(0x544) &&
            !t7.containsKey(0x542) &&
            t7[0x547]!.isEmpty,
        '${t7.length} 项: ${t7.keys.map((t) => '0x${t.toRadixString(16)}').join(' ')}',
      );
    }

    // 有 PoW 应答时 0x547 带应答本体（官方 t.am 缓存语义）
    {
      final ctx547 = _tlvCtx(qq8ProfileQQ8950, t547: Uint8List.fromList(
          <int>[1, 2, 3, 4]));
      final b547 = Qq8LoginBody.buildSlider(ctx547, ticket: ticket);
      final t547 = qq8ReadTlv(b547, offset: 4);
      check(
        'slider：0x547 有应答时发应答本体（官方 t.am 缓存）',
        t547[0x547]?.join(',') == '1,2,3,4',
        t547[0x547]?.map((v) => v.toRadixString(16).padLeft(2, '0')).join(' '),
      );
    }

    // 0x547 的顺序位：官方在 0x544 之前（Helper:978-980 的 arraycopy 序）
    {
      final order = qq8SliderTlvOrderFor(qq8ProfileQQ8950.apk);
      check(
        'slider 清单：0x547 在 0x544 之前（官方 arraycopy 序），无 0x542',
        order.length == 6 &&
            order[4] == 0x547 && order[5] == 0x544 &&
            !order.contains(0x542),
        order.map((t) => '0x${t.toRadixString(16)}').join(' '),
      );
    }

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

    // ssoVer=22（9.3.60）：官方滑块提交 = 193/8/104/116/547/544/553，**无 0x542**
    // （官方三版本对照：0x542 只在子命令 8 下发短信流程里出现）。六字节
    // 0x542 只属于密码路径（ssoVer ≥ 20 档），见 2e 段末。
    {
      final ctx22 = _tlvCtx(qq8ProfileQQ9360);
      final b22 = Qq8LoginBody.buildSlider(ctx22, ticket: ticket);
      final t22 = qq8ReadTlv(b22, offset: 4);
      final o22 = qq8SliderTlvOrderFor(qq8ProfileQQ9360.apk);
      check(
        'slider（9.3.60，ssoVer=22）：7 项 = 193/8/104/116/547/544/553，无 0x542',
        t22.length == 7 &&
            t22.keys.join(',') == o22.join(',') &&
            o22.last == 0x553 &&
            !t22.containsKey(0x542) &&
            t22[0x553]?.join(',') == '0',
        '${t22.length} 项: ${t22.keys.map((t) => '0x${t.toRadixString(16)}').join(' ')}',
      );
    }
  }

  // -- 2e. 密码登录清单的维护版对齐（0x548 自构造 PoW + 0x542）-------------
  stdout.writeln('\n【2e】密码登录清单（维护版 oicq v1.26.25 对齐）');
  {
    final order8950 = qq8PasswordTlvOrderFor(qq8ProfileQQ8950.apk);
    check('8.9.50 密码清单 = 官方 37 项 + 末尾 0x542（38 项）',
        order8950.length == 38 && order8950.last == 0x542,
        '${order8950.length} 项，尾=0x${order8950.last.toRadixString(16)}');
    final order8211 = qq8PasswordTlvOrderFor(qq8ProfileQQ8211.apk);
    check('8.2.11（ssoVer=7）密码清单不加 0x542（官方表无此项）',
        order8211.length == 37 && !order8211.contains(0x542),
        '${order8211.length} 项');

    // 组包：带自构造 0x548 时它出现在 0x545 之后、0x542 之前（官方表位次）。
    final fakeT548 = Uint8List(484)..fillRange(0, 484, 0xCD);
    final ctx = _tlvCtx(qq8ProfileQQ8950, t548: fakeT548);
    final body = Qq8LoginBody.build(
      ctx,
      Qq8SubCmd.password,
      qq8PasswordTlvOrderFor(qq8ProfileQQ8950.apk),
      cond: Qq8LoginConditions(t548: ctx.t548),
    );
    final tlvs = qq8ReadTlv(body, offset: 4);
    final keys = tlvs.keys.toList();
    check('密码包带 0x548（body 透传自 ctx.t548）',
        tlvs[0x548]?.length == 484 && tlvs[0x548]![0] == 0xCD);
    check('密码包以 0x542 收尾（四字节档）',
        keys.last == 0x542 &&
            tlvs[0x542]?.join(',') == [0x4A, 0x02, 0x60, 0x01].join(','),
        keys.map((t) => '0x${t.toRadixString(16)}').join(' '));
    check('0x548 的位次在 0x544 之后、0x542 之前（无 QIMEI 时 0x545 被 guard 滤掉）',
        keys.indexOf(0x548) > keys.indexOf(0x544) &&
            keys.indexOf(0x548) < keys.indexOf(0x542));

    // 无 t548（旧行为）：guard 滤掉 0x548，但 0x542 仍在。
    final bodyNoPow = Qq8LoginBody.build(
      _tlvCtx(qq8ProfileQQ8950),
      Qq8SubCmd.password,
      qq8PasswordTlvOrderFor(qq8ProfileQQ8950.apk),
      cond: Qq8LoginConditions.firstPasswordLogin,
    );
    final tNoPow = qq8ReadTlv(bodyNoPow, offset: 4);
    check('未提供自构造 PoW：0x548 被 guard 滤掉（首登官方语义不变）',
        !tNoPow.containsKey(0x548) && tNoPow.containsKey(0x542));

    // 六字节档（ssoVer ≥ 20）只出现在密码路径：9.3.60 密码包 0x542 = 4A 04 60 01 78 01。
    final body9360 = Qq8LoginBody.build(
      _tlvCtx(qq8ProfileQQ9360),
      Qq8SubCmd.password,
      qq8PasswordTlvOrderFor(qq8ProfileQQ9360.apk),
      cond: Qq8LoginConditions.firstPasswordLogin,
    );
    final t9360 = qq8ReadTlv(body9360, offset: 4);
    check('密码包（9.3.60，ssoVer=22）：0x542 = 4A 04 60 01 78 01（六字节档）',
        t9360[0x542]?.join(',') ==
            [0x4A, 0x04, 0x60, 0x01, 0x78, 0x01].join(','),
        t9360[0x542]?.map((v) => v.toRadixString(16).padLeft(2, '0')).join(' '));
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
    // 0x508 进阶提示块：官方 tlv_t508.verify 布局 = flag(1B) ‖ timeout(i32)
    // ‖ u16len ‖ userBuf。flag=1 → doFetch=true。
    final payload = _buildResponse(1, <int, List<int>>{
      0x508: <int>[1, 0, 0, 3, 0xE8, 0, 4, 0xDE, 0xAD, 0xBE, 0xEF],
    });
    final r = Qq8LoginResponse.parse(payload, _shareKey);
    final n = r.t508Notice;
    check('0x508 解包：doFetch=true / timeout=1000 / userBuf 4 字节',
        n != null &&
            n.doFetch &&
            n.timeoutMs == 1000 &&
            n.userBuf.join(',') == '222,173,190,239',
        n == null
            ? '<null>'
            : 'doFetch=${n.doFetch} timeout=${n.timeoutMs} '
                'userBuf=${n.userBuf.map((v) => v.toRadixString(16).padLeft(2, '0')).join()}');

    // flag=0 → doFetch=false；超时 0 官方兜 1000 由服务层/换文案层处理，此处只透传。
    final payload0 = _buildResponse(1, <int, List<int>>{
      0x508: <int>[0, 0, 0, 0, 0, 0, 1, 0xAB],
    });
    final n0 = Qq8LoginResponse.parse(payload0, _shareKey).t508Notice;
    check('0x508 flag=0 → doFetch=false', n0 != null && !n0.doFetch);

    // 畸形：userBuf 长度越界 → null（不静默截断）
    final payloadBad = _buildResponse(1, <int, List<int>>{
      0x508: <int>[1, 0, 0, 0, 0, 0, 64, 0x00],
    });
    final nBad = Qq8LoginResponse.parse(payloadBad, _shareKey).t508Notice;
    check('0x508 长度越界 → null', nBad == null);
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

  // -- 2e. 验证分支：设备锁（20）/ 请求下发短信（8）/ 提交短信码（7）--------
  stdout.writeln('\n【2e】验证分支：设备锁 / 短信码');
  {
    final ctx = _tlvCtx(qq8ProfileQQ8950);
    const saltHex = '0102030405060708';

    // 设备锁：204 之后自动发的那条，体 = 0x08/0x104/0x116/0x401
    {
      final d = Qq8LoginBody.buildDeviceUnlock(ctx);
      final tlvs = qq8ReadTlv(d, offset: 4);
      check(
        '设备锁：子命令 20、4 项、顺序 0x08 0x104 0x116 0x401',
        (d[0] << 8 | d[1]) == Qq8SubCmd.device &&
            tlvs.length == 4 &&
            tlvs.keys.join(',') == '8,260,278,1025',
        'sub=${d[0] << 8 | d[1]} keys=${tlvs.keys.join(',')}',
      );
      check('设备锁：0x104 = 盐', _hexCompact(tlvs[0x104]!) == saltHex,
          _hexCompact(tlvs[0x104]!));
      check('设备锁：0x401 是 16 字节随机', tlvs[0x401]?.length == 16,
          '${tlvs[0x401]?.length}');
      var threw = false;
      try {
        Qq8LoginBody.buildDeviceUnlock(_tlvCtx(qq8ProfileQQ8950, t104: Uint8List(0)));
      } on Qq8LoginException {
        threw = true;
      }
      check('设备锁：没有盐时显式拒绝', threw);
    }

    // 请求下发短信：子命令 8，体 = 0x08/0x104/0x116/0x174/0x17a/0x197
    {
      final d = Qq8LoginBody.buildSendSms(ctx);
      final tlvs = qq8ReadTlv(d, offset: 4);
      check(
        '下发短信：子命令 8、6 项、顺序含 0x174 与 0x197',
        (d[0] << 8 | d[1]) == Qq8SubCmd.sendSms &&
            tlvs.length == 6 &&
            tlvs.keys.join(',') == '8,260,278,372,378,407',
        'sub=${d[0] << 8 | d[1]} keys=${tlvs.keys.join(',')}',
      );
      check('下发短信：0x174 = 令牌', _hexCompact(tlvs[0x174]!) == 'aabbccdd',
          _hexCompact(tlvs[0x174]!));
      check('下发短信：0x17a = 9', _hexCompact(tlvs[0x17A]!) == '00000009',
          _hexCompact(tlvs[0x17A]!));
      check('下发短信：0x197 = tlv(1 字节 00)',
          _hexCompact(tlvs[0x197]!) == '000100', _hexCompact(tlvs[0x197]!));
    }

    // 提交短信码：子命令 7，体 = 0x08/0x104/0x116/0x174/0x17c/0x401/0x198/0x544
    {
      final d = Qq8LoginBody.buildSubmitSms(ctx, code: '654321');
      final tlvs = qq8ReadTlv(d, offset: 4);
      check(
        '提交短信码：子命令 7、8 项、顺序与参考一致',
        (d[0] << 8 | d[1]) == Qq8SubCmd.submitSms &&
            tlvs.length == 8 &&
            tlvs.keys.join(',') == '8,260,278,372,380,1025,408,1348',
        'sub=${d[0] << 8 | d[1]} keys=${tlvs.keys.join(',')}',
      );
      check('提交短信码：0x17c = tlv(码的字节)',
          tlvs[0x17C]!.length == 8 &&
              String.fromCharCodes(tlvs[0x17C]!.sublist(2)) == '654321',
          _hexCompact(tlvs[0x17C]!));
      check('提交短信码：0x198 = tlv(1 字节 00)',
          _hexCompact(tlvs[0x198]!) == '000100', _hexCompact(tlvs[0x198]!));
      check('提交短信码：带 0x544（8.9.50 空体）',
          tlvs.containsKey(0x544) && tlvs[0x544]!.isEmpty);

      var badCode = false;
      try {
        Qq8LoginBody.buildSubmitSms(ctx, code: '12345');
      } on Qq8LoginException {
        badCode = true;
      }
      check('提交短信码：5 位码被拒（不学参考实现的静默替换）', badCode);

      var nonNumeric = false;
      try {
        Qq8LoginBody.buildSubmitSms(ctx, code: 'abcdef');
      } on Qq8LoginException {
        nonNumeric = true;
      }
      check('提交短信码：非数字码被拒', nonNumeric);

      var noToken = false;
      try {
        Qq8LoginBody.buildSubmitSms(
          _tlvCtx(qq8ProfileQQ8950, t174: Uint8List(0)),
          code: '654321',
        );
      } on Qq8LoginException {
        noToken = true;
      }
      check('提交短信码：没有 0x174 令牌时显式拒绝', noToken);
    }

    // 响应侧：160/162/239 判定 + 0x178 手机号解析 + 0x204 提示
    {
      final phone = <int>[0x31, 0x0b, ...'13800000000'.codeUnits];
      final payload = _buildResponse(Qq8LoginResultType.smsVerify1, <int, List<int>>{
        0x104: <int>[9, 9],
        0x174: <int>[0xaa, 0xbb],
        0x178: phone,
      });
      final r = Qq8LoginResponse.parse(payload, _shareKey);
      check('短信响应：needsSmsVerify 为真', r.needsSmsVerify, 'type=${r.type}');
      check('短信响应：手机号 = 13800000000', r.verifyPhone == '13800000000',
          '${r.verifyPhone}');
      check('短信响应：0x174 令牌解出 2 字节', r.verifyToken?.length == 2);
      check('短信响应：162/239 同样判定为短信验证',
          _buildResponse(Qq8LoginResultType.smsVerify2, <int, List<int>>{0x104: <int>[1]})
                  .isNotEmpty &&
              Qq8LoginResponse.parse(
                _buildResponse(Qq8LoginResultType.smsVerify3, <int, List<int>>{
                  0x104: <int>[1],
                }),
                _shareKey,
              ).needsSmsVerify);

      final lockPayload =
          _buildResponse(Qq8LoginResultType.deviceLock, <int, List<int>>{
        0x104: <int>[1, 2],
        0x204: utf8.encode('设备锁提示'),
      });
      final lock = Qq8LoginResponse.parse(lockPayload, _shareKey);
      check('设备锁响应：needsDeviceLock 为真', lock.needsDeviceLock);
      check('设备锁响应：0x204 提示语解出', lock.deviceLockHint == '设备锁提示',
          '${lock.deviceLockHint}');
    }
  }

  // ----------------------------------------------------------------
  stdout.writeln('');
  stdout.writeln('--- 17. 手机号短信验证登录：三条子命令的组包（字段照官方 w/x/y.java）---');
  {
    // 17 检查手机号：子命令 17 + 官方"带账号串"那套数组（无 0x104 / 0x52C）
    final ctx = _tlvCtx(qq8ProfileQQ8950);
    final checkBody =
        Qq8LoginBody.buildSmsLoginCheck(ctx, phone: '13800138000');
    final checkTags = _tagsOf(checkBody);
    stdout.writeln('    17 检查：sub=${_subOf(checkBody)} '
        'tags=${checkTags.map(_hx).join(',')}');
    check('子命令 = 17', _subOf(checkBody) == 17, '${_subOf(checkBody)}');
    check('带账号串 0x112', checkTags.contains(0x112));
    check('11 项且顺序 = 官方第三套（0x100…0x154,0x112,0x116,0x521）',
        checkTags.join(',') ==
            <int>[
              0x100, 0x108, 0x109, 0x52D, 0x8, 0x142, 0x145, 0x154, 0x112, 0x116,
              0x521,
            ].join(','),
        checkTags.map(_hx).join(','));
    check('不含 0x104 / 0x52C（官方带账号串那套就没有）',
        !checkTags.contains(0x104) && !checkTags.contains(0x52C));
    check('没有 0x127/0x184（那是提交那一步的）',
        !checkTags.contains(0x127) && !checkTags.contains(0x184));
    final acc = _tlvBody(checkBody, 0x112);
    check('0x112 里就是手机号原文',
        acc != null && String.fromCharCodes(acc) == '13800138000',
        acc == null ? '(缺)' : String.fromCharCodes(acc));

    // 19 下发验证码：只要 4 项
    final refresh = Qq8LoginBody.buildSmsLoginRefresh(ctx);
    final refreshTags = _tagsOf(refresh);
    stdout.writeln('    19 下发：sub=${_subOf(refresh)} tags=${refreshTags.map(_hx).join(',')}');
    check('子命令 = 19', _subOf(refresh) == 19, '${_subOf(refresh)}');
    check('TLV 恰好 4 项且顺序 = 0x104,0x8,0x116,0x521',
        refreshTags.length == 4 &&
            refreshTags[0] == 0x104 &&
            refreshTags[1] == 0x8 &&
            refreshTags[2] == 0x116 &&
            refreshTags[3] == 0x521,
        refreshTags.map(_hx).join(','));

    // 18 提交验证码：0x127（验证码 + random）与 0x184（双 MD5）
    final random = _hex('00112233445566778899aabbccddeeff');
    final verify = Qq8LoginBody.buildSmsLoginVerify(
      ctx,
      code: '123456',
      random: random,
      mpasswd: 'AbCdEfGhIjKlMnOp',
      msalt: 0x1122334455667788,
    );
    final verifyTags = _tagsOf(verify);
    stdout.writeln('    18 提交：sub=${_subOf(verify)} tags=${verifyTags.map(_hx).join(',')}');
    check('子命令 = 18', _subOf(verify) == 18, '${_subOf(verify)}');
    check('6 项且顺序 = 0x104,0x8,0x127,0x184,0x116,0x521',
        verifyTags.join(',') ==
            <int>[0x104, 0x8, 0x127, 0x184, 0x116, 0x521].join(','),
        verifyTags.map(_hx).join(','));
    final t127 = _tlvBody(verify, 0x127);
    check('0x127 = u16(0) ‖ u16(6) ‖ "123456" ‖ u16(16) ‖ random',
        t127 != null &&
            t127.length == 2 + 2 + 6 + 2 + 16 &&
            t127[0] == 0 &&
            t127[1] == 0 &&
            ((t127[2] << 8) | t127[3]) == 6 &&
            String.fromCharCodes(t127.sublist(4, 10)) == '123456' &&
            ((t127[10] << 8) | t127[11]) == 16,
        t127 == null ? '(缺)' : '${t127.length} 字节');
    final t184 = _tlvBody(verify, 0x184);
    check('0x184 = 16 字节（双 MD5 之后就是摘要长度）',
        t184 != null && t184.length == 16, t184 == null ? '(缺)' : '${t184.length}');
    check('0x184 与"本地算出来的"一致（可独立复算）',
        t184 != null &&
            _hexOf(md5Bytes(<int>[
              ...md5Bytes(utf8.encode('AbCdEfGhIjKlMnOp')),
              for (var i = 7; i >= 0; i--) (0x1122334455667788 >> (8 * i)) & 0xFF,
            ])) ==
                _hexOf(t184),
        '');

    // 验证码通过之后那次登录（官方 GetStViaSMSVerifyLogin → 子命令 9）：
    // 账号串 = 手机号（0x112）、0x185 出现（cond.loginType == 3）、
    // 0x106 的登录类型 = 3，且 TEA 密钥种子用 msalt（不是 uin）。
    {
      const msalt = 0x1122334455667788;
      const mpasswd = 'AbCdEfGhIjKlMnOp';
      const plainPwd = '13800138000';
      final base = _tlvCtx(qq8ProfileQQ8950);
      final smsCtx = Qq8TlvContext(
        uin: 0, // 手机号登录：18 号回包之前 uin 还是 0
        apk: base.apk,
        device: base.device,
        passwordMd5: md5Bytes(utf8.encode(mpasswd)),
        seqId: base.seqId,
        ksid: base.ksid,
        t104: base.t104,
        t174: Uint8List(0),
        tgt: Uint8List(0),
        srmToken: Uint8List(0),
        msalt: msalt,
        loginType: 3,
        account: plainPwd,
        randomBytes: (n) => _fill(n, 0xab),
        teaPadding: (n) => _fill(n, 0),
        nowMillis: () => _fixedNow,
      );
      final smsBody = Qq8LoginBody.build(
        smsCtx,
        Qq8SubCmd.password,
        qq8ProfileQQ8950.apk.loginTlvOrder,
        cond: Qq8LoginConditions(accountIsUin: false, loginType: 3, t104: smsCtx.t104),
        args: <int, List<Object?>>{
          0x112: <Object?>[plainPwd],
        },
      );
      final smsTags = _tagsOf(smsBody);
      stdout.writeln('    短信后的登录：sub=${_subOf(smsBody)} '
          'tags=${smsTags.map(_hx).join(',')}');
      check('子命令 = 9（就是普通口令登录）', _subOf(smsBody) == 9);
      check('带账号串 0x112 = 手机号',
          String.fromCharCodes(_tlvBody(smsBody, 0x112) ?? <int>[]) == plainPwd);
      check('带 0x185（cond.loginType == 3 才发）', smsTags.contains(0x185));
      final b106 = _tlvBody(smsBody, 0x106);
      final seed = Uint8List(24)
        ..setRange(0, 16, base.device.guid)
        ..setRange(16, 24, <int>[
          for (var i = 7; i >= 0; i--) (msalt >> (8 * i)) & 0xFF,
        ]);
      final plain106 = qqTeaDecrypt(b106!, md5Bytes(seed));
      check('0x106 用 msalt 当种子能解开（不是 uin）', plain106.length > 90,
          'len=${plain106.length}');
      check('0x106 里的登录类型 = 3（偏移 92 的 u32）',
          ((plain106[92] << 24) |
                  (plain106[93] << 16) |
                  (plain106[94] << 8) |
                  plain106[95]) ==
              3,
          '${plain106[92]},${plain106[93]},${plain106[94]},${plain106[95]}');
      check('0x106 里的账号串 = 手机号',
          String.fromCharCodes(plain106.sublist(98, 98 + plainPwd.length)) ==
              plainPwd,
          'len=${((plain106[96] << 8) | plain106[97])}');
    }

    // 响应侧：208（检查）带盐 + random + 计数/时限 + msalt；232（刷新）带盐 + 手机号提示
    {
      final payload208 =
          _buildResponse(Qq8LoginResultType.smsLoginCheck, <int, List<int>>{
        0x104: <int>[0x01, 0x02],
        0x126: <int>[0, 0, 0, 16, ...List<int>.generate(16, (i) => i)],
        0x182: <int>[0, 0x00, 0x05, 0x00, 0x3c],
        0x183: <int>[0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88],
      });
      final r208 = Qq8LoginResponse.parse(payload208, _shareKey);
      stdout.writeln('    208 解出：type=${r208.type} '
          'random=${r208.smsLoginRandom?.length}B '
          'cnt=${r208.smsLoginLimits?.msgCnt} '
          'limit=${r208.smsLoginLimits?.timeLimit}s '
          'msalt=0x${r208.smsLoginMsalt?.toRadixString(16)}');
      check('208：isSmsLoginStep 为真', r208.isSmsLoginStep, 'type=${r208.type}');
      check('208：盐 0x104 = 0102',
          r208.smsLoginSalt != null && _hexCompact(r208.smsLoginSalt!) == '0102',
          '${r208.smsLoginSalt}');
      check('208：0x126 random 取 16 字节（长度在 body+2）',
          r208.smsLoginRandom?.length == 16 &&
              r208.smsLoginRandom!.last == 15,
          '${r208.smsLoginRandom?.length}');
      check('208：0x182 msgCnt=5 / timeLimit=60（偏移 +1 起）',
          r208.smsLoginLimits?.msgCnt == 5 &&
              r208.smsLoginLimits?.timeLimit == 60,
          '${r208.smsLoginLimits}');
      check('208：0x183 msalt = 0x1122334455667788（u64 大端）',
          r208.smsLoginMsalt == 0x1122334455667788,
          '0x${r208.smsLoginMsalt?.toRadixString(16)}');

      final payload232 =
          _buildResponse(Qq8LoginResultType.smsLoginRefresh, <int, List<int>>{
        0x104: <int>[0x03, 0x04],
        0x52B: <int>[
          0, 0, 0, 0, 0x00, 0x56, 0x00, 0x00,
          ...utf8.encode('13800000000'),
        ],
      });
      final r232 = Qq8LoginResponse.parse(payload232, _shareKey);
      stdout.writeln('    232 解出：type=${r232.type} zone=${r232.smsLoginZone} '
          'hint=${r232.smsLoginPhoneHint}');
      check('232：isSmsLoginStep 为真', r232.isSmsLoginStep, 'type=${r232.type}');
      check('232：zone=86 / 号码 = 13800000000（号码取 body+8 到末尾）',
          r232.smsLoginZone == 86 && r232.smsLoginPhoneHint == '13800000000',
          'zone=${r232.smsLoginZone} phone=${r232.smsLoginPhoneHint}');
      check('232：needsSmsVerify 为假（208/232 不是旧路那三个码）',
          !r232.needsSmsVerify && !r208.needsSmsVerify);
    }
  }

  // -- 汇总 --------------------------------------------------------------
  stdout.writeln('\n${'=' * 66}');
  stdout.writeln('通过 $_passed 项，失败 $_failed 项');
  if (_failed == 0) {
    stdout.writeln('登录主流程可用 ✓');
  }
  exit(_failed == 0 ? 0 : 1);
}
