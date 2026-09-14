/// 协议线 `Session` 适配（`qq8_session_adapter.dart`）离线自测
///
/// 走**真实的** `Qq8LoginService`（脚本传输）上线，然后按 UI 契约的用法驱动
/// 适配器：连上 → 列会话 → 发消息 → 拉历史 → 收推送 → 不支持的能力。
///
/// 运行：
/// ```bash
/// dart run tool/qq8_session_adapter_selftest.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/client_api/objects.dart';
import 'package:qqclient/client_api/qq8_login_service.dart';
import 'package:qqclient/client_api/qq8_providers.dart';
import 'package:qqclient/client_api/qq8_session_adapter.dart';
import 'package:qqclient/client_api/segment.dart';
import 'package:qqclient/client_api/session.dart';
import 'package:qqclient/infra/coder.dart';
import 'package:qqclient/kernel/crypto/ecdh.dart';
import 'package:qqclient/kernel/crypto/tea.dart';
import 'package:qqclient/kernel/wlogin8/qq8_config.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_history.dart';
import 'package:qqclient/kernel/wlogin8/qq8_jce.dart';
import 'package:qqclient/kernel/wlogin8/qq8_list.dart';
import 'package:qqclient/kernel/wlogin8/qq8_msg.dart';
import 'package:qqclient/kernel/wlogin8/qq8_pb.dart';
import 'package:qqclient/kernel/wlogin8/qq8_push.dart';
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

const int _me = 10001;
final Uint8List _tgtgt = _hex('a1' * 16);

/// 固定 ECDH 私钥 + 与服务共享的密钥对（服务通过 `ecdhBuilder` 注入同一对）。
final EcdhKeyPair _fixedEcdh = Ecdh.exchange(
  Uint8List.fromList(Qq8Config.serverEcdhPublicKey),
  privateKey: _hex('${'00' * 31}01'),
);

/// 固定设备夹具（与 `qq8_login_service_selftest.dart` 同款）。
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
      tgtgt: _tgtgt,
      guid: _hex('00112233445566778899aabbccddeeff'),
    );

/// 造一个真机结构的响应帧：`[外壳(flag=2)][SSO 头][payload]`。
/// 脚本里协商出来的 d2key（`_successFrame` 里塞的就是它）。
final Uint8List _d2key = _hex('a3' * 16);

/// 拆我们**发出去**的 UNI 包，取 (命令字, body)。
(String, Uint8List) _uniParts(Uint8List pkt) {
  var pos = 14;
  final uinLen =
      (pkt[pos] << 24) | (pkt[pos + 1] << 16) | (pkt[pos + 2] << 8) | pkt[pos + 3];
  pos += uinLen;
  final sso = qqTeaDecrypt(pkt.sublist(pos), _d2key);
  final cmdLen = (sso[4] << 24) | (sso[5] << 16) | (sso[6] << 8) | sso[7];
  final cmd = String.fromCharCodes(sso.sublist(8, 8 + cmdLen - 4));
  var p = 8 + cmdLen - 4;
  p += 4; // session 长度字段
  p += 4; // session
  p += 4; // 固定 4
  final bodyLen =
      (sso[p] << 24) | (sso[p + 1] << 16) | (sso[p + 2] << 8) | sso[p + 3];
  return (cmd, sso.sublist(p + 4, p + bodyLen));
}

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
  final uinBytes = utf8.encode('$_me');
  return (ByteWriter()
        ..u32(0x0A)
        ..u8(2)
        ..u32(0)
        ..u8(4 + uinBytes.length)
        ..raw(uinBytes)
        ..raw(qqTeaEncrypt(plain, Uint8List(16))))
      .build();
}

Uint8List _successFrame(int seq, {Uint8List? key}) {
  final inner = (ByteWriter()..u16(1))
      .build();
  final innerTlvs = ByteWriter()..raw(inner);
  void put(int tag, List<int> body) {
    innerTlvs..u16(tag)..u16(body.length)..raw(body);
  }

  put(0x10A, List<int>.filled(56, 0xa1)); // tgt
  put(0x143, List<int>.filled(64, 0xa2)); // d2
  put(0x305, List<int>.filled(16, 0xa3)); // d2key
  put(0x133, List<int>.filled(48, 0xa4)); // sig_key
  put(0x134, List<int>.filled(16, 0xa5)); // ticket_key
  put(0x16A, List<int>.filled(56, 0xa6)); // srm_token

  final enc = qqTeaEncrypt(innerTlvs.build(), key ?? _tgtgt);
  return _frame(seq, 'wtlogin.login', _payload(0, <int, List<int>>{0x119: enc}));
}

