/// 上线注册（`StatSvc.register`）离线自测
///
/// 覆盖：pb blob 黄金向量（参考实现生成）、请求体的 JCE 结构逐槽位核对、
/// logout 变体、响应判读。
///
/// 出处与证据等级见 `lib/kernel/wlogin8/qq8_register.dart` 头部。
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/qq8_register_selftest.dart
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_jce.dart';
import 'package:qqclient/kernel/wlogin8/qq8_pb.dart';
import 'package:qqclient/kernel/wlogin8/qq8_register.dart';

int _pass = 0;
int _fail = 0;

void ok(String name, [String? note]) {
  _pass++;
  stdout.writeln('  \u2713 $name${note == null ? '' : '   ($note)'}');
}

void bad(String name, String detail) {
  _fail++;
  stdout.writeln('  \u2717 $name\n      → $detail');
}

void checkEq(String name, Object? actual, Object? expected) {
  if ('$actual' == '$expected') {
    ok(name);
  } else {
    bad(name, '期望 $expected，实际 $actual');
  }
}

void section(String t) => stdout.writeln('\n$t');

Uint8List hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String toHex(List<int> b) =>
    b.map((x) => (x & 0xff).toRadixString(16).padLeft(2, '0')).join();

/// 固定时间戳（与 gen_pb_vector.cjs 一致）。
const int _ts = 1700000000000;

/// 黄金向量：`../analysis/scripts/gen_pb_vector.cjs` 生成。
const String _pbGolden = '0a09082e1080d095ffbc310a05089b021000';

Qq8Device _device() => Qq8Device(
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
      tgtgt: Uint8List(16),
      guid: hex('00112233445566778899aabbccddeeff'),
    );

void testPbBlob() {
  section('1. pb blob（黄金向量来自 oicq lib/algo/pb.js）');

  final blob = Qq8Pb.encode(<int, Object?>{
    1: <Object?>[
      <int, Object?>{1: 46, 2: _ts},
      <int, Object?>{1: 283, 2: 0},
    ],
  });
  checkEq('长度 18', blob.length, 18);
  checkEq('逐字节一致', toHex(blob), _pbGolden);
}

void testBody() {
  section('2. 请求体结构（JCE 逐槽位核对）');

  final device = _device();
  final body = Qq8Register.buildBody(
    uin: 10001,
    device: device,
    nowMillis: _ts,
  );

  // 外层包装：service / method
  final wrapper = Qq8Jce.decode(body);
  checkEq('service = PushService', wrapper[5], 'PushService');
  checkEq('method = SvcReqRegister', wrapper[6], 'SvcReqRegister');

  final f = Qq8Jce.decodeWrapper(body);
  checkEq('tag0 = uin', f[0], 10001);
  checkEq('tag1 = 7（上线）', f[1], 7);
  checkEq('tag4 = 11', f[4], 11);
  checkEq('tag11 = sdk', f[11], 29);
  checkEq('tag16 = guid', toHex(f[16] as Uint8List),
      '00112233445566778899aabbccddeeff');
  checkEq('tag17 = 2052', f[17], 2052);
  checkEq('tag19/20 = model', '${f[19]}/${f[20]}', '25091RP04C/25091RP04C');
  checkEq('tag21 = release', f[21], '10');
  checkEq('tag30/31 = brand', '${f[30]}/${f[31]}', 'Xiaomi/Xiaomi');
  checkEq('tag33 = pb blob（与黄金向量一致）', toHex(f[33] as Uint8List),
      _pbGolden);
  checkEq('tag38 = 1000', f[38], 1000);
  checkEq('tag39 = 98', f[39], 98);
  checkEq('null 槽位（15/25/35/37）被跳过',
      '${f.containsKey(15)}${f.containsKey(25)}${f.containsKey(35)}${f.containsKey(37)}',
      'falsefalsefalsefalse');
  checkEq('实发槽位数 36（40 - 4 个 null）', f.length, 36);

  // logout 变体
  final out = Qq8Jce.decodeWrapper(
      Qq8Register.buildBody(uin: 10001, device: device, logout: true, nowMillis: _ts));
  checkEq('logout：tag1 = 0', out[1], 0);
  checkEq('logout：tag4 = 21', out[4], 21);
  checkEq('logout：tag10 = 44', out[10], 44);
}

