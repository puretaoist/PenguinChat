// 官方 ProtocolDet（`0x525` 内嵌 `0x536`）等价实现的自测。
//
// 全部向量来自真机实测，且**由脚本生成**（`apk-analysis/gen_pd2_vector.py`），
// 绝不手抄——手抄过一次，把 `39.170.111.4` 读成了 `4.39.170.111`，脚本立刻纠正。
//
// 素材：
//   * `kRealPd2` = 真机 `analysis/_ref/official-logs/qq8211/pd2.dat` 63 字节原件
//   * `kOfficial536Body` = 官方日志 `qq8211/wtlogin_20260930.txt:375` 的 65 字节上线 body
//     （对应 `subCmd=0x9 type:0 ret:0` 密码登录成功那次）
//
// 跑法：dart run tool/qq8_protocol_det_selftest.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_profiles.dart';
import 'package:qqclient/kernel/wlogin8/qq8_protocol_det.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tlv.dart';

int passed = 0;
int failed = 0;

void ok(String name, [String? note]) {
  passed++;
  stdout.writeln('  ok  $name${note == null ? '' : '  ($note)'}');
}

void bad(String name, String why) {
  failed++;
  stdout.writeln('FAIL  $name\n      $why');
}

void check(String name, bool cond, [String note = '']) {
  if (cond) {
    ok(name, note.isEmpty ? null : note);
  } else {
    bad(name, note.isEmpty ? '条件为假' : note);
  }
}

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// 真机 `pd2.dat` 的 63 字节原件（3 条 × 21B，裸条目无 2 字节头）。
///
/// 出处：`analysis/_ref/official-logs/qq8211/pd2.dat`，经
/// `adb exec-out "su -c 'cat <path>'"` 原样拉取
/// （**不能走 `adb shell`**，pty 会把 `\n` 改成 `\r\n` 破坏二进制）。
/// 由 `apk-analysis/gen_pd2_vector.py` 生成，勿手改。
const List<int> kRealPd2 = <int>[
  // #0 uin=2089495846 mlen=4 ip=101.70.146.3 time=1791273382 ver=537064117
  0x00, 0x00, 0x00, 0x00, 0x7c, 0x8b, 0x2d, 0x26,
  0x04, 0x65, 0x46, 0x92, 0x03, 0x6a, 0xc4, 0xa9,
  0xa6, 0x20, 0x02, 0xf2, 0xb5,
  // #1 uin=3499239040 mlen=4 ip=101.70.146.3 time=1791273379 ver=537064117
  0x00, 0x00, 0x00, 0x00, 0xd0, 0x92, 0x26, 0x80,
  0x04, 0x65, 0x46, 0x92, 0x03, 0x6a, 0xc4, 0xa9,
  0xa3, 0x20, 0x02, 0xf2, 0xb5,
  // #2 uin=2089495846 mlen=4 ip=101.70.146.3 time=1791274229 ver=537064117
  0x00, 0x00, 0x00, 0x00, 0x7c, 0x8b, 0x2d, 0x26,
  0x04, 0x65, 0x46, 0x92, 0x03, 0x6a, 0xc4, 0xac,
  0xf5, 0x20, 0x02, 0xf2, 0xb5,
];

/// 官方日志 `qq8211/wtlogin_20260930.txt:375` 打印的上线 body（65 字节）。
///
/// 这条日志对应 **`subCmd=0x9 type:0 ret:0` 密码登录成功** 那次，
/// 是 8.2.11 代际唯一可查的密码成功样本。条目数 = 3。
/// 由 `apk-analysis/gen_pd2_vector.py` 从日志 hex 解出，勿手改。
const List<int> kOfficial536Body = <int>[
  // 头: 协议版本 1, 条目数 3
  0x01, 0x03,
  // #0 uin=3499239040 mlen=4 ip=39.170.111.4 time=1790080415 ver=537064117
  0x00, 0x00, 0x00, 0x00, 0xd0, 0x92, 0x26, 0x80,
  0x04, 0x27, 0xaa, 0x6f, 0x04, 0x6a, 0xb2, 0x75,
  0x9f, 0x20, 0x02, 0xf2, 0xb5,
  // #1 uin=3499239040 mlen=4 ip=39.170.111.3 time=1789969335 ver=537064117
  0x00, 0x00, 0x00, 0x00, 0xd0, 0x92, 0x26, 0x80,
  0x04, 0x27, 0xaa, 0x6f, 0x03, 0x6a, 0xb0, 0xc3,
  0xb7, 0x20, 0x02, 0xf2, 0xb5,
  // #2 uin=3499239040 mlen=4 ip=39.170.111.8 time=1789976631 ver=537064117
  0x00, 0x00, 0x00, 0x00, 0xd0, 0x92, 0x26, 0x80,
  0x04, 0x27, 0xaa, 0x6f, 0x08, 0x6a, 0xb0, 0xe0,
  0x37, 0x20, 0x02, 0xf2, 0xb5,
];

