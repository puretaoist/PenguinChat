# QQ 8.2.11 Play 版 —— 逆向提取的登录参数

来源：`QQ-com.tencent.mobileqq-play-8.2.11.apk`（94.3 MB，构建时间 2020-12-25，arm64-v8a）
方法：7-Zip 解包 + jadx 1.5.6 反编译 + nm/objdump 分析 native + Python 扫描 dex 字符串池

---

## 一、结论速览

**8.2.11 的登录链路完全不含 native 签名依赖。**
所需的一切都是纯算法（TLV / TEA / ECDH / RSA / JCE），可用 Dart 重写。

对照 `takayama-lily/oicq` 的 `lib/wtlogin/`（6 个纯 JS 文件，共 41 KB），
8.2.11 时代的登录就是那个形态—— **oicq 的源码可直接作为移植参照**。

---

## 二、完整参数表

| 字段 | 值 | 来源 |
|---|---|---|
| `version` | `8.2.11.4530` | `AppSetting.java:40` |
| `ver`（短版本） | `8.2.11` | AndroidManifest `versionName` |
| `fullVersion` | `8.2.11.4530.2020-12-25.0153f87a.GoogleMarket` | `AppSetting.java:46` |
| `displayVersion` | `V 8.2.11.4530` | `AppSetting.java:40` |
| `qua` | `V1_AND_SQ_8.2.11_1380_GM_D` | dex 字符串池（`classes.dex`） |
| **`sign`** | **`a6b745bf24a2c277527716f6f36eb68d`** | `META-INF/ANDROIDR.RSA` 内证书 DER 的 MD5 |
| `subid`（SubAppId） | `537064117` | `AppSetting.java:31`（字段 `f`，由 `a()` 返回） |
| `appid` | `16` | WLogin SDK 常量（oicq 表中同为 16） |
| `miscBitmap` | `150470524` | `WtloginHelper.java:123/141/156` |
| `mainSigMap` | `16724722` | `WtloginHelper.java:121/139/154` |
| `subSigMap` | `66560` | `WtloginHelper.java:122/140/155` |
| `versionCode` | `1380`（由 qua 推断） | `V1_AND_SQ_8.2.11_1380_GM_D` |
| `appSignStr` | `CFF538A644DABF88` | `AppSetting.java:37`，用于拼 QUA 串 |
| 渠道 | `GoogleMarket` | 版本串后缀 |
| 构建日期 | `2020-12-25` | 版本串 |

---

## 三、关键验证：`sign` 字段的来源已确认

oicq `lib/device.js` 里 8.4.1 的 sign：

```js
sign: Buffer.from([166,183,69,191,36,162,194,119,82,119,22,246,243,110,182,141])
//    = a6 b7 45 bf 24 a2 c2 77 52 77 16 f6 f3 6e b6 8d
```

8.2.11 APK 的证书 DER 在 `META-INF/ANDROIDR.RSA` 偏移 `0x3c`、长度 `595`，其 MD5：

```
a6b745bf24a2c277527716f6f36eb68d
```

**逐字节相同。**

推论：
1. **`sign` = APK 签名证书 DER 的 MD5**（方法已确认）
2. **腾讯用同一张证书签所有 QQ 版本**，所以 `sign` 跨版本不变
3. oicq 的 `apk` 参数表可以直接复用

---

## 四、`mMiscBitmap` 的对照（说明参数表可复用）

| 来源 | `miscBitmap` |
|---|---|
| QQ 8.2.11（实测） | `150470524` |
| oicq `apk[2]`（aPad） | `150470524` ← **相同** |
| oicq `apk[1]`（android phone） | `184024956` |

`miscBitmap` 是**能力位**（声明客户端支持哪些特性）。8.2.11 的能力位与
oicq 表中 aPad 条目一致——说明**不必为 8.2.11 单独造一张表**。

---

## 五、`libckeygenerator.so` 的更正（重要）

早先误判它是 QQ 登录签名库，**实际是腾讯视频的 ckey 防盗链 SDK**：

- 真实包路径：`com.tencent.qqlive.tvkplayer.vinfo.ckey`
- `CKey41Gen` 里写着 `"vid:" + vid + "[" + time + "];guid:" + guid` —— 给视频 URL 签名
- `SetIpPort("rlog.video.qq.com", 8080, "bkrlog.video.qq.com", 8080)` —— 日志上报
- 线程名 `TVK_ckeythread`（TVK = Tencent Video Kit）
- 源码路径字符串：`video_security/ckey_sdk_project/android/jni/`
- 导入表里的 `socket`/`connect`/`gethostbyname` 是给日志上报用的，**与密码学无关**

QQ 只是内嵌了腾讯视频播放器才带上它。**与登录无关，不需要它。**

---

## 六、native 库现状

| 库 | 大小 | 作用 | 是否登录必需 |
|---|---:|---|---|
| `libwtecdh.so` | 17,800 B | ECDH + RSA（纯 OpenSSL：`EC_KEY_*` / `RSA_*`） | **可纯 Dart 重写** |
| `libckeygenerator.so` | 362,392 B | 腾讯视频 ckey | ❌ 无关 |
| `libmsfbootV2.so` | 203,800 B | MSF 长连接引导 | 待评估 |
| `libmqq.so` | 9,992 B | 杂项 | 待评估 |
| `libfekit.so` | — | **8.2.11 不存在**，8.9.50 才有（9.7MB 混淆） | ❌ 不需要 |

