# HANDOFF — 新会话开工必读

> 这份文档是**当前唯一有效的交接说明**。旧的 `docs/STATUS.md` / `docs/NEXT-TASK.md` /
> `M1-REPORT.md` / `M2-REPORT.md` 已移入 `docs/archive/`（内容过期，只作历史）。
> 更新日期：2026-11-07。

---

## 0. 一句话现状

Flutter / Android 的 **QQ 客户端**（Telegram 风格 UI），代号 **PenguinChat**，
包名 `com.puretaoist31.penguinchat`。

- **UI 侧**：已在真机上跑通并反复验收（聊天页、会话列表、联系人、设置、我的、底栏胶囊、状态栏透明）。
- **协议侧**：自实现 QQ 8.2.11 协议线**真机登录 + 收发消息 + 语音上传发送全部打通**
  （0x544 纯 Dart 真签首次真机登录 2026-10-29 成功；0x126d NT 语音上传 2026-11-07 对端可播）。
- **代码状态**：**162 个改动未提交**（详见 §5）。这是新会话第一件要注意的事。

---

## 1. 环境（本机绝对路径，直接复制用）

| 用途 | 路径 / 命令 |
|---|---|
| 项目根 | `C:/Users/Administrator/penguis/qqclient` |
| dart | `C:/Users/Administrator/scoop/apps/flutter/bin/cache/dart-sdk/bin/dart.exe` |
| flutter | `C:/Users/Administrator/scoop/apps/flutter/bin/flutter.bat` |
| adb | `C:/Users/Administrator/AppData/Local/Android/Sdk/platform-tools/adb.exe` |
| 设备 | `HA2CSJR5`（1904x3040 平板，`wm size 1080x2400` 可切手机形态；`wm size reset` 复原） |
| python | `C:/Users/Administrator/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe` |
| TG 源码 | `C:/Users/Administrator/penguis/telegram-src/TelegramAndroid/TMessagesProj` |
| 四个 QQ 包 | `C:/Users/Administrator/penguis/`（8.2.11 / 8.9.50 / 9.3.60 / tim 4.1.0） |

**注意**：`dart.bat` / `flutter.bat` 在本机会卡在 SDK bootstrap，一律用上表里的 dart.exe；
`flutter.bat` 用于 build / test 时可正常工作。

---

## 2. 常用命令

```bash
# 静态检查（当前基线：只有 6 条既有 curly_braces info，零 error/warning）
dart analyze lib test

# 全量 widget 测试（当前基线 361 项全过，约 27 秒）
flutter test

# 离线自测（58 个 *_selftest.dart，纯 Dart）
dart run tool/qq8_ntv2_selftest.dart

# 构建 + 装机
flutter build apk --release --split-per-abi --target-platform=android-arm64
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
adb shell am start -n com.puretaoist31.penguinchat/.MainActivity

# 真机截图（必须带 UI_SHOT=1，否则空跑）
$env:UI_SHOT='1'; flutter test test/tools/ui_shot_test.dart
```

规模基线：`lib` 156 个 dart 文件 / 62,538 行；`test` 38 个文件 / 9,591 行；`tool` 58 个自测脚本。

---

## 3. 分层纪律（违反一次就会连锁返工）

```
L4 ui/         表现层（Flutter）
L3 client_api/ 契约 + 数据对象 + 数据层
L2 kernel/     协议内核（wlogin8 / onebot / crypto / transport）
L1 infra/      字节读写、存储、日志、音频
```

依赖方向只能是 **L4 → L3 → L2 → L1**。`lib/infra` `lib/kernel` `lib/client_api`
**一律不许 import Flutter**（要平台能力就注入 Directory / Socket / 回调），
否则 `tool/*_selftest.dart` 跑不起来。

两个"看起来反了但正确"的地方，**不要顺手修正**：
- `Session` 契约在 L3（`lib/client_api/session.dart`），L2 的 OneBotSession 去 implements 它（依赖倒置）。
- `onebot_session.dart` 已从 L2 迁到 L3（原先是唯一一处反向依赖）。

