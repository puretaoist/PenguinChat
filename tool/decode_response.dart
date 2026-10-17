// 离线解码已保存的登录响应（type=16 排查用）：解出明文 TLV，
// 打印 0x130（服务器时间+出口 IP）、0x508（进阶提示块）与全部 TLV 清单。
//
// 用法（在 qqclient 目录下）：
//   dart run tool/decode_response.dart <qq8-response-*.json> [...]
//
// 响应 JSON 的 frame_hex 是 OICQ 负载（登录信封剥壳后那段），
// share_key 是本次会话的 ECDH 共享密钥 —— 与 Qq8LoginResponse.parse 同构。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/wlogin8/qq8_login.dart';
import 'package:qqclient/kernel/wlogin8/qq8_recv.dart';

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}


void main(List<String> args) {
  for (final path in args) {
    final j = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    stdout.writeln('=== ${path.split('/').last}');
    stdout.writeln('at=${j['at']} type=${j['type']}');
    stdout.writeln('t146: ${j['t146_title']} | ${j['t146_content']}');

    // frame_hex 存的是**完整响应帧**（SSO 外壳 + 负载），先拆壳再解密。
    final frame = _hex(j['frame_hex'] as String);
    final shareKey = _hex(j['share_key'] as String);
    final sso = qq8UnwrapRecv(frame);
    stdout.writeln(
        'SSO: flag=${sso.flag} seq=${sso.seq} cmd=${sso.cmd} 负载=${sso.payload.length}B');
    final r = Qq8LoginResponse.parse(sso.payload, shareKey);

    final names = r.tlvs.keys.toList()..sort();
    stdout.write('TLV (${names.length} 项):');
    for (final t in names) {
      stdout.write(' 0x${t.toRadixString(16).padLeft(3, '0')}(${r.tlvs[t]!.length}B)');
    }
    stdout.writeln();

    // 0x130：官方 case 16 解服务器时间+出口 IP；真实长度 14B，先全部按
    // u32 槽打印避免秒级时间戳假设出错（此前按 u64 读出荒谬值）。
    final t130 = r.tlvs[0x130];
    if (t130 != null) {
      final bd = ByteData.sublistView(t130);
      final slots = [
        for (var o = 0; o + 4 <= t130.length; o += 4) bd.getUint32(o),
      ];
      stdout.writeln(
          '0x130: ${t130.length}B ${t130.map((e) => e.toRadixString(16).padLeft(2, '0')).join()}');
      stdout.writeln('       u32 slots: ${slots.map((s) => '0x${s.toRadixString(16)}($s)').join(' ')}');
      if (slots.isNotEmpty && slots[0] > 1600000000 && slots[0] < 2000000000) {
        final t = DateTime.fromMillisecondsSinceEpoch(slots[0] * 1000, isUtc: true);
        stdout.writeln('       若槽 0 = 秒级时间戳 → $t UTC');
      }
    }

    // 0x508：flag/timeout/userBuf（userBuf 是加密 notice 查询载荷，只看尺寸）
    final n = r.t508Notice;
    if (n != null) {
      stdout.writeln(
          '0x508: doFetch=${n.doFetch} timeoutMs=${n.timeoutMs} userBuf=${n.userBuf.length}B');
    }

    // 0x104：若有盐，打印指纹（长度+头 8 hex）足够跨次比对
    final t104 = r.tlvs[0x104];
    if (t104 != null) {
      final head = t104.take(8).map((e) => e.toRadixString(16).padLeft(2, '0')).join();
      stdout.writeln('0x104: ${t104.length}B head=$head…');
    }
    stdout.writeln();
  }
}
