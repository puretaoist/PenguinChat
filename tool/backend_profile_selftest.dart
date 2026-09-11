/// 后端适配表（`assets/backends/*.json`）与 JSONPath 求值器的离线自测
///
/// **不需要网络、不需要 Flutter 引擎、不需要 QQ 账号**：直接读工程里的
/// asset 文件，用手写的真实响应样本验证"同一份逻辑代码能否在不同后端上
/// 得到同样结果"。
///
/// 核心验证目标（本文件存在的理由）：
///   **NapCat 与 Lagrange 的同一条逻辑数据，字段名完全不同，但经适配表
///   归一化后必须逐字段相等。** 这是把适配做成数据的全部意义。
///
/// 运行（注意：本环境的 `dart.bat` 会卡住，直接用 SDK 二进制）：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/backend_profile_selftest.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:qqclient/kernel/onebot/backend_profile.dart';
import 'package:qqclient/kernel/onebot/json_path.dart';

// ---------------------------------------------------------------------------
// 断言工具
// ---------------------------------------------------------------------------

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  \u2713 $name');
  } else {
    _failed++;
    stdout.writeln('  \u2717 $name${detail == null ? '' : '  → $detail'}');
  }
}

void checkEq(String name, Object? actual, Object? expected) {
  final ok = _deepEq(actual, expected);
  check(name, ok, ok ? null : '期望 ${jsonEncode(expected)}，实际 ${jsonEncode(actual)}');
}