其它硬规矩：
- 注释写**为什么**，不写"做了什么"；关键常量必须写出处（官方反编译位置 / 参考实现文件名:行号）。
- 测试**禁止固定 sleep**，要等就 `waitUntil(() => 条件)`。
- 凭据不进日志，用 `Redact`。
- 每个模块配 `tool/<模块>_selftest.dart`，末尾 `exit(failed == 0 ? 0 : 1)`（**不要用 exitCode**，句柄没放会挂住进程）。
- **前端必须完全吃透 TG 源码才能开始写**（见 `AGENTS.md` §1.8）：
  动 UI 前先在 `telegram-src/TelegramAndroid/TMessagesProj` 里读明白，
  每个 UI 常量写明 `文件:行号`；参数只许来自「官方源码实读」或「本文 §8 已取证表」。
  拿不到官方依据就显式标"自定值"并登记 `docs/ui-parity-matrix.md`，**绝不许"看着差不多"就动手**，
  也**不许写完再补出处**（事后补的出处多半是编的）。

---

## 4. 协议线要点（写任何协议代码前必看）

### 4.1 必须记住的几条事实
- **TEA 不是标准 CBC**：`B_i = P_i ⊕ C_{i-1}`，`C_i = E(B_i) ⊕ B_{i-1}`。
  按标准 CBC 写，报错是"尾部校验失败"，指不到根因。见 `lib/kernel/crypto/tea.dart`。
- **一次登录 = 一条会话**（SSO seq 全程共用），不是一串独立请求。
- **群 seq 是水位不是游标**，方向反了群消息永远为空。
- **0x544 / 0x553 / 0x545 是天花板**：三者分别依赖 `libpoxy.so` / fekit / `libqimei.so`，
  纯 Dart 复现不了；服务端必然把我们当 oicq / Lagrange 那一档信任级别。
- **code 45 是账号级风控标记，会烧号**：口令链必须默认关闭，10 分钟最多 3 次。
- **票据一张只能用一次**，续期即轮换，旧票下一秒回 `type=15`；必须 `--save-token` 落盘。
- **图片 rkey 是小时级过期**，只能 GroupPicDown 换链（历史图片约 67% 可看回）；
  重拉历史拿不到新 rkey。
- **语音上传**：0x126d 回执里 80 端口全回 `retcode=-5503001`，必须按回执给的 15000 端口原样打；
  `C2CUserInfo{1:AccountType,2:TargetUid}`，AccountType=1 表示 TargetUid 填 uin。

### 4.2 已打通 / 未打通

| 能力 | 状态 |
|---|---|
| 密码 / 短信 / 扫码登录（真机） | ✅ 打通（票据可续期） |
| 私聊 / 群聊收发、历史翻页 | ✅ 打通 |
| 图片收发（含群图换链） | ✅ 打通（历史回看约 67%） |
| 语音播放（SILK v3 FFI） | ✅ 打通 |
| 语音上传发送（NT 0x126d） | ✅ 打通（私聊；对端可播） |
| 群语音上传 | ❌ 仍走老链路，需改 `0x126e_100` |
| 业务推送真正打开 | ❌ 注册回执对了，但业务推送未验证 |
| 已读回执（双勾） | ❌ 协议上做不到，普通消息服务端默认关 |
| 票据加密落盘 | ✅ Android Keystore 包裹密钥 + AES-GCM；旧明文首次读取时自动迁移（真机未验证） |

---

## 5. 未提交改动清单（**最重要**）

`git status` = **162 项**：124 M + 22 D + 16 ??。

> ⚠️ **绝对不要 `git checkout .` 或 `git stash`**：这些改动里混着多轮已真机验收的真实成果，
> 批量回退会把它们全丢掉。回退只能**单文件 + 手工反向修改**。

**新增（??）**
```
docs/archive/                        ← 本次文档整理（23 份历史文档）
lib/ui/chat/                         ← chat_draft_controller / chat_load_coordinator /
                                       chat_viewport_state / message_timeline_provider
lib/ui/widgets/bubble_text_layout.dart
lib/ui/widgets/home_chat_pane.dart
lib/ui/widgets/home_selection_bar.dart
lib/ui/widgets/tg_action_bar.dart
lib/ui/widgets/tg_bubble_shape.dart
test/{bubble_text_layout,chat_draft_controller,chat_load_coordinator,chat_viewport_state,
      home_chat_pane,home_dialog_list,message_timeline_provider,telegram_list_item,
      tg_action_bar}_test.dart
```

