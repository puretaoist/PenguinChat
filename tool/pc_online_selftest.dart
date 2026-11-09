// PC 长连接（Register/Alive/Heartbeat/UnRegister + 心跳调度）离线自测。
import 'dart:io';

import 'package:penguinchat/kernel/wlogin8/pc/pc_online.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_proto.dart';

int _pass = 0, _fail = 0;
void ok(String n) { _pass++; stdout.writeln('  ✓ $n'); }
void bad(String n, String d) { _fail++; stdout.writeln('  ✗ $n\n      → $d'); }
void check(String n, bool c, [String d = '']) => c ? ok(n) : bad(n, d);
void checkEq(String n, Object? a, Object? b) =>
    ('$a' == '$b') ? ok(n) : bad(n, '期望 $b，实际 $a');
void section(String t) => stdout.writeln('\n$t');

void main() {
  section('1. Alive / Heartbeat payload');
  {
    final alive = PcOnline.buildAlivePayload();
    check('Alive = [0,0,0,4]',
        alive.length == 4 && alive[0] == 0 && alive[1] == 0 && alive[2] == 0 && alive[3] == 4);
    final hb = PbReader(PcOnline.buildHeartbeatPayload());
    final (f, _) = hb.readTag();
    checkEq('Heartbeat 字段1', f, 1);
    checkEq('Heartbeat type = 1', hb.readVarint(), 1);
  }

  section('2. Register payload');
  {
    final p = PcOnline.buildRegisterPayload(
      guidHex: 'AABBCCDDEEFF00112233445566778899',
      currentVersion: '3.2.19-39038',
      deviceName: 'DEV-1',
      kernel: 'Linux',
      os: 'Linux',
      vendorOs: 'linux',
    );
    String guid = '', cur = '';
    String devName = '', devType = '', osVer = '', vendor = '';
    var notify = 0, bind = 0, sawDevice = false, sawBiz = false;
    final r = PbReader(p);
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 1) {
        guid = r.readString();
      } else if (f == 3) {
        cur = r.readString();
      } else if (f == 6) {
        sawDevice = true;
        final d = PbReader(r.readBytes());
        while (!d.atEnd) {
          final (df, dw) = d.readTag();
          if (df == 1) {
            devName = d.readString();
          } else if (df == 2) {
            devType = d.readString();
          } else if (df == 3) {
            osVer = d.readString();
          } else if (df == 5) {
            vendor = d.readString();
          } else {
            d.skip(dw);
          }
        }
      } else if (f == 10) {
        sawBiz = true;
        final b = PbReader(r.readBytes());
        while (!b.atEnd) {
          final (bf, bw) = b.readTag();
          if (bf == 1) {
            notify = b.readVarint();
          } else if (bf == 2) {
            bind = b.readVarint();
          } else {
            b.skip(bw);
          }
        }
      } else {
        r.skip(w);
      }
    }
    checkEq('guid(hex)', guid, 'AABBCCDDEEFF00112233445566778899');
    checkEq('currentVersion', cur, '3.2.19-39038');
    check('含 device(6)', sawDevice);
    checkEq('device.devName', devName, 'DEV-1');
    checkEq('device.devType=kernel', devType, 'Linux');
    checkEq('device.osVer(Linux 映射)', osVer, 'Ubuntu 22.04.4 LTS');
    checkEq('device.vendorOsName', vendor, 'linux');
    check('含 businessInfo(10)', sawBiz);
    checkEq('businessInfo.notifySwitch=1', notify, 1);
    checkEq('businessInfo.bindUinNotifySwitch=1', bind, 1);
  }

  section('3. UnRegister payload（device 在字段 2）');
  {
    final p = PcOnline.buildUnRegisterPayload(
      deviceName: 'DEV-1',
      kernel: 'Linux',
      os: 'Linux',
      vendorOs: 'linux',
    );
    var field2 = false;
    String devName = '';
    final r = PbReader(p);
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 2) {
        field2 = true;
        final d = PbReader(r.readBytes());
        while (!d.atEnd) {
          final (df, dw) = d.readTag();
          if (df == 1) {
            devName = d.readString();
          } else {
            d.skip(dw);
          }
        }
      } else {
        r.skip(w);
      }
    }
    check('device 在字段 2', field2);
    checkEq('device.devName', devName, 'DEV-1');
  }

  section('4. parseRegisterResponse');
  {
    final okMsg = (PbWriter()..writeString(2, 'register success')).toBytes();
    checkEq('message', PcOnline.parseRegisterResponse(okMsg), 'register success');
    check('isRegisterSuccess=true', PcOnline.isRegisterSuccess('register success'));
    check('isRegisterSuccess=false', !PcOnline.isRegisterSuccess('error'));
  }

  section('5. PcHeartbeatScheduler 节奏（10s Alive / 27 次补 Heartbeat）');
  {
    final s = PcHeartbeatScheduler();
    for (var i = 1; i <= 26; i++) {
      final t = s.nextTick();
      if (t.length != 1 || t[0] != PcOnline.aliveCmd) {
        bad('第 $i tick 仅 Alive', '$t');
        break;
      }
      if (i == 26) ok('前 26 tick 仅 Alive');
    }
    final t27 = s.nextTick();
    check('第 27 tick = [Alive, Heartbeat]',
        t27.length == 2 && t27[0] == PcOnline.aliveCmd && t27[1] == PcOnline.heartbeatCmd, '$t27');
    checkEq('第 27 tick 后计数清零', s.aliveCount, 0);
    final t28 = s.nextTick();
    check('第 28 tick 回到仅 Alive', t28.length == 1 && t28[0] == PcOnline.aliveCmd, '$t28');
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
