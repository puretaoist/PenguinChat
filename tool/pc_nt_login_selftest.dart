// PC NTLogin EasyLogin 离线自测（build 往返 + 三种响应解析）。
import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/kernel/wlogin8/pc/pc_crypto.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_nt_login.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_proto.dart';

int _pass = 0, _fail = 0;
void ok(String n) { _pass++; stdout.writeln('  ✓ $n'); }
void bad(String n, String d) { _fail++; stdout.writeln('  ✗ $n\n      → $d'); }
void check(String n, bool c, [String d = '']) => c ? ok(n) : bad(n, d);
void checkEq(String n, Object? a, Object? b) =>
    ('$a' == '$b') ? ok(n) : bad(n, '期望 $b，实际 $a');
void section(String t) => stdout.writeln('\n$t');
bool _eq(Uint8List a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
Uint8List _u(List<int> v) => Uint8List.fromList(v);

void main() {
  final sessionTicket = _u([1, 2, 3, 4, 5]);
  final sessionKey = _u(List<int>.generate(32, (i) => i + 1));
  final a1 = _u([9, 9, 9]);
  final guid = _u(List<int>.generate(16, (i) => 0x30 + i));

  section('1. buildEasyLoginPayload 往返');
  final payload = PcNtLogin.buildEasyLoginPayload(
    sessionTicket: sessionTicket,
    sessionKey: sessionKey,
    encryptedA1: a1,
    account: '12345',
    os: 'Linux',
    kernel: 'Linux',
    deviceName: 'DEV-1',
    appId: 1600001615,
    packageName: 'com.tencent.qq',
    currentVersion: '3.2.19-39038',
    guid: guid,
  );
  {
    Uint8List? ticket, buffer;
    var type = 0;
    final r = PbReader(payload);
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 1) {
        ticket = Uint8List.fromList(r.readBytes());
      } else if (f == 3) {
        buffer = Uint8List.fromList(r.readBytes());
      } else if (f == 4) {
        type = r.readVarint();
      } else {
        r.skip(w);
      }
    }
    check('sessionTicket(field1) 正确', ticket != null && _eq(ticket, sessionTicket));
    checkEq('type(field4) = 1', type, 1);
    final cm = _parseCommon(PcAesGcm.decrypt(sessionKey, buffer!));
    checkEq('account', cm.account, '12345');
    checkEq('clientInfo.deviceType = os', cm.deviceType, 'Linux');
    checkEq('clientInfo.deviceName', cm.deviceName, 'DEV-1');
    checkEq('clientInfo.platform = 7(linux)', cm.platform, 7);
    check('clientInfo.guid', _eq(cm.guid, guid));
    checkEq('appInfo.version = kernel', cm.version, 'Linux');
    checkEq('appInfo.appId', cm.appId, 1600001615);
    checkEq('appInfo.appName', cm.appName, 'com.tencent.qq');
    checkEq('appInfo.qua（- 换 _）', cm.qua, 'V1_LNX_NQ_3.2.19_39038_GW_B');
    checkEq('sdkInfo.version = 1', cm.sdkVersion, 1);
    // body = EasyLoginReqBody{1:a1}
    final b = PbReader(cm.body);
    Uint8List? a1b;
    while (!b.atEnd) {
      final (f, w) = b.readTag();
      if (f == 1) {
        a1b = Uint8List.fromList(b.readBytes());
      } else {
        b.skip(w);
      }
    }
    check('body.a1 正确', a1b != null && _eq(a1b, a1));
  }

  section('2. 解析 Success 响应');
  {
    final t1 = _u([10]), t2 = _u([20, 21]), t3 = _u([30]), t4 = _u([40, 41, 42, 43]);
    final tickets = (PbWriter()
          ..writeBytes(3, t1)
          ..writeBytes(4, t2)
          ..writeBytes(5, t3)
          ..writeBytes(6, t4))
        .toBytes();
    final rspBody = (PbWriter()..writeBytes(1, tickets)).toBytes();
    final common = _commonResponse(cookies: 'ck=1', rspBody: rspBody);
    final resp = _forward(PcAesGcm.encrypt(sessionKey, common));
    final res = PcNtLogin.parseEasyLoginResponse(resp, sessionKey);
    checkEq('status=success', res.status, PcNtLoginStatus.success);
    check('a1', _eq(res.a1, t1));
    check('a2', _eq(res.a2, t2));
    check('d2', _eq(res.d2, t3));
    check('d2Key', _eq(res.d2Key, t4));
    checkEq('回传 unusualCookies', res.newUnusualCookies, 'ck=1');
  }

  section('3. 解析 UnusualDevice 响应（errCode=140022011）');
  {
    final sig = _u([7, 7, 7, 7]);
    final secProtect = (PbWriter()..writeBytes(2, sig)).toBytes();
    final rspBody = (PbWriter()..writeBytes(3, secProtect)).toBytes();
    final common = _commonResponse(
      errCode: PcNtLogin.unusualDeviceErrCode,
      title: 'Unusual',
      msg: 'need verify',
      rspBody: rspBody,
    );
    final resp = _forward(PcAesGcm.encrypt(sessionKey, common));
    final res = PcNtLogin.parseEasyLoginResponse(resp, sessionKey);
    checkEq('status=unusualDevice', res.status, PcNtLoginStatus.unusualDevice);
    check('unusualSig', _eq(res.unusualSig, sig));
  }

  section('4. 解析 Failure 响应');
  {
    final common = _commonResponse(errCode: 1234, title: 'Err', msg: 'bad');
    final resp = _forward(PcAesGcm.encrypt(sessionKey, common));
    final res = PcNtLogin.parseEasyLoginResponse(resp, sessionKey);
    checkEq('status=failure', res.status, PcNtLoginStatus.failure);
    checkEq('errCode', res.errCode, 1234);
    checkEq('errTag', res.errTag, 'Err');
    checkEq('errMsg', res.errMsg, 'bad');
  }

  section('5. platform / qua 辅助');
  {
    checkEq('windows→4', pcPlatformFor('Windows'), 4);
    checkEq('mac→5', pcPlatformFor('Mac'), 5);
    checkEq('linux→7', pcPlatformFor('Linux'), 7);
    checkEq('qua(Mac)', pcQuaFor('Mac', '7.0.1-52892'), 'V1_MAC_NQ_7.0.1_52892_GW_B');
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}

