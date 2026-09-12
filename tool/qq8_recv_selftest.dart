/// 响应拆壳（`qq8_recv.dart`）离线自测
///
/// 黄金向量：**2026-09-11 真机响应的完全脱敏版**——外层与内层 payload 里的
/// 账号都替换为 10001，并按同款（零密钥 TEA）重新封装；结构仍来自真机响应
/// （`vectors/recv-real-dump-sanitized.hex`，原始件在 analysis 的日志目录）。
///
/// 结构出处：oicq js 时代的 `parseSSO`（②）+ 官方 8.9.50 `oicq_request.d()`
/// （③ 的定界与 rsp flag）+ 真机 dump 逐字段核对（①）——见 `qq8_recv.dart` 头部。
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/qq8_recv_selftest.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/infra/coder.dart';
import 'package:qqclient/kernel/crypto/tea.dart';
import 'package:qqclient/kernel/wlogin8/qq8_login.dart';
import 'package:qqclient/kernel/wlogin8/qq8_recv.dart';

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

// GENERATED-VECTORS-BEGIN（真机 dump 的脱敏版）
const String _realDump =
    '0000000a0200000000093130303031c9cccdbeda0a8fc4c20d7daf88c069b225'
        '11fbe554ec9a80fa37d70b1ca8455f5c4317ba9c50595f20d355fd8c8391d963'
        '4595c8af12a86b75a4049e3e74783f30e4dce02d09119cd48ad1c3fed23399e3'
        'e9484eac8416c0ef03fc91281f100e771d3eb88943c0ef3b44ae8c501abad23a'
        'ac6a7b1b8c5c4c3bf04d7195a0883a7d78ef8d5eee4b8b21131f6d29b3d31b54'
        'f0741fac8d2f865b3f7a67e6b361e4d4f71db4cee2e448af9fb78e5e739a39b4'
        '525c15d0679e3f68f636ef9f2cbb9d7ca14d01c03ac00ba06cdcaffe415d5292'
        'bf14848a3c7ea1cd00b0d827ca08325c00a7263cbffd5691fe0e1ee55d8c5b70'
        '1e9bc2f4c47360f2693780a2328d4da0592844067f8319c39887375a7d068c56'
        '845e90d6058623f0475983bba39fffe6545f6cf33c8d88a090007fce10fa29eb'
        '00a68120de9a5222f829a7a94f1599bb49201cd71d3cfad0dca10b5574c655f4'
        'cfc9a2d2113b84b3ee1a9eced72e3918e3695ec4b2962124d5ed6d063366d5e1'
        '23765295db674809091c80b91d0603bb3889f671ddc4ab6dfd9d645b82c7772d'
        '0e29a1769fedc1d6233bb6480614429b9b62791dde24b0f94ce02a2c342d0fb1'
        '631c9c3dfb4c9459bde32dccd4981ddf125e0d5c6e7fe2db3c9c06a9fddb1749'
        '9397b3e60f0a82308e3e7d902e18b0eef35dba5947609d26751956ea9385920f'
        '6c007f7f0c5a6fbaaeec298af938fd1e4d61d2d0f88c5fe00ec0319c99f7651d'
        '21b0ebd7da3e141c01fba46f381822d76a4bf3866305b1b82c20112613cba0ec'
        'dfac4ac9b8188245c15894cf8acd9a665b4900e72264730675102b68926f5444'
        'c11426636903070e14cebee26aba002341647ffc25d1a3bcbd348c1d50057226'
        'b6cd9e438d429ee6a5d543c11b21f5b380b61f7c9b474f7a1230493518584993'
        '73dca57e7c523a753ace48be41237744a6182ab0629810347cb3e05e64f997e5'
        '2348e22fe7f430';
// GENERATED-VECTORS-END

void testRealDump() {
  section('1. 真机响应（脱敏版）拆壳');

  final r = qq8UnwrapRecv(hex(_realDump));
  checkEq('外壳 flag=2（TEA 全零）', r.flag, 2);
  checkEq('SSO seq 与真机一致', r.seq, 32150);
  checkEq('SSO cmd', r.cmd, 'wtlogin.login');
  checkEq('retcode=0', r.retcode, 0);
  checkEq('负载长度 617', r.payload.length, 617);
  checkEq('负载-17 是 8 的倍数（可交内层 ECDH）', (r.payload.length - 17) % 8, 0);
  checkEq('负载头部前 9 字节', toHex(r.payload.sublist(0, 9)), '0202691f4108100001');
  checkEq('负载 rsp flag（u16@13，官方 d() 读法）',
      (r.payload[13] << 8) | r.payload[14], 0);
  checkEq('负载尾字节 0x03', r.payload.last, 3);
  // 账号在负载的 [9..13)，按脱敏原则不做断言。
}

