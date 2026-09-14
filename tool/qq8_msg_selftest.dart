/// 发消息（`MessageSvc.PbSendMsg`）离线自测
///
/// 两层：
/// * **内核层**：`PB_CONTENT` / 保留元素 / rich / 私聊与群聊请求体 / 同步 cookie
///   的字段逐项核对（用我们自己的 pb 编解码闭环）——参考实现逐字段对照，
///   没有黄金向量（js 时代那份没有 pb 发消息路径）；
/// * **服务层**：脚本传输跑"上线 → 发私聊 → 成功/失败响应"，并把真实发出的
///   UNI 包解开核对命令字与 body（包内层用 d2key 加密，测试里能解）。
///
/// 运行：
/// ```bash
/// dart run tool/qq8_msg_selftest.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/client_api/qq8_login_service.dart';
import 'package:qqclient/infra/coder.dart';
import 'package:qqclient/kernel/crypto/ecdh.dart';
import 'package:qqclient/kernel/crypto/tea.dart';
import 'package:qqclient/kernel/wlogin8/qq8_config.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_jce.dart';
import 'package:qqclient/kernel/wlogin8/qq8_msg.dart';
import 'package:qqclient/kernel/wlogin8/qq8_pb.dart';
import 'package:qqclient/kernel/wlogin8/qq8_tran.dart';

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

// ---------------------------------------------------------------------------
// 夹具（与服务自测同款：固定设备 + 固定 ECDH）
// ---------------------------------------------------------------------------

final Uint8List _d2key = _hex('a3' * 16);

final EcdhKeyPair _fixedEcdh = Ecdh.exchange(
  Uint8List.fromList(Qq8Config.serverEcdhPublicKey),
  privateKey: _hex('${'00' * 31}01'),
);

Qq8Device _fixtureDevice(int uin) => Qq8Device(
      product: 'piano',
      device: 'piano',
      board: 'piano',
      brand: 'Xiaomi',
      model: '25091RP04C',
      bootloader: 'unknown',
      fingerprint: 'Xiaomi/piano/piano:16/BP2A/eng:user/release-keys',
      bootId: '11111111-2222-3333-4444-555555555555',
      procVersion: 'Linux version 5.15.0',
      baseband: '',
      sim: 'T-Mobile',
      apn: 'wifi',
      osType: 'android',
      macAddress: '00:50:56:C0:00:08',
      ipAddress: '10.0.0.1',
      wifiBssid: '00:50:56:C0:00:08',
      wifiSsid: 'TP-LINK-2711',
      imei: '860000000000001',
      androidId: 'ABCDEF1234567890',
      version: const Qq8AndroidVersion(
        release: '10',
        codename: 'REL',
        incremental: '1234567',
        sdk: 29,
      ),
      imsi: Uint8List(16),
      tgtgt: _hex('ffeeddccbbaa99887766554433221100'),
      guid: _hex('00112233445566778899aabbccddeeff'),
    );

/// 响应帧：`[外壳(flag=2)][SSO 头][payload]`。
Uint8List _frame(int seq, String cmd, Uint8List payload) {
  final cmdBytes = utf8.encode(cmd);
  final header = (ByteWriter()
        ..u32(0)
        ..u32(seq)
        ..u32(0)
        ..u32(4)
        ..u32(cmdBytes.length + 4)
        ..raw(cmdBytes)
        ..u32(8)
        ..raw(_hex('01020304'))
        ..u32(0))
      .build();
  final headLen = header.length - 4;
  header[0] = (headLen >> 24) & 0xff;
  header[1] = (headLen >> 16) & 0xff;
  header[2] = (headLen >> 8) & 0xff;
  header[3] = headLen & 0xff;
  final plain = Uint8List.fromList(<int>[...header, ...payload]);
  final uinBytes = utf8.encode('10001');
  return (ByteWriter()
        ..u32(0x0A)
        ..u8(2)
        ..u32(0)
        ..u8(4 + uinBytes.length)
        ..raw(uinBytes)
        ..raw(qqTeaEncrypt(plain, Uint8List(16))))
      .build();
}

