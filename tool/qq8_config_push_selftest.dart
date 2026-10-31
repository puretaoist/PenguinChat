/// ConfigPush 请求解析与回执构造的离线自测（缺陷1 / P2 / P3）。
///
/// 覆盖 `lib/kernel/wlogin8/qq8_config_push.dart`：
///  - 请求 `serverconfig/f.java:20-36`：1=type / 2=data / 3=seq；
///  - 回执 `serverconfig/g.java:20-38`：1=type / 2=seq / 3=data(仅 type3)；
///  - 两者 tag 号不同（回执 tag2 是 seq，不是 data）；
///  - 外层 4 字节长度前缀可有可无（真机带、解析侧两种都收）；
///  - 无法识别时返回 null（调用方据此**不回执**，官方外层 decode 失败也不回）。
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/qq8_config_push_selftest.dart
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/wlogin8/qq8_config_push.dart';
import 'package:qqclient/kernel/wlogin8/qq8_jce.dart';

int _pass = 0;
int _fail = 0;

void ok(String name, [String? note]) {
  _pass++;
  stdout.writeln('  \u2713 $name${note == null ? '' : '   ($note)'}');
}

void bad(String name, String detail) {
  _fail++;
  stdout.writeln('  \u2717 $name\n      \u2192 $detail');
}

void checkEq(String name, Object? actual, Object? expected) {
  if ('$actual' == '$expected') {
    ok(name);
  } else {
    bad(name, '期望 $expected，实际 $actual');
  }
}

String toHex(List<int> b) =>
    b.map((x) => (x & 0xff).toRadixString(16).padLeft(2, '0')).join();

/// 造一个 PushReq 线上 payload（默认带 4 字节长度前缀，与真机一致）。
Uint8List _pushReqPayload({
  required int type,
  Uint8List? data,
  required int seq,
  bool withLenPrefix = true,
}) {
  final wup = Qq8Jce.encodeWrapper(
    service: 'PushService',
    method: 'PushReq',
    attributes: <String, Uint8List>{
      'PushReq': Qq8Jce.encodeStruct(<int, Object?>{1: type, 2: data, 3: seq}),
    },
  );
  if (!withLenPrefix) return wup;
  final out = Uint8List(4 + wup.length);
  out[0] = (wup.length >> 24) & 0xff;
  out[1] = (wup.length >> 16) & 0xff;
  out[2] = (wup.length >> 8) & 0xff;
  out[3] = wup.length & 0xff;
  out.setRange(4, out.length, wup);
  return out;
}

void main() {
  stdout.writeln('ConfigPush 离线自测');
  stdout.writeln('=' * 56);

  // ---------- 1. 请求解析 ----------
  stdout.writeln('\n1. PushReq 解析');
  final bigdata = Uint8List.fromList(<int>[0xde, 0xad, 0xbe, 0xef]);
  final req = decodePushReq(_pushReqPayload(type: 2, data: bigdata, seq: 987654321));
  checkEq('解析成功', req != null, true);
  checkEq('type = 2', req?.type, 2);
  checkEq('data 原样', toHex(req!.data), toHex(bigdata));
  checkEq('seq = 987654321（长整型不丢）', req.seq, 987654321);

  final reqNoPrefix = decodePushReq(
      _pushReqPayload(type: 1, data: null, seq: 7, withLenPrefix: false));
  checkEq('无 4 字节前缀也能解析', reqNoPrefix?.type, 1);
  checkEq('无前缀 seq = 7', reqNoPrefix?.seq, 7);

  // ---------- 2. 无法识别 -> null（调用方不回执）----------
  stdout.writeln('\n2. 无法识别');
  checkEq('垃圾字节 -> null',
      decodePushReq(Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6])) == null, true);

  // ---------- 3. 回执字段序 ----------
  stdout.writeln('\n3. PushResp 构造（tag 号与请求不同）');
  final respType1 = Qq8Jce.decodeWrapper(buildPushRespBody(type: 1, seq: 12345));
  checkEq('type1: tag1 = 1', respType1[1], 1);
  checkEq('type1: tag2 = seq 12345（不是 data）', respType1[2], 12345);
  checkEq('type1: 无 tag3', respType1.containsKey(3), false);

  final respType3 =
      Qq8Jce.decodeWrapper(buildPushRespBody(type: 3, seq: 999, data: bigdata));
  checkEq('type3: tag1 = 3', respType3[1], 3);
  checkEq('type3: tag2 = seq 999', respType3[2], 999);
  checkEq('type3: tag3 = 原 data', toHex(respType3[3] as List<int>), toHex(bigdata));

  final respType2 =
      Qq8Jce.decodeWrapper(buildPushRespBody(type: 2, seq: 777, data: bigdata));
  checkEq('type2: tag2 = seq 777（即使有 data 也不放 tag2）', respType2[2], 777);
  checkEq('type2: 非 type3 不回带 tag3', respType2.containsKey(3), false);

  // 请求 tag2 是 data，回执 tag2 是 seq —— 这正是旧实现写错的地方。
  checkEq('请求 tag2 是 data（与回执相反）',
      toHex(Qq8Jce.decodeWrapper(_pushReqPayload(type: 2, data: bigdata, seq: 5))[2]
          as List<int>),
      toHex(bigdata));

  stdout.writeln('\n${'=' * 56}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