/// 合成一个 `[外壳][SSO 头][payload]` 的帧，覆盖三个 flag 与错误分支。
Uint8List _ssoFrame({
  required int shellFlag,
  required Uint8List payload,
  int seq = 0x1234,
  String cmd = 'wtlogin.login',
  int retcode = 0,
  Uint8List? d2key,
}) {
  final cmdBytes = utf8.encode(cmd);
  final header = (ByteWriter()
        ..u32(0) // headlen 占位，稍后回填
        ..u32(seq)
        ..u32(retcode)
        ..u32(4)
        ..u32(cmdBytes.length + 4)
        ..raw(cmdBytes)
        ..u32(8)
        ..raw(hex('01020304'))
        ..u32(0) // 压缩标志 0
        ..raw(Uint8List(4))) // 真机头里 [45, 65) 还有字段，这里补 4 字节
      .build();
  final headlen = header.length - 4;
  header[0] = (headlen >> 24) & 0xff;
  header[1] = (headlen >> 16) & 0xff;
  header[2] = (headlen >> 8) & 0xff;
  header[3] = headlen & 0xff;

  final plain = Uint8List.fromList(<int>[...header, ...payload]);
  final Uint8List ct;
  if (shellFlag == 0) {
    ct = plain;
  } else if (shellFlag == 1) {
    ct = qqTeaEncrypt(plain, d2key!);
  } else if (shellFlag == 2) {
    ct = qqTeaEncrypt(plain, Uint8List(16));
  } else {
    ct = plain;
  }
  final uinBytes = utf8.encode('10001');
  return (ByteWriter()
        ..u32(0x0A)
        ..u8(shellFlag)
        ..u32(0)
        ..u8(4 + uinBytes.length)
        ..raw(uinBytes)
        ..raw(ct))
      .build();
}

void testShellFlags() {
  section('2. 三个外壳 flag + 错误分支');

  final payload = hex('0202691f4108100001deadbeef'); // 任意负载（这里只验拆壳）
  for (final flag in <int>[0, 1, 2]) {
    final key = flag == 1 ? hex('00112233445566778899aabbccddeeff') : null;
    final frame = _ssoFrame(
      shellFlag: flag,
      payload: payload,
      d2key: flag == 1 ? key : null,
    );
    final r = qq8UnwrapRecv(frame, d2key: key);
    checkEq('flag=$flag：负载还原', toHex(r.payload), toHex(payload));
    checkEq('flag=$flag：seq', r.seq, 0x1234);
    checkEq('flag=$flag：cmd', r.cmd, 'wtlogin.login');
  }

  // flag=1 但没有 d2key → 显式报错
  var threw = false;
  try {
    qq8UnwrapRecv(
      _ssoFrame(
        shellFlag: 1,
        payload: payload,
        d2key: hex('00112233445566778899aabbccddeeff'),
      ),
      d2key: null,
    );
  } on Qq8LoginException {
    threw = true;
  }
  checkEq('flag=1 缺 d2key 时抛错', threw, true);

  // 未知 flag
  threw = false;
  try {
    qq8UnwrapRecv(_ssoFrame(shellFlag: 3, payload: payload));
  } on Qq8LoginException {
    threw = true;
  }
  checkEq('未知外壳 flag 抛错', threw, true);

  // magic 不对
  threw = false;
  final badMagic = Uint8List.fromList(_ssoFrame(shellFlag: 0, payload: payload));
  badMagic[3] = 0x0B;
  try {
    qq8UnwrapRecv(badMagic);
  } on Qq8LoginException {
    threw = true;
  }
  checkEq('magic 非 0x0A 抛错', threw, true);

  // retcode 非 0
  threw = false;
  try {
    qq8UnwrapRecv(_ssoFrame(shellFlag: 0, payload: payload, retcode: 7));
  } on Qq8LoginException {
    threw = true;
  }
  checkEq('retcode 非 0 抛错', threw, true);

  // 非空 d2：当前显式拒绝（无样本不猜）
  threw = false;
  final withD2 = Uint8List.fromList(_ssoFrame(shellFlag: 0, payload: payload));
  withD2[8] = 1; // d2len = 1
  try {
    qq8UnwrapRecv(withD2);
  } on Qq8LoginException {
    threw = true;
  }
  checkEq('非空 d2 显式拒绝（无样本）', threw, true);

  // 太短
  threw = false;
  try {
    qq8UnwrapRecv(Uint8List(8));
  } on Qq8LoginException {
    threw = true;
  }
  checkEq('过短的帧抛错', threw, true);
}

void main() {
  stdout.writeln('响应拆壳离线自测');
  stdout.writeln('=' * 62);
  stdout.writeln('黄金向量：真机响应 716 字节的脱敏版（账号→10001，密文原样）。');

  testRealDump();
  testShellFlags();

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
