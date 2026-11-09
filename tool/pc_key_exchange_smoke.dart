// PC NTLogin 生死验证：连腾讯服务器打一次 SsoKeyExchange。
//
// ## 风险说明（为什么这个冒烟是低风险的）
//
// - 用**假 uin**（默认 10000，不存在的号），不碰任何真实账号
// - **不发密码、不发票据、不登录**
// - 只做一次 ECDH 密钥交换（`trpc.login.ecdh.EcdhService.SsoKeyExchange`）
// - 服务端要么回 `sessionTicket/sessionKey`（协议对），要么回错误码
//
// ## 用法
//
//   dart run tool/pc_key_exchange_smoke.dart --uin=10000
//
// 连 `msfwifi.3g.qq.com:8080`。加 `--dry-run` 只打印请求结构不联网。
//
// ⚠️ 这是**连真实腾讯服务器**。执行前请确认你有意为之（见 SAFETY.md）。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/kernel/wlogin8/pc/pc_key_exchange.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_sso.dart';

Future<void> main(List<String> args) async {
  var uin = 10000;
  var dryRun = false;
  var host = 'msfwifi.3g.qq.com';
  var port = 8080;
  for (final a in args) {
    if (a.startsWith('--uin=')) uin = int.parse(a.substring(6));
    if (a == '--dry-run') dryRun = true;
    if (a.startsWith('--host=')) host = a.substring(7);
    if (a.startsWith('--port=')) port = int.parse(a.substring(7));
  }

  // guid：16 字节。真机应固定持久化；这里用固定值便于复现。
  final guid = Uint8List.fromList(List<int>.generate(16, (i) => 0x10 + i));

  final req = PcKeyExchange.build(uin: '$uin', guid: guid);
  stdout.writeln('KeyExchange 请求已构造: ${req.bytes.length} 字节 (uin=$uin)');

  final sso = PcSso.buildRequest12(
    uin: uin,
    sequence: 0x10000 + DateTime.now().millisecondsSinceEpoch % 0x10000,
    subAppId: 537064117, // 见 profile；PC 端可不同，先沿用
    currentVersion: '9.9.9-39038',
    command: 'trpc.login.ecdh.EcdhService.SsoKeyExchange',
    payload: req.bytes,
    guid: guid,
  );
  stdout.writeln('SSO 包: ${sso.length} 字节');

  if (dryRun) {
    stdout.writeln('--dry-run：不联网。前 32 字节: '
        '${sso.take(32).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
    return;
  }

  stdout.writeln('连接 $host:$port ...');
  final socket = await Socket.connect(host, port,
      timeout: const Duration(seconds: 15));
  stdout.writeln('已连接');

  // 发送：sso 已是「u32 总长 + 内容」，直接写
  socket.add(sso);
  await socket.flush();

  // 读响应：4 字节长度 + (len-4) 字节
  final completer = Completer<Uint8List>();
  final buf = BytesBuilder(copy: false);
  socket.listen((chunk) {
    buf.add(chunk);
    final data = buf.toBytes();
    if (data.length >= 4) {
      final len = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
      if (data.length >= len && !completer.isCompleted) {
        completer.complete(Uint8List.sublistView(data, 4, len));
      }
    }
  }, onError: (Object e) {
    if (!completer.isCompleted) completer.completeError(e);
  }, cancelOnError: true);

  try {
    final packet = await completer.future.timeout(const Duration(seconds: 20));
    stdout.writeln('收到响应: ${packet.length} 字节');
    final resp = PcSso.parseResponse(packet);
    stdout.writeln('retCode=${resp.retCode} command=${resp.command}');
    if (!resp.ok) {
      stdout.writeln('服务端拒绝：extra=${resp.extra}');
      stdout.writeln('payload(${resp.payload.length}B): '
          '${resp.payload.take(64).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
      exit(2);
    }
    final result = PcKeyExchange.parse(
      response: resp.payload,
      keyPair: req.keyPair,
    );
    stdout.writeln('=== KeyExchange 成功 ===');
    stdout.writeln('sessionKey: ${result.sessionKey.length} 字节');
    stdout.writeln('sessionTicket: ${result.sessionTicket.length} 字节');
    stdout.writeln('expiration: ${result.expiration}');
    stdout.writeln('=> 生死验证通过：PC NTLogin 可纯 Dart 实现');
    exit(0);
  } finally {
    await socket.close();
  }
}
