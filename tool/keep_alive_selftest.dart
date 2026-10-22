// 后台保活的判据与去重逻辑自测。
//
// 跑法：dart run tool/keep_alive_selftest.dart
//
// 这个文件只测 L1（`lib/infra/lifecycle/keep_alive.dart`）——纯 Dart，
// 不需要 Flutter、不需要设备。真正的平台侧（`MethodChannel` + 前台服务）
// 无法在单测里验证，只能真机跑；但「什么时候该挂、什么时候不该挂」
// 这条判据是纯逻辑，而它恰恰是最容易写错的部分（漏掉一个状态组合，
// 表现就是「切后台一会儿消息就不来了」这种极难复现的问题）。
import 'dart:io';

import 'package:qqclient/infra/lifecycle/keep_alive.dart';

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

/// 记录调用的假实现。
///
/// 用「调用序列」而不是「最终状态」断言，是因为重复调用本身就是缺陷：
/// 生命周期回调在真机上很密集，每次都跨平台通道往返一次会让日志没法读，
/// 也会在某些 ROM 上把 startForeground 调成高频操作（有被限流的风险）。
class FakeKeepAlive implements KeepAlive {
  FakeKeepAlive({this.failOnStart = false, this.failOnStop = false});

  final bool failOnStart;
  final bool failOnStop;

  /// 调用记录：`'start'` / `'stop'` / `'permission'`。
  final List<String> calls = <String>[];

  bool running = false;

  @override
  Future<void> start() async {
    calls.add('start');
    if (failOnStart) throw StateError('ForegroundServiceStartNotAllowedException');
    running = true;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (failOnStop) throw StateError('service already dead');
    running = false;
  }

  @override
  Future<bool> isRunning() async => running;

  @override
  Future<bool> ensurePermission() async {
    calls.add('permission');
    return true;
  }
}

Future<void> main() async {
  stdout.writeln('=== 后台保活自测 ===');

  await testPolicy();
  await testControllerTransitions();
  await testDedup();
  await testFailureTolerance();
  await testShutdown();
  await testNoop();

  stdout.writeln('\n=== 结果: $passed 通过, $failed 失败 ===');
  if (failed > 0) exit(1);
}

Future<void> testPolicy() async {
  stdout.writeln('\n-- 判据（KeepAlivePolicy）--');
  const policy = KeepAlivePolicy();

  // 三种组合穷举。核心是第三条：前台时不挂。
  check(
    '后台 + 已连接 → 挂',
    policy.shouldRun(appInBackground: true, sessionActive: true),
  );
  check(
    '前台 + 已连接 → 不挂（进程活着，挂服务只是多一条通知打扰用户）',
    !policy.shouldRun(appInBackground: false, sessionActive: true),
  );
  check(
    '后台 + 未连接 → 不挂（没连接可保，挂了只是白占通知栏）',
    !policy.shouldRun(appInBackground: true, sessionActive: false),
  );
  check(
    '前台 + 未连接 → 不挂',
    !policy.shouldRun(appInBackground: false, sessionActive: false),
  );
}

Future<void> testControllerTransitions() async {
  stdout.writeln('\n-- 状态迁移 --');
  final fake = FakeKeepAlive();
  final logs = <String>[];
  final controller = KeepAliveController(
    fake,
    log: (m, {error}) => logs.add(m),
  );

  // 初始：前台无连接。
  await controller.update(appInBackground: false, sessionActive: false);
  check('初始不挂', fake.calls.isEmpty && !controller.running);

  // 连上了但还在前台：不挂。
  await controller.update(appInBackground: false, sessionActive: true);
  check('前台连上也不挂', fake.calls.isEmpty, '调用序列=${fake.calls}');

  // 切后台：挂。
  final changed = await controller.update(appInBackground: true, sessionActive: true);
  check('切后台后挂起', changed && fake.running && controller.running);
  check(
    '挂起前先申请通知权限（Android 13+ 没有它通知不显示）',
    fake.calls.join(',') == 'permission,start',
    '实际=${fake.calls}',
  );

  // 回前台：撤。
  await controller.update(appInBackground: false, sessionActive: true);
  check('回前台后撤销', !fake.running && !controller.running);
  check('撤销不需要权限申请', fake.calls.join(',') == 'permission,start,stop');

  // 后台断线：撤（没连接可保）。
  await controller.update(appInBackground: true, sessionActive: true);
  await controller.update(appInBackground: true, sessionActive: false);
  check('后台断线后撤销', !fake.running, '调用序列=${fake.calls}');

  check('日志记录了开与关', logs.any((m) => m.contains('开启')) && logs.any((m) => m.contains('关闭')));
}

