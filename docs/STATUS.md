# 实现状态清单

> 逐文件说明"做到哪了"以及"凭什么认为它是对的"。
> 最后一个字段是**验证强度**，比完成度更重要——完成但没验证的东西不能当资产用。

---

## 验证强度分级

| 级别 | 含义 |
|---|---|
| **A** | 有**外部权威对照**：参考实现原始代码生成的黄金向量，或官方反编译代码逐行核对 |
| **B** | 有**真实等价物**测试：起真实的本地服务器 / 真实文件系统，走完整链路 |
| **C** | 只有**往返测试**：自己造输入、自己解，能抓不对称但抓不到"规格推断错了" |
| **D** | 只有**结构断言**：状态机、参数校验一类 |
| **E** | **无测试** |

---

## L1 基础设施

| 文件 | 行数 | 状态 | 自测 | 验证 |
|---|---|---|---|---|
| `infra/coder.dart` | 195 | 完成 | `selftest.dart` 部分 | A（大端往返 + 参考实现对照） |
| `infra/log/logger.dart` | 360 | 完成 | `log_selftest.dart` | D |
| `infra/log/log_file.dart` | 300+ | 完成 | 同上（51 项合计） | B（真实文件系统 + 轮转 + 体积闸门） |
| `infra/storage/blob_store.dart` | 193 | 完成 | `storage_selftest.dart` | B（真实文件） |
| `infra/storage/cache_policy.dart` | 154 | 完成 | 同上（48 项合计） | D |
| `infra/storage/storage_manager.dart` | 407 | 完成 | 同上 | B |

**存储层的设计取舍见 [`../STORAGE-DESIGN.md`](../STORAGE-DESIGN.md)。**
核心约束：内容寻址去重、总量硬预算 512MB、LRU 淘汰但收藏不淘汰、
**媒体字节绝不进消息库**。

---

## L2 协议内核

### crypto

| 文件 | 行数 | 状态 | 自测 | 验证 |
|---|---|---|---|---|
| `crypto/tea.dart` | 368 | 完成 | `tea_compat_check.dart` 15 项 | **A** |
| `crypto/ecdh.dart` | 183 | 完成 | `qq8_selftest.dart` 部分 | **A** |
| `crypto/digest.dart` | 35 | 完成 | 同上 | A |

⚠️ **`tea.dart` 的分组链不是标准 CBC**：
`B_i = P_i ⊕ C_{i-1}`，`C_i = E(B_i) ⊕ B_{i-1}`。
当初按标准 CBC 实现导致**任何 oicq 密文都解不开**，
报错是"尾部校验失败"，完全指不到根因。改动前先读文件头注释。

### onebot（日用线内核）★

| 文件 | 行数 | 状态 | 自测 | 验证 |
|---|---|---|---|---|
| `onebot/onebot_client.dart` | 747 | 完成 | `onebot_selftest.dart` | **B** |
| `onebot/backend_profile.dart` | 325 | 完成 | `backend_profile_selftest.dart` | A（对照 NapCat/Lagrange/LLOneBot 实际响应） |
| `onebot/json_path.dart` | 235 | 完成 | 同上（72 项合计） | A |
| `onebot/onebot_session.dart` | 571 | 完成 | `session_selftest.dart` 93 项 | **B** |

**这条线是能用的。** 自测里起了真实的本地 WebSocket 服务器，走完整的
「连接 → 握手 → 调 API → 收事件 → 断线重连」链路。

后端适配表在 `assets/backends/*.json`，**数据驱动**——加一个新后端实现
只需要加一个 JSON，不用改代码。

### wlogin8（研究线内核，QQ 8.x）

