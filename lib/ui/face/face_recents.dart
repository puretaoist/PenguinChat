/// 最近使用的表情（落盘 `face_recents.json`）。
///
/// ## 为什么单独一份文件
///
/// 不塞进 `ui_prefs.json`：那份文件的字段被 `test/ui_test.dart` 逐字断言
/// （坏文件回默认值），加新字段会让那条契约变模糊。这里只是一个计数表，
/// 读坏了就当空，不影响任何别的偏好。
///
/// ## 排序规则对齐 TG（2026-11-08 修正）
///
/// 旧实现是「按时间，最新在前」。TG 不是这样：
/// * `messenger/Emoji.java:84` `MAX_RECENT_EMOJI_COUNT = 48`（**不是 16**）；
/// * `Emoji.java:911-934` `sortEmoji()` 按 **`emojiUseHistory` 的使用次数降序**
///   排，次数相同才保持原序；
/// * `Emoji.java:893-905` `addRecentEmoji()` 只做计数 +1，满了就替换掉
///   列表最后一条（次数最少的那个）。
///
/// 所以这里存 `id → 使用次数`，展示时按次数降序取前 [limit] 条。
/// 落盘格式 `{"counts": {"12": 3, "109": 1}}`；旧格式 `{"ids": [...]}`
/// 仍然认（迁移成次数 1，并按原顺序保留），不会丢用户的记录。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../infra/log/logger.dart';

class FaceRecents {
  FaceRecents(this._file);

  /// 最多记多少个。`Emoji.java:84` `MAX_RECENT_EMOJI_COUNT = 48`。
  static const int limit = 48;

  final File? _file;

  /// id → 使用次数。
  final Map<String, int> _counts = <String, int>{};

  /// 最近用过的表情 id，**按使用次数降序**（次数相同保持插入顺序）。
  ///
  /// 这就是 TG 的 `Emoji.recentEmoji` 语义——不是「最近」，是「最常用」。
  List<String> get ids {
    final entries = _counts.entries.toList(growable: false);
    // 稳定排序：Dart 的 List.sort 不保证稳定，所以用「次数降序 + 原索引升序」
    // 显式兜住——否则同次数的条目每次刷新都会换位置。
    final indexed = <({String id, int count, int order})>[
      for (int i = 0; i < entries.length; i++)
        (id: entries[i].key, count: entries[i].value, order: i),
    ];
    indexed.sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      return a.order.compareTo(b.order);
    });
    return <String>[
      for (final e in indexed.take(limit)) e.id,
    ];
  }

  Future<void> load() async {
    final file = _file;
    if (file == null) return;
    try {
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      // 新格式：{"counts": {...}}
      final counts = decoded['counts'];
      if (counts is Map) {
        for (final e in counts.entries) {
          final k = e.key;
          final v = e.value;
          if (k is String && k.isNotEmpty && v is num) {
            _counts[k] = v.toInt().clamp(1, 1 << 20);
          }
        }
        return;
      }
      // 旧格式：{"ids": [...]} → 迁移成次数 1（保持原顺序即原优先级）。
      final ids = decoded['ids'];
      if (ids is List) {
        for (final id in ids) {
          if (id is String && id.isNotEmpty) _counts[id] = 1;
        }
      }
    } catch (e) {
      Log.get('FaceRecents').w('最近表情读取失败，按空处理: $e');
    }
  }

  /// 记一次使用：次数 +1，并异步落盘。
  ///
  /// ## 满了怎么办（照 TG `Emoji.java:893-905`）
  ///
  /// TG 的做法是：**新条目进来时替换掉「列表最后一条」**（次数最少的那个），
  /// 而不是「加进去之后再统一裁剪」——后者会让刚用过的条目一进来就被踢掉
  /// （因为它的次数还是 1，排在所有老条目后面）。
  ///
  /// ```java
  /// if (count == 0 && emojiUseHistory.size() >= MAX_RECENT_EMOJI_COUNT) {
  ///     String emoji = recentEmoji.get(recentEmoji.size() - 1);  // 最后一条
  ///     emojiUseHistory.remove(emoji);
  ///     recentEmoji.set(recentEmoji.size() - 1, code);           // 替换
  /// }
  /// emojiUseHistory.put(code, ++count);
  /// ```
  void touch(String id) {
    if (id.isEmpty) return;
    final isNew = !_counts.containsKey(id);
    // 满了 + 这是个新条目 → 先腾位：踢掉次数最低的那一条。
    if (isNew && _counts.length >= limit) {
      final victims = ids; // 已按次数降序，最后一条就是最该走的
      if (victims.isNotEmpty) _counts.remove(victims.last);
    }
    _counts[id] = (_counts[id] ?? 0) + 1;
    unawaited(_save());
  }

  /// 串行化的落盘队列。
  ///
  /// 为什么需要：`touch` 是同步 + `unawaited(_save())`，连点几个表情就会
  /// 并发写同一个文件。`File.writeAsString` 并发时后写的会截断先写的，
  /// 结果是**丢失计数**（自测里 3 次 touch 只落 1 条就是这个问题）。
  /// 这里用一条 Future 链把写串起来，最后一次的内容一定包含全部计数。
  Future<void> _writeQueue = Future<void>.value();

  Future<void> _save() {
    final file = _file;
    if (file == null) return Future<void>.value();
    // 快照在入队那一刻取，保证每次写的是「轮到它时」的完整状态。
    _writeQueue = _writeQueue.then((_) async {
      try {
        await file.writeAsString(
          jsonEncode(<String, Object?>{'counts': _counts}),
          flush: true,
        );
      } catch (e) {
        Log.get('FaceRecents').w('最近表情写入失败: $e');
      }
    });
    return _writeQueue;
  }
}
