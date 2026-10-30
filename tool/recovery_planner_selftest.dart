/// 免密恢复编排自测（lib/client_api/recovery_planner.dart + recovery_coordinator.dart）
///
/// 纯离线：不联网、不建连接、不需要账号。目标是把 planner 的规则穷举掉
/// （顺序、优先级、三种 Stop、以及「永不返回密码」这个结构性约束），
/// 再把协调器的单飞与有界语义钉死。
///
/// 运行：dart run tool/recovery_planner_selftest.dart
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/client_api/qq8_token_store.dart';
import 'package:qqclient/client_api/recovery_coordinator.dart';
import 'package:qqclient/client_api/recovery_planner.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  OK  $name${detail == null ? '' : '   ($detail)'}');
  } else {
    _fail++;
    stdout.writeln('  NG  $name${detail == null ? '' : '  ($detail)'}');
  }
}

Uint8List _b(int n, [int fill = 0x11]) =>
    Uint8List.fromList(List<int>.filled(n, fill));

Qq8TokenData _token({
  bool d2 = true,
  bool d2key = true,
  bool a2key = false,
  bool a1 = false,
  bool noPicSig = false,
}) =>
    Qq8TokenData(
      uin: 10001,
      savedAt: 'test',
      tgt: _b(72),
      d2: d2 ? _b(64) : Uint8List(0),
      d2key: d2key ? _b(16) : Uint8List(0),
      sigKey: _b(16),
      ticketKey: _b(16),
      srmToken: _b(16),
      a2Key: a2key ? _b(16) : null,
      a1: a1 ? _b(152) : Uint8List(0),
      noPicSig: noPicSig ? _b(80) : null,
    );

Qq8RecoveryDecision _plan(
  Qq8RecoveryAvailability a, {
  Set<Qq8RecoveryMaterial> tried = const <Qq8RecoveryMaterial>{},
  bool networkError = false,
  bool challengeActive = false,
}) =>
    planNext(
      a: a,
      tried: tried,
      networkError: networkError,
      challengeActive: challengeActive,
    );

String _code(Qq8RecoveryDecision d) {
  if (d is Qq8RecoveryStop) return d.code;
  return 'attempt';
}

Qq8RecoveryMaterial? _mat(Qq8RecoveryDecision d) =>
    d is Qq8RecoveryAttempt ? d.material : null;

