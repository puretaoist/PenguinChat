/// PTT（语音）上行组包的离线自测。
///
/// 只测纯函数：申请上传请求体的字段号（官方 `cmd0x346.java` 的 ApplyUploadReq
/// 是"十位段" 10/20/30…）、回执解析、RichText.ptt 的私聊/群聊必填字段差异。
/// 真实链路（HTTP 上传 + 服务端回执）必须真机取证。
///
/// 跑：`dart run tool/qq8_ptt_selftest.dart`
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/kernel/crypto/digest.dart';
import 'package:penguinchat/kernel/wlogin8/qq8_pb.dart';
import 'package:penguinchat/kernel/wlogin8/qq8_ptt.dart';

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

/// 字节数组要按内容比，Uint8List 的 == 是引用相等。
bool eqBytes(Object? a, Object? b) {
  if (a is! List<int> || b is! List<int>) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 十六进制串 → 字节（自测里嵌真机回包用）。
Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  final md5 = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));

  stdout.writeln('== 申请上传请求体 ==');
  final body = Qq8Ptt.buildApplyUploadBody(
    uin: 3880159487,
    peerUin: 2089495846,
    fileName: 'abc.amr',
    fileSize: 5873,
    md5: md5,
    seq: 12345,
  );
  final m = Qq8Pb.decode(body);
  checkEq('1 = cmd 500', Qq8Pb.intAt(m, 1), 500);
  checkEq('2 = seq', Qq8Pb.intAt(m, 2), 12345);
  final req = Qq8Pb.bytesAt(m, 7);
  check('7 = ApplyUploadReq 存在', req != null);
  final r = Qq8Pb.decode(req!);
  checkEq(' 10 = sender_uin', Qq8Pb.intAt(r, 10), 3880159487);
  checkEq(' 20 = recver_uin', Qq8Pb.intAt(r, 20), 2089495846);
  checkEq(' 30 = file_type(2)', Qq8Pb.intAt(r, 30), 2);
  checkEq(' 40 = file_size', Qq8Pb.intAt(r, 40), 5873);
  checkEq(' 50 = file_name', Qq8Pb.textAt(r, 50), 'abc.amr');
  check(' 60 = 10m_md5', eqBytes(Qq8Pb.bytesAt(r, 60), md5));
  checkEq('101 = business_id(17)', Qq8Pb.intAt(m, 101), 17);
  checkEq('102 = client_type(104)', Qq8Pb.intAt(m, 102), 104);

  stdout.writeln('== 申请上传回执 ==');
  final rsp = Qq8Pb.encode(<int, Object?>{
    10: 0,
    20: '',
    60: '59.1.2.3',
    80: 8080,
    90: Uint8List.fromList(<int>[1, 2, 3, 4]),
    100: Uint8List.fromList(<int>[5, 6, 7]),
    110: 1,
  });
  // 申请体必须带 msg_extension_req(#99999)，且 ptt_time 就是语音秒数。
  final reqM = Qq8Pb.decode(Qq8Ptt.buildApplyUploadBody(
    uin: 10001,
    peerUin: 10002,
    fileName: 'abc.amr',
    fileSize: 5873,
    md5: md5,
    seq: 9,
    voiceSeconds: 7,
  ));
  final ext = Qq8Pb.bytesAt(reqM, 99999);
  check('申请体带 ExtensionReq', ext != null && ext.isNotEmpty);
  if (ext != null) {
    final em = Qq8Pb.decode(ext);
    checkEq('ExtensionReq id=3', Qq8Pb.intAt(em, 1), 3);
    checkEq('ExtensionReq ptt_time=7', Qq8Pb.intAt(em, 90800), 7);
    checkEq('ExtensionReq ptt_format=1', Qq8Pb.intAt(em, 90200), 1);
  }

  final t = Qq8Ptt.parseApplyUploadResponse(rsp);
  checkEq('ret_code=0 → ok', t.ok, true);
  checkEq('upload_ip', t.host, '59.1.2.3');
  checkEq('upload_port', t.port, 8080);
  checkEq('uuid 长度', t.uuid?.length, 4);
  checkEq('upload_key 长度', t.uploadKey?.length, 3);
  checkEq('file_exist', t.fileExists, true);
  check('hasEndpoint', t.hasEndpoint);

  // 线上真实回包是 RspBody{7: ApplyUploadRsp}，必须能自动拆包（否则 code 恒 -1）。
  final wrapped = Qq8Pb.encode(<int, Object?>{
    1: 500,
    2: 7,
    7: Qq8Pb.encode(<int, Object?>{10: 0, 60: '1.2.3.4', 80: 80, 90: <int>[1, 2], 100: <int>[3]}),
  });
  final wt = Qq8Ptt.parseApplyUploadResponse(wrapped);
  checkEq('RspBody 拆包 → ok', wt.ok, true);
  checkEq('RspBody 拆包 ip', wt.host, '1.2.3.4');

  final bad = Qq8Ptt.parseApplyUploadResponse(Qq8Pb.encode(<int, Object?>{10: 9311, 20: 'denied'}));
  checkEq('失败码 → !ok', bad.ok, false);
  checkEq('失败文案', bad.message, 'denied');

  stdout.writeln('== RichText.ptt（私聊 / 群聊）==');
  final dm = Qq8Ptt.buildPttElem(
    fileType: Qq8Ptt.elemFileType,
    fileMd5: md5,
    fileName: 'abc.amr',
    fileSize: 5873,
    fileUuid: Uint8List.fromList(<int>[9, 9]),
    downPara: '',
    seconds: 4,
    dm: true,
  );
  final d = Qq8Pb.decode(dm);
  checkEq('私聊 1 = file_type(4)', Qq8Pb.intAt(d, 1), 4);
  check('私聊 4 = file_md5', eqBytes(Qq8Pb.bytesAt(d, 4), md5));
  checkEq('私聊 5 = file_name', Qq8Pb.textAt(d, 5), 'abc.amr');
  checkEq('私聊 6 = file_size', Qq8Pb.intAt(d, 6), 5873);
  check('私聊不带 8(file_id)', Qq8Pb.intAt(d, 8) == null);
  check('私聊不带 19(time)', Qq8Pb.intAt(d, 19) == null);
  check('私聊不带 21(format)', Qq8Pb.intAt(d, 21) == null);

  final grp = Qq8Ptt.buildPttElem(
    fileType: Qq8Ptt.elemFileType,
    fileMd5: md5,
    fileName: 'abc.amr',
    fileSize: 5873,
    fileUuid: Uint8List.fromList(<int>[9, 9]),
    downPara: '',
    seconds: 4,
    dm: false,
    fileId: 88,
    groupFileKey: Uint8List.fromList(<int>[7, 7, 7]),
    format: Qq8Ptt.formatSilk,
  );
  final g = Qq8Pb.decode(grp);
  checkEq('群聊 8 = file_id', Qq8Pb.intAt(g, 8), 88);
  check('群聊 18 = group_file_key', eqBytes(Qq8Pb.bytesAt(g, 18), <int>[7, 7, 7]));
  checkEq('群聊 19 = time(秒)', Qq8Pb.intAt(g, 19), 4);
  checkEq('群聊 21 = format(1=SILK)', Qq8Pb.intAt(g, 21), 1);


  // ── Qq8PttHighway：真机验证过的 httpconn 上传帧 ──────────────────────
  final chunk = Uint8List.fromList(List<int>.generate(64, (i) => i));
  final ticketBytes =
      Uint8List.fromList(List<int>.generate(104, (i) => 0xA0 + (i % 16)));
  final frame = Qq8PttHighway.buildFrame(
    seq: 7,
    uin: '3880159487',
    totalSize: 3547,
    offset: 0,
    chunk: chunk,
    ticket: ticketBytes,
    fileMd5: md5,
    ext: Uint8List.fromList(<int>[0x32, 0x00]),
    appId: 537064117,
    loginSig: Uint8List.fromList(<int>[0xAA, 0xBB, 0xCC]),
  );
  checkEq('frame 首字节 0x28', frame.first, 0x28);
  checkEq('frame 尾字节 0x29', frame.last, 0x29);
  final headLen =
      (frame[1] << 24) | (frame[2] << 16) | (frame[3] << 8) | frame[4];
  final chunkLen =
      (frame[5] << 24) | (frame[6] << 16) | (frame[7] << 8) | frame[8];
  checkEq('片长 = chunk 长度', chunkLen, chunk.length);
  checkEq('帧总长 = 9 + 头 + 数据 + 1', frame.length,
      9 + headLen + chunk.length + 1);
  final fh = Qq8Pb.decode(Uint8List.sublistView(frame, 9, 9 + headLen));
  final f1 = Qq8Pb.decode(Qq8Pb.bytesAt(fh, 1)!);
  // 2026-11-05 修正：f2 Uin 在协议定义里是 string（Lagrange Highway.cs），按字符串编。
  checkEq('头1.2 = uin（string）', Qq8Pb.textAt(f1, 2), '3880159487');
  checkEq('头1.3 = PicUp.DataUp', Qq8Pb.textAt(f1, 3), 'PicUp.DataUp');
  checkEq('头1.7 = 16', Qq8Pb.intAt(f1, 7), 16);
  checkEq('头1.8 = 1007（语音上传）', Qq8Pb.intAt(f1, 8), 1007);
  final f2h = Qq8Pb.decode(Qq8Pb.bytesAt(fh, 2)!);
  checkEq('头2.2 = 总长', Qq8Pb.intAt(f2h, 2), 3547);
  checkEq('头2.3 = 偏移', Qq8Pb.intAt(f2h, 3), 0);
  checkEq('头2.4 = 片长', Qq8Pb.intAt(f2h, 4), chunk.length);
  check('头2.6 = ticket', eqBytes(Qq8Pb.bytesAt(f2h, 6), ticketBytes));
  check('头2.8 = md5(片)', eqBytes(Qq8Pb.bytesAt(f2h, 8), md5Bytes(chunk)));
  check('头2.9 = md5(整)', eqBytes(Qq8Pb.bytesAt(f2h, 9), md5));
  checkEq('头4 = 0（时间戳不填）', Qq8Pb.intAt(fh, 4), 0);
  // 2026-11-05 补齐的两个字段：缺它们时服务端统一回 372。
  checkEq('头1.6 = 客户端 AppId', Qq8Pb.intAt(f1, 6), 537064117);
  final f5 = Qq8Pb.decode(Qq8Pb.bytesAt(fh, 5)!);
  checkEq('头5.1 = loginSigType(8=A2)', Qq8Pb.intAt(f5, 1), 8);
  check('头5.2 = A2 原始字节', eqBytes(Qq8Pb.bytesAt(f5, 2), <int>[0xAA, 0xBB, 0xCC]));
  checkEq('头5.3 = AppId', Qq8Pb.intAt(f5, 3), 537064117);
  // 2026-11-01 真机回包原文（HTTP 200 / 135 字节）。注意：
  // 这条回包的 `f3 uint32_error_code` 实际是 **372**（失败），旧实现读的是
  // `f2.f1`（SegHead.serviceid，恒 0）所以误判成功 —— 2026-11-03 已修正。
  const ackHex =
      '280000007d000000000a270801120a333838303135393438371a0c50696355702e446174615570200128003000381040ef071239080010db1b180020db1b42102dcc5048488ae1b33ec1a5d24d00b4b94a102dcc5048488ae1b33ec1a5d24d00b4b9509edef2a20b600068ce4218f4022000280030013a0040d985bfb5993448005000b2060029';
  checkEq('ackCode(真机回包) = 372（服务端拒收，旧实现误判 0）',
      Qq8PttHighway.ackCode(_hex(ackHex)), 372);
  checkEq('ackExtendInfo(真机回包) = 空', Qq8PttHighway.ackExtendInfo(_hex(ackHex)), null);
  // 成功帧：把 error_code 改成 0（`18 f4 02` → `18 00`），再验证解析。
  final iErr = ackHex.lastIndexOf('18f402');
  check('回包里能找到 error_code=372 的编码', iErr > 0);
  // error_code 由 3 字节（18 f4 02）换成 2 字节（18 00），头长从 0x7d 减到 0x7c。
  final okAck = _hex('280000007c' +
      ackHex.substring(10, iErr) +
      '1800' +
      ackHex.substring(iErr + 6));
  checkEq('ackCode(成功帧 error_code=0)', Qq8PttHighway.ackCode(okAck), 0);
  checkEq('ackCode(非法帧) = -1',
      Qq8PttHighway.ackCode(Uint8List.fromList(<int>[1, 2, 3])), -1);
  checkEq('ackExtendInfo(非法帧) = null',
      Qq8PttHighway.ackExtendInfo(Uint8List.fromList(<int>[1, 2, 3])), null);
  stdout.writeln('');
  stdout.writeln('PTT SELFTEST pass=$_pass fail=$_fail');
  if (_fail > 0) exitCode = 1;

  // ── 申请下载（1200）：换直链 ──────────────────────────────
  {
    final uuid = Uint8List.fromList(List<int>.generate(36, (i) => 0x41 + i % 26));
    final body = Qq8Pb.decode(
        Qq8Ptt.buildApplyDownloadBody(uin: 12345, uuid: uuid, seq: 7));
    final sub = Qq8Pb.decode(Qq8Pb.bytesAt(body, 14)!);
    checkEq('申请下载 1=1200', Qq8Pb.intAt(body, 1), 1200);
    checkEq('申请下载 2=seq', Qq8Pb.intAt(body, 2), 7);
    checkEq('申请下载 14.10=uin', Qq8Pb.intAt(sub, 10), 12345);
    checkEq('申请下载 14.20=uuid', Qq8Pb.bytesAt(sub, 20)!.length, uuid.length);
    checkEq('申请下载 14.30=owner(1)', Qq8Pb.intAt(sub, 30), 1);
    checkEq('申请下载 14.50=filetype(4)', Qq8Pb.intAt(sub, 50), 4);
    checkEq('申请下载 101=business(17)', Qq8Pb.intAt(body, 101), 17);
    checkEq('申请下载 102=client(104)', Qq8Pb.intAt(body, 102), 104);
    const url = 'http://36.248.11.116/download?appid=1402&fileid=&format=amr&rkey=CAI';
    final rsp = Qq8Pb.encode(<int, Object?>{
      14: <int, Object?>{
        10: 0,
        2: 'success',
        30: <int, Object?>{50: url},
      },
    });
    checkEq('解析直链 14.30.50', Qq8Ptt.parseApplyDownloadUrl(rsp), url);
    checkEq('解析直链：没有 14 时 null',
        Qq8Ptt.parseApplyDownloadUrl(Qq8Pb.encode(<int, Object?>{1: 1200})), null);
  }
}
