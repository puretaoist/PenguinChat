# QQ Client（Flutter / Android）

软件安全课程作业：**反编译官方 QQ APK → 提取协议与加密机制 → 自研 Android 客户端**（UI 向 Telegram 靠齐）。

> ## ⚠️ 先读这个
>
> 本项目会连接**真实腾讯服务器**，这**违反《QQ 用户协议》**，
> 且存在**账号被永久封禁**的风险。
>
> 客户端默认运行在**离线模式**，连接真实服务器需逐条确认风险。
> 项目**不提供**任何设备指纹伪造、验证码绕过、设备锁绕过能力。
>
> 完整风险说明与安全建议见 **[`SAFETY.md`](SAFETY.md)**。
> **请勿使用主账号测试。**

## 当前状态

| 里程碑 | 内容 | 状态 |
|---|---|---|
| P1 | 协议测绘（接口清单导出） | ✅ 完成 |
| **M1** | **工程骨架 + 协议内核 + Telegram 风格 UI** | ✅ **完成** |
| **M2** | **登录协议逆向 + 字节序/加密模式修正** | ✅ **完成** |
| M3 | MSF 长连接 + 心跳 | ⏳ |
| M4 | 会话列表 + 消息收发 | ⏳ |
| M5 | 性能优化（可选：Rust 内核） | ⏳ |
| M6 | 报告与演示 | ⏳ |

## M2 关键修正（重要）

M1 有两处未经验证的假设，M2 用反编译证据推翻了：

| 项 | M1（错） | M2（对） | 证据 |
|---|---|---|---|
| 字节序 | 小端 | **大端** | `tools.util.int16_to_buf` 高字节在前 |
| 加密模式 | 裸 ECB TEA | **填充 + CBC（零 IV）** | `tools.cryptor` 解密路径 `P = D(C) XOR C_prev` |

TLV 布局本身是对的，并得到确认：`[cmd:u16 BE][len:u16 BE][body]`，
头固定 4 字节，`len` 只计 body。详见 [`M2-REPORT.md`](M2-REPORT.md)。

## 快速开始

### 云端构建（推荐）

本机 Gradle 环境（JDK / SDK / 网络代理 / 进程文件锁）问题较多，**编译交给 GitHub Actions**：

```bash
bash scripts/push-to-github.sh <你的GitHub用户名> qqclient
```

推送后打开仓库的 **Actions** 页面，等 5–10 分钟，在 run 页面的 Artifacts 区域下载 APK。

详细步骤见 [`CI-BUILD.md`](CI-BUILD.md)。

### 本机开发

```bash
flutter pub get
dart run tool/selftest.dart           # 协议内核自测（57 项）
dart run tool/storage_selftest.dart   # 存储层自测（48 项）
dart run tool/safety_selftest.dart    # 安全防护自测（53 项）
flutter analyze                       # 静态分析
flutter build apk --debug             # 本机构建（需配好 Android SDK + 镜像源）
flutter run                           # 连接设备运行
```

## 运行模式与安全约束

| 模式 | 行为 | 风险 |
|---|---|---|
| `offline`（**默认**） | 不联网，UI 使用内置样例数据 | 无 |
| `loopback` | 内存回环，协议链路完整可跑 | 无 |
| `realServer` | 连腾讯生产服务器 | **有，不可完全消除** |

安全约束（代码层强制，非文档约定）：

- 默认离线，开启真实服务器需**逐条复述** 4 条风险要点（关键词校验，防随手点过）
- 登录尝试**硬限制**：10 分钟 3 次；递增冷却；连续 5 次失败锁 24 小时
- 尝试计数**持久化**——重启应用不清零
- **禁止自动重试**：除「无信号」外任何服务端拒绝都立即中止
- 一键切断（`killSwitch`）随时回到离线

详见 [`SAFETY.md`](SAFETY.md)。

## 存储设计（体积控制）

目标：**装完几百 MB，用一年还是几百 MB。**

针对官方 QQ「越用越大到几十 G」的问题，本项目的存储层按
**内容寻址 + 单一预算 + 两级语义**设计，而非官方的「每业务一套目录与配额」。
预期占用从官方的 10GB+ 降到 **≤ 512MB（硬约束，非估计）**。

详见 [`STORAGE-DESIGN.md`](STORAGE-DESIGN.md)。

## 架构（对标 Telegram TDLib 的分层设计）

