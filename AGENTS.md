# AGENTS.md — 项目交接说明

> 这份文件是**给接手本项目的 AI agent 读的第一份文档**。
> 读完它应该能：明白项目在做什么、遵守哪些纪律、当前做到哪、下一步做什么。
>
> 细节文档见 [`docs/`](docs/) 目录，本文件末尾有索引。

---

## 0. 一句话

一个 **Flutter / Android 的 QQ 客户端**（Telegram 风格 UI），
用**可替换的协议内核**同时支撑两条线：

| 线 | 内核 | 定位 | 风险 |
|---|---|---|---|
| **日用线** | OneBot 11 + NapCat | 真能聊天 | 最低（跑官方客户端本体） |
| **研究线** | QQ 8.2.11 / 8.9.50 / tim 自实现协议 | 尝试做到日用 | 高（自实现协议） |

---

## 1. 硬性纪律

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

### 1.8 前端：先吃透 TG 源码，再写第一行 UI（铁律）

**不许"看着差不多"就动手。** 动任何 UI 代码之前，必须先在官方源码里把要写的那个东西读明白。

**唯一合法的两个参数来源**：

| 来源 | 位置 | 适用 |
|---|---|---|
| ① 官方源码实读 | `C:/Users/Administrator/penguis/telegram-src/TelegramAndroid/TMessagesProj/src/main/java/org/telegram/` | 一切几何、字号、圆角、透明度、动画时长、阴影、绘制顺序 |
| ② 已取证表 | `docs/HANDOFF.md` §8、`docs/blur-parity.md`、`docs/ui-parity-matrix.md` | 上一轮已经逐行读过并记下来的值，**不许重复翻源码** |

**两条硬要求**：

1. **每个 UI 常量必须能说出出处 `文件:行号`**，写在该文件头部的文档注释里。
   拿不出处就别写这个值——先读源码，读不懂就停下来问，不许猜。
2. **拿不到官方依据时，必须显式标注"这是自定值"**（注释 + `docs/ui-parity-matrix.md` 登记），
   **绝不许冒充"已对齐 TG"**。`ui-parity-matrix.md` 里的 ❓ 就是给这种情况用的。

**禁止的做法**（都踩过，见 `docs/PITFALLS.md` C123）：

- ❌ 先写完 UI，再回头补出处 —— 事后补的出处多半是编的，而且已经改不回去了
- ❌ 用"截图看起来像"当依据 —— 截图没有行号，抄不出 0.4dp 描边和 4 段 alpha 渐变
- ❌ 用"TG 应该差不多是这样"当依据 —— 官方很多值反直觉（`ActionBar` 高度**已含状态栏**、
  玻璃底栏**始终半透明不能叠实色**、SettingCell **不画 divider**）
- ❌ 拿别的第三方客户端（AyuGram 魔改版、Telegram X、Nagram）当 TG 依据 —— 只认本机
  `telegram-src/` 这一份官方源码，魔改版的分支会把参数带偏

**为什么必须这样**：UI 偏差不是审美问题，是**结构问题**。凭印象写的 56dp/70dp/0.76 透明度，
看起来只差几个像素，但会连带出「行高挤」「tab 附近有实色板」「状态栏图标看不清」这类
用户能立刻感知、却极难定位的缺陷（`docs/PITFALLS.md` C109/C111 就是这类）。补一次出处
的成本是十分钟，返工一次的成本是一整天。

**L3/L4 仍然与 QQ 协议无关**（§1.7 的例外继续有效）：本条款管的是 **UI 参数**，
不是让你去读 QQ 的反编译。

### 1.9 UI 取证流程：读到绘制层，先报告后动手

§1.8 规定了「参数必须有出处」，但没规定「怎么读才叫读透」。2026-11-07 的会话内搜索
顶栏动画连续做错 **5 版**（150ms 纯 alpha → 自定义挤压 → 纯 alpha 修正 → 宽度挤压 →
照 `dispatchDraw` 重写），复盘确认根因不是框架、不是运气，而是取证方法有结构性缺陷：
**每次都只读了一个文件，从没读过一条链**。

