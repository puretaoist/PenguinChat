// `DeviceLoginGuard` 的自测：规则、窗口、持久化。
//
// 规则依据见该文件类注释（图灵盾 `b2.402` 的 30 条时间戳 + 真机 8 天
// 196 次登录的证据）。这里的断言把「该拦 / 该放」钉死，防止后人
// 调整阈值时把护栏改没了。
import 'dart:convert';
import 'dart:io';

import 'package:penguinchat/kernel/safety/device_login_guard.dart';

int _pass = 0;
int _fail = 0;

void ok(String name) {
  _pass++;
  stdout.writeln('  \u2713 $name');
}

void bad(String name, String detail) {
  _fail++;
  stdout.writeln('  \u2717 $name\n      \u2192 $detail');
}

void check(String name, bool cond, [String detail = '']) {
  if (cond) {
    ok(name);
  } else {
    bad(name, detail);
  }
}

void checkEq(String name, Object? actual, Object? expected) {
  if ('$actual' == '$expected') {
    ok(name);
  } else {
    bad(name, '期望 $expected，实际 $actual');
  }
}

void section(String t) => stdout.writeln('\n$t');

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('device_guard_');
  final t0 = DateTime(2026, 11, 8, 12, 0, 0);

  section('1. 空记录：放行');
  {
    final g = DeviceLoginGuard();
    check('空记录允许登录', g.check(uin: 10001, now: t0).allowed);
  }

  section('2. 换号间隔（不同账号，10 分钟内要等）');
  {
    final g = DeviceLoginGuard(seed: <DeviceLoginRecord>[
      DeviceLoginRecord(uin: 10001, atMs: t0.millisecondsSinceEpoch),
    ]);
    final d1 = g.check(uin: 20002, now: t0.add(const Duration(minutes: 1)));
    checkEq('1 分钟前登过别的号 → 判为等待', d1.verdict.name, 'wait');
    check('等待时长约 9 分钟', d1.waitFor != null &&
        d1.waitFor!.inMinutes == 9, '${d1.waitFor}');

    final d2 = g.check(uin: 20002, now: t0.add(const Duration(minutes: 15)));
    check('15 分钟后 → 放行', d2.allowed, d2.reason);
  }

  section('3. 同号重登不受「换号间隔」限制（那是另一层的 60s 节流）');
  {
    final g = DeviceLoginGuard(seed: <DeviceLoginRecord>[
      DeviceLoginRecord(uin: 10001, atMs: t0.millisecondsSinceEpoch),
    ]);
    final d = g.check(uin: 10001, now: t0.add(const Duration(minutes: 1)));
    check('同一账号 1 分钟后再登 → 本层放行', d.allowed, d.reason);
  }

  section('4. 24h 内不同账号数上限（默认 3）');
  {
    final g = DeviceLoginGuard(seed: <DeviceLoginRecord>[
      DeviceLoginRecord(uin: 10001, atMs: t0.millisecondsSinceEpoch),
      DeviceLoginRecord(
          uin: 20002, atMs: t0.add(const Duration(hours: 1)).millisecondsSinceEpoch),
      DeviceLoginRecord(
          uin: 30003, atMs: t0.add(const Duration(hours: 2)).millisecondsSinceEpoch),
    ]);
    final d = g.check(
      uin: 40004,
      now: t0.add(const Duration(hours: 3)),
    );
    checkEq('第 4 个不同账号 → 拒绝', d.verdict.name, 'block');
    check('拒绝原因点明设备维度', d.reason.contains('这台设备'), d.reason);

    // 已登过的号不受「新账号数」限制。
    final d2 = g.check(
      uin: 10001,
      now: t0.add(const Duration(hours: 3)),
    );
    check('已登过的号 → 不受账号数上限限制', d2.allowed, d2.reason);
  }

  section('5. 24h 内总登录次数上限（默认 20）');
  {
    final recs = <DeviceLoginRecord>[
      for (int i = 0; i < 20; i++)
        DeviceLoginRecord(
          uin: 10001,
          atMs: t0.add(Duration(minutes: i)).millisecondsSinceEpoch,
        ),
    ];
    final g = DeviceLoginGuard(seed: recs);
    final d = g.check(uin: 10001, now: t0.add(const Duration(minutes: 30)));
    checkEq('已登 20 次 → 拒绝', d.verdict.name, 'block');
    check('拒绝原因点明频率', d.reason.contains('频繁'), d.reason);
  }

  section('6. 窗口外的记录被剪掉（24h 前的历史不算）');
  {
    final g = DeviceLoginGuard(seed: <DeviceLoginRecord>[
      DeviceLoginRecord(
        uin: 10001,
        atMs: t0.subtract(const Duration(hours: 25)).millisecondsSinceEpoch,
      ),
      DeviceLoginRecord(
        uin: 20002,
        atMs: t0.subtract(const Duration(hours: 26)).millisecondsSinceEpoch,
      ),
    ]);
    final d = g.check(uin: 30003, now: t0);
    check('25h 前的记录不算进「不同账号数」→ 放行', d.allowed, d.reason);
    checkEq('check 后窗口内只剩 0 条', g.records.length, 0);
  }

  section('7. record 记账 + 落盘 + 读回');
  {
    final f = File('${dir.path}/guard.json');
    final g1 = DeviceLoginGuard(persistFile: f);
    await g1.record(uin: 10001, now: t0);
    await g1.record(uin: 20002, now: t0.add(const Duration(hours: 1)));
    check('落盘文件已写出', await f.exists());

    final raw = jsonDecode(await f.readAsString()) as Map;
    final list = raw['records'] as List;
    checkEq('文件里有 2 条记录', list.length, 2);

    final g2 = DeviceLoginGuard(persistFile: f);
    await g2.load();
    checkEq('读回 2 条记录', g2.records.length, 2);
    checkEq('读回的 uin 正确', g2.records.first.uin, 10001);
  }

  section('8. 坏文件：不抛、按空处理');
  {
    final f = File('${dir.path}/bad.json');
    await f.writeAsString('{ 这不是 json');
    final g = DeviceLoginGuard(persistFile: f);
    await g.load();
    checkEq('坏 JSON 后记录为空', g.records.length, 0);
    check('坏文件后仍能正常判定', g.check(uin: 1, now: t0).allowed);
  }

  section('9. 阈值可配置（不是写死的）');
  {
    final g = DeviceLoginGuard(maxDistinctUinsPerDay: 1);
    await g.record(uin: 10001, now: t0);
    final d = g.check(uin: 20002, now: t0.add(const Duration(minutes: 20)));
    checkEq('上限设为 1 时，第 2 个号即被拒', d.verdict.name, 'block');
  }

  try {
    await dir.delete(recursive: true);
  } on FileSystemException {
    // Windows 句柄未放开；不影响判据。
  }
  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
