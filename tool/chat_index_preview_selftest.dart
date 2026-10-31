/// 冷启动会话预览自测（lib/client_api/chat_index_preview.dart）
///
/// 纯离线：造临时目录 + chats.json，验证"读哪个账号""解析""排序""坏文件
/// 不抛"四条。这是"点图标立刻看到会话列表"那条启动路径的数据地基 ——
/// 它一旦静默返回 null，真机上的表现就是又退回品牌页，很难在日志里看出来。
///
/// 运行：dart run tool/chat_index_preview_selftest.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:qqclient/client_api/chat_index_preview.dart';
import 'package:qqclient/client_api/objects.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  OK  $name${detail == null ? '' : '   ($detail)'}');
  } else {
    _fail++;
    stdout.writeln('  NG  $name${detail == null ? '  ($detail)' : ''}');
  }
}

Directory _tmp(String tag) =>
    Directory.systemTemp.createTempSync('qqclient-preview-$tag-');

File _index(Directory accountsRoot, int uin) {
  final dir = Directory('${accountsRoot.path}${Platform.pathSeparator}$uin');
  dir.createSync(recursive: true);
  return File('${dir.path}${Platform.pathSeparator}chats.json');
}

Map<String, dynamic> _chatJson(
  String id,
  String title, {
  String type = 'private',
  int? lastTime,
  bool pinned = false,
  int priority = 3,
  int unread = 0,
  bool archived = false,
}) =>
    <String, dynamic>{
      'id': id,
      'title': title,
      'type': type,
      if (lastTime != null) 'lastTime': lastTime,
      if (pinned) 'pinned': true,
      'priority': priority,
      if (unread != 0) 'unread': unread,
      if (archived) 'archived': true,
      'lastMessage': '最后一条',
    };

Future<void> main() async {
  stdout.writeln('== 冷启动会话预览 ==');

  // 1. 没有 accounts 目录 / 没有任何索引 -> null（调用方退回品牌页）
  final empty = _tmp('empty');
  check('没有账号目录时返回 null', await loadChatIndexPreview(empty) == null);
  final accountsRoot = Directory('${empty.path}${Platform.pathSeparator}accounts')
    ..createSync(recursive: true);
  check('有 accounts 但无 chats.json 时返回 null',
      await loadChatIndexPreview(empty) == null);

  // 2. 正常解析 + 排序
  final index = _index(accountsRoot, 10001);
  index.writeAsStringSync(jsonEncode(<Map<String, dynamic>>[
    _chatJson('private_20002', '小明', lastTime: 2000),
    _chatJson('group_30003', '测试群',
        type: 'group', lastTime: 5000, unread: 3),
    _chatJson('private_20004', '置顶的人', lastTime: 1000, pinned: true),
    _chatJson('private_20005', '优先级高', lastTime: 500, priority: 1),
    _chatJson('private_20006', '归档的', lastTime: 9000, archived: true),
  ]));
  final preview = await loadChatIndexPreview(empty);
  check('解析出 5 个会话', preview?.chats.length == 5,
      '实际=${preview?.chats.length}');
  check('uin 取目录名', preview?.uin == 10001, '实际=${preview?.uin}');
  final order = (preview?.chats ?? const <Chat>[]).map((c) => c.id).toList();
  check('置顶最前', order.isNotEmpty && order.first == 'private_20004', '$order');
  check('其次按优先级（priority 1 在 3 之前）',
      order.indexOf('private_20005') < order.indexOf('group_30003'), '$order');
  check('同优先级按最后消息时间倒序',
      order.indexOf('group_30003') < order.indexOf('private_20002'), '$order');
  check('最后消息时间解析正确',
      preview?.chats.firstWhere((c) => c.id == 'group_30003').lastTime ==
          DateTime.fromMillisecondsSinceEpoch(5000));
  check('未读数解析正确',
      preview?.chats.firstWhere((c) => c.id == 'group_30003').unreadCount == 3);
  check('群类型解析正确',
      preview?.chats.firstWhere((c) => c.id == 'group_30003').type ==
          ChatType.group);
  check('归档标记解析正确',
      preview?.chats.firstWhere((c) => c.id == 'private_20006').archived == true);

  // 3. 多账号：取 chats.json 修改时间最新的那一个
  final second = _index(accountsRoot, 30002);
  second.writeAsStringSync(jsonEncode(<Map<String, dynamic>>[
    _chatJson('private_40004', '另一个号的人', lastTime: 7000),
  ]));
  second.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
  final multi = await loadChatIndexPreview(empty);
  check('多账号时取最新那份索引', multi?.uin == 30002, '实际=${multi?.uin}');
  check('取到的是新账号的会话', multi?.chats.single.title == '另一个号的人');

  // 4. 坏索引 -> null 而不是抛异常（宁可退回品牌页，也不许启动失败）
  second.writeAsStringSync('{ this is not json');
  check('索引损坏时返回 null 而不抛', await loadChatIndexPreview(empty) == null);

  // 5. 结构不认识（对象但没有 chats 数组）-> null
  second.writeAsStringSync(jsonEncode(<String, dynamic>{'foo': 1}));
  check('结构不认识时返回 null', await loadChatIndexPreview(empty) == null);

  // 6. 空数组 -> null（没有东西可画，别拿一个空列表骗宿主）
  second.writeAsStringSync('[]');
  check('空索引返回 null', await loadChatIndexPreview(empty) == null);

  stdout.writeln('\n结果: pass=$_pass fail=$_fail');
  if (_fail > 0) exit(1);
}