**已改（M）的主要面**：`lib/client_api/*`（chat_store、segment、session、qq8_*、recovery_planner…）、
`lib/infra/audio/*`、`lib/kernel/wlogin8/*`、`lib/ui/pages/*`（home_page / home_shell /
settings_page / my_profile_page / contacts_page）、`lib/ui/widgets/*`、`lib/ui/theme/*`、
`android/app/src/main/res/values{,-night}/styles.xml`、`test/*` 与 `test/goldens/*`。

**已知的 6 条既有 analyze info**（curly_braces，非本轮引入，可留）：
`lib/client_api/qq8_token_store.dart:568`、`lib/kernel/wlogin8/qq8_file.dart:291`、
`qq8_gfs.dart:189`、`qq8_image.dart:787`、`qq8_push.dart:512`、`qq8_tlv.dart:1508`。

**提交建议**：按主题拆成多个 commit（协议 / 数据层 / UI 组件 / 页面 / 文档），
不要把 162 项塞进一个 commit。

---

## 6. 未完成 / 待决策

### 6.1 代码遗留（明确要做）

1. **`lib/ui/pages/home_shell.dart` 的状态栏样式丢了**。
   上一轮回退底栏胶囊时用了 `git checkout HEAD -- lib/ui/pages/home_shell.dart`，
   连带把状态栏那套一起抹掉了：`_overlayStyle()`、`_withSystemBars()`、
   两处 `return PopScope(` 外层的 `AnnotatedRegion`、宽屏 `SafeArea(top: false)`。
   **仍在的部分**：`lib/main.dart` 的 `SystemChrome.setEnabledSystemUIMode(edgeToEdge)`、
   `android/app/src/main/res/values{,-night}/styles.xml` 的透明状态栏条目。
   后果：状态栏是透明的，但图标亮度不再随主题反色（浅色主题下图标可能看不清）。
   修法：在 `_HomeShellState` 里加回 `_overlayStyle()` + `_withSystemBars()`，把两处
   `return PopScope(` 包起来（**用按行号插入 + `dart format` 收尾，不要用"索引+括号计数"脚本，
   那会把文件改坏**）。

2. **底栏胶囊目前是"回退版"**（`bgHover @0.80` + `Border.all(divider)` 描边 + 黑 0.28/blur16 阴影），
   底部遮罩是 `blur σ16 + bgApp 透明→实色渐变`。
   用户多次反馈「tab 附近有实色遮挡」，实测剩余"板感"来自胶囊本体比背景亮 11~16 + 0.5dp 描边。
   官方参数已取证完整（见 `docs/blur-parity.md` 与本文 §8.2），**是否按官方 GlassTabView 重做未定**。

3. **群语音上传**：`sendVoice` 里 `gid != null` 不走 NT 分支，要改成 `0x126e_100`。

4. **`tool/tmp` 下 150+ 历史抓包脚本未清**（`dart analyze tool` 报 433 条 info）。

### 6.2 待用户拍板

- **是否回滚 `dart format` 的全库重排**：前一轮用 Dart 3.13.5 的 tall style 重排了 98 个文件，
  `git diff` 因此膨胀到 114 files / +7730 / −4933。纯格式，但和真实改动混在一起了。
- **`lib/ui/widgets/tg_page_header.dart` 是否删除**：现在只有 4 个二级设置页还在用，
  首页 / 联系人 / 设置 / 我的都已换成 `tg_action_bar.dart`。
- **设置页是否也预热 selfNickname**：现在只有 `my_profile_page.dart` 调
  `ensureSelfNickname()`，设置页标题长期显示「QQ <uin>」而不是昵称。

### 6.3 未验

- 真机深交互（长按多选、滑动归档、通知回复）只做过抽查。
- 业务推送是否真的打开。
- 群语音发送。

---

## 7. 最贵的坑（摘自 docs/PITFALLS.md，139 条全文在那）

