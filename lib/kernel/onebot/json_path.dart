/// JSONPath 子集求值器
///
/// ## 为什么自己写
///
/// 用途只有一个：解析 `assets/backends/*.json` 里声明的字段路径。
/// 语法是固定的、由我们自己编写的表，不需要完整 JSONPath 规范
/// （过滤器、函数、脚本表达式都不需要）。自己实现可以让这一层
/// 零依赖、可离线自测，也避免 pub 依赖带来的网络构建问题。
///
/// ## 支持的语法
///
/// | 写法 | 含义 |
/// |---|---|
/// | `$` | 根节点 |
/// | `$.a.b` | 逐级取成员 |
/// | `$[*]` | 展开列表；对 Map 则展开其所有值 |
/// | `$.*` | 同上（对 Map） |
/// | `$[0]` | 取下标（不支持负数） |
/// | `$..a` | 递归下降查找所有名为 `a` 的成员 |
/// | `/a/b` | **相对路径**：以「当前节点」为根的 `$.a.b`，用于列表项内部的字段映射 |
/// | `null` / `""` | 显式表示「该后端不提供此字段」 |
///
/// ## 与参考实现的差异
///
/// Stapxs 的 `pathMap` 路径根在**完整响应信封**（`{status, retcode, data}`）上，
/// 因此到处是 `$.data.xxx`。本实现把根定义在 [OneBotClient.call] 的返回值
/// （即信封里的 `data`）上，表里直接写 `$.xxx`。少一层噪音，且与客户端的
/// 返回类型对齐。
///
/// Stapxs 还支持 `@regex` 后缀做二次提取，本实现暂不支持——我们自己的表
/// 不需要它，需要时应显式扩展而不是留一个隐式行为。
library;

/// 求值 [expr]，返回**所有**匹配的节点。
///
/// - [expr] 为 null、空串时返回空列表（表示「不适用」）。
/// - 路径语法错误抛 [FormatException]（表写错了应当立刻发现，而不是静默返回空）。
List<Object?> selectAll(Object? root, String? expr) {
  if (expr == null || expr.isEmpty) return const [];
  final segs = _parse(expr);
  final out = <Object?>[];
  _walk(root, segs, 0, out);
  return out;
}

/// 求值 [expr]，返回**首个**匹配；无匹配返回 null。
Object? selectOne(Object? root, String? expr) {
  final all = selectAll(root, expr);
  return all.isEmpty ? null : all.first;
}

/// 求值 [expr] 并保证结果是 `List`：
///   - 命中一个 List 节点 → 返回该 List
///   - 命中多个节点（`[*]` / `..`）→ 返回命中集合
///   - 无命中 → 空列表
List<Object?> selectList(Object? root, String? expr) {
  if (expr == null || expr.isEmpty) return const [];
  final segs = _parse(expr);
  final out = <Object?>[];
  _walk(root, segs, 0, out);
  // 单命中且本身是 List 时展开，其余情况直接返回命中集合
  if (out.length == 1 && out.first is List) return out.first as List;
  return out;
}

// ---------------------------------------------------------------------------
// 内部：解析
// ---------------------------------------------------------------------------

sealed class _Seg {
  const _Seg();
}

class _Key extends _Seg {
  final String name;
  const _Key(this.name);
}

class _Index extends _Seg {
  final int index;
  const _Index(this.index);
}

class _Wildcard extends _Seg {
  const _Wildcard();
}

class _Descend extends _Seg {
  final String name;
  const _Descend(this.name);
}