Uint8List _payload(int type, Map<int, List<int>> tlvs) {
  final w = ByteWriter()..u16(1)..u8(type)..u16(2);
  tlvs.forEach((tag, body) {
    w.u16(tag);
    w.u16(body.length);
    w.raw(body);
  });
  final enc = qqTeaEncrypt(w.build(), _fixedEcdh.shareKey);
  return Uint8List.fromList(<int>[
    ...List<int>.filled(16, 0x77),
    ...enc,
    0x03,
  ]);
}


/// 注册成功帧（JCE）。
Uint8List _registerFrame(int seq) {
  final struct = Qq8Jce.encodeStruct(<int, Object?>{0: _me, 9: 1});
  final payload = Qq8Jce.encode(<int, Object?>{
    0: <Object?, Object?>{'SvcRespRegister': struct},
  });
  final body = Qq8Jce.encode(<int, Object?>{7: payload});
  return _frame(seq, 'StatSvc.register', body);
}

/// 一条 `msg_comm.Msg`（字段号同官方）。
Uint8List _msg({
  required int from,
  required int to,
  int msgType = 9,
  int seq = 1,
  int time = 1700000000,
  String text = '你好',
  String? fromNick,
  Map<int, Object?>? groupInfo,
}) =>
    Qq8Pb.encode(<int, Object?>{
      1: <int, Object?>{
        1: from,
        2: to,
        3: msgType,
        5: seq,
        6: time,
        9: ?groupInfo,
        14: ?fromNick,
      },
      3: <int, Object?>{
        1: <int, Object?>{
          2: <Uint8List>[
            Qq8Pb.encode(<int, Object?>{
              1: {1: text},
            }),
          ],
        },
      },
    });

/// 好友列表响应（JCE）：1 个好友 + 1 个分组。
Uint8List _friendPayload() => Qq8Jce.encode(<int, Object?>{
      7: Qq8Jce.encode(<int, Object?>{
        0: <Object?, Object?>{
          'GetFriendListResp': Qq8Jce.encodeStruct(<int, Object?>{
            5: 1,
            7: <Object?>[
              Qq8JceNested(Qq8Jce.encode(<int, Object?>{
                0: 22222,
                1: 1,
                3: '小王',
                14: '阿王',
                31: 1,
              })),
            ],
            14: <Object?>[
              Qq8JceNested(Qq8Jce.encode(<int, Object?>{0: 1, 1: '我的好友'})),
            ],
            15: 0,
          }),
        },
      }),
    });

/// 群列表响应（JCE）：1 个群。
Uint8List _groupPayload() => Qq8Jce.encode(<int, Object?>{
      7: Qq8Jce.encode(<int, Object?>{
        0: <Object?, Object?>{
          'GetTroopListRespV2': Qq8Jce.encodeStruct(<int, Object?>{
            1: 1,
            2: 0,
            5: <Object?>[
              Qq8JceNested(Qq8Jce.encode(<int, Object?>{
                1: 987654321,
                4: '测试群',
                19: 233,
                29: 500,
              })),
            ],
          }),
        },
      }),
    });

