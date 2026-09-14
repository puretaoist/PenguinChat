/// 协议线登录/会话服务（`lib/client_api/qq8_login_service.dart`）离线自测
///
/// 用**脚本传输**（`Qq8ScriptedTransport`）把服务状态机走一遍：
/// 口令登录 → 各验证分支（滑块/短信/设备锁）→ 上线注册；以及失败与无票据路径。
/// 全程不联网、不需要账号。
///
/// 运行：
/// ```bash
/// dart run tool/qq8_login_service_selftest.dart
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/client_api/qq8_login_service.dart';
import 'package:qqclient/infra/coder.dart';
import 'package:qqclient/kernel/crypto/ecdh.dart';
import 'package:qqclient/kernel/crypto/tea.dart';
import 'package:qqclient/kernel/safety/environment_probe.dart';
import 'package:qqclient/kernel/safety/safety_gate.dart';
import 'package:qqclient/kernel/wlogin8/qq8_config.dart';
import 'package:qqclient/kernel/wlogin8/qq8_device.dart';
import 'package:qqclient/kernel/wlogin8/qq8_history.dart';
import 'package:qqclient/kernel/wlogin8/qq8_image.dart';
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

final Uint8List _tgtgt = _hex('ffeeddccbbaa99887766554433221100');

String _plainHexOf(List<int> b) =>
    b.map((v) => (v & 0xff).toRadixString(16).padLeft(2, '0')).join();

/// 固定 ECDH 私钥 + 与服务共享的密钥对（服务通过 `ecdhBuilder` 注入同一对）。
final EcdhKeyPair _fixedEcdh = Ecdh.exchange(
  Uint8List.fromList(Qq8Config.serverEcdhPublicKey),
  privateKey: _hex('${'00' * 31}01'),
);

/// 固定设备夹具（tgtgt 可控 ⇒ 能预先造出 0x119 的密文）。
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

/// 私聊推送负载：`PbPushMsg{1: Msg{1: MsgHead, 3: MsgBody}}`，
/// 字段号照官方 pb 定义（见 `qq8_push.dart` 头注）。
Uint8List _c2cPushPayload() => Qq8Pb.encode(<int, Object?>{
      1: Qq8Pb.encode(<int, Object?>{
        1: Qq8Pb.encode(<int, Object?>{
          1: 22222, // from_uin
          2: 10001, // to_uin
          3: 9, // msg_type
          5: 66, // msg_seq
          6: 1700000000, // msg_time
        }),
        3: Qq8Pb.encode(<int, Object?>{
          1: Qq8Pb.encode(<int, Object?>{
            2: <Uint8List>[
              Qq8Pb.encode(<int, Object?>{
                1: {1: '在吗'},
              }),
            ],
          }),
        }),
      }),
      2: 7, // svrip
    });

/// 被踢下线负载（JCE 包装：`[标题]内容`）。
Uint8List _kickPayload() => Qq8Jce.encodeWrapper(
      service: 'x',
      method: 'y',
      attributes: {
        'r': Qq8Jce.encodeStruct(<int, Object?>{3: '账号已在另一台设备登录', 4: '安全提示'}),
      },
    );