Future<void> testDedup() async {
  stdout.writeln('\n-- 去重（没变化不重复调平台侧）--');
  final fake = FakeKeepAlive();
  final controller = KeepAliveController(fake);

  // 连续五次同状态。
  for (var i = 0; i < 5; i++) {
    await controller.update(appInBackground: true, sessionActive: true);
  }
  check(
    '同状态连调 5 次只下发 1 次',
    fake.calls.where((c) => c == 'start').length == 1,
    '调用序列=${fake.calls}',
  );

  // 返回值也应为 false（表示"这次没做事"）。
  final again = await controller.update(appInBackground: true, sessionActive: true);
  check('重复调用返回 false', !again);

  // 真变化时才返回 true。
  final changed = await controller.update(appInBackground: false, sessionActive: true);
  check('状态变化时返回 true', changed);
}

Future<void> testFailureTolerance() async {
  stdout.writeln('\n-- 失败容错（保活失败不能让应用崩）--');
  final fake = FakeKeepAlive(failOnStart: true);
  final logs = <String>[];
  final controller = KeepAliveController(fake, log: (m, {error}) => logs.add(m));

  // 不应抛异常。
  var threw = false;
  try {
    await controller.update(appInBackground: true, sessionActive: true);
  } catch (_) {
    threw = true;
  }
  check('start 抛异常时 update 不向外抛', !threw);
  check('失败记了日志', logs.any((m) => m.contains('失败')), '日志=$logs');
  // 目标值仍然记为 true：否则生命周期回调会反复重试同一次失败迁移，
  // 把日志刷满（见 update() 里的注释）。
  check('失败后目标状态仍记为 true（避免反复重试）', controller.running);
  check(
    '失败后再次同状态调用不会重试',
    !await controller.update(appInBackground: true, sessionActive: true),
  );

  // stop 失败同理。
  final fake2 = FakeKeepAlive(failOnStop: true);
  final controller2 = KeepAliveController(fake2);
  await controller2.update(appInBackground: true, sessionActive: true);
  threw = false;
  try {
    await controller2.update(appInBackground: false, sessionActive: true);
  } catch (_) {
    threw = true;
  }
  check('stop 抛异常时 update 不向外抛', !threw);
}

Future<void> testShutdown() async {
  stdout.writeln('\n-- 退出收尾 --');
  final fake = FakeKeepAlive();
  final controller = KeepAliveController(fake);
  await controller.update(appInBackground: true, sessionActive: true);
  await controller.shutdown();
  check('退出时关掉服务', !fake.running && !controller.running);

  // 没在跑时 shutdown 应该是空操作（退出路径会被调用多次）。
  final before = fake.calls.length;
  await controller.shutdown();
  check('未运行时 shutdown 是空操作', fake.calls.length == before);

  // shutdown 之后若状态又变，应能重新挂上（例如热重载后重新连接）。
  await controller.update(appInBackground: true, sessionActive: true);
  check('shutdown 后仍可重新挂起', fake.running);
}

Future<void> testNoop() async {
  stdout.writeln('\n-- Noop 实现（桌面/测试环境）--');
  const noop = NoopKeepAlive();
  await noop.start();
  await noop.stop();
  check('Noop.start/stop 不抛', true);
  check('Noop.isRunning 恒 false', !await noop.isRunning());
  check('Noop.ensurePermission 恒 true', await noop.ensurePermission());

  // Noop 配上控制器也不该出问题（这是桌面端实际跑的那条路径）。
  final controller = KeepAliveController(noop);
  await controller.update(appInBackground: true, sessionActive: true);
  check('Noop + 控制器：状态记录为 true', controller.running);
}
