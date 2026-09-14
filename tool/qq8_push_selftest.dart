/// 在线推送解析（`qq8_push.dart`）离线自测
///
/// ⚠️ **没有真机推送样本**（协议线还没上线成功过），所以这里没有黄金向量：
/// 所有负载都用 `Qq8Pb`/`Qq8Jce` 按**官方 8.9.50 的 pb 定义字段号**手搓，
/// 再做"手搓 → 解析 → 逐字段断言 + 关键值独立复算"。
///
/// 官方字段号出处见 `lib/kernel/wlogin8/qq8_push.dart` 头注。
///
/// 运行：
/// ```bash
/// dart run tool/qq8_push_selftest.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/wlogin8/qq8_elem.dart';
import 'package:qqclient/kernel/wlogin8/qq8_jce.dart';
import 'package:qqclient/kernel/wlogin8/qq8_msg.dart';
import 'package:qqclient/kernel/wlogin8/qq8_pb.dart';
import 'package:qqclient/kernel/wlogin8/qq8_push.dart';

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

/// 我自己的 uin（自测里固定一个）。
const int _me = 10001;

/// 私聊消息的 body 元素：纯文本。
Uint8List _textElem(String s) => Qq8Pb.encode({
      1: {1: s},
    });

/// 私聊消息的 body 元素：@ 某人（`text[3] = attr_6_buf`）。
Uint8List _atElem(int uin) => Qq8Pb.encode({
      1: {
        1: '@$uin ',
        3: Uint8List.fromList(<int>[
          0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
          (uin >> 24) & 0xff, (uin >> 16) & 0xff, (uin >> 8) & 0xff, uin & 0xff,
        ]),
      },
    });

/// 元素：@ 全体成员。
Uint8List _atAllElem() => Qq8Pb.encode({
      1: {
        1: '@全体成员 ',
        3: Uint8List.fromList(<int>[
          0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01,
        ]),
      },
    });

/// 「保留元素」`37 = general_flags`（每条消息末尾都带，不该污染文本）。
Uint8List _flagsElem() => Qq8Pb.encode({
      37: {
        17: 0,
        19: {15: 0, 31: 0, 41: 0},
      },
    });

/// 一条推送的完整外三层：`PbPushMsg{1: Msg{1: MsgHead, 2: ContentHead, 3: MsgBody}}`。
///
/// [richExtra] 用于 `RichText` 上除 `attr`/`elems` 之外的字段——目前只有语音
/// （`ptt` = 4；它**不在 elems 里**，见 qq8_elem.dart 的 scanPtt）。
Uint8List _buildPush({
  required Map<int, Object?> head,
  Map<int, Object?>? content,
  required List<Uint8List> elems,
  Map<int, Object?>? richAttr,
  Map<int, Object?>? richExtra,
  Map<int, Object?>? outer,
}) {
  final rich = <int, Object?>{2: elems, ...?richExtra};
  if (richAttr != null) rich[1] = richAttr;
  final msg = <int, Object?>{1: head, 3: {1: rich}};
  if (content != null) msg[2] = content;
  return Qq8Pb.encode(<int, Object?>{
    1: msg,
    ...?outer,
  });
}

