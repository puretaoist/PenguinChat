# 0x553（FEKit attach）实验预案

> 状态：**已准备，未实测**（2026-10-29 夜）。用户要求先不跑真机/真号，怕触发风控。
> 本文件只写「怎么跑」，不写结论。

## 为什么盯 0x553

四个版本**子命令 9（密码）官方 TLV 顺序表**逐项对比（出处 `analysis/_decompiled/*/sources/oicq/wlogin_sdk/request/{k,j,l,c0}.java`）：

| 版本 | 项数 | 末尾 | 0x553 |
|---|---|---|---|
| QQ 8.2.11 | 37 | `0x548` | 无（树里无 `tlv_t553` 类） |
| QQ 8.9.50 | 37 | `0x548` | 无（无 `tlv_t553` 类） |
| QQ 9.3.60 | **38** | `0x548, 0x553` | 有，`l.java:816` |
| TIM 4.1.0 | **38** | `0x548, 0x553` | 有，`j.java` 末尾 / `c0.java:395` |

其余 37 项三版本完全一致。所以**新旧客户端在密码包上的结构性差异只有 0x553 这一条**。

0x553 的 body 不是协议字段，是 native 产出的 attestation：

```java
// 9.3.60 request/l.java:816（子命令 9 = 密码登录）
case tlv_t553.CMD_553 /* 1363 */:
  bArr17 = new tlv_t553().get_tlv_t553(
      QSec.getInstance().getFeKitAttach(ctx, String.valueOf(uin), "0x810", "0x9"));
```

`tlv_t553` 只是透传壳（`get_tlv_t553(byte[])` 原样搬运）。`QSec.getFeKitAttach`
= `getXwDebugID(uin)`（native，`libfekit.so`）；异常/未 init 时返回 `new byte[]{0}`。

各子命令的第四个参数（scene 恒 `"0x810"`）：

| 子命令 | 第四参 | 出处 |
|---|---|---|
| 9 密码登录 | `"0x9"` | `l.java:816` |
| 2 交滑块票 | `"0x2"` | TIM `WtloginHelper:509` |
| 10 | `"0xa"` | `n.java:207/411` |
| 15 A1 exchange | `"0xf"` | `e0.java:338/979` |

## 三级实验阶梯（按顺序，每一级都可能直接终结问题）

### A. 先证伪「45 = 版本风控」这个前提

此前所有「45 = 账号/版本风控」的结论**都建立在 0x544 签名错误的状态上**（salt 里要带子命令号，
2026-10-29 才修对）。修好之后同一个 8.2.11 档案在好号上直接 `type=2` 并登录成功。

```bash
cd /c/Users/Administrator/penguis/qqclient
DART="$USERPROFILE/scoop/apps/flutter/bin/cache/dart-sdk/bin/dart.exe"
"$DART" tool/qq8_live_smoke.dart --uin=<被45的号> --md5=00000000000000000000000000000000 \
  --profile=8.2.11 --t544=oicq --identity=analysis/_ref/official-logs/identity-25091RP04C.json \
  --send --slider-wait=tmp/tk.txt --slider-wait-secs=5
```

判读（只做首发，不等票）：

- 回 `type=2`（要滑块）⇒ **45 从来不是版本问题**，0x553 不需要，收工。
- 回 `type=45` ⇒ 版本论成立，进 B。

### B. 0x553 是「看有无」还是「看内容」

同一个包，加一条**垃圾** 0x553：

```bash
"$DART" tool/qq8_live_smoke.dart --uin=<被45的号> --md5=0000... \
  --profile=8.2.11 --t544=oicq --t553=00 \
  --identity=.../identity-25091RP04C.json --send --slider-wait=tmp/tk.txt --slider-wait-secs=5
```

- 变成 `type=2` / 其它码 ⇒ 服务端**只看有无**（或只校验长度/结构），我们自己造个合规 body 就过。
- 仍 `type=45` ⇒ **看内容**，进 C。

