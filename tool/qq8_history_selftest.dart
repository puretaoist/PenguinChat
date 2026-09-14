/// 拉消息与历史（`qq8_history.dart`）离线自测
///
/// ⚠️ **没有真机样本**（协议线还没上线成功），所以没有黄金向量：请求体按
/// **官方 pb 字段号**构造后逐字段断言，响应用手搓 pb 走一遍解析。
/// 字段号出处见 `lib/kernel/wlogin8/qq8_history.dart` 头注。
///
/// 运行：
/// ```bash
/// dart run tool/qq8_history_selftest.dart
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/wlogin8/qq8_history.dart';
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

const int _me = 10001;

/// 一条 `msg_comm.Msg`（字段号同官方定义）。
Uint8List _msg({
  required int from,
  required int to,
  int msgType = 9,
  int seq = 1,
  int time = 1700000000,
  int uid = 0,
  Map<int, Object?>? groupInfo,
  String text = '你好',
}) =>
    Qq8Pb.encode(<int, Object?>{
      1: <int, Object?>{
        1: from,
        2: to,
        3: msgType,
        5: seq,
        6: time,
        7: uid,
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

int? _intOf(Uint8List pb, int tag) => Qq8Pb.intAt(Qq8Pb.decode(pb), tag);
Uint8List? _bytesOf(Uint8List pb, int tag) =>
    Qq8Pb.bytesAt(Qq8Pb.decode(pb), tag);

void main() {
  stdout.writeln('拉消息 / 历史离线自测（字段号照官方 8.9.50 pb 定义）');
  stdout.writeln('=' * 62);

  // ----------------------------------------------------------------
  section('1. 拉新消息（MessageSvc.PbGetMsg）请求体');
  {
    final body = Qq8History.buildGetMsgBody(
      syncCookie: Uint8List.fromList(<int>[0xAA, 0xBB, 0xCC]),
    );
    check('sync_flag=0 / ramble_flag=0', _intOf(body, 1) == 0 && _intOf(body, 3) == 0);
    check('sync_cookie 带上（bytes）',
        _bytesOf(body, 2)?.length == 3, '${_bytesOf(body, 2)?.length}');
    check('latest_ramble_number=20 / other_ramble_number=3',
        _intOf(body, 4) == 20 && _intOf(body, 5) == 3);
    check('online_sync_flag=1 / context_flag=1 / msg_req_type=1',
        _intOf(body, 6) == 1 && _intOf(body, 7) == 1 && _intOf(body, 9) == 1);
    final first = Qq8History.buildGetMsgBody();
    check('首次拉取（无 cookie）不带 tag2', _bytesOf(first, 2) == null);
  }

  // ----------------------------------------------------------------
  section('2. 拉新消息响应：按对端分组解析');
  {
    final payload = Qq8Pb.encode(<int, Object?>{
      1: 0, // result
      3: Uint8List.fromList(<int>[1, 2, 3, 4]), // sync_cookie（要回写）
      5: <Uint8List>[
        Qq8Pb.encode(<int, Object?>{
          2: 22222, // peer_uin
          4: <Uint8List>[
            _msg(from: 22222, to: _me, seq: 11, text: '在吗'),
            _msg(from: _me, to: 22222, seq: 12, text: '在'),
          ],
          5: 3, // unread_msg_num
        }),
        Qq8Pb.encode(<int, Object?>{
          2: 33333,
          4: <Uint8List>[
            _msg(
              from: 44444,
              to: _me,
              msgType: 82,
              seq: 99,
              groupInfo: {1: 987654321, 8: '测试群'},
              text: '群里的话',
            ),
          ],
          5: 0,
        }),
      ],
    });
    final page = Qq8History.parseGetMsg(payload);
    check('result=0 / ok', page.ok && page.result == 0);
    check('sync_cookie 解出（4B，要回写下次请求）',
        page.syncCookie?.length == 4, '${page.syncCookie?.length}');
    check('两个会话块，peer/未读数解出',
        page.blocks.length == 2 &&
            page.blocks[0].peerUin == 22222 &&
            page.blocks[0].unreadCount == 3 &&
            page.blocks[1].peerUin == 33333,
        page.blocks.map((b) => '${b.peerUin}/${b.unreadCount}').join(' '));
    check('摊平后 3 条消息，文本/方向都对',
        page.messages.length == 3 &&
            page.messages[0].text == '在吗' &&
            page.messages[0].isSelf(_me) == false &&
            page.messages[1].isSelf(_me) == true &&
            page.messages[2].text == '群里的话',
        page.messages.map((m) => m.text).join('|'));
    check('群消息从 msg_type=82 认出 kind=group（不靠命令字）',
        page.messages[2].kind == Qq8IncomingKind.group &&
            page.messages[2].groupCode == 987654321,
        '${page.messages[2].kind.name} ${page.messages[2].groupCode}');
    check('群消息 chatId = 群号', page.messages[2].chatId(_me) == 987654321);

    final fail = Qq8History.parseGetMsg(
        Qq8Pb.encode(<int, Object?>{1: 3, 2: '拉取被拒'}));
    check('失败响应：result=3 + 文案，消息为空',
        !fail.ok && fail.errmsg == '拉取被拒' && fail.messages.isEmpty);
  }

  // ----------------------------------------------------------------
  section('3. 私聊历史（PbGetOneDayRoamMsg）');
  {
    final req = Qq8History.buildOneDayRoamBody(
        peerUin: 22222, lastMsgTime: 1700000123, readCnt: 20);
    check('请求体：peer_uin / last_msgtime / random=0 / read_cnt',
        _intOf(req, 1) == 22222 &&
            _intOf(req, 2) == 1700000123 &&
            _intOf(req, 3) == 0 &&
            _intOf(req, 4) == 20);

    final resp = Qq8Pb.encode(<int, Object?>{
      1: 0,
      3: 22222,
      4: 1699999999,
      6: <Uint8List>[
        _msg(from: 22222, to: _me, seq: 5, text: '今天的记录'),
        _msg(from: _me, to: 22222, seq: 6, text: '嗯'),
      ],
      7: 1, // iscomplete
    });
    final page = Qq8History.parseOneDayRoam(resp);
    check('两条历史 + iscomplete 解出',
        page.ok && page.messages.length == 2 && page.isComplete == true,
        '${page.messages.length} complete=${page.isComplete}');
    check('历史消息的 seq/文本/方向正确',
        page.messages[0].seq == 5 &&
            page.messages[0].text == '今天的记录' &&
            !page.messages[0].isSelf(_me) &&
            page.messages[1].isSelf(_me),
        '');
    check('私聊历史按 kindHint=c2c 定 kind（哪怕 msg_type 空缺）',
        page.messages[0].kind == Qq8IncomingKind.c2c);
  }

  // ----------------------------------------------------------------
  section('4. 群历史（PbGetGroupMsg）');
  {
    final req = Qq8History.buildGroupMsgBody(
        groupCode: 987654321, beginSeq: 981, endSeq: 1000);
    check('请求体：group_code / begin_seq / end_seq / public_group=0',
        _intOf(req, 1) == 987654321 &&
            _intOf(req, 2) == 981 &&
            _intOf(req, 3) == 1000 &&
            _intOf(req, 6) == 0);

    final resp = Qq8Pb.encode(<int, Object?>{
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
          groupInfo: {1: 987654321},
          text: '群历史一',
        ),
      ],
    });
    final page = Qq8History.parseGroupMsg(resp);
    check('返回的实际 seq 区间解出',
        page.returnBeginSeq == 981 && page.returnEndSeq == 1000,
        '${page.returnBeginSeq}-${page.returnEndSeq}');
    check('群历史消息解出且 kind=group',
        page.messages.length == 1 &&
            page.messages[0].kind == Qq8IncomingKind.group &&
            page.messages[0].text == '群历史一',
        page.messages.isEmpty ? '(空)' : page.messages[0].text);

    final empty = Qq8History.parseGroupMsg(Qq8Pb.encode(<int, Object?>{1: 0}));
    check('空响应（无 tag6）→ 0 条，不炸',
        empty.ok && empty.messages.isEmpty);
  }

  // ----------------------------------------------------------------
  section('5. 与推送共用同一套消息解析');
  {
    final raw = _msg(from: 22222, to: _me, seq: 7, text: '共用解析');
    final viaPush = qq8ParseMsg(raw);
    final inHistory = Qq8History.parseOneDayRoam(
      Qq8Pb.encode(<int, Object?>{
        1: 0,
        6: <Uint8List>[raw],
      }),
    ).messages.single;
    check('同一条 Msg 在两边的字段完全一致（文本/seq/rand/time）',
        viaPush != null &&
            viaPush.text == inHistory.text &&
            viaPush.seq == inHistory.seq &&
            viaPush.rand == inHistory.rand &&
            viaPush.time == inHistory.time,
        '');
    check('缺 msg_head 时 qq8ParseMsg 返回 null（不编）',
        qq8ParseMsg(Qq8Pb.encode(<int, Object?>{3: Uint8List(1)})) == null);
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