| 文件 | 行数 | 状态 | 自测 | 验证 |
|---|---|---|---|---|
| `wlogin8/qq8_tlv.dart` | 879 | 完成 | `qq8_tlv_selftest.dart` 58 项 | **A** |
| `wlogin8/qq8_sso.dart` | 277 | 完成 | `qq8_sso_selftest.dart` 20 项 | **A** |
| `wlogin8/qq8_tran.dart` | 332 | 完成 | `qq8_tran_selftest.dart` 34 项 | **B** |
| `wlogin8/qq8_login.dart` | 400+ | 完成 | `qq8_login_selftest.dart` 73 项 | **A** |
| `wlogin8/qq8_profiles.dart` | 287 | 完成 | `qq8_profile_selftest.dart` 90 项 | **A** |
| `wlogin8/qq8_device.dart` | 256 | 完成 | `qq8_selftest.dart` 30 项 | D |
| `wlogin8/qq8_config.dart` | 165 | 完成 | 同上 | A（参数全部反编译提取） |

**验证强度分级说明（重要，别高估）：**

- `qq8_tlv.dart` / `qq8_sso.dart`：**A**。黄金向量由参考实现 oicq 的
  `lib/wtlogin/tlv.js`、`wt.js` **原始模块**在 Node 里跑出来生成，
  不是手工抄的。
- `qq8_login.dart`：**A**。请求侧 + 响应侧都对着官方反编译核过：
  body 头格式对 `oicq_request.java:362`，TLV guard 逐条对 `k.java` / `j.java`；
  响应布局逐行对官方 9.3.60 `oicq_request.c()/d()`、`tlv_t.search_tlv`、
  `WtloginHelper.ShareKeyInit()`（2026-09-11 完成，对照表见该文件头注释）。
  真机只差最后一项：服务端是否接受我们的组包。
- `qq8_tran.dart`：**B**，自测起真实的本地 `ServerSocket`。

**这条线的天花板**（真机跑通也不会改变）：三个设备证明块
`0x544` / `0x553` / `0x545` 都只能发**官方降级形态**——
它们分别依赖 `libpoxy.so`、fekit、`libqimei.so`，纯 Dart 复现不了。
所以本实现在服务端眼里**必然**是 oicq / Lagrange 那一档的信任级别。

详见 [`../LIVE-TEST.md`](../LIVE-TEST.md)。

### safety

| 文件 | 行数 | 状态 | 自测 | 验证 |
|---|---|---|---|---|
| `safety/safety_gate.dart` | 349 | 完成 | `safety_selftest.dart` | D |
| `safety/attempt_limiter.dart` | 295 | 完成 | 同上（77 项合计） | D |
| `safety/environment_probe.dart` | 403 | 完成 | 同上 | D |

**UI 接线时别忘了走 `SafetyGate`**：默认离线，
连真实服务器需要逐条确认风险。设计理由见 [`../SAFETY.md`](../SAFETY.md)。

---

## L3 客户端 API

| 文件 | 行数 | 状态 | 自测 | 验证 |
|---|---|---|---|---|
| `client_api/session.dart` | 266 | 完成（契约） | `session_selftest.dart` 部分 | D |
| `client_api/objects.dart` | 404 | 完成（含 `MessageSendState`） | 同上 | D |
| `client_api/segment.dart` | 683 | 完成 | `segment_selftest.dart` 92 项 | A（13 种消息段，CQ 码与数组格式互转） |
| `client_api/chat_store.dart` | 813 | 完成 | `chat_store_selftest.dart` 102 项 | **B**（真实文件系统 + 假 Session 编排全部边界） |
| `client_api/session_providers.dart` | 452 | 完成 | `session_providers_selftest.dart` 42 项 | D（闸门拒绝路径 + 配置落盘） |

`chat_store.dart` 是 UI 与协议之间的数据层：乐观插入、echo 合并、撤回打补丁
（不从列表删）、按 id 去重、体积淘汰（只淘汰已送达的，发送中/失败的不淘汰）。
持久化是「会话索引 JSON + 每会话一个 JSONL」，**媒体字节绝不进消息库**。