void main() {
  stdout.writeln('=== ProtocolDet / 0x536 自测 ===');

  testEmpty();
  testDecodeDisk();
  testDecodeOfficialBody();
  testEncodeRoundTrip();
  testGuard();
  testBadInput();
  testTlv525();
  testMerge();
  testT537();

  stdout.writeln('\n$passed 通过, $failed 失败');
  exit(failed == 0 ? 0 : 1);
}

void testEmpty() {
  stdout.writeln('\n-- 空列表 = 01 00（官方 packExtraData(null)）');
  final b = Qq8ProtocolDet.encode(const <Qq8ProtocolDetEntry>[]);
  check('空列表 body 长度 2', b.length == 2, '实际 ${b.length}');
  check('空列表 body = 0100', hex(b) == '0100', hex(b));
  check('emptyBody getter 同值', hex(Qq8ProtocolDet.emptyBody) == '0100');
}

void testDecodeDisk() {
  stdout.writeln('\n-- 解真机 pd2.dat（63 字节 / 3 条）');
  final raw = Uint8List.fromList(kRealPd2);
  check('原件长度 63', raw.length == 63, '实际 ${raw.length}');

  final list = Qq8ProtocolDet.decodeFile(raw);
  check('解出 3 条', list.length == 3, '实际 ${list.length}');
  if (list.length != 3) return;

  check('#0 uin=2089495846', list[0].uin == 2089495846, '${list[0].uin}');
  check('#1 uin=3499239040', list[1].uin == 3499239040, '${list[1].uin}');
  check('#2 uin=2089495846', list[2].uin == 2089495846, '${list[2].uin}');

  check('#0 ip=101.70.146.3', list[0].ipText == '101.70.146.3', list[0].ipText);
  check('#1/#2 同段 IP',
      list[1].ipText == '101.70.146.3' && list[2].ipText == '101.70.146.3', '');

  check('#0 time=1791273382', list[0].time == 1791273382, '${list[0].time}');
  check('#1 time=1791273379', list[1].time == 1791273379, '${list[1].time}');
  check('#2 time=1791274229', list[2].time == 1791274229, '${list[2].time}');

  check('ver 恒 = subAppId 537064117',
      list.every((e) => e.version == 537064117), '');
  check('ip 长度都是 4', list.every((e) => e.ip.length == 4), '');
  check('encodedSize 都是 21', list.every((e) => e.encodedSize == 21), '');
}

void testDecodeOfficialBody() {
  stdout.writeln('\n-- 解官方日志 :375 的 65 字节上线 body');
  final body = Uint8List.fromList(kOfficial536Body);
  check('body 长度 65', body.length == 65, '${body.length}');
  check('头 = 01 03', hex(body.sublist(0, 2)) == '0103',
      hex(body.sublist(0, 2)));

  // 上线 body = 2 字节头 + 裸条目；解码时要去掉头
  final list = Qq8ProtocolDet.decodeFile(
    Uint8List.fromList(body.sublist(2)),
  );
  check('解出 3 条', list.length == 3, '${list.length}');
  if (list.length != 3) return;

  check('三条都是 uin=3499239040',
      list.every((e) => e.uin == 3499239040), '${list.map((e) => e.uin)}');
  check('#0 ip=39.170.111.4', list[0].ipText == '39.170.111.4', list[0].ipText);
  check('#1 ip=39.170.111.3', list[1].ipText == '39.170.111.3', list[1].ipText);
  check('#2 ip=39.170.111.8', list[2].ipText == '39.170.111.8', list[2].ipText);
  check('#0 time=1790080415', list[0].time == 1790080415, '${list[0].time}');

  // 关键否定断言：磁盘样本与日志样本**不是同一次采集**（IP 段不同）
  final disk = Qq8ProtocolDet.decodeFile(Uint8List.fromList(kRealPd2));
  check('磁盘样本 IP 与日志样本不同（两次采集）',
      disk[0].ipText != list[0].ipText,
      '${disk[0].ipText} vs ${list[0].ipText}');
}

