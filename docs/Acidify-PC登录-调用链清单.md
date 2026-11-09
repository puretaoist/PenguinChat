# Acidify PC 登录调用链 · 全覆盖清单

> 用途：作为 PC NTLogin「扫码登录 + PCLogin + EasyLogin + 登录后长连接」转写为 Dart 的**源码级依据**，目标是「相关代码一个不漏」。
> 来源：`LagrangeDev/acidify`，本地克隆 `C:\temp\acidify`，`main` @ `bb32302fa7bb5c18b7de814e8c5a9430a01dbbbd`（2026-11-04）。
> 包根：`acidify-core/src/commonMain/kotlin/org/ntqqrev/acidify/`（下文路径均相对此目录，省略该前缀）。
> 覆盖范围：扫码登录链 + `KeyExchange` + `PCLogin` + `EasyLogin` + 登录后长连接（`Register`/`Alive`/`Heartbeat`/`UnRegister`）。**密码登录（`AndroidLogin`/`KuromeClient`）与 IM 业务（消息/好友/群）不在范围。**

> ⚠️ **关于 hex 常量**：本机终端/输出通道会把源码里的 hex 显示错（如 `04` 显示成 `2c`），与项目 `docs/PITFALLS.md` 记录同源。本文所有二进制常量均已用**程序内 `==` 比较**核实，绝不靠肉眼抄写。已确认：`KeyExchange.serverPublicKey`（65 字节，`0x04` 开头）与 `verifyHashKey`（32 字节）**与现有 Dart `pc_key_exchange.dart` 逐字节 SAME=true**。

---

## 1. 调用链总览

```
Bot.login()                                [LoginOps.kt]
 ├─ 有 a2         → onlineInternal()
 ├─ 有 encryptedA1 → renewSessionInternal()  → KeyExchange → NTLogin.EasyLogin → completeOnline()
 │                     └ 异常设备(140022011) → qrCodeLoginInternal(unusualSig)
 └─ 否则           → qrCodeLoginInternal()
        │
qrCodeLoginInternal()                      [LoginOps.kt]
 ① callService(WtLogin.TransEmp.FetchQRCode)                      → qrSig / qrCodeUrl / qrCodeString / qrCodePng
 ② loop callService(WtLogin.TransEmp.QueryQRCodeState)：
       Success(CONFIRMED=0)    → sessionStore{uin,tgtgt,encryptedA1,noPicSig} → break
       WAITING_FOR_CONFIRMATION(53) → HTTP POST https://ntlogin.qq.com/qr/getFace
       EXPIRED(17)/CANCELLED(54)/UNKNOWN → throw；delay(queryInterval≥1000ms, 默认 3000)
 ③ unusualSig==null → callService(WtLogin.PCLogin)         → {d2Key,uid,a2,d2,encryptedA1}
                     → sessionStore.uid=uid; updateCredentials(encryptedA1,a2,d2,d2Key)
    unusualSig!=null → callService(NTLogin.UnusualEasyLogin) → tickets{a1,a2,d2,d2Key}
 ④ onlineInternal() → sendOnlinePacket()=BotOnline(Register) + doPostOnlineLogic() → completeOnline()
```

**登录后的长连接（`PacketContext`）**：建立 TCP `msfwifi.3g.qq.com:8080` → 4 字节大端长度分帧 → `SsoCodec` 编解码。上线后 `postOnline()` 起心跳：每 **10s** 发一次 `Alive`，每 **27 次**（即 270s）发一次 `Heartbeat`。心跳返回非 0 retCode 视作掉线。

---

## 2. 文件全覆盖清单（按层）

### 2.1 入口 / 编排层
| 文件 | 关键内容 | 与 Dart 关系 |
|---|---|---|
| `LoginOps.kt` | `Bot.qrCodeLogin` / `qrCodeLoginInternal` / `renewSession` / `renewSessionInternal` / `Bot.login` / `AndroidBot.passwordLogin`(不在范围) | **待转写**（登录总流程） |
| `SystemOps.kt` | `online` / `onlineInternal` / `completeOnline` / `offline`(L79) | **待转写**（上线收尾） |
| `AbstractBot.kt` / `Bot.kt` | 宿主属性：`loginMutex`、`sharedEventFlow`、`client`、`sessionStore`、`appInfo`、`isLoggedIn`、`eventCollectJob`、`transformers`、`faceDetailRefreshJob` | 参照（客户端宿主管理） |

