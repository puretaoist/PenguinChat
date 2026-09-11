/// L2 协议内核：后端适配表（数据驱动）
///
/// ## 解决什么问题
///
/// OneBot 11 是**规范**，不是**实现**。各家实现对同一份数据的字段命名并不统一。
/// 实测（来源：Stapxs `assets/pathMap/*.yaml`）：
///
/// | 逻辑字段 | NapCat.Onebot | Lagrange.OneBot |
/// |---|---|---|
/// | 文件大小 | `/size` | `/file_size` |
/// | 创建者 | `/creator_name` | `/create_name` |
/// | 个性签名 | `/longNick` | `/sign` |
/// | 个性号 | `/qid` | `/q_id` |
/// | QQ 等级 | `/qqLevel` | `/level` |
/// | 好友列表源 | `get_friends_with_category` | `get_friend_list` |
/// | 消息回应 | `set_msg_emoji_like` | `set_group_reaction` |
/// | 设置群名 | **无此 API** | `set_group_name` |
/// | 已读上报 | `mark_group_msg_as_read` | **无对应** |
///
/// 所以适配**必须是数据，不能是代码**：后端换版本 / 换实现 / 换协议时，
/// 只改 `assets/backends/*.json`，Dart 一行不动。
///
/// 这不是过度设计——Stapxs 的 `LLOneBot.yaml` 全文只有两行：
/// ```yaml
/// name: LLOneBot
/// redirect: NapCat.Onebot
/// ```
/// 如果按「一个后端一个类」来写，这一行等价物就是一次重复实现。
///
/// ## 路径根约定
///
/// 表中所有路径以 [OneBotClient.call] 的返回值（响应信封里的 `data`）为根，
/// 直接写 `$.user_id`，不写 `$.data.user_id`。参见 `json_path.dart` 的说明。
///
/// ## 未适配的后端怎么办
///
/// [BackendProfileRegistry.resolve] 返回 null 时，调用方应回落到
/// [BackendProfileRegistry.fallbackName] 指定的表，并把差异记入日志——
/// 而不是崩溃。这是刻意的：未知后端仍然可用，只是可能少几个字段。
library;

import 'dart:convert';

import 'json_path.dart';

/// 分页语义。各家后端的 `*_msg_history` 行为不同。
enum Pager {
  /// 一次返回全量（NapCat）。
  full,

  /// 增量返回。
  incremental,

  /// 不支持分页参数。
  none;

  static Pager parse(String? raw) => switch (raw) {
        'incremental' => Pager.incremental,
        'none' => Pager.none,
        _ => Pager.full,
      };
}

/// 一个逻辑 API 在某个后端上的映射声明。
class ApiSpec {
  /// 实际要调用的 OneBot action。
  ///
  /// 支持 `a|b` 备选写法：按顺序尝试，第一个成功的生效。用于同一份数据
  /// 在不同版本里换过 action 名的情况（如 `get_friend_list|get_group_list`）。
  final String action;

  /// 私聊场景下的替代 action（对应源表的 `private_name`）。
  final String? privateAction;

  /// 列表来源的 JSONPath。为空表示响应本身就是单条记录。
  final String? source;

  /// 分页语义。
  final Pager pager;

  /// 结果需要倒序（对应源表的 `reverse`）。
  final bool reverse;

  /// 逻辑字段名 → JSONPath。
  ///
  /// 值为 `null` 或空串表示**该后端不提供此字段**——保留键便于上层区分
  /// "后端没有"与"表里没写"。
  final Map<String, String?> map;

  const ApiSpec({
    required this.action,
    this.privateAction,
    this.source,
    this.pager = Pager.full,
    this.reverse = false,
    this.map = const {},
  });

  /// 从 JSON 表构造。字段缺失时抛 [FormatException]（表写错要立刻暴露）。
  factory ApiSpec.fromJson(String logicalName, Map<String, dynamic> json) {
    final action = json['action'];
    if (action is! String || action.isEmpty) {
      throw FormatException('后端适配表：API "$logicalName" 缺少 action 字段');
    }
    final rawMap = json['map'];
    final fields = <String, String?>{};
    if (rawMap is Map) {
      for (final e in rawMap.entries) {
        final v = e.value;
        if (v != null && v is! String) {
          throw FormatException('后端适配表：API "$logicalName" 的字段 "${e.key}" 路径必须是字符串或 null');
        }
        fields[e.key.toString()] = (v as String?)?.trim();
      }
    }
    return ApiSpec(
      action: action,
      privateAction: json['private_action'] as String?,
      source: json['source'] as String?,
      pager: Pager.parse(json['pager'] as String?),
      reverse: json['reverse'] as bool? ?? false,
      map: fields,
    );
  }

