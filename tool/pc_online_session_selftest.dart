// PcOnlineSession 离线自测（Fake 传输，不联网）。
import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/kernel/wlogin8/pc/pc_online.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_proto.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_sso.dart';

int _pass = 0, _fail = 0;
void ok(String n) { _pass++; stdout.writeln('  ✓ $n'); }
void bad(String n, String d) { _fail++; stdout.writeln('  ✗ $n\n      → $d'); }
void check(String n, bool c, [String d = '']) => c ? ok(n) : bad(n, d);
void checkEq(String n, Object? a, Object? b) =>
    ('$a' == '$b') ? ok(n) : bad(n, '期望 $b，实际 $a');
void section(String t) => stdout.writeln('\n$t');

class FakeTransport implements PcPacketTransport {
  final List<({String command, bool simple})> calls = [];
  int registerRet = 0;
  String registerMessage = 'register success';
  int aliveRet = 0;

  @override
  Future<PcSsoResponse> send({
    required String command,
    required Uint8List payload,
    required bool simple,
  }) async {
    calls.add((command: command, simple: simple));
    if (command == PcOnline.registerCmd) {
      return PcSsoResponse(
        retCode: registerRet,
        command: command,
        payload: (PbWriter()..writeString(2, registerMessage)).toBytes(),
        sequence: 0,
      );
    }
    if (command == PcOnline.aliveCmd) {
      return PcSsoResponse(
        retCode: aliveRet,
        command: command,
        payload: Uint8List(0),
        sequence: 0,
      );
    }
    return PcSsoResponse(
      retCode: 0,
      command: command,
      payload: Uint8List(0),
      sequence: 0,
    );
  }
}

PcOnlineSession _session(FakeTransport t) => PcOnlineSession(
      transport: t,
      registerPayload: Uint8List.fromList([1]),
      unRegisterPayload: Uint8List.fromList([2]),
    );

Future<void> main() async {
  section('1. online：Register 成功');
  {
    final t = FakeTransport();
    final s = _session(t);
    check('初始未在线', !s.isOnline);
    await s.online();
    check('online 后 isOnline', s.isOnline);
    checkEq('首个包是 Register', t.calls.first.command, PcOnline.registerCmd);
    check('Register simple=false（protocol12）', !t.calls.first.simple);
  }

  section('2. online：Register 失败');
  {
    final t1 = FakeTransport()..registerRet = 5;
    var thrown = false;
    try {
      await _session(t1).online();
    } catch (_) {
      thrown = true;
    }
    check('retCode!=0 抛异常', thrown);

    final t2 = FakeTransport()..registerMessage = 'oops';
    var thrown2 = false;
    try {
      await _session(t2).online();
    } catch (_) {
      thrown2 = true;
    }
    check('message!="register success" 抛异常', thrown2);
  }

  section('3. tick 节奏（26×Alive + 第27次 Alive+Heartbeat）');
  {
    final t = FakeTransport();
    final s = _session(t);
    await s.online();
    t.calls.clear(); // 只统计心跳
    for (var i = 0; i < 26; i++) {
      await s.tick();
    }
    final alive26 = t.calls.where((c) => c.command == PcOnline.aliveCmd).length;
    final hb0 = t.calls.where((c) => c.command == PcOnline.heartbeatCmd).length;
    checkEq('前 26 tick 共 26 次 Alive', alive26, 26);
    checkEq('前 26 tick 无 Heartbeat', hb0, 0);
    await s.tick(); // 第 27
    final totalAlive = t.calls.where((c) => c.command == PcOnline.aliveCmd).length;
    final totalHb = t.calls.where((c) => c.command == PcOnline.heartbeatCmd).length;
    checkEq('27 tick 后 Alive 共 27 次', totalAlive, 27);
    checkEq('27 tick 后 Heartbeat 共 1 次', totalHb, 1);
    final last2 = t.calls.sublist(t.calls.length - 2);
    check('第27 tick 末两包 = [Alive, Heartbeat]',
        last2[0].command == PcOnline.aliveCmd && last2[1].command == PcOnline.heartbeatCmd);
    check('Alive 走 simple=true', last2[0].simple);
    check('Heartbeat 走 simple=false', !last2[1].simple);
  }

  section('4. offline：发 UnRegister 且幂等');
  {
    final t = FakeTransport();
    final s = _session(t);
    await s.online();
    t.calls.clear();
    await s.offline();
    checkEq('offline 发 1 包', t.calls.length, 1);
    checkEq('命令是 UnRegister', t.calls.first.command, PcOnline.unregisterCmd);
    check('UnRegister simple=false', !t.calls.first.simple);
    check('offline 后 isOnline=false', !s.isOnline);
    t.calls.clear();
    await s.offline(); // 再调用不应再发包
    checkEq('重复 offline 不再发包', t.calls.length, 0);
  }

  section('5. Alive 失败抛异常');
  {
    final t = FakeTransport()..aliveRet = 9;
    final s = _session(t);
    await s.online();
    var thrown = false;
    try {
      await s.tick();
    } catch (_) {
      thrown = true;
    }
    check('Alive retCode!=0 抛异常', thrown);
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