```
lib/
├── main.dart                 应用入口
├── infra/                    L1 基础设施
│   ├── coder.dart            字节流读写器（默认大端；显式提供小端变体）
│   └── storage/              存储层（内容寻址，控体积）
│       ├── blob_store.dart        CAS：SHA-256 落盘 + 两级分桶
│       ├── cache_policy.dart      全局预算 + LRU 淘汰
│       └── storage_manager.dart   两级语义 + 引用清单
├── kernel/                   L2 协议内核
│   ├── wlogin/
│   │   ├── tlv.dart          TLV 编解码（4 字节头，大端）
│   │   ├── tlv_types.dart    113 个已确认 TLV 编号（自动生成）
│   │   └── login_commands.dart  14 条登录命令字 + 阶段/结果码模型
│   ├── crypto/tea.dart       TEA 分组原语 + QQ TEA（填充+CBC）
│   ├── transport/transport.dart  长连接抽象 + 回环实现（M3 接真实 MSF）
│   ├── safety/              账号风险防护（见 SAFETY.md）
│   │   ├── safety_gate.dart      连接模式闸门 + 知情同意 + 风控信号判定
│   │   └── attempt_limiter.dart  登录尝试限制（持久化 + 递增冷却）
│   └── trpc/                 trpc 服务 / SSO 命令字（M4）
├── client_api/               L3 客户端 API 层（对标 td_api）
│   └── objects.dart          Chat / ChatMessage 数据对象
└── ui/                       L4 表现层
    ├── theme/                Telegram 配色与尺寸规格
    ├── pages/home_page.dart  三栏主界面
    └── widgets/              头像、消息气泡
```

### 设计要点（借鉴 TDLib）

1. **双层 API 分离**：`client_api`（稳定、高层）与 `kernel`（严格对应线上报文）分开，中间由编排层转换。
2. **UI 与协议解耦**：UI 只依赖 `client_api` 的数据对象，协议变更不影响界面。
3. **内核可替换**：`kernel` 层接口设计为可整体替换（如后续换 Rust via FFI），UI 零改动。

## 已实现的协议能力

- **TLV 编解码**：`[cmd:u16][len:u16][body]`，**大端**，头固定 4 字节，`len` 只计 body。
  已确认 **113 个** TLV 编号（`tlv_types.dart`）。
- **TEA 分组原语**：16 轮、delta `0x9E3779B9`、解密 sum 初值 `0xE3779B90`、**大端**字。
- **QQ TEA 真实模式**：`pad = (8-(len+10)%8)%8`，输出长 `pad+len+10`，
  CBC 零 IV，尾部 7 字节零校验。
- **登录命令族**：`EcdhService.SsoNTLogin*` 14 条（口令/短信/网关码/新设备/免密/票据刷新）。
- **传输层抽象**：`Transport` 接口 + `LoopbackTransport`（UI 可离线开发）。

> **验证状态说明**
>
> 已做到：`flutter analyze` 无问题；`dart run tool/selftest.dart` **57/57 通过**；
> 字节序/轮函数/加密模式均有反编译证据支撑。
>
> 未做到：**没有与官方客户端的密文逐字节比对**。因此「算法规格正确」有证据，
> 但「实现与官方完全等价」尚未证明。这是 M2 的已知边界，见 `M2-REPORT.md` 第七节。

## 性能优化路线（可选）

判定标准：**高频 + 逐字节循环** 的模块才值得下沉到 Rust。

| 层 | 是否下沉 | 理由 |
|---|---|---|
| UI / 渲染 | ❌ | Flutter 引擎本身已是 C++ |
| TLV 编解码 | ✅ 候选 | 高频小对象分配，Dart GC 有开销 |
| TEA/AES/ECDH | ✅ 候选 | 计算密集，Rust 无 GC 停顿 |
| Socket 收发 | ❌ | IO 密集，瓶颈在网络 |
| 存储 | ❌ | 用成熟库，不自研 |

推荐方式：`flutter_rust_bridge` 自动生成 FFI 胶水，避免手写 JNI。
成本：APK 增加约 2-6MB（可用 `--split-per-abi` 降低）。

## 环境

- Flutter 3.47.2 stable / Dart 3.13.2
- 依赖：flutter_riverpod、dio、pointycastle、cryptography、shared_preferences

## 免责声明

本项目仅用于经作者授权的课程逆向学习（软件安全攻防）。反编译所得协议知识应用于教学研究，不得用于未授权用途。

本项目为独立作品，与腾讯控股有限公司及其关联公司无任何隶属、认可、赞助或官方关联关系。

## 许可

**专有许可，保留所有权利（All Rights Reserved）。**

未经版权持有人事先书面许可，任何人不得使用、复制、修改、分发、再许可、
出售或以其他方式利用本软件的全部或任何部分。完整条款见 [`LICENSE`](LICENSE)。

需要说明两点：

- 本软件依赖的第三方组件（Flutter、Dart SDK 及 `pubspec.yaml` 中列出的各包）
  **仍然适用其各自的许可条款**，本项目不改变、不限制也不取代这些条款。
  使用者有责任自行遵守。
- 本许可**不授予任何专利许可、商标许可或品牌使用权**。

如需授权，请通过仓库 <https://github.com/puretaoist/PenguinChat> 联系版权持有人。