Uint8List _forward(Uint8List buffer) =>
    (PbWriter()..writeBytes(3, buffer)..writeInt(4, 1)).toBytes();

Uint8List _commonResponse({
  int errCode = 0,
  String title = '',
  String msg = '',
  String? cookies,
  List<int> rspBody = const <int>[],
}) {
  final body = Uint8List.fromList(rspBody);
  final head = PbWriter();
  if (errCode != 0) {
    head.writeBytes(4, (PbWriter()..writeInt(1, errCode)..writeString(2, title)..writeString(3, msg)).toBytes());
  }
  if (cookies != null) {
    head.writeBytes(5, (PbWriter()..writeString(1, cookies)).toBytes());
  }
  head.writeBytes(7, (PbWriter()..writeInt(1, 1)).toBytes());
  return (PbWriter()..writeBytes(1, head.toBytes())..writeBytes(2, body)).toBytes();
}

({String account, String deviceType, String deviceName, int platform, Uint8List guid,
  String version, int appId, String appName, String qua, int sdkVersion, Uint8List body})
    _parseCommon(Uint8List commonBytes) {
  Uint8List? head, body;
  final c = PbReader(commonBytes);
  while (!c.atEnd) {
    final (f, w) = c.readTag();
    if (f == 1) {
      head = c.readBytes();
    } else if (f == 2) {
      body = c.readBytes();
    } else {
      c.skip(w);
    }
  }
  var account = '', deviceType = '', deviceName = '', version = '', appName = '', qua = '';
  var platform = 0, appId = 0, sdkVersion = 0;
  var guid = Uint8List(0);
  final h = PbReader(head!);
  while (!h.atEnd) {
    final (f, w) = h.readTag();
    if (f == 1) {
      final u = PbReader(h.readBytes());
      while (!u.atEnd) {
        final (uf, uw) = u.readTag();
        if (uf == 1) {
          account = u.readString();
        } else {
          u.skip(uw);
        }
      }
    } else if (f == 2) {
      final ci = PbReader(h.readBytes());
      while (!ci.atEnd) {
        final (cf, cw) = ci.readTag();
        if (cf == 1) {
          deviceType = ci.readString();
        } else if (cf == 2) {
          deviceName = ci.readString();
        } else if (cf == 3) {
          platform = ci.readVarint();
        } else if (cf == 4) {
          guid = Uint8List.fromList(ci.readBytes());
        } else {
          ci.skip(cw);
        }
      }
    } else if (f == 3) {
      final ai = PbReader(h.readBytes());
      while (!ai.atEnd) {
        final (af, aw) = ai.readTag();
        if (af == 1) {
          version = ai.readString();
        } else if (af == 2) {
          appId = ai.readVarint();
        } else if (af == 3) {
          appName = ai.readString();
        } else if (af == 5) {
          qua = ai.readString();
        } else {
          ai.skip(aw);
        }
      }
    } else if (f == 7) {
      final si = PbReader(h.readBytes());
      while (!si.atEnd) {
        final (sf, sw) = si.readTag();
        if (sf == 1) {
          sdkVersion = si.readVarint();
        } else {
          si.skip(sw);
        }
      }
    } else {
      h.skip(w);
    }
  }
  return (
    account: account,
    deviceType: deviceType,
    deviceName: deviceName,
    platform: platform,
    guid: guid,
    version: version,
    appId: appId,
    appName: appName,
    qua: qua,
    sdkVersion: sdkVersion,
    body: body ?? Uint8List(0),
  );
}
