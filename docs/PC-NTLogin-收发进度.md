# PC NTLogin 收发进度与交接（2026-11-08）

> 本文记录「转向 PC NTLogin（绕开 Android 8.2.11 的 0x544 设备证明/烧号问题）」后，本轮从零到「登录→上线→拉好友/群」的全过程与现状，供交接/回看。
> 定位：**纯 Dart 自实现 PC NTQQ 协议 + Flutter UI，多端；最低 Android 日用**。签名**内置**（不依赖外部服务）。

---

## 0. 一句话现状
- **签名**：方案定 = 内嵌 JS 引擎跑 `sign.js` 纯算法；代码就绪，Android 构建验证进行中。
- **登录/上线**：✅ 真机跑通（扫码→PCLogin→SsoInfoSync）。
- **收发**：`PcClient` 长连接地基 + OIDB 层 + 拉好友/群 = ✅（真机空号验证 `oidbResult=0`；离线自测 177 项全过）。收消息/发消息/历史/富媒体待做。
- **未动现有 Android 登录线**（原有 `Qq8LoginService`/收发）——全部为**新增并行**，可回退。

---

## 1. 为什么转 PC NTLogin
Android 8.2.11 线的根本障碍：`0x544/0x553` 设备证明纯 Dart 不可达，且口令链/风控会把账号烧成 `type=45`（见 `docs/PITFALLS.md` C9/C13/C45/C68）。PC NTLogin 走 trpc `EcdhService` 体系，需要的是 `sec_sign` 签名（可本地纯算法），**不需 0x544 native**，因此绕开该问题。

## 2. 签名（重点）
- **本质**：PC NTQQ 的 `sec_sign` 被官方混淆成「VM + 250KB 字节码 blob」。开源实现（Rust/C/Python）多是「加载 Linux `wrapper.node` 转发」，Android/Windows 用不了。
- **唯一可内置的纯算法**：NTQQ-PureSignServer 的 C#/`sign.js`（`pure-53644`，对应 Linux QQ `3.2.34-53644`）。
- **选定方案**：内嵌 JS 引擎跑 `sign.js`。
  - `assets/sign.js`：从 `sign.js` 提取的**纯算法部分**（去 export + TextEncoder/crypto polyfill），**已用 Node 与原版 `computeSign53644` 逐字节对齐（sign/extra 全等）**。
  - 引擎：`flutter_js`（Android=QuickJS / iOS=JSC）。**桌面 Win/Linux 暂不支持**（后续再议）。
  - 封装：`lib/ui/pc_sign_engine.dart`（`getJavascriptRuntime()` 执行 sign.js → `PcSsoSecureInfo`）。
  - `PcLoginService` 支持注入本地签名（`signerOverride`），否则回落到外部 HTTP 签名服务。
- **外部签名服务（备选/调试）**：`C:\temp\signerserver\sign-server.mjs`（Node 跑 `sign.js`，监听 8099，`POST /sign {cmd,src,seq} → {value:{sign,token,extra}}`）。仅 `tool/pc_fetch_test.dart` 等本机工具用它；**App 内置版不需要**。
- ⚠️ `flutter_js` 0.8.7 与 `path_provider_windows` 的 `ffi` 版本冲突，已在 `pubspec.yaml` 加 `dependency_overrides: ffi: ^2.0.0` 统一。
- ⚠️ 之前试过 `flutter_qjs 0.3.7`：虽然全平台，但构建脚本太旧（`jcenter`/AGP3.5/无 namespace）与项目 AGP9 不兼容，已弃用。

## 3. 已完成的代码（`lib/`）
| 文件 | 作用 | 状态 |
|---|---|---|
| `kernel/wlogin8/pc/pc_*.dart`（12 个） | PC 协议底层：proto/crypto/key_exchange/sso/sso_reserved/qr_tlv/qr_login/pc_login/nt_login/online/register/oidb/friend/group | ✅ 编译+自测 |
| `kernel/wlogin8/pc/pc_sso.dart` | Protocol12/13 信封；`buildRequest12(d2,d2Key,a2,ssoReserved)`、`buildRequest13` | ✅ |
| `kernel/wlogin8/pc/pc_register.dart` | 上线 `SsoInfoSync` / 下线 `UnRegister` / 心跳 | ✅ |
| `kernel/wlogin8/pc/pc_oidb.dart` / `pc_friend.dart` / `pc_group.dart` | OIDB 封装 + 拉好友(0xfd4_1) + 拉群(0xfe5_2) | ✅ 真机空号验证 |
| `client_api/pc_client.dart` | L3 长连接客户端（分帧/请求响应/推送流/seq） | ✅ |
| `client_api/pc_login_service.dart` | L3 扫码登录服务（扫码→PCLogin→SsoInfoSync→online，Stream 状态） | ✅ |
| `client_api/pc_login_providers.dart` | Riverpod 装配 + PC guid 持久化 + `pcSignServerProvider` | ✅ |
| `ui/pc_sign_engine.dart` | 内置签名（flutter_js 跑 assets/sign.js） | ✅ analyze |
| `ui/pages/pc_scan_page.dart` + `qq8_connect_page` 右上角「PC 扫码」入口 | L4 扫码登录页 | ✅ |

工具：`tool/pc_qr_login_flow.dart`（扫码全流程+PCLogin+SsoInfoSync 上线）、`tool/pc_renew_online_test.dart`（a1 续期+上线）、`tool/pc_fetch_test.dart`（a1 续期+上线+拉好友/群）、`tool/pc_*_selftest.dart`（9 个离线自测，**177 项全过**）。

## 4. 真机验证结论
- 扫码 `trans_emp`（带签名）→ `CONFIRMED` ✅
- PCLogin(`wtlogin.login`, 带签名) → **曾回 `0x9 服务连接中`（登录频率限流）**；Diana 同档案能登，故是限流非协议错。需**冷启动单次**验证。
- 免密续期链（KeyExchange→EasyLogin→SsoInfoSync）✅ `register success`。
- 拉好友/群 ✅ `oidbResult=0`（测试号无好友/群，body 仅元数据，属空号真实情况）。
- **关键坑**：SSO 保留字段（ssoReserved）**必须带 `uid`**，否则 `-10003 身份验证失败`（PITFALLS C19 同源）。

## 5. 剩余（里程碑）
- **M2.3 收消息**：上线后消费长连接推送（`trpc.msg.register_proxy` / `PushMsg`），解析进会话，喂现有 chat_store/UI。
- **M2.4 发消息**：`MessageSvc.PbSendMsg`（私聊/群，带签名），成功判据对齐官方。
- **M2.5 历史 + 富媒体**：拉历史、图片/语音（Highway）。
- **构建验证**：`flutter build apk` 确认 `flutter_js` native 编过（进行中）。
- **多端**：当前 `flutter_js` 只 Android/iOS；要 Win/Linux 需换全平台引擎（见 §2）。

## 6. 工程注意 / 回退
- **回退**：以上全部为**新增文件 + pubspec 增依赖**，未改现有 Android 登录/收发逻辑；如需放弃，删新增文件、还原 `pubspec.yaml` 即可。基线 commit：`91cfeed`（改动前记录）。
- **纪律**：PC 登录也受账号频率风控；用测试号、冷启动单次、勿高频（PITFALLS C68）。
- **环境**：dart 建议用 `dart.exe`（非 `dart.bat`，后者卡 bootstrap）。
- **AppInfo 必须固定 `Linux 3.2.34-53644`**（与签名 `qua=V1_LNX_NQ_3.2.34_53644_GW_B` 严格一致），否则签名对不上。
