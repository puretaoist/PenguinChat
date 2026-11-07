# M1 阶段总结：Flutter 工程骨架 + 协议内核 + Telegram 风格 UI

> 日期：2026-09-10 · 工程位置：`C:\Users\Administrator\penguis\qqclient`

---

## 一、本阶段交付内容

| 交付物 | 路径 | 说明 |
|---|---|---|
| Flutter 工程 | `penguis/qqclient/` | 完整可构建的 Android 工程 |
| L1 字节工具 | `lib/infra/coder.dart` | ByteReader/ByteWriter/hexdump |
| L2 TLV 编解码 | `lib/kernel/wlogin/tlv.dart` | WLogin 登录协议核心 |
| L2 TEA 加密 | `lib/kernel/crypto/tea.dart` | QQ 传统对称加密 |
| L3 数据对象 | `lib/client_api/objects.dart` | Chat / ChatMessage |
| L4 主题 | `lib/ui/theme/telegram_theme.dart` | Telegram 配色与尺寸 |
| L4 主界面 | `lib/ui/pages/home_page.dart` | 三栏布局（响应式） |
| L4 组件 | `lib/ui/widgets/*.dart` | 头像、消息气泡 |
| 自测脚本 | `tool/selftest.dart` | 19 项内核测试 |
| 单元测试 | `test/protocol_test.dart` | 标准 Flutter 测试 |
| 文档 | `README.md` / `STRUCTURE.md` | 项目说明与结构 |

---

## 二、验证结果（全部通过）

### 内核自测：19/19 ✅
```
[L1] 字节读写器
  [OK] 小端序 u8/u16/u32 往返
  [OK] 长度前缀字节串往返
  [OK] 读到末尾无残留
  [OK] 越界读取抛出异常

[L2] TLV 编解码
  [OK] 首字段字节布局 = 04 01 04 00
  [OK] 解码后字段数一致
  [OK] tlv_t104 值还原
  [OK] tlv_t106 长度 16
  [OK] tlv_t116 字符串还原
  [OK] TLV 命名规则 tlv_t104
  [OK] 已知常量表 >= 20 项
  [OK] 容错模式不抛异常

[L2] TEA 加密
  [OK] 密文 != 明文
  [OK] 解密还原成功
  [OK] ECB 确定性（同输入同输出）
  [OK] 非法密钥长度报错
  [OK] XXTEA 往返一致

[调试工具] hexdump
  [OK] 十六进制部分正确
  [OK] ASCII 部分正确
```

### 静态分析：`flutter analyze` → **No issues found!**

### 跨语言交叉验证 ✅
Dart 与 Python 的 TEA 实现在相同输入下产出**完全一致的密文**：
```
输入: 0123456789abcdef (key 同为 "0123456789abcdef")
输出: 8b48b3aec04043f7f3e5766f13a918fa
```
> 这是很重要的正确性证据：同一个算法用两种语言独立实现、结果一致，
> 说明对算法语义（轮数、delta、字节序、Feistel 结构）的理解是正确的。

---

## 三、架构设计要点

### 分层（对标 Telegram TDLib）

```
L4 ui/          表现层     ← Flutter，只认识 Chat/ChatMessage
L3 client_api/  客户端 API  ← 对标 td_api，稳定抽象
L2 kernel/      协议内核    ← 对标 TDLib 本体，严格对应报文
L1 infra/       基础设施    ← 字节读写原语
```

**三条设计原则**：
1. **单向依赖**：L4→L3→L2→L1，绝不反向
2. **UI 无协议知识**：界面层看不到 TLV/TEA 概念
3. **内核可替换**：L2 换 Rust（via FFI）时 L3/L4 零改动

### 为什么这样分层
借鉴 TDLib 的成功经验：Telegram 靠这套分层支持了 8 种语言的客户端绑定。
我们的目标 APK（QQ）自身也是这个演进方向（QQNT kernel = native 内核 + Java 桥接）。

---

## 四、与目标 APK 的对应关系

| 本客户端 | 目标 APK（QQ） | 已逆向依据 |
|---|---|---|
| `kernel/wlogin/tlv.dart` | `oicq/wlogin_sdk/tlv_type/tlv_t*` | 115 个 TLV 字段已导出 |
| `kernel/crypto/tea.dart` | `com/tencent/qphone/base/util/Cryptor` | 加密类命中 |
| `kernel/trpc/`（待实现） | `trpc.*` 918 个服务 | api_trpc_services.csv |
| `client_api/objects.dart` | `com/tencent/qqnt/kernel/nativeinterface/*` | QQNT 接口层 |

---

## 五、环境问题与解决（有教学价值）

| 问题 | 现象 | 解决 |
|---|---|---|
| `flutter test` 无法运行 | `Unable to connect to flutter_tester: WebSocket upgrade` | 改用纯 Dart 自测脚本 `tool/selftest.dart` |
| Gradle wrapper 下载失败 | `PKIX path building failed`（证书链） | wrapper 改指向本地已缓存版本 |
| 构建无法拉依赖 | `Could not resolve kotlin-build-tools-impl:2.3.21` | **Gradle 未走代理** → 配置 `~/.gradle/gradle.properties` 的 `systemProp.*.proxyHost` |

> 第三条尤其值得记录：curl 能通不代表 Gradle 能通 —— **Gradle 是独立 JVM 进程，
> 不继承 shell 的 `http_proxy` 环境变量，必须显式配置 `systemProp`**。

---

## 六、下一步（M2）

**目标**：登录链路跑通（能拿到票据）

1. 用 jadx 反编译 `oicq.wlogin_sdk.request.WtloginHelper` 及登录相关类
2. 还原登录 TLV 序列（请求包用了哪些 TLV、各自字节布局）
3. 在 `kernel/wlogin/` 下实现登录流程编排
4. 用 Frida hook 真机验证报文（P4 阶段）

**待确认**：客户端是否需要连接真实腾讯服务器？（影响 M2 的验证方式）
