# QQ 协议线登录页改造计划(对齐 Nagram 分步引导)

## Context(为什么改)

当前协议线登录页 [qq8_connect_page.dart](file:///c:/Users/Administrator/penguis/qqclient/lib/ui/pages/qq8_connect_page.dart) 是"一屏平铺 4 个登录按钮 + 输入框 + 状态行"的调试式布局,存在三个用户感知的硬伤:

1. **没有一个明确的"登录/确认"主按钮**——密码框回车才能触发,手机上不可见;
2. **没有登录方式切换**——密码/手机号短信/票据/扫码四个按钮同时平铺,用户不知道哪个是主要方式;
3. **入口藏在三层之后**——主界面 → "连接设置"(OneBot 连接页) → 右上角"协议线登录" → 才是 QQ 登录,普通用户找不到。

参考 Nagram/Telegram 的 `LoginActivity`:手机号/密码优先,一次只做一件事,每个"页"一个浮动"继续"主按钮,其余登录方式收进菜单。

## 现状(已探明)

- `Qq8ConnectView` 是纯哑视图(状态 + 12 个回调),可单独测;widget 测试在 `test/qq8_connect_page_test.dart`。
- `Qq8ConnectController`(`lib/client_api/qq8_providers.dart`)已暴露全部动作:口令/票据/手机号短信/滑块/设备锁/扫码取码/扫码轮询。
- 状态阶段:`idle/connecting/needsSlider/needsSmsCode/needsDeviceLock/waitingQrScan/online/failed/disconnected`。
- 主题统一走 `TelegramColors`/`TelegramMetrics`;`lib/ui/widgets/` 无通用卡片/按钮组件,需自建。
- 扫码结果是 PNG 字节(`Image.memory` 即可渲染,`qq8_qrcode.dart` 注释 + `fetchQrcode`/`pollQrcode` 服务方法)。
- 无 `url_launcher`/`webview` 依赖,滑块闭环需新增。

## 方案

### 一、登录方式切换(顶部 Segmented/Tab)

把"密码 / 手机号短信 / 扫码(二维码) / 票据"收敛成**顶部一个 segmented 控制器**,默认选中**口令登录**(对齐 Telegram 手机号优先,这里口令最直接)。

| 方式 | 说明 |
|---|---|
| 口令 | 主推。QQ 号 + 口令,一个明显的「登录」主按钮 |
| 二维码 | 显示 `Image.memory(qrToken)`,外加轮询按钮;用**另一台设备上的 QQ** 扫 |
| 手机号短信 | 手机号 + 验证码,分两步 |
| 票据 | 已保存票据,一键登录 |

用 `SegmentedButton<T>` 或底部 `NavigationBar`,具体看尺寸。

### 二、一步一页 + 主按钮(对齐 Nagram `LoginActivity`)

- 不再平铺:按当前阶段只渲染**当前要做的一件事** + 一个「继续/登录」主按钮。
- 每个动作一个明确按钮:口令登录(「登录」)、扫码(「获取二维码」→「刷新状态」)、短信(「发送验证码」→「提交验证码」)、滑块 ticket(「提交验证码」)、成功后(「进入聊天」)。
- 按钮用 `TelegramColors.accent` 的 FilledButton,禁用态跟 `busy`。
- 错误/info 就地显示(已有 `stateLabel` + `error`)。

### 三、入口直达(改成一级入口)

把 `connect_page.dart` AppBar 右上角那个"协议线登录"(藏在 OneBot 连接页深处)提为**主界面直接入口**:

- 在 `home_page.dart` 主界面增加一个**协议线登录入口**(比如 AppBar 或设置里醒目的按钮)。
- 保留 OneBot 连接页与协议线登录页都可达(二线并存),但把协议线登录从"三层跳转"改为"一层即达"。

### 四、滑块闭环(手机上可用)

按用户答复:Play 8.2.11 密码登录**不需要**混元图形验证,所以滑块不是主路径。但国情下账号可能仍被要求滑块,方案:

- 新增 `url_launcher` 依赖,滑块 `needsSlider` 时显示底部按钮「在浏览器打开滑块页」,`launchUrl(sliderUrl)` 调系统浏览器。
- 解完回到 App,粘贴 `ticket` → 「提交验证码」。手机可用(比"只能 F12 抓"强),且保留现有逻辑。
- 不做 WebView 内嵌(依赖重、需真机验 WebView 交互,当前不是主路径)。

### 五、文案人话化

把「ticket」「票据」「协议线」「用已保存票据登录」等术语改成人话:

| 原文案 → 新文案 |
|---|
| 协议线登录(QQ)→ QQ 账号登录 |
| 口令(只在本机内存里转 MD5)→ 密码 |
| 用已保存票据登录 → 用已保存的登录状态 |
| 手机号短信登录 → 短信验证码登录(备用) |
| 把拿到的 ticket 粘贴回来 → 把验证码粘贴回来 |

## 文件清单

1. **`lib/ui/pages/qq8_connect_page.dart`** —— 按上述重构 `Qq8ConnectView`:顶部方式切换 + 每阶段单卡片 + 主按钮 + 人话文案 + url_launcher 打开滑块。
2. **`lib/ui/pages/home_page.dart`** —— 主界面增加协议线登录直达入口(`Qq8ConnectPage`),不再依赖 OneBot 连接页中转。
3. **`lib/ui/pages/connect_page.dart`** —— 保留对 `Qq8ConnectPage` 的跳转(调试/二线),不动。
4. **`test/qq8_connect_page_test.dart`** —— 更新:测方式切换存在、主按钮触发回调、各阶段渲染。
5. **`pubspec.yaml`** —— 新增 `url_launcher`。

## 验证

- `dart analyze lib tool test` 无问题;
- `dart run tool/qq8_login_selftest.dart`、`tool/qq8_profile_selftest.dart`、`tool/qq8_login_service_selftest.dart`、`tool/qq8_qrcode_selftest.dart` 全过;
- `flutter test test/qq8_connect_page_test.dart`(widget 测试:各阶段渲染 + 回调);
- 真机:协议线登录直达入口可见 → 口令登录 → 滑块 url_launcher 打开 → 粘 ticket → 提交。

## 备注/取舍

- 不引入 `webview_flutter`(依赖重、非主路径、需真机验 WebView);滑块用系统浏览器 + 粘贴回 App。
- 不改 `Qq8LoginService` / `Qq8ConnectController` 契约(动作都已具备,只改 UI 表达)。
- Telegram 的"手机号优先"我们不照搬——QQ 口令登录是主推,手机号短信登录作为备用方式。