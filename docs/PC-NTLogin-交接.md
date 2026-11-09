# PC NTLogin / 扫码登录 — 项目交接文档

> 生成时间：2026-11-08
> 用途：重开会话后，**第一句请说「读 docs/PC-NTLogin-交接.md 继续」**，即可无缝接手。
> 配套详细规格：`docs/PC-NTLogin-协议规格.md`（字段号、常量、SSO 格式全在那里，本文不重复，只讲进度/踩坑/待办）。

---

## 0. 一句话现状

**纯 Dart 自实现 QQ 协议，已在真机跑通「KeyExchange + 扫码取码 + 轮询 + getFace + 确认」全链路（`qq_qr6` 拿到真票据）；PCLogin 代码就绪待验证；但旧协议 `wtlogin.trans_emp` 当前被服务端收紧（高频扫码触发风控），官方 9.9.19 用的是新协议 `SsoQRLoginGenQr`（trpc）。**

---

## 1. 已完成（实机验证过，不是推断）

| 环节 | 命令 / 方式 | 证据 |
|---|---|---|
| KeyExchange | `trpc.login.ecdh.EcdhService.SsoKeyExchange` | 真服务器 `retCode=0`，拿到 sessionKey(32B)+sessionTicket(95B) |
| FetchQRCode | `wtlogin.trans_emp` subCmd 0x31 | `retCode=0`，返回真实二维码 URL（txz.qq.com/p?k=...） |
| QueryQRCodeState | `wtlogin.trans_emp` subCmd 0x12 | 正确读到 WAITING_FOR_SCAN → WAITING_FOR_CONFIRMATION → CONFIRMED |
| **getFace** | HTTP POST `https://ntlogin.qq.com/qr/getFace` | `retCode=0`，返回扫码账号 uin/faceUrl |
| **CONFIRMED** | — | `qq_qr6` 成功：uin=3639444121，tgtgt=16B / encryptedA1=152B / noPicSig=88B |

**关键教训：`getFace` 是必须的。** 在 `WAITING_FOR_CONFIRMATION`(state=53) 时必须调它，否则服务端会走 `CANCELLED`(54)。补上 getFace 后第一次就 CONFIRMED。

---

## 2. 代码清单（`lib/kernel/wlogin8/pc/`）

| 文件 | 作用 | 状态 |
|---|---|---|
| `pc_proto.dart` | 最小 protobuf 编解码（PbWriter/PbReader） | ✅ |
| `pc_crypto.dart` | P-256 ECDH（原始秘密，不 MD5）+ AES-GCM（IV12‖ct‖tag16）+ SHA256 | ✅ |
| `pc_key_exchange.dart` | KeyExchange 构造/解析（含硬编码 serverPublicKey/verifyHashKey） | ✅ 真机通过 |
| `pc_sso.dart` | SSO Protocol 12 信封 + TEA + gzip；含 `PcWtLogin.buildWtLoginPacket`（通用 wtlogin 封装 2064/2066） | ✅ |
| `pc_sso_reserved.dart` | ssoReserved pb（trace/uid/msgType/secureInfo/ntCoreVersion） | ✅ |
| `pc_qr_tlv.dart` | secp192k1 ECDH + TLV 构建器 + 扫码 7 TLV + 0xD1 pb | ✅ |
| `pc_qr_login.dart` | `PcWtLogin.buildTransEmp/buildFetchQrCodeBody/buildWtLoginPacket` + `pcBuildQueryStateBody/pcParseQueryState` | ✅ |
| `pc_pc_login.dart` | PCLogin（wtlogin.login subCmd 9）：15 TLV + tlv119 解析 | ⚠️ 代码就绪，未真机验证 |

自测：`tool/pc_key_exchange_selftest.dart`(23)、`pc_sso_selftest.dart`(30)、`pc_qr_selftest.dart`(9)、`pc_secp192k1_vector_selftest.dart`(2)，全过。

工具：`tool/pc_qr_login_flow.dart`（扫码全流程：取码→打印URL→轮询→getFace→CONFIRMED→PCLogin；含存票据）；`tool/pc_key_exchange_smoke.dart`（KeyExchange 冒烟）。

---

## 3. 核心结论：为什么官方能扫、我们的旧协议被拒

**从官方 9.9.19 的 `wrapper.node`（96MB native）挖出的命令表：**

- 官方扫码唯一命令 = **`trpc.login.ecdh.EcdhService.SsoQRLoginGenQr`**（trpc / NTLogin 体系，新协议）
- 官方还有 `SsoNTLoginCheckA1List`、`SsoNTLoginEasyLogin` 等
- Acidify 用旧 `wtlogin.trans_emp`
- Lagrange.Core 用旧 `wtlogin.qrlogin`（Android）

**三个开源项目都只有旧协议，没有 `SsoQRLoginGenQr`。** 这就是「Acidify 代码没遗漏」的真相——开源生态里没有新协议实现。

**但注意：Acidify/Lagrange 仍在维护、有人在用旧协议，说明旧协议本身可行。** 我们的失败更可能是**短时间高频扫码触发了风控**（q6 成功后疯狂重试了几十次、还频繁换号/换网/换版本），不是协议被封。

---

## 4. 待办（按优先级）