**完整流程见 [`docs/UI-取证流程.md`](docs/UI-取证流程.md)**，六条硬要求摘要：

1. **先交取证报告，用户确认后才准动代码**。本仓库两次成功的 UI 重做都是先有报告，
   四次失败全是直接动手。
2. **必须画出完整调用链**：`触发点 → 状态字段 → 动画器 → 绘制方法 → 参数`，
   每段带 `文件:行号`。**画不出这条链就说明没读完，不许动代码**，
   直接告诉用户「这块链我还没画出来」。
3. **必须读到绘制层**（`onDraw` / `dispatchDraw` / `onMeasure` / `onLayout` /
   `onSizeChanged`），不能停在入口方法。入口方法通常只 `setValue(true)` 改标志位，
   真正的插值在绘制层——`ActionBarMenuItem.toggleSearch` 只有 150ms alpha，
   玻璃宽度却在 `ActionBar.dispatchDraw` 里，**在另一个文件**。
4. **先做名词对齐表**：`headerItem` / `avatarContainer` / `searchItem` /
   `searchIconItem` / `otherIcon` / `glassDrawable*` 逐个对应到我方 widget。
   把 `headerItem`（右上角 ⋮ 菜单）当成「头像+标题」就是这么死的。
5. **参数表逐项带出处，缺项写「未取证 / 自定值」**，并登记 `docs/ui-parity-matrix.md`。
6. **中间帧测试 + 三张截图**（开始 / 中间 / 结束），不能只看终态。
   `pump(时长/2)` 断言中间值；`AnimatedOpacity` 首次挂载时目标值已是终值，
   没有 0→1 过程，必须用 `TweenAnimationBuilder(begin: 0, ...)`。

**允许跳过的情况只有两种**：改的是纯颜色/文案/数据且常量已有出处；
或已取证表里已有现成值（这时**不许重复翻源码**，直接引用表里的行号）。

---

## 2. 目录地图