Uint8List _wrap(Uint8List plain) => Uint8List.fromList(<int>[
      ...List<int>.filled(16, 0x77),
      ...qqTeaEncrypt(plain, _fixedEcdh.shareKey),
      0x03,
    ]);

/// 登录成功帧（0x119 用 `MD5(d2key)` 加密——token 路径的 tgtgt 约定）。
Uint8List _successFrame(int seq) {
  final inner = ByteWriter()..u16(1);
  void put(int tag, List<int> body) {
    inner
      ..u16(tag)
      ..u16(body.length)
      ..raw(body);
  }

  put(0x10A, List<int>.filled(56, 0xa1));
  put(0x143, List<int>.filled(64, 0xa2));
  put(0x305, _d2key);
  put(0x133, List<int>.filled(48, 0xa4));
  put(0x134, List<int>.filled(16, 0xa5));
  put(0x16A, List<int>.filled(56, 0xa6));
  final enc = qqTeaEncrypt(inner.build(), md5Bytes(_d2key));
  final payload = (ByteWriter()..u16(1)..u8(0)..u16(2))
    ..u16(0x119)
    ..u16(enc.length)
    ..raw(enc);
  return _frame(seq, 'wtlogin.login', _wrap(payload.build()));
}

Uint8List _registerFrame(int seq) {
  final struct = Qq8Jce.encodeStruct(<int, Object?>{0: 10001, 9: 1});
  final payload = Qq8Jce.encode(<int, Object?>{
    0: <Object?, Object?>{'SvcRespRegister': struct},
  });
  return _frame(seq, 'StatSvc.register', Qq8Jce.encode(<int, Object?>{7: payload}));
}

/// 把 UNI 包拆成 (命令字, body)——内层用 d2key 解。
(String, Uint8List) _uniParts(Uint8List pkt) {
  var pos = 14;
  final uinLen = (pkt[pos] << 24) | (pkt[pos + 1] << 16) | (pkt[pos + 2] << 8) | pkt[pos + 3];
  pos += uinLen;
  final sso = qqTeaDecrypt(pkt.sublist(pos), _d2key);
  final cmdLen = (sso[4] << 24) | (sso[5] << 16) | (sso[6] << 8) | sso[7];
  final cmd = String.fromCharCodes(sso.sublist(8, 8 + cmdLen - 4));
  var p = 8 + cmdLen - 4;
  p += 4; // session 长度字段
  p += 4; // session
  p += 4; // 固定 4
  final bodyLen = (sso[p] << 24) | (sso[p + 1] << 16) | (sso[p + 2] << 8) | sso[p + 3];
  return (cmd, sso.sublist(p + 4, p + bodyLen));
}

class _MemStore implements Qq8TokenStore {
  Qq8TokenData? data;
  @override
  Future<Qq8TokenData?> load(int uin) async => data;
  @override
  Future<void> save(Qq8TokenData d) async => data = d;
  @override
  Future<void> clear(int uin) async => data = null;
}