`session_providers.dart` 用 `package:riverpod`（纯 Dart）而不是
`flutter_riverpod`——`AGENTS.md` §1.1 禁止 L3 引入 Flutter，而两者是同一套
provider 对象，L4 的 `ProviderScope` 直接消费。**连接必须过 `SafetyGate`**
（`_passGate`）：本机地址判为 loopback 直接放行，非本机地址要求已开启
真实服务器模式且有当前版本的知情同意。

---

## L4 表现层

| 文件 | 行数 | 状态 |
|---|---|---|
| `ui/theme/telegram_theme.dart` | 60 | 完成 |
| `ui/widgets/telegram_avatar.dart` | 48 | 完成 |
| `ui/widgets/message_bubble.dart` | 139 | 完成（含 sending / failed+重试 / 已撤回三态） |
| `ui/pages/home_page.dart` | 644 | 完成（数据来自 provider，含下拉刷新 / 翻页 / 重试） |
| `ui/pages/connect_page.dart` | 662 | 完成（地址 + 状态 + 风险确认 + 立即切断） |
| `main.dart` | 135 | 完成（ProviderScope 注入目录 / 适配表 / 闸门 + 日志落盘） |

`ui/` **没有自测**——它需要 `flutter_tester`，纯 Dart 自测跑不了。
本环境的 `flutter.bat` 也会卡在 SDK 引导检查，**UI 至今没有跑起来看过**，
正确性靠真机验证（清单见 `NEXT-TASK.md` §7）。

`main.dart` 只做三件「必须早于 UI」的事：定位应用私有目录
（`path_provider`）、把平台能力注入 provider、加载 `assets/backends/*.json`。
业务一行都不在这里。

---

## 未完成 / 暂时别动

| 目录 | 说明 |
|---|---|
| `kernel/transport/` | 早期 MSF 长连接骨架，218 行，未完成 |
| `kernel/trpc/` | 早期 SSO 命令字骨架，未完成 |
| `kernel/wlogin/` | 早期 NT 线 TLV 研究，165+166+209 行，**已被 `wlogin8/` 取代** |

这三个是探索期留下的，**当前两条主线都不依赖它们**。
除非明确要研究 MSF/trpc，否则不要在里面继续投入。

---

## 测试总览

| 自测文件 | 项数 | 覆盖 |
|---|---|---|
| `selftest.dart` | 57 | L1 字节读写 + 内核基础 |
| `storage_selftest.dart` | 48 | CAS 去重 / 预算淘汰 / 收藏保护 |
| `log_selftest.dart` | 51 | 格式 / 脱敏 / 体积闸门 / 导出 |
| `safety_selftest.dart` | 77 | 闸门 / 限流 / 环境探针 |
| `onebot_selftest.dart` | 49 | WS 客户端（真实 mock 服务器） |
| `backend_profile_selftest.dart` | 72 | 适配表 / JSONPath |
| `session_selftest.dart` | 93 | 会话生命周期 + 事件分发 |
| `segment_selftest.dart` | 92 | 消息段编解码 |
| `tea_compat_check.dart` | 15 | TEA 编解码兼容性 |
| `qq8_selftest.dart` | 30 | 设备 / ECDH / 摘要 |
| `qq8_tlv_selftest.dart` | 58 | 48 个 TLV（含黄金向量） |
| `qq8_sso_selftest.dart` | 20 | 三层信封（含黄金向量） |
| `qq8_tran_selftest.dart` | 34 | 分帧与传输（真实 socket） |
| `qq8_login_selftest.dart` | 73 | 登录组包 + 响应解析 |
| `qq8_profile_selftest.dart` | 90 | 四版本档案差异 |
| `chat_store_selftest.dart` | 102 | 乐观插入 / echo 合并 / 去重 / 撤回 / 淘汰 / 损坏文件 |
| `session_providers_selftest.dart` | 42 | 地址分类 / 闸门拒绝 / 连接配置落盘 |
| **合计** | **1003** | 全量约 30 秒 |

另有 `tool/qq8_live_smoke.dart`（真机冒烟，默认 dry-run，不参与
`*_selftest` 通配，CI 里单独跑一步）。
