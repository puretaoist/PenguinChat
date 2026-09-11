# AGENTS.md — 项目交接说明

> 这份文件是**给接手本项目的 AI agent 读的第一份文档**。
> 读完它你应该能：明白项目在做什么、遵守哪些纪律、当前做到哪、下一步做什么。
>
> 细节文档见 [`docs/`](docs/) 目录，本文件末尾有索引。

---

## 0. 一句话

一个 **Flutter / Android 的 QQ 客户端**（Telegram 风格 UI），
用**可替换的协议内核**同时支撑两条线：

| 线 | 内核 | 定位 | 风险 |
|---|---|---|---|
| **日用线** | OneBot 11 + NapCat | 真能聊天 | 最低（跑官方客户端本体） |
| **研究线** | QQ 8.2.11 / 8.9.50 自实现协议 | 课程作业 / 协议学习 | 高（自实现协议） |

---

## 1. 硬性纪律（不要违反）

### 1.1 分层单向依赖

```
L4 ui/         表现层（Flutter）
L3 client_api/ 客户端 API 层（契约 + 数据对象）
L2 kernel/     协议内核（onebot / wlogin8 / crypto / transport）
L1 infra/      基础设施（字节读写、存储、日志）
```

**依赖方向只能是 L4 → L3 → L2 → L1，绝不反向。**

有两处看起来"反了"但其实是标准做法，**不要"顺手修正"**：

- `Session` 契约放在 **L3**（`lib/client_api/session.dart`），
  L2 的 `OneBotSession` 去 `implements` 它。这是**依赖倒置**——
  契约在高层、实现在低层。如果把契约挪到 L2，L2 就要依赖 L3 的对象类型，那才是反向。
- 底层**不得 import Flutter**。`lib/infra/` `lib/kernel/` `lib/client_api/`
  都是纯 Dart，这样才能在 `tool/*.dart` 里离线自测。
  需要平台能力时**注入**（传 `Directory`、传 `Socket`），不要 import。

### 1.2 每个模块配自测，且必须能被 CI 跑到

- 自测放 `tool/<模块>_selftest.dart`，**纯 Dart**，末尾用 `exit(failed == 0 ? 0 : 1)`
- CI 用通配遍历 `tool/*_selftest.dart`，**新增自测不需要改工作流**
- **不要用 `exitCode = ...`**：只要进程还持有 `ServerSocket` / `Timer` 之类句柄，
  事件循环不会结束，进程会一直挂着（本仓库踩过）

### 1.3 提交前必须过三道

```bash
dart analyze lib tool     # 必须 No issues found
dart run tool/<各>_selftest.dart   # 全过
```

推送后 CI 会再跑一遍全部自检 + dry-run + 打包。

### 1.4 测试里不要用固定 sleep 断言时序

**这是本仓库已经踩过并付出代价的坑。** 详见 [`docs/PITFALLS.md`](docs/PITFALLS.md)。

一句话：本机大概率不复现的竞态，在 CI 上近乎必然。
要等状态就用 `waitUntil(() => 条件)`（`tool/onebot_selftest.dart` 里有实现），
要等事件就先订阅收集、再等条件，**不要连用两次 `stream.first`**。

### 1.5 凭据绝不进日志

用 `lib/infra/log/logger.dart` 的 `Redact`：

```dart
log.i('登录 uin=${Redact.kv('uin', uin)}');        // 普通值
log.d('tgtgt ${Redact.fingerprint('tgtgt', b)}'); // 敏感值只输出长度+前4字节
```

`Redact.sensitiveKeys` 里列了 29 个凭据类键名，命中即打码。

### 1.6 不做规避风控的事

不做设备指纹伪造、不绕验证码、不伪装官方客户端。理由与替代做法见
[`SAFETY.md`](SAFETY.md)——**不是道德说教，是这些做法会让账号更快被标记。**

---

## 2. 目录地图