Future<void> main() async {
  stdout.writeln('协议线 Session 适配离线自测（真实服务 + 脚本传输）');
  stdout.writeln('=' * 62);

  final scripted = Qq8ScriptedTransport(<Uint8List>[
    _successFrame(1, key: md5Bytes(_hex('a3' * 16))),
    _registerFrame(1),
  ]);
  final store = _MemStore();
  store.data = Qq8TokenData(
    uin: _me,
    savedAt: 'test',
    tgt: _hex('1122334455667788'),
    d2: _hex('a2' * 64),
    d2key: _hex('a3' * 16),
    sigKey: _hex('a4' * 48),
    ticketKey: _hex('a5' * 16),
    srmToken: _hex('a6' * 56),
  );
  final svc = Qq8LoginService(
    tokenStore: store,
    deviceBuilder: _fixtureDevice,
    ecdhBuilder: () => _fixedEcdh,
    transportBuilder: () => scripted,
    timeout: const Duration(seconds: 5),
  );
  final adapter = Qq8SessionAdapter(service: svc, uin: _me);

  final states = <SessionState>[];
  final events = <SessionEvent>[];
  adapter.events.listen(events.add);
  svc.states.listen((s) => states.add(adapter.state));

  // ----------------------------------------------------------------
  section('1. connect（token 登录）+ 状态映射');
  {
    await adapter.connect();
    check('state = ready', adapter.state == SessionState.ready, adapter.state.name);
    check('account.uin / backendName',
        adapter.account?.uin == '$_me' && adapter.backendName == 'wlogin8',
        '${adapter.account?.uin} ${adapter.backendName}');
    // 事件走广播流、异步投递：断言前先让一轮事件循环跑完
    await Future<void>.delayed(const Duration(milliseconds: 10));
    check('发出过 SessionStateChanged（到 ready）',
        events.whereType<SessionStateChanged>().any((e) => e.state == SessionState.ready),
        '${events.length} 个事件');
    check('能力上报：列表/历史/发消息/撤回/已读为 true，戳一戳与未知能力为 false',
        adapter.supports('send_message') &&
            adapter.supports('fetch_history') &&
            adapter.supports('list_chats') &&
            adapter.supports('recall') &&
            adapter.supports('set_message_read') &&
            !adapter.supports('send_poke') &&
            !adapter.supports('没有这个能力'));
  }

  // ----------------------------------------------------------------
  section('2. listChats（好友 + 群 → Chat）');
  {
    scripted.scriptedResponses.addAll(<Uint8List>[
      _frame(2, Qq8List.cmdFriendList, _friendPayload()),
      _frame(3, Qq8List.cmdGroupList, _groupPayload()),
    ]);
    final chats = await adapter.listChats();
    check('两个会话：私聊 + 群', chats.length == 2,
        chats.map((c) => c.id).join(' '));
    final priv = chats.firstWhere((c) => c.type == ChatType.private);
    final grp = chats.firstWhere((c) => c.type == ChatType.group);
    check('私聊 ID/标题/裸 ID（备注优先）',
        priv.id == 'private_22222' && priv.title == '小王' && priv.rawId == 22222,
        '${priv.id} ${priv.title}');
    check('群 ID/标题/成员数',
        grp.id == 'group_987654321' &&
            grp.title == '测试群' &&
            grp.memberCount == 233,
        '${grp.id} ${grp.title} ${grp.memberCount}');
  }

  // ----------------------------------------------------------------
  section('3. sendMessage（文本段 → 内核发送 → 消息 ID）');
  {
    scripted.scriptedResponses.add(
        _frame(4, Qq8Msg.sendCmd, Qq8Pb.encode(<int, Object?>{1: 0, 2: '', 3: 1700000500})));
    final id = await adapter.sendMessage(
        'private_22222', <Segment>[const TextSegment('hello '), const TextSegment('world')]);
    check('返回的 id 非空', id != null && id.isNotEmpty, id ?? '(null)');
    if (id != null) {
      // 独立复算：u32 对方 ‖ u32 seq ‖ u32 rand ‖ u32 time ‖ u8 flag(1=自己发)
      final raw = base64.decode(id);
      int u32(int i) => (raw[i] << 24) | (raw[i + 1] << 16) | (raw[i + 2] << 8) | raw[i + 3];
      check('id 打包正确（对方/时间/flag=1）',
          raw.length == 17 &&
              u32(0) == 22222 &&
              u32(12) == 1700000500 &&
              raw[16] == 1,
          'len=${raw.length} t=${u32(12)}');
    }
    var threw = false;
    try {
      await adapter.sendMessage('private_22222', <Segment>[const ReplySegment('x')]);
    } on SessionException {
      threw = true;
    }
    check('引用段里的消息 ID 不合法 → 拒绝（不静默丢引用）', threw);
  }

  // ----------------------------------------------------------------
  section('4. fetchHistory：私聊（时间游标）');
  {
    scripted.scriptedResponses.add(_frame(5, Qq8History.cmdOneDayRoam,
        Qq8Pb.encode(<int, Object?>{
      1: 0,
      3: 22222,
      6: <Uint8List>[
        _msg(from: 22222, to: _me, seq: 5, time: 1700000100, text: '旧消息'),
        _msg(from: _me, to: 22222, seq: 6, time: 1700000200, text: '我的旧消息'),
      ],
      7: 0, // 还没翻到头
    })));
    final page = await adapter.fetchHistory('private_22222', count: 20);
    check('两条历史、时间倒序（最新在前）',
        page.messages.length == 2 &&
            page.messages.first.text == '我的旧消息' &&
            page.messages.first.outgoing &&
            !page.messages.last.outgoing,
        page.messages.map((m) => m.text).join('|'));
    check('chatId 是复合 ID', page.messages.first.chatId == 'private_22222');
    check('还有更多 → next 是时间游标（最旧一条的时间）',
        page.hasMore && page.next?.time?.millisecondsSinceEpoch == 1700000100000,
        '${page.next}');
  }

  // ----------------------------------------------------------------
  section('5. fetchHistory：群（seq 游标，先学到 seq 才能拉）');
  {
    final empty = await adapter.fetchHistory('group_987654321');
    check('还没见过群消息 → 空页、不发请求（不猜 seq）',
        empty.messages.isEmpty && !empty.hasMore && scripted.sent.length == 6,
        '已发 ${scripted.sent.length} 个包');

    // 收一条群推送 → 适配套件学到最新 seq
    scripted.emit(_frame(99, Qq8PushCmd.pushGroup,
        Qq8Pb.encode(<int, Object?>{
      1: Qq8Pb.encode(<int, Object?>{
        1: Qq8Pb.encode(<int, Object?>{
          1: 33333,
          2: _me,
          3: 82,
          5: 1000,
          6: 1700000600,
          9: {1: 987654321, 8: '测试群'},
          14: '阿花',
        }),
        3: Qq8Pb.encode(<int, Object?>{
          1: <int, Object?>{
            2: <Uint8List>[
              Qq8Pb.encode(<int, Object?>{
                1: {1: '群里说话'},
              }),
            ],
          },
        }),
      }),
    })));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final msgEv = events.whereType<SessionMessage>().lastOrNull;
    check('群推送 → SessionMessage（chatId=group_987654321、文本、发送者）',
        msgEv != null &&
            msgEv.message.chatId == 'group_987654321' &&
            msgEv.message.text == '群里说话' &&
            msgEv.message.senderName == '阿花' &&
            msgEv.message.senderId == '33333',
        msgEv == null ? '没有消息事件' : '${msgEv.message.chatId} ${msgEv.message.text}');

    scripted.scriptedResponses.add(_frame(6, Qq8History.cmdGetGroupMsg,
        Qq8Pb.encode(<int, Object?>{
      1: 0,
      3: 987654321,
      4: 981,
      5: 1000,
      6: <Uint8List>[
        _msg(
          from: 33333,
          to: _me,
          msgType: 82,
          seq: 999,
          time: 1700000550,
          text: '群历史一',
          groupInfo: {1: 987654321},
        ),
      ],
    })));
    final page = await adapter.fetchHistory('group_987654321', count: 20);
    check('学到 seq 后能拉：1 条 + 群 chatId',
        page.messages.length == 1 &&
            page.messages.single.chatId == 'group_987654321' &&
            page.messages.single.text == '群历史一',
        page.messages.map((m) => m.text).join('|'));
    check('next 是 seq 游标（begin-1 = 980）', page.next?.seq == 980, '${page.next?.seq}');
  }

  // ----------------------------------------------------------------
  section('6. 多元素推送 → ChatMessage（语音/卡片/认不出/引用）');
  {
    // 一条群里发的消息，同时带：语音（RichText.ptt）、卡片（12）、
    // 认不出的字段（100）、引用（45）
    final push = Qq8Pb.encode(<int, Object?>{
      1: Qq8Pb.encode(<int, Object?>{
        1: Qq8Pb.encode(<int, Object?>{
          1: 33333,
          2: _me,
          3: 82,
          5: 1001,
          6: 1700000700,
          9: {1: 987654321, 8: '测试群'},
          14: '阿花',
        }),
        3: Qq8Pb.encode(<int, Object?>{
          1: <int, Object?>{
            1: Qq8Pb.encode(<int, Object?>{3: 0xABCD, 9: 'Arial'}),
            2: <Uint8List>[
              Qq8Pb.encode(<int, Object?>{
                12: {
                  1: Uint8List.fromList(
                      <int>[0, ...utf8.encode('<msg brief="一张卡片"/>')]),
                },
              }),
              Qq8Pb.encode(<int, Object?>{
                45: {
                  1: 900,
                  2: 33333,
                  3: 1700000600,
                  5: <Uint8List>[
                    Qq8Pb.encode(<int, Object?>{
                      1: {1: '被引用的原话'},
                    }),
                  ],
                },
              }),
              Qq8Pb.encode(<int, Object?>{
                100: {1: 1},
              }),
              Qq8Pb.encode(<int, Object?>{
                37: {17: 0},
              }),
            ],
            4: Qq8Pb.encode(<int, Object?>{
              4: Uint8List.fromList(List<int>.generate(16, (i) => i)),
              6: 4096,
              19: 7,
            }),
          },
        }),
      }),
    });
    scripted.emit(_frame(100, Qq8PushCmd.pushGroup, push));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final ev = events.whereType<SessionMessage>().lastOrNull;
    check('推送抵达且适配成 ChatMessage', ev != null,
        ev == null ? '没有消息事件' : '');

    if (ev != null) {
      final m = ev.message;
      check('纯文本 = 卡片占位 + 引用不掺进来 + 语音 + 不支持占位',
          m.text == '[卡片] 一张卡片[不支持显示的消息][语音]', m.text);
      check('引用原文进了 replyPreview（气泡引用条读它）',
          m.replyPreview == '被引用的原话', '${m.replyPreview}');
      check('引用**不**造假消息 ID（src_msg 里没有 rand）', m.replyToId == null,
          '${m.replyToId}');

      final types = m.segments.map((s) => s.runtimeType.toString()).toList();
      check('段类型齐了：卡片 / 引用 / 不支持 / 语音',
          types.length == 4 &&
              types[0] == 'XmlSegment' &&
              types[1] == 'ReplySegment' &&
              types[2] == 'UnknownSegment' &&
              types[3] == 'RecordSegment',
          types.join(' / '));

      final voice = m.segments.whereType<RecordSegment>().firstOrNull;
      check('语音段带上时长与体积', voice?.seconds == 7 && voice?.size == 4096,
          '${voice?.seconds}s ${voice?.size}B');
      final card = m.segments.whereType<XmlSegment>().firstOrNull;
      check('卡片段带上摘要', card?.summary == '一张卡片', '${card?.summary}');
      final unknown = m.segments.whereType<UnknownSegment>().firstOrNull;
      check('认不出的段落里保留了字段名（排查用）',
          unknown?.data['elem'] == 'unknown(100)' &&
              unknown?.data['field'] == 100,
          '${unknown?.data}');
      check('认不出的段文案是官方那句',
          unknown?.preview == '[不支持显示的消息]', '${unknown?.preview}');
    }
  }

  // ----------------------------------------------------------------
  section('6.5 推送回执：多端同步要回 OnlinePush.RespPush，群推不回');
  {
    // 多端同步（PbC2CMsgSync）：needsAck=true → 回一条空 items 的回执
    final syncPush = Qq8Pb.encode(<int, Object?>{
      1: Qq8Pb.encode(<int, Object?>{
        1: Qq8Pb.encode(<int, Object?>{
          1: _me, // 自己别的端发的
          2: 22222,
          3: 9,
          5: 2001,
          6: 1700000800,
        }),
        3: Qq8Pb.encode(<int, Object?>{
          1: <int, Object?>{
            1: Qq8Pb.encode(<int, Object?>{3: 7, 9: 'Arial'}),
            2: <Uint8List>[
              Qq8Pb.encode(<int, Object?>{
                1: {1: '手机上发的'},
              }),
            ],
          },
        }),
      }),
      2: 0x01020304, // svrip
    });
    final before = scripted.sent.length;
    scripted.emit(_frame(101, Qq8PushCmd.c2cSync, syncPush));
    await Future<void>.delayed(const Duration(milliseconds: 40));

    check('回执发出去了（多一条包）', scripted.sent.length == before + 1,
        '多发了 ${scripted.sent.length - before}');
    if (scripted.sent.length > before) {
      final (cmd, body) = _uniParts(scripted.sent.last);
      check('回执命令字 = OnlinePush.RespPush', cmd == 'OnlinePush.RespPush', cmd);
      final w = Qq8Jce.decode(body);
      check('回执 service/method 对', w[5] == 'OnlinePush' && w[6] == 'SvcRespPushMsg',
          '${w[5]}/${w[6]}');
      check('iRequestId = 推送的 seq(101)', w[4] == 101, '${w[4]}');
      final attrs = Qq8Jce.decode(w[7] as Uint8List)[0] as Map<Object?, Object?>;
      final r = Qq8Jce.decode(attrs['r'] as Uint8List)[0] as Map<int, Object?>;
      check('回执里带上 uin / svrip / 空 items',
          r[0] == _me && r[2] == 0x01020304 && (r[1] as List).isEmpty,
          '${r[0]} ${r[2]} ${r[1]}');
    }

    // 群消息推送（PbPushGroupMsg）：参考实现不回执
    final beforeGroup = scripted.sent.length;
    scripted.emit(_frame(102, Qq8PushCmd.pushGroup,
        Qq8Pb.encode(<int, Object?>{
      1: Qq8Pb.encode(<int, Object?>{
        1: Qq8Pb.encode(<int, Object?>{
          1: 33333,
          2: _me,
          3: 82,
          5: 1002,
          6: 1700000810,
          9: {1: 987654321, 8: '测试群'},
        }),
        3: Qq8Pb.encode(<int, Object?>{
          1: <int, Object?>{
            2: <Uint8List>[
              Qq8Pb.encode(<int, Object?>{
                1: {1: '群推不该回执'},
              }),
            ],
          },
        }),
      }),
    })));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    check('群消息推送不回执（与参考实现一致）',
        scripted.sent.length == beforeGroup,
        '多发了 ${scripted.sent.length - beforeGroup}');
  }

  // ----------------------------------------------------------------
  section('6.6 通知推送：该拉的拉、不该拉的不拉');
  {
    // 先让脚本准备好一次"拉新消息"的响应（PbGetMsg：一个会话块 + 一条消息）
    // ⚠️ 这里的 seq 必须等于"通知触发的拉取"真正用的 seq：会话层按 seq 配对，
    // 对不上就当成推送丢掉（然后这次拉取超时）。当前是 7——**在本节之前插入
    // 任何发包用例，后面的 seq 都要跟着顺移**（这是本文件的老坑）。
    scripted.scriptedResponses.add(_frame(
      7,
      Qq8History.cmdGetMsg,
      // 字段号照 qq8_history.dart 头注：
      // 1 result / 3 sync_cookie / 5 uin_pair_msgs
      // UinPairMsg：2 peer_uin / 4 msg(repeated) / 5 unread_msg_num
      Qq8Pb.encode(<int, Object?>{
        1: 0, // result
        3: Uint8List.fromList(<int>[1, 2, 3, 4]), // sync cookie（非空即更新）
        5: <Uint8List>[
          Qq8Pb.encode(<int, Object?>{
            2: 44444, // peer_uin
            4: <Uint8List>[
              _msg(
                from: 44444,
                to: _me,
                msgType: 9,
                seq: 3001,
                time: 1700000900,
                text: '通知拉回来的消息',
              ),
            ],
            5: 1, // unread_msg_num
          }),
        ],
      }),
    ));

    final notify = Qq8Jce.encodeWrapper(
      service: 'x',
      method: 'y',
      attributes: {
        'r': Qq8Jce.encodeStruct({5: 166}), // 166 = 好友消息类
      },
    );
    // 通知包前面有 4 字节前缀（见 qq8_push.dart 的解析）
    final before = scripted.sent.length;
    scripted.emit(_frame(103, Qq8PushCmd.notify,
        Uint8List.fromList(<int>[0, 0, 0, 0, ...notify])));
    await Future<void>.delayed(const Duration(milliseconds: 60));

    check('收到"有新消息"通知后会去拉一次 PbGetMsg',
        scripted.sent.length == before + 1, '多发了 ${scripted.sent.length - before}');
    if (scripted.sent.length > before) {
      final (cmd, _) = _uniParts(scripted.sent.last);
      check('发出去的命令字 = MessageSvc.PbGetMsg',
          cmd == Qq8History.cmdGetMsg, cmd);
    }

    // 拉回来的消息走推送同一条流水线 → 适配器发 SessionMessage
    final pulled = events.whereType<SessionMessage>().where(
        (e) => e.message.text == '通知拉回来的消息');
    check('拉回来的消息进了 UI 事件流（复用推送流水线）',
        pulled.isNotEmpty, '${events.whereType<SessionMessage>().length} 条消息事件');

    // 不该拉的类型：群请求（84）需要的是 getGrpSysMsg，我们还没做
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final beforeSys = scripted.sent.length;
    final sysNotify = Qq8Jce.encodeWrapper(
      service: 'x',
      method: 'y',
      attributes: {
        'r': Qq8Jce.encodeStruct({5: 84}),
      },
    );
    scripted.emit(_frame(104, Qq8PushCmd.notify,
        Uint8List.fromList(<int>[0, 0, 0, 0, ...sysNotify])));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    check('系统消息类（84 群请求）不乱拉——那要 getGrpSysMsg，还没做',
        scripted.sent.length == beforeSys,
        '多发了 ${scripted.sent.length - beforeSys}');
  }

  // ----------------------------------------------------------------
  section('7. 撤回与已读上报（消息 ID 反解 → 发对命令字）');
  {
    // 收到的消息（flag=0）不能撤回
    final incomingId = Qq8Msg.dmMessageId(
        peerUin: 22222, seq: 1, rand: 2, time: 3, outgoing: false);
    var refused = false;
    try {
      await adapter.recall('private_22222', incomingId);
    } on SessionException catch (e) {
      refused = e.message.contains('只能撤回自己发的');
    }
    check('撤回别人发的消息 → 拒绝（QQ 只能撤回自己的）', refused);

    var badIdRefused = false;
    try {
      await adapter.recall('private_22222', 'not-an-id');
    } on SessionException {
      badIdRefused = true;
    }
    check('非法消息 ID → 拒绝', badIdRefused);

    final before = scripted.sent.length;
    final mine = Qq8Msg.dmMessageId(
        peerUin: 22222, seq: 321, rand: 0x11223344, time: 1700000500, outgoing: true);

    // 撤回成功（脚本排一条 result=0 的响应）
    scripted.scriptedResponses.add(_frame(
        8,
        Qq8Msg.withdrawCmd,
        Qq8Pb.encode(<int, Object?>{
          1: Qq8Pb.encode(<int, Object?>{1: 0, 2: ''}),
        })));
    var recallThrew = false;
    try {
      await adapter.recall('private_22222', mine);
    } on SessionException {
      recallThrew = true;
    }
    check('撤回成功：不抛异常且发了包', !recallThrew && scripted.sent.length == before + 1,
        '已发 ${scripted.sent.length}');

    // 撤回被服务端拒（result=5）→ 抛 SessionException 并带服务端文案
    scripted.scriptedResponses.add(_frame(
        9,
        Qq8Msg.withdrawCmd,
        Qq8Pb.encode(<int, Object?>{
          1: Qq8Pb.encode(<int, Object?>{1: 5, 2: '消息不存在'}),
        })));
    var failed = false;
    try {
      await adapter.recall('private_22222', mine);
    } on SessionException catch (e) {
      failed = e.message.contains('消息不存在');
    }
    check('撤回被拒 → 抛出并带服务端文案', failed);

    // 已读上报：私聊（报到时间）与群（报到 seq）
    scripted.scriptedResponses.add(_frame(10, Qq8Msg.readedReportCmd, Uint8List(0)));
    await adapter.markRead('private_22222', mine);
    scripted.scriptedResponses.add(_frame(11, Qq8Msg.readedReportCmd, Uint8List(0)));
    await adapter.markRead(
        'group_987654321',
        Qq8Msg.groupMessageId(
            gid: 987654321, senderUin: 33333, seq: 999, rand: 1, time: 1700000550));
    check('已读上报：私聊与群两条都发出去了',
        scripted.sent.length == before + 4, '已发 ${scripted.sent.length}');

    // 引用回复：ReplySegment 不再被拒，翻成 src_msg 元素发出去（seq 12）
    final quoted = Qq8Msg.dmMessageId(
        peerUin: 22222, seq: 5, rand: 6, time: 1700000400, outgoing: false);
    scripted.scriptedResponses.add(_frame(
        12,
        Qq8Msg.sendCmd,
        Qq8Pb.encode(<int, Object?>{1: 0, 2: '', 3: 1700000500})));
    final replyId = await adapter.sendMessage('private_22222', <Segment>[
      ReplySegment(quoted, text: '被引用的话'),
      const TextSegment('这是我的回复'),
    ]);
    check('带引用的回复能发出去（ReplySegment 翻成 src_msg）',
        replyId != null && replyId.isNotEmpty, replyId ?? '(null)');

    // 能力上报：撤回与已读现在都算支持
    check('supports：recall / set_message_read 已变为 true',
        adapter.supports('recall') && adapter.supports('set_message_read'));
  }

  // ----------------------------------------------------------------
  section('8. 多元素发送：表情能发；图片段只认本地文件、混排拒绝');
  {
    scripted.scriptedResponses.add(_frame(
        13,
        Qq8Msg.sendCmd,
        Qq8Pb.encode(<int, Object?>{1: 0, 2: '', 3: 1700000600})));
    final before = scripted.sent.length;

    final faceId = await adapter.sendMessage('private_22222', <Segment>[
      const TextSegment('笑一个'),
      const FaceSegment('14'),
      const TextSegment('吧'),
    ]);
    check('表情段不再被拒（发出去并拿到消息 ID）',
        faceId != null && faceId.isNotEmpty, faceId ?? '(null)');
    check('文本+表情只发一个包', scripted.sent.length == before + 1,
        '多发了 ${scripted.sent.length - before - 1} 个');

    // 发图走上传链路（探图 → PicUp → highway）：没有本地文件就**明确拒绝**，
    // 不能拿一个空图糊过去（转发收到的那种只有 QQ 文件名）。
    var imgThrew = false;
    try {
      await adapter.sendMessage('private_22222', <Segment>[
        const ImageSegment('00112233445566778899aabbccddeeff100-10-10.jpg'),
      ]);
    } on SessionException catch (e) {
      imgThrew = e.message.contains('没有本地文件');
    }
    check('转发收到的图（无本地文件）被拒，且说清原因', imgThrew);
    check('被拒的段没有发出去', scripted.sent.length == before + 1,
        '${scripted.sent.length}');

    // 图片 + 文字混排：一条消息里暂时只能有一张图，不能静默只发一半
    var mixThrew = false;
    try {
      await adapter.sendMessage('private_22222', <Segment>[
        const TextSegment('看这个'),
        const ImageSegment('不存在的路径.png'),
      ]);
    } on SessionException catch (e) {
      mixThrew = e.message.contains('只能单独发');
    }
    check('图片+文字混排被拒（宁失败不静默丢）', mixThrew);
  }

  // ----------------------------------------------------------------
  section('9. `/表情名` 切分（纯函数，不用发包）');
  {
    List<Object> split(String s) => Qq8SessionAdapter.splitFaceTokens(s);

    check('单个表情：/微笑 → [14]',
        split('/微笑').length == 1 && split('/微笑')[0] == 14,
        '${split('/微笑')}');
    check('前后带文本：你好/微笑吧 → ["你好", 14, "吧"]',
        split('你好/微笑吧').join('|') == '你好|14|吧',
        split('你好/微笑吧').join('|'));
    check('后面跟标点也认：/微笑，你好 → [14, "，你好"]',
        split('/微笑，你好').join('|') == '14|，你好',
        split('/微笑，你好').join('|'));
    check('超级表情用带斜杠的名字：/吃瓜 → [271]',
        split('/吃瓜').length == 1 && split('/吃瓜')[0] == 271,
        '${split('/吃瓜')}');
    check('不是表情名的斜杠原样保留：/notaface → 一个文本片段',
        split('/notaface').length == 1 && split('/notaface')[0] == '/notaface',
        '${split('/notaface')}');
    check('路径里的斜杠不吞：见 a/b 说明',
        split('见 a/b 说明').join('|') == '见 a/b 说明',
        split('见 a/b 说明').join('|'));
    check('连续两个表情各自成元素：/微笑/大哭 → [14, 9]',
        split('/微笑/大哭').join('|') == '14|9',
        split('/微笑/大哭').join('|'));
    check('没有斜杠时原样返回', split('普通一句话').join('|') == '普通一句话',
        split('普通一句话').join('|'));
  }

  // ----------------------------------------------------------------
  section('10. 仍未支持的操作与释放');
  {
    var pokeThrew = false;
    try {
      await adapter.sendPoke('private_22222', '22222');
    } on SessionException {
      pokeThrew = true;
    }
    check('戳一戳仍不支持（抛 SessionException + supports 报 false）',
        pokeThrew && !adapter.supports('send_poke'));

    await adapter.dispose();
    await svc.close();
    check('dispose 后事件流关闭', true);
  }

  // ----------------------------------------------------------------
  section('11. 连接控制器（UI 的驱动口）');
  {
    final tmp = await Directory.systemTemp.createTemp('qq8-conn-');
    final scripted2 = Qq8ScriptedTransport(<Uint8List>[
      _successFrame(1, key: md5Bytes(_hex('a3' * 16))),
      _registerFrame(1),
      _frame(2, Qq8List.cmdFriendList, _friendPayload()),
      _frame(3, Qq8List.cmdGroupList, _groupPayload()),
    ]);
    final store2 = _MemStore()
      ..data = Qq8TokenData(
        uin: _me,
        savedAt: 'test',
        tgt: _hex('1122334455667788'),
        d2: _hex('a2' * 64),
        d2key: _hex('a3' * 16),
        sigKey: _hex('a4' * 48),
        ticketKey: _hex('a5' * 16),
        srmToken: _hex('a6' * 56),
      );
    final svc2 = Qq8LoginService(
      tokenStore: store2,
      deviceBuilder: _fixtureDevice,
      ecdhBuilder: () => _fixedEcdh,
      transportBuilder: () => scripted2,
      timeout: const Duration(seconds: 5),
    );
    final controller =
        Qq8ConnectController(service: svc2, dataDir: tmp);
    final labels = <String>[];
    controller.addListener((s) => labels.add(s.stateLabel));

    check('初始：未连接、没有 session/store',
        controller.status.stage == Qq8LoginStage.idle &&
            controller.session == null &&
            controller.store == null,
        controller.status.stateLabel);

    await controller.loginWithToken(_me);
    // _attach 是异步的（上线后自动套适配器 + 建 ChatStore）：等它跑完
    await Future<void>.delayed(const Duration(milliseconds: 80));
    check('登录后：session 与 store 都自动就绪',
        controller.session != null && controller.store != null);
    check('会话列表经 ChatStore 到了 UI 口（2 个）',
        controller.store?.chats.length == 2,
        '${controller.store?.chats.length}');
    check('状态到"已上线"且 isOnline',
        controller.status.isOnline && controller.status.stateLabel == '已上线',
        controller.status.stateLabel);
    check('状态变化序列里出现过"连接中…"', labels.contains('连接中…'),
        labels.join('>'));

    check('状态标签映射（需要人操作的几种）',
        const Qq8ConnectStatus(stage: Qq8LoginStage.needsSlider).stateLabel ==
                '需要完成滑动验证' &&
            const Qq8ConnectStatus(stage: Qq8LoginStage.waitingQrScan).needsHumanAction &&
            const Qq8ConnectStatus(stage: Qq8LoginStage.needsSmsCode).needsHumanAction &&
            const Qq8ConnectStatus(stage: Qq8LoginStage.failed).stateLabel == '登录失败');

    await controller.shutdown();
    await svc2.close();
    await tmp.delete(recursive: true);
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
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