Future<void> main() async {
  stdout.writeln('发消息（MessageSvc.PbSendMsg）离线自测');
  stdout.writeln('=' * 62);

  // ----------------------------------------------------------------
  section('1. 内核：固定内容头与保留元素');
  {
    check('PB_CONTENT = {1:1, 2:0, 3:0}',
        _hexOf(Qq8Msg.pbContent) == '080110001800', _hexOf(Qq8Msg.pbContent));

    final reserver = Qq8Pb.decode(Qq8Msg.pbReserver);
    final t37 = Qq8Pb.bytesAt(reserver, 37);
    check('保留元素含 tag37', t37 != null);
    final inner = Qq8Pb.decode(t37!);
    check('tag37 = {17:0, 19:{15:0,31:0,41:0}}',
        Qq8Pb.intAt(inner, 17) == 0 &&
            _hexOf(Qq8Pb.bytesAt(inner, 19)!) == '78 00 f8 01 00 c8 02 00'.replaceAll(' ', ''),
        _hexOf(Qq8Pb.bytesAt(inner, 19)!));
  }

  // ----------------------------------------------------------------
  section('2. 内核：纯文本 rich');
  {
    final rich = Qq8Pb.decode(Qq8Msg.textRich('hi 中文'));
    final elems = rich[2];
    check('rich = {2: [文本元素, 保留元素]}',
        elems != null && elems.length == 2, '${elems?.length}');
    final textElem = Qq8Pb.decode(elems![0] as Uint8List);
    check('文本元素 = {1: {1: "hi 中文"}}',
        Qq8Pb.textAt(Qq8Pb.decode(Qq8Pb.bytesAt(textElem, 1)!), 1) == 'hi 中文');
    check('第二个元素就是保留元素（逐字节一致）',
        _hexOf(elems[1] as Uint8List) == _hexOf(Qq8Msg.pbReserver));
  }

  // ----------------------------------------------------------------
  section('3. 内核：私聊请求体');
  {
    final body = Qq8Msg.buildC2cTextBody(
      uid: 12345,
      elems: <Uint8List>[Qq8Msg.textElem('hello')],
      seq: 321,
      rand: 0x11223344,
      syncCookieSeed: 0x01020304,
      nowSeconds: 1700000000,
      syncR5: 0x11111111,
      syncR9: 0x22222222,
      syncR11: 0x33333333,
    );
    final m = Qq8Pb.decode(body);
    final route1 = Qq8Pb.decode(Qq8Pb.bytesAt(m, 1)!);
    final c2c = Qq8Pb.decode(Qq8Pb.bytesAt(route1, 1)!);
    check('路由 {1:{1:{1:uid}}}（私聊）', Qq8Pb.intAt(c2c, 1) == 12345,
        '${Qq8Pb.intAt(c2c, 1)}');
    check('tag2 = PB_CONTENT（逐字节）',
        _hexOf(Qq8Pb.bytesAt(m, 2)!) == _hexOf(Qq8Msg.pbContent));
    check('tag3 = {1: rich}', Qq8Pb.bytesAt(Qq8Pb.decode(Qq8Pb.bytesAt(m, 3)!), 1) != null);
    check('tag4 = 消息 seq（= 包序号）', Qq8Pb.intAt(m, 4) == 321);
    check('tag5 = rand', Qq8Pb.intAt(m, 5) == 0x11223344);

    final cookie = Qq8Pb.decode(Qq8Pb.bytesAt(m, 6)!);
    check('cookie：1/2/13 = 时间，3 = seed，12 = seed&0xff',
        Qq8Pb.intAt(cookie, 1) == 1700000000 &&
            Qq8Pb.intAt(cookie, 2) == 1700000000 &&
            Qq8Pb.intAt(cookie, 3) == 0x01020304 &&
            Qq8Pb.intAt(cookie, 12) == 0x04 &&
            Qq8Pb.intAt(cookie, 13) == 1700000000);
    check('cookie：4 = 0xffffffff - seed、5/9/11 = 注入的随机',
        Qq8Pb.intAt(cookie, 4) == 0xFEFDFCFB &&
            Qq8Pb.intAt(cookie, 5) == 0x11111111 &&
            Qq8Pb.intAt(cookie, 9) == 0x22222222 &&
            Qq8Pb.intAt(cookie, 11) == 0x33333333);
  }

  // ----------------------------------------------------------------
  section('4. 内核：群聊请求体（与私聊的差异）');
  {
    final body = Qq8Msg.buildGroupTextBody(
      gid: 987654321,
      elems: <Uint8List>[Qq8Msg.textElem('group hi')],
      rand16: 0xABCD,
      rand32: 0x55667788,
    );
    final m = Qq8Pb.decode(body);
    final route = Qq8Pb.decode(Qq8Pb.bytesAt(m, 1)!);
    // 官方 pb 定义（msf.msgsvc.msg_svc.RoutingHead 的 __fieldMap__）：
    // 1=c2c / 2=grp(group_code) / 4=dis(dis_uin，讨论组)。普通群走 2。
    check('路由 {1:{2:{1:gid}}}（群用 grp=tag2，不是讨论组的 tag4）',
        Qq8Pb.intAt(Qq8Pb.decode(Qq8Pb.bytesAt(route, 2)!), 1) == 987654321);
    check('路由里没有讨论组字段 tag4', Qq8Pb.bytesAt(route, 4) == null);
    check('tag4 = u16 随机', Qq8Pb.intAt(m, 4) == 0xABCD);
    check('tag5 = u32 随机', Qq8Pb.intAt(m, 5) == 0x55667788);
    check('群聊没有同步 cookie（tag6 不在）', Qq8Pb.bytesAt(m, 6) == null);
    check('群聊多一个 tag8 = 0', Qq8Pb.intAt(m, 8) == 0);
  }

  // ----------------------------------------------------------------
  section('5. 内核：响应解析与群号变换');
  {
    final okRsp = Qq8Pb.encode(<int, Object?>{1: 0, 2: '', 3: 1700000123});
    final ok = Qq8Msg.parseSendResponse(okRsp, seq: 7, rand: 8);
    check('成功码 0 与时间解出', ok.ok && ok.time == 1700000123, '${ok.time}');

    final failRsp = Qq8Pb.encode(<int, Object?>{1: 4, 2: '发送失败：对方拒绝', 3: 0});
    final fail = Qq8Msg.parseSendResponse(failRsp, seq: 1, rand: 2);
    check('失败码与文案解出', !fail.ok && fail.code == 4 && fail.message.contains('发送失败'),
        '${fail.code} ${fail.message}');

    check('code2uin：0..10 段 +202',
        Qq8Msg.code2uin(1000000) == 203000000, '${Qq8Msg.code2uin(1000000)}');
    check('code2uin：387..499 段 +3490',
        Qq8Msg.code2uin(400123456) == 3890123456, '${Qq8Msg.code2uin(400123456)}');
  }

  // ----------------------------------------------------------------
  section('6. 服务层：上线后发私聊（脚本传输）');
  {
    final scripted = Qq8ScriptedTransport(<Uint8List>[
      _successFrame(1),
      _registerFrame(1),
      _frame(2, 'MessageSvc.PbSendMsg', Qq8Pb.encode(<int, Object?>{1: 0, 3: 1700000999})),
      _frame(3, 'MessageSvc.PbSendMsg',
          Qq8Pb.encode(<int, Object?>{1: 4, 2: '对方已把你拉黑'})),
    ]);
    final svc = Qq8LoginService(
      tokenStore: _MemStore()
        ..data = Qq8TokenData(
          uin: 10001,
          savedAt: 'test',
          tgt: _hex('1122334455667788'),
          d2: _hex('a2' * 64),
          d2key: _d2key,
          sigKey: _hex('a4' * 48),
          ticketKey: _hex('a5' * 16),
          srmToken: _hex('a6' * 56),
        ),
      deviceBuilder: _fixtureDevice,
      ecdhBuilder: () => _fixedEcdh,
      transportBuilder: () => scripted,
      timeout: const Duration(seconds: 5),
    );

    await svc.loginWithToken(uin: 10001);
    check('已上线可以发消息', svc.snapshot.stage == Qq8LoginStage.online,
        svc.snapshot.stage.name);

    final r1 = await svc.sendC2c(
      uid: 12345,
      elems: <Uint8List>[Qq8Msg.textElem('hello from penguin')],
    );
    check('发送成功（code=0）并拿到服务端时间',
        r1.ok && r1.time == 1700000999, 'code=${r1.code} time=${r1.time}');
    check('seq 分配了（私聊用包序号当消息序号）', r1.seq > 0, '${r1.seq}');

    // 核对真实发出的包：命令字 + body 结构
    final (cmd, body) = _uniParts(scripted.sent[2]);
    check('发出的命令字 = MessageSvc.PbSendMsg', cmd == 'MessageSvc.PbSendMsg', cmd);
    final m = Qq8Pb.decode(body);
    check('body 里 tag4 == 包序号（参考实现同款）', Qq8Pb.intAt(m, 4) == r1.seq,
        'tag4=${Qq8Pb.intAt(m, 4)} seq=${r1.seq}');
    final rich = Qq8Pb.decode(Qq8Pb.bytesAt(Qq8Pb.decode(Qq8Pb.bytesAt(m, 3)!), 1)!);
    final elems = rich[2] as List<Object>;
    final textElem = Qq8Pb.decode(elems[0] as Uint8List);
    check('body 里就是我们发的那句话',
        Qq8Pb.textAt(Qq8Pb.decode(Qq8Pb.bytesAt(textElem, 1)!), 1) ==
            'hello from penguin');
    check('body 末尾带保留元素',
        _hexOf(elems[1] as Uint8List) == _hexOf(Qq8Msg.pbReserver));

    final r2 = await svc.sendC2c(
      uid: 12345,
      elems: <Uint8List>[Qq8Msg.textElem('再来一条')],
    );
    check('服务端拒绝时把原因带出来',
        !r2.ok && r2.code == 4 && r2.message.contains('拉黑'),
        '${r2.code} ${r2.message}');
    await svc.close();
  }

  // ----------------------------------------------------------------
  section('7. 服务层：未上线不能发');
  {
    final svc = Qq8LoginService(
      tokenStore: _MemStore(),
      deviceBuilder: _fixtureDevice,
      ecdhBuilder: () => _fixedEcdh,
      transportBuilder: () => Qq8ScriptedTransport(<Uint8List>[]),
    );
    var threw = false;
    try {
      await svc.sendC2c(uid: 1, elems: <Uint8List>[Qq8Msg.textElem('x')]);
    } on Qq8NotOnlineException catch (e) {
      threw = e.message.contains('还没上线');
    }
    check('未上线抛 Qq8NotOnlineException 并说明原因', threw);
    await svc.close();
  }

  // ----------------------------------------------------------------
  section('8. 撤回与已读上报（字段号照官方 pb 定义）');
  {
    // 消息 ID 反解：与生成互逆
    final dmId = Qq8Msg.dmMessageId(
        peerUin: 22222, seq: 321, rand: 0x11223344, time: 1700000500, outgoing: true);
    final dm = Qq8Msg.parseDmMessageId(dmId);
    check('私聊 ID 反解（对方/seq/rand/time/flag）',
        dm != null &&
            dm.peerUin == 22222 &&
            dm.seq == 321 &&
            dm.rand == 0x11223344 &&
            dm.time == 1700000500 &&
            dm.flag == 1,
        '$dm');
    final gpId = Qq8Msg.groupMessageId(
        gid: 987654321, senderUin: 10001, seq: 777, rand: 0x55667788, time: 1700000600);
    final gp = Qq8Msg.parseGroupMessageId(gpId);
    check('群 ID 反解（群号/发送者/seq/rand/time/pktnum）',
        gp != null &&
            gp.gid == 987654321 &&
            gp.senderUin == 10001 &&
            gp.seq == 777 &&
            gp.rand == 0x55667788 &&
            gp.pktNum == 1,
        '$gp');
    check('乱码 ID 反解返回 null（不抛）',
        Qq8Msg.parseDmMessageId('不是base64!') == null &&
            Qq8Msg.parseGroupMessageId('') == null);

    // msg_uid 重建：高位固定 16777216 << 32（参考实现 rand2uuid 同款）
    check('rand2uuid：高位固定 + 低 32 位是 rand',
        Qq8Msg.rand2uuid(0x11223344) == ((16777216 << 32) | 0x11223344));

    // 私聊撤回：外层 1 → PbC2CMsgWithDrawReq{1: MsgInfo, 2: long_flag}
    final c2c = Qq8Msg.buildC2cWithdrawBody(
        selfUin: 10001, peerUin: 22222, seq: 321, rand: 0x11223344, time: 1700000500);
    final c2cOuter = Qq8Pb.decode(c2c);
    final c2cReq = Qq8Pb.decode(Qq8Pb.bytesAt(c2cOuter, 1)!);
    final msgInfo = Qq8Pb.decode(Qq8Pb.bytesAt(c2cReq, 1)!);
    check('私聊撤回：外层字段 1 = 私聊分支，msg_info 六项齐全',
        Qq8Pb.intAt(msgInfo, 1) == 10001 &&
            Qq8Pb.intAt(msgInfo, 2) == 22222 &&
            Qq8Pb.intAt(msgInfo, 3) == 321 &&
            Qq8Pb.intAt(msgInfo, 4) == Qq8Msg.rand2uuid(0x11223344) &&
            Qq8Pb.intAt(msgInfo, 5) == 1700000500 &&
            Qq8Pb.intAt(msgInfo, 6) == 0x11223344,
        '');
    check('私聊撤回：long_message_flag = 0（tag2 值为 0 → 编码省略也是 0）',
        (Qq8Pb.intAt(c2cReq, 2) ?? 0) == 0);

    // 群撤回：外层 2 → {1: sub_cmd=1, 3: gid, 4: {1: seq, 2: rand}}
    final grp = Qq8Msg.buildGroupWithdrawBody(gid: 987654321, seq: 777, rand: 0x55667788);
    final grpOuter = Qq8Pb.decode(grp);
    check('群撤回：只有外层字段 2（群分支）', Qq8Pb.bytesAt(grpOuter, 2) != null &&
        Qq8Pb.bytesAt(grpOuter, 1) == null);
    final grpReq = Qq8Pb.decode(Qq8Pb.bytesAt(grpOuter, 2)!);
    final grpMsg = Qq8Pb.decode(Qq8Pb.bytesAt(grpReq, 4)!);
    check('群撤回：sub_cmd=1 / group_code / msg_list{seq, rand}',
        Qq8Pb.intAt(grpReq, 1) == 1 &&
            Qq8Pb.intAt(grpReq, 3) == 987654321 &&
            Qq8Pb.intAt(grpMsg, 1) == 777 &&
            Qq8Pb.intAt(grpMsg, 2) == 0x55667788,
        '');

    // 撤回响应（与请求同构）
    final okResp = Qq8Pb.encode({
      1: Qq8Pb.encode({1: 0, 2: ''}),
      2: Qq8Pb.encode({1: 0, 2: ''}),
    });
    check('响应解析：私聊/群都取到 result=0',
        Qq8Msg.parseWithdrawResponse(okResp, group: false).result == 0 &&
            Qq8Msg.parseWithdrawResponse(okResp, group: true).result == 0);
    final failResp = Qq8Pb.encode({
      1: Qq8Pb.encode({1: 5, 2: '消息不存在'}),
    });
    final f = Qq8Msg.parseWithdrawResponse(failResp, group: false);
    check('失败响应：result + 文案带出', f.result == 5 && f.errmsg == '消息不存在');
    check('缺分支的响应：result=-1 且说明',
        Qq8Msg.parseWithdrawResponse(failResp, group: true).result == -1);

    // 已读上报
    final c2cRead = Qq8Pb.decode(
        Qq8Msg.buildC2cReadReportBody(peerUin: 22222, lastReadTime: 1700000500));
    final c2cReport = Qq8Pb.decode(Qq8Pb.bytesAt(c2cRead, 3)!);
    final pair = Qq8Pb.decode(Qq8Pb.bytesAt(c2cReport, 2)!);
    check('私聊已读：3 → 2 → UinPairReadInfo{peer_uin, last_read_time}',
        Qq8Pb.intAt(pair, 1) == 22222 && Qq8Pb.intAt(pair, 2) == 1700000500,
        '');
    final grpRead = Qq8Pb.decode(
        Qq8Msg.buildGroupReadReportBody(gid: 987654321, lastReadSeq: 777));
    final grpReport = Qq8Pb.decode(Qq8Pb.bytesAt(grpRead, 1)!);
    check('群已读：1 → {group_code, last_read_seq}',
        Qq8Pb.intAt(grpReport, 1) == 987654321 &&
            Qq8Pb.intAt(grpReport, 2) == 777,
        '');
  }

  // ----------------------------------------------------------------
  section('9. 引用回复（src_msg 元素，字段照官方 SourceMsg）');
  {
    final reply = Qq8ReplyInfo(
        seq: 321, senderUin: 22222, time: 1700000500, preview: '被引用的话');
    final rich = Qq8Pb.decode(Qq8Msg.textRich('收到', reply: reply));
    final elems = (rich[2] as List<Object?>);
    check('引用时 elems = [src_msg, 文本, 保留元素]（3 个）', elems.length == 3,
        '${elems.length}');
    final src = Qq8Pb.decode(elems.first as Uint8List);
    final m45 = Qq8Pb.decode(Qq8Pb.bytesAt(src, 45)!);
    check('src_msg：seq/发送者/时间/flag/type',
        Qq8Pb.intAt(m45, 1) == 321 &&
            Qq8Pb.intAt(m45, 2) == 22222 &&
            Qq8Pb.intAt(m45, 3) == 1700000500 &&
            Qq8Pb.intAt(m45, 4) == 1 &&
            (Qq8Pb.intAt(m45, 6) ?? 0) == 0,
        '');
    final quoted = (m45[5] as List<Object?>).first as Uint8List;
    final quotedText = Qq8Pb.decode(Qq8Pb.bytesAt(Qq8Pb.decode(quoted), 1)!);
    check('src_msg 的元素里带着引用原文',
        Qq8Pb.textAt(quotedText, 1) == '被引用的话');

    final plain = Qq8Pb.decode(Qq8Msg.textRich('普通'));
    check('不引用时 elems = [文本, 保留元素]（2 个，行为不变）',
        (plain[2] as List<Object?>).length == 2);

    final c2cBody = Qq8Msg.buildC2cTextBody(
      uid: 22222,
      elems: <Uint8List>[Qq8Msg.textElem('收到')],
      seq: 1,
      rand: 2,
      syncCookieSeed: 3,
      nowSeconds: 4,
      syncR5: 5,
      syncR9: 6,
      syncR11: 7,
      reply: reply,
    );
    final c2cRich = Qq8Pb.decode(
        Qq8Pb.bytesAt(Qq8Pb.decode(Qq8Pb.bytesAt(Qq8Pb.decode(c2cBody), 3)!), 1)!);
    final c2cFirst = (c2cRich[2] as List<Object?>).first as Uint8List;
    check('私聊发送体里带上了 src_msg',
        Qq8Pb.bytesAt(Qq8Pb.decode(c2cFirst), 45) != null);

    final grpBody = Qq8Msg.buildGroupTextBody(
      gid: 987654321,
      elems: <Uint8List>[Qq8Msg.textElem('收到')],
      rand16: 1,
      rand32: 2,
      reply: reply,
    );
    final grpRich = Qq8Pb.decode(
        Qq8Pb.bytesAt(Qq8Pb.decode(Qq8Pb.bytesAt(Qq8Pb.decode(grpBody), 3)!), 1)!);
    final grpFirst = (grpRich[2] as List<Object?>).first as Uint8List;
    check('群发送体里也带上了（第 1 个元素就是 src_msg）',
        Qq8Pb.bytesAt(Qq8Pb.decode(grpFirst), 45) != null);
  }

  // ----------------------------------------------------------------
  section('10. 表情元素（字段号照参考实现 converter.ts 的 face()）');
  {
    // 小表情：Elem.face{1: id, 2: 旧码 u16, 11: 固定尾巴}
    final small = Qq8Pb.decode(Qq8Msg.faceElem(14));
    final face = Qq8Pb.decode(Qq8Pb.bytesAt(small, 2)!);
    check('小表情走 Elem.face（字段 2）', Qq8Pb.bytesAt(small, 2) != null);
    check('face.id = 14', Qq8Pb.intAt(face, 1) == 14, '${Qq8Pb.intAt(face, 1)}');
    final old = Qq8Pb.bytesAt(face, 2)!;
    check('旧版表情码 = 0x1441 + id（u16 大端）',
        old.length == 2 && ((old[0] << 8) | old[1]) == 0x1441 + 14,
        old.map((b) => b.toRadixString(16)).join());
    final tail = Qq8Pb.bytesAt(face, 11)!;
    check('兼容尾巴 = FACE_OLD_BUF（逐字节）',
        tail.length == 8 &&
            tail[0] == 0x00 &&
            tail[1] == 0x01 &&
            tail[2] == 0x00 &&
            tail[3] == 0x04 &&
            tail[7] == 0xD0,
        tail.map((b) => b.toRadixString(16).padLeft(2, '0')).join());

    // 超级表情（id > 0xFF）：Elem.common_elem{1: 33, 2: Face{id, 名字}, 3: 1}
    final big = Qq8Pb.decode(Qq8Msg.faceElem(271));
    final common = Qq8Pb.decode(Qq8Pb.bytesAt(big, 53)!);
    check('超级表情走 common_elem（字段 53）且 serviceType=33',
        Qq8Pb.intAt(common, 1) == 33, '${Qq8Pb.intAt(common, 1)}');
    final inner = Qq8Pb.decode(Qq8Pb.bytesAt(common, 2)!);
    check('pb_elem 里 id=271、名字=/吃瓜（服务端要回显的文案）',
        Qq8Pb.intAt(inner, 1) == 271 &&
            Qq8Pb.textAt(inner, 2) == '/吃瓜' &&
            Qq8Pb.textAt(inner, 3) == '/吃瓜',
        '${Qq8Pb.intAt(inner, 1)} ${Qq8Pb.textAt(inner, 2)}');
    check('business_type = 1', Qq8Pb.intAt(common, 3) == 1);

    // 有序组装：文本 / 表情 / 文本 的顺序原样保留
    final rich = Qq8Pb.decode(Qq8Msg.richElems(<Uint8List>[
      Qq8Msg.textElem('笑一个'),
      Qq8Msg.faceElem(14),
      Qq8Msg.textElem('吧'),
    ]));
    final elems = (rich[2] as List<Object?>).cast<Uint8List>();
    check('richElems 顺序 = 文本/表情/文本（不重排）',
        elems.length == 4 && // 3 个内容元素 + 保留元素
            Qq8Pb.textAt(Qq8Pb.decode(Qq8Pb.bytesAt(Qq8Pb.decode(elems[0]), 1)!), 1) ==
                '笑一个' &&
            Qq8Pb.bytesAt(Qq8Pb.decode(elems[1]), 2) != null &&
            Qq8Pb.textAt(Qq8Pb.decode(Qq8Pb.bytesAt(Qq8Pb.decode(elems[2]), 1)!), 1) ==
                '吧',
        '${elems.length} 个元素');
    check('末尾仍是保留元素（逐字节）',
        _hexOf(elems.last) == _hexOf(Qq8Msg.pbReserver));

    // 表情 + 引用：引用元素排在最前（quote 语义就是"这条消息引用了谁"）
    final reply = Qq8ReplyInfo(seq: 5, senderUin: 22222, time: 1700000400, preview: '原话');
    final withReply = Qq8Pb.decode(Qq8Msg.richElems(
      <Uint8List>[Qq8Msg.faceElem(14)],
      reply: reply,
    ));
    final rElems = (withReply[2] as List<Object?>).cast<Uint8List>();
    check('带引用时：src_msg 在最前，表情在后',
        Qq8Pb.bytesAt(Qq8Pb.decode(rElems.first), 45) != null &&
            Qq8Pb.bytesAt(Qq8Pb.decode(rElems[1]), 2) != null &&
            rElems.length == 3,
        '${rElems.length} 个元素');
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