### 2.2 服务层（SSO 命令实现）
| 文件 | 类 / object | 命令字 | 说明 |
|---|---|---|---|
| `internal/service/system/WtLogin.kt` | `WtLogin<T,R>` 抽象基类 | — | 内层 TEA(secp192k1 shareKey)+外层 2064/2066 头；`build`/`parse` 见 §3.1 |
| 同上 | `WtLogin.TransEmp` 抽象 | `wtlogin.trans_emp`(2066) | 扫码子命令；`buildWtLoginPayload` 加 `requestBody`+`packet` 双层（§3.2） |
| 同上 | `WtLogin.TransEmp.FetchQRCode` | subCmd **0x31** | 取码；7 TLV；响应解 `qrSig`+`TlvQRCodeBodyD1Resp`(url/string)+`0x17`(png) |
| 同上 | `WtLogin.TransEmp.QueryQRCodeState` | subCmd **0x12** | 轮询；CONFIRMED 时 `discard(4)+u32(uin)+discard(4)+TLV{0x1e tgtgt,0x18 encA1,0x19 noPicSig}` |
| 同上 | `WtLogin.Login<T,R>` 抽象 | `wtlogin.login`(2064) | payload=`u16(internalCmd)+tlvPack`（无 requestBody/packet 层） |
| 同上 | `WtLogin.PCLogin` | internalCmd **9** | 15 TLV（§4.1）；解析 `tlv119=TEA.decrypt(·, sessionStore.tgtgt)` |
| 同上 | `WtLogin.AndroidLogin` 系列 | 0x09/0x02/0x08/0x07 | 密码登录（**排除**） |
| `internal/service/system/NTLogin.kt` | `NTLogin<T,R>` 抽象 | — | trpc NTLogin 信封（§3.3）；EncryptType.WithEmptyKey |
| 同上 | `NTLogin.EasyLogin` | `trpc.login.ecdh.EcdhService.SsoNTLoginEasyLogin` | A1 换票；结果 Success/UnusualDevice(140022011)/Failure |
| 同上 | `NTLogin.UnusualEasyLogin` | `...SsoNTLoginEasyLoginUnusualDevice` | 异常设备后换票 |
| `internal/service/system/KeyExchange.kt` | `KeyExchange` | `trpc.login.ecdh.EcdhService.SsoKeyExchange` | P-256 ECDH → sessionTicket/sessionKey（§3.4） |
| `internal/service/system/Alive.kt` | `Alive` | `Heartbeat.Alive` | `RequestType.Simple`+`EncryptType.None`，payload=`[0,0,0,4]`，**走 protocol13** |
| `internal/service/system/Heartbeat.kt` | `Heartbeat` | `trpc.qq_new_tech.status_svc.StatusService.SsoHeartBeat` | `SsoHeartBeat(type=1).pbEncode()` |
| `internal/service/system/BotOnline.kt` | `BotOnline` | `trpc.qq_new_tech.status_svc.StatusService.Register` | `RegisterInfo{guid hex, currentVersion, device, businessInfo{1,1}}`；响应 `message=="register success"` |
| `internal/service/system/BotOffline.kt` | `BotOffline` | `trpc.qq_new_tech.status_svc.StatusService.UnRegister` | `UnRegisterInfo{device}` |

### 2.3 TLV 层
| 文件 | 内容 |
|---|---|
| `internal/tlv/TlvBuilder.kt` | `writeTlv(tag){body}` = `u16(tag)+u16(len)body`；`build()` = `u16(tlvCount)+全部` |
| `internal/tlv/Tlv.kt` | PCLogin 的 15 个 TLV：`tlv18/100/106A2/107/116/124/128/141/142/144/145/147/166/16a/16e/177/191/318/521`（§4.1） |
| `internal/tlv/TlvQRCode.kt` | 扫码 7 TLV：`tlv11(unusualSig)/16/1b/1d/33/35/66/D1`（§4.2） |
| `internal/tlv/AndroidTlv.kt` | 密码登录 TLV（**排除**） |

