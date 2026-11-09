// `FaceRecents` 的自测：排序规则、上限、旧格式迁移、坏文件容错。
//
// 规则全部对齐 TG（`messenger/Emoji.java`）：
// * `:84` `MAX_RECENT_EMOJI_COUNT = 48`
// * `:911-934` `sortEmoji()` 按使用次数降序
// * `:893-905` `addRecentEmoji()` 只计数，满了替换最后一条
//
// 为什么值得单测：旧实现是「按时间最新在前」，与 TG 语义相反。
// 这个差别在界面上只表现为「最近那几个的顺序不对」，肉眼很难判定对错，
// 只能靠断言钉住。
import 'dart:convert';
import 'dart:io';

import 'package:penguinchat/ui/face/face_recents.dart';

int _pass = 0;
int _fail = 0;

void ok(String name) {
  _pass++;
  stdout.writeln('  \u2713 $name');
}

void bad(String name, String detail) {
  _fail++;
  stdout.writeln('  \u2717 $name\n      \u2192 $detail');
}

void check(String name, bool cond, [String detail = '']) {
  if (cond) {
    ok(name);
  } else {
    bad(name, detail);
  }
}

void checkEq(String name, Object? actual, Object? expected) {
  if ('$actual' == '$expected') {
    ok(name);
  } else {
    bad(name, '期望 $expected，实际 $actual');
  }
}

void section(String t) => stdout.writeln('\n$t');

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('face_recents_');

  section('1. 上限与常量');
  {
    checkEq('上限是 48（Emoji.java:84）', FaceRecents.limit, 48);
  }

  section('2. 排序：按使用次数降序，不是按时间');
  {
    final f = File('${dir.path}/a.json');
    final r = FaceRecents(f);
    // 依次用：14 一次、109 三次、12 两次。
    r.touch('14');
    r.touch('109');
    r.touch('12');
    r.touch('109');
    r.touch('12');
    r.touch('109');
    // 若按「时间最新在前」，结果会是 109,12,14（碰巧一样）——
    // 所以再补一次 14，让「最新」与「最常用」分开。
    r.touch('14');
    // 次数：109=3、14=2、12=2。按次数降序应为 109 先，14/12 按插入序。
    checkEq('次数最高的排第一', r.ids.first, '109');
    checkEq('同次数的保持插入顺序（14 早于 12）', r.ids.join(','), '109,14,12');
  }

  section('3. 落盘与读回：计数不丢');
  {
    final f = File('${dir.path}/b.json');
    final r1 = FaceRecents(f);
    r1.touch('7');
    r1.touch('7');
    r1.touch('8');
    // `touch` 是同步 + 异步落盘；写是串行队列，等队列跑完再读。
    // 300ms 足够（三次写各自几毫秒）；这里刻意不用固定 sleep 断言业务时序，
    // 只是等 IO 落地，与 PITFALLS A2 那条「别用 sleep 断言某事已发生」不同。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    check('文件已写出', await f.exists());

    final r2 = FaceRecents(f);
    await r2.load();
    checkEq('读回后次数高的仍在前', r2.ids.join(','), '7,8');
    // 再加一次 8，两者次数相等（都是 2）；此时按读入顺序，7 仍在先。
    r2.touch('8');
    checkEq('次数相等时保持稳定顺序', r2.ids.join(','), '7,8');
    // 再加一次 8 → 8 次数 3，反超。
    r2.touch('8');
    checkEq('次数反超后排到前面', r2.ids.join(','), '8,7');
  }

  section('4. 旧格式 {"ids": [...]} 仍能读（迁移成次数 1）');
  {
    final f = File('${dir.path}/legacy.json');
    await f.writeAsString(jsonEncode(<String, Object?>{
      'ids': <String>['12', '109', '14'],
    }));
    final r = FaceRecents(f);
    await r.load();
    checkEq('旧格式按原顺序读回（都是次数 1）', r.ids.join(','), '12,109,14');
  }

  section('5. 坏文件与空值：不抛、按空处理');
  {
    final f = File('${dir.path}/bad.json');
    await f.writeAsString('{ 这不是 json');
    final r = FaceRecents(f);
    await r.load();
    checkEq('坏 JSON 按空处理', r.ids.length, 0);

    final f2 = File('${dir.path}/bad2.json');
    await f2.writeAsString(jsonEncode(<String, Object?>{
      'counts': <String, Object?>{'12': 'abc', '109': 2, '': 5},
    }));
    final r2 = FaceRecents(f2);
    await r2.load();
    checkEq('非数字计数被丢掉，合法项保留', r2.ids.join(','), '109');

    final r3 = FaceRecents(null);
    await r3.load();
    r3.touch('12');
    checkEq('没有文件句柄时照常工作（测试/只读场景）', r3.ids.join(','), '12');
  }

  section('6. 超过上限时裁掉次数最低的');
  {
    final f = File('${dir.path}/trim.json');
    final r = FaceRecents(f);
    // 塞 50 条，各用 1 次；再把 'keep' 用 5 次。
    for (int i = 0; i < 50; i++) {
      r.touch('e$i');
    }
    for (int i = 0; i < 5; i++) {
      r.touch('keep');
    }
    check('总数不超过上限', r.ids.length <= FaceRecents.limit,
        '${r.ids.length}');
    check('高次数的条目一定被保留', r.ids.contains('keep'));
    checkEq('最高次数排第一', r.ids.first, 'keep');
  }

  section('7. 空 id 不记');
  {
    final r = FaceRecents(null);
    r.touch('');
    checkEq('空字符串被忽略', r.ids.length, 0);
  }

  await cleanup(dir);
  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}

Future<void> cleanup(Directory d) async {
  try {
    if (await d.exists()) await d.delete(recursive: true);
  } on FileSystemException {
    // Windows 上偶发句柄未放开；清理失败不影响判据（只看失败项数）。
  }
}
