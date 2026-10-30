/// `AttachCoordinator` 自测（纯 Dart，离线，无网络/无 Flutter）。
///
/// 验的是**资源所有权**，不是世代整数：
/// 每个用例都数「某个资源被释放了几次」，因为线上真正的 bug 是
/// 旧 ChatStore 没释放（两个 store 抢同一个索引文件）或释放了两次
/// （第二次会抛/写坏盘）。
///
/// 用可控 `Completer` 模拟 `bootstrap()` 的 await，不靠 sleep。
///
/// 跑法：`dart run tool/attach_coordinator_selftest.dart`
library;

// 自测脚本的标准写法（与 tool/qq8_device_store_selftest.dart 一致）：
// 打印是对人的输出，不是生产代码。
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import '../lib/client_api/attach_coordinator.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String note = '']) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    print('  ✗ $name${note.isEmpty ? '' : ' — $note'}');
  }
}

/// 一次 attach 建出来的那一对资源（真实接线里是 adapter + store）。
class FakePair {
  FakePair(this.name);

  final String name;
  int storeDisposed = 0;
  int adapterDisposed = 0;
  bool _released = false;

  /// 模拟 `ChatStore.dispose()` + `Qq8SessionAdapter.dispose()`。
  ///
  /// 两者都可能抛，所以释放必须 try/finally 成对；幂等闸防止重复释放
  /// （真实实现里第二次 dispose 会写已关闭的流）。
  Future<void> release(List<String> log) async {
    if (_released) return;
    _released = true;
    log.add('release-start:$name');
    try {
      storeDisposed++;
    } finally {
      adapterDisposed++;
    }
    await Future<void>.delayed(Duration.zero); // 模拟 flush 索引
    log.add('release-end:$name');
  }
}

AttachCoordinator<FakePair> newCoord() => AttachCoordinator<FakePair>();

/// 控制器里一次 attach 的等价结构：建资源 → await bootstrap → 发布/释放。
///
/// 与 `Qq8ConnectController._attachInner` 同一套顺序（try/on/finally），
/// 所以这里断言对真实实现有意义。
Future<FakePair?> runAttach(
  AttachCoordinator<FakePair> c,
  AttachPlan plan, {
  required Future<void> bootstrap,
  required List<String> log,
  bool failBootstrap = false,
}) async {
  FakePair? pair;
  try {
    await bootstrap;
    if (failBootstrap) throw StateError('bootstrap failed');
    pair = FakePair('${plan.uin}#${plan.epoch}');
    if (!c.complete(plan, pair)) {
      final stale = pair;
      pair = null;
      await stale.release(log); // 过时：调用方必须释放
      return null;
    }
    return pair;
  } on Object {
    pair = null;
    c.fail(plan);
    return null;
  }
}