void testResponse() {
  section('3. 响应判读');

  // 响应也是 WUP 包装：合成 [sBuffer(7) → 属性表 → SvcRespRegister 结构]。
  // 官方字段序（SvcRespRegister.java:63-85）：2=cReplyCode、9=bCrashFlag，
  // 判据是 cReplyCode == 0（msf/core/push/e.java:196-235）。
  Uint8List respWith({int? replyCode, int? crashFlag}) {
    final struct = Qq8Jce.encodeStruct(<int, Object?>{
      0: 10001,
      if (replyCode != null) 2: replyCode,
      if (crashFlag != null) 9: crashFlag,
    });
    final payload = Qq8Jce.encode(<int, Object?>{
      0: <Object?, Object?>{'SvcRespRegister': struct},
    });
    return Qq8Jce.encode(<int, Object?>{7: payload});
  }

  checkEq('cReplyCode=0 → 成功', Qq8Register.parseResponse(respWith(replyCode: 0)), true);
  checkEq('cReplyCode=2 → 失败（明确被拒）',
      Qq8Register.parseResponse(respWith(replyCode: 2)), false);
  // bCrashFlag=1 只是崩溃标记，不能当失败（旧口径会误判）
  checkEq('cReplyCode=0 且 bCrashFlag=1 → 仍成功',
      Qq8Register.parseResponse(respWith(replyCode: 0, crashFlag: 1)), true);
  // tag2 缺失（老样本/畸形包）退回旧口径
  checkEq('缺 cReplyCode、bCrashFlag=1 → 退化口径判成功',
      Qq8Register.parseResponse(respWith(crashFlag: 1)), true);
  checkEq('缺 cReplyCode、bCrashFlag=0 → 退化口径判失败',
      Qq8Register.parseResponse(respWith(crashFlag: 0)), false);
}

void testSetStatus() {
  section('4. 在线状态上报（StatSvc.SetStatusFromClient）');

  final device = _device();
  final body = Qq8Register.buildSetStatusBody(
    uin: 10001,
    device: device,
  );

  final wrapper = Qq8Jce.decode(body);
  checkEq('service = PushService', wrapper[5], 'PushService');
  checkEq('method 仍是 SvcReqRegister', wrapper[6], 'SvcReqRegister');

  final f = Qq8Jce.decodeWrapper(body);
  checkEq('tag0 = uin', f[0], 10001);
  checkEq('tag1 = 7（与 register 相同）', f[1], 7);
  checkEq('tag4 = 11（在线）', f[4], Qq8OnlineStatus.online);
  checkEq('tag10 = 248（状态上报专用，register 是 0）', f[10], 248);
  checkEq('tag12 = 0（register 是 1）', f[12], 0);
  checkEq('tag23 = 473（register 是 0）', f[23], 473);
  // 分开断言：两个空串拼起来只剩分隔符，写成 '//' 会得到一条永远失败的假断言
  checkEq('tag30 = 空串（register 是 brand）', f[30], '');
  checkEq('tag31 = 空串（register 是 brand）', f[31], '');
  checkEq('tag33 缺失（状态包不带 pb blob）', f.containsKey(33), false);
  checkEq('tag34 = 1（register 是 0）', f[34], 1);
  checkEq('tag38 = 0（register 是 1000）', f[38], 0);
  checkEq('tag39 = 0（register 是 98）', f[39], 0);
  checkEq('null 槽位（15/25/35/37）仍被跳过',
      '${f.containsKey(15)}${f.containsKey(25)}${f.containsKey(35)}${f.containsKey(37)}',
      'falsefalsefalsefalse');
  checkEq('实发槽位数 35（40 - 5 个 null，比 register 少 pb blob）', f.length, 35);

  // 与 register 的差异必须**只有**预期那几槽——防止将来照抄字段表把两边做成一样
  final reg = Qq8Jce.decodeWrapper(
      Qq8Register.buildBody(uin: 10001, device: device, nowMillis: _ts));
  final diff = <int>[];
  for (final k in <int>{...reg.keys, ...f.keys}) {
    final a = reg.containsKey(k) ? reg[k].toString() : '<无>';
    final b = f.containsKey(k) ? f[k].toString() : '<无>';
    if (a != b) diff.add(k);
  }
  diff.sort();
  checkEq('与 register 的差异槽位 = [10, 12, 23, 30, 31, 33, 34, 38, 39]',
      diff.join(','), '10,12,23,30,31,33,34,38,39');

  // 状态值可换（将来做「离开/勿扰」时不用改结构）
  final absent = Qq8Jce.decodeWrapper(
      Qq8Register.buildSetStatusBody(
          uin: 10001, device: device, status: Qq8OnlineStatus.absent));
  checkEq('status=31 → tag4 = 31', absent[4], 31);
}

void main() {
  stdout.writeln('上线注册（StatSvc.register）离线自测');
  stdout.writeln('=' * 62);

  testPbBlob();
  testBody();
  testResponse();
  testSetStatus();

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