### 2.4 proto 层（kotlinx ProtoBuf，字段号即 `@ProtoNumber`）
| 文件 | 关键类 |
|---|---|
| `internal/proto/login/NTEcdh.kt` | `KeyExchangeRequest/Response/RequestBuf/ResponseSecret`、`NTLoginForwardRequest`（§5.1） |
| `internal/proto/login/NTLogin.kt` | `NTLoginCommon/Head/UserInfo/ClientInfo/AppInfo/SdkInfo/Cookie/ErrorInfo/Tickets/SecCheck/SecProtect/EasyLoginReqBody/RspBody/Unusual...`（§5.2） |
| `internal/proto/login/TlvBody543.kt` | `TlvBody543{9→Layer1{11→Layer2{1→uid}}}` |
| `internal/proto/login/TlvQRCodeBodyD1.kt` | `Req{1 system{1 os,2 deviceName}, 4 typeBuf}` / `Resp{2 qrCodeUrl, 3 qrCodeString}` |
| `internal/proto/system/SsoReservedFields.kt` | `15 trace,16 uid?,21 msgType?,24 secureInfo?,26 ntCoreVersion?` |
| `internal/proto/system/SsoSecureInfo.kt` | `1 sign,2 token,3 extra` |
| `internal/proto/system/SsoHeartBeat.kt` | `1 type` |
| `internal/proto/system/RegisterInfo.kt` | `1 guid,2 kickPc?,3 currentVersion,4 isFirstRegisterProxyOnline?,5 localeId?,6 device,7 setMute?,8 registerVendorType?,9 regType?,10 businessInfo,11 batteryStatus?` |
| `internal/proto/system/DeviceInfo.kt` | `1 devName,2 devType,3 osVer,4 brand?,5 vendorOsName` |
| `internal/proto/system/OnlineBusinessInfo.kt` | `1 notifySwitch,2 bindUinNotifySwitch` |
| `internal/proto/system/RegisterInfoResponse.kt` | `2 message` |

### 2.5 传输 / 客户端层
| 文件 | 关键内容 |
|---|---|
| `internal/context/PacketContext.kt` | TCP 连接管理 + `SsoCodec`（protocol12/13 编解码、gzip）+ 心跳循环（§3.5） |
| `internal/AbstractClient.kt` | `callService()`：seq 自增→`build`→`sendPacket`→retCode≠0 抛`ServiceException`→`parse`；`ssoReservedMsgType` 默认 32；`criticalCommand`={wtlogin.trans_emp, wtlogin.login, MessageSvc.PbSendMsg}（签名失败必须即时抛） |
| `internal/LagrangeClient.kt` | 属性全部来自 `appInfo`/`sessionStore`；`getSsoSecureInfo=signProvider.sign`；`sendOnlinePacket=callService(BotOnline)` |
| `common/SessionStore.kt` | 字段见 §8.1 |
| `internal/context/TicketContext.kt` | 登录后 SKey/PSKey/CsrfToken（HTTP 侧，长连接 postOnline 触发取 SKey） |
| `internal/context/AbstractContext.kt` | `postOnline()/preOffline()` 抽象（10 行） |

### 2.6 密码学层
| 文件 | 内容 |
|---|---|
| `internal/crypto/ecdh/Ecdh.kt` / `EcdhProvider.kt` / `EllipticCurve.kt` / `EllipticPoint.kt` | 自实现 ECDH（§6.1） |
| `internal/crypto/aes/AesGcmProvider.kt` | AES-GCM 信封 `IV(12)+ct+tag(16)` |
| `internal/crypto/tea/TEA.kt` | 标准腾讯 TEA（QQ 变种） |
| `internal/crypto/hash/SHA256.kt` / `MD5.kt` | 哈希 |

### 2.7 工具层
| 文件 | 内容 |
|---|---|
| `internal/util/BinaryReader.kt` | 大端读取 + `Prefix` 位编码 + `readPrefixedBytes/String`（§8.2） |
| `internal/util/BinaryExt.kt` | `readTlv()`/`parseTlv()`/`barrier(prefix,addition)`/`writeString`/`writeBytes`（§8.2） |
| `internal/util/ProtobufExt.kt` | `pbEncode/pbDecode`（kotlinx ProtoBuf 默认配置） |
| `internal/util/GenerateTrace.kt` | trace = `"00-"+32hex+"-"+16hex+"-01"`（55 字符） |
| `internal/util/GenerateDeviceInfo.kt` | `DeviceInfo{devName=deviceName, devType=kernel, osVer=平台映射, vendorOsName=vendorOs}` |
| `internal/util/ContractHook.kt` | `ensureLagrange()`/`ensureKurome()`（类型断言，非 Lagrange 直接抛） |
| `internal/util/ServiceExt.kt` | `buildTlv()`/`buildTlvQRCode()` DSL |
| `internal/util/StringExt.kt` | `toHexString`/`hexToByteArray` 等 |
| `common/AppInfo.kt` | 客户端档案（§7） |
| `struct/QRCodeState.kt` / `internal/service/EncryptType.kt` / `RequestType.kt` | 枚举（§8.3） |