| 编号 | 现象 | 根因 |
|---|---|---|
| C1 | 任何 oicq 密文解不开，报"尾部校验失败" | TEA 分组链不是标准 CBC |
| C36 | 群消息永远为空 | 群 seq 是**水位**不是游标，方向反了 |
| C54 / C68 | 账号被永久标记 / 烧号 | code 45 是账号级风控，重试只会加剧 |
| C85 | 断网后永不自动上线 | 30 秒断网把 3 次重试配额用完 |
| C104 | 图片加载不出来 | 不是慢，是**没有加载层**（UI 绕过缓存直接 Image.network） |
| C118 | 语音上传一直失败 | 回执成败读错字段（应读 head f3 uint32_error_code，372=失败） |
| C121 / C122 | 滚动位置还原错位 | 用像素缓存还原；应存 `{msgId, offsetFromBottom}` 锚点 |
| C26 | 登录流程莫名其妙失败 | 一次登录是**一条会话**，不是一串请求 |
| C67 / C70 | 0x544 签名总回 45 | salt 里的 `t.A` 就是 guid；交票复用了登录子命令的签 |

---

## 8. TG 侧已取证的参数（改 UI 前先看这里，别重新翻源码）

### 8.1 页头 / ActionBar
- `ActionBar.getCurrentActionBarHeight()`：竖屏 56dp / 横屏 48dp；标题竖 20sp / 横 18sp。
- `ActionBar.java:1400`：高度**已含状态栏**，背景铺到状态栏后面（`occupyStatusBar = true`）。
- `DialogsActivity.java:3222`：首页**没有常驻搜索框**，搜索是 ActionBar 内图标，点开才进搜索页。
- 头部阴影：滚出 5dp 才画（`DialogsActivity.java:4607-4608`），3dp 贴图 `R.drawable.header_shadow`。

### 8.2 底栏玻璃（`org/telegram/ui/Components/glass/GlassTabView.java`）
- 高 56dp、圆角 28、最大宽 344、内 padding 12、上下 margin 8、内容底部留白 72。
- 选中态底板：`Theme.multAlpha(tabSelected, 0.09)`，scale `lerp(0.6,1,f)`（`GlassTabView.java:150-165`）。
- 玻璃底色：`BlurredBackgroundProviderImpl.mainTabs` → `solveSrcColor(key_windowBackgroundWhite, key_glass_targetMainTabs, 0.85)`；
  描边上下双色（浅 0x11000000 / 0x20000000，深 0x06FFFFFF / 0x11FFFFFF），宽 0.4dp；
  阴影 `dpf2(2.667) / offset 0,0.85`。
- 底部淡出：`BlurredBackgroundWithFadeDrawable.setFadeHeight(dp(60), true)`，
  渐变 4 段 alpha `0, 0x60, 0xB0, 0xE8`（÷285），其余 CLAMP；整条**始终是模糊半透明**，不能叠实色。

### 8.3 聊天页气泡（`ChatMessageCell.java`）
- 气泡最大宽 = `min(父宽, displaySize.y) − dp(80+42)`；圆角 dp(17)。
- 文字内边距：左 入 17 / 出 11，上 8，右 入 9 / 出 38.5，下 6.5；正文 16dp。
- 发送者名 14dp；时间 12dp 右下对齐；头像 42dp、x=6、圆角 21。

### 8.4 设置页 / 我的页
- `SettingsActivity.java:645`：资料块 188dp（`asCustomShadow(topView, 200-12)`）；
  头像 90 圆角 90、名字 22 bold、副标题 13。
- SettingCell：图标块 28×28 圆角 10 上下渐变、标题 16 / 副 13、行高 `min(44/60/50)`、
  **不画 divider**；段卡圆角 16、左右内缩 12、段间距 12。
- 官方**没有**：每行 chevron（只有 AccountCell）、switch 行、列表内退出登录（在 ActionBar 更多菜单）。
- `ProfileActivity.java`（myProfile=true）：头像实显 96dp、名字 17.5 bold、状态 13.5、
  列表 padding top 226dp（152+74）、首行前 12dp 空隙、TextDetailCell 标题 16 / 值 13 / 单行 60。

---

## 9. 文档索引

### 9.1 现存（`docs/`，仍然有效）