`libwtecdh.so` 同时导出**纯 C 符号**（`GenerateKey` / `GetPubKey` / `GetPrivKey` /
`RsaEncryptData` / `RsaDecryptData`），可直接 `dart:ffi` 调用；但更优的路线是
按 oicq 的做法用 `pointycastle` 纯 Dart 实现。

---

## 七、演进路径（解释为什么 8.2.11 最简单）

| 时代 | 签名方式 | 证据 |
|---|---|---|
| **8.2.11 / 8.4.1** | **纯算法，零依赖** | oicq `lib/wtlogin/` 全为 JS；本 APK 无 `libfekit.so` |
| 中期 | 纯 JS 的 **T544** | Icalingua fork 新增 `lib/wtlogin/t544.js`（59.5 KB 纯 JS） |
| 8.9.x+ | 外部签名服务（qsign） | Icalingua fork 新增 `lib/qsign-api.js`；`libfekit.so` 出现 |

另：8.9.50 比 8.2.11 多两个风控库（`libturingga.so` / `libturingmfa.so`），
说明设备指纹校验是后来才严格的。

---

## 八、参照物：oicq 源码

`takayama-lily/oicq@master` 的 `lib/`（36 个文件）中与登录/协议直接相关的：

| 文件 | 大小 | 内容 |
|---|---:|---|
| `lib/wtlogin/ecdh.js` | 513 B | **ECDH（含服务端公钥硬编码）** |
| `lib/wtlogin/tlv.js` | 10,338 B | TLV 构造 |
| `lib/wtlogin/wt.js` | 14,838 B | WLogin 主流程 |
| `lib/wtlogin/login-password.js` | 7,152 B | 密码登录 |
| `lib/wtlogin/login-qrcode.js` | 7,877 B | 扫码登录 |
| `lib/wtlogin/writer.js` | 1,934 B | 缓冲区写入 |
| `lib/algo/tea.js` | 3,228 B | TEA |
| `lib/algo/jce/jce.js` | 9,612 B | JCE 序列化 |
| `lib/algo/pb.js` | 3,780 B | protobuf |
| `lib/device.js` | 5,245 B | **设备信息与 apk 参数表** |

服务端 ECDH 公钥（旧协议，供 8.2.11 使用）：

```
04EBCA94D733E399B2DB96EACDD3F69A8BB0F74224E2B44E3357812211D2E62EF
BC91BB553098E25E33A799ADC7F76FEB208DA7C6522CDB0719A305180CC54A82E
```

---

## 九、产物位置（工作区内）

```
apk-analysis/
├── lib/arm64-v8a/          提取的 4 个 native 库
├── dex/                    classes.dex / classes8.dex / classes11.dex
├── jadx-main/              classes.dex 的反编译输出（AppSetting、WtloginHelper 在此）
├── jadx11/                 classes11.dex 的反编译输出（CKeyFacade 在此）
├── jadx8/                  classes8.dex 的反编译输出
├── ckey_strings.txt        libckeygenerator.so 的字符串
├── scan_dex.py             dex 关键类定位
├── extract_apkinfo.py      版本 + 证书哈希提取
├── extract_qua.py          qua / 版本串提取
└── verify_sign.py          sign 字段验证
```

---

## 十、待确认（已全部闭环）

| 项 | 结论 |
|---|---|
| **`versionCode`** | **`1380`** —— 由 `AndroidManifest.xml` 解码确认，与 qua 中的 `_1380_` 一致 |
| **`sdkver`** | **`6.0.0.2423`** —— 在 `classes.dex` 中找到；oicq 表里 8.4.1 为 `6.0.0.2428`，模式吻合 |
| **`sigmap` 字段对应关系** | 已确认，见下 |

### `sigmap` 字段的对应关系（从 oicq `lib/wtlogin/tlv.js` 读出）

```js
.writeU32(this.apk.sigmap);   // → WLogin 的 mMainSigMap，写入 TLV 0x106
.writeU32(this.apk.bitmap)    // → WLogin 的 mMiscBitmap
.writeU32(0x10400)            // → WLogin 的 mSubSigMap（参考实现硬编码）
```

| oicq 字段 | WLogin 参数 | QQ 8.2.11 实测值 |
|---|---|---|
| `sigmap` | `mMainSigMap` | `16724722` |
| `bitmap` | `mMiscBitmap` | `150470524` |
| （硬编码 `0x10400`） | `mSubSigMap` | `66560` = `0x10400` ✓ **数值完全一致** |

**注意**：oicq 的 `apk[1]`（android phone）记录的是 8.4.1 的值
（`sigmap=34869472, bitmap=184024956`），与 8.2.11 不同；
但 `bitmap=150470524` 那条（oicq 标为 aPad）与 8.2.11 一致。
`mSubSigMap` 则跨版本稳定。

---

## 十一、参数表最终版（可直接写进代码）

```dart
versionName   = "8.2.11"
appVersion    = "8.2.11.4530"
versionCode   = 1380
fullVersion   = "8.2.11.4530.2020-12-25.0153f87a.GoogleMarket"
qua           = "V1_AND_SQ_8.2.11_1380_GM_D"
packageName   = "com.tencent.mobileqq"
appId         = 16
subAppId      = 537064117
appSign       = a6b745bf24a2c277527716f6f36eb68d
miscBitmap    = 150470524
mainSigMap    = 16724722
subSigMap     = 66560
sdkVersion    = "6.0.0.2423"
protocolVersion = 8001
```

已落地为 `lib/kernel/wlogin8/qq8_config.dart`，配套自测
`tool/qq8_selftest.dart`。