/// 一条 `msg_comm.Msg`（字段号同官方定义）。
Uint8List _msg({
  required int from,
  required int to,
  int msgType = 9,
  int seq = 1,
  int time = 1700000000,
  String text = '你好',
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

/// `PbGetMsgResp`：一个对端块 + 一条消息 + 新 sync_cookie。
Uint8List _getMsgPayload() => Qq8Pb.encode(<int, Object?>{
      1: 0,
      3: Uint8List.fromList(<int>[1, 2, 3, 4]),
      5: <Uint8List>[
        Qq8Pb.encode(<int, Object?>{
          2: 22222,
          4: <Uint8List>[
            _msg(from: 22222, to: 10001, seq: 21, text: '拉到的消息'),
          ],
          5: 1,
        }),
      ],
    });

/// `PbGetOneDayRoamMsgResp`：一条私聊历史。
Uint8List _roamPayload() => Qq8Pb.encode(<int, Object?>{
      1: 0,
      3: 22222,
      6: <Uint8List>[
        _msg(from: 22222, to: 10001, seq: 8, text: '私聊历史'),
      ],
      7: 1,
    });

/// `PbGetGroupMsgResp`：一条群历史 + 返回区间。
Uint8List _groupMsgPayload() => Qq8Pb.encode(<int, Object?>{
      1: 0,
      3: 987654321,
      4: 981,
      5: 1000,
      6: <Uint8List>[
        _msg(
          from: 33333,
          to: 10001,
          msgType: 82,
          seq: 999,
          text: '群历史',
          groupInfo: {1: 987654321},
        ),
      ],
    });

/// 好友列表响应（JCE）：第 [start] 页（序号 1/2 对应两个人），总数 [total]。
Uint8List _friendPagePayload({required int start, required int total}) =>
    Qq8Jce.encode(<int, Object?>{
      7: Qq8Jce.encode(<int, Object?>{
        0: <Object?, Object?>{
          'GetFriendListResp': Qq8Jce.encodeStruct(<int, Object?>{
            5: total,
            7: <Object?>[
              Qq8JceNested(Qq8Jce.encode(<int, Object?>{
                0: 20000 + start,
                1: 1,
                3: start == 2 ? '路人乙' : '',
                14: start == 2 ? '乙' : '甲',
                31: start,
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

/// 群列表响应（JCE）。
Uint8List _groupListPayload() => Qq8Jce.encode(<int, Object?>{
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
                23: 10002,
              })),
            ],
          }),
        },
      }),
    });

/// 造**登录层** payload：`[16B 头][TEA(明文, shareKey)][0x03]`。
///
/// 服务内部会跳过前 16 字节、丢掉末字节，再用 ECDH 共享密钥解中间那段，
/// 所以测试必须按同样的形状加密——共享密钥来自下面的固定私钥（与服务注入的一致）。
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

/// 登录成功帧：`0x119` 的 body 是用 tgtgt 加密的票据块。
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

/// 注册成功帧（`rsp[9] = 1`）。
Uint8List _registerFrame(int seq) {
  final struct = Qq8Jce.encodeStruct(<int, Object?>{0: 10001, 9: 1});
  final payload = Qq8Jce.encode(<int, Object?>{
    0: <Object?, Object?>{'SvcRespRegister': struct},
  });
  final body = Qq8Jce.encode(<int, Object?>{7: payload});
  return _frame(seq, 'StatSvc.register', body);
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

/// 字节序列里找子序列（自测用；发出去的包是 TEA 密文，只能解密后再找）。
bool _containsBytes(List<int> hay, List<int> needle) {
  if (needle.isEmpty || hay.length < needle.length) return false;
  for (var i = 0; i + needle.length <= hay.length; i++) {
    var eq = true;
    for (var k = 0; k < needle.length; k++) {
      if (hay[i + k] != needle[k]) {
        eq = false;
        break;
      }
    }
    if (eq) return true;
  }
  return false;
}

/// 最小 PNG（签名 + IHDR，宽高在 16/20）——发图自测用，能过探图即可。
Uint8List _pngBytes(int w, int h) {
  final out = <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // 签名
    0, 0, 0, 13, // IHDR 长度
    ...'IHDR'.codeUnits,
    (w >> 24) & 0xFF, (w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF,
    (h >> 24) & 0xFF, (h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF,
    8, 6, 0, 0, 0,
    0, 0, 0, 0, // crc 占位（探图不校验）
  ];
  return Uint8List.fromList(out);
}

Future<void> main() async {
  stdout.writeln('协议线登录/会话服务 离线自测');
  stdout.writeln('=' * 62);

  final powSample = _hex(File('vectors/pow-0x546-real.hex').readAsStringSync());

  // ----------------------------------------------------------------
  section('1. 口令 → 滑块（含真实防刷题）→ 提交 → 上线');
  {
    final store = _MemStore();
    final scripted = Qq8ScriptedTransport(<Uint8List>[
      _frame(1, 'wtlogin.login', _payload(2, <int, List<int>>{
        0x104: List<int>.filled(44, 0x41),
        0x192: utf8.encode('https://example.invalid/captcha'),
        0x546: powSample,
      })),
      _successFrame(2),
      _registerFrame(1),
    ]);
    final svc = Qq8LoginService(
      tokenStore: store,
      deviceBuilder: _fixtureDevice,
      ecdhBuilder: () => _fixedEcdh,
      transportBuilder: () => scripted,
      timeout: const Duration(seconds: 5),
    );
    final seen = <Qq8LoginStage>[];
    final sub = svc.states.listen((s) => seen.add(s.stage));

    await svc.loginWithPassword(uin: 10001, password: 'hunter2');
    check('停在 needsSlider', svc.snapshot.stage == Qq8LoginStage.needsSlider,
        svc.snapshot.stage.name);
    check('给出验证地址', svc.snapshot.sliderUrl == 'https://example.invalid/captcha',
        '${svc.snapshot.sliderUrl}');

    await svc.submitSliderTicket('t03TESTTICKET');
    check('提交后上线', svc.snapshot.stage == Qq8LoginStage.online,
        svc.snapshot.stage.name);
    check('票据已存且可用', store.data?.usable ?? false,
        'd2=${store.data?.d2.length}B d2key=${store.data?.d2key.length}B');
    check('sig 已解出', svc.sig?.tgt?.length == 56, '${svc.sig?.tgt?.length}');
    check('发了 3 个包（登录 / 滑块 / 注册）', scripted.sent.length == 3,
        '${scripted.sent.length}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    check('状态序列含 connecting→needsSlider→connecting→online',
        seen.join(',').contains('needsSlider') && seen.last == Qq8LoginStage.online,
        seen.map((s) => s.name).join('>'));
    await svc.close();
    await sub.cancel();
  }

  // ----------------------------------------------------------------
  section('2. 口令 → 短信验证 → 提交码 → 上线');
  {
    final store = _MemStore();
    final scripted = Qq8ScriptedTransport(<Uint8List>[
      _frame(1, 'wtlogin.login', _payload(160, <int, List<int>>{
        0x104: List<int>.filled(20, 0x42),
        0x174: _hex('aabbccdd'),
        0x178: <int>[0x31, 0x0b, ...'13800000000'.codeUnits],
      })),
      _successFrame(2),
      _registerFrame(1),
    ]);
    final svc = Qq8LoginService(
      tokenStore: store,
      deviceBuilder: _fixtureDevice,
      ecdhBuilder: () => _fixedEcdh,
      transportBuilder: () => scripted,
      timeout: const Duration(seconds: 5),
    );
    await svc.loginWithPassword(uin: 10001, password: 'hunter2');
    check('停在 needsSmsCode', svc.snapshot.stage == Qq8LoginStage.needsSmsCode,
        svc.snapshot.stage.name);
    check('手机号解出', svc.snapshot.phone == '13800000000', '${svc.snapshot.phone}');
    check('未标记"已自动下发"', !svc.snapshot.smsAutoSent);

    await svc.submitSmsCode('654321');
    check('提交码后上线', svc.snapshot.stage == Qq8LoginStage.online,
        svc.snapshot.stage.name);
    check('票据已存', store.data != null);
    await svc.close();
  }

  // ----------------------------------------------------------------
  section('3. 设备锁（204）→ 解锁 → 上线');
  {
    final store = _MemStore();
    final scripted = Qq8ScriptedTransport(<Uint8List>[
      _frame(1, 'wtlogin.login', _payload(204, <int, List<int>>{
        0x104: List<int>.filled(16, 0x43),
        0x204: utf8.encode('需要设备锁验证'),
      })),
      _successFrame(2),
      _registerFrame(1),
    ]);
    final svc = Qq8LoginService(
      tokenStore: store,
      deviceBuilder: _fixtureDevice,
      ecdhBuilder: () => _fixedEcdh,
      transportBuilder: () => scripted,
      timeout: const Duration(seconds: 5),
    );
    await svc.loginWithPassword(uin: 10001, password: 'hunter2');
    check('停在 needsDeviceLock',
        svc.snapshot.stage == Qq8LoginStage.needsDeviceLock, svc.snapshot.stage.name);
    check('提示语解出', svc.snapshot.deviceLockHint == '需要设备锁验证',
        '${svc.snapshot.deviceLockHint}');
    await svc.unlockDevice();
    check('解锁后上线', svc.snapshot.stage == Qq8LoginStage.online,
        svc.snapshot.stage.name);
    await svc.close();
  }

  // ----------------------------------------------------------------
  section('3b. 手机号短信登录：17 → 19 → 18（无票据）→ 9（mpasswd）→ 上线');
  {
    final store = _MemStore();
    final random = List<int>.generate(16, (i) => i);
    final scripted = Qq8ScriptedTransport(<Uint8List>[
      // 17 检查手机号 → 208：盐 / 随机数 / 次数与时限 / msalt
      _frame(1, 'wtlogin.login', _payload(208, <int, List<int>>{
        0x104: List<int>.filled(20, 0x51),
        0x126: <int>[0, 0, 0, 16, ...random],
        0x182: <int>[0, 0, 5, 0, 60],
        0x183: <int>[0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88],
      })),
      // 19 下发验证码 → 232：新盐 + 提示手机号（0x52B）
      _frame(2, 'wtlogin.login', _payload(232, <int, List<int>>{
        0x104: List<int>.filled(20, 0x52),
        0x52B: <int>[0, 0, 0, 0, 0, 86, 0, 0, ...utf8.encode('13800138000')],
      })),
      // 18 提交验证码 → type 0 但**没有 0x119**：只有 uin(0x113) + msalt + 新盐
      _frame(3, 'wtlogin.login', _payload(0, <int, List<int>>{
        0x113: <int>[0, 0, 0x27, 0x11],
        0x183: <int>[0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88],
        0x104: <int>[1, 2, 3],
      })),
      // 9 用 mpasswd 当口令换票据 → 成功
      _successFrame(4),
      _registerFrame(1),
    ]);
    final svc = Qq8LoginService(
      tokenStore: store,
      deviceBuilder: _fixtureDevice,
      ecdhBuilder: () => _fixedEcdh,
      transportBuilder: () => scripted,
      timeout: const Duration(seconds: 5),
    );

    await svc.loginWithPhone(phone: '13800138000');
    check('检查后停在 needsSmsCode',
        svc.snapshot.stage == Qq8LoginStage.needsSmsCode,
        svc.snapshot.stage.name);
    check('标记为手机号短信线（smsFlow）', svc.snapshot.smsFlow);
    check('208 只是检查、还没发短信（smsAutoSent 假）', !svc.snapshot.smsAutoSent);
    check('手机号带在快照里', svc.snapshot.phone == '13800138000',
        '${svc.snapshot.phone}');
    check('次数/时限解出 = 5 次 / 60s',
        svc.smsLoginLimits?.msgCnt == 5 && svc.smsLoginLimits?.timeLimit == 60,
        '${svc.smsLoginLimits}');
    check('这张快照没带 uin（手机号流程登录前不知道）', svc.snapshot.uin == null,
        '${svc.snapshot.uin}');

    await svc.refreshSmsLoginCode();
    check('下发后仍在 needsSmsCode', svc.snapshot.stage == Qq8LoginStage.needsSmsCode);
    check('下发后 smsAutoSent 为真', svc.snapshot.smsAutoSent);
    check('提示号取 0x52B', svc.snapshot.phone == '13800138000',
        '${svc.snapshot.phone}');

    await svc.submitSmsLoginCode('654321');
    check('提交后自动续登录并上线',
        svc.snapshot.stage == Qq8LoginStage.online, svc.snapshot.stage.name);
    check('uin 取的是 18 号回包的 0x113 = 10001', svc.snapshot.uin == 10001,
        '${svc.snapshot.uin}');
    check('票据已存（uin=10001）', store.data?.uin == 10001, '${store.data?.uin}');
    check('共发 5 个包（17 / 19 / 18 / 9 / 注册）', scripted.sent.length == 5,
        '${scripted.sent.length}');
    await svc.close();
  }

  // ----------------------------------------------------------------
  section('4. 失败路径：服务端文案要能直接显示');
  {
    final msg = (ByteWriter()
          ..u32(0)
          ..bytes16(utf8.encode('登录失败'))
          ..bytes16(utf8.encode('服务连接中，请稍后再试。(0x6)')))
        .build();
    final scripted = Qq8ScriptedTransport(<Uint8List>[
      _frame(1, 'wtlogin.login', _payload(6, <int, List<int>>{0x146: msg})),
    ]);
    final svc = Qq8LoginService(
      tokenStore: _MemStore(),
      deviceBuilder: _fixtureDevice,
      ecdhBuilder: () => _fixedEcdh,
      transportBuilder: () => scripted,
      timeout: const Duration(seconds: 5),
    );
    await svc.loginWithPassword(uin: 10001, password: 'hunter2');
    check('停在 failed', svc.snapshot.stage == Qq8LoginStage.failed,
        svc.snapshot.stage.name);
    check('错误文案含服务端提示',
        (svc.snapshot.error ?? '').contains('服务连接中') &&
            (svc.snapshot.error ?? '').contains('登录失败'),
        '${svc.snapshot.error}');
    await svc.close();
  }

  // ----------------------------------------------------------------
  section('5. token 登录：没有票据时要明确失败');
  {
    final svc = Qq8LoginService(
      tokenStore: _MemStore(),
      deviceBuilder: _fixtureDevice,
      ecdhBuilder: () => _fixedEcdh,
      transportBuilder: () => Qq8ScriptedTransport(<Uint8List>[]),
    );
    await svc.loginWithToken(uin: 10001);
    check('明确失败并给出原因',
        svc.snapshot.stage == Qq8LoginStage.failed &&
            (svc.snapshot.error ?? '').contains('票据'),
        '${svc.snapshot.error}');
    await svc.close();
  }

  // ----------------------------------------------------------------
  section('6. 上线后：推送流可用 + 关闭回 idle');
  {
    final scripted = Qq8ScriptedTransport(<Uint8List>[
      // token 路径：设备 tgtgt 会被服务改成 MD5(d2key)，0x119 要用派生密钥加密
      _successFrame(1, key: md5Bytes(_hex('a3' * 16))),
      _registerFrame(1),
    ]);
    final svc = Qq8LoginService(
      tokenStore: _MemStore(),
      deviceBuilder: _fixtureDevice,
      ecdhBuilder: () => _fixedEcdh,
      transportBuilder: () => scripted,
      timeout: const Duration(seconds: 5),
    );
    // 直接用 token 路径上线：先塞一份可用票据
    final store = svc.tokenStore as _MemStore;
    final tokenD2Key = _hex('a3' * 16);
    store.data = Qq8TokenData(
      uin: 10001,
      savedAt: 'test',
      tgt: _hex('1122334455667788'),
      d2: _hex('a2' * 64),
      d2key: tokenD2Key,
      sigKey: _hex('a4' * 48),
      ticketKey: _hex('a5' * 16),
      srmToken: _hex('a6' * 56),
    );
    await svc.loginWithToken(uin: 10001);
    check('token 登录后在线', svc.snapshot.stage == Qq8LoginStage.online,
        svc.snapshot.stage.name);

    // 推送流要**在线之后**订阅：上线前 `pushes` 还是空流
    final pushes = <String>[];
    svc.pushes.listen((p) => pushes.add(p.cmd));
    // 解析后的事件流：先挂订阅再发帧（否则漏掉早到的那条）
    final events = <Qq8PushEvent>[];
    svc.events.listen(events.add);
    scripted.emit(_frame(99, 'MessageSvc.PushNotify', _hex('cafe')));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    check('推送进了 pushes 流', pushes.contains('MessageSvc.PushNotify'),
        pushes.join(','));

    // 推送解析（收消息 v1）：消息事件、被踢下线的状态迁移
    scripted.emit(_frame(100, 'OnlinePush.PbPushC2CMsg', _c2cPushPayload()));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final msgEv = events.whereType<Qq8MessagePush>().firstOrNull;
    check('私聊推送解成 Qq8MessagePush（发件人 22222 / 文本「在吗」）',
        msgEv != null && msgEv.message.fromUin == 22222 && msgEv.message.text == '在吗',
        msgEv == null ? '没有消息事件' : '${msgEv.message.fromUin} ${msgEv.message.text}');
    check('假负载（JCE 解不开）只是 UnknownPush，不改状态',
        events.whereType<Qq8UnknownPush>().isNotEmpty &&
            svc.snapshot.stage == Qq8LoginStage.online,
        svc.snapshot.stage.name);

    // 拉消息 / 历史（收消息的"主动取"）：脚本里排上三条响应
    // （seq 2/3/4 = 注册之后会话的 nextSeq 顺序）
    scripted.scriptedResponses.addAll(<Uint8List>[
      _frame(2, Qq8History.cmdGetMsg, _getMsgPayload()),
      _frame(3, Qq8History.cmdOneDayRoam, _roamPayload()),
      _frame(4, Qq8History.cmdGetGroupMsg, _groupMsgPayload()),
    ]);
    final pulled = await svc.pullMessages();
    check('拉新消息：解出 1 个会话块 / 1 条消息 / 回写 sync_cookie',
        pulled.ok &&
            pulled.blocks.length == 1 &&
            pulled.blocks.single.peerUin == 22222 &&
            pulled.messages.single.text == '拉到的消息' &&
            pulled.syncCookie?.length == 4,
        'result=${pulled.result} 条数=${pulled.messages.length}');

    final roam = await svc.fetchC2cHistory(peerUin: 22222, before: 1700000200);
    check('私聊历史：1 条 + iscomplete',
        roam.ok && roam.messages.single.text == '私聊历史' && roam.isComplete == true,
        '条数=${roam.messages.length}');

    final grp = await svc.fetchGroupHistory(
        groupCode: 987654321, beginSeq: 981, endSeq: 1000);
    check('群历史：1 条 + 返回区间 981-1000',
        grp.ok &&
            grp.messages.single.text == '群历史' &&
            grp.returnBeginSeq == 981 &&
            grp.returnEndSeq == 1000,
        '条数=${grp.messages.length}');
    check('三次请求都发出去了（累计 5 个包：登录/注册 + 3）',
        scripted.sent.length == 5, '${scripted.sent.length}');

    // 好友列表（pageSize=1 逼出真分页）与群列表
    scripted.scriptedResponses.addAll(<Uint8List>[
      _frame(5, Qq8List.cmdFriendList, _friendPagePayload(start: 1, total: 2)),
      _frame(6, Qq8List.cmdFriendList, _friendPagePayload(start: 2, total: 2)),
      _frame(7, Qq8List.cmdGroupList, _groupListPayload()),
    ]);
    final fl = await svc.fetchFriendList(pageSize: 1);
    check('好友列表：翻两页凑齐 2 人 + 1 个分组',
        fl.ok &&
            fl.total == 2 &&
            fl.friends.length == 2 &&
            fl.friends[1].displayName == '路人乙' &&
            fl.classes.single.name == '我的好友',
        '${fl.friends.length}/${fl.total}');
    final gl = await svc.fetchGroupList();
    check('群列表：1 个群、名字/成员数解出',
        gl.ok &&
            gl.groups.single.gid == 987654321 &&
            gl.groups.single.memberCount == 233,
        '${gl.groups.length} 个');
    check('累计 8 个包（登录/注册 + 3 拉取 + 3 列表）',
        scripted.sent.length == 8, '${scripted.sent.length}');

    scripted.emit(_frame(101, 'MessageSvc.PushForceOffline', _kickPayload()));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    check('被踢包解成 Qq8KickPush（提示带样式）',
        events.whereType<Qq8KickPush>().any((e) => e.hint.contains('安全提示')),
        events.whereType<Qq8KickPush>().map((e) => e.hint).join('|'));
    check('被踢后状态转 disconnected 且带服务端提示',
        svc.snapshot.stage == Qq8LoginStage.disconnected &&
            (svc.snapshot.error ?? '').contains('账号已在另一台设备登录'),
        '${svc.snapshot.stage.name} ${svc.snapshot.error}');

    await svc.close();
    check('关闭后回 idle', svc.snapshot.stage == Qq8LoginStage.idle,
        svc.snapshot.stage.name);
  }

  // ----------------------------------------------------------------
  section('6b. 发图（sendImage）：PicUp 申请 → highway 真传 → 回填 fid 再发');
  {
    // 本地假图床：收帧 → 回 ack（链路与真机一致，只是地址是我们自己的）
    final got = <int>[];
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final socket in server) {
        final buf = BytesBuilder(copy: false);
        socket.listen((d) {
          buf.add(d);
          final acc = buf.takeBytes();
          var pos = 0;
          while (acc.length - pos >= 10) {
            if (acc[pos] != 40) {
              pos++;
              continue;
            }
            final headLen = (acc[pos + 1] << 24) |
                (acc[pos + 2] << 16) |
                (acc[pos + 3] << 8) |
                acc[pos + 4];
            final bodyLen = (acc[pos + 5] << 24) |
                (acc[pos + 6] << 16) |
                (acc[pos + 7] << 8) |
                acc[pos + 8];
            final total = 9 + headLen + bodyLen + 1;
            if (acc.length - pos < total) break;
            final head = Qq8Pb.decode(acc.sublist(pos + 9, pos + 9 + headLen));
            final seg = Qq8Pb.decode(Qq8Pb.bytesAt(head, 2)!);
            final off = Qq8Pb.intAt(seg, 3) ?? 0;
            final len = Qq8Pb.intAt(seg, 4) ?? 0;
            got.add(len);
            final ack = Qq8Pb.encode(<int, Object?>{
              2: <int, Object?>{2: 0, 3: off, 4: len},
              3: 0,
            });
            final out = Uint8List(9 + ack.length + 1);
            out[0] = 40;
            out[1] = (ack.length >> 24) & 0xFF;
            out[2] = (ack.length >> 16) & 0xFF;
            out[3] = (ack.length >> 8) & 0xFF;
            out[4] = ack.length & 0xFF;
            out.setRange(9, 9 + ack.length, ack);
            out[out.length - 1] = 41;
            socket.add(out);
            pos += total;
          }
          if (pos < acc.length) buf.add(Uint8List.sublistView(acc, pos));
        });
      }
    }());

    final scripted = Qq8ScriptedTransport(<Uint8List>[
      _successFrame(1, key: md5Bytes(_hex('a3' * 16))),
      _registerFrame(1),
      // sendImage 第一步：OffPicUp 回执（fid + 图床地址 + ticket）
      _frame(2, Qq8ImageUp.cmdOffPicUp, Qq8Pb.encode(<int, Object?>{
        2: <Uint8List>[
          Qq8Pb.encode(<int, Object?>{
            3: 0, // code
            7: 0x0100007F, // ip：127.0.0.1（低字节在前）
            8: server.port,
            9: Uint8List.fromList(<int>[0xAA, 0xBB]),
            10: 'FID_FOR_TEST',
          }),
        ],
      })),
      // 第三步：把图片消息发出去（PbSendMsg 的响应）
      _frame(
          3, Qq8Msg.sendCmd, Qq8Pb.encode(<int, Object?>{1: 0, 2: '', 3: 1700000700})),
    ]);
    final svc = Qq8LoginService(
      tokenStore: _MemStore(),
      deviceBuilder: _fixtureDevice,
      ecdhBuilder: () => _fixedEcdh,
      transportBuilder: () => scripted,
      timeout: const Duration(seconds: 5),
    );
    (svc.tokenStore as _MemStore).data = Qq8TokenData(
      uin: 10001,
      savedAt: 'test',
      tgt: _hex('1122334455667788'),
      d2: _hex('a2' * 64),
      d2key: _hex('a3' * 16),
      sigKey: _hex('a4' * 48),
      ticketKey: _hex('a5' * 16),
      srmToken: _hex('a6' * 56),
    );
    await svc.loginWithToken(uin: 10001);
    check('先上线（发图要求在线）', svc.snapshot.stage == Qq8LoginStage.online);

    final img = _pngBytes(64, 40);
    final progress = <double>[];
    final r = await svc.sendImage(
      bytes: img,
      uid: 22222,
      onProgress: progress.add,
      uploadTimeout: const Duration(seconds: 10),
    );
    final uploaded = got.fold<int>(0, (a, b) => a + b);
    stdout.writeln('    假图床收到 ${got.length} 片（共 $uploaded 字节），'
        '进度 ${progress.length} 次');
    check('图片消息发送结果 ok', r.ok, 'code=${r.code} ${r.message}');
    check('图片数据真的传到了假图床（字节数一致）', uploaded == img.length,
        '$uploaded != ${img.length}');
    check('进度回调到 100%', progress.isNotEmpty && progress.last == 1.0);

    // 最后一条包（PbSendMsg）里要带上 PicUp 给的 fid。
    // 业务包（UNI）是 TEA 密文，明文搜不到，但结构固定：
    // `[u32 total][u32 0x0B][u8 1][u32 seq][u8 0][u32 uinLen+4][uin][TEA(inner, d2key)]`
    // —— 密钥就是 d2key（测试里是 a3*16），直接解开找 fid。
    final lastPacket = scripted.sent.last;
    final uinLen = '${10001}'.length;
    final cipher = lastPacket.sublist(18 + uinLen);
    final plain = qqTeaDecrypt(cipher, _hex('a3' * 16));
    final fidFound = _containsBytes(plain, utf8.encode('FID_FOR_TEST'));
    final cmdFound = _containsBytes(plain, utf8.encode(Qq8Msg.sendCmd));
    check('解开的最后一条包确实是 PbSendMsg', cmdFound);
    check('发出的消息里含 fid（元素回填没丢）', fidFound);
    check('整条链路只发了 4 个 SSO 包（token 登录/注册/申请/发消息）',
        scripted.sent.length == 4, '${scripted.sent.length}');
    await svc.close();
    await server.close();
  }

  // ----------------------------------------------------------------
  section('7. 票据存储：明文与 AES-GCM 加密两种实现');
  {
    if (!Directory.systemTemp.existsSync()) {
      Directory.systemTemp.createSync(recursive: true);
    }
    final tmp = Directory.systemTemp.createTempSync('qq8-token-test-');
    try {
      final token = Qq8TokenData(
        uin: 10001,
        savedAt: 'test',
        tgt: _hex('1122334455667788'),
        d2: _hex('a2' * 64),
        d2key: _hex('a3' * 16),
        sigKey: _hex('a4' * 48),
        ticketKey: _hex('a5' * 16),
        srmToken: _hex('a6' * 56),
      );

      final plain = FileQq8TokenStore(tmp);
      await plain.save(token);
      final backPlain = await plain.load(10001);
      check('明文版：存取一致', backPlain?.d2key.join(',') == token.d2key.join(','),
          '${backPlain?.d2key.length}B');

      final enc = EncryptedFileQq8TokenStore(tmp);
      await enc.save(token);
      final backEnc = await enc.load(10001);
      check('加密版：存取一致（d2key 逐字节）',
          backEnc?.d2key.join(',') == token.d2key.join(','),
          '${backEnc?.d2key.length}B');
      check('加密版：票据字段完整（tgt/d2/sig/ticket/srm）',
          backEnc?.tgt.join(',') == token.tgt.join(',') &&
              backEnc?.d2.join(',') == token.d2.join(',') &&
              backEnc?.sigKey.join(',') == token.sigKey.join(',') &&
              backEnc?.ticketKey.join(',') == token.ticketKey.join(',') &&
              backEnc?.srmToken.join(',') == token.srmToken.join(','));

      final encFile = File('${tmp.path}${Platform.pathSeparator}'
          'qq8-token-10001.json.enc');
      final cipherText = await encFile.readAsString();
      check('加密版：磁盘上看不到 d2key 明文',
          !cipherText.contains(_plainHexOf(token.d2key)) &&
              !cipherText.contains(_plainHexOf(token.d2)),
          '${cipherText.length} 字符');

      // 换个密钥（相当于拿到错密钥）→ 必须当作"没有票据"，不能返回半截数据
      final encWrongKey = EncryptedFileQq8TokenStore(
        tmp,
        keyProvider: () async => List<int>.filled(32, 0x5a),
      );
      check('加密版：密钥不对 → 返回 null（不把坏数据交给协议层）',
          await encWrongKey.load(10001) == null);

      // 篡改密文 → GCM 校验失败 → 同样当作没有
      final tampered = cipherText.replaceRange(0, 1,
          cipherText[0] == 'a' ? 'b' : 'a');
      await encFile.writeAsString(tampered);
      final enc2 = EncryptedFileQq8TokenStore(tmp);
      check('加密版：密文被改 → 返回 null', await enc2.load(10001) == null);

      await enc.clear(10001);
      check('加密版：clear 后读不到', await enc.load(10001) == null);
    } finally {
      tmp.deleteSync(recursive: true);
    }
  }

  // ----------------------------------------------------------------
  section('8. 掉线要传给上层（心跳连败 → disconnected）');
  {
    final scripted = Qq8ScriptedTransport(<Uint8List>[
      // token 路径：tgtgt = MD5(d2key)，成功帧要用派生密钥加密
      _successFrame(1, key: md5Bytes(_hex('a3' * 16))),
      _registerFrame(1),
    ]);
    final svc = Qq8LoginService(
      tokenStore: _MemStore(),
      deviceBuilder: _fixtureDevice,
      ecdhBuilder: () => _fixedEcdh,
      transportBuilder: () => scripted,
      heartbeatInterval: const Duration(milliseconds: 30),
      timeout: const Duration(milliseconds: 150),
    );
    final store = svc.tokenStore as _MemStore;
    store.data = Qq8TokenData(
      uin: 10001,
      savedAt: 'test',
      tgt: _hex('1122334455667788'),
      d2: _hex('a2' * 64),
      d2key: _hex('a3' * 16),
      sigKey: _hex('a4' * 48),
      ticketKey: _hex('a5' * 16),
      srmToken: _hex('a6' * 56),
    );

    final stages = <Qq8LoginStage>[];
    svc.states.listen((s) => stages.add(s.stage));
    await svc.loginWithToken(uin: 10001);
    check('先在线', svc.snapshot.stage == Qq8LoginStage.online,
        svc.snapshot.stage.name);

    // 脚本已用尽 → 心跳请求会超时 → 连败两次 → 会话层回调 onOffline
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (svc.snapshot.stage != Qq8LoginStage.disconnected &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    check('心跳连败后进入 disconnected',
        svc.snapshot.stage == Qq8LoginStage.disconnected,
        svc.snapshot.stage.name);
    check('disconnected 带可显示的原因',
        (svc.snapshot.error ?? '').contains('断开'), '${svc.snapshot.error}');
    check('isOnline 变 false', !svc.isOnline);
    check('状态流里出现过 disconnected', stages.contains(Qq8LoginStage.disconnected),
        stages.map((s) => s.name).join('>'));
    await svc.close();
  }

  // ----------------------------------------------------------------
  section('9. 安全闸门：不通过就一个字节都不发');
  {
    // 未开启真实服务器模式 → 拒
    final offlineGate = SafetyGate();
    final scripted = Qq8ScriptedTransport(<Uint8List>[_successFrame(1)]);
    final svc = Qq8LoginService(
      tokenStore: _MemStore(),
      deviceBuilder: _fixtureDevice,
      ecdhBuilder: () => _fixedEcdh,
      transportBuilder: () => scripted,
      gate: offlineGate,
    );
    await svc.loginWithPassword(uin: 10001, password: 'hunter2');
    check('离线模式：拒发且给出引导',
        svc.snapshot.stage == Qq8LoginStage.failed &&
            (svc.snapshot.error ?? '').contains('真实服务器模式'),
        svc.snapshot.error);
    check('离线模式：一个包都没发', scripted.sent.isEmpty,
        '${scripted.sent.length}');
    await svc.close();

    final okGate = SafetyGate();
    final enableErr = await okGate.enableRealServer(
      <String>[
        '同意封禁与限制登录风险',
        '同意设备指纹（Qimei）相关风险',
        '不伪造、不绕过任何验证',
        '使用专门注册的测试账号',
        '不隐藏 native / libfekit 特征，用干净设备测',
      ],
      environment: EnvironmentReport(
        findings: const <EnvFinding>[],
        probedAt: DateTime.now(),
      ),
    );
    check('测试前提：闸门可被正确开启', enableErr == null, '$enableErr');
    final scripted3 = Qq8ScriptedTransport(<Uint8List>[
      _successFrame(1, key: md5Bytes(_hex('a3' * 16))),
      _registerFrame(1),
    ]);
    final svc3 = Qq8LoginService(
      tokenStore: _MemStore()
        ..data = Qq8TokenData(
          uin: 10001,
          savedAt: 'test',
          tgt: _hex('1122334455667788'),
          d2: _hex('a2' * 64),
          d2key: _hex('a3' * 16),
          sigKey: _hex('a4' * 48),
          ticketKey: _hex('a5' * 16),
          srmToken: _hex('a6' * 56),
        ),
      deviceBuilder: _fixtureDevice,
      ecdhBuilder: () => _fixedEcdh,
      transportBuilder: () => scripted3,
      gate: okGate,
      timeout: const Duration(seconds: 5),
    );
    await svc3.loginWithToken(uin: 10001);
    check('闸门全开：正常登录并上线',
        svc3.snapshot.stage == Qq8LoginStage.online, svc3.snapshot.stage.name);
    await svc3.close();
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
