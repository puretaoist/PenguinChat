# PC NTLogin 与账号风控 · 进展总结（2026-11-09）

> 本轮从「sign 内置」一路做到「PC 登录链路成型 + 账号风控定论」。本文是综合沉淀，补充旧的 `docs/PC-NTLogin-收发进度.md`。
> 定位不变：纯 Dart 自实现 QQ 协议 + Flutter，多端，最低 Android 日用；低占用/高稳定。

---

## 一、PC NTLogin 线（本轮成果，均已 `flutter build apk` 通过）

### 1. 纯 Dart 签名（sec_sign）——不再依赖 JS 引擎/native
- 来源：从 NTQQ-PureSignServer 的 `sign.js` 提取**纯算法**（对应 Linux QQ `3.2.34-53644`，`qua=V1_LNX_NQ_3.2.34_53644_GW_B`），Node 与原版**逐字节一致**（固定+5 随机共 6 组）。
- 移植：`lib/kernel/wlogin8/pc/pc_sign.dart`（字码 VM 全指令 + chacha/crc32/md5，**Dart 原生 BigInt**）、`pc_sign_consts.dart`（脚本提取常量）、`pc_sign_blobs.dart`（内嵌 blob27/41）——**纯 Dart 自包含**。
- 真机验证：`PC_SIGN_SELFTEST sign=9edc… match=true`（与 Node 一致），21–26ms/次。
- **弃用 `flutter_js`**：其 Android QuickJS 不支持 BigInt（`typeof BigInt=undefined`），sign.js 跑不了；已移除依赖、`third_party/flutter_js`、`assets/sign.js`、ffi override。
- `PcLoginService` 默认走纯 Dart `PcSign`；`signerOverride`/`signServer` 可选外部服务（仅调试）。

### 2. 登录 / 上线链路
- 扫码(`trans_emp`) → `PCLogin`(`wtlogin.login`, 带签名) → 得 a2/d2/d2Key/a1/uid → `SsoInfoSync` 上线：全纯 Dart。
- 关键文件：`client_api/pc_client.dart`（长连接）、`pc_login_service.dart`（登录服务）、`pc_login_providers.dart`（装配+guid/deviceName/session 持久化）、`ui/pages/pc_scan_page.dart`（L4）。

### 3. 设备指纹修复（对齐真实官方 Linux QQ）
- `osVer`：`_goOnline` 里 `systemKernel: kernel`(=“Linux”) → **`Ubuntu 22.04.4 LTS`**（原来把内核名当发行版串，是明显假指纹）。
- `deviceName`：`DESKTOP-xxxx`/`DESKTOP-ACIDIFY` → **`ubuntu-xxxxxx`**（Linux 主机名风格，与 os=Linux 自洽；**去掉了 ACIDIFY/Lagrange 库名**）。
- `guid`：16B 真随机、持久于 `dataDir/pc/device_guid.bin`。
- 未动：`subAppId=537391664`（与 sign.js AppInfo 一致，改则签名不自洽）、`appIdQrCode`（待确认真实值，暂不冒改）。

### 4. session 持久复用（免重复扫码）
- 登录成功 `_saveSession()`：a2/d2/d2Key/a1/uid → `dataDir/pc/session.json`。
- `tryResumeOnline()`：启动时读 session 直接 `SsoInfoSync` 上线；失败回退扫码。`pc_scan_page` 进页先试复用。

### 5. 保活 + 自动重连
- 上线后 `_startKeepAlive()`：每 10s `Alive`、每 27 次 `Heartbeat`；`_PcConn` 加 `done` 断线通知。
- 掉线 → `_onDisconnected()` → `_reconnect()`：重连 + 用 session 重新上线（6 次退避）。

### 6. 真机踩坑与关键发现
- 登录卡 `0x9`（服务连接中）/`168`：均为**账号级风控**，非签名（sign 已 match）。
- 腾讯 QQ 安全中心判定：**设备名 `Lagrange-130DB3` / 登录应用「QQ桌面版-Linux」→「风险设备/外挂」→ 强制下线 + 功能限制**。→ **设备名暴露第三方库是实锤触发点**。

---

## 二、账号 / 风控根本结论（子智能体 A–G + 公开资料，三方一致）

- **`type=45` 真相**：服务端把「账号风险」伪装成「版本过低」。黑盒模型：账号风险系数 `k`，**k>80 = 二级风控 → 旧版QQ无法登录、gocq 回 45**；`k>100` 冻结；**新号 k 升快**。→ 换版本/ssoVer/档案/native 真签 **全无效**。
- **判定在服务端**：反编译证实登录 SDK **无本地风险评分**，客户端只做两件事——打包设备/网络/历史 TLV + 解析返回码决定走「图形/短信/设备锁验证/成功」。所谓风控=服务端按上报包打分。
- **五元组强绑定**：设备ID + 设备名 + OS 指纹 + 网络环境(IP/APN/BSSID) + 行为时序；任一项「不可解释偏移」→ 判疑似模拟器/多开/脚本 → 断连/冻结该设备ID下关联会话。
- **可改 vs 不可改**：设备/网络/指纹(客户端可伪装改善) vs 账号历史/实名/历史登录地/验证码(服务端侧，改不了)。
- **手表协议：已排除**（2.0.8 是 2019 构建，社区教程 2021，2026 大概率已停用/同等风控；项目有手表档案但仅取码用）。