void testEncodeRoundTrip() {
  stdout.writeln('\n-- 编码环回（解 → 编 → 再解）');
  for (final pair in <List<Object>>[
    <Object>['磁盘样本', kRealPd2],
    <Object>['日志样本裸条目', kOfficial536Body.sublist(2)],
  ]) {
    final name = pair[0] as String;
    final raw = Uint8List.fromList(pair[1] as List<int>);
    final a = Qq8ProtocolDet.decodeFile(raw);
    final encoded = Qq8ProtocolDet.encode(a);
    check('$name: 编码后 65 字节', encoded.length == 65, '${encoded.length}');
    final b = Qq8ProtocolDet.decodeFile(
      Uint8List.fromList(encoded.sublist(2)),
    );
    check('$name: 环回条数一致', a.length == b.length, '${a.length} vs ${b.length}');
    check('$name: 环回字段全等', a.length == b.length && _sameList(a, b), '');
  }
}

bool _sameList(List<Qq8ProtocolDetEntry> a, List<Qq8ProtocolDetEntry> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void testGuard() {
  stdout.writeln('\n-- 上限与单条解析');
  final many = List<Qq8ProtocolDetEntry>.generate(
    5,
    (i) => Qq8ProtocolDetEntry(
      uin: 2000000000 + i,
      ip: Uint8List.fromList(const [1, 2, 3, 4]),
      time: 1700000000 + i,
      version: 537064117,
    ),
  );
  final b5 = Qq8ProtocolDet.encode(many);
  check('5 条只编 3 条 → 65 字节', b5.length == 65, '${b5.length}');
  check('条目数字节 = 3', b5[1] == 3, '${b5[1]}');

  final single = Qq8ProtocolDet.decodeSingle(
    Uint8List.fromList(kRealPd2.sublist(0, 21)),
  );
  check('decodeSingle 21B 成功', single != null && single.uin == 2089495846,
      '${single?.uin}');
  check(
      'decodeSingle 20B 拒绝',
      Qq8ProtocolDet.decodeSingle(
            Uint8List.fromList(kRealPd2.sublist(0, 20)),
          ) ==
          null);
}

void testBadInput() {
  stdout.writeln('\n-- 坏输入不崩');
  check('空文件 → 空列表', Qq8ProtocolDet.decodeFile(Uint8List(0)).isEmpty);
  check('超 4096 → 空列表', Qq8ProtocolDet.decodeFile(Uint8List(5000)).isEmpty);

  final badMlen = Uint8List.fromList(kRealPd2);
  badMlen[8] = 5;
  check('mlen=5 → 停止解析', Qq8ProtocolDet.decodeFile(badMlen).isEmpty);

  final trunc = Uint8List.fromList(kRealPd2.sublist(0, 31));
  final tl = Qq8ProtocolDet.decodeFile(trunc);
  check('截断 → 只解出 1 条', tl.length == 1, '${tl.length}');

  final badEnc = Qq8ProtocolDet.encode(<Qq8ProtocolDetEntry>[
    Qq8ProtocolDetEntry(
      uin: 1,
      ip: Uint8List.fromList(const [1, 2, 3, 4]),
      time: 1,
      version: 1,
    ),
    Qq8ProtocolDetEntry(
      uin: 2,
      ip: Uint8List.fromList(const [1, 2, 3]),
      time: 2,
      version: 2,
    ),
  ]);
  check('坏条目 break → 只编 1 条 (2+21=23)', badEnc.length == 23,
      '${badEnc.length}');
  check('坏条目后条目数 = 1', badEnc[1] == 1, '${badEnc[1]}');
}

void testTlv525() {
  stdout.writeln('\n-- 0x525 组包（含 0x536 内嵌）');
  final apk = qq8ProfileQQ8211.apk;
  final dev = Qq8Device.fromIdentity(
    Qq8DeviceIdentity.fromJson(<String, Object?>{
      'uin': 2089495846,
      'android_id': '25cf6881290b58f7',
      'mac': '02:00:00:00:00:00',
    })!,
  );

  Qq8TlvContext mk(Uint8List? det) => Qq8TlvContext(
        uin: 2089495846,
        apk: apk,
        device: dev,
        passwordMd5: Uint8List(16),
        ksid: Uint8List(16),
        t104: Uint8List(0),
        t174: Uint8List(0),
        tgt: Uint8List(16),
        srmToken: Uint8List(0),
        protocolDet: det,
      );

  final empty = Qq8Tlv.body(mk(null), 0x525);
  check('未设 protocolDet → 8 字节', empty.length == 8, '${empty.length}');
  check('未设 → 外层 0001 + 0536 + 0002 + 0100',
      hex(empty) == '0001053600020100', hex(empty));

  final real = Qq8Tlv.body(
    mk(Qq8ProtocolDet.encode(
      Qq8ProtocolDet.decodeFile(Uint8List.fromList(kRealPd2)),
    )),
    0x525,
  );
  check('设 3 条 → 8+63 = 71 字节', real.length == 71, '${real.length}');
  check('外层 tlv 计数 = 1', real[0] == 0 && real[1] == 1, '');
  check('内层 tag = 0x536', real[2] == 0x05 && real[3] == 0x36, '');
  check('内层长度字段 = 65', real[4] == 0 && real[5] == 65, '${real[5]}');
  check('内层 body 前 2 字节 0103', hex(real.sublist(6, 8)) == '0103',
      hex(real.sublist(6, 8)));

  final emptyList = Qq8Tlv.body(mk(Qq8ProtocolDet.encode(const [])), 0x525);
  check('空列表与 null 等价', hex(emptyList) == hex(empty), hex(emptyList));
}

void testMerge() {
  stdout.writeln('\n-- merge 并入（官方 updateCachedExtraDataFile）');
  final base = Qq8ProtocolDet.decodeFile(Uint8List.fromList(kRealPd2));
  check('基线 3 条', base.length == 3, '${base.length}');

  // 不满 3 条 → 直接 append
  final two = base.sublist(0, 2);
  final inc = Qq8ProtocolDetEntry(
    uin: 1000000001,
    ip: Uint8List.fromList(const [8, 8, 8, 8]),
    time: 1800000000,
    version: 537064117,
  );
  final m2 = Qq8ProtocolDet.merge(two, inc);
  check('2 条 + 1 = 3 条', m2.length == 3, '${m2.length}');
  check('append 在末尾', m2[2] == inc, '${m2[2]}');

  // 已满 3 条 → 替换 mTime 最小的那条（官方不是 FIFO 轮转）
  // base 的 time: 1791273382 / 1791273379 / 1791274229
  // 最小 = 下标 1（1791273379）
  final m3 = Qq8ProtocolDet.merge(base, inc);
  check('满 3 条仍是 3 条', m3.length == 3, '${m3.length}');
  check('替换的是 mTime 最小的下标 1', m3[1] == inc, '${m3[1]}');
  check('下标 0 原样保留', m3[0] == base[0], '');
  check('下标 2 原样保留', m3[2] == base[2], '');
  check('最小 time 确实在下标 1',
      base[0].time > base[1].time && base[2].time > base[1].time,
      '${base.map((e) => e.time).toList()}');

  // 空列表 + 1 条
  final m0 = Qq8ProtocolDet.merge(const <Qq8ProtocolDetEntry>[], inc);
  check('空 + 1 = 1 条', m0.length == 1, '${m0.length}');
}

void testT537() {
  stdout.writeln('\n-- 响应 TLV 0x537（官方 oicq_request.java:1632）');
  // 官方日志 :386 `0x537 resp:872:23 setRes:0 tuple:21`
  // body 总长 23 = 2 字节前缀 + 21 字节裸条目，tuple 是去掉前缀后的 21 字节。
  final raw = Uint8List.fromList(<int>[
    0x00, 0x00, // 2 字节前缀（官方 arraycopy(bArr8, 2, ...) 丢掉的部分）
    ...kRealPd2.sublist(0, 21),
  ]);
  check('TLV body 23 字节', raw.length == 23, '${raw.length}');

  // 模拟 Qq8LoginResponse.t537 的切法
  final stripped = Uint8List.sublistView(raw, 2);
  check('去前缀后 21 字节', stripped.length == 21, '${stripped.length}');

  final entry = Qq8ProtocolDet.decodeSingle(stripped);
  check('解出条目', entry != null, '');
  check('uin=2089495846', entry?.uin == 2089495846, '${entry?.uin}');
  check('ip=101.70.146.3', entry?.ipText == '101.70.146.3', '${entry?.ipText}');

  // 长度不符（20 字节）必须拒绝
  check('20 字节拒收',
      Qq8ProtocolDet.decodeSingle(Uint8List.sublistView(raw, 2, 22)) == null);

  // merge 到真机磁盘样本，模拟"服务端告诉我们新出口"
  final disk = Qq8ProtocolDet.decodeFile(Uint8List.fromList(kRealPd2));
  final merged = Qq8ProtocolDet.merge(disk, entry!);
  check('并入后 3 条', merged.length == 3, '${merged.length}');
  final fileBytes = Qq8ProtocolDet.encodeFile(merged);
  check('落盘 63 字节（裸条目无头）', fileBytes.length == 63,
      '${fileBytes.length}');
  final reread = Qq8ProtocolDet.decodeFile(fileBytes);
  check('重读 3 条', reread.length == 3, '${reread.length}');
  check('重读含新条目', reread.any((e) => e.uin == 2089495846 && e.time == 1791273382),
      '');
}
