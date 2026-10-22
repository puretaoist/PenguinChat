// 分层架构门禁：`STRUCTURE.md` 里那条「L4 → L3 → L2 → L1，绝不反向」
// 从 2026-09-10 写下第一天起就没有任何自动化检查，靠人眼——
// 结果是 `onebot_session.dart` 在 L2 却 import 了三个 L3 文件，
// 五个月后才被 2026-09-22 的复审用肉眼抓出来。
//
// 这个脚本把那条规矩变成可执行的断言。判据只有一条：
// **低层文件里不得出现对高层的 import**。
//
// 跑法：dart run tool/layering_selftest.dart
//
// 它扫描 `lib/` 下的真实源码（不是模拟数据），所以每次改动都会重新验证。
import 'dart:io';

int passed = 0;
int failed = 0;

void ok(String name, [String? note]) {
  passed++;
  stdout.writeln('  ok  $name${note == null ? '' : '  ($note)'}');
}

void bad(String name, String why) {
  failed++;
  stdout.writeln('FAIL  $name\n      $why');
}

void check(String name, bool cond, [String note = '']) {
  if (cond) {
    ok(name, note.isEmpty ? null : note);
  } else {
    bad(name, note.isEmpty ? '条件为假' : note);
  }
}

/// 一个层的定义：目录 + 允许依赖的同级/更底层前缀。
class Layer {
  final String name;
  final String dir;
  final List<String> allowed;

  const Layer(this.name, this.dir, this.allowed);
}

/// 分层表（顺序即层级，从低到高）。
///
/// `import` 的目标只要**不属于本层也不属于允许的低层**，就算越界。
const List<Layer> kLayers = <Layer>[
  Layer('L1 infra', 'lib/infra/', <String>[]),
  Layer('L2 kernel', 'lib/kernel/', <String>['lib/infra/']),
  Layer('L3 client_api', 'lib/client_api/', <String>['lib/infra/', 'lib/kernel/']),
  Layer('L4 ui', 'lib/ui/', <String>['lib/infra/', 'lib/kernel/', 'lib/client_api/']),
];

/// 从源码文本里抽出所有 `import '...'` 的目标路径。
///
/// 只处理相对路径与 `package:qqclient/...`；`dart:` / `package:flutter/`
/// / 第三方包一律跳过（它们不属于本项目的层）。
List<String> importsOf(String source) {
  final out = <String>[];
  final re = RegExp(r"""^\s*import\s+['"]([^'"]+)['"]""", multiLine: true);
  for (final m in re.allMatches(source)) {
    out.add(m.group(1)!);
  }
  return out;
}

/// 把 import 目标解析成相对仓库根的路径（如 `lib/kernel/x.dart`）。
///
/// 返回 null 表示「不是本项目的文件」（dart: / package:flutter / 其它包）。
String? resolve(String fromFile, String target) {
  if (target.startsWith('dart:')) return null;
  if (target.startsWith('package:qqclient/')) {
    return 'lib/${target.substring('package:qqclient/'.length)}';
  }
  if (target.startsWith('package:')) return null;
  // 相对路径：以 fromFile 所在目录为基准做归一化
  final parts = fromFile.split('/')..removeLast();
  for (final seg in target.split('/')) {
    if (seg == '.' || seg.isEmpty) continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(seg);
    }
  }
  return parts.join('/');
}

