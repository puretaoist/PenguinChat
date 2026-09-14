/// 二维码扫码登录 离线自测
///
/// 分两层：
/// * **内核层**（`lib/kernel/wlogin8/qq8_qrcode.dart`）：取码/轮询组包与两段响应
///   解析的结构自洽 —— 参考实现逐字段对照，但没有黄金向量（js 时代那份参考
///   没有二维码），所以只断言"我们自己造的形状能被自己正确解回"；
/// * **服务层**（`Qq8LoginService`）：脚本传输跑一遍
///   取码 → 轮询未扫 → 轮询已扫确认 → 二维码登录 → 上线，以及取消路径。
///
/// 运行：
/// ```bash
/// dart run tool/qq8_qrcode_selftest.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/client_api/qq8_login_service.dart';
import 'package:qqclient/infra/coder.dart';
import 'package:qqclient/kernel/crypto/ecdh.dart';
import 'package:qqclient/kernel/crypto/tea.dart';
import 'package:qqclient/kernel/wlogin8/qq8_config.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_jce.dart';
import 'package:qqclient/kernel/wlogin8/qq8_login.dart';
import 'package:qqclient/kernel/wlogin8/qq8_profiles.dart';
import 'package:qqclient/kernel/wlogin8/qq8_qrcode.dart';
import 'package:qqclient/kernel/wlogin8/qq8_sso.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tlv.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tran.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✓ $name${detail == null ? '' : '   ($detail)'}');
  } else {
    _fail++;
    stdout.writeln('  ✗ $name${detail == null ? '' : '  ($detail)'}');
  }
}

void section(String t) => stdout.writeln('\n$t');