### 2.8 异常层（`exception/`，登录链会抛的）
| 文件 | 触发点 |
|---|---|
| `WtLoginException.kt` | PCLogin `state!=0`(tlv146)、EasyLogin Failure → `WtLoginException(code, tag, message)` |
| `ServiceException.kt` | `callService` 中 SSO `retCode!=0` |
| `ServiceInternalException.kt` | `ServiceExt.checkRetCode` |
| `SessionRenewalException.kt` | `renewSessionInternal` 失败/需异常设备（`unusualSig`） |
| `BotOnlineException.kt` | `BotOnline` 响应 `message != "register success"` |
| `UnstableNetworkException.kt` | 密码登录 tlv146 code=237（不在范围，参考） |

---

## 3. 传输层与各命令的字段级规格

### 3.1 WtLogin 基类（`WtLogin.kt`）
- 内层密钥：`secp192k1` 随机密钥对；`shareKey = MD5(ECDH(secp192k1, bobPub))`（= `Ecdh.keyExchange(..., true)`，16 字节）。
- **build**：
  ```
  u8(2)
  barrier(UINT_16|INCLUDE_PREFIX, addition=1) {   // 写入长度 = 内容 + 1 + 2 = 内容+3
     u16 8001; u16 wtLoginSubCmd; u16 0; u32 uin;
     u8 3; u8 135; u32 0; u8 19; u16 0; u16 appClientVersion; u32 0;
     u8 1; u8 1; 16×random; u16 0x102;
     bytes(u16|LENGTH_ONLY) secp192k1公钥(压缩25B);
     bytes TEA.encrypt(payload, shareKey);   // 裸写
     u8 3
  }
  ```
- **parse**：`u8 header(须=0x02) ‖ skip(15) ‖ TEA.decrypt(余-1, shareKey) ‖ u8(须=0x03)` → `parseWtLoginPayload`。
- 注意：head 里**没有 appId/subAppId**（只在 AppInfo TLV 里出现）。

### 3.2 TransEmp 双层（扫码）
- `buildWtLoginPayload`：先 `buildCode2DPayload` 得 tlvPack，再套：
  ```
  requestBody = u32(nowSec) u8(0x2) u16(43+tlv+1) u16(subCmd) 21×0 u8(0x3) u16(0) u16(0x32) u32(0) u64(0) tlvPack u8(0x3)
  packet      = u8(0) u16(requestBody.len) u32(appId) u32(0x72) bytes0(u16|LEN) bytes0(u8|LEN) requestBody
  ```
  加密对象是 **packet**（不是 requestBody）。
- `parseWtLoginPayload`：`u32(packetLength) discard(4) u16(command) discard(40) u32(appid)` → `parseCode2DPayload(rest)`。

### 3.3 NTLogin 信封（EasyLogin，`NTLogin.kt`）
- build：`NTLoginCommon{ head, body }` → `NTLoginForwardRequest{1:sessionTicket, 3:buffer=AesGcm(common.pbEncode(), sessionKey), 4:type=1}`（**5:secBuffer 不赋值**）。
  - `head.userInfo{1:account=uin字符串}`；
  - `head.clientInfo{1:deviceType=os, 2:deviceName, 3:platform(int), 4:guid}`（pubno/clientVer/clientType/ssoVer 用默认 0）；
  - `head.appInfo{1:version=kernel, 2:appId, 3:appName=packageName, 5:qua}`；
  - `head.cookie{1:cookieContent=unusualCookies}`；`head.sdkInfo{1:version=1}`；
  - `body = NTLoginEasyLoginReqBody{1:a1=encryptedA1}`。
- parse：`forward=pbDecode<NTLoginForwardRequest>`；`common=AesGcm.decrypt(forward.buffer, sessionKey).pbDecode<NTLoginCommon>`；cookie 更新；再按 `head.errorInfo.errCode` 分支。
- **qua** = `V1_{WIN|MAC|LNX}_NQ_{currentVersion.replace("-","_")}_GW_B`。
- **platform**：windows=4 / mac=5 / linux=7 / else 0。

