# 项目结构说明

工程根目录：`C:\Users\Administrator\penguis\qqclient`

```
qqclient/
├── lib/                              源代码（分层架构）
│   ├── main.dart                     应用入口
│   │
│   ├── infra/                        ── L1 基础设施层 ──
│   │   └── coder.dart                ByteReader / ByteWriter / hexdump
│   │
│   ├── kernel/                       ── L2 协议内核层（对标 TDLib 本体）──
│   │   ├── wlogin/
│   │   │   └── tlv.dart              TLV 编解码 + 26 个已确认 QQ TLV 常量
│   │   ├── crypto/
│   │   │   └── tea.dart              TEA / XXTEA（QQ 传统包加密）
│   │   ├── transport/                MSF 长连接（M3 实现）
│   │   └── trpc/                     trpc 服务 / SSO 命令字（M4 实现）
│   │
│   ├── client_api/                   ── L3 客户端 API 层（对标 td_api）──
│   │   └── objects.dart              Chat / ChatMessage 数据对象
│   │
│   └── ui/                           ── L4 表现层 ──
│       ├── theme/telegram_theme.dart Telegram 配色 + 尺寸规格
│       ├── pages/home_page.dart      三栏主界面（列表/消息/输入）
│       └── widgets/
│           ├── telegram_avatar.dart  圆形首字母头像
│           └── message_bubble.dart   消息气泡（含时间戳、已读标记）
│
├── test/
│   └── protocol_test.dart            标准 Flutter 单元测试
├── tool/
│   └── selftest.dart                 纯 Dart 自测（受限环境可用，19 项）
├── assets/
│   └── theme.json                    Telegram 主题配置（明/暗两套）
├── android/                          Android 平台工程
├── pubspec.yaml                      依赖配置
└── README.md                         项目说明
```

## 数据流

```
用户操作
   ↓
[L4 UI]  home_page.dart
   ↓  只依赖 Chat / ChatMessage
[L3 API] client_api/objects.dart     ← 稳定的高层抽象
   ↓  编排转换（M2-M4 实现）
[L2 内核] kernel/wlogin + crypto + transport
   ↓  严格对应线上报文字节
[L1 基础] infra/coder.dart
   ↓
网络（MSF 长连接）
```

## 分层原则

| 原则 | 说明 |
|---|---|
| 单向依赖 | L4 → L3 → L2 → L1，绝不反向 |
| UI 无协议知识 | UI 层看不到 TLV、TEA 等概念，只处理数据对象 |
| 内核可替换 | L2 整体换成 Rust 时，L3/L4 零改动 |
| 可测试性 | L1/L2 为纯逻辑，不依赖 Flutter 引擎即可单测 |

## 已完成的核心算法

### TLV（`kernel/wlogin/tlv.dart`）

```
+--------+--------+------------------+
| type   | len    | value            |
| uint16 | uint16 | len 字节          |
+--------+--------+------------------+
        全部小端序（LE）
```

示例：`TlvPacket()..add(0x104, [0x01,0x02,0x03,0x04])` 编码为：
```
04 01 | 04 00 | 01 02 03 04
type    len     value
```

### TEA（`kernel/crypto/tea.dart`）

- 分组：64 位（2 × uint32）
- 密钥：128 位（4 × uint32）
- 轮数：16（QQ 变体）
- delta：`0x9E3779B9`
- 模式：ECB

与 Python 实现交叉验证一致：
```
明文 0123456789abcdef
密文 8b48b3aec04043f7f3e5766f13a918fa
```
