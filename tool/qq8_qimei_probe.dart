// 真机/本机一次性探针：验证 L2 的 QIMEI 取号（`Qq8Qimei.fetch`）在真实网络下能否拿到号。
//
// 为什么单独做成探针：`Qq8Qimei.fetch` 只在 `qq8_live_smoke.dart --fetch-qimei`
// 里被调用，而那条路带着"真发登录包"的两道闸门；但**取号本身不涉及账号**
// （请求体里只有设备属性，没有 uin、没有口令、没有票据），所以它可以独立验证。
//
// 跑法：dart run tool/qq8_qimei_probe.dart
// 判读：打印 q16/q36 与命中的端点 = 成功；两个端点都失败会被 fetch 抛异常。
import 'dart:io';

import 'package:qqclient/kernel/crypto/digest.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_profiles.dart';
import 'package:qqclient/kernel/wlogin8/qq8_qimei.dart';

Future<void> main(List<String> argv) async {
  // 用**固定**设备（同一个 guid 每次得到同一个 QIMEI，便于复跑比对）。
  final device = Qq8Device.generate(10001);
  final profile = qq8DefaultProfile;

  stdout.writeln('=== 探针：灯塔 OLA 取号（不涉及账号）===');
  stdout.writeln('  档案: ${profile.describe()}');
  stdout.writeln('  appKey: ${profile.beaconAppKey}');
  stdout.writeln('  androidId: ${device.androidId}');
  stdout.writeln('  guid: ${_hex(device.guid)}');
  stdout.writeln('');

  final sw = Stopwatch()..start();
  try {
    final r = await Qq8Qimei.fetch(
      device: device,
      apk: profile.apk,
      beaconAppKey: profile.beaconAppKey,
      onLog: (line) => stdout.writeln('  [取号] $line'),
    );
    sw.stop();
    stdout.writeln('');
    stdout.writeln('  ✓ 成功（${sw.elapsedMilliseconds} ms）');
    stdout.writeln('    q16 = ${r.q16}  (${r.q16.length} 字符)');
    stdout.writeln('    q36 = ${r.q36}  (${r.q36.length} 字符)');
    stdout.writeln('    端点 = ${r.endpoint}');
    stdout.writeln('');
    // 8.2.11 的 0x545 走 md5OfSource：MD5(q16)。
    final md5OfQ16 = _hex(md5Bytes(r.q16.codeUnits));
    stdout.writeln('  8.2.11 的 0x545 body = MD5(q16) = $md5OfQ16');
    stdout.writeln('  （8.9.50+ 直接发 q16 原文：${r.q16}）');
    exit(0);
  } on Object catch (e) {
    sw.stop();
    stdout.writeln('');
    stdout.writeln('  ✗ 取号失败（${sw.elapsedMilliseconds} ms）：$e');
    exit(1);
  }
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