### 3.4 KeyExchange（`KeyExchange.kt`）
- `publicKey = prime256V1.packPublic(false)`（65B，`0x04`）；`sharedKey = keyExchange(serverPublicKey, false)`（32B 原始 X）；
- `secret = AesGcm(KeyExchangeRequestBuf{1:uin,2:guid}, sharedKey)`；
- `verifyPacket = publicKey ‖ i32(1) ‖ secret ‖ i32(0) ‖ u32(timestamp)`；
- 请求 `KeyExchangeRequest{1:publicKey,2:type=1,3:secret,4:timestamp,5:verifyHash}`；
- 响应 `KeyExchangeResponse{1:secret,2:field2,3:publicKey}` → `sharedKey2=keyExchange(resp.publicKey,false)` → `KeyExchangeResponseSecret{1:sessionKey,2:sessionTicket,3:expiration}`。

### 3.5 SsoCodec（`PacketContext.kt`）
- **protocol12（D2Auth）**：
  ```
  barrier(UINT32|INCLUDE) {
    i32(12); u8(encryptType); bytes(d2 或 空, UINT32|INCLUDE); u8(0);
    string(uin, UINT32|INCLUDE);
    sso = barrier(UINT32|INCLUDE){
       i32(sequence); i32(subAppId); i32(2052); 12字节固定(02 00…);
       bytes(a2, UINT32|INCLUDE); string(command, UINT32|INCLUDE);
       bytes(空, UINT32|INCLUDE); string(guidHex大写, UINT32|INCLUDE);
       bytes(空, UINT32|INCLUDE); string(currentVersion, UINT16|INCLUDE);
       bytes(ssoReserved, UINT32|INCLUDE)
    } + bytes(payload, UINT32|INCLUDE)
    → writeEncrypted：None 原样；WithD2Key→TEA(d2Key)；WithEmptyKey→TEA(16零字节)
  }
  ```
- **protocol13（Simple，仅 Alive 用）**：
  ```
  barrier(UINT32|INCLUDE){
    i32(13); u8(encryptType); i32(sequence); u8(0); string(uin, UINT32|INCLUDE);
    sso = barrier(UINT32|INCLUDE){ string(command,UINT32|INCLUDE); i32(4); bytes(ssoReserved,UINT32|INCLUDE) } + bytes(payload,UINT32|INCLUDE)
    → writeEncrypted 同上
  }
  ```
- **decode**：`u32 protocol ‖ u8 authFlag ‖ u8 dummy ‖ string(uin,UINT32|INCLUDE) ‖ 密文 → 按 authFlag 解密 → u32 headLen ‖ u32 seq ‖ i32 retCode ‖ string extra ‖ string command ‖ bytes cookie ‖ i32 isCompressed ‖ bytes reserved(UINT32裸) ‖ bytes payload`；`isCompressed==1` 时 payload gzip 解压。
- 心跳循环：`postOnline()` → `startHeartbeat`：每 10s `Alive`；`aliveCount%27==0` 发 `Heartbeat` 并清零。retCode≠0 → 发 `BotOfflineEvent` 并停。

---

## 4. TLV 字段级规格

### 4.1 PCLogin 15 TLV（`Tlv.kt`，顺序即构建顺序；包前 `u16(count=15)`）
| Tag | 内容 |
|---|---|
| 0x106 | `bytes(encryptedA1)`（裸写） |
| 0x144 | `TEA.encrypt( tlv16e ‖ tlv147 ‖ tlv128 ‖ tlv124 , sessionStore.tgtgt )` |
| 0x116 | `u8(0) u32(12058620) i32(subSigMap) u8(0)` |
| 0x142 | `u16(0) str16(packageName)` |
| 0x145 | `bytes(guid)` |
| 0x18 | `u16(0) u32(5) u32(0) u32(8001) u32(uin) u16(0) u16(0)` |
| 0x141 | `str32("Unknown") u32(0)` |
| 0x177 | `u8(1) u32(0) str16(wtLoginSdk)` |
| 0x191 | `u8(0)` |
| 0x100 | `u16(0) u32(5) i32(appId) i32(subAppId) i32(appClientVersion) i32(mainSigMap)` |
| 0x107 | `u16(1) u8(0x0d) u16(0) u8(1)` |
| 0x318 | 空 |
| 0x16a | `bytes(noPicSig)` |
| 0x166 | `u8(5)` |
| 0x521 | `u32(0x13) str16("basicim")` |