bool _deepEq(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEq(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

void section(String title) => stdout.writeln('\n$title');

// ---------------------------------------------------------------------------
// 样本数据（模拟各后端的真实响应 data 字段）
// ---------------------------------------------------------------------------

const napCatFriends = [
  {
    'categoryId': 0,
    'categoryName': '我的好友',
    'categorySortId': 1,
    'buddyList': [
      {'user_id': 10001, 'nickname': '小明', 'remark': '同学', 'longNick': '晚上好'},
    ],
  },
  {
    'categoryId': 1,
    'categoryName': '同事',
    'categorySortId': 2,
    'buddyList': [
      {'user_id': 10002, 'nickname': '小红', 'remark': '', 'longNick': '加班中'},
    ],
  },
];

/// Lagrange 的好友列表是平铺的，分组放在 group 字段里，且没有 longNick。
const lagrangeFriends = [
  {
    'user_id': 10001,
    'nickname': '小明',
    'remark': '同学',
    'group': {'group_id': 0, 'group_name': '我的好友'},
  },
  {
    'user_id': 10002,
    'nickname': '小红',
    'remark': '',
    'group': {'group_id': 1, 'group_name': '同事'},
  },
];

const napCatFiles = {
  'files': [
    {
      'file_id': 'f1',
      'file_name': '资料.zip',
      'size': 123456,
      'download_times': 7,
      'dead_time': 0,
      'modify_time': 1700000000,
      'uploader_name': '小明',
      'create_time': 1699999999,
      'creator_name': '小明',
    },
  ],
  'folders': <Map<String, dynamic>>[],
};

const lagrangeFiles = {
  'files': [
    {
      'file_id': 'f1',
      'file_name': '资料.zip',
      'file_size': 123456,
      'download_times': 7,
      'dead_time': 0,
      'modify_time': 1700000000,
      'uploader_name': '小明',
      'create_time': 1699999999,
      'create_name': '小明',
    },
  ],
  'folders': <Map<String, dynamic>>[],
};

const napCatStranger = {
  'user_id': 10001,
  'nickname': '小明',
  'sex': 'male',
  'age': 20,
  'longNick': '晚上好',
  'qid': 'xiaoming',
  'qqLevel': 42,
  'country': '中国',
  'province': '北京',
  'city': '北京',
  'regTime': 1600000000,
  'birthday_year': 2000,
  'birthday_month': 1,
  'birthday_day': 2,
};

const lagrangeStranger = {
  'user_id': 10001,
  'nickname': '小明',
  'sex': 'male',
  'age': 20,
  'sign': '晚上好',
  'q_id': 'xiaoming',
  'level': 42,
  'RegisterTime': 1600000000,
};

// ---------------------------------------------------------------------------
// 1. JSONPath 求值器
// ---------------------------------------------------------------------------

void testJsonPath() {
  section('1. JSONPath 求值器');

  const doc = {
    'a': {
      'b': {'c': 1},
      'list': [
        {'x': 10},
        {'x': 20},
      ],
    },
    'files': [
      {'file': 'a.jpg', 'meta': {'file': 'nested.jpg'}},
    ],
    'empty': <String, dynamic>{},
  };

  checkEq(r'逐级取成员 $.a.b.c', selectOne(doc, r'$.a.b.c'), 1);
  checkEq(r'取下标 $.a.list[0].x', selectOne(doc, r'$.a.list[0].x'), 10);
  checkEq(r'列表通配 $.a.list[*].x', selectAll(doc, r'$.a.list[*].x'), [10, 20]);
  checkEq(r'省略前导 $ 也支持', selectOne(doc, 'a.b.c'), 1);
  checkEq(r'Map 通配 $.* 展开所有值', selectAll({'x': 1, 'y': 2}, r'$.*'), [1, 2]);

  // 递归下降：本层与更深层的同名键都要取到
  checkEq(r'递归下降 $..file', selectAll(doc, r'$..file'), ['a.jpg', 'nested.jpg']);

  // 列表展开辅助：单命中且本身是 List 时展开
  checkEq('selectList 平铺单层列表', selectList(doc, r'$.a.list[*].x'), [10, 20]);
  checkEq('selectList 展开 List 节点', selectList({'v': [1, 2, 3]}, r'$.v'), [1, 2, 3]);

  // N/A 语义
  checkEq('null 路径返回空', selectAll(doc, null), <Object?>[]);
  checkEq('空串路径返回空', selectAll(doc, ''),
      <Object?>[]);
  checkEq('不存在的字段返回 []', selectAll(doc, r'$.nope'), <Object?>[]);
  checkEq('字段存在但值为 null → 命中 null', selectAll({'k': null}, r'$.k'), [null]);

  // 语法错误必须立刻暴露，而不是静默返回空
  var threw = false;
  try {
    selectAll(doc, r'$.a[');
  } on FormatException {
    threw = true;
  }
  check('缺 ] 抛 FormatException', threw);

  threw = false;
  try {
    selectAll(doc, r'$..');
  } on FormatException {
    threw = true;
  }
  check('`..` 后缺字段名抛 FormatException', threw);

  // 真实场景：多级通配
  checkEq(
    r'多级通配 $[*].buddyList[*]',
    selectAll(napCatFriends, r'$[*].buddyList[*].user_id'),
    [10001, 10002],
  );

  // 真实场景：嵌套下标 $message.image.0.id
  checkEq(
    r'嵌套下标 $.message.image.0.id',
    selectOne({
      'message': {
        'image': [
          {'id': 'img-1'},
        ],
      },
    }, r'$.message.image.0.id'),
    'img-1',
  );

  // 相对路径（列表项内部）
  checkEq(
    '相对路径 /group/group_name',
    selectOne(lagrangeFriends[0], '/group/group_name'),
    '我的好友',
  );
}

// ---------------------------------------------------------------------------
// 2. 表加载与别名继承
// ---------------------------------------------------------------------------

BackendProfileRegistry loadRegistry() {
  final dir = Directory('assets/backends');
  if (!dir.existsSync()) {
    stderr.writeln('找不到 assets/backends/，请在工程根目录运行本脚本');
    exit(2);
  }
  final sources = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .map((f) => f.readAsStringSync())
      .toList();
  return BackendProfileRegistry.fromJsonStrings(sources);
}

void testRegistry(BackendProfileRegistry reg) {
  section('2. 适配表加载与别名继承');

  check('三张表都加载成功（含别名入口）', reg.names.length == 3, 'names=${reg.names}');

  final napcat = reg.resolve('NapCat.Onebot');
  check('按 app_name 精确匹配 NapCat', napcat != null && napcat.name == 'NapCat.Onebot');
  check('NapCat 表覆盖的 API 数量 > 20', (napcat?.apiCount ?? 0) > 20,
      'count=${napcat?.apiCount}');

  // 别名继承：LLOneBot 表只有两行，但解析后应拿到 NapCat 的全部 API
  final llonebot = reg.resolve('LLOneBot');
  check('LLOneBot 解析到 NapCat 表（redirect 继承）',
      llonebot != null && llonebot.name == 'NapCat.Onebot');
  check('继承后 API 数量与 NapCat 一致',
      llonebot?.apiCount == napcat?.apiCount,
      '${llonebot?.apiCount} vs ${napcat?.apiCount}');

  // 大小写宽松匹配
  check('大小写不敏感匹配', reg.resolve('napcat.onebot')?.name == 'NapCat.Onebot');

  // 未知后端不应让客户端崩溃
  check('未知 app_name 返回 null（由调用方回落）', reg.resolve('SomeNewBot') == null);
  check('resolveOrDefault 回落到兜底表',
      reg.resolveOrDefault('SomeNewBot').name == 'NapCat.Onebot');

  // 逻辑 API 并集
  final all = reg.allLogicalApis;
  check('逻辑 API 并集非空', all.isNotEmpty, 'count=${all.length}');
}

// ---------------------------------------------------------------------------
// 3. 跨后端归一化：本测试组是整套设计的核心证据
// ---------------------------------------------------------------------------

void testCrossBackendEquivalence(BackendProfileRegistry reg) {
  section('3. 跨后端归一化（核心）');

  final napcat = reg.resolve('NapCat.Onebot')!;
  final lagrange = reg.resolve('Lagrange.OneBot')!;

  // --- 好友列表 ---
  final nFriends = napcat
      .spec('friend_list')!
      .itemsFrom(napCatFriends)
      .map((e) => napcat.spec('friend_list')!.itemFrom(e).cast<String, dynamic>())
      .toList();
  final lFriends = lagrange
      .spec('friend_list')!
      .itemsFrom(lagrangeFriends)
      .map((e) => lagrange.spec('friend_list')!.itemFrom(e).cast<String, dynamic>())
      .toList();

  check('两边都取到 2 个好友', nFriends.length == 2 && lFriends.length == 2,
      'napcat=${nFriends.length} lagrange=${lFriends.length}');

  checkEq('好友 user_id 一致', nFriends[0]['user_id'], lFriends[0]['user_id']);
  checkEq('好友 nickname 一致', nFriends[0]['nickname'], lFriends[0]['nickname']);
  checkEq('好友 remark 一致', nFriends[0]['remark'], lFriends[0]['remark']);
  checkEq('两个来源的 user_id 序列相同',
      nFriends.map((e) => e['user_id']).toList(),
      lFriends.map((e) => e['user_id']).toList());

  // 差异必须被如实记录为 null，而不是被悄悄丢掉
  checkEq('NapCat 不提供分组 → 标记为 null', nFriends[0]['category_id'], null);
  checkEq('Lagrange 的分组字段被正确映射', lFriends[0]['category_id'], 0);
  checkEq('Lagrange 不提供 longNick → 标记为 null', lFriends[0]['longNick'], null);
  checkEq('NapCat 的 longNick 被正确取出', nFriends[0]['longNick'], '晚上好');

  // --- 群文件（字段名完全不同：size/file_size、creator_name/create_name）---
  final nFiles = napcat.spec('group_files')!.itemsFrom(napCatFiles);
  final lFiles = lagrange.spec('group_files')!.itemsFrom(lagrangeFiles);
  final nFile = napcat.spec('group_files')!.itemFrom(nFiles.first);
  final lFile = lagrange.spec('group_files')!.itemFrom(lFiles.first);

  checkEq('群文件 size 归一化一致（size vs file_size）', nFile['size'], lFile['size']);
  checkEq('群文件 creator_name 归一化一致（creator_name vs create_name）',
      nFile['creator_name'], lFile['creator_name']);
  checkEq('群文件 size 值正确', nFile['size'], 123456);

  // --- 陌生人信息（longNick/sign、qid/q_id、qqLevel/level）---
  final nStranger = napcat.spec('stranger_info')!.oneFrom(napCatStranger);
  final lStranger = lagrange.spec('stranger_info')!.oneFrom(lagrangeStranger);

  checkEq('签名归一化一致（longNick vs sign）', nStranger['longNick'], lStranger['longNick']);
  checkEq('个性号归一化一致（qid vs q_id）', nStranger['qid'], lStranger['qid']);
  checkEq('QQ 等级归一化一致（qqLevel vs level）',
      nStranger['qqLevel'], lStranger['qqLevel']);
  checkEq('等级值正确', nStranger['qqLevel'], 42);
}

// ---------------------------------------------------------------------------
// 4. API 名差异与能力探测
// ---------------------------------------------------------------------------

void testActionResolution(BackendProfileRegistry reg) {
  section('4. API 名差异与能力探测');

  final napcat = reg.resolve('NapCat.Onebot')!;
  final lagrange = reg.resolve('Lagrange.OneBot')!;

  // 同一逻辑能力 → 不同 action
  checkEq('好友列表 action 不同（NapCat）',
      napcat.spec('friend_list')!.actions(), ['get_friends_with_category']);
  checkEq('好友列表 action 不同（Lagrange）',
      lagrange.spec('friend_list')!.actions(), ['get_friend_list']);

  checkEq('消息回应 action 不同（NapCat）',
      napcat.spec('send_respond')!.actions(), ['set_msg_emoji_like']);
  checkEq('消息回应 action 不同（Lagrange）',
      lagrange.spec('send_respond')!.actions(), ['set_group_reaction']);

  // 私聊场景走 private_action
  checkEq('消息历史：群聊 action',
      napcat.spec('message_history')!.actions(), ['get_group_msg_history']);
  checkEq('消息历史：私聊走 private_action',
      napcat.spec('message_history')!.actions(isPrivate: true), ['get_friend_msg_history']);
  checkEq('已读上报：私聊走 private_action',
      napcat.spec('set_message_read')!.actions(isPrivate: true), ['mark_private_msg_as_read']);

  // 能力差异：表里有 / 没有
  check('NapCat 有已读上报', napcat.spec('set_message_read') != null);
  check('Lagrange 没有已读上报（能力探测应能发现）',
      lagrange.spec('set_message_read') == null);
  check('Lagrange 有设置群名', lagrange.spec('set_group_name') != null);
  check('NapCat 没有设置群名', napcat.spec('set_group_name') == null);

  // 备选 action 写法 `a|b`
  const alternative = ApiSpec(action: 'get_friend_list|get_group_list', map: {});
  checkEq('`a|b` 备选写法被拆成候选列表',
      alternative.actions(), ['get_friend_list', 'get_group_list']);

  // 分页语义差异
  check('NapCat 消息历史为 full 分页',
      napcat.spec('message_history')!.pager == Pager.full);
  check('Lagrange 消息历史为 incremental 分页',
      lagrange.spec('message_history')!.pager == Pager.incremental);

  // reverse
  check('Lagrange 收藏表情需要倒序', lagrange.spec('custom_face')!.reverse);
  check('NapCat 收藏表情不需要倒序', !napcat.spec('custom_face')!.reverse);

  // Apple 端断言：所有 action 名非空
  var allNamed = true;
  for (final p in [napcat, lagrange]) {
    for (final s in p.apis.values) {
      if (s.actions().any((a) => a.isEmpty)) allNamed = false;
    }
  }
  check('所有条目的 action 名非空', allNamed);
}

// ---------------------------------------------------------------------------
// 5. 消息历史样本
// ---------------------------------------------------------------------------

void testMessageHistory(BackendProfileRegistry reg) {
  section('5. 消息历史提取');

  final napcat = reg.resolve('NapCat.Onebot')!;
  final spec = napcat.spec('message_history')!;

  const sample = {
    'messages': [
      {
        'message_id': 101,
        'real_seq': '500',
        'target_id': 20001,
        'message_type': 'group',
        'time': 1700000000,
        'post_type': 'message',
        'group_id': 20001,
        'sender': {'user_id': 10001, 'nickname': '小明'},
        'message': [
          {'type': 'text', 'data': {'text': '你好'}},
        ],
        'raw_message': '你好',
      },
    ],
  };

  final items = spec.itemsFrom(sample);
  check(r'从 $.messages[*] 取出 1 条', items.length == 1, 'len=${items.length}');

  final rec = spec.itemFrom(items.first);
  checkEq('message_id 提取正确', rec['message_id'], 101);
  checkEq('群号提取正确', rec['group_id'], 20001);
  checkEq('发送者 QQ 从 /sender/user_id 取出', rec['user_id'], 10001);
  checkEq('消息段数组原样保留', (rec['message'] as List).length, 1);
  checkEq('seq 从 /real_seq 取出', rec['seq'], '500');

  // source 不存在时 itemsFrom 返回空而不是抛异常
  const emptySpec = ApiSpec(action: 'x');
  checkEq('无 source 时 itemsFrom 返回空表', emptySpec.itemsFrom(sample), <Object?>[]);
}

// ---------------------------------------------------------------------------
// 6. 表自身的健壮性
// ---------------------------------------------------------------------------

void testTableRobustness() {
  section('6. 表健壮性');

  var threw = false;
  try {
    ApiSpec.fromJson('bad', <String, dynamic>{});
  } on FormatException {
    threw = true;
  }
  check('缺 action 的表项抛 FormatException', threw);

  threw = false;
  try {
    BackendProfile.fromJson(<String, dynamic>{});
  } on FormatException {
    threw = true;
  }
  check('缺 name 的表抛 FormatException', threw);

  // 坏路径在**首次使用**时抛错，而不是在加载时静默接受
  final p = BackendProfile.fromJson({
    'name': 'X',
    'apis': {
      'a': {
        'action': 'a',
        'source': r'$.v[*]',
        'map': {'bad': r'$[abc]'},
      },
    },
  });
  var pathThrew = false;
  try {
    final items = p.spec('a')!.itemsFrom({
      'v': [
        {'bad': 1},
      ],
    });
    p.spec('a')!.itemFrom(items.first);
  } on FormatException {
    pathThrew = true;
  }
  check('非法路径在求值时抛 FormatException', pathThrew);

  // 循环 redirect 不应死循环
  final cyclic = BackendProfileRegistry([
    const BackendProfile(name: 'A', redirect: 'B'),
    const BackendProfile(name: 'B', redirect: 'A'),
  ]);
  final resolved = cyclic.resolve('A');
  check('循环 redirect 不死循环', resolved != null);

  // map 里显式的 null 表示"后端不提供"
  final withNull = BackendProfile.fromJson({
    'name': 'Y',
    'apis': {
      'a': {
        'action': 'a',
        'map': {'provided': r'$.v', 'missing': null},
      },
    },
  });
  final rec = withNull.spec('a')!.oneFrom({'v': 7});
  checkEq('提供的字段被取出', rec['provided'], 7);
  check('不提供的字段保留键但值为 null',
      rec.containsKey('missing') && rec['missing'] == null);
}

// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('后端适配表 + JSONPath 离线自测');
  stdout.writeln('=' * 60);

  testJsonPath();

  final reg = loadRegistry();
  testRegistry(reg);
  testCrossBackendEquivalence(reg);
  testActionResolution(reg);
  testMessageHistory(reg);
  testTableRobustness();

  stdout.writeln('\n${'=' * 60}');
  stdout.writeln('通过 $_passed 项，失败 $_failed 项');
  exit(_failed == 0 ? 0 : 1);
}
