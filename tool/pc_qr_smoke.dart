// 扫码批次 A 冒烟：连服务器拿一个真实二维码。
//
// 用法：
//   dart run tool/pc_qr_smoke.dart              # 联网，生成二维码
//   dart run tool/pc_qr_smoke.dart --dry-run    # 只打印请求，不联网
//
// ⚠️ 连真实腾讯服务器（wtlogin.trans_emp），但不扫任何账号。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/infra/coder.dart';
import 'package:penguinchat/kernel/crypto/tea.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_proto.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_qr_login.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_qr_tlv.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_sso.dart';

Future<void> main(List<String> args) async {
  final dryRun = args.contains('--dry-run');
  var host = 'msfwifi.3g.qq.com';
  var port = 8080;

  // PC 档案参数（先取一组常见值；这些是"自称的版本"，服务端据此判定）
  // 真实 PC 档案：Acidify AppInfo.Bundled.Linux_39038
  const appId = 1600001615;
  const subAppId = 537313942;
  const mainSigMap = 169742560;
  const ssoVersion = 19;
  const packageName = 'com.tencent.qq';
  const ptVersion = '2.0.0';
  const currentVersion = '3.2.19-39038';
  const os = 'Linux';
  const deviceName = 'DESKTOP-ACIDIFY';
  const appClientVersion = 39038;

  final guid = Uint8List.fromList(List<int>.generate(16, (i) => 0x20 + i));

  final body = PcWtLogin.buildFetchQrCodeBody(
    appId: appId,
    subAppId: subAppId,
    mainSigMap: mainSigMap,
    ssoVersion: ssoVersion,
    packageName: packageName,
    ptVersion: ptVersion,
    os: os,
    deviceName: deviceName,
    guid: guid,
  );
  final req = await PcWtLogin.buildTransEmp(
    transEmpSubCmd: 0x31,
    appId: appId,
    subAppId: subAppId,
    appClientVersion: appClientVersion,
    uin: 0,
    tlvPack: body,
    guid: guid,
    currentVersion: currentVersion,
  );
  stdout.writeln('FetchQRCode 包: ${req.packet.length} 字节');

  if (dryRun) {
    final head = req.packet
        .take(24)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    stdout.writeln('--dry-run：不联网。前 24 字节: $head');
    return;
  }

  stdout.writeln('连接 $host:$port ...');
  final socket = await Socket.connect(host, port,
      timeout: const Duration(seconds: 15));
  stdout.writeln('已连接');
  socket.add(req.packet);
  await socket.flush();

  final completer = Completer<Uint8List>();
  final buf = BytesBuilder(copy: false);
  socket.listen((chunk) {
    buf.add(chunk);
    final d = buf.toBytes();
    if (d.length >= 4) {
      final len = (d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3];
      if (d.length >= len && !completer.isCompleted) {
        completer.complete(Uint8List.sublistView(d, 4, len));
      }
    }
  }, onError: (Object e) {
    if (!completer.isCompleted) completer.completeError(e);
  }, cancelOnError: true);

  try {
    final pkt = await completer.future.timeout(const Duration(seconds: 20));
    stdout.writeln('收到响应: ${pkt.length} 字节');
    final resp = PcSso.parseResponse(pkt);
    stdout.writeln('retCode=${resp.retCode} command=${resp.command}');

    // 解 wtlogin 信封
    final code2d = _unwrapTransEmp(resp.payload, req.shareKey);
    stdout.writeln('code2D body: ${code2d.length} 字节');

    // 解析 FetchQRCode 响应：u8(discard) ‖ qrSig(u16长) ‖ TLV
    final r = ByteReader(code2d);
    r.readUint8();
    final qrSig = r.readBytesWithLen16();
    final tlv = pcReadTlv(Uint8List.fromList(
      code2d.sublist(r.pos),
    ));
    final d1 = tlv[0xD1];
    String url = '';
    String qrStr = '';
    if (d1 != null) {
      final p = PbReader(d1);
      while (!p.atEnd) {
        final (f, w) = p.readTag();
        if (f == 2) {
          url = p.readString();
        } else if (f == 3) {
          qrStr = p.readString();
        } else {
          p.skip(w);
        }
      }
    }
    stdout.writeln('=== 扫码生成成功 ===');
    stdout.writeln('qrSig: ${qrSig.length} 字节');
    stdout.writeln('qrCodeUrl: $url');
    stdout.writeln('qrCodeString: $qrStr');
    stdout.writeln('TLV 键: ${tlv.keys.map((k) => '0x${k.toRadixString(16)}').join(', ')}');
    exit(url.isNotEmpty ? 0 : 3);
  } finally {
    await socket.close();
  }
}

/// 解 wtlogin 信封，拿 code2D body。
Uint8List _unwrapTransEmp(Uint8List packet, Uint8List shareKey) {
  final r = ByteReader(packet);
  if (r.readUint8() != 0x02) throw StateError('wtlogin 头不是 0x02');
  r.read(15); // internalLength(2)+ver(2)+cmd(2)+seq(2)+uin(4)+flag(1)+retryTime(2)
  final encrypted = r.read(r.remaining - 1);
  final decrypted = qqTeaDecrypt(encrypted, shareKey);
  if (r.readUint8() != 0x03) throw StateError('wtlogin 尾不是 0x03');

  // TransEmp.parseWtLoginPayload：u32 packetLength ‖ 4 ‖ u16 cmd ‖ 40 ‖ u32 appid ‖ rest
  final w = ByteReader(decrypted);
  w.readUint32();
  w.read(4);
  w.readUint16();
  w.read(40);
  w.readUint32();
  return Uint8List.fromList(decrypted.sublist(w.pos));
}