void main() {
  stdout.writeln('在线推送解析离线自测（字段号照官方 8.9.50 pb 定义）');
  stdout.writeln('=' * 62);

  // ----------------------------------------------------------------
  section('1. 私聊直推（OnlinePush.PbPushC2CMsg）');
  {
    final push = _buildPush(
      head: {
        1: 22222, // from_uin
        2: _me, // to_uin
        3: 9, // msg_type
        4: 0, // c2c_cmd
        5: 1234, // msg_seq
        6: 1700000000, // msg_time
        7: 0x1234567890ABCDEF, // msg_uid
        14: '小明',
      },
      content: {1: 1, 2: 0, 3: 0},
      richAttr: {3: 0xAABBCCDD, 9: 'Times New Roman'},
      elems: [_textElem('你好'), _flagsElem()],
      outer: {2: 0x0A0B0C0D, 3: Uint8List.fromList([1, 2, 3]), 4: 0, 9: 0, 10: 0},
    );
    final ev = qq8ParsePush(Qq8PushCmd.pushC2c, push);
    check('解析成 Qq8MessagePush', ev is Qq8MessagePush);
    if (ev is Qq8MessagePush) {
      final m = ev.message;
      check('kind = c2c', m.kind == Qq8IncomingKind.c2c);
      check('from/to/seq/time 解出',
          m.fromUin == 22222 && m.toUin == _me && m.seq == 1234 && m.time == 1700000000,
          '${m.fromUin}->${m.toUin} seq=${m.seq} t=${m.time}');
      check('rand 取 rich_text.attr.random（不是 msg_uid）',
          m.rand == 0xAABBCCDD, m.rand.toRadixString(16));
      check('字体名解出', m.font == 'Times New Roman', m.font);
      check('文本拼接正确（保留元素不污染）', m.text == '你好', m.text);
      check('from_nick = 小明', m.fromNick == '小明', '${m.fromNick}');
      check('svrip / push_token 带出',
          ev.svrip == 0x0A0B0C0D && ev.pushToken?.length == 3, '${ev.svrip}');
      check('私聊直推不回执（参考实现没注册该命令）', !ev.needsAck);
      check('chatId = 对方 uin', m.chatId(_me) == 22222, '${m.chatId(_me)}');
      check('isSelf=false（别人发的）', !m.isSelf(_me));
      // 独立复算私聊消息 ID：u32 对方 ‖ u32 seq ‖ u32 rand ‖ u32 time ‖ u8 flag
      final raw = base64.decode(m.messageId(_me));
      int u32(int i) => (raw[i] << 24) | (raw[i + 1] << 16) | (raw[i + 2] << 8) | raw[i + 3];
      check('messageId 独立复算（dm：对方/seq/rand/time/flag）',
          raw.length == 17 &&
              u32(0) == 22222 &&
              u32(4) == 1234 &&
              u32(8) == 0xAABBCCDD &&
              u32(12) == 1700000000 &&
              raw[16] == 0,
          'len=${raw.length}');
    }
  }

  // ----------------------------------------------------------------
  section('2. 群消息（OnlinePush.PbPushGroupMsg，含 @）');
  {
    final push = _buildPush(
      head: {
        1: 33333, // from_uin（群成员）
        2: _me,
        3: 82, // 群
        5: 777,
        6: 1700000100,
        7: 0x11, // msg_uid（无 attr.random 时取低 32 位）
        9: {1: 987654321, 8: '测试群'}, // group_info
        14: '阿花',
      },
      content: {1: 2, 2: 0, 3: 0}, // pkg_num=2（分片）
      elems: [
        _textElem('看这个 '),
        _atElem(_me),
        _atAllElem(),
        _flagsElem(),
      ],
    );
    final ev = qq8ParsePush(Qq8PushCmd.pushGroup, push);
    check('解析成 Qq8MessagePush', ev is Qq8MessagePush);
    if (ev is Qq8MessagePush) {
      final m = ev.message;
      check('kind = group / 群号 / 群名',
          m.kind == Qq8IncomingKind.group &&
              m.groupCode == 987654321 &&
              m.groupName == '测试群',
          '${m.groupCode} ${m.groupName}');
      check('rand 回退到 msg_uid 低 32 位', m.rand == 0x11, '${m.rand}');
      check('文本含两段 @ 的原文', m.text == '看这个 @$_me @全体成员 ', m.text);
      check('atMe(我) = true；别人为 false',
          m.atMe(_me) && !m.atMe(44444));
      check('atAll = true → mentions(任何人) = true', m.atAll && m.mentions(44444));
      check('pktNum=2 解出（分片）', m.pktNum == 2, '${m.pktNum}');
      check('元素类型串对（text/at/at/flags）',
          m.elemKinds.join(',') == 'text,at,at,flags', m.elemKinds.join(','));
      check('群消息不回执（参考实现行为）', !ev.needsAck);
      check('chatId = 群号', m.chatId(_me) == 987654321, '${m.chatId(_me)}');
      // 群消息 ID：u32 群号 ‖ u32 发送者 ‖ u32 seq ‖ u32 rand ‖ u32 time ‖ u8 pktnum
      final raw = base64.decode(m.messageId(_me));
      int u32(int i) => (raw[i] << 24) | (raw[i + 1] << 16) | (raw[i + 2] << 8) | raw[i + 3];
      check('messageId 独立复算（群：群号/成员/seq/rand/time/pktnum）',
          raw.length == 21 &&
              u32(0) == 987654321 &&
              u32(4) == 33333 &&
              u32(8) == 777 &&
              u32(16) == 1700000100 &&
              raw[20] == 2,
          'len=${raw.length}');
    }
  }

  // ----------------------------------------------------------------
  section('3. 讨论组 / 多端同步 / 群临时会话');
  {
    final discuss = _buildPush(
      head: {
        1: 55555,
        2: _me,
        3: 83,
        5: 8,
        6: 1700000200,
        13: {1: 123456}, // discuss_info.discuss_uin
      },
      elems: [_textElem('讨论组消息')],
      outer: {2: 7},
    );
    final evD = qq8ParsePush(Qq8PushCmd.pushDiscuss, discuss);
    check('讨论组：kind=discuss、discussUin 解出、要回执',
        evD is Qq8MessagePush &&
            evD.message.kind == Qq8IncomingKind.discuss &&
            evD.message.discussUin == 123456 &&
            evD.needsAck,
        evD is Qq8MessagePush ? '${evD.message.discussUin}' : '');

    final sync = _buildPush(
      head: {1: _me, 2: 22222, 3: 9, 5: 3, 6: 1700000300},
      elems: [_textElem('我在手机上发的')],
      outer: {2: 7},
    );
    final evS = qq8ParsePush(Qq8PushCmd.c2cSync, sync);
    check('多端同步：kind=c2c、isSelf=true、要回执',
        evS is Qq8MessagePush &&
            evS.message.kind == Qq8IncomingKind.c2c &&
            evS.message.isSelf(_me) &&
            evS.needsAck,
        '');

    final tmp = _buildPush(
      head: {
        1: 66666,
        2: _me,
        3: 9,
        4: 141, // c2c_cmd = 来自群的临时会话
        5: 4,
        6: 1700000400,
        8: {1: 1, 2: 0, 3: 987654321, 4: 987654321}, // c2c_tmp_msg_head
      },
      elems: [_textElem('群临时会话')],
    );
    final evT = qq8ParsePush(Qq8PushCmd.pushC2c, tmp);
    check('群临时会话：c2cCmd=141、groupCode 取自 tmp_head',
        evT is Qq8MessagePush &&
            evT.message.c2cCmd == 141 &&
            evT.message.groupCode == 987654321,
        evT is Qq8MessagePush ? '${evT.message.groupCode}' : '');
  }

  section('4. 认得出 / 认不出的元素：都要有东西显示，不能是空气泡');
  {
    final xmlElem = Qq8Pb.encode({
      12: {1: Uint8List.fromList(utf8.encode('<msg/>'))},
    });
    final imgElem = Qq8Pb.encode({
      4: {1: Uint8List(8), 2: 12345},
    });
    // 真·认不出的字段号（参考实现里查不到 100）
    final unknownElem = Qq8Pb.encode({
      100: {1: 5},
    });
    final push = _buildPush(
      head: {1: 22222, 2: _me, 3: 9, 5: 1, 6: 1700},
      elems: [_textElem('照片：'), imgElem, xmlElem, unknownElem, _flagsElem()],
    );
    final ev = qq8ParsePush(Qq8PushCmd.pushC2c, push);
    if (ev is Qq8MessagePush) {
      // 认得出的（图片、卡片）在纯文本里留官方占位，会话列表摘要才不会空白；
      // 认不出的也给一句 `[不支持显示的消息]`——**空字符串正是空气泡的根因**。
      check('文本 = 原文 + 各类占位（保留元素不掺进来）',
          ev.message.text == '照片：[图片][卡片消息][不支持显示的消息]',
          ev.message.text);
      check('类型名逐个记下（含 unknown(100)）',
          ev.message.elemKinds.join(',') == 'text,image,xml,unknown(100),flags',
          ev.message.elemKinds.join(','));
      check('认得出的进 elems、认不出的给占位段（顺序不变）',
          ev.message.elems.length == 4 &&
              ev.message.elems[0] is Qq8TextElem &&
              ev.message.elems[1] is Qq8ImageElem &&
              ev.message.elems[2] is Qq8CardElem &&
              ev.message.elems[3] is Qq8UnsupportedElem,
          '${ev.message.elems}');
    } else {
      check('解析成 Qq8MessagePush', false, ev.runtimeType.toString());
    }
  }

  section('5. 被踢下线（JCE）与通知');
  {
    final kick = Qq8Jce.encodeWrapper(
      service: 'x',
      method: 'y',
      attributes: {
        'r': Qq8Jce.encodeStruct({3: '被迫下线：你的账号在另一台设备登录', 4: '安全提示'}),
      },
    );
    final ev = qq8ParsePush(Qq8PushCmd.forceOffline, kick);
    check('被踢包解成 Qq8KickPush 且 hint = [4]3',
        ev is Qq8KickPush && ev.hint == '[安全提示]被迫下线：你的账号在另一台设备登录',
        ev is Qq8KickPush ? ev.hint : ev.runtimeType.toString());

    final kick2 = Qq8Jce.encodeWrapper(
      service: 'x',
      method: 'y',
      attributes: {
        'r': Qq8Jce.encodeStruct({1: '标题', 2: '内容'}),
      },
    );
    final ev2 = qq8ParsePush(Qq8PushCmd.reqMsfOffline, kick2);
    check('没有 [4] 时退回 [1]2', ev2 is Qq8KickPush && ev2.hint == '[标题]内容',
        ev2 is Qq8KickPush ? ev2.hint : '');

    final notify = Qq8Jce.encodeWrapper(
      service: 'x',
      method: 'y',
      attributes: {
        'r': Qq8Jce.encodeStruct({5: 33, 1: 22222}),
      },
    );
    final withPrefix = Uint8List.fromList([0, 0, 0, 0, ...notify]);
    final evN = qq8ParsePush(Qq8PushCmd.notify, withPrefix);
    check('通知（4 字节前缀）解出 notifyType=33',
        evN is Qq8NotifyPush && evN.notifyType == 33,
        evN is Qq8NotifyPush ? '${evN.notifyType}' : evN.runtimeType.toString());

    final evN2 = qq8ParsePush(Qq8PushCmd.notify, notify);
    check('通知（无前缀）也解出 notifyType=33',
        evN2 is Qq8NotifyPush && evN2.notifyType == 33, '');
  }

  // ----------------------------------------------------------------
  section('6. 边角：未知命令、缺 msg、畸形包');
  {
    final ev = qq8ParsePush('SomeSvc.Unknown', Uint8List.fromList([1, 2, 3]));
    check('未知命令字 → Qq8UnknownPush（附说明）',
        ev is Qq8UnknownPush && ev.note == '命令字未注册' && ev.payloadLength == 3,
        ev is Qq8UnknownPush ? '${ev.note}' : '');

    final noMsg = qq8ParsePush(
        Qq8PushCmd.pushC2c, Qq8Pb.encode({2: 7, 3: Uint8List(2)}));
    check('PbPushMsg 里没有 msg(1) → UnknownPush（不猜）',
        noMsg is Qq8UnknownPush && noMsg.note == '没有 msg(1) 字段',
        noMsg is Qq8UnknownPush ? '${noMsg.note}' : '');

    var threw = false;
    try {
      qq8ParsePush(Qq8PushCmd.pushC2c, Uint8List.fromList([0x0a, 0x10, 0x01]));
    } on Qq8PbException {
      threw = true;
    }
    check('截断的 pb → 抛 Qq8PbException（上层兜底，见文件头）', threw);
  }

  // ----------------------------------------------------------------
  section('7. 多元素：图片 / 表情（字段号见 qq8_elem.dart 文件头）');
  {
    // 私聊图（Elem 4 = NotOnlineImage）：md5 用 hex 串形式（字段 1）。
    final c2cImg = Qq8Pb.encode({
      4: {
        1: '00112233445566778899aabbccddeeff',
        2: 40960, // size
        5: 1000, // 类型 jpg
        8: 240, // 高（注意：8 是高、9 是宽）
        9: 320, // 宽
        10: 'FID-C2C-1',
        29: {1: 1, 30: '/offpic/xyz'},
      },
    });
    // 群图（Elem 8 = CustomFace）：md5 是字节（字段 13）。
    final grpImg = Qq8Pb.encode({
      8: {
        2: '00112233445566778899aabbccddeeff.gif',
        7: 'FID-GRP-1',
        13: Uint8List.fromList(
            List<int>.generate(16, (i) => 0x10 + i)),
        16: '/gchatpic_new/1/2-3-4/0',
        20: 1001, // png
        22: 200, // 宽
        23: 100, // 高
        25: 12345, // size
      },
    });
    // 小表情（Elem 2 = Face{1: id}）与大表情（Elem 53 serviceType=33）。
    final face = Qq8Pb.encode({
      2: {1: 14},
    });
    final bigFace = Qq8Pb.encode({
      53: {
        1: 33,
        2: Qq8Pb.encode({1: 271, 2: '/吃瓜', 3: '/吃瓜'}),
        3: 1,
      },
    });
    // 闪照：common_elem serviceType=3，pb_elem 里 1 号字段是那张图。
    final flash = Qq8Pb.encode({
      53: {
        1: 3,
        2: Qq8Pb.encode({
          1: Qq8Pb.encode({
            1: 'aabbccddeeff00112233445566778899',
            2: 2048,
            5: 1000,
            8: 400,
            9: 300,
          }),
        }),
      },
    });

    final push = _buildPush(
      head: {1: 22222, 2: _me, 3: 9, 4: 0, 5: 77, 6: 1700000000, 7: 1},
      richAttr: {3: 0x1234, 9: 'Arial'},
      elems: [
        _textElem('看这张'),
        c2cImg,
        grpImg,
        face,
        bigFace,
        flash,
        _flagsElem(),
      ],
    );
    final ev = qq8ParsePush(Qq8PushCmd.pushC2c, push);
    check('解析成 Qq8MessagePush', ev is Qq8MessagePush);
    if (ev is Qq8MessagePush) {
      final m = ev.message;
      check('元素类型串：text/image/image/face/face/image/flags',
          m.elemKinds.join('/') == 'text/image/image/face/face/image/flags',
          m.elemKinds.join('/'));
      check('纯文本里留下占位（会话列表摘要要看得到东西）',
          m.text == '看这张[动画表情][图片][表情][表情][闪照]', m.text);
      check('elems 数量与顺序对（文本+5 个非文本元素）', m.elems.length == 6,
          '${m.elems.length}');
      check('elems 里没有"保留元素"（37 被排除）',
          !m.elems.any((e) => e is! Qq8TextElem && e is! Qq8ImageElem &&
              e is! Qq8FaceElem));

      final imgs = m.elems.whereType<Qq8ImageElem>().toList();
      check('识别出 3 张图（私聊图/群图/闪照）', imgs.length == 3, '${imgs.length}');
      if (imgs.length == 3) {
        final c2c = imgs[0];
        check('私聊图：宽高按 9/8 取（不是 8/9）',
            c2c.width == 320 && c2c.height == 240,
            '${c2c.width}x${c2c.height}');
        check('私聊图：文件名 = md5+大小-宽-高.扩展名',
            c2c.file == '00112233445566778899aabbccddeeff40960-320-240.jpg',
            c2c.file);
        check('私聊图：直链 = c2cpicdw + 29.30 + spec',
            c2c.url == 'https://c2cpicdw.qpic.cn/offpic/xyz&spec=0&rf=naio',
            '${c2c.url}');
        check('私聊图：29.1=1 → 动画表情', c2c.asFace && !c2c.group);

        final grp = imgs[1];
        check('群图：宽高取 22/23',
            grp.width == 200 && grp.height == 100, '${grp.width}x${grp.height}');
        check('群图：md5 从字节解出（小写 hex）',
            grp.md5 == '101112131415161718191a1b1c1d1e1f', '${grp.md5}');
        check('群图：直链 = gchat + 16 号字段',
            grp.url == 'https://gchat.qpic.cn/gchatpic_new/1/2-3-4/0', '${grp.url}');
        check('群图：文件名用 20/22/23/25 拼',
            grp.file == '101112131415161718191a1b1c1d1e1f12345-200-100.png',
            grp.file);

        final fl = imgs[2];
        check('闪照：标记为 flash 且摘要是 [闪照]', fl.flash && fl.summary == '[闪照]');
      }

      final faces = m.elems.whereType<Qq8FaceElem>().toList();
      check('识别出 2 个表情，第二个是大表情',
          faces.length == 2 && !faces[0].isBig && faces[1].isBig,
          faces.map((f) => '${f.id}${f.isBig ? '!' : ''}').join(','));
      check('小表情 id = 14（微笑）', faces[0].id == '14', faces[0].id);
      check('大表情 id = 271（/吃瓜）', faces[1].id == '271', faces[1].id);
    }

    // 表情名表：照着参考实现 face.ts 抄的，抽查几条（含超级表情的斜杠写法）
    check('名字表：14 → 微笑', Qq8FaceNames.nameOf('14') == '微笑');
    check('名字表：/吃瓜 → 271', Qq8FaceNames.idOf('/吃瓜') == 271);
    check('名字表：超级表情也接受不带斜杠的写法',
        Qq8FaceNames.idOf('吃瓜') == 271);
    check('名字表：查不到就是 null（不瞎猜）',
        Qq8FaceNames.nameOf('99999') == null && Qq8FaceNames.idOf('不存在') == null);
    check('名字表：面板里的表情 id 都能查到名字',
        Qq8FaceNames.common.every((id) => Qq8FaceNames.nameOf('$id') != null));
  }

  // ----------------------------------------------------------------
  section('8. 补齐的消息类型：语音 / 视频 / 文件 / 卡片 / 戳一戳 / 认不出');
  {
    // 语音：**在 RichText.ptt（字段 4）里，不在 elems 里**
    final ptt = Qq8Pb.encode({
      4: Uint8List.fromList(List<int>.generate(16, (i) => i)),
      6: 8192,
      19: 12,
      20: '/voice/abc.silk',
    });
    final voicePush = _buildPush(
      head: {1: 22222, 2: _me, 3: 9, 5: 88, 6: 1700},
      richAttr: {3: 1, 9: 'Arial'},
      elems: [_flagsElem()],
      richExtra: {4: ptt},
    );
    final vEv = qq8ParsePush(Qq8PushCmd.pushC2c, voicePush);
    check('语音能解出来', vEv is Qq8MessagePush);
    if (vEv is Qq8MessagePush) {
      final m = vEv.message;
      check('语音文案 = [语音]', m.text == '[语音]', m.text);
      final v = m.elems.whereType<Qq8VoiceElem>().firstOrNull;
      check('语音：秒数 12、大小 8192',
          v != null && v.seconds == 12 && v.size == 8192,
          '${v?.seconds}s ${v?.size}B');
      check('语音：直链补上 grouptalk 域名（服务端只给后缀）',
          v?.url == 'https://grouptalk.c2c.qq.com/voice/abc.silk', '${v?.url}');
      check('语音：md5 从字节转十六进制',
          v?.md5 == '000102030405060708090a0b0c0d0e0f', '${v?.md5}');
      check('语音的 elemKinds 记为 voice', m.elemKinds.contains('voice'));
    }

    // 视频（Elem 19）：1 = fid、2 = md5、3 = 文件名、5 = 秒数、6 = 大小
    final video = Qq8Pb.encode({
      19: {
        1: 'FID-VIDEO',
        2: Uint8List.fromList(List<int>.generate(16, (i) => 0xa0 + i)),
        3: 'funny.mp4',
        5: 15,
        6: 1048576,
      },
    });
    // 群文件（Elem 5）：5.2 前三字节是头 → 7.2 里才是文件信息
    final fileInner = Qq8Pb.encode({
      2: '/fid-abc',
      3: 2048,
      4: '报告.pdf',
      5: 0,
      8: 'd41d8cd98f00b204e9800998ecf8427e',
    });
    final fileElem = Qq8Pb.encode({
      5: {
        2: Uint8List.fromList(<int>[0, 0, 1, ...Qq8Pb.encode({7: {2: fileInner}})]),
      },
    });
    // 卡片：12 = xml，首字节 1 表示后面是 zlib 压缩的
    const xml = '<msg serviceID="1" brief="[分享] 一篇文章" url="https://x"/>';
    final xmlPlain = Qq8Pb.encode({
      12: {
        1: Uint8List.fromList(<int>[0, ...utf8.encode(xml)]),
        2: 7,
      },
    });
    final xmlZlib = Qq8Pb.encode({
      12: {
        1: Uint8List.fromList(<int>[1, ...zlib.encode(utf8.encode(xml))]),
        2: 8,
      },
    });
    // 戳一戳：commonElem serviceType = 2
    final poke = Qq8Pb.encode({
      53: {
        1: 2,
        2: Qq8Pb.encode({1: 1}),
        3: 1,
      },
    });
    // 认不出的类型：字段 126（参考实现里叫 poke，但线上语义我们没核对过）
    final unknown = Qq8Pb.encode({
      126: {1: 5},
    });

    final push = _buildPush(
      head: {1: 22222, 2: _me, 3: 9, 5: 89, 6: 1700},
      richAttr: {3: 2, 9: 'Arial'},
      elems: [video, fileElem, xmlPlain, xmlZlib, poke, unknown, _flagsElem()],
    );
    final ev = qq8ParsePush(Qq8PushCmd.pushC2c, push);
    check('多类型推送能解析', ev is Qq8MessagePush);
    if (ev is Qq8MessagePush) {
      final m = ev.message;
      check('元素类型串对',
          m.elemKinds.join('/') == 'video/file/xml/xml/poke/unknown(126)/flags',
          m.elemKinds.join('/'));

      final vid = m.elems.whereType<Qq8VideoElem>().firstOrNull;
      check('视频：文件名/秒数/大小/fid 都解出来',
          vid?.name == 'funny.mp4' &&
              vid?.seconds == 15 &&
              vid?.size == 1048576 &&
              vid?.fileId == 'FID-VIDEO',
          '${vid?.name} ${vid?.seconds}s');

      final file = m.elems.whereType<Qq8FileElem>().firstOrNull;
      check('文件：三层嵌套解开（名字/大小/fid 去掉 / 前缀）',
          file?.name == '报告.pdf' &&
              file?.size == 2048 &&
              file?.fileId == 'fid-abc',
          '${file?.name} ${file?.size} ${file?.fileId}');

      final cards = m.elems.whereType<Qq8CardElem>().toList();
      check('两种卡片都解出来（未压缩 + zlib 压缩）', cards.length == 2);
      check('未压缩卡片：原文正确、摘要从 brief 属性抠出',
          cards[0].raw == xml && cards[0].summary == '[分享] 一篇文章',
          cards[0].summary);
      check('zlib 压缩卡片：解压后与原文一致', cards[1].raw == xml,
          '${cards[1].raw.length} 字符');
      check('卡片优先用 summary 属性', Qq8CardElem.extractSummary(
              '<msg summary="一句话" brief="另一句"/>') == '一句话');
      check('卡片没有 summary 属性时退回 JSON 的 prompt',
          Qq8CardElem.extractSummary('{"prompt":"点了才知道"}') == '点了才知道');

      check('戳一戳：文案 [戳一戳] 且带 id',
          m.elems.whereType<Qq8PokeElem>().isNotEmpty &&
              m.elems.whereType<Qq8PokeElem>().first.id == 1,
          '${m.elems.whereType<Qq8PokeElem>().firstOrNull?.id}');

      final un = m.elems.whereType<Qq8UnsupportedElem>().firstOrNull;
      check('认不出的元素：字段号与类型名都带出来',
          un != null && un.field == 126 && un.name == 'unknown(126)',
          '${un?.name}/${un?.field}');
      check('纯文本里给官方占位，不再是空字符串（空气泡的根因）',
          m.text ==
              '[视频][文件][卡片] [分享] 一篇文章[卡片] [分享] 一篇文章[戳一戳][不支持显示的消息]',
          m.text);
    }
  }

  // ----------------------------------------------------------------
  section('9. 推送回执（OnlinePush.RespPush：seq 进 iRequestId）');
  {
    final ack = Qq8Msg.buildRespPushAck(uin: 10001, svrip: 0x0A0B0C0D, seq: 4321);
    // 注意：这里要**外层**的包装字段，所以用 decode 而不是 decodeWrapper
    //（后者会一路解到最里面的结构）
    final w = Qq8Jce.decode(ack);
    check('service/method = OnlinePush / SvcRespPushMsg',
        w[5] == 'OnlinePush' && w[6] == 'SvcRespPushMsg',
        '${w[5]}/${w[6]}');
    check('iRequestId = 推送的 seq（参考实现把 seq 塞这里）',
        w[4] == 4321, '${w[4]}');

    final payload = w[7];
    check('sBuffer(7) 是字节串', payload is Uint8List,
        payload is Uint8List ? '${payload.length} 字节' : '${payload.runtimeType}');

    // 属性表里的 'r'：{0: uin, 1: items(空), 2: svrip, 4: 0}
    final attrsOuter = Qq8Jce.decode(payload as Uint8List)[0];
    final nested = attrsOuter as Map<Object?, Object?>;
    final rBytes = nested['r'];
    check('属性表里有 r（回执结构）', rBytes is Uint8List);
    // struct 层外面还套了一层 tag 0（见 encodeStruct），所以取 [0]
    final r = Qq8Jce.decode(rBytes as Uint8List)[0] as Map<int, Object?>;
    check('r[0] = uin', r[0] == 10001, '${r[0]}');
    check('r[1] = 空 items（正常处理完就没有要重发的）',
        r[1] is List && (r[1] as List).isEmpty, '${r[1]}');
    check('r[2] = svrip（u32 原样）', r[2] == 0x0A0B0C0D, '${r[2]}');
    check('r[4] = 0 且没有 3 号字段（参考实现给 null = 不写）',
        r[4] == 0 && !r.containsKey(3), 'keys=${r.keys}');
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
