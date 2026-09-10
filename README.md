# QQ Client（Flutter / Android）

软件安全课程作业：**反编译官方 QQ APK → 提取协议与加密机制 → 自研 Android 客户端**（UI 向 Telegram 靠齐）。

## 当前状态

| 里程碑 | 内容 | 状态 |
|---|---|---|
| P1 | 协议测绘（接口清单导出） | ✅ 完成 |
| P2 | 登录流程还原（TLV 序列） | ⏳ 待推进 |
| P3 | 加密还原（native 交叉验证） | ⏳ 待推进 |
| **M1** | **工程骨架 + 协议内核 + Telegram 风格 UI** | ✅ **完成** |
| M2 | 登录链路跑通 | ⏳ |
| M3 | MSF 长连接 + 心跳 | ⏳ |
| M4 | 会话列表 + 消息收发 | ⏳ |
| M5 | 性能优化（可选：Rust 内核） | ⏳ |
| M6 | 报告与演示 | ⏳ |

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
dart run tool/selftest.dart     # 协议内核自测（19 项，不依赖 flutter_tester）
flutter analyze                 # 静态分析
flutter build apk --debug       # 本机构建（需配好 Android SDK + 镜像源）
flutter run                     # 连接设备运行
```

## 架构（对标 Telegram TDLib 的分层设计）

```
lib/
├── main.dart                 应用入口
├── infra/                    L1 基础设施
│   └── coder.dart            字节流读写器（小端序原语 + hexdump）
├── kernel/                   L2 协议内核
│   ├── wlogin/tlv.dart       WLogin TLV 编解码（登录鉴权核心）
│   ├── crypto/tea.dart       TEA / XXTEA 加密
│   ├── transport/            MSF 长连接（M3）
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

- **TLV 编解码**：`type(uint16) + len(uint16) + value`，小端序；内置 26 个已逆向确认的 QQ TLV 常量。
- **TEA / XXTEA**：QQ 传统对称加密，16 轮、delta=0x9E3779B9、ECB 模式。
- **字节工具**：小端读写原语、长度前缀字节串、hexdump 调试输出。

> TEA 实现已与 Python 版交叉验证：相同输入下密文完全一致
> （`0123456789abcdef` → `8b48b3aec04043f7f3e5766f13a918fa`）。

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
