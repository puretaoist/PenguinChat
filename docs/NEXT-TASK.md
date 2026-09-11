# 当前任务：把 UI 接上协议内核

> **这是本项目最大的缺口。** 协议内核（L2）和 UI（L4）各自都能跑，
> 但中间没有接线——`home_page.dart` 现在渲染的是硬编码假数据。
>
> 做完这个任务，App 就能第一次真正收发 QQ 消息。

---

## 0. 现状证据

```dart
// lib/ui/pages/home_page.dart —— 现在长这样（节选）
class _HomePageState extends State<HomePage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

  static final _now = DateTime(2026, 9, 10, 18, 20);
  final List<Chat> _chats = [          // ← 硬编码
    Chat(...), Chat(...), Chat(...),
  ];
  final List<ChatMessage> _messages = [ // ← 硬编码
    ChatMessage(...), ChatMessage(...),
  ];
```

它的 import 只有：

```dart
import 'package:flutter/material.dart';
import '../../client_api/objects.dart';   // 只用数据对象
import '../theme/telegram_theme.dart';
import '../widgets/message_bubble.dart';
import '../widgets/telegram_avatar.dart';
```

**没有 import `session.dart`，也没有任何 Session 实现。**

```dart
// lib/main.dart —— 现在长这样
void main() {
  runApp(const QQClientApp());        // ← 没有任何 DI / 状态管理
}
```

`flutter_riverpod` 已经在 `pubspec.yaml` 里，但 `lib/` 下**一次都没用过**。

---

## 1. 交付物

四个文件（新建 3 个、改 2 个）：

```
lib/client_api/chat_store.dart          ← 新建：数据层
lib/client_api/session_providers.dart   ← 新建：Riverpod 接线
lib/ui/pages/connect_page.dart          ← 新建：连接配置
lib/ui/pages/home_page.dart             ← 改：从 store 取数
lib/main.dart                           ← 改：ProviderScope + SafetyGate 初始化
```

外加自测：`tool/chat_store_selftest.dart`

---

## 2. `lib/client_api/chat_store.dart`

### 2.1 职责

**这一层只做三件事**，不要让它膨胀：

1. 持有会话列表（`List<Chat>`）与每个会话的消息（`List<ChatMessage>`）
2. 订阅 `Session.events`，把事件合并进本地状态
3. 持久化（会话索引 + 消息），启动时恢复

**它不做的事**：不发网络请求（那是 `Session` 的活）、不碰 Widget（那是 UI 的活）。

### 2.2 为什么放在 L3

因为它的类型全部来自 L3（`Chat` / `ChatMessage` / `Session`）。
放 L2 会让 L2 依赖 L3 的对象，违反单向依赖。放 L4 又会被 UI 细节污染、无法离线自测。

### 2.3 接口草稿

```dart
/// 会话与消息的本地状态 + 持久化。
class ChatStore {
  ChatStore({
    required Session session,
    required Directory dataDir,       // ← 注入，便于离线自测
    Logger? logger,
  });

  /// 会话列表，按 [Chat.priority] 与最后消息时间排序。
  List<Chat> get chats;

  /// 某个会话的消息，时间正序（旧→新）。
  List<ChatMessage> messagesOf(String chatId);

  /// 状态变化通知（UI 用 listenable 或配合 Riverpod 的 StreamProvider）。
  Stream<ChatStoreEvent> get changes;

  /// 启动：拉会话列表 + 从磁盘恢复。
  Future<void> bootstrap();

  /// 打开一个会话：若本地没有则拉历史。
  Future<void> openChat(String chatId);

  /// 往前翻页。
  Future<void> loadMore(String chatId);

  /// 发送：乐观插入（outgoing=true, id=`local:<seq>`），
  /// 服务端回 id 后替换，失败则标记发送失败并保留文本。
  Future<void> send(String chatId, List<Segment> segments);

  /// 释放资源。
  Future<void> dispose();
}
```

### 2.4 必须处理的边界

