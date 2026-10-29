# 首次真机成功登录（2026-10-29 21:32）

我方**纯 Dart 原生客户端**（包名 `com.example.qqclient`，无任何腾讯 so、无 OneBot、无 hook）
在真机 Redmi 25091RP04C（serial HA2CSJR5）上完成 QQ 密码登录并上线。

## 成功链路（App 日志原文，`files/logs/qqclient-2026-10-29.log`）

| 时间 | 动作 | 结果 |
|---|---|---|
| 21:32:41 | 子命令 9（口令）25 项 TLV，含 0x544 | `type=2` 需要滑块 |
| 21:32:50 | App 内 WebView 解滑块，`message type=34` 带回 ticket/randstr | ticket 129 字符 |
| 21:32:51 | 子命令 2 交票，5 项 `0x193,0x8,0x104,0x116,0x547` | `type=160` 转短信 |
| 21:32:55 | 子命令 8 发短信 | `type=160`，二次下发 |
| 21:33:05 | 子命令 7 交短信码，8 项 | **`type=0`**（0x119/0x161） |
| 21:33:06 | 上线 | 好友 2/2、群 0/0、拉新消息 1 条 |

## 三个必要条件的组合（缺一不可）

1. **真机身份注入**：`<dataDir>/qq8/identity.json`（`adb push` + `run-as` 写入）。
   内容 = `analysis/_ref/official-logs/identity-25091RP04C.json`
   （`android_id=25cf6881290b58f7`、`guid=7d9cf98da15d5c95f87507273280cbbf`、`qimei=c5da7bd1…a806`、`ksid=188ca876…d3d7`）。
   启动日志应出现 `设备身份来源: identity.json（人工注入）`。
2. **0x544 用纯 Dart 真签**：`Qq8T544Mode.oicq`（39 字节），登录 subCmd=9、交票 subCmd=2、
   发短信 8、交码 7（salt 里含子命令号，复用同一把签会回 45，见 PITFALLS C70）。
   实测对照：同一账号零字节降级签 → `type=45`；纯 Dart 签 → `type=2`。
3. **验证码在 App 自己的 WebView 里解**：UA 与登录包同源，ticket 才与 `cap_cd`/sid 对得上。
   PC 浏览器（Edge/Helium）解出来的票交上去一律 237 WrongTicket。

## 票据落地与自动续期

登录成功后自动写 `<dataDir>/qq8/qq8-token-<uin>.json`（1002 字节）：

```
tgt 72B / d2 64B / d2key 16B / sig_key 48B / a1 136B / srm_token 80B / ticket_key 16B
```

杀进程重开后**不需要再输密码**（实测 21:35:36）：

```
启动自动登录：用保存的票据登录
发登录包 subCmd=11 TLV=18项 … 0x544
登录响应 type=0 → 已上线   （全程 0.6 秒）
```

⇒ 票据续期走子命令 11，**不碰口令链**，这是后续所有日常使用的默认路径。

## 与「小号成功后被风控」的差别（重要）

2026-10-24/25/26 小号 3499239040 也成功过，10-27 起四套档案一律 45。当时与这次的关键差异：

| 维度 | 那次（成功后被打标） | 这次 |
|---|---|---|
| 设备身份 | 合成派生 / 中途换过（`ourdev-identity.json`） | 真机官方值，钉死 |
| 0x544 | 24 项老表，无签 / 零字节降级 / 错子命令签 | 纯 Dart 真签，按子命令取号 |
| 口令链频次 | 数十次反复打（限流器 52 条记录） | 一次成功即锁票 |
| 验证码 | 无 / PC 浏览器票 | App WebView 内解 |

**纪律（防止再次被打标）**：

1. 一次成功立刻锁票；之后只用 `subCmd=11` 续期，不再走口令链。
2. 同一账号短时间内不反复登录/登出；App 内限流器 `lib/kernel/safety/attempt_limiter.dart` 保持 3 次/10 分钟。
3. `identity.json` 一旦注入就不要再换（合成/采集混用 = 两台设备在同一个号上登录）。
4. 需要重新口令登录时，先确认 0x544 是真签（日志 `0x544` 39/41 字节），不要用降级体试探。

## 复现命令

```bash
# 1) 构建 + 安装纯净包（不含腾讯 so）
cd /c/Users/Administrator/penguis/qqclient
USERPROFILE=C:/Users/Administrator bash scripts/build-pure-apk.sh

# 2) 注入真机身份（MSYS 路径转换必须关，否则 /data 被改写成本地路径）
export MSYS_NO_PATHCONV=1
adb push C:/Users/Administrator/penguis/analysis/_ref/official-logs/identity-25091RP04C.json //data/local/tmp/identity.json
adb shell "cat /data/local/tmp/identity.json | run-as com.example.qqclient sh -c 'cat > files/qq8/identity.json'"

# 3) 起 App，手动登录（滑块/短信都在 App 内完成）
adb shell am start -n com.example.qqclient/.MainActivity
```
