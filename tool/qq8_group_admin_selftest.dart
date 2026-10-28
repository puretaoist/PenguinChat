/// 群设置 / 成员管理离线自测
///
/// 全部是**纯字节**断言：请求体与应答样本都和独立第二实现
/// `../analysis/scripts/gen_group_admin_vectors.py` 逐字节比对（那个脚本手写
/// varint / 大端打包，既不引用本项目 Dart 代码，也不引用 oicq）。
///
/// 运行：
/// ```bash
/// dart run tool/qq8_group_admin_selftest.dart
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/wlogin8/qq8_group_admin.dart';

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

// 与 gen_group_admin_vectors.py 完全相同的输入常量
const int gid = 763829581;
const int uid = 3499239040;
const String name = '新群名';
const String announce = '明天不上课';
const int seconds = 600;

void main() {
  section('1) 群设置（OidbSvc.0x89a_0）：body 逐字节 = Python');
  check(
    '只改群名',
    _hexOf(Qq8GroupAdmin.buildSettingBody(gid: gid, name: name)) ==
        '08cdba9cec02120b1a09e696b0e7bea4e5908d',
  );
  check(
    '只改公告',
    _hexOf(Qq8GroupAdmin.buildSettingBody(gid: gid, announce: announce)) ==
        '08cdba9cec021211220fe6988ee5a4a9e4b88de4b88ae8afbe',
  );
  check(
    '全员禁言开（0xffffffff）',
    _hexOf(Qq8GroupAdmin.buildSettingBody(gid: gid, wholeMute: true)) ==
        '08cdba9cec0212078801ffffffff0f',
  );
  check(
    '全员禁言关（0）',
    _hexOf(Qq8GroupAdmin.buildSettingBody(gid: gid, wholeMute: false)) ==
        '08cdba9cec021203880100',
  );
  check(
    '三项一起改（字段序 3/4/17）',
    _hexOf(Qq8GroupAdmin.buildSettingBody(
          gid: gid,
          name: name,
          announce: announce,
          wholeMute: false,
        )) ==
        '08cdba9cec02121f1a09e696b0e7bea4e5908d220fe6988ee5a4a9e4b88de4b88ae8afbe880100',
  );
  var threw = false;
  try {
    Qq8GroupAdmin.buildSettingBody(gid: gid);
  } on Qq8GroupAdminException {
    threw = true;
  }
  check('一项都不改 → 本地直接抛（不瞎发）', threw);

  section('2) 踢人（OidbSvc.0x8a0_0）');
  check(
    'body：{1: 群号, 2: {1: 5, 2: uin, 3: 拒加群}}',
    _hexOf(Qq8GroupAdmin.buildKickBody(gid: gid, uid: uid, rejectAddRequest: true)) ==
        '08cdba9cec02120a08051080cdc8840d1801',
  );
  check(
    'block=false 时字段 3 = 0',
    _hexOf(Qq8GroupAdmin.buildKickBody(gid: gid, uid: uid)) ==
        '08cdba9cec02120a08051080cdc8840d1800',
  );
  final kickOk = Qq8GroupAdmin.parseKick(_hex('220412020800'));
  check('应答 [4][2][1]=0 → ok', kickOk.ok && kickOk.code == 0);
  final kickErr = Qq8GroupAdmin.parseKick(_hex('22041202080c'));
  check('应答 [4][2][1]=12 → 不 ok，码原样带出',
      !kickErr.ok && kickErr.code == 12);
  final kickBad = Qq8GroupAdmin.parseKick(_hex('0801'));
  check('应答缺 [4][2] → 不假成功', !kickBad.ok && kickBad.code == null);

  section('3) 单人禁言（OidbSvc.0x570_8，15 字节二进制）');
  check(
    'body = u32 群号 ‖ 0x20 ‖ u16 1 ‖ u32 uin ‖ u32 秒',
    _hexOf(Qq8GroupAdmin.buildMuteMemberBody(gid: gid, uid: uid, seconds: seconds)) ==
        '2d871d4d200001d092268000000258',
  );
  check(
    '秒数 0 = 解除禁言',
    _hexOf(Qq8GroupAdmin.buildMuteMemberBody(gid: gid, uid: uid, seconds: 0)) ==
        '2d871d4d200001d092268000000000',
  );
  check(
    '秒数超上限夹到 30 天（不把 4 字节写溢出）',
    _hexOf(Qq8GroupAdmin.buildMuteMemberBody(
          gid: gid,
          uid: uid,
          seconds: Qq8GroupAdmin.maxMuteSeconds + 999,
        )) ==
        '2d871d4d200001d092268000278d00',
  );
  check(
    '负数按 0 处理',
    _hexOf(Qq8GroupAdmin.buildMuteMemberBody(gid: gid, uid: uid, seconds: -5)) ==
        '2d871d4d200001d092268000000000',
  );
  final muteOk = Qq8GroupAdmin.parseMuteMember(_hex('1800'));
  check('应答 3=0 → ok', muteOk.ok && muteOk.code == 0);
  final muteNone = Qq8GroupAdmin.parseMuteMember(_hex(''));
  check('应答空 → 不假成功（没有确认）', !muteNone.ok && muteNone.code == null);

  section('4) 设/取消管理员（OidbSvc.0x55c_1，9 字节二进制）');
  check(
    'body = u32 群号 ‖ u32 uin ‖ u8 1',
    _hexOf(Qq8GroupAdmin.buildSetAdminBody(gid: gid, uid: uid)) ==
        '2d871d4dd092268001',
  );
  check(
    '取消管理员 u8 = 0',
    _hexOf(Qq8GroupAdmin.buildSetAdminBody(gid: gid, uid: uid, enable: false)) ==
        '2d871d4dd092268000',
  );
  final adminOk = Qq8GroupAdmin.parseSetAdmin(_hex('1800'));
  check('应答 3=0 → ok', adminOk.ok && adminOk.code == 0);
  final adminErr = Qq8GroupAdmin.parseSetAdmin(_hex('1805'));
  check('应答 3=5 → 不 ok，码 5', !adminErr.ok && adminErr.code == 5);

  section('5) 群设置应答');
  final setOk = Qq8GroupAdmin.parseSetting(_hex('1800'));
  check('应答 3=0 → ok', setOk.ok && setOk.code == 0);
  final setErr = Qq8GroupAdmin.parseSetting(_hex('1805'));
  check('应答 3=5 → 不 ok，码 5', !setErr.ok && setErr.code == 5);
  final setBad = Qq8GroupAdmin.parseSetting(_hex('0a0161'));
  check('应答没结果码 → 不假成功', !setBad.ok && setBad.code == null);

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
