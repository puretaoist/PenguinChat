/// QIMEI 取号（`lib/kernel/wlogin8/qq8_qimei.dart`）离线自测
///
/// 只验**能离线验的部分**：上报 JSON 的字段与形状、`sign` 公式、
/// AES 往返、响应解析、RSA 输出长度。**真发那一步（POST 到 snowflake）
/// 只能真机验**——本自测不联网。
///
/// 运行：
/// ```bash
/// dart run tool/qq8_qimei_selftest.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:qqclient/kernel/crypto/digest.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_profiles.dart';
import 'package:qqclient/kernel/wlogin8/qq8_qimei.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  ✓ $name${detail == null ? '' : '   ($detail)'}');
  } else {
    _failed++;
    stdout.writeln('  ✗ $name${detail == null ? '' : '  ($detail)'}');
  }
}

void section(String t) => stdout.writeln('\n$t');

String _hex(List<int> b) =>
    b.map((x) => (x & 0xFF).toRadixString(16).padLeft(2, '0')).join();

Future<void> main() async {
  stdout.writeln('QIMEI 取号 离线自测');
  stdout.writeln('=' * 62);

  final device = Qq8Device.generate(10001);
  final apk = qq8ProfileQQ8950.apk;
  final beaconKey = qq8ProfileQQ8950.beaconAppKey;

  // ----------------------------------------------------------------
  section('1. 上报 JSON：字段与形状（照 oicq genRandomPayloadByDevice）');
  {
    final payload = Qq8Qimei.buildPayload(
      device: device,
      apk: apk,
      beaconAppKey: beaconKey,
      random: Random(42),
      now: DateTime(2026, 9, 13, 8, 30, 15),
    );
    final m = jsonDecode(payload) as Map<String, dynamic>;
    stdout.writeln('    payload ${payload.length}B，字段 ${m.length} 个');

    check('appKey = 灯塔 appkey（0S200MNJT807V3GE）',
        m['appKey'] == '0S200MNJT807V3GE', '${m['appKey']}');
    check('platformId=1 / deviceType=Phone / channelId=2017',
        m['platformId'] == 1 &&
            m['deviceType'] == 'Phone' &&
            m['channelId'] == '2017');
    check('packageId = com.tencent.mobileqq', m['packageId'] == 'com.tencent.mobileqq',
        '${m['packageId']}');
    check('androidId / imei 来自设备',
        m['androidId'] == device.androidId && m['imei'] == device.imei);
    check('osVersion = Android <版本>,level <sdk>',
        m['osVersion'] == 'Android ${device.version.release},level ${device.version.sdk}',
        '${m['osVersion']}');
    check('qimei/qimei36 为空串（本次就是去要号）',
        m['qimei'] == '' && m['qimei36'] == '');
    check('sdkVersion = 1.2.13.6（参考实现内嵌值）',
        m['sdkVersion'] == '1.2.13.6');

    final beacon = '${m['beaconIdSrc']}';
    final parts = beacon.split(';').where((s) => s.isNotEmpty).toList();
    check('beaconIdSrc 是 40 段 ki: 片段', parts.length == 40, '${parts.length}');
    check('k1 用"月+两个随机数"（yyyy-MM-01…）',
        parts[0].startsWith('k1:2026-09-01'), parts[0]);
    check('k3 固定 16 个 0', parts[2] == 'k3:0000000000000000', parts[2]);
    check('k4 是 16 位十六进制',
        RegExp(r'^k4:[0-9a-f]{16}$').hasMatch(parts[3]), parts[3]);
    check('其余是 0..9999 的随机数',
        parts[4].startsWith('k5:') && int.parse(parts[4].substring(3)) < 10000,
        parts[4]);

    final reserved = jsonDecode('${m['reserved']}') as Map<String, dynamic>;
    check('reserved 里的设备字段与设备一致（bod/brd/dv/name/kernel）',
        reserved['bod'] == device.board &&
            reserved['brd'] == device.brand &&
            reserved['dv'] == device.device &&
            reserved['name'] == device.model &&
            reserved['kernel'] == device.fingerprint);
    check('reserved.uptimes = 本地时间串（yyyy-MM-dd HH:mm:ss）',
        reserved['uptimes'] == '2026-09-13 08:30:15', '${reserved['uptimes']}');
  }

  // ----------------------------------------------------------------
  section('2. 请求体：RSA / AES / sign 三项');
  {
    final payload = Qq8Qimei.buildPayload(
      device: device,
      apk: apk,
      beaconAppKey: beaconKey,
      random: Random(7),
      now: DateTime(2026, 9, 13, 8, 30, 15),
    );
    final req = Qq8Qimei.buildRequest(payload, random: Random(99));
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    stdout.writeln('    key ${('${body['key']}').length} 字符 / '
        'params ${('${body['params']}').length} 字符 / '
        'sign ${('${body['sign']}').length} 字符');

    check('体里六个字段齐全（key/params/time/nonce/sign/extra）',
        body.keys.toSet().containsAll(
            <String>{'key', 'params', 'time', 'nonce', 'sign', 'extra'}),
        body.keys.join(','));

    final keyBytes = base64.decode('${body['key']}');
    check('key = RSA 加密后的 128 字节（1024 位）', keyBytes.length == 128,
        '${keyBytes.length}');

    final decrypted = Qq8Qimei.aesCbcDecrypt('${body['params']}', req.cryptKey);
    check('params 用 cryptKey 解回来 = 上报 JSON 原文', decrypted == payload,
        '${decrypted.length} vs ${payload.length}');

    final expectSign = _hex(md5Bytes(Uint8List.fromList(utf8.encode(
        '${body['key']}${body['params']}${body['time']}${body['nonce']}'
        '${Qq8Qimei.secret}'))));
    check('sign = MD5(key + params + time + nonce + secret)',
        body['sign'] == expectSign, '${body['sign']}');
    check('cryptKey 是 16 位（a-f0-9）', req.cryptKey.length == 16 &&
        RegExp(r'^[a-f0-9]{16}$').hasMatch(req.cryptKey), req.cryptKey);
  }

  // ----------------------------------------------------------------
  section('3. 响应解析：{code,data} → q16/q36');
  {
    const cryptKey = 'abcdef1234567890';
    final inner = jsonEncode(<String, String>{
      'q16': 'A1B2C3D4E5F60718',
      'q36': 'A1B2C3D4E5F60718A1B2C3D4E5F60718A1B2',
    });
    final data = Qq8Qimei.aesCbcEncryptB64(inner, cryptKey);
    final rsp = jsonEncode(<String, Object?>{'code': 0, 'data': data});
    final r = Qq8Qimei.decodeResponse(rsp, cryptKey);
    check('q16/q36 解出来', r.q16 == 'A1B2C3D4E5F60718' && r.q36.length == 36,
        '${r.q16} / ${r.q36.length}');

    var codeErr = '';
    try {
      Qq8Qimei.decodeResponse(jsonEncode(<String, Object?>{'code': 5}), cryptKey);
    } on Qq8QimeiException catch (e) {
      codeErr = e.message;
    }
    check('非 0 code 显式报错（不静默）', codeErr.contains('code=5'), codeErr);

    var junkErr = '';
    try {
      Qq8Qimei.decodeResponse('not-json', cryptKey);
    } on Object catch (e) {
      junkErr = '$e';
    }
    check('坏响应显式报错', junkErr.isNotEmpty);

    var emptyErr = '';
    try {
      Qq8Qimei.decodeResponse(jsonEncode(<String, Object?>{'code': 0, 'data': ''}),
          cryptKey);
    } on Qq8QimeiException catch (e) {
      emptyErr = e.message;
    }
    check('没有 data 字段时显式报错', emptyErr.contains('data'), emptyErr);
  }

  // ----------------------------------------------------------------
  section('4. 端点与常量（与两处出处对齐）');
  {
    check('参考实现的端点 = /ola/android',
        Qq8Qimei.endpointOlaAndroid == 'https://snowflake.qq.com/ola/android');
    check('官方新版端点 = /ola/v2',
        Qq8Qimei.endpointOlaV2 == 'https://snowflake.qq.com/ola/v2');
    check('secret 与参考实现一致（ZdJqM15EeO2zWc08）',
        Qq8Qimei.secret == 'ZdJqM15EeO2zWc08');
    check('RSA 模数是 1024 位（128 字节）',
        (Qq8Qimei.rsaModulus.bitLength + 7) ~/ 8 == 128,
        '${Qq8Qimei.rsaModulus.bitLength} 位');
    check('指数 = 65537', Qq8Qimei.rsaExponent == BigInt.from(65537));
  }

  // ----------------------------------------------------------------
  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_passed 项，失败 $_failed 项');
  if (_failed == 0) {
    stdout.writeln('取号模块离线部分可用 ✓（真发要联网，另行验证）');
  }
  exit(_failed == 0 ? 0 : 1);
}
