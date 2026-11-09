// PC 拉群（OIDB 0xfe5_2 / FetchGroups）离线自测：验证请求构造与响应解析。
import 'dart:io';

import 'package:penguinchat/kernel/wlogin8/pc/pc_group.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_proto.dart';

int _pass = 0, _fail = 0;
void ok(String n) { _pass++; stdout.writeln('  ✓ $n'); }
void bad(String n, String d) { _fail++; stdout.writeln('  ✗ $n\n      → $d'); }
void check(String n, bool c, [String d = '']) => c ? ok(n) : bad(n, d);
void checkEq(String n, Object? a, Object? b) =>
    ('$a' == '$b') ? ok(n) : bad(n, '期望 $b，实际 $a');
void section(String t) => stdout.writeln('\n$t');

void main() {
  section('1. buildFetchGroupsReq 结构');
  {
    final body = PcGroupService.buildFetchGroupsReq();
    final r = PbReader(body);
    var sawConfig = false;
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 1) {
        sawConfig = true;
        final cfg = PbReader(r.readBytes());
        var c1 = false, c2 = false, c3 = false;
        while (!cfg.atEnd) {
          final (cf, cw) = cfg.readTag();
          if (cf == 1) {
            c1 = true;
            cfg.readBytes();
          } else if (cf == 2) {
            c2 = true;
            cfg.readBytes();
          } else if (cf == 3) {
            c3 = true;
            cfg.readBytes();
          } else {
            cfg.skip(cw);
          }
        }
        check('config.config1/2/3 均在', c1 && c2 && c3);
      } else {
        r.skip(w);
      }
    }
    check('含 config(field1)', sawConfig);
    checkEq('cmd', PcGroupService.cmd, 'OidbSvcTrpcTcp.0xfe5_2');
  }

  section('2. parseFetchGroupsResp');
  {
    final info = (PbWriter()
          ..writeInt(2, 1700000000) // createdTime
          ..writeInt(3, 500) // memberMax
          ..writeInt(4, 42) // memberCount
          ..writeString(5, '测试群')
          ..writeString(19, '验证问题')
          ..writeString(21, '群简介')
          ..writeString(30, '群公告'))
        .toBytes();
    final custom = (PbWriter()..writeString(3, '群备注')).toBytes();
    final group = (PbWriter()
          ..writeInt(3, 123456) // groupUin
          ..writeBytes(4, info)
          ..writeBytes(5, custom))
        .toBytes();
    final body = (PbWriter()..writeBytes(2, group)).toBytes();

    final list = PcGroupService.parseFetchGroupsResp(body);
    checkEq('群数=1', list.length, 1);
    final g = list.first;
    checkEq('uin', g.uin, 123456);
    checkEq('name', g.name, '测试群');
    checkEq('memberCount', g.memberCount, 42);
    checkEq('capacity', g.capacity, 500);
    checkEq('remark', g.remark, '群备注');
    checkEq('createdAt', g.createdAt, 1700000000);
    checkEq('description', g.description, '群简介');
    checkEq('question', g.question, '验证问题');
    checkEq('announcement', g.announcement, '群公告');
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