```
qqclient/
├── AGENTS.md                ← 本文件
├── README.md                项目说明（面向人类）
├── STRUCTURE.md             分层架构详解
├── SAFETY.md                账号风险与防护设计
├── STORAGE-DESIGN.md        存储设计（学 Telegram 不学 QQ）
├── CI-BUILD.md              云端构建说明（含本机构建踩过的坑）
├── LIVE-TEST.md             真机测试说明（两步走流程）
├── docs/                    交接文档（给 agent 读的）
│
├── lib/
│   ├── main.dart                       入口（当前极简，见 §4）
│   ├── infra/                          L1
│   │   ├── coder.dart                  ByteReader / ByteWriter
│   │   ├── log/logger.dart             日志门面（纯 Dart）
│   │   ├── log/log_file.dart           落盘 + 导出
│   │   └── storage/                    内容寻址存储（CAS）
│   ├── kernel/                         L2
│   │   ├── crypto/tea.dart             QQ 专用 TEA（分组链与标准 CBC 不同！）
│   │   ├── crypto/ecdh.dart            prime256v1 协商
│   │   ├── crypto/digest.dart          MD5 的各种用途
│   │   ├── onebot/                     日用线内核 ★
│   │   │   ├── onebot_client.dart      WS 客户端（echo↔Completer 关联）
│   │   │   ├── backend_profile.dart    后端适配表（数据驱动字段映射）
│   │   │   ├── json_path.dart          JSONPath 子集
│   │   │   └── onebot_session.dart     Session 实现 ★
│   │   ├── wlogin8/                    研究线内核（QQ 8.x）
│   │   │   ├── qq8_tlv.dart            48 个 TLV 打包（有 oicq 黄金向量）
│   │   │   ├── qq8_sso.dart            三层信封
│   │   │   ├── qq8_tran.dart           TCP 传输层
│   │   │   ├── qq8_login.dart          登录主流程
│   │   │   └── qq8_profiles.dart       四版本档案
│   │   ├── wlogin/                     旧版 TLV 研究（NT 线，未完成）
│   │   ├── safety/                     风险闸门 + 尝试限流
│   │   └── transport/ trpc/            MSF 长连接（骨架，未完成）
│   ├── client_api/                     L3
│   │   ├── session.dart                Session 契约 ★（内核接缝）
│   │   ├── objects.dart                Chat / ChatMessage / ChatMember
│   │   └── segment.dart                sealed Segment（13 种消息段）
│   └── ui/                             L4
│       ├── pages/home_page.dart        三栏主界面（**当前吃假数据**，见 §4）
│       ├── theme/telegram_theme.dart   配色与尺寸
│       └── widgets/                    头像 / 消息气泡
│
├── assets/backends/         后端适配表（napcat / lagrange / llonebot）
├── tool/                    全部离线自检（纯 Dart）
├── android/                 Android 工程
└── .github/workflows/build.yml   CI：自检 → dry-run → 打包 APK
```

---

## 3. 怎么跑

### 3.1 ⚠️ 本机 `dart` / `flutter` 包装脚本会卡住

本机的 `dart.bat` / `flutter.bat` 在 SDK bootstrap 阶段会挂起。
**直接用真正的 dart 可执行文件**：

```powershell
$dart = "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe"
& $dart run tool/qq8_tlv_selftest.dart
```

### 3.2 跑全部自测

```powershell
$dart = "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe"
Get-ChildItem tool -Filter "*_selftest.dart" | ForEach-Object { & $dart run $_.FullName }
& $dart run tool/tea_compat_check.dart
& $dart run tool/selftest.dart
```

当前规模：**13 个 `*_selftest.dart` + 2 个独立自检，合计 850+ 项**，全量约 27 秒。

### 3.3 构建

**不要在本地构建**（本机 JDK / Android SDK / NDK / 代理环境都有坑，
`CI-BUILD.md` 里有完整踩坑记录）。走 GitHub Actions：

- 推送到 `main` 就自动构建
- 或在 Actions 页面手动 `Run workflow`，可选 `debug` / `release`
- 打 `v*` tag 会把 APK 附到 Release
- 产物在 run 页面的 **Artifacts** 区域（下载需要登录 GitHub）

仓库：<https://github.com/puretaoist/PenguinChat>

---

## 4. 当前状态（**诚实的清单**）

### 4.1 已完成且经过验证

| 模块 | 验证方式 | 规模 |
|---|---|---|
| L1 字节读写 / 存储 / 日志 | 自测 | 48 + 51 项 |
| L2 安全层（闸门 + 限流） | 自测 | 77 项 |
| L2 OneBot 客户端 + 适配表 + 会话 | 自测（含本地 mock WS 服务器） | 47 + 72 + 93 项 |
| L3 数据对象 / 消息段 | 自测 | 92 项 |
| L2 QQ8 协议（TLV/SSO/传输/登录） | **oicq 黄金向量** + 官方反编译对照 + 本地 mock TCP | 275 项 |

QQ8 协议线的验证强度是分级的，**别高估**：
`TLV / 信封 / TEA / 分帧 / body 头格式` 都有黄金向量或官方代码出处；
**`响应解析` 只有往返测试**（拿不到真实响应样本），真机联通后才能校准。

