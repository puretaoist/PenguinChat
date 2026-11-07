# 外部资料检索：code 45 / 版本过低 / 签名服务（2026-10-29）

结论先行：code 45 在业界被一致认定为**账号风控标记**，不是版本号问题；唯一被广泛验证的破解手段是**签名服务（unidbg 加载真实 libfekit.so）**，而且 2024 年之后连签名服务也「不能百分百解决」。

## 1. 错误码语义表（OlivOS 论坛，最完整的一份）
来源：https://forum.olivos.run/d/505-signserver

- `Code45 协议版本低`
- `Code45 签名服务器未生效的登录错误`  ← **同一码、两种成因**，说明 45 既可能是版本判据也可能是「签名没生效」
- `Code45 帐号被限制在非常用设备登录(且被冻结)，需要去微信-腾讯客服-账号登录问题-手持身份证拍照向人工客服申请解冻`
- `Code40 帐号被冻结`
- `Code237 登录网络环境不安全，重启程序，在滑块步骤时，请把滑块的链接复制到手机，用流量打开滑块即可`  ← **我方 237 的直接解法**
- `-10003 解析数据包错误，协议与账号临时登录文件不符`
- 该帖还要求「签名服务器 txlib_version 需 8.9.68 及以上」

> 对我方：237 = 滑块票据被判定「网络环境不安全」。官方建议用手机流量打开滑块链接。我方是 WebView 内嵌打开、与客户端同 IP，很可能正是被判不安全的原因。

## 2. 「版本过低」的真实含义 = 疑似 BOT
来源：https://www.cnblogs.com/czy-blogs/p/17320097.html （Yunzai 用户总结）
原文要点：「该问题是 TX 认为账号有被用作 BOT 的嫌疑，而阻止你登陆……TX 就用"版本过低"的问题来卡我们」。

给出的实践解法（社区验证）：
- **code 45 / 238**：① 把 platform 从 5(iPad) 改成 4(MacOS)；② **手机官方 QQ → 点自己头像 → 设置 → 账号安全 → 登录设备管理 → 把所有设备全删掉（别删自己手机）**，再重试。
- **code 237 / 235**：换一个新号。

> 对我方：第 ② 条是唯一一条「可能把已被标的账号救回来」的账号级操作，1 分钟可试，值得插队验证小号 3499239040。

## 3. 社区共识：45 几乎不会自然解除，签名服务是主流但非万能
来源：https://forum.kokona.tech/d/2025/3
- 「确定是 code45 风控的话几乎不会自然解除。目前 code45 风控的主流应对方法是搭载签名服务……在目前的环境下签名服务已经不能百分百解决 code45 了，但是大部分情况下还是可用的。」
- 还提到 mirai 的 overflow 项目。

## 4. 签名服务的技术内核 = unidbg 里跑真实 libfekit.so（对我们最有价值）
qsign 源码（Kotlin 重写的 Java 壳 + unidbg）：
https://github.com/CrackerCat/unidbg-fetch-qsign
其它部署形态：rhwong/qsign-onekey（Windows 一键，2025-08 仍在更新）、CikeyQi/unidbg-fetch-qsign-shell、touchscale/Qsign。

### 4.1 FEKit 初始化配方（解决了我们「FEKit.init 4 个串语义未知」的死结）
`src/main/kotlin/com/tencent/mobileqq/fe/FEKit.kt`：
```kotlin
QQSecuritySign.initSafeMode(false)
QQSecuritySign.dispatchEvent("Kicked", "0")
Dtn.initContext(context)
Dtn.initLog(IFEKitLog 实例)
Dtn.initUin("0")
ChannelManager.setChannelProxy(ChannelProxy 实例)
ChannelManager.initReport(QUA, CHANNEL_VERSION)   // 见下：真正的设备信息入口
QQSecuritySign.requestToken()
QSec.doSomething(context, 1)
```
即：**不需要猜 FEKit.init 的 4 个字符串**，按上面 9 步调 JNI 即可。换账号用 `FEKit.changeUin(uin)`（= Dtn.initUin(uin) + dispatchEvent("Kicked", uin)）。

`ChannelManager.initReport` 的真实签名与样例（注释里给了官方一行日志）：
`initReport(qua, version, androidOs, brand+model, qimei36, guid)`
样例：`V1_AND_SQ_8.9.63_4188_HDBM_T, 6.100.248, 12, HONORLGE-AN10, 022eefeab5f927507337089f100015717619, 35bf20e2a3e25bf715479d6ab76b146d`

### 4.2 0x544（lite sign）的 salt 布局 —— 按子命令分四种 mode
`src/main/kotlin/moe/fuqiuluo/api/Energy.kt`，data 形如 `810_9`（= "810_" + hex(subcmd)）：