| 文件 | 内容 |
|---|---|
| `docs/HANDOFF.md` | **本文件**，开工必读 |
| `docs/PITFALLS.md` | 139 条坑，4,779 行，最值钱的一份 |
| `docs/ui-parity-matrix.md` | PenguinChat × Telegram/AyuGram UI 差异表 |
| `docs/blur-parity.md` | 模糊覆盖对照（官方 13.1.1 vs 本项目） |
| `docs/FIRST-LOGIN-20261029.md` | 首次真机登录成功记录（0x544 真签链路） |
| `docs/LOCAL-QSIGN.md` | Windows 原生跑 qsign |
| `docs/启动对齐-官方做法取证与实施-20261031.md` | 冷启动 / 闪屏对齐 |
| `docs/轮询策略调整-推送为主与群窗口短路-20261031.md` | 前台 15s / 后台 120s 策略 |
| `docs/断网消息补回与群水位实测-20261031.md` | 群水位语义实测 |
| `docs/推送通道实测与注册续租-20261031.md` | 推送注册与续租 |
| `docs/新消息系统通知-实施与验证-20261031.md` | 通知 7 条判定 |
| `docs/通知名字与冷启动-20261031.md` | 通知里的名字与点通知进会话 |
| `docs/通知栏回复-实现-20261101.md` | 通知栏直接回复 |
| `docs/已读回执-可行性-20261101.md` | 为什么做不到双勾 |
| `docs/图片加载-官方对照与改造方案-20261031.md` | 图片加载层（C104 的完整版） |
| `docs/群图换链-GroupPicDown-20261031.md` | 群图 rkey 过期换链 |
| `docs/语音消息-V1播放-20261101.md` | SILK v3 + AudioTrack |
| `docs/语音消息-V2录音发送-20261101.md` | 录音 / 编码 / 0x346 / 上传（含"读错字段"的教训） |
| `docs/语音换链-ptt-uuid-20261103.md` | 语音 rkey 过期换链 |
| `docs/长按气泡popup与滑动动作-20261103.md` | popup 锚点 / 多选 / 滑动归档 |
| `docs/四个UI问题-20261103.md` | 滚动记忆 / 切页动画 / 昵称 / 主题可配置 |
| `docs/前端对齐TG-会话列表与聊天页-20261031.md` | 会话列表与聊天页对齐 |
| `docs/前端优化-动画与冷启动-20261031.md` | 动画与冷启动 |
| `docs/设置页与动画打磨-20261101.md` | 设置页 |
| `docs/参照TG补齐底栏与资料页-20261101.md` | 底栏 / 联系人 / 资料页 |
| `docs/UI统一与五处修正-20261101.md` | 五条 UI 反馈的根因 |
| `docs/项目改名与版本-20261101.md` | 改名与 MethodChannel 三组同步 |

### 9.2 根目录

`README.md`（构建入口）· `AGENTS.md`（工程约定）· `STRUCTURE.md`（分层理由）·
`SAFETY.md`（账号风险与防护）· `STORAGE-DESIGN.md`（存储取舍）·
`CI-BUILD.md`（云端构建 + 本机构建的坑）· `LIVE-TEST.md`（真机测试流程）· `TOOLING.md`（逆向工具链）

### 9.3 历史（`docs/archive/`，**已过期，只作追溯**）

23 份：`STATUS.md`、`NEXT-TASK.md`、`REVIEW-2026-09-22.md`、`M1-REPORT.md`、`M2-REPORT.md`、
`FEKIT-0x553-PLAN.md`、`RESEARCH-code45.md`、`qqclient-scroll-audit-handoff.md`、
`qq8-login-ui-revamp.md`、`WorkBuddy-日常登录与账号隔离-实施任务书.md`、
`五项真机缺陷-*`（2）、`日常登录-*`（3）、`推送注册与恢复错误治理-*`（2）、
`图片加载-覆盖度实测与P3取舍`、`图片富媒体下载-P3取证与内核`、`图片直链刷新实验-P2结论`、
`语音上传-TIM抓包对照`、`语音消息-官方实现取证`。

> 这些文档里的**行数、文件清单、状态结论全部过期**（例：`home_page.dart` 已从 644 行长到 2,664 行）。
> 只有**协议取证结论**（反编译行号、字段号、命令字）仍然可信。

---

## 10. 新会话建议的开工顺序

1. 读本文件 → 读 `docs/PITFALLS.md` 的 C 类（协议与实现）目录 → 需要细节再跳条目。
2. `git status` 确认 162 项未提交改动还在，**先决定提交策略**（按主题拆 commit）。
3. 跑一次基线：`dart analyze lib test`（应只有 6 条 info）+ `flutter test`（应 361 全过）。
4. 从 §6.1 的遗留清单挑一件做（建议先修 `home_shell.dart` 的状态栏样式，它影响所有页面）。
5. 动 UI 前先看 §8，**不要重新翻 TG 源码**——参数都在这里了。
