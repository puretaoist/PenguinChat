# PC NTLogin 协议规格（自实现研究线）

> 日期：2026-11-08
> 来源：Acidify（LagrangeDev/acidify，GPL-3.0）源码逆向 + 本项目 9.3.60 APK 交叉验证
> 用途：这是**替代 Android wtlogin 路线**的完整技术规格。所有字段号、常量、流程都逐项核过。

---

## 0. 一句话：为什么走 PC 协议

QQ 有**两套登录协议**：

| | Android（手机 QQ） | PC（NTQQ） |
|---|---|---|
| 协议 | `wtlogin.login` + TLV | `trpc.login.ecdh.EcdhService.*`（NTLogin） |
| 设备证明 | **需要 `0x544` + `0x553`**（libfekit/libpoxy native） | **不需要** |
| 我们能否纯软件实现 | ❌ 卡 native | ✅ **Acidify 已证明可以** |
| ssoVer 代际墙 | ≥18 一律 type=45 | 不同协议栈，墙不同 |

**结论：Android 路线必须签名服务（qsign），PC 路线不需要。这是唯一纯软件可行的方向。**

---

## 1. KeyExchange（登录第一步）

命令字：`trpc.login.ecdh.EcdhService.SsoKeyExchange`
加密：`EncryptType.WithEmptyKey`（=2，见 §3）

### 1.1 常量（已验证）

| 常量 | 长度 | 校验 | 位置 |
|---|---|---|---|
| `serverPublicKey` | 65 字节 | 首字节 **0x04**，在 P-256 曲线上 | `lib/kernel/wlogin8/pc/pc_key_exchange.dart` |
| `verifyHashKey` | 32 字节 | — | 同上 |

⚠️ **不要从屏幕抄这两个常量**。本环境的终端编码会把 hex 显示错（`04` 显示成 `2c`）。
用 `tool/tmp/fix_pc_consts.py` 从 GitHub API 精确提取并校验。

### 1.2 流程

```
① 客户端生成 P-256 密钥对 (priv, publicKey[65B])
② sharedKey = ECDH(priv, serverPublicKey)      → 32 字节原始秘密，不 MD5
③ secret    = AES-GCM( pb{1:uin, 2:guid}, sharedKey )
④ verifyPkt = publicKey ‖ i32be(1) ‖ secret ‖ i32be(0) ‖ u32be(timestamp)
⑤ verifyHash= AES-GCM( SHA256(verifyPkt), verifyHashKey )
⑥ 请求 = KeyExchangeRequest{ 1:publicKey, 2:type=1, 3:secret, 4:timestamp, 5:verifyHash }
⑦ 响应 = KeyExchangeResponse{ 1:secret, 2:field2, 3:publicKey }   ← publicKey 在 3！
   sharedKey2 = ECDH(同一个 priv, response.publicKey)
   secret2    = AES-GCM.decrypt(response.secret, sharedKey2)
              = KeyExchangeResponseSecret{ 1:sessionKey, 2:sessionTicket, 3:expiration }
```

### 1.3 AES-GCM 信封格式

`IV(12) ‖ ciphertext ‖ tag(16)`。出处：Acidify `AesGcmProvider.kt`。

---

## 2. NTLogin.EasyLogin（免密续期）

命令字：`trpc.login.ecdh.EcdhService.SsoNTLoginEasyLogin`
异常设备：`...SsoNTLoginEasyLoginUnusualDevice`
加密：`WithEmptyKey`

### 2.1 请求

```
NTLoginForwardRequest {
    1: sessionTicket     ← KeyExchange 拿到
    3: buffer            ← AES-GCM(NTLoginCommon, sessionKey)   ← buffer 在 3！
    4: type = 1
    5: secBuffer
}

NTLoginCommon {
    1: head {
        1: userInfo   { 1: account(uin 字符串), 2: countryCode }
        2: clientInfo { 1: deviceType, 2: deviceName, 3: platform(int),
                        4: guid(bytes), 5: pubno, 6: clientVer, 7: clientType, 8: ssoVer }
        3: appInfo    { 1: version(kernel), 2: appId, 3: appName,
                        4: clientA1Version, 5: qua }
        4: errorInfo
        5: cookie     { 1: cookieContent }
        7: sdkInfo    { 1: version = 1 }      ← sdkInfo 在 7
    }
    2: body  = NTLoginEasyLoginReqBody{ 1: encryptedA1 }
}
```

### 2.2 响应