| 情况 | 要求 |
|---|---|
| **乐观插入** | 发出即显示，不要等服务端回包才渲染（Telegram 就是这么做的） |
| **发送失败** | 消息保留并标记失败态，**不要静默丢弃**用户输入 |
| **多端同步** | `SessionMessage.isEcho == true`（自己在别处发的）要能正确合并，不能重复插入 |
| **撤回** | 用 `ChatMessage.deleted` / `recallInfo` 标记，**不要从列表里删掉** |
| **重复消息** | 按 `messageId` 去重；本地临时 id 与服务端 id 的替换要处理 |
| **媒体字节** | **绝不写进消息库**。图片/语音只存引用，字节交给 `infra/storage/`。见 `STORAGE-DESIGN.md` |

### 2.5 持久化方案（建议）

- **会话索引**：`shared_preferences`（已经是依赖），存 JSON 数组
- **消息**：每个会话一个文件 `<dataDir>/chats/<chatId>.jsonl`，追加写
- **体积**：默认保留最近 N 条（建议 500/会话），更早的靠 `session.fetchHistory` 翻页拉

理由：JSONL 追加写不需要读全量文件就能 append，比"整个 JSON 重写"更适合消息这种
只增不改的场景。

---

## 3. `lib/client_api/session_providers.dart`

用 `flutter_riverpod`（**不要**再引新的状态管理库）。

```dart
/// 当前连接配置（WebSocket 地址等）。
final connectionConfigProvider =
    StateNotifierProvider<ConnectionConfigNotifier, OneBotConfig>(...);

/// Session 实例。连接成功后才非 null。
final sessionProvider = Provider<Session?>((ref) => ...);

/// ChatStore 实例。
final chatStoreProvider = Provider<ChatStore?>((ref) => ...);

/// 会话列表（UI 直接 watch 这个）。
final chatsProvider = StreamProvider<List<Chat>>((ref) => ...);

/// 某个会话的消息。
final messagesProvider = StreamProvider.family<List<ChatMessage>, String>(
    (ref, chatId) => ...);
```

**注意**：`Session` 是有生命周期的（connect / close / dispose），
provider 的 `ref.onDispose` 里要正确释放，否则热重载会漏连接。

---

## 4. `lib/ui/pages/connect_page.dart`

最简单的可用版本：

- 一个输入框：WebSocket 地址，**默认 `ws://127.0.0.1:3001`**
- 一个「连接」按钮
- 连接状态显示（`SessionState` 直接映射）
- 连接成功后显示 `AccountInfo`（uin / 昵称 / `backendName` / 版本）
- **失败时把错误原文显示出来**，不要只显示"连接失败"——
  OneBot 的排障全靠这句原文

### 4.1 必须遵守的安全约束

`lib/kernel/safety/safety_gate.dart` 已经实现了三层模式：

| 模式 | 行为 |
|---|---|
| `offline` | 不联网（默认） |
| `loopback` | 内存回环 |
| `realServer` | 连真实服务器，**需要逐条确认风险** |

**连接页面必须走 `SafetyGate`**，不要自己判断。
`SafetyGate.enableRealServer(acknowledged, environment:)` 会：
先要 `EnvironmentProbe` 的探测报告 → 风险等级过高直接拒绝 →
再要求逐条确认（关键词匹配，防止随手点过）。

理由见 [`../SAFETY.md`](../SAFETY.md)，**这不是仪式，是避免无心之失**。

---

## 5. 改 `home_page.dart`

把 `_chats` / `_messages` 两个硬编码列表换成 `watch` provider，
`setState` 换成 provider 更新。

**UI 外观不要动**——三栏布局、主题、气泡都已经调好了，
这个任务只换数据源。

需要新增的交互：

- 下拉刷新会话列表
- 进入会话时调 `openChat`（首次会拉历史）
- 列表滚到顶部时调 `loadMore`
- 发送失败的消息显示重试入口
- 撤回的消息显示"已撤回"而不是消失

---

## 6. `tool/chat_store_selftest.dart`（必须写）

延续本仓库的做法：**纯 Dart、可离线跑、注入假的 `Session`**。

参考 `tool/session_selftest.dart` 的写法（它已经有一个完整的假 Session）。

至少要覆盖：