```
qqclient/
├── AGENTS.md                ← 本文件
├── README.md                项目说明
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
│   │   │   └── json_path.dart          JSONPath 子集
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
│   │   ├── segment.dart                sealed Segment（13 种消息段）
│   │   ├── onebot_session.dart         OneBot Session 实现 ★（2026-10-22 从 L2 迁入）
│   │   ├── qq8_session_adapter.dart    QQ8 Session 适配器（复用 qq8_login_service）
│   │   ├── chat_store.dart             数据层：乐观插入 / echo 合并 / 撤回打补丁
│   │   ├── session_providers.dart      连接前必须过 SafetyGate（_passGate）
│   │   └── qq8_*.dart                  研究线：登录服务 / 票据存储 / providers
│   └── ui/                             L4
│       ├── pages/home_page.dart        三栏主界面（**当前吃假数据**，见 §4）
│       ├── theme/telegram_theme.dart   配色与尺寸
│       └── widgets/                    头像 / 消息气泡
│
├── assets/backends/         后端适配表（napcat / lagrange / llonebot）
│
│   （协议分析产物在**同级目录** `../analysis/`，不在本仓库里——它是
│    研究素材，和 APK、参考实现放在一起。协议代码里引用的"某文件某行"
│    都在那边。入口见 ../analysis/README.md）
├── tool/                    全部离线自检（纯 Dart）
├── test/                    flutter test（含 UI widget 测试）
├── android/                 Android 工程
└── .github/workflows/build.yml   CI：自检 → dry-run → 单测 → 打包 APK
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

走 GitHub Actions：

- 推送到 `main` 就自动构建 debug
- 或在 Actions 页面手动 `Run workflow`，选 `debug` / `release`
- **不发布 GitHub Release**（2026-09-11 决定）：产物只在 **Artifacts**
  区域（下载需要登录 GitHub）；tag 触发已移除
- 签名统一在 `android/app/qqclient.p12`：debug / release 同一把钥匙，
  任意两次构建可互相覆盖安装（口令故意公开，上架前必须换）

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
[`docs/HANDOFF.md`](docs/HANDOFF.md) §6.3，共 3 条，均未验。

### 4.3 骨架，尚未完成

| 模块 | 状态 |
|---|---|
| `lib/kernel/transport/` `trpc/` `wlogin/` | 早期 MSF 研究骨架，未完成，**暂时别动** |

### 4.4 明确缺失

- **真机验证**（唯一还差的一步，前面已经没有代码缺口）
- 连接页没有 QR / 扫码之类，只有手填地址（够用，先不做）

---

## 5. 下一步做什么

**UI 接线已完成（2026-09-11），代码侧没有已知缺口。** 剩下的按优先级：

1. **真机验证** —— 唯一还差的一步。装到手机上连本机的 NapCat，
   逐条走 [`docs/HANDOFF.md`](docs/HANDOFF.md) §6.3 的清单。
   **在这一步之前，不要说「UI 能用了」**：本环境从没渲染过它。
2. **构建体积 / 签名** —— 已解决（2026-09-11）：CI 限定
   `--target-platform android-arm64`（debug artifact 44.7MB，release
   实测 17.8MB）；debug/release 统一签名（`android/app/qqclient.p12`），
   任意两次构建可互相覆盖安装。release 走 `workflow_dispatch` + `build_mode=release`。
3. ~~修 CI 的 tag 分支~~ —— 已处理（2026-09-11）：不做"tag 出 release"，
   而是**整体移除** tag 触发与 Release 发布（决定：产物不往 Release 推）。

之后才轮到 QQ8 研究线（见下）。

### 5.1 建议的开工顺序

先读这些（按顺序）：

1. 本文件（你在读）
2. [`docs/HANDOFF.md`](docs/HANDOFF.md) —— **当前唯一有效的交接文档**：环境绝对路径、常用命令、162 项未提交改动、遗留清单、TG 已取证参数
3. [`docs/PITFALLS.md`](docs/PITFALLS.md) —— 踩过的坑，**能省你几小时**
4. [`docs/HANDOFF.md`](docs/HANDOFF.md) §7 与 `docs/PITFALLS.md` C 类 —— 最贵的坑
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
| **UI 参数出处** | **动 UI 前必须先在 `telegram-src/` 读明白，每个常量写明 `文件:行号`**（§1.8）。拿不到官方依据就显式标"自定值"并登记到 `docs/ui-parity-matrix.md`，不许冒充对齐 |
| 不要顺手优化 | 协议实现里很多字段看着冗余（如 `qq8BufUnknown`），删了会静默失败 |

---

## 7. 文档索引

| 文件 | 内容 |
|---|---|
| [`docs/HANDOFF.md`](docs/HANDOFF.md) | **开工必读**：现状 / 环境 / 命令 / 未提交改动 / 遗留 / TG 参数 |
| [`docs/ui-parity-matrix.md`](docs/ui-parity-matrix.md) | 与 Telegram/AyuGram 的 UI 差异表 + **登记规则**（新增 UI 先登记再写码，见 §1.8） |
| [`docs/blur-parity.md`](docs/blur-parity.md) | 模糊覆盖对照 |
| [`docs/UI-取证流程.md`](docs/UI-取证流程.md) | **动 UI 前必读**：六条取证硬要求、调用链模板、名词对齐表、中间帧测试写法（§1.9） |
| [`docs/PITFALLS.md`](docs/PITFALLS.md) | 已踩过的坑与规避方式 |
| [`../analysis/README.md`](../analysis/README.md) | **协议参数的出处**：反编译对照、提取脚本、如何重建产物（在仓库外，同级目录） |
| [`STRUCTURE.md`](STRUCTURE.md) | 分层架构与依赖规则 |
| [`README.md`](README.md) | 项目总览、快速开始、运行模式 |
| [`SAFETY.md`](SAFETY.md) | 账号风险分析、三层防护设计 |
| [`STORAGE-DESIGN.md`](STORAGE-DESIGN.md) | 存储设计取舍 |
| [`CI-BUILD.md`](CI-BUILD.md) | 云端构建与本机构建的坑 |
| [`LIVE-TEST.md`](LIVE-TEST.md) | QQ8 线真机测试的两步流程 |
| [`docs/archive/`](docs/archive/) | 历史文档（23 份，**已过期，只作追溯**） |
| [`TOOLING.md`](TOOLING.md) | 逆向工具链 |