```
NTLoginEasyLoginRspBody {
    1: tickets    { 3: a1, 4: a2, 5: d2, 6: d2Key }   ← 字段号 3/4/5/6
    2: secCheck
    3: secProtect { 1: newDeviceCheckSig, 2: unusualDeviceCheckSig,
                    3: unusualDeviceQrSig, 4: uinToken }
}
// errCode == 140022011 → UnusualDevice，需扫二维码验证
```

### 2.3 QUA 格式（PC）

```
V1_WIN_NQ_{version}_GW_B    Windows
V1_MAC_NQ_{version}_GW_B    macOS
V1_LNX_NQ_{version}_GW_B    Linux
platform: windows=4, mac=5, linux=7
```

---

## 3. SSO 信封（Protocol 12）

连接：`msfwifi.3g.qq.com:8080`

### 3.1 EncryptType

```kotlin
None(0), WithD2Key(1), WithEmptyKey(2)
```

- `WithD2Key` → `TEA.encrypt(sso, d2Key)`
- `WithEmptyKey` → `TEA.encrypt(sso, ByteArray(16))`  ← **16 个零字节作密钥**
- `None` → 不加密

### 3.2 请求包结构（Protocol 12）

```
u32(含自身) {
    int protocol = 12
    byte encryptType
    bytes(含自身) d2 或 空
    byte 0
    string(含自身) uin
    u32(含自身) {
        int sequence           // 初值 Random(0x10000, 0x20000)，每个请求 +1
        int subAppId
        int 2052               // locale id
        bytes 固定 12 字节: 02 00 00 00 00 00 00 00 00 00 00 00
        bytes(含自身) a2
        string(含自身) command
        bytes(含自身) 空
        string(含自身) guid.toHexString()
        bytes(含自身) 空
        string(u16含自身) currentVersion
        bytes(含自身) ssoReserved(pb)
    }
    bytes(含自身) payload
}
```

`ssoReservedMsgType` 默认 **32**；`HeartBeat.Alive` 不需要签名。

### 3.3 响应解析

```
protocol(u32) ‖ authFlag(byte) ‖ dummy(byte) ‖ uin(string,u32含) ‖ encrypted(bytes)
  → 按 authFlag TEA 解密
  → headLen(u32) ‖ sequence(u32) ‖ retCode(int) ‖ extra(str) ‖ command(str)
    ‖ messageCookie(bytes) ‖ isCompressed(int) ‖ reserved(bytes) ‖ payload(bytes)
  → isCompressed == 1 时 payload 用 **gzip** 解压
```

---

## 4. 扫码登录（第 2 步，`wtlogin.trans_emp`）

> 注意：扫码**不走 NTLogin（trpc），走旧 `wtlogin.trans_emp`**。
> 但它和 Android 的 wtlogin 不同：**内层多一层 TEA，曲线是 secp192k1**。

### 4.1 双层加密（关键，别只做一层）

```
外层 SSO：EncryptType.WithEmptyKey → TEA(sso, 16零字节)   ← 与 §3 相同
内层 wtlogin：TEA(payload, shareKey)                      ← 新增！
  shareKey = MD5( ECDH(secp192k1, secp192k1BobPublicKey) )   ← hash=true
```

**曲线是 secp192k1（不是 P-256！）**。固定公钥（49 字节未压缩点）：
```
04928D8850673088B343264E0C6BACB8496D697799F37211DEB25BB73906CB089FEA9639B4E0260498B51A992D50813DA8
```

### 4.2 外层 wtlogin 包结构

**注意：真正被 TEA 加密的是 `packet`，不是 `requestBody`。这两层都要有。**

```
packet（加密对象）=
    u8 0x00                      // encryptMethod = EM_ST / EM_ECDH_ST
    u16 requestBody.size         // 裸长度
    u32 appId
    u32 0x72                     // Role
    u16 0                        // uSt（u16|LENGTH_ONLY 空）
    u8 0                         // rollback（u8|LENGTH_ONLY 空）
    requestBody

requestBody =
    u32 now(epochSeconds)
    u8 0x02                      // packet start
    u16 (43 + tlvPack.size + 1)  // head_len
    u16 transEmpSubCmd           // 0x31 = FetchQRCode
    bytes 21                     // 固定 21 字节
    u8 0x03
    u16 0x00                     // close
    u16 0x32                     // version code 50
    u32 0                        // trans_emp sequence
    u64 0                        // dummy uin
    bytes tlvPack                // 7 个扫码 TLV 包
    u8 0x03
```