Future<void> main() async {
  stdout.writeln('== recovery planner selftest ==');

  stdout.writeln('[1] 材料顺序是写死的常量');
  check('顺序 = d2Key, a2Key, a1NoPicSig, a2Only',
      qq8RecoveryOrderedMaterials.length == 4 &&
          qq8RecoveryOrderedMaterials[0] == Qq8RecoveryMaterial.d2Key &&
          qq8RecoveryOrderedMaterials[1] == Qq8RecoveryMaterial.a2Key &&
          qq8RecoveryOrderedMaterials[2] == Qq8RecoveryMaterial.a1NoPicSig &&
          qq8RecoveryOrderedMaterials[3] == Qq8RecoveryMaterial.a2Only);
  check('orderedMaterials getter 指向同一份常量',
      identical(orderedMaterials, qq8RecoveryOrderedMaterials));
  check('枚举里没有密码类材料',
      !Qq8RecoveryMaterial.values
          .any((m) => m.name.toLowerCase().contains('pass')));

  stdout.writeln('[2] 两种不该在这里重试的情况');
  final all = Qq8RecoveryAvailability.fromToken(
      _token(d2: true, d2key: true, a2key: true, a1: true, noPicSig: true));
  check('networkError -> Stop(network)，即使材料齐全',
      _code(_plan(all, networkError: true)) == 'network');
  check('challengeActive -> Stop(challenge)',
      _code(_plan(all, challengeActive: true)) == 'challenge');
  check('network 优先于 challenge',
      _code(_plan(all, networkError: true, challengeActive: true)) ==
          'network');

  stdout.writeln('[3] 按顺序挑第一个可用且没试过的材料');
  final d1 = _plan(all);
  check('材料齐全 -> 先 d2Key', _mat(d1) == Qq8RecoveryMaterial.d2Key);
  check('attempt 从 1 起', d1 is Qq8RecoveryAttempt && d1.attempt == 1);
  check('why 非空（能进日志）', d1 is Qq8RecoveryAttempt && d1.why.isNotEmpty);
  final d2 = _plan(all, tried: {Qq8RecoveryMaterial.d2Key});
  check('试过 d2Key -> a2Key', _mat(d2) == Qq8RecoveryMaterial.a2Key);
  check('attempt = tried+1 = 2', d2 is Qq8RecoveryAttempt && d2.attempt == 2);
  final d3 = _plan(all, tried: {
    Qq8RecoveryMaterial.d2Key,
    Qq8RecoveryMaterial.a2Key,
  });
  check('再试过 a2Key -> a1NoPicSig', _mat(d3) == Qq8RecoveryMaterial.a1NoPicSig);
  final d4 = _plan(all, tried: {
    Qq8RecoveryMaterial.d2Key,
    Qq8RecoveryMaterial.a2Key,
    Qq8RecoveryMaterial.a1NoPicSig,
  });
  check('只剩 a2Only 时给 a2Only', _mat(d4) == Qq8RecoveryMaterial.a2Only);
  final d5 = _plan(all, tried: Qq8RecoveryMaterial.values.toSet());
  check('全试过 -> Stop(exhausted)', _code(d5) == 'exhausted');
  check('exhausted 文案提示重新登录',
      d5 is Qq8RecoveryStop && d5.message.contains('重新登录'));

  stdout.writeln('[4] 材料不足时的降级路径');
  final onlyD2key = Qq8RecoveryAvailability.fromToken(_token());
  check('有 A2+D2KEY -> d2Key', _mat(_plan(onlyD2key)) == Qq8RecoveryMaterial.d2Key);
  final a1Only = Qq8RecoveryAvailability.fromToken(
      _token(d2: false, d2key: false, a1: true, noPicSig: true));
  check('只有 A1+noPicSig -> a1NoPicSig',
      _mat(_plan(a1Only)) == Qq8RecoveryMaterial.a1NoPicSig);
  final a1WithoutSig = Qq8RecoveryAvailability.fromToken(
      _token(d2: false, d2key: false, a1: true));
  check('有 A1 但没 noPicSig -> 不可用（exhausted）',
      _code(_plan(a1WithoutSig)) == 'exhausted');
  final onlyA2 = Qq8RecoveryAvailability.fromToken(_token(d2: true, d2key: false));
  check('只有 A2 -> a2Only', _mat(_plan(onlyA2)) == Qq8RecoveryMaterial.a2Only);
  final nothing = Qq8RecoveryAvailability.fromToken(null);
  check('null 票据 -> 全 false',
      !nothing.hasA2 && !nothing.hasD2Key && !nothing.hasA2Key &&
          !nothing.hasA1 && !nothing.hasNoPicSig);
  check('什么都没有 -> Stop(exhausted)', _code(_plan(nothing)) == 'exhausted');
  check('d2 空但 d2key 非空 -> d2Key 不可用（需同时有）',
      !Qq8RecoveryAvailability.fromToken(_token(d2: false, d2key: true))
          .has(Qq8RecoveryMaterial.d2Key));

  stdout.writeln('[5] 纯函数性：同输入同输出');
  final r1 = _plan(onlyD2key);
  final r2 = _plan(onlyD2key);
  check('两次调用同类同材料',
      r1 is Qq8RecoveryAttempt &&
          r2 is Qq8RecoveryAttempt &&
          r1.material == r2.material &&
          r1.attempt == r2.attempt);
  check('toString 便于排查（含材料名）',
      r1.toString().contains('d2Key'));

  stdout.writeln('[6] 协调器：单飞（并发只跑一次）');
  {
    final coor = Qq8RecoveryCoordinator(delay: Duration.zero);
    var starts = 0;
    final gate = Completer<void>();
    Future<bool?> body() async {
      starts++;
      await gate.future;
      return true;
    }

    final f1 = coor.runSingleFlight<bool>(body);
    final f2 = coor.runSingleFlight<bool>(body);
    final r2v = await f2;
    check('第二个并发调用立刻拿到 null', r2v == null);
    check('执行期间 busy = true', coor.busy);
    check('body 只开始了一次', starts == 1, 'starts=$starts');
    gate.complete();
    final r1v = await f1;
    check('第一个调用拿到 body 返回值', r1v == true);
    check('结束后 busy = false', !coor.busy);
    final r3 = await coor.runSingleFlight<bool>(() async => false);
    check('空闲后可再跑（不是一次性）', r3 == false && !coor.busy);
  }

  stdout.writeln('[7] 协调器：有界（最多 4 次）');
  {
    final delays = <Duration>[];
    final coor = Qq8RecoveryCoordinator(
      delay: const Duration(milliseconds: 5),
      sleeper: (d) async {
        delays.add(d);
      },
    );
    var calls = 0;
    final sw = Stopwatch()..start();
    final v = await coor.runBounded<int>((i) async {
      calls++;
      return i >= 3 ? i : null;
    });
    sw.stop();
    check('第 3 次成功即返回', v == 3, 'v=$v');
    check('只调了 3 次（成功后不再试）', calls == 3, 'calls=$calls');
    check('两次失败间各等一次 delay',
        delays.length == 2 && delays.every((d) => d.inMilliseconds == 5),
        'delays=${delays.length}');
    check('sleeper 注入生效（没真睡）', sw.elapsedMilliseconds < 60,
        '${sw.elapsedMilliseconds}ms');
  }
  {
    final coor = Qq8RecoveryCoordinator(
      delay: Duration.zero,
      sleeper: (_) async {},
    );
    var calls = 0;
    final v = await coor.runBounded<int>((_) async {
      calls++;
      return null;
    });
    check('一直失败 -> 正好 maxAttempts 次',
        calls == Qq8RecoveryCoordinator.maxAttempts, 'calls=$calls');
    check('一直失败返回 null（不抛）', v == null);
  }
  {
    final coor = Qq8RecoveryCoordinator(
      delay: Duration.zero,
      sleeper: (_) async {},
    );
    var calls = 0;
    final v = await coor.runBounded<int>((i) async {
      calls++;
      if (i < 3) throw StateError('boom');
      return 7;
    });
    check('body 抛异常被吞并继续', v == 7 && calls == 3, 'v=$v calls=$calls');
  }

  stdout.writeln('[8] 票据新增材料字段：可选、向后兼容');
  final t = _token(a2key: true, a1: true, noPicSig: true);
  check('a2Key / noPicSig 有值', t.a2Key != null && t.noPicSig != null);
  final plain = _token();
  check('不传时是 null（不是空数组）',
      plain.a2Key == null && plain.noPicSig == null);
  final back = Qq8TokenData.fromJson(
      jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>);
  check('JSON 往返 a2_key', back.a2Key != null && back.a2Key!.length == 16);
  check('JSON 往返 no_pic_sig',
      back.noPicSig != null && back.noPicSig!.length == 80);
  final legacy = <String, dynamic>{
    'uin': 10001,
    'saved_at': 'x',
    'tgt': 'aa',
    'd2': 'bb',
    'd2key': 'cc',
    'sig_key': 'dd',
    'ticket_key': 'ee',
    'srm_token': 'ff',
    'a1': '',
  };
  final lt = Qq8TokenData.fromJson(legacy);
  check('旧票据文件（无这两个键）读成 null',
      lt.a2Key == null && lt.noPicSig == null);
  check('旧票据仍能推 d2Key 可用',
      Qq8RecoveryAvailability.fromToken(lt).has(Qq8RecoveryMaterial.d2Key));
  final kept = t.copyWith(renewedAtMs: 5);
  check('copyWith 不传时保留 a2Key/noPicSig',
      kept.a2Key != null && kept.noPicSig != null);
  final dirty = Map<String, dynamic>.from(legacy)
    ..['a2_key'] = 'zz'
    ..['no_pic_sig'] = 42;
  final dt = Qq8TokenData.fromJson(dirty);
  check('脏值读成 null 不抛', dt.a2Key == null && dt.noPicSig == null);

  stdout.writeln('==============================');
  stdout.writeln('pass=$_pass fail=$_fail');
  exit(_fail == 0 ? 0 : 1);
}