Uint8List _hex(String s) {
  final clean = s.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hexOf(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

// ---------------------------------------------------------------------------
// 夹具：固定设备 / 固定 ECDH（与服务注入的一致，测试才能预先造密文）
// ---------------------------------------------------------------------------

final Uint8List _scannedTgtgt = _hex('1122334455667788aabbccddeeff0011');

final EcdhKeyPair _fixedEcdh = Ecdh.exchange(
  Uint8List.fromList(Qq8Config.serverEcdhPublicKey),
  privateKey: _hex('${'00' * 31}01'),
);

Qq8Device _fixtureDevice(int uin) => Qq8Device(
      product: 'piano',
      device: 'piano',
      board: 'piano',
      brand: 'Xiaomi',
      model: '25091RP04C',
      bootloader: 'unknown',
      fingerprint: 'Xiaomi/piano/piano:16/BP2A/eng:user/release-keys',
      bootId: '11111111-2222-3333-4444-555555555555',
      procVersion: 'Linux version 5.15.0',
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
      imsi: Uint8List(16),
      tgtgt: _hex('ffeeddccbbaa99887766554433221100'),
      guid: _hex('00112233445566778899aabbccddeeff'),
    );

Qq8TlvContext _tlvCtx(int uin) => Qq8TlvContext(
      uin: uin,
      apk: qq8ProfileQQ8950.apk,
      device: _fixtureDevice(uin),
      passwordMd5: Uint8List(16),
      seqId: 100,
      ksid: utf8.encode('|860000000000001|A8.9.50.10650'),
      t104: Uint8List(0),
      t174: Uint8List(0),
      tgt: Uint8List(0),
      srmToken: Uint8List(0),
    );

/// 造响应帧：`[外壳(flag=2)][SSO 头][payload]`。
Uint8List _frame(int seq, String cmd, Uint8List payload) {
  final cmdBytes = utf8.encode(cmd);
  final header = (ByteWriter()
        ..u32(0)
        ..u32(seq)
        ..u32(0)
        ..u32(4)
        ..u32(cmdBytes.length + 4)
        ..raw(cmdBytes)
        ..u32(8)
        ..raw(_hex('01020304'))
        ..u32(0))
      .build();
  final headLen = header.length - 4;
  header[0] = (headLen >> 24) & 0xff;
  header[1] = (headLen >> 16) & 0xff;
  header[2] = (headLen >> 8) & 0xff;
  header[3] = headLen & 0xff;

  final plain = Uint8List.fromList(<int>[...header, ...payload]);
  final uinBytes = utf8.encode('0');
  return (ByteWriter()
        ..u32(0x0A)
        ..u8(2)
        ..u32(0)
        ..u8(4 + uinBytes.length)
        ..raw(uinBytes)
        ..raw(qqTeaEncrypt(plain, Uint8List(16))))
      .build();
}

/// 登录层包装：`[16B 头][TEA(明文, shareKey)][0x03]`。
Uint8List _wrap(Uint8List plain) {
  final enc = qqTeaEncrypt(plain, _fixedEcdh.shareKey);
  return Uint8List.fromList(<int>[
    ...List<int>.filled(16, 0x77),
    ...enc,
    0x03,
  ]);
}

/// 取码响应明文：`[54B] ‖ u8 retcode ‖ u16-len qrsig ‖ u16 ‖ TLV…`
Uint8List _fetchPlain(int retcode, List<int> qrsig, List<int>? qrToken) {
  final w = ByteWriter()
    ..raw(List<int>.filled(54, 0x5a))
    ..u8(retcode)
    ..u16(qrsig.length)
    ..raw(qrsig)
    ..u16(0);
  if (qrToken != null) {
    w
      ..u16(0x17)
      ..u16(qrToken.length)
      ..raw(qrToken);
  }
  return w.build();
}

/// 轮询响应明文：
/// `[48B] ‖ u16 0(无子块) ‖ u32 ‖ u8 retcode [‖ u32 ‖ u32 uin ‖ 6B ‖ TLV…]`
Uint8List _queryPlain(
  int retcode, {
  int uin = 0,
  List<int>? t106,
  List<int>? t16a,
  List<int>? t318,
  List<int>? tgtgt,
}) {
  final w = ByteWriter()
    ..raw(List<int>.filled(48, 0x33))
    ..u16(0)
    ..u32(0)
    ..u8(retcode);
  if (retcode == 0) {
    w
      ..u32(0)
      ..u32(uin)
      ..raw(List<int>.filled(6, 0));
    for (final e in <int, List<int>?>{
      0x18: t106,
      0x19: t16a,
      0x65: t318,
      0x1E: tgtgt,
    }.entries) {
      final body = e.value;
      if (body == null) continue;
      w
        ..u16(e.key)
        ..u16(body.length)
        ..raw(body);
    }
  }
  return w.build();
}

/// 登录成功帧（0x119 用 [key] 加密；二维码流程里 key = 扫到的 tgtgt）。
Uint8List _successFrame(int seq, Uint8List key) {
  final inner = ByteWriter()..u16(1);
  void put(int tag, List<int> body) {
    inner
      ..u16(tag)
      ..u16(body.length)
      ..raw(body);
  }

  put(0x10A, List<int>.filled(56, 0xa1));
  put(0x143, List<int>.filled(64, 0xa2));
  put(0x305, List<int>.filled(16, 0xa3));
  put(0x133, List<int>.filled(48, 0xa4));
  put(0x134, List<int>.filled(16, 0xa5));
  put(0x16A, List<int>.filled(56, 0xa6));

  final enc = qqTeaEncrypt(inner.build(), key);
  final payload = (ByteWriter()..u16(1)..u8(0)..u16(2))
    ..u16(0x119)
    ..u16(enc.length)
    ..raw(enc);
  return _frame(seq, 'wtlogin.login', _wrap(payload.build()));
}

Uint8List _registerFrame(int seq) {
  final struct = Qq8Jce.encodeStruct(<int, Object?>{0: 10001, 9: 1});
  final payload = Qq8Jce.encode(<int, Object?>{
    0: <Object?, Object?>{'SvcRespRegister': struct},
  });
  return _frame(seq, 'StatSvc.register', Qq8Jce.encode(<int, Object?>{7: payload}));
}

class _MemStore implements Qq8TokenStore {
  Qq8TokenData? data;
  @override
  Future<Qq8TokenData?> load(int uin) async => data;
  @override
  Future<void> save(Qq8TokenData d) async => data = d;
  @override
  Future<void> clear(int uin) async => data = null;
}

Future<void> main() async {
  stdout.writeln('二维码扫码登录 离线自测');
  stdout.writeln('=' * 62);

  // ----------------------------------------------------------------
  section('1. 内核：取码请求体的结构');
  {
    final ctx = _tlvCtx(0);
    final body = Qq8Qrcode.buildFetchBody(ctx, qq8ApkWatch);
    final r = ByteReader(body);
    check('u16 子命令 = 0', r.readUint16() == 0);
    check('u32 = 16', r.readUint32() == 16);
    check('u64 = 0', r.readUint64() == 0);
    check('u8 = 8', r.read(1)[0] == 8);
    check('空 TLV（长度 0）', r.readUint16() == 0);
    check('TLV 个数 = 6', r.readUint16() == 6);

    final tags = <int>[];
    while (r.remaining > 0) {
      final tag = r.readUint16();
      final len = r.readUint16();
      final bodyBytes = r.read(len);
      tags.add(tag);
      if (tag == 0x16) {
        final inner = ByteReader(bodyBytes);
        check('0x16 用**手表**档案：u32 7 / appid 16 / subid 537065138',
            inner.readUint32() == 7 &&
                inner.readUint32() == 16 &&
                inner.readUint32() == 537065138,
            '');
        inner.read(16); // guid
        final idLen = inner.readUint16();
        final id = String.fromCharCodes(inner.read(idLen));
        final verLen = inner.readUint16();
        final ver = String.fromCharCodes(inner.read(verLen));
        final signLen = inner.readUint16();
        inner.read(signLen);
        check('0x16 里 id/ver = com.tencent.qqlite / 2.0.8',
            id == 'com.tencent.qqlite' && ver == '2.0.8', '$id $ver');
      }
    }
    check('6 个 TLV 号与参考一致：0x16 0x1B 0x1D 0x1F 0x33 0x35',
        tags.join(',') == '22,27,29,31,51,53', tags.join(','));
  }

  // ----------------------------------------------------------------
  section('2. 内核：轮询请求体与 code2d 信封');
  {
    final qrsig = _hex('aabbccdd');
    final body = Qq8Qrcode.buildQueryBody(qrsig);
    final r = ByteReader(body);
    check('u16 子命令 = 5', r.readUint16() == 5);
    check('u8 = 1', r.read(1)[0] == 1);
    check('u32 8 / u32 16', r.readUint32() == 8 && r.readUint32() == 16);
    final len = r.readUint16();
    check('qrsig 原样带上', _hexOf(r.read(len)) == 'aabbccdd');
    check('尾部 u64 0 / u8 8 / u16 0 / u16 0',
        r.readUint64() == 0 && r.read(1)[0] == 8 && r.readUint16() == 0 && r.readUint16() == 0);

    // code2d 信封：uin=0、OICQ 命令字 0x812、SSO 头 subid 用手表档案
    final ssoCtx = Qq8SsoContext(
      uin: 0,
      apk: qq8ProfileQQ8950.apk,
      device: _fixtureDevice(0),
      sessionId: _hex('01020304'),
      randomKey: _hex('0f' * 16),
      ecdhPublicKey: _fixedEcdh.publicKey,
      ecdhShareKey: _fixedEcdh.shareKey,
      sig: Qq8SigInfo(),
      seqId: 100,
    );
    final pkt = Qq8Qrcode.buildPacket(ssoCtx, Qq8Qrcode.cmdFetch,
        Qq8Qrcode.headFetch, body,
        watch: qq8ApkWatch, timestampSeconds: 1700000000);
    // 顶层 = [u32 总长][登录信封]；登录信封 = [u32 0x0A][u8 type][d2][uin][加密 SSO 段]
    final p = ByteReader(pkt);
    check('传输层长度头含自身', p.readUint32() == pkt.length, '${pkt.length}');
    check('登录信封 magic = 0x0A', p.readUint32() == 0x0A);
    check('信封 type = 2（login）', p.readUint8() == 2);
    p.readUint32(); // d2 长度字段（空 d2 → 4）
    p.readUint8(); // 常量 0
    final uinLenField = p.readUint32() - 4;
    final uinStr = String.fromCharCodes(p.read(uinLenField));
    check('信封里 uin 写 "0"（trans_emp 的约定）', uinStr == '0', uinStr);

    // SSO 段用全零密钥加密（type=2），解开才能看命令字与 subid
    final ssoPlain = qqTeaDecrypt(pkt.sublist(p.pos), Uint8List(16));
    check('SSO 段里带 wtlogin.trans_emp',
        String.fromCharCodes(ssoPlain).contains('wtlogin.trans_emp'));
    check('SSO 头里带手表 subid（537065138）',
        _hexOf(ssoPlain)
            .contains(qq8ApkWatch.subid.toRadixString(16)),
        '0x${qq8ApkWatch.subid.toRadixString(16)}');
  }

  // ----------------------------------------------------------------
  section('3. 内核：两段响应解析');
  {
    final qrsig = utf8.encode('QRsig-1234');
    final qrToken = utf8.encode('https://qrcode.example/xyz');
    final f = Qq8Qrcode.parseFetch(
        _wrap(_fetchPlain(0, qrsig, qrToken)), _fixedEcdh.shareKey);
    check('取码：retcode=0 且 ok', f.ok && f.retcode == 0);
    check('取码：qrsig 解出', utf8.decode(f.qrsig) == 'QRsig-1234');
    check('取码：0x17 解出二维码内容',
        utf8.decode(f.qrToken) == 'https://qrcode.example/xyz');

    final waiting = Qq8Qrcode.parseQuery(
        _wrap(_queryPlain(Qq8QrcodeResult.waitingForScan)), _fixedEcdh.shareKey);
    check('轮询：未扫描 → 不 confirmed，给出提示',
        !waiting.confirmed &&
            waiting.retcode == Qq8QrcodeResult.waitingForScan &&
            waiting.message.contains('尚未扫描'),
        waiting.message);

    final confirmed = Qq8Qrcode.parseQuery(
      _wrap(_queryPlain(0,
          uin: 10001,
          t106: _hex('cafe01'),
          t16a: _hex('cafe02'),
          t318: _hex('cafe03'),
          tgtgt: _scannedTgtgt)),
      _fixedEcdh.shareKey,
    );
    check('轮询：确认 → confirmed 且四块材料齐全',
        confirmed.confirmed && confirmed.uin == 10001,
        'uin=${confirmed.uin}');
    check('轮询：t106/t16a/t318/tgtgt 逐块解出',
        _hexOf(confirmed.t106!) == 'cafe01' &&
            _hexOf(confirmed.t16a!) == 'cafe02' &&
            _hexOf(confirmed.t318!) == 'cafe03' &&
            _hexOf(confirmed.tgtgt!) == _hexOf(_scannedTgtgt));

    var threw = false;
    try {
      Qq8Qrcode.parseFetch(_wrap(Uint8List(10)), _fixedEcdh.shareKey);
    } on Qq8LoginException {
      threw = true;
    }
    check('取码：明文太短 → 抛错（不猜）', threw);
  }

  // ----------------------------------------------------------------
  section('4. 内核：二维码登录包（子命令 9 + 注入三块材料）');
  {
    final ctx = _tlvCtx(10001);
    final t106 = _hex('aa' * 40);
    final t16a = _hex('bb' * 30);
    final t318 = _hex('cc' * 20);
    final body = Qq8LoginBody.buildQrLogin(ctx,
        t106: t106, t16a: t16a, t318: t318);
    final tlvs = qq8ReadTlv(body, offset: 4);
    check('子命令 = 9', (body[0] << 8 | body[1]) == 9);
    check('24 项且顺序与参考一致',
        tlvs.length == 24 &&
            tlvs.keys.join(',') == qq8QrLoginTlvOrder.join(','),
        '${tlvs.length} 项');
    check('0x106 = 扫到的整块（原样）', _hexOf(tlvs[0x106]!) == _hexOf(t106));
    check('0x16A = 扫到的 t16a', _hexOf(tlvs[0x16A]!) == _hexOf(t16a));
    check('0x318 = 扫到的 t318', _hexOf(tlvs[0x318]!) == _hexOf(t318));
    check('不含 0x104/0x544（二维码流程不发这两个）',
        !tlvs.containsKey(0x104) && !tlvs.containsKey(0x544));

    var threw = false;
    try {
      Qq8LoginBody.buildQrLogin(ctx,
          t106: Uint8List(0), t16a: t16a, t318: t318);
    } on Qq8LoginException {
      threw = true;
    }
    check('缺材料 → 抛错', threw);
  }

  // ----------------------------------------------------------------
  section('5. 服务层：取码 → 轮询 → 扫码登录 → 上线');
  {
    final qrToken = utf8.encode('https://qrcode.example/abc');
    final scripted = Qq8ScriptedTransport(<Uint8List>[
      _frame(1, 'wtlogin.trans_emp', _wrap(_fetchPlain(0, utf8.encode('sig1'), qrToken))),
      _frame(2, 'wtlogin.trans_emp',
          _wrap(_queryPlain(Qq8QrcodeResult.waitingForScan))),
      _frame(3, 'wtlogin.trans_emp',
          _wrap(_queryPlain(Qq8QrcodeResult.waitingForConfirm))),
      _frame(4, 'wtlogin.trans_emp',
          _wrap(_queryPlain(0,
              uin: 10001,
              t106: _hex('aa' * 40),
              t16a: _hex('bb' * 30),
              t318: _hex('cc' * 20),
              tgtgt: _scannedTgtgt))),
      _successFrame(5, _scannedTgtgt),
      _registerFrame(1),
    ]);
    final store = _MemStore();
    final svc = Qq8LoginService(
      tokenStore: store,
      deviceBuilder: _fixtureDevice,
      ecdhBuilder: () => _fixedEcdh,
      transportBuilder: () => scripted,
      timeout: const Duration(seconds: 5),
    );

    await svc.fetchQrcode();
    check('取码后进入 waitingQrScan',
        svc.snapshot.stage == Qq8LoginStage.waitingQrScan, svc.snapshot.stage.name);
    check('二维码内容给到 UI', svc.snapshot.qrToken != null &&
        utf8.decode(svc.snapshot.qrToken!) == 'https://qrcode.example/abc',
        '${svc.snapshot.qrToken?.length}B');

    await svc.pollQrcode();
    check('未扫描：留在 waitingQrScan 并带提示',
        svc.snapshot.stage == Qq8LoginStage.waitingQrScan &&
            (svc.snapshot.qrMessage ?? '').contains('尚未扫描'),
        svc.snapshot.qrMessage);

    await svc.pollQrcode();
    check('已扫描未确认：提示变了',
        svc.snapshot.stage == Qq8LoginStage.waitingQrScan &&
            (svc.snapshot.qrMessage ?? '').contains('确认'),
        svc.snapshot.qrMessage);

    await svc.pollQrcode();
    check('确认后自动完成登录并上线',
        svc.snapshot.stage == Qq8LoginStage.online,
        '${svc.snapshot.stage.name} ${svc.snapshot.error ?? ''}');
    check('票据已存', store.data?.usable ?? false);
    check('发了 6 个包（取码/3 次轮询/登录/注册）', scripted.sent.length == 6,
        '${scripted.sent.length}');
    await svc.close();
  }

  // ----------------------------------------------------------------
  section('6. 服务层：取消 / 超时要变成 failed');
  {
    final scripted = Qq8ScriptedTransport(<Uint8List>[
      _frame(1, 'wtlogin.trans_emp',
          _wrap(_fetchPlain(0, utf8.encode('sig2'), utf8.encode('qr')))),
      _frame(2, 'wtlogin.trans_emp',
          _wrap(_queryPlain(Qq8QrcodeResult.canceled))),
    ]);
    final svc = Qq8LoginService(
      tokenStore: _MemStore(),
      deviceBuilder: _fixtureDevice,
      ecdhBuilder: () => _fixedEcdh,
      transportBuilder: () => scripted,
      timeout: const Duration(seconds: 5),
    );
    await svc.fetchQrcode();
    await svc.pollQrcode();
    check('取消 → failed 且原因可显示',
        svc.snapshot.stage == Qq8LoginStage.failed &&
            (svc.snapshot.error ?? '').contains('取消'),
        svc.snapshot.error);
    check('取消后二维码不再展示', svc.snapshot.qrToken == null);

    // 没有取码就轮询 → 明确报错
    final svc2 = Qq8LoginService(
      tokenStore: _MemStore(),
      deviceBuilder: _fixtureDevice,
      ecdhBuilder: () => _fixedEcdh,
      transportBuilder: () => Qq8ScriptedTransport(<Uint8List>[]),
    );
    await svc2.pollQrcode();
    check('未取码就轮询 → failed',
        svc2.snapshot.stage == Qq8LoginStage.failed &&
            (svc2.snapshot.error ?? '').contains('还没有取二维码'),
        svc2.snapshot.error);
    await svc.close();
    await svc2.close();
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
