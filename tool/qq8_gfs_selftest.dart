/// 群文件系统（GFS）离线自测
///
/// 全部是**纯字节**断言：请求体与服务端应答样本都和独立第二实现
/// `../analysis/scripts/gen_gfs_vectors.py` 逐字节比对（那个脚本不引用本项目
/// Dart 代码，也不引用 oicq，手写 varint/长度前缀）。
///
/// 运行：
/// \`\`\`bash
/// dart run tool/qq8_gfs_selftest.dart
/// \`\`\`
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/wlogin8/qq8_gfs.dart';
import 'package:qqclient/kernel/wlogin8/qq8_image.dart';
import 'package:qqclient/kernel/wlogin8/qq8_pb.dart';

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

String _hexOf(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

// 与 gen_gfs_vectors.py 完全相同的输入常量
const int gid = 763829581;
const int uin = 3499239040;
const int subid = 537298353;
const String name = '测试.bin';
const int size = 12345;
const String fid = 'a1b2c3d4e5f6';
const String ticket = 'TICKET/abc';
const int busid = 102;
const int rand = 0x11223344;

Uint8List _md5() => Uint8List.fromList(List<int>.generate(16, (i) => i));
Uint8List _sha1() => Uint8List.fromList(List<int>.generate(20, (i) => i));

void main() {
  section('一、请求体逐字节 = Python 黄金向量');
  check(
    '列目录 dirBody（0x6d8_1）',
    _hexOf(Qq8Gfs.buildDirBody(gid: gid)) ==
        '120f08cdba9cec0210011a012f28646800',
    _hexOf(Qq8Gfs.buildDirBody(gid: gid)),
  );
  check(
    '取属性 statBody（0x6d8_0）',
    _hexOf(Qq8Gfs.buildStatBody(gid: gid, fid: fid)) ==
        '0a1608cdba9cec021000220c613162326333643465356636',
    _hexOf(Qq8Gfs.buildStatBody(gid: gid, fid: fid)),
  );
  check(
    '申请上传 applyUploadBody（0x6d6_0）',
    _hexOf(Qq8Gfs.buildApplyUploadBody(
          gid: gid,
          name: name,
          size: size,
          md5: _md5(),
          sha1: _sha1(),
        )) ==
        '0a7908cdba9cec021000186620052a012f320ae6b58be8af952e62696e3a2f2f73746f726167652f656d756c617465642f302f50696374757265732f66696c65732f732fe6b58be8af952e62696e40b9604a14000102030405060708090a0b0c0d0e0f101112135a10000102030405060708090a0b0c0d0e0f7801',
    _hexOf(Qq8Gfs.buildApplyUploadBody(
      gid: gid,
      name: name,
      size: size,
      md5: _md5(),
      sha1: _sha1(),
    )),
  );
  check(
    '取下载地址 downloadBody（0x6d6_2）',
    _hexOf(Qq8Gfs.buildDownloadBody(gid: gid, busid: busid, fid: fid)) ==
        '1a1808cdba9cec0210021866220c613162326333643465356636',
    _hexOf(Qq8Gfs.buildDownloadBody(gid: gid, busid: busid, fid: fid)),
  );
  check(
    '删除 deleteBody（0x6d6_3）',
    _hexOf(Qq8Gfs.buildDeleteBody(
            gid: gid, busid: busid, pid: '/', fid: fid)) ==
        '221b08cdba9cec021003186622012f2a0c613162326333643465356636',
    _hexOf(Qq8Gfs.buildDeleteBody(
        gid: gid, busid: busid, pid: '/', fid: fid)),
  );
  check(
    '上传回执 feedBody（0x6d9_4）',
    _hexOf(Qq8Gfs.buildFeedBody(gid: gid, busid: busid, fid: fid, rand: rand)) ==
        '2a2208cdba9cec0210041a180866120c61316232633364346535663618c4e68889012801',
    _hexOf(Qq8Gfs.buildFeedBody(
        gid: gid, busid: busid, fid: fid, rand: rand)),
  );

  final ext = Qq8Gfs.buildUploadExt(
    uin: uin,
    gid: gid,
    name: name,
    size: size,
    md5: _md5(),
    sha1: _sha1(),
    busid: busid,
    fid: fid,
    uploadTicket: ticket,
    subid: subid,
    ext500a: Uint8List.fromList(<int>[1, 2, 3, 4]),
    ext500b: 7,
  );
  check('上传扩展 uploadExt 逐字节 = 黄金向量',
      _hexOf(ext) ==
          '086410011800a206ac01a206170866a00680cdc8840dc00ccdba9cec028019cdba9cec02c20c4aa006b960c20c10000102030405060708090a0b0c0d0e0fe21214000102030405060708090a0b0c0d0e0f10111213c2250c613162326333643465356636e22b0a5449434b45542f616263e21220a00602c20c09353337323938333533e012028219083965396330396463c0250482190da2060ae6b58be8af952e62696ea21f0fc20c0c0a0808011204010203041007c00c01',
      _hexOf(ext));

  final em = Qq8Pb.decode(ext);
  final e100 = Qq8Pb.decode(Qq8Pb.bytesAt(em, 100)!);
  final e100_100 = Qq8Pb.decode(Qq8Pb.bytesAt(e100, 100)!);
  final e100_200 = Qq8Pb.decode(Qq8Pb.bytesAt(e100, 200)!);
  check('扩展结构：1=100 / 2=1 / 3=0 / 200=1',
      Qq8Pb.intAt(em, 1) == 100 &&
          Qq8Pb.intAt(em, 2) == 1 &&
          Qq8Pb.intAt(em, 3) == 0 &&
          Qq8Pb.intAt(em, 200) == 1);
  check('扩展 100.100：busid/self uin/gid/gid',
      Qq8Pb.intAt(e100_100, 1) == busid &&
          Qq8Pb.intAt(e100_100, 100) == uin &&
          Qq8Pb.intAt(e100_100, 200) == gid &&
          Qq8Pb.intAt(e100_100, 400) == gid);
  check('扩展 100.200：size/md5/sha1/fid/上传票据',
      Qq8Pb.intAt(e100_200, 100) == size &&
          _hexOf(Qq8Pb.bytesAt(e100_200, 200)!) == _hexOf(_md5()) &&
          _hexOf(Qq8Pb.bytesAt(e100_200, 300)!) == _hexOf(_sha1()) &&
          Qq8Pb.textAt(e100_200, 600) == fid &&
          Qq8Pb.textAt(e100_200, 700) == ticket);
  final e300 = Qq8Pb.decode(Qq8Pb.bytesAt(e100, 300)!);
  check('扩展 100.300：固定客户端串 9e9c09dc 与 subid 字符串',
      Qq8Pb.textAt(e300, 400) == Qq8Gfs.clientKey &&
          Qq8Pb.textAt(e300, 200) == '$subid');
  final extNo500 = Qq8Gfs.buildUploadExt(
    uin: uin,
    gid: gid,
    name: name,
    size: size,
    md5: _md5(),
    sha1: _sha1(),
    busid: busid,
    fid: fid,
    uploadTicket: ticket,
    subid: subid,
  );
  final e100No500 = Qq8Pb.decode(
      Qq8Pb.bytesAt(Qq8Pb.decode(extNo500), 100)!);
  check('不带 ext500 时 100 里没有 500 段（字段与参考实现同构）',
      Qq8Pb.bytesAt(e100No500, 500) == null);

  section('二、应答解析');
  final dir = Qq8Gfs.parseDir(_hex(
      '22860112830108002a20121e0a052f646f637312012f1a04646f63732080f09dc7063080cdc8840d40022a5d1a5b0a0c613162326333643465356636120ae6b58be8af952e62696e206628b9603080f09dc706380048035214000102030405060708090a0b0c0d0e0f101112136210000102030405060708090a0b0c0d0e0f7880cdc8840d8201012f'));
  check('列目录：code=0、两个条目（1 目录 + 1 文件）',
      dir.code == 0 && dir.entries.length == 2,
      'code=${dir.code} n=${dir.entries.length}');
  final d0 = dir.entries.firstWhere((e) => e.isDir);
  check('目录条目：fid=/docs、fileCount=2、上传者',
      d0.fid == '/docs' && d0.fileCount == 2 && d0.uploaderUin == uin,
      '${d0.fid}/${d0.fileCount}');
  final f0 = dir.entries.firstWhere((e) => !e.isDir);
  check('文件条目：name/size/busid/md5/sha1/pid 全部对',
      f0.name == name &&
          f0.size == size &&
          f0.busid == busid &&
          f0.md5Hex == _hexOf(_md5()) &&
          f0.sha1Hex == _hexOf(_sha1()) &&
          f0.uploaderUin == uin &&
          f0.pid == '/');
  check('文件条目 sizeText 可读（12345 → 12.1 KB）', f0.sizeText == '12.1 KB',
      f0.sizeText);

  final err = Qq8Gfs.parseDir(_hex('221212100801120ce7bea4e4b88de5ad98e59ca8'));
  check('错误应答：code=1、文案「群不存在」',
      err.code == 1 && err.message == '群不存在', '${err.code}/${err.message}');

  final stat = Qq8Gfs.parseStat(_hex(
      '22610a5f0800225b0a0c613162326333643465356636120ae6b58be8af952e62696e206628b9603080f09dc706380048035214000102030405060708090a0b0c0d0e0f101112136210000102030405060708090a0b0c0d0e0f7880cdc8840d8201012f'));
  check('取属性：code=0 且条目 fid/name 对',
      stat.code == 0 && stat.entry?.fid == fid && stat.entry?.name == name,
      'code=${stat.code}');

  final ap = Qq8Gfs.parseApplyUpload(
      _hex('22280a26080030663a0c6131623263336434653566364a0a5449434b45542f6162636204010203047007'));
  check('申请上传（新文件）：exists=false、busid/fid/票据/ext500 都有',
      ap.code == 0 &&
          !ap.exists &&
          ap.busid == busid &&
          ap.fid == fid &&
          ap.uploadTicket == ticket &&
          _hexOf(ap.ext500a!) == '01020304' &&
          ap.ext500b == 7,
      'busid=${ap.busid} fid=${ap.fid}');
  final apx = Qq8Gfs.parseApplyUpload(
      _hex('22160a140800500130663a0c613162326333643465356636'));
  check('申请上传（秒传命中）：exists=true', apx.exists && apx.code == 0);

  final dl = Qq8Gfs.parseDownload(
      _hex('221a1a180800220e31342e31382e312e323a383038303204deadbeef'));
  check('取下载地址：host/token 对', dl.code == 0 && dl.host == '14.18.1.2:8080' && dl.tokenHex == 'deadbeef',
      '${dl.host} ${dl.tokenHex}');
  final url = Qq8Gfs.buildDownloadUrl(host: dl.host, tokenHex: dl.tokenHex, name: name);
  check('下载 URL：/ftn_handler/<token>/?fname=<编码后的名字>',
      url ==
          'http://14.18.1.2:8080/ftn_handler/deadbeef/?fname=%E6%B5%8B%E8%AF%95.bin',
      url);

  final fd = Qq8Gfs.parseFeed(_hex('22162a140800221008001a0c613162326333643465356636'));
  check('上传回执：code=0、最终 fid 对', fd.code == 0 && fd.fid == fid, fd.fid);

  final de = Qq8Gfs.parseDelete(_hex('220422020800'));
  check('删除应答：code=0', de.code == 0 && de.message == null);

  section('三、highway 帧带 ext（群文件上传才有）');
  final frameNoExt = Qq8Highway.buildFrame(
    seq: 1,
    uin: '$uin',
    appid: subid,
    buCmdId: Qq8Gfs.highwayCmdIdGroupFile,
    ticket: Uint8List.fromList(<int>[1, 2, 3]),
    fileMd5: _md5(),
    fileSize: size,
    offset: 0,
    chunk: Uint8List.fromList(<int>[9, 9, 9]),
  );
  final headLen = ((frameNoExt[1] << 24) | (frameNoExt[2] << 16) | (frameNoExt[3] << 8) | frameNoExt[4]) & 0xFFFFFFFF;
  final hNoExt = Qq8Pb.decode(frameNoExt.sublist(9, 9 + headLen));
  final h1NoExt = Qq8Pb.decode(Qq8Pb.bytesAt(hNoExt, 1)!);
  check('不带 ext：head 顶层没有 3 号字段、basehead 没有 10（图片路径逐字节不变）',
      Qq8Pb.bytesAt(hNoExt, 3) == null && Qq8Pb.intAt(h1NoExt, 10) == null);
  check('不带 ext：业务号 = 71', Qq8Pb.intAt(h1NoExt, 8) == 71);

  final frameExt = Qq8Highway.buildFrame(
    seq: 2,
    uin: '$uin',
    appid: subid,
    buCmdId: Qq8Gfs.highwayCmdIdGroupFile,
    ticket: Uint8List.fromList(<int>[1, 2, 3]),
    fileMd5: _md5(),
    fileSize: size,
    offset: 0,
    chunk: Uint8List.fromList(<int>[9, 9, 9]),
    ext: ext,
    netFlag: 2052,
  );
  final hl2 = ((frameExt[1] << 24) | (frameExt[2] << 16) | (frameExt[3] << 8) | frameExt[4]) & 0xFFFFFFFF;
  final hExt = Qq8Pb.decode(frameExt.sublist(9, 9 + hl2));
  final h1Ext = Qq8Pb.decode(Qq8Pb.bytesAt(hExt, 1)!);
  check('带 ext：head 顶层 3 = ext 原文（不在 basehead 里）',
      _hexOf(Qq8Pb.bytesAt(hExt, 3)!) == _hexOf(ext));
  check('带 ext：basehead 10 = 2052（参考实现 highway.ts:65）',
      Qq8Pb.intAt(h1Ext, 10) == 2052);
  check('带 ext：STX/ETX 与分片长度自洽',
      frameExt.first == Qq8Highway.stx &&
          frameExt.last == Qq8Highway.etx &&
          ((frameExt[5] << 24) | (frameExt[6] << 16) | (frameExt[7] << 8) | frameExt[8]) == 3);

  section('六、目录写操作（0x6d7_0/1/2、0x6d6_4/5）');

  check('命令字与参考实现一致',
      Qq8Gfs.cmdMkdir == 'OidbSvc.0x6d7_0' &&
          Qq8Gfs.cmdDeleteDir == 'OidbSvc.0x6d7_1' &&
          Qq8Gfs.cmdRenameDir == 'OidbSvc.0x6d7_2' &&
          Qq8Gfs.cmdRenameFile == 'OidbSvc.0x6d6_4' &&
          Qq8Gfs.cmdMoveFile == 'OidbSvc.0x6d6_5');

  check(
      '建目录请求体 = 黄金向量',
      _hexOf(Qq8Gfs.buildMkdirBody(gid: gid, name: '新文件夹')) ==
          '0a1908cdba9cec0210001a012f220ce696b0e69687e4bbb6e5a4b9',
      _hexOf(Qq8Gfs.buildMkdirBody(gid: gid, name: '新文件夹')));
  check(
      '删目录请求体 = 黄金向量',
      _hexOf(Qq8Gfs.buildDeleteDirBody(gid: gid, fid: fid)) ==
          '121608cdba9cec0210011a0c613162326333643465356636');
  check(
      '改目录名请求体 = 黄金向量',
      _hexOf(Qq8Gfs.buildRenameDirBody(gid: gid, fid: fid, name: '新文件夹')) ==
          '1a2408cdba9cec0210021a0c613162326333643465356636220ce696b0e69687e4bbb6e5a4b9');
  check(
      '改文件名请求体 = 黄金向量',
      _hexOf(Qq8Gfs.buildRenameFileBody(
              gid: gid, busid: busid, fid: fid, pid: '/', name: '新文件夹')) ==
          '2a2908cdba9cec0210041866220c6131623263336434653566362a012f320ce696b0e69687e4bbb6e5a4b9');
  check(
      '移动文件请求体 = 黄金向量',
      _hexOf(Qq8Gfs.buildMoveFileBody(
              gid: gid, busid: busid, fid: fid, pid: '/', toPid: '/dir2')) ==
          '322208cdba9cec0210051866220c6131623263336434653566362a012f32052f64697232');

  final dirStat = Qq8Pb.encode(<int, Object?>{
    1: '/abc123',
    2: '/',
    3: '新文件夹',
    4: 1760000000,
    6: uin,
    8: 0,
  });
  final mk = Qq8Gfs.parseMkdir(Qq8Pb.encode(<int, Object?>{
    4: <int, Object?>{
      1: <int, Object?>{1: 0, 4: dirStat},
    },
  }));
  check(
      '解建目录应答：[4][1][4] 是目录属性',
      mk.code == 0 &&
          mk.entry != null &&
          mk.entry!.isDir &&
          mk.entry!.name == '新文件夹' &&
          mk.entry!.fid == '/abc123' &&
          mk.entry!.uploaderUin == uin);

  Uint8List rsp(int outer, int innerTag, {int code = 0, String? msg}) =>
      Qq8Pb.encode(<int, Object?>{
        outer: <int, Object?>{
          innerTag: <int, Object?>{
            1: code,
            if (msg != null) 2: msg,
          },
        },
      });
  check('删目录应答 [4][2] 判码', Qq8Gfs.parseDeleteDir(rsp(4, 2)).code == 0);
  check('改文件名应答 [4][5] 判码', Qq8Gfs.parseRenameFile(rsp(4, 5)).code == 0);
  check('改目录名应答 [4][3] 判码', Qq8Gfs.parseRenameDir(rsp(4, 3)).code == 0);
  check('移动应答 [4][6] 判码', Qq8Gfs.parseMoveFile(rsp(4, 6)).code == 0);
  final denied = Qq8Gfs.parseDeleteDir(rsp(4, 2, code: 5, msg: '没有权限'));
  check('应答带错误码时如实返回（不假成功）',
      denied.code == 5 && denied.message == '没有权限');
  check('应答缺字段时返回 -1 而不是 0',
      Qq8Gfs.parseMoveFile(Qq8Pb.encode(<int, Object?>{4: <int, Object?>{}}))
              .code ==
          -1);

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