### 4.2 骨架，尚未可用

| 模块 | 状态 |
|---|---|
| `lib/ui/` | 三栏布局能渲染，但**吃的是硬编码假数据** |
| `lib/main.dart` | 只 `runApp`，**没有任何依赖注入 / 状态管理接线** |
| `lib/kernel/transport/` `trpc/` `wlogin/` | 早期 MSF 研究骨架，未完成，**暂时别动** |

### 4.3 明确缺失

- **UI ↔ Session 之间没有接线**（这是最大的缺口，见 [`docs/NEXT-TASK.md`](docs/NEXT-TASK.md)）
- **没有 `chat_store`**：会话列表 / 消息持久化数据层不存在
- **没有连接配置页**：无法在 App 里填 `ws://127.0.0.1:3001`
- **`flutter_riverpod` 已在 `pubspec.yaml` 里，但整个 `lib/` 里一次都没用**

---

## 5. 下一步做什么

**当前任务是把 UI 接上协议内核**，详细规格见
[`docs/NEXT-TASK.md`](docs/NEXT-TASK.md)。摘要：

1. `lib/client_api/chat_store.dart` —— 会话列表 + 消息缓存的持久化数据层
2. `lib/client_api/session_providers.dart` —— Riverpod provider，把 `Session` 暴露给 UI
3. 连接配置页 —— 填 WebSocket 地址（默认 `ws://127.0.0.1:3001`）
4. 改 `home_page.dart` 与 `main.dart` —— 从 `ChatStore` 取数据而非硬编码

**验收标准**：装到手机上、连上本机的 NapCat、能收发真实 QQ 消息。
端到端路子见 `README.md` 的「运行模式与安全约束」。

### 5.1 建议的开工顺序

先读这些（按顺序）：

1. 本文件（你在读）
2. [`docs/STATUS.md`](docs/STATUS.md) —— 每个文件的实现程度
3. [`docs/PITFALLS.md`](docs/PITFALLS.md) —— 踩过的坑，**能省你几小时**
4. [`docs/NEXT-TASK.md`](docs/NEXT-TASK.md) —— 当前任务的完整规格
5. `lib/client_api/session.dart` —— 内核接缝的契约，写 UI 前必读
6. [`STRUCTURE.md`](STRUCTURE.md) —— 分层架构的完整理由

---

## 6. 工程约定

| 项 | 约定 |
|---|---|
| 注释语言 | **中文**。讲"为什么"而不是"做了什么"——代码本身说明做了什么 |
| 关键决策 | 写进文件头部的文档注释，附**出处**（官方反编译位置 / 参考实现文件名与行号） |
| 测试命名 | `tool/<模块>_selftest.dart`，输出「通过 N 项，失败 M 项」 |
| 提交信息 | 用 `feat:` / `fix:` / `docs:` / `chore:` 前缀，正文说清**为什么**和**验证方式** |
| 魔法数字 | 必须带注释说明来源。协议里的"看起来没用但删了就登不上"的字段尤其 |
| 不要顺手优化 | 协议实现里很多字段看着冗余（如 `qq8BufUnknown`），删了会静默失败 |

---

## 7. 文档索引

| 文件 | 内容 |
|---|---|
| [`docs/STATUS.md`](docs/STATUS.md) | 逐模块实现状态与测试规模 |
| [`docs/NEXT-TASK.md`](docs/NEXT-TASK.md) | 当前任务（UI 接线）的完整规格 |
| [`docs/PITFALLS.md`](docs/PITFALLS.md) | 已踩过的坑与规避方式 |
| [`STRUCTURE.md`](STRUCTURE.md) | 分层架构与依赖规则 |
| [`README.md`](README.md) | 项目总览、快速开始、运行模式 |
| [`SAFETY.md`](SAFETY.md) | 账号风险分析、三层防护设计 |
| [`STORAGE-DESIGN.md`](STORAGE-DESIGN.md) | 存储设计取舍 |
| [`CI-BUILD.md`](CI-BUILD.md) | 云端构建与本机构建的坑 |
| [`LIVE-TEST.md`](LIVE-TEST.md) | QQ8 线真机测试的两步流程 |
| [`M1-REPORT.md`](M1-REPORT.md) [`M2-REPORT.md`](M2-REPORT.md) | 历史阶段报告 |
| [`TOOLING.md`](TOOLING.md) | 逆向工具链 |
