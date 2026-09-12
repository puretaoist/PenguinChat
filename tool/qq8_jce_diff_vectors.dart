// 由 ../analysis/scripts/gen_jce_diff_vectors.cjs 生成——**勿手改**。
//
// 差分用例：输入与期望字节都来自可跑的参考实现（oicq js 时代
// lib/algo/jce），由 tool/qq8_jce_selftest.dart 逐条比对
// （编码逐字节一致 + 解码往返一致）。
library;

import 'dart:typed_data';

final List<({String name, Map<int, Object?> fields, String hex})>
    kQq8JceDiffVectors =
    <({String name, Map<int, Object?> fields, String hex})>[
  (
    name: 'tag 边界 14/15/255',
    fields: {14: 'a', 15: 'b', 255: 'c'},
    hex: '0ae60161f60f0162f6ff01630b',
  ),
  (
    name: '字符串长度 255/256',
    fields: {14: 'yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy', 15: 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'},
    hex: '0ae6ff797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979f70f000001007a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a0b',
  ),
  (
    name: '空容器',
    fields: {1: '', 2: <Object?>[], 3: <Object?, Object?>{}, 4: Uint8List.fromList(<int>[])},
    hex: '0a1600290c380c4d000c0b',
  ),
  (
    name: '中文与 emoji（按 UTF-8 字节数）',
    fields: {1: '中文测试', 2: 'emoji😀'},
    hex: '0a160ce4b8ade69687e6b58be8af952609656d6f6a69f09f98800b',
  ),
  (
    name: '整数边界',
    fields: {1: -128, 2: -129, 3: 127, 4: 128, 5: -32768, 6: 32767, 7: 32768, 8: -2147483648, 9: 2147483647, 10: 2147483648, 11: 4294967296, 12: 9007199254740991},
    hex: '0a108021ff7f307f410080518000617fff72000080008280000000927fffffffa30000000080000000b30000000100000000c3001fffffffffffff0b',
  ),
  (
    name: '列表/映射/嵌套',
    fields: {1: <Object?>[1, 'a', Uint8List.fromList(<int>[255]), <Object?>[2, 3], <Object?, Object?>{'k': 'v'}], 2: <Object?, Object?>{'x': <Object?>[1, 2], 'y': Uint8List.fromList(<int>[0, 255])}},
    hex: '0a19000500010601610d000001ff0900020002000308000106016b160176280002060178190002000100020601791d00000200ff0b',
  ),
  (
    name: '双精度',
    fields: {1: 3.5, 2: -0.5, 3: 0.3333333333333333},
    hex: '0a15400c00000000000025bfe0000000000000353fd55555555555550b',
  ),
  (
    name: '单双字节头混合',
    fields: {0: 1, 14: 2, 15: 3, 254: 4, 255: 5},
    hex: '0a0001e002f00f03f0fe04f0ff050b',
  ),
];