`--t553` 会在顺序表末尾自动追加 0x553，body 原样发送（`Qq8ApkInfo.withT553`）。

### C. 喂真 attach（用我们自己的 .test 包当签名机）

`.test` 包已内置 TIM 的 117 个 so（含 `libfekit.so` 7.5MB / `libQSec.so`）与整套 TIM dex，
所以可以直接反射调 `QSec.getFeKitAttach`：

```bash
ADB=C:/Users/Administrator/AppData/Local/Android/Sdk/platform-tools/adb.exe
# 1) 构建 + 装 .test 包（带 TIM so）
cd /c/Users/Administrator/penguis/qqclient && bash scripts/build-tim-apk.sh

# 2) 取真 attach（4 个子命令各一份，落在 files/fekit-{9,2,a,f}.hex）
"$ADB" shell am force-stop com.example.qqclient.test
"$ADB" shell am start -n com.example.qqclient.test/com.example.qqclient.TimCoreProbeActivity \
  --es only fekitattach --es uin <uin>
sleep 6
"$ADB" logcat -d | grep -E "TIMCORE :|FEKIT"

# 3) 捞 hex
"$ADB" exec-out run-as com.example.qqclient.test cat files/fekit-9.hex > tmp/fekit-9.hex

# 4) 喂给 Dart 包，走 8.2.11 档案
"$DART" tool/qq8_live_smoke.dart --uin=<被45的号> --md5=0000... \
  --profile=8.2.11 --t544=oicq --t553=$(cat tmp/fekit-9.hex) \
  --identity=.../identity-25091RP04C.json --send --slider-wait=tmp/tk.txt --slider-wait-secs=5
```

**天花板（先说清）**：FEKit attestation 的用料历来是 `(包名, 签名摘要, APK 字节数)`，
替身应用报的是 `.test` 自己的身份，**很可能被判不匹配**。所以 C 是「值得试但可能不通」。

- 通 ⇒ 混合方案成立：只用 native 产这一块料，报文仍我们组。之后才谈产品上带不带 7.5MB so。
- 不通 ⇒ 只剩两条：①复刻 FEKit 协议（`PureAndroidQSign` 在做 9.2.35，工程量极大）
  ②票据导入（已实现，绕过密码链，只需求一张新鲜票）。
  收费签名服务（libfekit.cc 之类）要把账号凭证交第三方，**产品不可接受**。

## 已就绪的工具面（本次改动，均已 `dart analyze` 通过 / Kotlin 编译通过）

| 位置 | 改动 |
|---|---|
| `lib/kernel/wlogin8/qq8_tlv.dart` | 新增 `Qq8ApkInfo.withT553(List<int>? body)`；`qq8PasswordTlvOrderFor` 末尾补 `if (apk.tlv553DegradedBody != null) 0x553`（修与官方 9.3.60/TIM 表不一致的漏项，对 8.2.11 零影响） |
| `lib/kernel/wlogin8/qq8_profiles.dart` | 新增 `Qq8ClientProfile.withApk(Qq8ApkInfo)` |
| `tool/qq8_live_smoke.dart` | 新增 `--t553=<hex>`（注入 0x553 body，顺带打印是否注入） |
| `android/.../TimCoreProbeActivity.kt` | 新增 `--es only fekitattach --es uin <uin>`：反射调 `QSec.getFeKitAttach(ctx, uin, "0x810", sub)`，4 个子命令各落一个 `files/fekit-<sub>.hex` 并打 logcat |

## 风控纪律（跑之前先读）

- 只用**已被 45 的那个号**做 A/B/C，不要碰好号。
- 限流器 `lib/kernel/safety/attempt_limiter.dart`：10 分钟 3 次，跨命令累计；
  记录在 `%TEMP%/qqclient-attempts.json`。每跑一次 `--send` 前先看一眼。
- `type=45` 不在豁免列表里（`isProgressCode` 只有 type=2/204），会计入连败。