List<_Seg> _parse(String raw) {
  final segs = <_Seg>[];
  var i = 0;

  // 可选的前导 `$`（相对路径 `/a` 没有 `$`，由下面的裸名分支处理）
  if (i < raw.length && raw[i] == r'$') i++;

  while (i < raw.length) {
    final c = raw[i];

    if (c == '/') {
      // 相对路径分隔符：等价于 `.`，仅作可读性区分
      i++;
      continue;
    }

    if (c == '.') {
      if (i + 1 < raw.length && raw[i + 1] == '.') {
        // 递归下降 `..name`
        i += 2;
        final start = i;
        while (i < raw.length && raw[i] != '.' && raw[i] != '[' && raw[i] != '/') {
          i++;
        }
        final name = raw.substring(start, i);
        if (name.isEmpty) {
          throw FormatException('JSONPath 语法错误：`..` 后缺少字段名 → "$raw"');
        }
        segs.add(_Descend(name));
        continue;
      }
      i++;
      if (i < raw.length && raw[i] == '*') {
        i++;
        segs.add(const _Wildcard());
        continue;
      }
      final start = i;
      while (i < raw.length && raw[i] != '.' && raw[i] != '[' && raw[i] != '/') {
        i++;
      }
      final name = raw.substring(start, i);
      if (name.isEmpty) {
        throw FormatException('JSONPath 语法错误：`.` 后缺少字段名 → "$raw"');
      }
      // `$.a.0.b` 这种点号下标写法（源表在用）等价于 `$.a[0].b`
      final asIndex = int.tryParse(name);
      segs.add(asIndex != null ? _Index(asIndex) : _Key(name));
      continue;
    }

    if (c == '[') {
      final end = raw.indexOf(']', i);
      if (end < 0) {
        throw FormatException('JSONPath 语法错误：`[` 没有闭合 → "$raw"');
      }
      final body = raw.substring(i + 1, end).trim();
      i = end + 1;
      if (body == '*') {
        segs.add(const _Wildcard());
      } else {
        final n = int.tryParse(body);
        if (n == null || n < 0) {
          throw FormatException('JSONPath 语法错误：非法下标 "[$body]" → "$raw"');
        }
        segs.add(_Index(n));
      }
      continue;
    }

    // 裸字段名（相对路径开头，或省略 `$` 的写法）
    final start = i;
    while (i < raw.length && raw[i] != '.' && raw[i] != '[' && raw[i] != '/') {
      i++;
    }
    final name = raw.substring(start, i);
    if (name.isEmpty) {
      throw FormatException('JSONPath 语法错误：无法解析 "$raw"');
    }
    segs.add(_Key(name));
  }

  return segs;
}

// ---------------------------------------------------------------------------
// 内部：求值
// ---------------------------------------------------------------------------

void _walk(Object? node, List<_Seg> segs, int i, List<Object?> out) {
  if (i == segs.length) {
    out.add(node);
    return;
  }

  final seg = segs[i];

  switch (seg) {
    case _Key(:final name):
      // 只在键**确实存在**时命中。
      // 这让 `{"k": null}`（字段存在但为 null）与 `{}`（字段不存在）可区分——
      // 适配表依赖这个区分，否则"后端没提供"和"后端返回了 null"会混为一谈。
      if (node is Map && node.containsKey(name)) {
        _walk(node[name], segs, i + 1, out);
      }

    case _Index(:final index):
      if (node is List) {
        if (index < node.length) _walk(node[index], segs, i + 1, out);
      } else if (node is Map) {
        // 部分后端把对象键写成数字字符串（如 `{"0": {...}}`），
        // 点号下标 `$.a.0.b` 与方括号写法在这里都能正确落到对应键上。
        final key = index.toString();
        if (node.containsKey(key)) _walk(node[key], segs, i + 1, out);
      }

    case _Wildcard():
      if (node is List) {
        for (final e in node) {
          _walk(e, segs, i + 1, out);
        }
      } else if (node is Map) {
        for (final v in node.values) {
          _walk(v, segs, i + 1, out);
        }
      }

    case _Descend(:final name):
      // 本层命中 + 继续向下搜（都保持当前段下标，即"递归"语义）
      if (node is Map) {
        if (node.containsKey(name)) {
          _walk(node[name], segs, i + 1, out);
        }
        for (final v in node.values) {
          _walk(v, segs, i, out);
        }
      } else if (node is List) {
        for (final e in node) {
          _walk(e, segs, i, out);
        }
      }
  }
}
