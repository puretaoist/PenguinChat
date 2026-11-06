/// NT 富媒体（0x126d / 0xfd4）组包与解析的离线自测。
///
/// 只测纯函数：请求字段号、uid 映射抽取、回执拆壳、MsgInfo 切分、highway ext、
/// 消息元素。真实上行（申请 + 传输 + 对端能播）必须真机验证——
/// 这条链路的坑全在「文件有没有被服务端登记」，离线测不出来。
///
/// 跑：`dart run tool/qq8_ntv2_selftest.dart`
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/kernel/wlogin8/qq8_ntv2.dart';
import 'package:penguinchat/kernel/wlogin8/qq8_pb.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    stdout.writeln('  [OK] $name');
  } else {
    _fail++;
    stdout.writeln('  [FAIL] $name${detail.isEmpty ? '' : ' — $detail'}');
  }
}

void checkEq(String name, Object? actual, Object? expected) =>
    check(name, actual == expected, '期望 $expected，实际 $actual');

bool eqBytes(Object? a, Object? b) {
  if (a is! List<int> || b is! List<int>) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 十六进制串 → 字节。
Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  stdout.writeln('== qq8_ntv2 自测 ==');

  // ── 好友 uid 拉取（0xfd4_1）────────────────────────────────
  {
    final body = Qq8Pb.decode(Qq8Ntv2.buildFriendUidPullBody());
    checkEq('uid 拉取 2=req_count(300)', Qq8Pb.intAt(body, 2), 300);
    checkEq('uid 拉取 4=local_seq(13)', Qq8Pb.intAt(body, 4), 13);
    checkEq('uid 拉取 6=flag(1)', Qq8Pb.intAt(body, 6), 1);
    checkEq('uid 拉取 7=proxy_seq(max)', Qq8Pb.intAt(body, 7), 0x7FFFFFFF);
    checkEq('uid 拉取 10001 两组 biz', body[10001]?.length, 2);
    final biz0 = Qq8Pb.decode(body[10001]![0] as Uint8List);
    checkEq('uid 拉取 10001[0].1=1', Qq8Pb.intAt(biz0, 1), 1);
    final keys = Qq8Pb.decode(Qq8Pb.bytesAt(biz0, 2)!).values.first;
    checkEq('uid 拉取 10001[0] 有 6 个 key', keys.length, 6);
    checkEq('uid 拉取 10002 五个 sns key', body[10002]?.length, 5);
    check('uid 拉取 10003 含 4051', body[10003]!.contains(4051));
  }

  // ── uid 映射解析 ───────────────────────────────────────────
  {
    final payload = Qq8Pb.encode(<int, Object?>{
      3: 0,
      4: Qq8Pb.encode(<int, Object?>{
        101: <Object?>[
          Qq8Pb.encode(<int, Object?>{1: 'u_abcDEF', 2: 0, 3: 777}),
          Qq8Pb.encode(<int, Object?>{1: 'u_xyz', 2: 1, 3: 888}),
          // 缺 uid 的项要被丢掉（不能塞进表）
          Qq8Pb.encode(<int, Object?>{3: 999}),
        ],
      }),
    });
    final map = Qq8Ntv2.parseFriendUidPull(payload);
    checkEq('uid 映射条数（丢掉缺 uid 的）', map.length, 2);
    checkEq('uid 映射 777', map[777], 'u_abcDEF');
    checkEq('uid 映射 888', map[888], 'u_xyz');
    checkEq(
      'uid 映射：无 101 时为空表',
      Qq8Ntv2.parseFriendUidPull(Qq8Pb.encode(<int, Object?>{4: Uint8List(0)}))
          .length,
      0,
    );
    var threw = false;
    try {
      Qq8Ntv2.parseFriendUidPull(
        Qq8Pb.encode(<int, Object?>{
          3: 45,
          4: Uint8List.fromList(<int>[0x08, 0x01]),
        }),
      );
    } catch (_) {
      threw = true;
    }
    check('uid 映射：OIDB result!=0 要抛（不静默空表）', threw);
  }

  // ── 上传申请组包（0x126d_100）──────────────────────────────
  {
    final raw = Qq8Ntv2.buildUploadPttBody(
      targetUid: 'u_target01',
      fileSize: 12345,
      md5Hex: 'aabbccdd',
      sha1Hex: '0011223344',
      fileName: 'aabbccdd.silk',
      seconds: 3,
      clientRandomId: 998877,
    );
    final req = Qq8Pb.decode(raw);
    final head = Qq8Pb.decode(Qq8Pb.bytesAt(req, 1)!);
    final common = Qq8Pb.decode(Qq8Pb.bytesAt(head, 1)!);
    checkEq('申请 head.common.1=request_id(1)', Qq8Pb.intAt(common, 1), 1);
    checkEq('申请 head.common.2=command(100)', Qq8Pb.intAt(common, 2), 100);
    final scene = Qq8Pb.decode(Qq8Pb.bytesAt(head, 2)!);
    checkEq('申请 scene.101=request_type(2)', Qq8Pb.intAt(scene, 101), 2);
    checkEq('申请 scene.102=business_type(3)', Qq8Pb.intAt(scene, 102), 3);
    checkEq('申请 scene.200=scene_type(1)', Qq8Pb.intAt(scene, 200), 1);
    final c2c = Qq8Pb.decode(Qq8Pb.bytesAt(scene, 201)!);
    checkEq('申请 c2c.1=account_type(2)', Qq8Pb.intAt(c2c, 1), 2);
    checkEq('申请 c2c.2=target_uid', Qq8Pb.textAt(c2c, 2), 'u_target01');

    // accountType=1 + uin 是本项目实际走的组合（真机 2026-11-05 实测通过）
    final rawUin = Qq8Ntv2.buildUploadPttBody(
      targetUid: '2089495846',
      accountType: 1,
      fileSize: 2615,
      md5Hex: 'b7572aa1b2d7ab3aea1f0617b683ccc7',
      sha1Hex: '977bc5c87104c35b62fd220325e84fb9d3c94151',
      fileName: 'b7572aa1b2d7ab3aea1f0617b683ccc7.silk',
      seconds: 2,
      clientRandomId: 1,
    );
    final reqUin = Qq8Pb.decode(rawUin);
    final headUin = Qq8Pb.decode(Qq8Pb.bytesAt(reqUin, 1)!);
    final sceneUin = Qq8Pb.decode(Qq8Pb.bytesAt(headUin, 2)!);
    final c2cUin = Qq8Pb.decode(Qq8Pb.bytesAt(sceneUin, 201)!);
    checkEq('申请 c2c.1=account_type(1) + uin 组合', Qq8Pb.intAt(c2cUin, 1), 1);
    checkEq('申请 c2c.2=uin 数字串', Qq8Pb.textAt(c2cUin, 2), '2089495846');
    final client = Qq8Pb.decode(Qq8Pb.bytesAt(head, 3)!);
    checkEq('申请 head.client.1=agent_type(2)', Qq8Pb.intAt(client, 1), 2);

    final upload = Qq8Pb.decode(Qq8Pb.bytesAt(req, 2)!);
    final info0 = Qq8Pb.decode(upload[1]!.first as Uint8List);
    final fi = Qq8Pb.decode(Qq8Pb.bytesAt(info0, 1)!);
    checkEq('申请 file.size=12345', Qq8Pb.intAt(fi, 1), 12345);
    checkEq('申请 file.md5', Qq8Pb.textAt(fi, 2), 'aabbccdd');
    checkEq('申请 file.sha1', Qq8Pb.textAt(fi, 3), '0011223344');
    checkEq('申请 file.name', Qq8Pb.textAt(fi, 4), 'aabbccdd.silk');
    final ft = Qq8Pb.decode(Qq8Pb.bytesAt(fi, 5)!);
    checkEq('申请 file.type=3(语音)', Qq8Pb.intAt(ft, 1), 3);
    checkEq('申请 file.voice_format=1(SILK)', Qq8Pb.intAt(ft, 4), 1);
    checkEq('申请 file.time=秒', Qq8Pb.intAt(fi, 8), 3);
    checkEq('申请 upload_info.2=sub_file_type(0)', Qq8Pb.intAt(info0, 2), 0);
    checkEq('申请 2=try_fast_upload(1)', Qq8Pb.intAt(upload, 2), 1);
    checkEq('申请 3=srv_send_msg(0)', Qq8Pb.intAt(upload, 3), 0);
    checkEq('申请 4=client_random_id', Qq8Pb.intAt(upload, 4), 998877);
    checkEq('申请 5=compat_scene(1)', Qq8Pb.intAt(upload, 5), 1);
    checkEq('申请 7=client_seq(10)', Qq8Pb.intAt(upload, 7), 10);
    checkEq('申请 8=no_need_compat(0)', Qq8Pb.intAt(upload, 8), 0);
    final extBiz = Qq8Pb.decode(Qq8Pb.bytesAt(upload, 6)!);
    final ptt = Qq8Pb.decode(Qq8Pb.bytesAt(extBiz, 3)!);
    check(
      '申请 ext.ptt.11 bytes_reserve=08 00 38 00',
      eqBytes(Qq8Pb.bytesAt(ptt, 11), <int>[0x08, 0x00, 0x38, 0x00]),
    );
    check(
      '申请 ext.ptt.13 general_flags 14 字节',
      Qq8Pb.bytesAt(ptt, 13)?.length == 14,
    );

    var threw = false;
    try {
      Qq8Ntv2.buildUploadPttBody(
        targetUid: '',
        fileSize: 1,
        md5Hex: 'aa',
        sha1Hex: 'bb',
        fileName: 'x.silk',
        seconds: 1,
        clientRandomId: 1,
      );
    } catch (_) {
      threw = true;
    }
    check('申请：空 targetUid 要抛（0x126d 私聊必须 uid）', threw);
  }

  // ── 群语音上传申请组包（0x126e_100）────────────────────────
  {
    final raw = Qq8Ntv2.buildUploadGroupPttBody(
      groupUin: 486045673,
      fileSize: 2615,
      md5Hex: 'b7572aa1b2d7ab3aea1f0617b683ccc7',
      sha1Hex: '977bc5c87104c35b62fd220325e84fb9d3c94151',
      fileName: 'b7572aa1b2d7ab3aea1f0617b683ccc7.silk',
      seconds: 2,
      clientRandomId: 424242,
    );
    final req = Qq8Pb.decode(raw);
    final head = Qq8Pb.decode(Qq8Pb.bytesAt(req, 1)!);
    final common = Qq8Pb.decode(Qq8Pb.bytesAt(head, 1)!);
    checkEq('群申请 head.common.2=command(100)', Qq8Pb.intAt(common, 2), 100);
    final scene = Qq8Pb.decode(Qq8Pb.bytesAt(head, 2)!);
    checkEq('群申请 scene.101=request_type(2)', Qq8Pb.intAt(scene, 101), 2);
    checkEq('群申请 scene.102=business_type(3)', Qq8Pb.intAt(scene, 102), 3);
    checkEq('群申请 scene.200=scene_type(2)', Qq8Pb.intAt(scene, 200), 2);
    check('群申请 scene 不带 201(C2C)', Qq8Pb.bytesAt(scene, 201) == null);
    final grp = Qq8Pb.decode(Qq8Pb.bytesAt(scene, 202)!);
    checkEq('群申请 scene.202.group_uin', Qq8Pb.intAt(grp, 1), 486045673);
    final upload = Qq8Pb.decode(Qq8Pb.bytesAt(req, 2)!);
    checkEq('群申请 upload.5=compat_scene(2)', Qq8Pb.intAt(upload, 5), 2);
    checkEq('群申请 upload.4=client_random_id', Qq8Pb.intAt(upload, 4), 424242);
    final fi = Qq8Pb.decode(
      Qq8Pb.bytesAt(Qq8Pb.decode(upload[1]!.first as Uint8List), 1)!,
    );
    checkEq('群申请 file.size', Qq8Pb.intAt(fi, 1), 2615);
    checkEq('群申请 file.time(秒)', Qq8Pb.intAt(fi, 8), 2);
    final extBiz = Qq8Pb.decode(Qq8Pb.bytesAt(upload, 6)!);
    final ptt = Qq8Pb.decode(Qq8Pb.bytesAt(extBiz, 3)!);
    check('群申请 ext.ptt 不带 11 bytes_reserve', Qq8Pb.bytesAt(ptt, 11) == null);
    check(
      '群申请 ext.ptt.12 bytes_pb_reserve=08 00 38 00',
      eqBytes(Qq8Pb.bytesAt(ptt, 12), <int>[0x08, 0x00, 0x38, 0x00]),
    );
    check(
      '群申请 ext.ptt.13 general_flags 10 字节',
      Qq8Pb.bytesAt(ptt, 13)?.length == 10,
    );
    check('群申请 ext.ptt.13 末字节 0x00', Qq8Pb.bytesAt(ptt, 13)?.last == 0x00);
    checkEq('群申请命令名', Qq8Ntv2.cmdUploadGroupPtt, 'OidbSvcTrpcTcp.0x126e_100');
    checkEq('群申请 oidb 号', Qq8Ntv2.oidbUploadGroupPtt, 0x126e);

    var threw = false;
    try {
      Qq8Ntv2.buildUploadGroupPttBody(
        groupUin: 0,
        fileSize: 1,
        md5Hex: 'aa',
        sha1Hex: 'bb',
        fileName: 'x.silk',
        seconds: 1,
        clientRandomId: 1,
      );
    } catch (_) {
      threw = true;
    }
    check('群申请：groupUin<=0 要抛', threw);
  }

  // ── 上传回执解析 ───────────────────────────────────────────
  {
    final msgInfo = Qq8Pb.encode(<int, Object?>{
      1: <Object?>[
        Qq8Pb.encode(<int, Object?>{
          1: Qq8Pb.encode(<int, Object?>{
            1: Qq8Pb.encode(<int, Object?>{3: 'deadbeef'}),
            2: '11111111-2222-3333-4444-555555555555',
          }),
        }),
      ],
    });
    final payload = Qq8Pb.encode(<int, Object?>{
      3: 0,
      4: Qq8Pb.encode(<int, Object?>{
        1: Qq8Pb.encode(<int, Object?>{2: 0}),
        2: Qq8Pb.encode(<int, Object?>{
          1: 'UKEY-UKEY',
          2: 3600,
          3: <Object?>[
            Qq8Pb.encode(<int, Object?>{1: 0x0100007F, 2: 8080}),
          ],
          6: msgInfo,
          8: Uint8List.fromList(<int>[0x08, 0x01]),
        }),
      }),
    });
    final ticket = Qq8Ntv2.parseUploadPttResponse(payload);
    check('回执 ok', ticket.ok);
    checkEq('回执 ukey', ticket.ukey, 'UKEY-UKEY');
    checkEq('回执节点数', ticket.ipv4s.length, 1);
    checkEq('回执节点 IP（第一段在最低字节）', ticket.ipv4s.first.host, '127.0.0.1');
    checkEq('回执节点端口', ticket.ipv4s.first.port, 8080);
    check('回执 msgInfo 原样', eqBytes(ticket.msgInfo, msgInfo));
    check('回执 compat 原样', eqBytes(ticket.compatQMsg, <int>[0x08, 0x01]));

    final bad = Qq8Ntv2.parseUploadPttResponse(
      Qq8Pb.encode(<int, Object?>{3: 45, 5: 'no permission'}),
    );
    check('回执：OIDB result=45 → ok=false', !bad.ok);
    checkEq('回执：message 带出来', bad.message, 'no permission');

    final retErr = Qq8Ntv2.parseUploadPttResponse(
      Qq8Pb.encode(<int, Object?>{
        3: 0,
        4: Qq8Pb.encode(<int, Object?>{
          1: Qq8Pb.encode(<int, Object?>{2: 1007, 3: 'upload denied'}),
          2: Qq8Pb.encode(<int, Object?>{1: ''}),
        }),
      }),
    );
    check('回执：RespHead.ret_code!=0 → ok=false', !retErr.ok);
    checkEq('回执：ret_code 带出来', retErr.result, 1007);
  }

  // ── MsgInfo 切分 ──────────────────────────────────────────
  {
    final sha1Bytes = _hex('00112233');
    final msgInfo = Qq8Pb.encode(<int, Object?>{
      1: <Object?>[
        Qq8Pb.encode(<int, Object?>{
          1: Qq8Pb.encode(<int, Object?>{
            1: Qq8Pb.encode(<int, Object?>{1: 999, 3: '00112233'}),
            2: 'FILE-UUID-36-BYTES-xxxxxxxxxxxxxxxxx',
            4: 1234567,
          }),
          2: Qq8Pb.encode(<int, Object?>{1: 3}),
        }),
      ],
    });
    final split = Qq8Ntv2.splitMsgInfo(msgInfo);
    checkEq(
      '切分 file_uuid',
      split.fileUuid,
      'FILE-UUID-36-BYTES-xxxxxxxxxxxxxxxxx',
    );
    checkEq('切分 sha1', split.sha1Hex, '00112233');
    checkEq('切分 body 数', split.bodies.length, 1);
    check(
      '切分 body 原样',
      eqBytes(
        split.bodies.first,
        Uint8List.fromList(Qq8Pb.decode(msgInfo)[1]!.first as List<int>),
      ),
    );
    check('hexToBytes 往返', eqBytes(hexToBytes('00112233'), sha1Bytes));

    var threw = false;
    try {
      Qq8Ntv2.splitMsgInfo(Qq8Pb.encode(<int, Object?>{2: 1}));
    } catch (_) {
      threw = true;
    }
    check('切分：缺 1 要抛', threw);

    var threwOdd = false;
    try {
      hexToBytes('abc');
    } catch (_) {
      threwOdd = true;
    }
    check('hexToBytes：奇数长度要抛', threwOdd);
  }

  // ── highway ext + 消息元素 ─────────────────────────────────
  {
    final sha1 = _hex('aabbcc');
    final ext = Qq8Pb.decode(
      Qq8Ntv2.buildHighwayExt(
        fileUuid: 'UUID-1',
        ukey: 'UKEY-1',
        endpoints: const <Qq8Ntv2Endpoint>[
          Qq8Ntv2Endpoint('10.0.0.1', 80),
          Qq8Ntv2Endpoint('10.0.0.2', 443),
        ],
        msgInfoBodies: <Uint8List>[
          Qq8Pb.encode(<int, Object?>{1: 1}),
          Qq8Pb.encode(<int, Object?>{1: 2}),
        ],
        sha1Hex: 'aabbcc',
      ),
    );
    checkEq('ext.1=file_uuid', Qq8Pb.textAt(ext, 1), 'UUID-1');
    checkEq('ext.2=ukey', Qq8Pb.textAt(ext, 2), 'UKEY-1');
    checkEq('ext.6 两个 msg_info_body', ext[6]?.length, 2);
    checkEq('ext.10=block_size(1MiB)', Qq8Pb.intAt(ext, 10), 1048576);
    final net = Qq8Pb.decode(Qq8Pb.bytesAt(ext, 5)!);
    final hosts = net[1]!;
    checkEq('ext.5 两个节点', hosts.length, 2);
    final h0raw = Qq8Pb.decode(hosts[0] as Uint8List);
    final h0 = Qq8Pb.decode(Qq8Pb.bytesAt(h0raw, 1)!);
    checkEq('ext.5[0].1.1=is_domain(1)', Qq8Pb.intAt(h0, 1), 1);
    checkEq('ext.5[0].1.2=ip', Qq8Pb.textAt(h0, 2), '10.0.0.1');
    checkEq('ext.5[0].2=port', Qq8Pb.intAt(h0raw, 2), 80);
    final hash = Qq8Pb.decode(Qq8Pb.bytesAt(ext, 11)!);
    check('ext.11.1[0]=sha1 原始字节', eqBytes(hash[1]!.first, sha1));

    // 消息元素
    final msgInfo = Qq8Pb.encode(<int, Object?>{
      1: <Object?>[
        Qq8Pb.encode(<int, Object?>{1: 1}),
      ],
    });
    final elem = Qq8Pb.decode(Qq8Ntv2.buildPttMsgElem(msgInfo));
    final common = Qq8Pb.decode(Qq8Pb.bytesAt(elem, 53)!);
    checkEq('元素 53.1=service_type(48)', Qq8Pb.intAt(common, 1), 48);
    check('元素 53.2=MsgInfo 原样', eqBytes(Qq8Pb.bytesAt(common, 2), msgInfo));
    checkEq('元素 53.3=业务类型 私聊 12', Qq8Pb.intAt(common, 3), 12);
    final elemGroup = Qq8Pb.decode(
      Qq8Ntv2.buildPttMsgElem(msgInfo, group: true),
    );
    checkEq(
      '元素 53.3=业务类型 群 22',
      Qq8Pb.intAt(Qq8Pb.decode(Qq8Pb.bytesAt(elemGroup, 53)!), 3),
      22,
    );
  }

  // ── IP 转换边界 ───────────────────────────────────────────
  {
    checkEq('ipv4Of(0x0100007F)', Qq8Ntv2.ipv4Of(0x0100007F), '127.0.0.1');
    checkEq('ipv4Of(0x0101A8C0)', Qq8Ntv2.ipv4Of(0x0101A8C0), '192.168.1.1');
    checkEq('ipv4Of 全 FF', Qq8Ntv2.ipv4Of(0xFFFFFFFF), '255.255.255.255');
  }

  stdout.writeln('');
  stdout.writeln('通过 $_pass，失败 $_fail');
  if (_fail > 0) exitCode = 1;
}