然后 `TEA.encrypt(packet, shareKey)` 得到密文，再套外层 wtlogin 头：

```
u8 2
u16(含自身, addition=1 → 内容+3) {
    u16 8001; u16 2066(wtlogin.trans_emp); u16 0(sequence);
    u32 uin; u8 3(extVer); u8 135(cmdVer); u32 0;
    u8 19(pubId); u16 0(insId); u16 appClientVersion; u32 0(retryTime);
    u8 1; u8 1; bytes(16 随机); u16 0x102;
    bytes(TEA密文, u16裸长度);   // 注意这里要带 u16 裸长度
    u8 3
}
```

⚠️ **第一版漏了 `packet` 这层，导致服务端静默丢弃（超时）。补上后 retCode=0。**

### 4.3 FetchQRCode（subCmd 0x31）

请求 payload：
```
u16 0; u32 appId; u64 0(uin); bytes(空); u8 0; bytes(空,u16长);
TLV 包: 0x16, 0x1b, 0x1d, 0x33, 0x35, 0x66, 0xD1
```
响应：
```
u8(丢弃); bytes(u16长)=qrSig; TLV;
  qrCodeUrl/qrCodeString = tlv[0xD1].pbDecode()
  qrCodePng = tlv[0x17]
```

### 4.4 QueryQRCodeState（subCmd 0x12）

请求 payload：
```
u16 0; u32 appId; bytes(qrSig,u16长); u64 0; u8 0; bytes(空,u16长); u16 0(tlv数量)
```
响应：
```
u8 state; 
  若 CONFIRMED(0x30?)：discard(4) u32 uin discard(4) TLV →
    tgtgt=tlv[0x1e], encryptedA1=tlv[0x18], noPicSig=tlv[0x19]
  否则 state 表示 未扫/已扫未确认/过期/取消
```

### 4.5 PCLogin（`wtlogin.login` subCmd 9，扫码确认后取票）

TLV 列表：`0x106(A2), 0x144, 0x116, 0x142, 0x145, 0x18, 0x141, 0x177,
0x191, 0x100, 0x107, 0x318, 0x16a, 0x166, 0x521`

响应 state==0：`TEA.decrypt(tlv[0x119], tgtgt)` → 内部 TLV：
`d2Key=tlv[0x305], uid=tlv[0x543].pb, a2=tlv[0x10A], d2=tlv[0x143],
encryptedA1=tlv[0x106]`
state!=0：`tlv[0x146]` = `int code ‖ (u16)tag ‖ (u16)message`

### 4.6 待补依赖

- `secp192k1` ECDH（pointycastle 有 `ECCurve_secp192k1`）
- 扫码 TLV：`0x16/0x1b/0x1d/0x33/0x35/0x66/0xD1` 的结构（在 Acidify `buildTlvQRCode`）
- `0xD1` 的 pb（qrCodeUrl / qrCodeString）
- 通用 `readTlv` 解析

---

## 5. 已实现 / 未实现

| 模块 | 状态 | 位置 |
|---|---|---|
| protobuf 编解码 | ✅ | `lib/kernel/wlogin8/pc/pc_proto.dart` |
| P-256 ECDH（原始秘密）+ AES-GCM + SHA256 | ✅ | `lib/kernel/wlogin8/pc/pc_crypto.dart` |
| KeyExchange 构造/解析 | ✅ | `lib/kernel/wlogin8/pc/pc_key_exchange.dart` |
| KeyExchange 自测（23 项） | ✅ | `tool/pc_key_exchange_selftest.dart` |
| SSO 发送层（Protocol 12） | ⬜ | 待写 |
| 扫码 FetchQRCode / QueryQRCodeState | ⬜ | 待写 |
| EasyLogin 续期 + 接长连接 | ⬜ | 待写 |

---

## 5. 两个坑（务必记住）

1. **终端 hex 显示不可信**：本环境 GBK/UTF-8 混用会把 `04` 显示成 `2c`。取二进制常量一律用脚本 + 程序内校验，不要肉眼抄。
2. **Acidify 只实现了 PC 的扫码 + EasyLogin，没实现 PasswordLogin**：不是协议没有（`SsoNTLoginPasswordLogin` 存在），而是密码登录的 `loginContext` 由 native kernel 生成，纯软件难。若日后要密码登录，先啃 `PwdLoginInfo.loginContext`。

### 4.7 AppInfo 真实值（Acidify `common/AppInfo.kt` Bundled）