内部 TLV（供 0x144）：
- `0x16e`：`str(deviceName)`（裸写，无长度前缀）
- `0x147`：`i32(appId) str16(ptVersion) str16(packageName)`
- `0x128`：`u16(0) u8(0) u8(0) u8(0) u32(0) str16(os) bytes16(guid) str16("")`
- `0x124`：`12×0`

PCLogin 响应解析：`u16(command) u8(state) TLV`；`state==0` → `tlv119 = TEA.decrypt(tlvPack[0x119], sessionStore.tgtgt)` → 内部 TLV：
`d2Key=0x305, uid=TlvBody543(9→11→1), a2=0x10A, d2=0x143, encryptedA1=0x106`；
`state!=0` → `tlv146: i32(code) str16(tag) str16(message)` 抛 `WtLoginException`。

### 4.2 扫码 7 TLV（`TlvQRCode.kt`；包前 `u16(count)`）
| Tag | 内容 |
|---|---|
| 0x11 | `bytes(unusualSig)`（仅 unusualSig 非空时加） |
| 0x16 | `u32(0) i32(appId) i32(subAppId) bytes(guid) str16(packageName) str16(ptVersion) str16(packageName)` |
| 0x1b | `u32(0) u32(0) u32(3) u32(4) u32(72) u32(2) u32(2) u16(0)` |
| 0x1d | `u8(1) i32(mainSigMap) u32(0) u8(0)` |
| 0x33 | `bytes(guid)` |
| 0x35 | `i32(ssoVersion)` |
| 0x66 | `i32(ssoVersion)` |
| 0xD1 | pb `TlvQRCodeBodyD1Req{1:system{1:os,2:deviceName}, 4:typeBuf="3001"}` |

---

## 5. proto 字段号速查

### 5.1 `NTEcdh.kt`
- `KeyExchangeRequest`: 1 publicKey, 2 type, 3 secret, 4 timestamp, 5 verifyHash
- `KeyExchangeResponse`: 1 secret, 2 field2, 3 publicKey
- `KeyExchangeRequestBuf`: 1 uin(string), 2 guid
- `KeyExchangeResponseSecret`: 1 sessionKey, 2 sessionTicket, 3 expiration
- `NTLoginForwardRequest`: 1 sessionTicket, 3 buffer, 4 type, 5 secBuffer

### 5.2 `NTLogin.kt`
- `NTLoginCommon`: 1 head, 2 body(bytes)
- `NTLoginHead`: 1 userInfo, 2 clientInfo, 3 appInfo, 4 errorInfo?, 5 cookie, **7 sdkInfo**
- `NTLoginUserInfo`: 1 account, 2 countryCode
- `NTLoginClientInfo`: 1 deviceType, 2 deviceName, 3 platform, 4 guid, 5 pubno, 6 clientVer, 7 clientType, 8 ssoVer
- `NTLoginAppInfo`: 1 version, 2 appId, 3 appName, 4 clientA1Version, 5 qua
- `NTLoginSdkInfo`: 1 version
- `NTLoginCookie`: 1 cookieContent
- `NTLoginErrorInfo`: 1 errCode(ulong), 2 strTipsTitle, 3 strTipsContent
- `NTLoginTickets`: **3 a1, 4 a2, 5 d2, 6 d2Key**
- `NTLoginSecCheck`: 3 iframeUrl
- `NTLoginSecProtect`: 1 newDeviceCheckSig, 2 unusualDeviceCheckSig, 3 unusualDeviceQrSig, 4 uinToken
- `NTLoginEasyLoginReqBody`: 1 a1
- `NTLoginEasyLoginRspBody`: 1 tickets, 2 secCheck, 3 secProtect
- `NTLoginEasyLoginUnusualDeviceReqBody`: 1 a1, 2 unusualDeviceCheckSucceedSig
- `NTLoginEasyLoginUnusualDeviceRspBody`: 1 tickets

---

## 6. 密码学要点

### 6.1 ECDH（自实现，`EcdhProvider.kt`）
- `keyExchange(bobPub, isHash)`：`unpackPublic` → `shared = secret*bobPub`（double-and-add）→ `packShared`：
  - `packShared = isHash ? MD5(xBytes.copyOfRange(0, packSize)) : xBytes`
  - 即 **hash=true 时取共享点 X 坐标前 `packSize` 字节再 MD5**。
