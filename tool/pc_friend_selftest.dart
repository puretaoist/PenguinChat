// PC 拉好友（OIDB 0xfd4_1 / IncPull）离线自测：验证请求构造与响应解析编解码自洽。
import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/kernel/wlogin8/pc/pc_friend.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_oidb.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_proto.dart';

int _pass = 0, _fail = 0;
void ok(String n) { _pass++; stdout.writeln('  ✓ $n'); }
void bad(String n, String d) { _fail++; stdout.writeln('  ✗ $n\n      → $d'); }
void check(String n, bool c, [String d = '']) => c ? ok(n) : bad(n, d);
void checkEq(String n, Object? a, Object? b) =>
    ('$a' == '$b') ? ok(n) : bad(n, '期望 $b，实际 $a');
void section(String t) => stdout.writeln('\n$t');

void main() {
  section('1. buildIncPull 结构');
  {
    final body = PcFriendService.buildIncPull(reqCount: 300, nextUin: null);
    final r = PbReader(body);
    var reqCount = 0, flag = 0, bizCount = 0;
    var sawCookie = false;
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 2) {
        reqCount = r.readVarint();
      } else if (f == 5) {
        sawCookie = true;
        r.readBytes();
      } else if (f == 6) {
        flag = r.readVarint();
      } else if (f == 10001) {
        bizCount++;
        r.readBytes();
      } else {
        r.skip(w);
      }
    }
    checkEq('reqCount=300', reqCount, 300);
    checkEq('flag=1', flag, 1);
    checkEq('requestBiz 2 个', bizCount, 2);
    check('nextUin=null 时无 cookie', !sawCookie);
    check('cmd = OidbSvcTrpcTcp.0xfd4_1', PcFriendService.cmd == 'OidbSvcTrpcTcp.0xfd4_1',
        PcFriendService.cmd);
  }

  section('2. parseIncPullResp');
  {
    // SubBiz{1:numberProps map, 2:stringProps map} —— map 是「每个 entry 一条 message」直接挂在字段上
    final subBiz = PbWriter();
    for (final e in <List<int>>[
      [20037, 20],
      [20009, 1],
    ]) {
      subBiz.writeBytes(
          1, (PbWriter()..writeInt(1, e[0])..writeInt(2, e[1])).toBytes());
    }
    for (final e in <List<Object>>[
      [20002, 'Alice'],
      [103, '备注A'],
      [102, 'bio-b'],
      [27394, 'qidX'],
    ]) {
      subBiz.writeBytes(2,
          (PbWriter()..writeInt(1, e[0] as int)..writeString(2, e[1] as String)).toBytes());
    }
    final subBizBytes = subBiz.toBytes();
    // SubBizEntry{1:key=1, 2:value=subBiz}
    final entry = (PbWriter()..writeInt(1, 1)..writeBytes(2, subBizBytes)).toBytes();
    // Friend{1:uid,2:categoryId,3:uin,10001:subBizMap[entry]}
    final friend = (PbWriter()
          ..writeString(1, 'u_abc')
          ..writeInt(2, 5)
          ..writeInt(3, 10001)
          ..writeBytes(10001, entry))
        .toBytes();
    final body = (PbWriter()..writeBytes(101, friend)).toBytes();

    final list = PcFriendService.parseIncPullResp(body);
    checkEq('好友数=1', list.length, 1);
    final f = list.first;
    checkEq('uin', f.uin, 10001);
    checkEq('uid', f.uid, 'u_abc');
    checkEq('nickname', f.nickname, 'Alice');
    checkEq('remark', f.remark, '备注A');
    checkEq('bio', f.bio, 'bio-b');
    checkEq('qid', f.qid, 'qidX');
    checkEq('age', f.age, 20);
    checkEq('gender', f.gender, 1);
    checkEq('categoryId', f.categoryId, 5);
  }

  section('3. Oidb 外层封装往返');
  {
    final inner = Uint8List.fromList([1, 2, 3, 4]);
    final pkt = PcOidb.build(command: 0xfd4, service: 1, body: inner);
    final resp = PcOidb.parse(pkt);
    checkEq('command 保留(3=result? 这里 result 不在请求)', resp.result, 0);
    check('body 往返一致', resp.body.length == 4 && resp.body[0] == 1 && resp.body[3] == 4);
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