  /// 按场景解析出候选 action 列表（`a|b` 会拆开）。
  List<String> actions({bool isPrivate = false}) {
    final chosen = isPrivate ? (privateAction ?? action) : action;
    return chosen
        .split('|')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// 从响应 `data` 里取出记录列表。
  List<Object?> itemsFrom(Object? data) {
    if (source == null) return const [];
    final items = selectList(data, source);
    return reverse ? items.reversed.toList() : items;
  }

  /// 把一条原始记录按 [map] 转成逻辑字段表。
  ///
  /// 路径以 `item` 为根（表里写成 `/user_id` 的相对形式）。
  Map<String, dynamic> itemFrom(Object? item) {
    final out = <String, dynamic>{};
    for (final e in map.entries) {
      final path = e.value;
      out[e.key] = (path == null || path.isEmpty) ? null : selectOne(item, path);
    }
    return out;
  }

  /// 非列表型响应的字段提取（`source` 为空时用）。
  Map<String, dynamic> oneFrom(Object? data) => itemFrom(data);

  /// 诊断用。
  @override
  String toString() => 'ApiSpec($action, source=$source, fields=${map.length})';
}

/// 一个后端的完整适配表。
class BackendProfile {
  /// 规范化名称，例如 `NapCat.Onebot`。
  final String name;

  /// 指向另一个表（别名继承）。非 null 时本表只作为入口，实际用被指向的表。
  final String? redirect;

  /// 上报的 `app_name` 可能出现的其它写法（含历史名、衍生实现名）。
  final List<String> knownAs;

  /// 逻辑 API 名 → 映射声明。
  final Map<String, ApiSpec> apis;

  /// 消息段级别的字段别名：段类型 → {逻辑字段: JSONPath}。
  ///
  /// 对应源表的 `message_value`。各家对同一个段类型的字段名不一致，
  /// 例如图片 URL：NapCat 在 `$.file`，Lagrange 也在 `$.file`，
  /// 但 `get_record` 的返回结构差异更大。
  final Map<String, Map<String, String>> segmentValues;

  const BackendProfile({
    required this.name,
    this.redirect,
    this.knownAs = const [],
    this.apis = const {},
    this.segmentValues = const {},
  });

  /// 内置兜底表：**所有适配表资源都加载失败时的最后防线**。
  ///
  /// 没有任何字段映射，所以它不能替代真表——但它能保证客户端**起得来**：
  /// 连接、会话列表、收发消息这些不依赖字段映射的能力仍然可用，
  /// 只有字段归一化会退化成"直接用原始字段名"。
  ///
  /// 这比启动即崩要好：适配表读不到是打包/资源问题，
  /// 不该表现成用户点一下就闪退。
  static const BackendProfile builtinFallback = BackendProfile(
    name: 'Builtin.Fallback',
    knownAs: <String>['NapCat.Onebot', 'Lagrange.OneBot', 'LLOneBot'],
  );

  factory BackendProfile.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.isEmpty) {
      throw const FormatException('后端适配表：缺少 name 字段');
    }

    final apis = <String, ApiSpec>{};
    final rawApis = json['apis'];
    if (rawApis is Map) {
      for (final e in rawApis.entries) {
        final v = e.value;
        if (v is! Map) {
          throw FormatException('后端适配表：API "${e.key}" 必须是对象');
        }
        apis[e.key.toString()] = ApiSpec.fromJson(
          e.key.toString(),
          v.cast<String, dynamic>(),
        );
      }
    }

    final segmentValues = <String, Map<String, String>>{};
    final rawSeg = json['segment_values'];
    if (rawSeg is Map) {
      for (final e in rawSeg.entries) {
        final v = e.value;
        if (v is Map) {
          segmentValues[e.key.toString()] =
              v.map((k, val) => MapEntry(k.toString(), val.toString()));
        }
      }
    }