|| 适用 data | 布局 |
|---|---|---|
| v1 | `810_25`(37) `810_7`(7) `810_24`(36) | `u64(uin) ‖ u16(guid.len) ‖ guid ‖ u16(ver.len) ‖ ver` |
| v2 | `810_d` `810_a`(10) `810_f`(15) **`810_9`(9, 密码)** | `u32(0) ‖ u16(guid.len) ‖ guid ‖ u16(ver.len) ‖ ver ‖ u32(sub) ‖ u32(0)` |
| v3 | `812_a` | `phone("86-xxx") ‖ u16(0) ‖ u16(ver.len) ‖ ver ‖ u16(0)` |
| v4 | `812_5` | 未取全 |

> 我方现状：8.2.11 密码链 salt = `u32(uin) ‖ u16(16) ‖ guid ‖ u16(10) ‖ "6.0.0.2423" ‖ u32(9)` = 38B。
> qsign 的 v2 是 `u32(0) … u32(sub) ‖ u32(0)` = **42B，且不含 uin**。
> ⇒ 两条线索：(a) 我们的首字段用 uin 而 qsign 用 0，尾部少了 u32(0)；(b) **如果 sign 不绑定 uin，那么同一台设备的 0x544 对所有账号可复用，可一次性预计算**。

### 4.3 签名 API 形态（可当作离线 oracle）
- `GET /energy?data=810_9&salt=<hex>&guid=&uin=&version=` → 返回真实 0x544 签名
- `GET /sign?uin=&qua=&cmd=&seq=&buffer=<hex 整包 body>&qimei36=` → 返回 `{token, extra, sign, o3did}`（= 0x553 FeKitAttach 三件套）
> 意味着：只要能在 PC 上跑起 qsign（unidbg 模拟 ARM），就能**离线**为我们自己的 (uin, guid, version, subcmd) 产出真签，然后让 Dart 客户端直接回放，App 里不必内置 native。

## 5. 纯算法复刻的现状（还不能用）
- `zclkkk/PureAndroidQSign` —— .NET 10 净室重写 QQ 9.2.35 fekit（JNI_OnLoad 注册的 30 个方法），README 明说「不猜测未知 native 行为」，当前里程碑**只定义了接口**。⇒ 参考价值 > 使用价值。
- `fuqiuluo/rnidbg` —— qsign 作者用 Rust 重写 unidbg（Android-ARM64 内核模拟），2026-02 仍在提交。⇒ 若要在服务端跑真 so，这是新一代底座。

## 6. 「手表协议」这条支线
来源：https://forum.koishi.xyz/t/topic/3598 （被论坛管理员判定为错误教程，风险提示：约 80% 概率冻结 0-90 天，不建议照做）
其中出现的现象值得记：「大部分用户在登陆是总会遇到版本过低的提示 / **仅可使用手表协议登录**」。其 `qdvc` 设备串是 `display=MI.427512.001, product=hcl, protocol=6` 一类的手表/平板档案。
> 即：45 之后手表协议常常还能登。手表协议的 TLV 集更小，可能不含 0x544/0x553。若我们只需要「登录并收发群消息」，手表协议是一条值得单独侦察的路（未验证）。

## 7. 与我方实验的对照
- 我方小号：大号同分钟 type=2、小号 45；四套档案/版本字节全试仍 45 ⇒ 与「账号级风控标记」一致。
- 我方新号：8.2.11 档案仍 type=2 ⇒ 45 不是协议级封禁。
- 我方 0x544 长期发「四个零字节」/纯 JS 老算法 ⇒ 正对 OlivOS 表里「**签名服务器未生效的登录错误**」那一类 45，说明我们很可能是在「用无效签名反复登录」的过程中把账号送进风险池的。

## 8. 可执行清单（按性价比）
1. （1 分钟）手机官方 QQ → 登录设备管理 → 删掉所有其它设备 → 小号重试密码登录。
2. （1 分钟）官方 TIM/QQ 本体用小号登一次，拉 `qqapp-*.log`，确认「官方是否也被拦」。
3. （真机）237 复测：滑块链接改用手机 4G/5G 打开（或让 WebView 走蜂窝网络），而不是与客户端同 IP。
4. （离线）按 §4.1 的 9 步在 test 包里重写 sign544 探针，不再猜 init 字符串。
5. （离线）按 §4.2 v2 布局修正 0x544 salt（42B，首尾 u32(0)），验证是否影响首发码。
6. （离线，若 1-3 失败）在 PC 上跑 qsign + 对应 txlib，用 /energy 给我们自己的 (guid, version, 810_9) 产真签，回放进 Dart 客户端。