### 有效路线（共存，不"破"）：三件事
1. **五元组全程一致**：设备指纹/网络/行为登录间不变（Android 的 `0x128` 就在比对 last_mac/androidId/guid；`pd2.dat`=0x536 IP 历史要吻合当前出口）。
2. **新号养号**：新号 k 升快，别高频，一次成功即"锁票"。
3. **走门开着的链 + 频率纪律**：锁到真票后只用 `exchange_emp`(子命令11/15) 续期，**绝不反复打 `wtlogin.login` 风险门**；被 45 立即停手冷却/换干净号。

---

## 三、Android 8.2.11 线现状（对照）
- **0x544 已纯 Dart**（`qq8_t544.dart`，oicq lite-sign 移植），**2026-10-29 真机登录成功**；0x545 QIMEI 纯 Dart；0x553 本版不发。→ 签名/协议**不是卡点**。
- 设备指纹/协议**已较全**：`qq8_device.dart` 真机采集、`0x536/0x537` pd2 落盘、`0x128/0x202/0x141/0x153/0x187/0x188` 各 TLV 均有。
- **待补**：① `qq8_device.dart:14-15` 默认档案 `brand="OICQX" / model="Konata 2020"`（oicq 库假机型，露馅，应换真机值）；② guid 防自漂移（禁 `needChangeGuid`）；③ pd2 上报 IP 与真实出口一致；④ 频率纪律/锁票续期。

---

## 四、子智能体分析索引（A–G）
- **A｜官方 Android 反编译·0x544**：0x544=`ByteData.getCode`→native `libpoxy.so`；纯 Java 无法伪造；`t545` 是 QIMEI(MD5)；`0x553` 本版不发；8.2.11 无 libfekit(是 libpoxy/QSec/Qimei/Turing)。
- **B｜本项目 8.2.11 线**：0x544 已纯 Dart 真机成功；真卡点=账号风控 45/237，非签名。
- **C｜参考实现 acidify/diana/mania/signerserver**：都无 Android 0x544/qsign 纯算法（靠外部签名服务）；signerserver 仅 PC 3.2.34。可复用：协议 TLV 结构 + 签名 API 契约 + PoW。
- **D｜PC 设备指纹字段对比**：设备名库名是首暴露点；本项目 osVer=`Linux` 硬伤、deviceName 与 os 矛盾、构建号存疑；给 A–E 对齐清单。
- **E｜PC 风控规避/稳定**：PITFALLS 无 PC 实证；关键缺口=无 session 复用/无重连(已补)；做法=一次授权长期复用+低频保活。
- **F｜反编译·风控链/设备指纹采集**：判定在服务端；设备指纹集中 `t.java`→~8 TLV；`t.c()` 上报一致性位(0x128)；`pd2.dat`(0x536) IP 历史；PoW 纯算法可过、图片/短信不可；Turing=广告归因非登录验证。
- **G｜历史实证·过风控规律**：45=账号级；唯一真机证明通过=真身份+真签0x544按子命令+App内WebView解票+锁票续期；exchange_emp 不拦；手表排除；别黑盒试版本/native。

---

## 五、可落地清单
### 已做（本轮 PC）
设备指纹(osVer/deviceName 去库名) ✅ · 纯 Dart 签名 ✅ · session 复用 ✅ · 保活+自动重连 ✅

### 待补
- **PC**：出口 IP 稳定/真实网络；补**收发 IM**（能聊天的前提，M2.3–M2.5）。
- **Android**：`OICQX→真机机型`、guid 不自漂、pd2 真实 IP、频率纪律、真机身份注入完整性、走 exchange_emp 续期。
- **共用**：五元组一致 + 新号养号 + 冷却 + 一机一号。

### 不可破（别再试）
版本/ssoVer/档案切换、native 真签、手表协议、黑盒试参 —— 全已证无效；45 只能靠"不触发"。

---

## 六、回退 / 纪律 / 环境
- **回退**：以上均为新增/改新增文件 + pubspec 减依赖；删新增、还原 pubspec 即可，不动现有 Android 登录/收发逻辑。
- **纪律**：C68 反复登录会烧号；一机一号；出风控码立即停手；换号连设备身份/IP 一起换。
- **环境**：dart 用 `dart.exe`（非 bat）；AppInfo 固定 Linux `3.2.34-53644` 与签名 `qua` 严格一致；外部 8099 签名仅调试（App 默认纯 Dart）。
