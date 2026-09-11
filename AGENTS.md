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

### 1.7 协议代码：先对包，再写码（研究线铁律）

**写任何 QQ 协议代码之前，先在四个包上核对，并与参考实现 oicq 对照。**

四个包（都在 `C:\Users\Administrator\penguis\`）：

| 包 | 版本 |
|---|---|
| `QQ-com.tencent.mobileqq-play-8.2.11.apk` | 8.2.11 |
| `8.9.50.apk` | 8.9.50 |
| `9.3.60_23e3f34e30110797.apk` | 9.3.60 |
| `tim_4.1.0.4050.apk` | TIM 4.1.0 |

工具与已解出的产物（见 [`TOOLING.md`](TOOLING.md)）：

| 用途 | 位置 |
|---|---|
| jadx / apktool / Ghidra | `~/WorkBuddy/<会话目录>/penguis-analysis/tools/` |
| apktool 解包结果（dex + 资源） | 同上 `decoded/` |
| jadx 抽出的 wlogin 类 | 同上 `m2-out/`（`WtloginHelper.java` / `tlv_t.java` / `util.java` …） |
| TLV 字段总表 | 同上 `api_tlv_fields.csv`（由 `gen_tlv_registry.py` 生成） |

为什么必须先做这一步：

- **字段号和长度会随版本变**。`0x545`（QIMEI）在 8.2.11 是 `MD5(qimei)`（16 字节），
  8.9.50 起变成原文；`_SSoVer` 从 7 → 19 → 22。写死一个版本的假设，
  换个版本就是"参数看着都对但登不上"（见 [`docs/PITFALLS.md`](docs/PITFALLS.md) C4）。
- **oicq 是已知可用的实现**，拿它当对照能区分"我抄错了"和"这版协议就是这样"。
  黄金向量必须由参考实现的**原始模块**跑出来，不要手抄。
- **源码里没有出处的常量不许出现**。要么写清"来自哪个包、哪个类、哪一行"，
  要么就别写。`qq8_profiles.dart` 的头部表格就是标准做法，照着做。

**版本差异一律数据化**（`qq8_profiles.dart`），不要写 `if (版本 == xxx)` 分支。

例外的只有**日用线（OneBot）**：它是公开协议，改动以
`assets/backends/*.json` 适配表 + `backend_profile_selftest.dart` 为准，
不需要反编译。**L3/L4（数据层、UI）与协议无关，不受本条约束**——
但也正因为如此，不要在那里塞任何协议常量。

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

当前规模：**15 个 `*_selftest.dart` + 2 个独立自检，合计 1003 项**，全量约 30 秒。

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
| L3 数据对象 / 消息段 / **数据层** | 自测 | 92 + **102 项** |
| L3 接线层（provider + 闸门拒绝路径） | 自测 | **42 项** |
| L2 QQ8 协议（TLV/SSO/传输/登录） | **oicq 黄金向量** + 官方反编译对照 + 本地 mock TCP | 275 项 |

QQ8 协议线的验证强度是分级的，**别高估**：
`TLV / 信封 / TEA / 分帧 / body 头格式` 都有黄金向量或官方代码出处；
**`响应解析` 只有往返测试**（拿不到真实响应样本），真机联通后才能校准。

### 4.2 已接线，但**没有跑起来看过**

| 模块 | 状态 |
|---|---|
| `lib/ui/` | 数据已改为 watch provider，但**本环境跑不了 Flutter**（`flutter.bat` 卡在 SDK 引导检查），一次都没渲染过 |
| `lib/main.dart` | ProviderScope 注入目录 / 适配表 / 闸门 + 日志落盘 |
| `lib/client_api/chat_store.dart` | 数据层：乐观插入 / echo 合并 / 撤回打补丁 / JSONL 落盘 |
| `lib/client_api/session_providers.dart` | 连接前必须过 `SafetyGate`（`_passGate`） |
| `lib/ui/pages/connect_page.dart` | 地址 + 状态 + 环境检测 + 逐条确认 + 立即切断 |

**「analyze 干净 + 逻辑层自测通过」≠「UI 能用」。** 真机验证清单见
[`docs/NEXT-TASK.md`](docs/NEXT-TASK.md) §7，共 9 条，目前一条都没验。

### 4.3 骨架，尚未完成

| 模块 | 状态 |
|---|---|
| `lib/kernel/transport/` `trpc/` `wlogin/` | 早期 MSF 研究骨架，未完成，**暂时别动** |
| `.github/workflows/build.yml` | **有一个已知矛盾**：`v*` tag 推送走的是 `debug` 分支（条件只判了 `workflow_dispatch`），而 `CI-BUILD.md:73` 写的是 tag 出 release。改之前先读 §3.3 |

### 4.4 明确缺失

- **真机验证**（唯一还差的一步，前面已经没有代码缺口）
- 连接页没有 QR / 扫码之类，只有手填地址（够用，先不做）

---

## 5. 下一步做什么

**UI 接线已完成（2026-09-11），代码侧没有已知缺口。** 剩下的按优先级：

1. **真机验证** —— 唯一还差的一步。装到手机上连本机的 NapCat，
   逐条走 [`docs/NEXT-TASK.md`](docs/NEXT-TASK.md) §7 的 9 条。
   **在这一步之前，不要说「UI 能用了」**：本环境从没渲染过它。
2. **构建体积** —— ABI 部分已解决（2026-09-11）：CI 已限定
   `--target-platform android-arm64`，artifact 68.8MB → 44.7MB（run #5）。
   debug 仍偏大是 debug 引擎 + JIT 的缘故（不随 ABI 数缩小）。
   要出能分发的包，用 `workflow_dispatch` + `build_mode=release` 跑一次
   —— 这条路径还没跑过（release 只有一个 ABI，不需要 `--split-per-abi`）。
3. **修 CI 的 tag 分支** —— 见 §4.3 的已知矛盾。

之后才轮到 QQ8 研究线（见下）。

### 5.1 建议的开工顺序

先读这些（按顺序）：

1. 本文件（你在读）
2. [`docs/STATUS.md`](docs/STATUS.md) —— 每个文件的实现程度
3. [`docs/PITFALLS.md`](docs/PITFALLS.md) —— 踩过的坑，**能省你几小时**
4. [`docs/NEXT-TASK.md`](docs/NEXT-TASK.md) —— 刚做完的任务（含 9 条真机验证清单）
5. `lib/client_api/session.dart` —— 内核接缝的契约，改 UI 前必读
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