    return BackendProfile(
      name: name,
      redirect: json['redirect'] as String?,
      knownAs: (json['known_as'] as List?)?.whereType<String>().toList() ?? const [],
      apis: apis,
      segmentValues: segmentValues,
    );
  }

  /// 从 JSON 文本构造（供 asset 与测试共用）。
  static BackendProfile fromJsonString(String source) =>
      BackendProfile.fromJson((jsonDecode(source) as Map).cast<String, dynamic>());

  /// 查一个逻辑 API 的映射；表里没有则返回 null。
  ApiSpec? spec(String logicalName) => apis[logicalName];

  /// 是否只作为别名存在。
  bool get isAlias => redirect != null;

  /// 该表覆盖的逻辑 API 数量。
  int get apiCount => apis.length;

  @override
  String toString() => 'BackendProfile($name, apis=$apiCount, redirect=$redirect)';
}

/// 所有已知后端适配表的集合，按上报的 `app_name` 查找。
class BackendProfileRegistry {
  final Map<String, BackendProfile> _byName = {};

  /// 全部表里都没有匹配时使用的兜底表名。
  final String fallbackName;

  BackendProfileRegistry(Iterable<BackendProfile> profiles, {this.fallbackName = 'NapCat.Onebot'}) {
    for (final p in profiles) {
      _byName[p.name] = p;
      for (final alias in p.knownAs) {
        _byName.putIfAbsent(alias, () => p);
      }
    }
  }

  /// 从 JSON 文本列表构造（每个元素是一张表）。
  factory BackendProfileRegistry.fromJsonStrings(
    Iterable<String> sources, {
    String fallbackName = 'NapCat.Onebot',
  }) =>
      BackendProfileRegistry(
        sources.map(BackendProfile.fromJsonString),
        fallbackName: fallbackName,
      );

  /// 已注册的表名（不含别名）。
  List<String> get names =>
      _byName.values.map((p) => p.name).toSet().toList()..sort();

  /// 表中声明的逻辑 API 名（取并集，用于诊断"哪些能力各家都支持"）。
  Set<String> get allLogicalApis =>
      _byName.values.expand((p) => p.apis.keys).toSet();

  /// 按 `get_version_info` 上报的 `app_name` 查找表，跟随 [BackendProfile.redirect]。
  ///
  /// 找不到时返回 null——**调用方应回落到 [resolveOrDefault]**，
  /// 未知后端不应该让客户端不可用。
  BackendProfile? resolve(String? appName) {
    if (appName == null || appName.isEmpty) return null;
    var current = _byName[appName];
    if (current == null) {
      // 宽松匹配：大小写 / 常见后缀差异
      final lower = appName.toLowerCase();
      for (final e in _byName.entries) {
        if (e.key.toLowerCase() == lower) {
          current = e.value;
          break;
        }
      }
    }
    if (current == null) return null;
    return _followRedirects(current);
  }

  /// 同 [resolve]，但找不到时回落到 [fallbackName]。
  ///
  /// 如果连兜底表都不在（**注册表为空**，即适配表资源全部加载失败，
  /// 见 `main.dart` 的 `_loadBackendRegistry`），退到
  /// [BackendProfile.builtinFallback]。
  ///
  /// ⚠️ 原来是 `_byName[fallbackName]!`，在空注册表上会崩成
  /// `Null check operator used on a null value`——既不是给用户看的错误，
  /// 也没指出哪里坏了。而调用方的契约是"未知后端不应该让客户端不可用"。
  BackendProfile resolveOrDefault(String? appName) =>
      resolve(appName) ??
      _byName[fallbackName] ??
      BackendProfile.builtinFallback;

  BackendProfile? byName(String name) {
    final p = _byName[name];
    return p == null ? null : _followRedirects(p);
  }

  BackendProfile? _followRedirects(BackendProfile start) {
    var current = start;
    final seen = <String>{start.name};
    while (current.redirect != null) {
      final next = _byName[current.redirect!];
      if (next == null || !seen.add(next.name)) return current;
      current = next;
    }
    return current;
  }
}
