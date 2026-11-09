// PC 收消息（PushMsg）离线自测：合成 PushMsg 字节验证解析。
import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/kernel/wlogin8/pc/pc_message.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_proto.dart';

int _pass = 0, _fail = 0;
void ok(String n) { _pass++; stdout.writeln('  ✓ $n'); }
void bad(String n, String d) { _fail++; stdout.writeln('  ✗ $n\n      → $d'); }
void check(String n, bool c, [String d = '']) => c ? ok(n) : bad(n, d);
void checkEq(String n, Object? a, Object? b) =>
    ('$a' == '$b') ? ok(n) : bad(n, '期望 $b，实际 $a');
void section(String t) => stdout.writeln('\n$t');

Uint8List _elemText(String s) {
  final text = (PbWriter()..writeString(1, s)).toBytes(); // Text{1:textMsg}
  return (PbWriter()..writeBytes(1, text)).toBytes(); // Elem{1:text}
}

Uint8List _commonMessage({
  required int fromUin,
  required int toUin,
  required int groupCode,
  required int type,
  required int time,
  required int seq,
  required List<String> texts,
}) {
  final routing = PbWriter()..writeInt(1, fromUin)..writeInt(5, toUin);
  if (groupCode != 0) {
    routing.writeBytes(8, (PbWriter()..writeInt(1, groupCode)..writeString(7, '群名')).toBytes());
  }
  final content = (PbWriter()..writeInt(1, type)..writeInt(6, time)..writeInt(5, seq)).toBytes();
  final richText = PbWriter();
  for (final t in texts) {
    richText.writeBytes(2, _elemText(t)); // RichText{2: Elem...}
  }
  final body = (PbWriter()..writeBytes(1, richText.toBytes())).toBytes();
  return (PbWriter()
        ..writeBytes(1, routing.toBytes())
        ..writeBytes(2, content)
        ..writeBytes(3, body))
      .toBytes();
}

void main() {
  section('1. 好友文本消息');
  {
    final msg = _commonMessage(
        fromUin: 10001, toUin: 20002, groupCode: 0, type: 166, time: 1700000000, seq: 5, texts: ['你好', '世界']);
    final push = (PbWriter()..writeBytes(1, msg)).toBytes();
    final m = PcMessageService.parsePushMsg(push);
    checkEq('type=166', m.type, 166);
    checkEq('fromUin', m.fromUin, 10001);
    checkEq('toUin', m.toUin, 20002);
    checkEq('isGroup=false', m.isGroup, false);
    checkEq('time', m.time, 1700000000);
    checkEq('seq', m.sequence, 5);
    checkEq('text 拼接', m.text, '你好世界');
  }

  section('2. 群文本消息');
  {
    final msg = _commonMessage(
        fromUin: 30003, toUin: 0, groupCode: 8090, type: 82, time: 1700000001, seq: 9, texts: ['群消息']);
    final m = PcMessageService.parseCommonMessage(msg);
    checkEq('type=82', m.type, 82);
    checkEq('groupCode', m.groupCode, 8090);
    checkEq('groupName', m.groupName, '群名');
    checkEq('isGroup=true', m.isGroup, true);
    checkEq('fromUin', m.fromUin, 30003);
    checkEq('text', m.text, '群消息');
  }

  section('3. 命令常量');
  {
    checkEq('msgPushCmd', PcMessageService.msgPushCmd, 'trpc.msg.olpush.OlPushService.MsgPush');
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