/// 找出某层里所有越界的 import。
List<String> violationsIn(Layer layer) {
  final dir = Directory(layer.dir);
  if (!dir.existsSync()) return <String>[];
  final bad = <String>[];
  for (final f in dir.listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    final rel = f.path.replaceAll(r'\', '/');
    final from = rel.startsWith('lib/') ? rel : 'lib/$rel';
    final src = f.readAsStringSync();
    for (final target in importsOf(src)) {
      final resolved = resolve(from, target);
      if (resolved == null) continue;
      // 只关心 lib/ 下的本项目路径
      if (!resolved.startsWith('lib/')) continue;
      // 同层内互相 import 是允许的
      final sameLayer = kLayers.firstWhere(
        (l) => resolved.startsWith(l.dir),
        orElse: () => const Layer('?', '', <String>[]),
      );
      if (sameLayer.dir == layer.dir) continue;
      // 更高层 = 越界
      final allowed = layer.allowed.any(resolved.startsWith);
      if (!allowed) {
        bad.add('$from  →  $target  (解析为 $resolved)');
      }
    }
  }
  return bad;
}

void main() {
  stdout.writeln('分层架构门禁（STRUCTURE.md：L4 → L3 → L2 → L1，绝不反向）');
  stdout.writeln('=' * 62);

  // ---------------------------------------------------------------
  stdout.writeln('\n1. 每一层只依赖本层与更低层');
  for (final layer in kLayers) {
    final v = violationsIn(layer);
    check(
      '${layer.name}（${layer.dir}）无越界 import',
      v.isEmpty,
      v.isEmpty
          ? '${layer.dir} 下全部合规'
          : '${v.length} 处越界：\n        ${v.join('\n        ')}',
    );
  }

  // ---------------------------------------------------------------
  // 明确点名那条曾经违规的路径：它现在必须在 L3，且 L2 里不该有同名文件。
  stdout.writeln('\n2. OneBot 会话实现的位置（2026-09-22 复审的唯一违规项）');
  check(
    'onebot_session.dart 在 L3（client_api/）',
    File('lib/client_api/onebot_session.dart').existsSync(),
  );
  check(
    'onebot_session.dart 已不在 L2（kernel/onebot/）',
    !File('lib/kernel/onebot/onebot_session.dart').existsSync(),
  );
  check(
    'L2 的 onebot 目录只剩三个纯传输/归一化组件',
    () {
      final files = Directory('lib/kernel/onebot/')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.endsWith('.dart'))
          .toList()
        ..sort();
      return files.join(',') ==
          'backend_profile.dart,json_path.dart,onebot_client.dart';
    }(),
  );

  // ---------------------------------------------------------------
  // 依赖倒置的真正判据：低层不认识高层的数据类型名。
  // `onebot_session.dart` 当初之所以算违规，就是因为它 import 了
  // objects/segment/session 这三个只有 L3 才该出现的文件。
  stdout.writeln('\n3. L2 不认识 L3 的数据类型（依赖倒置的实际判据）');
  for (final name in <String>['objects.dart', 'segment.dart', 'session.dart']) {
    final hits = <String>[];
    final dir = Directory('lib/kernel/');
    for (final f in dir.listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      for (final t in importsOf(f.readAsStringSync())) {
        if (t.endsWith(name) && !t.contains('kernel/')) {
          hits.add('${f.path} → $t');
        }
      }
    }
    check('L2 里没有 import $name', hits.isEmpty, hits.join('; '));
  }

  // ---------------------------------------------------------------
  stdout.writeln('\n4. 底层不依赖 Flutter（可离线自测的前提）');
  for (final dir in <String>['lib/infra/', 'lib/kernel/', 'lib/client_api/']) {
    var hit = 0;
    for (final f in Directory(dir).listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.readAsStringSync().contains("import 'package:flutter")) hit++;
    }
    check('$dir 无 Flutter 依赖', hit == 0, hit == 0 ? '' : '$hit 个文件命中');
  }

  // ---------------------------------------------------------------
  stdout.writeln('\n5. import 解析器自检（避免门禁本身失效）');
  check(
    '相对路径归一化：lib/a/b.dart + ../c.dart → lib/c.dart',
    resolve('lib/a/b.dart', '../c.dart') == 'lib/c.dart',
    resolve('lib/a/b.dart', '../c.dart') ?? '(null)',
  );
  check(
    '相对路径越过 lib/ 时返回树外路径（门禁会跳过，不误报）',
    resolve('lib/a/b.dart', '../../x/y.dart') == 'x/y.dart' &&
        !resolve('lib/a/b.dart', '../../x/y.dart')!.startsWith('lib/'),
    resolve('lib/a/b.dart', '../../x/y.dart') ?? '(null)',
  );
  check(
    '相对路径归一化：lib/client_api/x.dart + ../kernel/y.dart → lib/kernel/y.dart',
    resolve('lib/client_api/x.dart', '../kernel/y.dart') == 'lib/kernel/y.dart',
    resolve('lib/client_api/x.dart', '../kernel/y.dart') ?? '(null)',
  );
  check(
    'package: 路径归一化：package:qqclient/x/y.dart → lib/x/y.dart',
    resolve('lib/a/b.dart', 'package:qqclient/x/y.dart') == 'lib/x/y.dart',
    resolve('lib/a/b.dart', 'package:qqclient/x/y.dart') ?? '(null)',
  );
  check(
    'dart: 与第三方包返回 null（不参与分层判定）',
    resolve('lib/a/b.dart', 'dart:async') == null &&
        resolve('lib/a/b.dart', 'package:flutter/material.dart') == null,
  );
  check(
    'importsOf 能抽出多行 import 与条件 import',
    importsOf(
      "import 'dart:io';\n"
      "import \"../x.dart\";\n"
      "import 'y.dart' as y;\n",
    ).length ==
        3,
    importsOf("import 'a.dart';\nimport 'b.dart';").join(','),
  );
  check(
    'importsOf 忽略注释掉的行',
    importsOf("// import 'gone.dart';\nimport 'real.dart';").join(',') ==
        'real.dart',
    importsOf("// import 'gone.dart';\nimport 'real.dart';").join(','),
  );

  // ---------------------------------------------------------------
  stdout.writeln('\n${'=' * 62}');
  if (failed == 0) {
    stdout.writeln('通过 $passed 项，失败 0 项');
    stdout.writeln('分层架构门禁通过 ✓');
    exit(0);
  } else {
    stdout.writeln('通过 $passed 项，失败 $failed 项');
    exit(1);
  }
}