| 用例 | 断言 |
|---|---|
| 启动恢复 | 写入后重建 store，会话与消息能读回来 |
| 事件合并 | 对方消息、自己消息（`isEcho`）、撤回事件都正确进状态 |
| 去重 | 同 `messageId` 的重复事件只留一条 |
| 乐观插入 | `send` 立即出现在列表里，服务端回 id 后原地替换 |
| 发送失败 | 失败后消息**仍在**，且带失败标记 |
| 翻页 | `loadMore` 把更早的消息插到列表头部，顺序正确 |
| 持久化边界 | 消息文件损坏 / 半截 JSON 行不会导致启动崩溃 |
| 体积 | 超过保留上限时淘汰最旧的（收藏的除外） |

**不要用固定 `sleep` 断言时序**——见 [`PITFALLS.md`](PITFALLS.md)，
本仓库已经因此挂过一次 CI。

---

## 7. 验收标准

**工程上（已达成，2026-09-11）：**

1. ✅ `dart analyze lib tool` 干净
2. ✅ `tool/chat_store_selftest.dart` 通过（102 项），且被 CI 通配收录
   （CI 用 `tool/*_selftest.dart` 通配，无需改 workflow）
3. ✅ 全部自测通过：17 个脚本全绿（合计 1003 项，含新增的 102 + 42）
4. ⏳ 推送后 CI 绿 —— **未推送**：推送会触发 CI 构建，需先确认

**功能上（未做，需真机）：**

本环境跑不了 Flutter（`flutter.bat` 卡在 SDK 引导检查），
**UI 至今没有真正跑起来看过**，只做到「analyze 干净 + 逻辑层自测通过」。
以下 7 条一条都没验：

1. 手机上装好 App
2. 在另一台设备/电脑上跑 NapCat（见 `README.md` 的运行模式章节）
3. App 里填 `ws://<napcat 地址>:3001` 连上
4. 能看到真实的好友与群列表
5. 能收发真实 QQ 消息，发出的消息有送达标记
6. 杀掉 App 重开，会话和消息还在
7. 撤回一条消息，App 里显示"已撤回"而不是消失

补充两条本次新增的交互，也一并要验：

8. 发一条消息时把 NapCat 停掉 → 气泡显示「发送失败，点此重试」，
   点它能把消息补发出去（**文本不能丢**）
9. 连接页填非本机地址 → 不出门就要求环境检测 + 逐条确认；
   「立即切断」能把模式打回离线

---

## 8. 建议的开工顺序（实际执行记录）

```
1. ✅ 先写 tool/chat_store_selftest.dart（测试先行，102 项）
2. ✅ 实现 chat_store.dart（813 行）
3. ✅ 写 session_providers.dart（用 package:riverpod 而非 flutter_riverpod，
      理由见该文件头：L3 禁止引入 Flutter）
4. ✅ 写 connect_page.dart（含 SafetyGate 接线 + 环境检测 + 逐条确认 + 立即切断）
5. ✅ 改 main.dart（ProviderScope 注入 目录 / 适配表 / 闸门 + 日志落盘）
6. ✅ 改 home_page.dart（换数据源 + 下拉刷新 / 翻页 / 重试 / 已撤回）
7. ✅ 本地 analyze + 全量自测（17 个脚本全绿）
8. ⏳ 推送到 main，看 CI 出 APK（待确认）
9. ⏳ 真机验证第 7 节的 9 条
10. ✅ 补 `tool/session_providers_selftest.dart`（42 项）——
       闸门拒绝路径是本次改动里最要紧的一行，不能只靠人眼
```

**顺带修的两个问题（不在原计划里）：**

- `onebot_client.dart` 建连日志把 `?access_token=...` 原样打了出来
  （`tokenInHeader=false` 时令牌就在 query 里）。已加 `_redacted()`
  把令牌替换成 `***`，见 `AGENTS.md` §1.5。
- `session_providers.dart` 引入 `path_provider`：Android 上没有纯 Dart
  拿应用私有目录的办法（`Directory.systemTemp` 会被系统清理，
  用户数据丢了就是丢消息）。

---

## 9. 这条路走完之后的下一步（先别做）

接上 QQ8 研究线。QQ8 内核（`lib/kernel/wlogin8/`）已经写完并验证到当前能做到的极限，
差的是真机登录验证——流程见 [`../LIVE-TEST.md`](../LIVE-TEST.md)。

**但先别碰它**：那条线风险高（自实现协议登录真实账号），
而且做完日用线你才会真正理解 `Session` 契约该长什么样，
回头设计 `Qq8Session` 会顺得多。
