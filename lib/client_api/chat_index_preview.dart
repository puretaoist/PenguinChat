/// L3 客户端 API 层：**冷启动首帧用的会话索引预览**（纯 Dart，不 import Flutter）。
///
/// ## 它解决什么问题
///
/// 会话列表真正的数据源是 [ChatStore]，而 [ChatStore] 必须挂在一个已登录的
/// Session 上（它订阅 SessionEvent）。于是"还没登录"这段时间里 UI 手里没有
/// 任何会话 —— 冷启动只能先放一张品牌页挡着，等协议线把账号恢复完再切。
/// 真机实测那段是 0.8–1.3s（debug），用户看到的是"点了图标先黑一下、再一张
/// 启动页、再淡入列表"，感官上就是**慢**。
///
/// 官方两个客户端都不这么干：Telegram 的 LaunchActivity 直接
/// `addFragmentToStack(new MainTabsActivity())`，列表从本地 SQLite 立刻出，
/// 网络在后台追；QQ 8.2.11 的闪屏只盖住真实工作（`axko.c()` 叫
/// realCreateActivity，工作一完立刻放行）。
///
/// 我们的数据其实也早就在磁盘上了：`<dataDir>/accounts/<uin>/chats.json`
/// 就是 ChatStore 的索引快照（id/标题/头像/最后一条/时间/未读数都在里面）。
/// 所以启动时**先把它读出来画一遍**，登录完成后再让 ChatStore 接管 ——
/// 用户看到的第一帧就是他自己的会话列表，没有品牌页、没有淡入。
///
/// ## 边界（刻意保守）
///
/// * 只读、不写、不创建目录；解析失败一律当作"没有预览"返回 null（宁可回退
///   到品牌页，也不能因为一段坏 JSON 让应用起不来）。
/// * 只有一份索引就是"最后用过那个号"的：多个账号目录时取 `chats.json`
///   修改时间最新的那个。账号切换后重新启动，预览自然跟着换。
/// * 预览里的会话**不可交互**（没有 store 就没有 openChat/send/长按菜单），
///   宿主必须自己挡掉回调；这里只负责"画出来"。
library;

import 'dart:convert';
import 'dart:io';

import '../infra/log/logger.dart';
import 'account_scope.dart';
import 'chat_store.dart' show chatFromIndexJson, compareChatsForList;
import 'objects.dart';

/// 一次冷启动的会话索引预览。
class ChatIndexPreview {
  const ChatIndexPreview({required this.uin, required this.chats});

  /// 这份索引属于哪个账号（目录名就是十进制 uin）。
  final int uin;

  /// 已按会话列表规则排好序（置顶 → 优先级 → 最后消息时间）。
  final List<Chat> chats;

  @override
  String toString() => 'ChatIndexPreview(uin: $uin, chats: ${chats.length})';
}

/// 读"最后用过那个账号"的会话索引。没有可读索引就返回 null。
///
/// 全程同步 IO（一个 listSync + 一次 readAsStringSync），索引是几十 KB 级，
/// 放在 runApp 之前不会拖慢首帧；反而省掉一次品牌页等待。
Future<ChatIndexPreview?> loadChatIndexPreview(Directory dataDir) async {
  final log = Log.get('会话预览');
  try {
    final accountsRoot = AccountScope.accountsRoot(dataDir);
    if (!accountsRoot.existsSync()) return null;

    Directory? best;
    DateTime? bestAt;
    for (final entry in accountsRoot.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final index = File('${entry.path}${Platform.pathSeparator}chats.json');
      if (!index.existsSync()) continue;
      final at = index.lastModifiedSync();
      if (bestAt == null || at.isAfter(bestAt)) {
        bestAt = at;
        best = entry;
      }
    }
    if (best == null) return null;

    final uin = int.tryParse(best.path.split(Platform.pathSeparator).last);
    final index = File('${best.path}${Platform.pathSeparator}chats.json');
    final decoded = jsonDecode(index.readAsStringSync());
    final list = decoded is List
        ? decoded
        : (decoded is Map ? decoded['chats'] : null);
    if (list is! List) {
      log.w('会话索引格式不认识，跳过预览');
      return null;
    }
    final chats = <Chat>[];
    for (final entry in list) {
      if (entry is! Map) continue;
      final chat = chatFromIndexJson(entry.cast<String, dynamic>());
      if (chat != null) chats.add(chat);
    }
    if (chats.isEmpty) return null;
    chats.sort(compareChatsForList);
    return ChatIndexPreview(
      uin: uin ?? 0,
      chats: List<Chat>.unmodifiable(chats),
    );
  } catch (e) {
    // 坏索引/权限问题都不该拦启动：没有预览就退回"品牌页 + 等登录"。
    log.w('读取会话索引预览失败，本次冷启动不预渲染列表', error: e);
    return null;
  }
}