- `unpackPublic` 接受 `0x04`(未压缩, len=2*size+1) / `0x02|0x03`(压缩, len=size+1)。
- 曲线：
  - `secp192k1`: size=24, packSize=24（扫码用，`hash=true` → 16B shareKey）
  - `prime256v1`: size=32, **packSize=16**（KeyExchange 用，`hash=false` → 32B 原始 X）
- `packPublic(compress=true)` 压缩 25B（secp192k1）/ 33B（P-256）；`false` 未压缩 `0x04+…`。
- 常量（均以程序内 `==` 校验）：
  - `KeyExchange.serverPublicKey` 65B(`0x04`)、`verifyHashKey` 32B —— **与 Dart 一致**。
  - 扫码 `WtLogin.secp192k1BobPublicKey` 49B(`0x04`，未压缩 secp192k1 点)。

### 6.2 AES-GCM（`AesGcmProvider.kt`）
- `encrypt` 返回 `IV(12) ‖ ciphertext ‖ tag(16)`；`decrypt` 取前 12 IV、后 16 tag。

### 6.3 TEA（`TEA.kt`）
- 标准腾讯 TEA（16 轮、`0x9E3779B9`/delta 变体，含 `getCipherLength/getPlainLength`）。Dart 已有等价 `qqTeaEncrypt/Decrypt`（自测通过），可直接复用。

---

## 7. AppInfo 档案（`common/AppInfo.kt`）
字段：`os,kernel,vendorOs,currentVersion,miscBitmap,ptVersion,ssoVersion,packageName,wtLoginSdk,appId,subAppId,appClientVersion,mainSigMap,subSigMap,ntLoginType`。

| 档案 | os | currentVersion | ssoVersion | appId | subAppId | appClientVersion | ntLoginType |
|---|---|---|---|---|---|---|---|
| Linux_39038（=Linux 默认） | Linux | 3.2.19-39038 | 19 | 1600001615 | 537313942 | 39038 | 1 |
| Linux_46494 | Linux | 3.2.26-46494 | 19 | 1600001615 | 537345891 | 46494 | 1 |
| Mac_52194 | Mac | 7.0.0-52194 | 23 | 1600001602 | 537379435 | 52194 | 5 |
| Mac_52892（=Mac 默认） | Mac | 7.0.1-52892 | 23 | 1600001602 | 537382843 | 52892 | 5 |

> 现有 `docs/PC-NTLogin-协议规格.md §4.7` 只记录了 Linux_39038 与 Mac_52892，**漏了 Linux_46494、Mac_52194**。`miscBitmap=32764`、`ptVersion=2.0.0`、`mainSigMap=169742560`、`subSigMap=0`、`wtLoginSdk=nt.wtlogin.0.0.1`、`packageName=com.tencent.qq` 各档案相同。

---

## 8. 会话 / 工具 / 枚举

### 8.1 SessionStore（`common/SessionStore.kt`）
持久：`uin:Long, uid:String, a2, d2, d2Key, tgtgt, encryptedA1, noPicSig, qrSig, guid, deviceName:String, credentialsUpdatedAtEpochSeconds:Long?`
瞬态(`@Transient`)：`keySig(=sessionTicket):ByteArray?, exchangeKey(=sessionKey):ByteArray?, unusualCookies:String?`
- `empty()`：guid=随机 16B，deviceName=`"Lagrange-"+随机3B hex`，d2Key=16 零字节。
- `updateCredentials(a1,a2,d2,d2Key)`：要求 a1/a2/d2 非空且 d2Key 为 16 字节，随后落 4 个值 + 时间戳。

### 8.2 序列化工具（`BinaryReader.kt` / `BinaryExt.kt`）
- `Prefix` 位编码：`NONE=0, UINT_8=0b0010, UINT_16=0b0100, UINT_32=0b1000, INCLUDE_PREFIX=0b0001, LENGTH_ONLY=0`；`prefixLength=(v&0b1110)>>1`；`isIncludePrefix=(v&1)==1`。
- `writeLength(len,prefix)`：写入 `len + (include?prefixLen:0)`，按 1/2/4 字节。
- `barrier(prefix, addition)`：`writeLength(content.size+addition, prefix) + content`。
- `readTlv()`：`u16 count` 后循环 `u16 tag,u16 len,bytes`。
- `writeString/writeBytes` 带可选 prefix。