**登录时必须用真实档案，不能猜。** 否则服务端静默丢弃（表现为超时）。

| 字段 | Linux_39038 | Mac_52892 |
|---|---|---|
| os | `Linux` | `Mac` |
| kernel | `Linux` | `Darwin` |
| vendorOs | `linux` | `macos` |
| currentVersion | `3.2.19-39038` | `7.0.1-52892` |
| miscBitmap | 32764 | 32764 |
| ptVersion | `2.0.0` | `2.0.0` |
| ssoVersion | **19** | 23 |
| packageName | `com.tencent.qq` | `com.tencent.qq` |
| wtLoginSdk | `nt.wtlogin.0.0.1` | `nt.wtlogin.0.0.1` |
| appId | **1600001615** | 1600001602 |
| subAppId | **537313942** | 537382843 |
| appClientVersion | **39038** | 52892 |
| mainSigMap | **169742560** | 169742560 |
| subSigMap | 0 | 0 |
| ntLoginType | 1 | 5 |

### 4.8 实现踩坑记录（2026-11-08 实战，5 类 bug）

按发生顺序，每一条都让服务端静默超时（20s 无响应）：

1. **参数用猜的** → `subAppId=0`、`mainSigMap=34869472`、`ssoVersion=22`、包名 `com.tencent.qqnt` 全错。**必须用 §4.7 真实值。**
2. **双层 subCmd 搞反** → 外层 wtlogin 包 subCmd 固定 **2066**（`wtlogin.trans_emp`），内层 `TransEmp.requestBody` 里才是 **0x31**（FetchQRCode）。
3. **缺 `TransEmp.requestBody` 整层** → 不能把 code2D body 直接拿去加密，必须套：
   `u32(now) ‖ u8(2) ‖ u16(43+tlv+1) ‖ u16(subCmd) ‖ 21字节 ‖ u8(3) ‖ u16(0) ‖ u16(0x32) ‖ u32(0) ‖ u64(0) ‖ tlvPack ‖ u8(3)`。
4. **`barrier(UINT16|INCLUDE, addition=1)` 的长度语义** → 写入值 = 内容 + addition + 2(含前缀) = **内容 + 3**，不是 +2。
5. **`writeBytes(空)` 是 0 字节**（裸写，不是写一个 0x00）；**SSO 头 guid 不能传全零**，要真实 guid。

### 4.9 当前状态（2026-11-08）

| 链路 | 状态 |
|---|---|
| KeyExchange（`SsoKeyExchange`） | ✅ **生死验证通过：纯 Dart 打真服务器 `retCode=0`，拿到 sessionKey(32B)+sessionTicket(95B)** |
| 扫码 FetchQRCode | ✅ **retCode=0，拿到真实二维码 URL**（`https://txz.qq.com/p?k=...`）——补上 §4.2 的 `packet` 包装层后打通 |

**下一步必须做确定性诊断**（不要再盲改）：
- 方案 A：抓官方 PC QQ 登录时的 `wtlogin.trans_emp` 包，与自实现逐字节 diff。
- 方案 B：克隆 Acidify 用 Kotlin 跑 FetchQRCode，抓它发出的字节对比。

### 4.10 已排除的组件（2026-11-08，8 次尝试后）

扫码仍超时，但以下组件都已**确定性验证为正确**，问题不在这些：

| 组件 | 验证方式 | 结果 |
|---|---|---|
| SSO Protocol 12 信封 | KeyExchange 用同一套打真服务器 | ✅ retCode=0 |
| TEA 加密 | 与 Acidify `TEA.kt` 逐行对比（填充/块链/轮数一致） | ✅ 一致 |
| **secp192k1 ECDH** | 纯 Python 独立实现 + 固定私钥对照（`tool/pc_secp192k1_vector_selftest.dart`） | ✅ 逐字节一致 |
| TLV 结构（7 个） | `tool/pc_qr_selftest.dart` 9 项 | ✅ |
| AppInfo 参数 | 用 Acidify 真实值（§4.7） | ✅ |
| uin=0 vs 10000 | 都试过 | 都超时，非此因 |

**结论：剩下的差异只可能在 `wtlogin.trans_emp` 包的某几个字节（字段顺序/长度/固定值），静态分析已到极限，必须抓包对比。**

---

## 6. 许可证

Acidify 是 **GPL-3.0**。本仓库**只借鉴协议结构与常量**（这些是 QQ 协议本身的事实，非 Acidify 的创作），代码用 Dart 独立重写，不复制其源码。