1. **PCLogin 真机验证**（代码就绪）：`pc_qr_login_flow.dart` 已接入，CONFIRMED 后自动跑 PCLogin。**用正常节奏扫一次（不要高频重试）**，看能否拿到 A2/D2/d2Key。
2. **EasyLogin 免密续期**：拿到 A1 后用 `SsoNTLoginEasyLogin`。规格见 Acidify LoginOps `renewSessionInternal`。
3. **登录后长连接**（日用必需）：`onlineInternal`（心跳 Alive/Heartbeat、收推送、拉好友/群）。
4. **新协议 `SsoQRLoginGenQr` 逆向**（若要稳定扫码）：proto 字段结构需从 `wrapper.node` 动态 hook（Frida）或抓包解密；开源项目都没有。
5. **文档**：把 getFace、packet 包装层等坑补进 `docs/PC-NTLogin-协议规格.md`（已有初稿）。

---

## 5. 踩坑记录（都是真金白银，别重踩）

1. **终端 hex 显示不可信**：本环境 GBK/UTF-8 混用会把 `04` 显示成 `2c`。取二进制常量一律用脚本 + 程序内校验（`tool/tmp/fix_pc_consts.py`），别肉眼抄。
2. **KeyExchange 的 serverPublicKey**：65 字节、首字节 **0x04**、在 P-256 曲线上。verifyHashKey 32 字节。（之前抄错过，已用脚本修正）
3. **扫码用 secp192k1（不是 P-256）**：已用纯 Python 独立实现验证与标准逐字节一致。
4. **wtlogin.trans_emp 双层加密**：外层 SSO `TEA(16零字节)` + 内层 `TEA(MD5(ECDH(secp192k1)))`。
5. **trans_emp 有 requestBody + packet 两层**（漏 packet 层会超时）：`packet = u8(0)‖u16(rbLen)‖u32(appId)‖u32(0x72)‖u16(0)‖u8(0)‖requestBody`。
6. **`barrier(UINT16|INCLUDE, addition=1)` 的长度 = 内容+1+2 = 内容+3**（不是 +2）。
7. **AppInfo 必须用真实值**：`Linux_39038`：appId=1600001615, subAppId=537313942, appClientVersion=39038, ssoVersion=19, currentVersion='3.2.19-39038', mainSigMap=169742560, packageName='com.tencent.qq', ptVersion='2.0.0', os='Linux'。
8. **必须单条持久 TCP 连接**跑完 FetchQRCode + 轮询（换连接会被判离线）。
9. **getFace 必须调**（state=53 时，HTTP POST ntlogin.qq.com/qr/getFace，body `{"appid":..,"faceUpdateTime":0,"qrsig":"<qrCodeString>"}`）。
10. **PCLogin 的 Login 响应解析和 TransEmp 不同**：不跳 54 字节头，直接 `u16(cmd)+u8(state)+TLV`；Login 外层 wtloginSubCmd=**2064**（TransEmp 是 2066）。
11. **高频风控**：短时间反复扫码/换号换网，会触发「扫码频率风控」（表现为 18~45s 内 CANCELLED）。正常节奏单次扫即可。

---

## 6. 环境 / 工具

- 官方 QQ：Windows NTQQ 9.9.19.35341，装在 `C:\Users\Administrator\qq-portable\App\`（便携版，进程 QQ.exe）。
- **抓包**：Windows 自带 `pktmon`（`C:\Windows\System32\PktMon.exe`），管理员权限。`pktmon start --capture --pkt-size 0 -f C:\temp\qq.etl` → 操作 QQ → `pktmon stop` → `pktmon etl2pcap qq.etl -o qq.pcap`。**官方 9.x 流量加密（抓不到明文命令）**，抓包主要用于验证加密/看连接。
- **官方协议字符串**：在 `qq-portable\App\versions\9.9.19-35341\resources\app\wrapper.node`（96MB native），命令名是明文 ASCII（`SsoQRLoginGenQr` 等），但 proto 字段号是硬编码的，挖不到。
- **跑 Acidify 本体**：JDK21/17 都有（`C:\Program Files\Zulu\zulu-21`、`C:\Program Files\AdoptOpenJDK\jdk-17.0.0.20-hotspot`）。gradlew 在 MSYS 下路径会被转坏（`C;/temp`），要用 `java -cp "gradle/wrapper/gradle-wrapper.jar" org.gradle.wrapper.GradleWrapperMain <task>` 方式跑。**但 Acidify 构建卡在 `:acidify-core:transformJvmMainAtomicfu`（atomicfu 插件 vs Kotlin 2.3.21/Gradle 9.6.1 不兼容，JDK17 也失败）——这是该项目的工具链 bug，建议改用 IntelliJ 直接打开 run，别在命令行跟 gradle 版本搏斗。**
- 二维码图片：`pip install qrcode pillow`，然后 `qrcode.QRCode(box_size=8,border=4)` 生成 PNG 给手机扫。

---

## 7. 建议的新会话开场

> 「读 docs/PC-NTLogin-交接.md 和 docs/PC-NTLogin-协议规格.md，继续 PC NTLogin 项目。」

**下一步最该做的**：先确认账号/风控是否冷却，用 `tool/pc_qr_login_flow.dart` **单次**扫码，验证 PCLogin（拿 A2/D2/d2Key）。这是扫码登录的最后一环。**切忌高频重试。**