Future<void> main() async {
  print('AttachCoordinator');

  // ------------------------------------------------------------------
  // 1. 基线：一次上线只建一轮，重复在线快照去重
  // ------------------------------------------------------------------
  {
    final c = newCoord();
    final u1 = c.update(uin: 10001, epoch: 1);
    check('首次在线给出计划', u1.plan != null);
    check('首次在线无待释放资源', u1.retired == null);

    final again = c.update(uin: 10001, epoch: 1);
    check('重复同一在线快照不再给计划', again.plan == null);
    check('重复同一在线快照不会误释放', again.retired == null);

    final r = FakePair('A');
    check('有效世代可以发布', c.complete(u1.plan!, r));
    check('发布后世代不变', c.generation == u1.plan!.gen);

    final dupAfterPublish = c.update(uin: 10001, epoch: 1);
    check('发布后重复快照仍去重', dupAfterPublish.plan == null);
    check('发布后重复快照不释放', dupAfterPublish.retired == null);
    check('已发布目标正确', c.publishedTarget == (uin: 10001, epoch: 1));
    check('仍在用的资源未被释放',
        r.storeDisposed == 0 && r.adapterDisposed == 0);
  }

  // ------------------------------------------------------------------
  // 2. pending 期间切号：旧轮次作废、新号能启动、旧资源真释放一次
  // ------------------------------------------------------------------
  {
    final c = newCoord();
    final log = <String>[];
    final bootA = Completer<void>();
    final bootB = Completer<void>();

    final planA = c.update(uin: 10001, epoch: 1).plan!;
    final futA = runAttach(c, planA, bootstrap: bootA.future, log: log);

    final b = c.update(uin: 10002, epoch: 2);
    check('pending 期间切 B 立刻给出 B 的计划', b.plan != null);
    check('切 B 时 A 未发布，无资源可交还', b.retired == null);
    check('B 的世代晚于 A', b.plan!.gen > planA.gen);
    final planB = b.plan!;
    final futB = runAttach(c, planB, bootstrap: bootB.future, log: log);

    // A 先回来（晚发起的 B 仍在跑）
    bootA.complete();
    final resA = await futA;
    check('A 的 await 回来后被判过时（未发布）', resA == null);
    check('A 的那一对资源被释放一次',
        log.where((e) => e == 'release-end:10001#1').length == 1);
    check('B 未发布前 publishedTarget 仍为空', c.publishedTarget == null);

    bootB.complete();
    final resB = await futB;
    check('B 正常发布', resB != null);
    check('最终只发布了 B', c.publishedTarget == (uin: 10002, epoch: 2));
    check('B 没有被释放',
        !log.any((e) => e.startsWith('release-start:10002')));
  }

  // ------------------------------------------------------------------
  // 3. 同号重连（epoch 变了）：旧资源必须交还并只释放一次
  // ------------------------------------------------------------------
  {
    final c = newCoord();
    final log = <String>[];
    final first = c.update(uin: 10001, epoch: 1);
    final r1 = FakePair('s1');
    check('第一代会话发布成功', c.complete(first.plan!, r1));

    // 断线：账号还在、只是不在线 → 保留展示
    final offline = c.update(uin: 10001, epoch: null);
    check('断线不给新计划', offline.plan == null);
    check('断线不交还同号资源', offline.retired == null);
    check('断线后仍认为该号已发布', c.publishedTarget?.uin == 10001);

    // 重连成功：同号新会话代
    final second = c.update(uin: 10001, epoch: 2);
    check('同号新会话给出新计划', second.plan != null);
    check('同号新会话必须交还旧资源', identical(second.retired, r1));

    await second.retired!.release(log);
    check('旧资源 store 释放一次', r1.storeDisposed == 1);
    check('旧资源 adapter 释放一次', r1.adapterDisposed == 1);

    final r2 = FakePair('s2');
    check('新会话可以发布', c.complete(second.plan!, r2));
    check('新会话目标 epoch=2', c.publishedTarget == (uin: 10001, epoch: 2));
    check('新资源未被释放', r2.storeDisposed == 0 && r2.adapterDisposed == 0);

    // 再喂一次同代在线：去重
    final dup = c.update(uin: 10001, epoch: 2);
    check('新会话的重复在线快照去重', dup.plan == null);
    check('新会话的重复快照不释放', dup.retired == null);
  }

  // ------------------------------------------------------------------
  // 4. 已发布后换号：立刻收回旧号展示（哪怕新号未在线）
  // ------------------------------------------------------------------
  {
    final c = newCoord();
    final log = <String>[];
    final a = c.update(uin: 10001, epoch: 1);
    final ra = FakePair('A');
    check('A 发布', c.complete(a.plan!, ra));

    final switchOffline = c.update(uin: 10002, epoch: null);
    check('换号（新号未在线）交还旧资源', identical(switchOffline.retired, ra));
    check('换号（新号未在线）不启动新计划', switchOffline.plan == null);
    check('换号后不再认为旧号在发布', c.publishedTarget == null);

    await switchOffline.retired!.release(log);
    check('旧号资源被释放一次',
        ra.storeDisposed == 1 && ra.adapterDisposed == 1);

    final b = c.update(uin: 10002, epoch: 2);
    check('新号上线给出计划', b.plan != null);
    check('新号上线无遗留资源', b.retired == null);
    final rb = FakePair('B');
    check('新号可以发布', c.complete(b.plan!, rb));
    check('新号成为已发布目标', c.publishedTarget == (uin: 10002, epoch: 2));
  }

  // ------------------------------------------------------------------
  // 5. 退出登录（uin=null）：收回并释放
  // ------------------------------------------------------------------
  {
    final c = newCoord();
    final log = <String>[];
    final a = c.update(uin: 10001, epoch: 1);
    final ra = FakePair('A');
    c.complete(a.plan!, ra);

    final out = c.update(uin: null, epoch: null);
    check('退出登录交还资源', identical(out.retired, ra));
    check('退出登录不给计划', out.plan == null);
    check('退出后已发布为空', c.publishedTarget == null);

    await out.retired!.release(log);
    check('退出时资源只释放一次',
        ra.storeDisposed == 1 && ra.adapterDisposed == 1);

    final outAgain = c.update(uin: null, epoch: null);
    check('重复退出不重复交还', outAgain.retired == null);
    check('重复退出不给计划', outAgain.plan == null);
  }

  // ------------------------------------------------------------------
  // 6. close()：永久关闭 + 交还资源 + 之后不再产生计划
  // ------------------------------------------------------------------
  {
    final c = newCoord();
    final log = <String>[];
    final a = c.update(uin: 10001, epoch: 1);
    final ra = FakePair('A');
    c.complete(a.plan!, ra);

    final retired = c.close();
    check('close 交还已发布资源', identical(retired, ra));
    check('close 后标记已关闭', c.isClosed);
    check('close 后发布目标清空', c.publishedTarget == null);

    await retired!.release(log);
    check('close 时资源释放一次',
        ra.storeDisposed == 1 && ra.adapterDisposed == 1);

    final after = c.update(uin: 10003, epoch: 9);
    check('close 之后不给计划', after.plan == null);
    check('close 之后不交还任何东西', after.retired == null);
    check('close 之后仍是关闭态', c.isClosed);

    // close 之前 pending 的一轮：迟到的 bootstrap 不得发布
    final c2 = newCoord();
    final boot = Completer<void>();
    final p = c2.update(uin: 10004, epoch: 1).plan!;
    final fut = runAttach(c2, p, bootstrap: boot.future, log: log);
    c2.close();
    boot.complete();
    final late = await fut;
    check('close 后迟到的 pending 不能发布', late == null);
    check('close 后迟到的那一对被释放',
        log.where((e) => e == 'release-end:10004#1').length == 1);
  }

  // ------------------------------------------------------------------
  // 7. bootstrap 抛异常：fail() 清 pending、同代可重试、不发布
  // ------------------------------------------------------------------
  {
    final c = newCoord();
    final log = <String>[];
    final p1 = c.update(uin: 10001, epoch: 1).plan!;
    final res = await runAttach(
      c,
      p1,
      bootstrap: Future<void>.value(),
      log: log,
      failBootstrap: true,
    );
    check('bootstrap 失败不发布', res == null);
    check('bootstrap 失败后不再 pending', !c.hasPending);
    check('bootstrap 失败后无已发布目标', c.publishedTarget == null);

    final retry = c.update(uin: 10001, epoch: 1);
    check('bootstrap 失败后同代可以重试', retry.plan != null);
    check('重试沿用同一世代（目标没变）', retry.plan!.gen == p1.gen);
  }

  // ------------------------------------------------------------------
  // 8. 完整时序：A 挂起 → 切 B → A 迟到 → B 完成（Completer，无 sleep）
  // ------------------------------------------------------------------
  {
    final c = newCoord();
    final log = <String>[];
    final bootA = Completer<void>();
    final bootB = Completer<void>();

    final planA = c.update(uin: 10001, epoch: 1).plan!;
    final futA = runAttach(c, planA, bootstrap: bootA.future, log: log);
    final planB = c.update(uin: 10002, epoch: 2).plan!;
    final futB = runAttach(c, planB, bootstrap: bootB.future, log: log);

    bootA.complete();
    final resA = await futA;
    check('整体时序：A 迟到未发布', resA == null);
    check('整体时序：A 只释放一次',
        log.where((e) => e == 'release-end:10001#1').length == 1);
    check('整体时序：A 未污染 B', c.publishedTarget == null);

    bootB.complete();
    final resB = await futB;
    check('整体时序：B 发布', resB != null);
    check('整体时序：最终只有 B', c.publishedTarget == (uin: 10002, epoch: 2));
    check('整体时序：B 未释放', resB!.storeDisposed == 0);
  }

  print('\nAccountCleanupBarrier');

  // ------------------------------------------------------------------
  // 9. 顺序保证：同账号旧 cleanup 必须早于新写盘（bootstrap）
  // ------------------------------------------------------------------
  {
    final barrier = AccountCleanupBarrier();
    final seq = <String>[];
    final oldReleaseGate = Completer<void>();

    // 旧 store 的 dispose 排进屏障（故意卡住，模拟慢 flush）
    unawaited(barrier.run(10001, () async {
      seq.add('old-dispose-start');
      await oldReleaseGate.future;
      seq.add('old-dispose-end');
    }));

    // 新 attach：先等屏障，再 bootstrap（写盘）
    final newAttach = barrier.waitFor(10001).then((_) async {
      seq.add('new-bootstrap-start');
    });

    await Future<void>.delayed(Duration.zero);
    check('旧 cleanup 未完成时新 bootstrap 不会开始',
        !seq.contains('new-bootstrap-start'));
    check('旧 cleanup 已开始', seq.contains('old-dispose-start'));

    oldReleaseGate.complete();
    await newAttach;
    check('旧 cleanup 完成后新 bootstrap 才开始',
        seq.indexOf('old-dispose-end') < seq.indexOf('new-bootstrap-start'));
  }

  // ------------------------------------------------------------------
  // 10. 不同账号互不阻塞；抛异常不永久卡住；同账号严格串行
  // ------------------------------------------------------------------
  {
    final barrier = AccountCleanupBarrier();
    final seq = <String>[];
    final gate = Completer<void>();

    unawaited(barrier.run(10001, () async {
      seq.add('A-start');
      await gate.future;
      seq.add('A-end');
    }));

    // 另一个账号不该被 A 的慢 cleanup 拖住
    await barrier.waitFor(10002).then((_) => seq.add('B-ready'));
    check('不同账号不互相阻塞',
        seq.contains('B-ready') && !seq.contains('A-end'));

    gate.complete();
    await barrier.waitFor(10001);
    check('A 完成后 waitFor 返回', seq.contains('A-end'));

    // 抛异常的 cleanup：异常传给调用方，链尾仍放行
    var threw = false;
    try {
      await barrier.run(10003, () async => throw StateError('boom'));
    } on StateError {
      threw = true;
    }
    check('cleanup 的异常会传给调用方', threw);

    var reached = false;
    await barrier.waitFor(10003).then((_) => reached = true);
    check('抛异常后该账号的屏障仍会放行', reached);

    // 同一账号连续两次 cleanup：必须串行（不并发写同一个根）
    final seq2 = <String>[];
    var active = 0;
    var maxActive = 0;
    Future<void> job(String n) async {
      active++;
      if (active > maxActive) maxActive = active;
      seq2.add('$n-start');
      await Future<void>.delayed(Duration.zero);
      seq2.add('$n-end');
      active--;
    }

    await Future.wait(<Future<void>>[
      barrier.run(10004, () => job('j1')),
      barrier.run(10004, () => job('j2')),
    ]);
    check('同账号两次 cleanup 严格串行（最大并发 1）', maxActive == 1,
        'maxActive=$maxActive');
    check('同账号清理顺序保持提交顺序',
        seq2.indexOf('j1-end') < seq2.indexOf('j2-start'));
  }

  print('\n通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