### 8.3 枚举
- `QRCodeState`：UNKNOWN=-1, CONFIRMED=0, CODE_EXPIRED=17, WAITING_FOR_SCAN=48, WAITING_FOR_CONFIRMATION=53, CANCELLED=54。
- `EncryptType`：None=0, WithD2Key=1, WithEmptyKey=2。
- `RequestType`：D2Auth(→protocol12), Simple(→protocol13)。

---

## 9. 与现有 Dart 实现 / 协议规格 差异对照

| 模块 | Acidify | Dart 现状 | 结论 |
|---|---|---|---|
| SSO protocol12 信封 | `PacketContext.SsoCodec` | `pc_sso.dart` | ✅ 结构一致（自测 30 项） |
| **SSO protocol13 信封** | 有（Alive 用） | **缺** | ❗**待转写**（长连接 Alive 必需） |
| KeyExchange | `KeyExchange.kt` | `pc_key_exchange.dart` | ✅ 常量/流程一致（SAME=true） |
| secp192k1 / P-256 | `Ecdh*` | `pc_crypto.dart`、`pc_qr_tlv.dart` | ✅ 一致（自测通过） |
| AES-GCM / TEA | `AesGcmProvider`/`TEA` | `pc_crypto.dart`/`qqTea*` | ✅ 信封格式一致 |
| FetchQRCode(0x31) | `WtLogin.TransEmp.FetchQRCode` | `pc_qr_login.dart` | ✅ 一致 |
| QueryQRCodeState(0x12)+getFace | 同上 + HTTP getFace | `pc_qr_login.dart`+flow | ✅ 一致 |
| PCLogin(9)/15 TLV | `WtLogin.PCLogin`+`Tlv.kt` | `pc_pc_login.dart` | ✅ 逐 TLV 一致（待真机） |
| **EasyLogin/UnusualEasyLogin** | `NTLogin.kt` | **缺** | ❗**待转写** |
| **登录后长连接（Register/Alive/Heartbeat/UnRegister）** | `BotOnline/Alive/Heartbeat/BotOffline`+`PacketContext` | **缺** | ❗**待转写** |
| 心跳节奏 | 10s Alive / 27×→270s Heartbeat | 文档未记 | 需补入规格 |
| qua 生成 | `-`→`_` 后拼 `V1_.._NQ_.._GW_B` | 文档写 `{version}` 未明确 | 需明确 |
| NTLoginForwardRequest | 无 secBuffer；clientInfo 仅 4 字段；sdkInfo v1 | — | 转写须照此 |
| SsoReservedFields 字段号 | 15/16/21/24/26 | `pc_sso_reserved.dart` 待核对 | 需核对字段号 |
| getSsoSecureInfo/signProvider | 有 qsign 接口（critical 命令签名失败即抛） | **无**（等效返回 null） | ⚠️ 需真机验证 wtlogin 是否强制签名 |
| AppInfo 档案 | 4 档（见 §7） | 文档仅 2 档 | 需补齐 2 档 |

---

## 10. 转写优先级（阶段 B 建议）
1. **protocol13 信封** 补进 `pc_sso.dart`（长连接 Alive 依赖）。
2. **EasyLogin 链**：`NTLogin` proto 类 + `NTLoginCommon` 构造 + `NTLoginForwardRequest` 编解码 + `AesGcm(sessionKey)`。
3. **长连接**：`BotOnline(Register)` → `postOnline` 心跳（Alive 10s / Heartbeat 270s）→ `BotOffline(UnRegister)`；重连/续期（`reconnectAndAuthenticate` 简化版）。
4. **接线 PCLogin** 到 `pc_qr_login_flow.dart`（并补 login 专用响应解析、票据改存项目本地）。
5. 真机单次扫码验证（风控冷却后）。

## 11. 待确认 / 风险
- **signProvider（qsign）**：Acidify 对 `wtlogin.trans_emp/login` 会尝试取签名；纯 Dart 无签名服务时等效 `ssoSecureInfo=null`。需真机确认 PC 扫码/PCLogin 是否在无签名下仍通过（现有 qq_qr6 扫码链已证明可无签名打通 FetchQRCode，PCLogin 待验证）。
- **hex 显示污染**：任何常量落地务必脚本校验（本项目已有 `tool/tmp/fix_pc_consts.py` 先例）。
- **风控**：扫码勿高频重试（历史教训）。
- **Acidify 仍在演进**：本清单基于 2026-11-04 main；转写前若仓库更新需重新比对。
