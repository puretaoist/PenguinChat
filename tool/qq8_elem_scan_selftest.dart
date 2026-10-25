/// 元素扫描的自测：哪些字段是「结构」、哪些是「内容」。
///
/// 覆盖 2026-10-25 真机暴露的那个 bug：**每条消息都带「不支持显示的消息」**。
/// 根因是 `Elem.elem_flags2`（字段 9）被当成认不出的内容元素，于是每条消息
/// 都被追加一句占位文案。它其实是官方 `im_msg_body$Elem` 里的元数据容器
/// （群名片/等级/靓号之类），与 `extra_info`(16) / `anon_group_msg`(21) /
/// `general_flags`(37) 同类——只做结构，不产生内容。
///
/// 关键点：**一个 `Elem` 只带一个字段**，字段 9 是作为 `rich_text.elems` 里的
/// 独立元素到达的（不是挤在文本那条里）。所以夹具要用 `scanAll` 喂一串
/// Elem，而不是往同一个 Elem 里塞两个字段——`scan()` 只看 `m.keys.first`。
///
/// 判据：
/// * 只带结构字段的消息，`text` 里**不能**出现 `[不支持显示的消息]`；
/// * 也**不能**多出 `Qq8UnsupportedElem`（文本自己的 `Qq8TextElem` 不算）；
/// * 但真正认不出的字段仍必须给占位（不能静默吞掉内容）。
///
/// 跑：`dart run tool/qq8_elem_scan_selftest.dart`
library;

import 'dart:convert';
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

/// 一个 `Elem`，只带一个字段 [field]，字段体是一小段 protobuf。
///
/// 体内容无关紧要——扫描器对这些字段只看字段号。
Uint8List _elem(int field) =>
    Qq8Pb.encode(<int, Object?>{field: Qq8Pb.encode(<int, Object?>{1: 'x'})});

/// 一个纯文本 `Elem`：`text`(1) → `Text.str`(1)。
///
/// 注意用 `utf8.encode` 而不是 `codeUnits`——后者给的是 UTF-16 码元，
/// `Uint8List.fromList` 会把 `20320` 截成低 8 位 `0x60`，解出来是乱码。
Uint8List _textElem(String s) => Qq8Pb.encode(<int, Object?>{
      1: Qq8Pb.encode(<int, Object?>{1: _bs(utf8.encode(s))}),
    });

/// 扫一串 Elem（`rich_text.elems` 的形状）。
Qq8ElemScan _scan(List<Uint8List> elems) {
  final s = Qq8ElemScan();
  s.scanAll(elems);
  return s;
}

/// `elems` 里除文本以外的东西（真正的「内容元素」）。
List<Object> _nonText(Qq8ElemScan s) =>
    s.elems.where((e) => e is! Qq8TextElem).toList();

void main() {
  stdout.writeln('=== 元素扫描：结构字段不产生占位 ===');

  // ---- 1. elem_flags2（字段 9）是结构，不是内容 --------------------------
  {
    final s = _scan(<Uint8List>[_textElem('你好')]);
    checkEq('纯文本：text = 你好', s.text.toString(), '你好');
    checkEq('纯文本：一个文本元素', s.elems.length, 1);
    check('纯文本：那个元素是 Qq8TextElem', s.elems.single is Qq8TextElem);

    final s2 = _scan(<Uint8List>[_textElem('你好'), _elem(9)]);
    checkEq('文本 + flags2：text 仍干净', s2.text.toString(), '你好');
    check('文本 + flags2：不出现「不支持显示的消息」',
        !s2.text.toString().contains('不支持'));
    checkEq('文本 + flags2：没有多出内容元素', _nonText(s2).length, 0);
    check('文本 + flags2：kinds 里记下了 unknown(9)（不是悄悄丢掉）',
        s2.kinds.contains('unknown(9)'), '实际 ${s2.kinds}');

    // 只有 flags2、没有文本（真机上一条纯元数据消息的形态）
    final s3 = _scan(<Uint8List>[_elem(9)]);
    checkEq('只有 flags2：text 为空', s3.text.toString(), '');
    checkEq('只有 flags2：不产生任何元素', s3.elems.length, 0);
    check('只有 flags2：kinds 有 unknown(9)', s3.kinds.contains('unknown(9)'));
  }

  // ---- 2. 其它结构字段同样不产生占位 ------------------------------------
  for (final field in const <int>[16, 21, 37]) {
    final s = _scan(<Uint8List>[_textElem('嗯'), _elem(field)]);
    checkEq('结构字段 $field：text 保持 嗯', s.text.toString(), '嗯');
    checkEq('结构字段 $field：不产生内容元素', _nonText(s).length, 0);
    check('结构字段 $field：kinds 记录为 ${elemName(field)}',
        s.kinds.contains(elemName(field)), '实际 ${s.kinds}');
  }

  // ---- 3. 真认不出的字段仍必须给占位 ------------------------------------
  // 40 不在 elemName 的已知表里、也不在结构集合内。
  {
    final s = _scan(<Uint8List>[_textElem('在'), _elem(40)]);
    checkEq('未知字段 40：文本本身没被吃掉', s.text.toString().startsWith('在'), true);
    check('未知字段 40：追加了占位文案',
        s.text.toString().contains('不支持显示的消息'), '实际 text = ${s.text}');
    final others = _nonText(s);
    checkEq('未知字段 40：产生一个内容元素', others.length, 1);
    check('未知字段 40：那个元素是 Qq8UnsupportedElem',
        others.single is Qq8UnsupportedElem);
    checkEq('未知字段 40：field 记为 40',
        (others.single as Qq8UnsupportedElem).field, 40);
  }

  // ---- 4. 结构字段与真实内容共存时，不互相干扰 --------------------------
  // 真机形态：一条群消息 = 文本 Elem + elem_flags2 Elem（+ 有时 extra_info）。
  {
    final s = _scan(<Uint8List>[
      _textElem('周末出来玩'),
      _elem(9),
      _elem(16),
    ]);
    checkEq('文本 + 两个结构元素：text 干净', s.text.toString(), '周末出来玩');
    checkEq('文本 + 两个结构元素：无多余内容元素', _nonText(s).length, 0);
  }

  // ---- 5. 三个结构字段都进了集合（防将来被删掉一个） --------------------
  {
    for (final field in const <int>[9, 16, 21, 37]) {
      final s = _scan(<Uint8List>[_elem(field)]);
      check('字段 $field 是结构字段（无内容元素）', _nonText(s).isEmpty);
    }
  }

  stdout.writeln('\n=== 结果: $_pass 通过, $_fail 失败 ===');
  if (_fail > 0) throw StateError('$_fail 项失败');
}
