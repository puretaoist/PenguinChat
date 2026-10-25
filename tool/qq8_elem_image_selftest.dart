/// 图片元素直链拼接的离线自测。
///
/// 覆盖 2026-10-25 真机暴露的那个 bug：群图 16 号字段有时只放 query
/// （`&rkey=…`），旧代码不校验就拼域名，得到
/// `https://gchat.qpic.cn&rkey=…` —— 主机名变成 `gchat.qpic.cn&rkey=…`，
/// DNS 解析失败（curl 报 000），于是图片永远显示占位框。
///
/// 判据（与参考实现 `parseImgElem` 一致）：
/// * 片段必须以 `/` 开头才算路径；
/// * 优先级 34.30 > 16 > 15 > md5 兜底；
/// * 被丢弃的片段不能让整条 URL 变成垃圾——要往下一个来源退。
///
/// 跑：`dart run tool/qq8_elem_image_selftest.dart`
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/wlogin8/qq8_elem.dart';
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

/// 造一个 `Elem`，里面塞 `custom_face`（群图）。
Uint8List _groupImage({
  required String md5,
  String? p16,
  String? p15,
  String? p7,
  String? p34Path,
}) {
  final customFace = Qq8Pb.encode(<int, Object?>{
    13: _bs(List<int>.generate(16, (i) => i)), // md5 字节（hex 用）
    22: 800,
    23: 600,
    25: 12345,
    20: 1000,
    if (p7 != null) 7: p7,
    if (p16 != null) 16: p16,
    if (p15 != null) 15: p15,
    if (p34Path != null) 34: Qq8Pb.encode(<int, Object?>{30: p34Path}),
  });
  return Qq8Pb.encode(<int, Object?>{8: customFace});
}

/// 造一个 `Elem`，里面塞 `not_online_image`（私聊图）。
Uint8List _privateImage({required String md5Hex, String? p15, String? su}) {
  final notOnline = Qq8Pb.encode(<int, Object?>{
    1: md5Hex,
    2: 999,
    5: 1000,
    8: 600,
    9: 800,
    if (p15 != null) 15: p15,
    if (su != null) 29: Qq8Pb.encode(<int, Object?>{30: su}),
  });
  return Qq8Pb.encode(<int, Object?>{4: notOnline});
}

void main() {
  stdout.writeln('=== 图片直链拼接 ===');

  // ---- 群图 ----
  stdout.writeln('\n-- 群图（CustomFace）');
  const md5BytesHex = '000102030405060708090a0b0c0d0e0f';

  // 16 号是正常路径 → 用它
  var img = _imageOf(_groupImage(md5: md5BytesHex, p16: '/download?appid=1407&x=1'));
  checkEq('16 号是路径时拼出来',
      img.url, 'https://gchat.qpic.cn/download?appid=1407&x=1');

  // 16 号只有 query → 必须丢弃，退回 md5 兜底
  img = _imageOf(_groupImage(md5: md5BytesHex, p16: '&rkey=AAA&spec=0'));
  check('16 号只有 query 时不被当成路径', img.url?.startsWith('https://gchat.qpic.cn/') ?? false,
      '实际 ${img.url}');
  checkEq('16 号无效时退回 md5 兜底', img.url,
      'https://gchat.qpic.cn/gchatpic_new/0/0-0-${md5BytesHex.toUpperCase()}/0');
  check('不会出现「域名后直接接 &」的坏 URL',
      !(img.url ?? '').contains('.cn&'), '实际 ${img.url}');

  // 16 号无效但有 15 号路径 → 用 15 号（域名换成 c2cpicdw）
  img = _imageOf(_groupImage(
      md5: md5BytesHex, p16: '&rkey=AAA', p15: '/offpic_new/0/x/0'));
  checkEq('16 号无效时退到 15 号', img.url,
      'https://c2cpicdw.qpic.cn/offpic_new/0/x/0');

  // 34.30 优先于 16
  img = _imageOf(_groupImage(
    md5: md5BytesHex,
    p16: '/from16',
    p34Path: '/from34',
  ));
  checkEq('34.30 优先于 16', img.url, 'https://gchat.qpic.cn/from34');

  // 34.30 也无效时退到 16
  img = _imageOf(_groupImage(
    md5: md5BytesHex,
    p16: '/from16',
    p34Path: '&only-query',
  ));
  checkEq('34.30 无效时退到 16', img.url, 'https://gchat.qpic.cn/from16');

  // 全都没有 → md5 兜底
  img = _imageOf(_groupImage(md5: md5BytesHex));
  checkEq('三个片段都没有时用 md5 兜底', img.url,
      'https://gchat.qpic.cn/gchatpic_new/0/0-0-${md5BytesHex.toUpperCase()}/0');

  // ---- 私聊图 ----
  stdout.writeln('\n-- 私聊图（NotOnlineImage）');
  const md5Hex = 'aabbccddeeff00112233445566778899';

  img = _imageOf(_privateImage(md5Hex: md5Hex, su: '/download?appid=1407'));
  checkEq('29.30 是路径时补 spec/rf', img.url,
      'https://c2cpicdw.qpic.cn/download?appid=1407&spec=0&rf=naio');

  img = _imageOf(_privateImage(md5Hex: md5Hex, su: '&rkey=BBB'));
  check('29.30 只有 query 时不被当成路径',
      !(img.url ?? '').contains('.cn&'), '实际 ${img.url}');

  img = _imageOf(_privateImage(md5Hex: md5Hex, p15: '/offpic_new/0/y/0'));
  checkEq('29.30 无效时退到 15 号', img.url,
      'https://c2cpicdw.qpic.cn/offpic_new/0/y/0');

  img = _imageOf(_privateImage(md5Hex: md5Hex));
  checkEq('全都没有时 URL 为 null（由 UI 显示占位）', img.url, null);
  checkEq('但 md5 仍然拿到，能拼文件名', img.md5, md5Hex);

  stdout.writeln('\n=== 结果: $_pass 通过, $_fail 失败 ===');
  if (_fail > 0) throw StateError('$_fail 项失败');
}

/// 用一个图片 Elem 扫描，取出唯一的 [Qq8ImageElem]。
Qq8ImageElem _imageOf(Uint8List elem) {
  final scan = Qq8ElemScan()..scan(elem);
  final imgs = scan.elems.whereType<Qq8ImageElem>().toList();
  if (imgs.isEmpty) throw StateError('没有解出图片元素');
  return imgs.first;
}
