// PC 发消息(PbSendMsg)离线自测：验证 c2c/group 请求构造 + 响应解析。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/kernel/wlogin8/pc/pc_proto.dart';
import 'package:penguinchat/kernel/wlogin8/pc/pc_send_msg.dart';

int _p = 0, _f = 0;
void ok(String n) { _p++; stdout.writeln('  ✓ $n'); }
void bad(String n, String d) { _f++; stdout.writeln('  ✗ $n\n      → $d'); }
void eq(String n, Object? a, Object? b) => (a.toString() == b.toString()) ? ok(n) : bad(n, '期望 $b 实际 $a');
void ck(String n, bool c) => c ? ok(n) : bad(n, '');

// 从 req 里取 routingHead 子串做最简校验：找 text 是否在
bool _contains(Uint8List b, String s) {
  final sb = utf8.encode(s);
  outer:
  for (var i = 0; i + sb.length <= b.length; i++) {
    for (var j = 0; j < sb.length; j++) {
      if (b[i + j] != sb[j]) continue outer;
    }
    return true;
  }
  return false;
}

void main() {
  stdout.writeln('1. buildC2C 结构');
  {
    final req = PcSendMsgService.buildC2C(
        peerUin: 123456, peerUid: 'u_abc', text: '你好世界', clientSequence: 7, random: 99);
    final r = PbReader(req);
    var sawRouting = false, sawContent = false, sawBody = false;
    var seq = 0, rnd = 0;
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 1) { sawRouting = true; final rr = PbReader(r.readBytes());
        while(!rr.atEnd){final(rf,rw)=rr.readTag(); if(rf==1){final c=PbReader(rr.readBytes()); var pu=0; var uid=''; while(!c.atEnd){final(cf,cw)=c.readTag(); if(cf==1)pu=c.readVarint(); else if(cf==2)uid=c.readString(); else c.skip(cw);} eq('c2c.peerUin',pu,123456); eq('c2c.peerUid',uid,'u_abc');} else rr.skip(rw);} }
      else if (f == 2) { sawContent = true; r.readBytes(); }
      else if (f == 3) { sawBody = true; r.readBytes(); }
      else if (f == 4) { seq = r.readVarint(); }
      else if (f == 5) { rnd = r.readVarint(); }
      else r.skip(w);
    }
    ck('routingHead/contentHead/messageBody 都在', sawRouting && sawContent && sawBody);
    eq('clientSequence', seq, 7);
    eq('random', rnd, 99);
    ck('body 含文本 "你好世界"', _contains(req, '你好世界'));
  }

  stdout.writeln('2. buildGroup 结构');
  {
    final req = PcSendMsgService.buildGroup(groupUin: 8090, text: '群消息', clientSequence: 3, random: 5);
    final r = PbReader(req);
    var grp = 0; var sawGroup = false;
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 1) { final rr = PbReader(r.readBytes());
        while(!rr.atEnd){final(rf,rw)=rr.readTag(); if(rf==2){sawGroup=true; final g=PbReader(rr.readBytes()); while(!g.atEnd){final(gf,gw)=g.readTag(); if(gf==1)grp=g.readVarint(); else g.skip(gw);}} else rr.skip(rw);} }
      else r.skip(w);
    }
    ck('routingHead.group 存在', sawGroup);
    eq('groupUin', grp, 8090);
    ck('body 含 "群消息"', _contains(req, '群消息'));
  }

  stdout.writeln('3. parseResp');
  {
    final resp = (PbWriter()
          ..writeInt(1, 0)
          ..writeString(2, '')
          ..writeInt(3, 1700000000)
          ..writeInt(11, 5566)
          ..writeInt(14, 3))
        .toBytes();
    final res = PcSendMsgService.parseResp(resp);
    eq('result', res.result, 0);
    ck('ok=true', res.ok);
    eq('sendTime', res.sendTime, 1700000000);
    eq('sequence', res.sequence, 5566);
    eq('clientSequence', res.clientSequence, 3);
  }

  stdout.writeln('\n${'=' * 50}\n通过 $_p 项，失败 $_f 项');
  exit(_f == 0 ? 0 : 1);
}
