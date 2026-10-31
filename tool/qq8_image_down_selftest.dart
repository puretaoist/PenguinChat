/// GroupPicDown（`ImgStore.GroupPicDown`）请求/回执的离线自测。
///
/// 只测**纯函数**：组包字段号是否与官方 `cmd0x388` 的 `__fieldMap__` 对齐、
/// 回执解析能否把三种规格的 down_para 与 ip/port/domain 拆出来。
/// 服务端真实回包形态必须真机取证（见 docs/图片富媒体下载-P3取证与探针-20261031.md）。
///
/// 跑：`dart run tool/qq8_image_down_selftest.dart`
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/wlogin8/qq8_image.dart';
import 'package:qqclient/kernel/wlogin8/qq8_pb.dart';

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

Uint8List _bs(List<int> xs) => Uint8List.fromList(xs);

const String _md5 = '0123456789abcdef0123456789abcdef';

void main() {
  stdout.writeln('== GroupPicDown 组包 ==');
  final body = Qq8ImageDown.buildGroupPicDownBody(
    gid: 486045673,
    uin: 123456,
    md5HexList: const <String>[_md5],
    picType: Qq8ImageDown.picTypeOriginal,
  );
  final top = Qq8Pb.decode(body);
  checkEq('ReqBody.uint32_net_type(1)', Qq8Pb.intAt(top, 1), 6);
  checkEq('ReqBody.uint32_subcmd(2) = 2（GetImgUrl）', Qq8Pb.intAt(top, 2), 2);
  final reqList = top[4];
  check('ReqBody.rpt_msg_getimg_url_req(4) 有 1 条',
      reqList != null && reqList.length == 1);
  final req = Qq8Pb.decode(reqList!.first as Uint8List);
  checkEq('req.uint64_group_code(1)', Qq8Pb.intAt(req, 1), 486045673);
  checkEq('req.uint64_dst_uin(2)', Qq8Pb.intAt(req, 2), 123456);
  checkEq('req.bytes_file_md5(4)', (Qq8Pb.bytesAt(req, 4) ?? Uint8List(0)).length, 16);
  checkEq('req.uint32_url_flag(5) 原图 = 2', Qq8Pb.intAt(req, 5), 2);
  checkEq('req.uint32_url_type(6) 原图 = 4', Qq8Pb.intAt(req, 6), 4);
  checkEq('req.uint32_req_term(7)', Qq8Pb.intAt(req, 7), 5);
  checkEq('req.uint32_req_platform_type(8)', Qq8Pb.intAt(req, 8), 9);
  checkEq('req.uint32_inner_ip(9)', Qq8Pb.intAt(req, 9), 0);
  checkEq('req.uint32_bu_type(10)', Qq8Pb.intAt(req, 10), 1);
  checkEq('req.bytes_build_ver(11)', Qq8Pb.textAt(req, 11), '8.2.11.0153f87a');
  checkEq('req.uint64_file_id(12) 批量下标', Qq8Pb.intAt(req, 12), 0);
  checkEq('req.uint32_pic_up_timestamp(19)', Qq8Pb.intAt(req, 19), 0);
  checkEq('req.uint32_req_transfer_type(20)', Qq8Pb.intAt(req, 20), 0);

  final bigBody = Qq8Pb.decode(Qq8ImageDown.buildGroupPicDownBody(
    gid: 1,
    uin: 2,
    md5HexList: const <String>[_md5],
    picType: Qq8ImageDown.picTypeBig,
  ));
  final big = Qq8Pb.decode(bigBody[4]!.first as Uint8List);
  checkEq('大图 url_flag = 8', Qq8Pb.intAt(big, 5), 8);
  checkEq('大图 url_type = 3', Qq8Pb.intAt(big, 6), 3);

  final thumbBody = Qq8Pb.decode(Qq8ImageDown.buildGroupPicDownBody(
    gid: 1,
    uin: 2,
    md5HexList: const <String>[_md5],
    picType: Qq8ImageDown.picTypeThumb,
  ));
  final thumb = Qq8Pb.decode(thumbBody[4]!.first as Uint8List);
  checkEq('缩略图 url_flag = 1', Qq8Pb.intAt(thumb, 5), 1);
  checkEq('缩略图 url_type = 2', Qq8Pb.intAt(thumb, 6), 2);

  final two = Qq8Pb.decode(Qq8ImageDown.buildGroupPicDownBody(
    gid: 5,
    uin: 6,
    md5HexList: const <String>[
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    ],
    fileIds: const <int>[111, 222],
    picUpTimestamps: const <int>[1700000000, 1700000001],
  ));
  final twoList = two[4]!;
  final r1 = Qq8Pb.decode(twoList.first as Uint8List);
  final r2 = Qq8Pb.decode(twoList.last as Uint8List);
  checkEq('批量第二条的下标 12 = 1', Qq8Pb.intAt(r2, 12), 1);
  checkEq('批量第一条 fileid(3)', Qq8Pb.intAt(r1, 3), 111);
  checkEq('批量第二条 pic_up_timestamp(19)', Qq8Pb.intAt(r2, 19), 1700000001);

  stdout.writeln('\n== GroupPicDown 回执解析 ==');
  Uint8List rspItem({
    int result = 0,
    String fail = '',
    Uint8List? thumb,
    Uint8List? original,
    Uint8List? big,
    Uint8List? bigThumb,
    List<String> domains = const <String>[],
    List<int> ips = const <int>[],
    List<int> ports = const <int>[],
    int httpsFlag = 0,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        2: _bs(List<int>.generate(16, (i) => i)),
        3: result,
        4: fail,
        12: ?thumb,
        13: ?original,
        14: ?big,
        18: ?bigThumb,
        9: ips,
        10: ports,
        11: domains.map((d) => utf8.encode(d)).toList(),
        19: httpsFlag,
      });

  void addItem(List<Uint8List> out, Uint8List item) => out.add(item);

  final items = <Uint8List>[];
  addItem(
      items,
      rspItem(
        original: _bs(List<int>.generate(40, (i) => i)),
        big: _bs(List<int>.filled(20, 7)),
        domains: const <String>['gchat.qpic.cn'],
        ips: const <int>[0x04030201, 0x08070605],
        ports: const <int>[80, 443],
        httpsFlag: 1,
      ));
  addItem(items, rspItem(result: 404, fail: 'expired'));
  final rsp = Qq8Pb.encode(<int, Object?>{1: 0, 2: 2, 4: items});
  final replies = Qq8ImageDown.parseGroupPicDownResponse(rsp);
  checkEq('回执条数', replies.length, 2);
  checkEq('第 1 条 result = 0', replies[0].result, 0);
  checkEq('第 1 条 md5（回执里的无符号字节序）', replies[0].md5Hex,
      '000102030405060708090a0b0c0d0e0f');
  checkEq('原图 para 长度', replies[0].originalPara?.length, 40);
  checkEq('大图 para 长度', replies[0].bigPara?.length, 20);
  checkEq('没有给的缩略 para 为 null', replies[0].thumbPara, null);
  checkEq('domain', replies[0].domains.join(','), 'gchat.qpic.cn');
  checkEq('ip 转点分（小端）', replies[0].ips.join(','), '1.2.3.4,5.6.7.8');
  checkEq('port', replies[0].ports.join(','), '80,443');
  checkEq('https 标志', replies[0].httpsFlag, 1);
  check('第 1 条 ok', replies[0].ok);
  checkEq('第 2 条 result', replies[1].result, 404);
  checkEq('第 2 条 failMsg', replies[1].failMsg, 'expired');
  check('第 2 条不 ok', !replies[1].ok);

  final empty = Qq8ImageDown.parseGroupPicDownResponse(
      Qq8Pb.encode(<int, Object?>{2: 2}));
  checkEq('没有 rpt_msg_getimg_url_rsp 时返回空表', empty.length, 0);

  stdout.writeln('\n=== 结果: $_pass 通过, $_fail 失败 ===');
  if (_fail > 0) throw StateError('$_fail 项失败');
}
