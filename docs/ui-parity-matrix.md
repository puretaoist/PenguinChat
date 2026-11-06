# PenguinChat × Telegram/AyuGram UI 差异表

> 生成方式：只读源码对照，不靠截图猜。TG 侧源码根
> `C:/Users/Administrator/penguis/telegram-src/TelegramAndroid/TMessagesProj/src/main/java/org/telegram/ui/`（下表简称 `T/`），
> 我方路径相对项目根 `C:/Users/Administrator/penguis/qqclient/`。行号为 2026-11-06 实测。

图例：✅ 已一致 ｜ ⚠️ 有偏差（含刻意偏差）｜ ❌ 缺失 ｜ ❓ 尚未逐行核实

优先级：**P1** = 用户已明确抱怨/影响主干观感；**P2** = 明显落后 TG 的外观项；**P3** = 细节对齐

---

## A. 主壳与导航 — `lib/ui/pages/home_shell.dart`

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| A1 | 宽屏（平板）没有底部悬浮 tab | `T/MainTabsActivity.java:99-103` INDEX_CHATS..INDEX_PROFILE；`:314` `new GlassTabView[5]` | `home_shell.dart:97-104` 开头 `if (wide) return HomePage(...)` 直接短路，平板只走三栏工作台 | ⚠️ **刻意偏差**，注释写在 `:10-12`。用户已问「平板没有悬浮底栏」→ 需要拍板：平板也叠底栏，还是保持三栏 | **P1** |
| A2 | tab 数量 4 vs 官方 5（少 CALLS） | 同上 5 槽含 `INDEX_CALLS` | `home_shell.dart:238-249` 聊天/联系人/设置/我的 | ✅ 有意裁剪（本项目无通话） | P3 |
| A3 | 底栏形态：高 56、圆角 28、最大宽 344、上下 margin 8 | `T/MainTabsLayout.java:311-385`；`T/DialogsActivity.java:291` | `home_shell.dart:204` `height = 56`；`:205` `_maxWidth = 344`；`:228` `circular(28)`；`:161-164` `left/right 8, bottom 8+inset` | ✅ 一致 | — |
| A4 | 进会话时底栏让位（滑出+淡出） | 官方聊天页全屏 push | `home_shell.dart:109` `showBar = !(_tab == 0 && _chatPaneOpen)`；`:167-175` AnimatedSlide/Opacity | ✅ 一致（还额外做了 150ms 同步节拍） | — |

## B. 会话列表 — `lib/ui/widgets/chat_list_panel.dart`

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| B1 | 行高 70 vs 72 | `T/Cells/DialogCell.java` heightDefault=72（我方注释已引） | `lib/ui/theme/telegram_theme.dart:274` `chatRowHeight = 70.0` | ⚠️ 差 2dp，整列会显得略挤 | P3 |
| B2 | 行左右 padding / 头像起点 | `T/Cells/DialogCell.java:170-171` avatarStart=11、messagePaddingStart=72 | `chat_list_panel.dart:490-494` `chatRowPadding` + `vertical: 9`；头像 `TelegramMetrics.avatarSize = 52`（`telegram_theme.dart:277`） | ✅ 几何按 11+52+13=76 对齐（`:487-489` 注释） | — |
| B3 | 标题字号/字重 | `T/Theme.java:7812` dialogs_namePaint = BOLD | `chat_list_panel.dart:539-545` `fontSize: 17`，未读 w700 / 常态 w600 | ⚠️ 字重常态 w600（TG 是 BOLD=w700）；字号 17 待核官方 dialogs_namePaint 尺寸 | P3 |
| B4 | 群聊摘要「发送者: 正文」 | `T/Cells/DialogCell.java:1802-1827` | `chat_list_panel.dart:587-589` 调 `_preview` | ✅ 一致 | — |
| B5 | 时间颜色/未读加粗、静音不刷强调色 | TG dialogs_timePaint 未读态 | `chat_list_panel.dart:619-632` | ✅ 一致（比 TG 多一条"静音不刷色"的合理规则） | — |
| B6 | 置顶 / 免打扰 / 未读 badge / 在线点 | `T/Cells/DialogCell.java:2491-2496`（pin）、`:4164-4188`（pinned overlay） | `:602-611` pin、`:549-558` muted 铃铛、`:637+` 未读 badge、`:505-521` online 12dp | ✅ 齐全 | — |

## C. 聊天页 header — `lib/ui/widgets/chat_header.dart`

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| C1 | 高度 | ActionBar 56dp | `:44` `TelegramMetrics.headerHeight = 56`（`telegram_theme.dart:270`） | ✅ | — |
| C2 | 标题 18 / 副标题 14 | `T/Components/ChatAvatarContainer.java:303-307` `subtitleTextView.setTextSize(14)` | `:79` fontSize 18；`:93` fontSize 14 | ✅ | — |
| C3 | 副标题文案 | TG「N members, M online」 | 我方「群聊 · 18 人」 | ⚠️ 文案风格差异，非几何 | P3 |

## D. 消息区 — `lib/ui/pages/home_page.dart` + `widgets/message_bubble.dart` + `widgets/message_list_builder.dart`

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| **D1** | **气泡高度（内边距）+ 相邻气泡间距** | `T/Cells/ChatMessageCell.java:7758` `totalHeight = messageObject.textHeight() + dp(19.5f) + namesOffset` | `message_bubble.dart:217-219` `padding: EdgeInsets.fromLTRB(isOut?11:17, 8, 12, 6)` → 上下合计 **14**；且 `home_page.dart:2484-2655` itemBuilder 外层无任何 Padding/Margin，`bubble_entrance.dart:109-121` 也没有 → **相邻气泡顶底相贴** | ❌ 上下少 5.5dp。修法：把上下内边距从 8/6 提到合计 19.5（建议上 9 / 下 10.5，先真机比对再微调）；**不要**给列表项加 separator——TG 的呼吸感来自内边距，不加行间距 | **P1** |
| D2 | 左右内边距 出站 11 / 入站 17 | `:16628` `+ dp(11) + getExtraTextX()`；`:16646` 入站分支 | `message_bubble.dart:219` `isOut ? 11 : 17` | ✅ | — |
| D3 | 发送者名 14sp + 七色轮转 | `T/Theme.java:8399` namePaint=dp((2*16+10)/3)=14；`UserObject.java:212-216` id%7 | `message_bubble.dart:243-248` `nameColorFor(senderId)`、fontSize 14、w600 | ✅ | — |
| D4 | 名字下间距 | `:18989` `namesOffset += getNameHeight()`；`:20290` replyStartY 再 +dp(1) | `message_bubble.dart:238-239` `Padding(only(bottom: 3))` | ⚠️ 与 TG 的 1dp 差 2dp，随 D1 一起调 | P3 |
| D5 | 消息左侧头像 42dp、x=6 | `:13839` `avatarImage.setImageCoords(dp(6), y, dp(42), dp(42))` | `telegram_theme.dart:292` `bubbleAvatarSize = 42`；槽宽 42+14（`home_page.dart:2541-2544`） | ✅ | — |
| D6 | 组内后续条顶角收紧 6dp | TG `ChatMessageCell` 的 `clipTop`/`drawRoundRect` 分支 | `message_bubble.dart:187-188` `outerTop = firstInGroup ? radius : 6.0` | ✅ | — |
| D7 | 时间戳定位 | `:13781` 出站 `timeX = layoutWidth - timeWidth - dp(42)`；`:13783` 入站 `backgroundWidth - dp(4) - timeWidth`；`:13785` 最小 dp(26) | 我方时间在气泡内 Column 末尾（独立一行/覆盖式），非绝对定位 | ⚠️ 结构不同、视觉近似；如果要像素级一致需改绝对定位 | P3 |
| D8 | 5 分钟合组规则 | `ChatListItemAnimator`/`MessageObject` 的 5 分钟 | `message_list_builder.dart:59-67` `sameGroup`：非 system + 同 outgoing + 同 senderId + <5min + 同年月日 | ✅ | — |
| D9 | 未读分隔线切断分组 | TG/Nagram unread divider | `message_list_builder.dart:71-104` `anchorIndex` 两侧都断组 | ✅ | — |

## E. 输入栏 — `lib/ui/widgets/chat_input_bar.dart`

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| E1 | 整宽实色面板 + 顶部细线（非渐变遮罩） | `T/Components/ChatActivityEnterView.java:4727-4755` drawBackground | `:73-91` bgSidebar + 0.5 divider + 上阴影 | ✅ | — |
| E2 | 表情键在**胶囊内左侧** 44x44 | `:2755` `addView(emojiButton, ... Gravity.BOTTOM \| LEFT, 2,0,0,0)` | `:140-150` `_ghostIcon(emoji)` 在胶囊 Row 首位 | ✅ | — |
| E3 | 回形针在**胶囊内右侧** | `:2840` `messageEditTextContainer.addView(attachButton, ... Gravity.BOTTOM \| RIGHT)` | `:184-193` `_ghostIcon(attach)` 在胶囊 Row 末位 | ✅（上一轮刚纠正过：原来放胶囊外） | — |
| E4 | 右侧发送/麦克风 | `:2977` `sendButtonContainer` 100x44（那 100 含相机键） | `:206-208` `SizedBox(48,48)` | ⚠️ 宽 48（无相机键，合理）；高 48 vs 44 差 4dp | P3 |
| E5 | 字号 18sp / 最多 6 行 | `:5813` `setTextSize(COMPLEX_UNIT_DIP, 18)`；`:5812` maxLines 6 | `:165-168` fontSize 18；`:159-160` minLines 1 / maxLines 6 | ✅ | — |
| E6 | 高度 44 | `:6471` `DEFAULT_HEIGHT = 44` | `:38` `overlayHeight = 56`（44 + 上下 6+6）；`:124` minHeight 44 | ✅ | — |
| E7 | 长按录音 / 上滑取消 | `ChatActivityEnterView` 的 record 手势 | `voice_record_button.dart` 存在 | ❓ 手势细节未逐行核 | P3 |

## F. 聊天壁纸 — `lib/ui/widgets/chat_wallpaper.dart` ❌ 最大缺口

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| F1 | 只支持 5 档线性渐变；无图片壁纸、无图案、无模糊/暗化、无视差 | `T/ChatActivity.java:43681` `backgroundDrawable != null ? backgroundDrawable : Theme.getCachedWallpaperNonBlocking()`；`:43711/:43815` getCachedWallpaperNonBlocking；`:44327` `Theme.getCachedWallpaper()` | `chat_wallpaper.dart:29-47` 只有 plain/dusk/forest/ocean/sunset 五个 `LinearGradient`；`:68-84` 纯色或渐变，无 Image | ❌ 文件头注释也自认"想要图片壁纸是下一步的事" | **P2** |

修法建议：加 `assets/wallpapers/`（2-3 张即可，用 webp 控制体积）+ 选中图片时 `ImageFiltered(ImageFilter.blur(sigmaX: 12))` + 一层黑/白 20% 叠加保证气泡可读性；预置图案可以用少量 SVG/平铺图。

## G. 弹层

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| G1 | 底部 ActionSheet：顶部圆角 12、项高 48、字号 16 | `T/ActionBar/ActionSheet`（未逐行核） | `action_sheet.dart:66` 圆角 12；`:112` height 48；`:124` fontSize 16 | ✅ 数值与 TG 观感一致（❓ 未引到具体行） | — |
| G2 | 消息长按菜单项高/字号 | — | `message_action_popup.dart:252` `kMessagePopupItemHeight`；`:265` fontSize 15 | ❓ 待核 | P3 |

## H. 设置页与其他

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| H1 | 设置页分组卡片（section header 13sp 大写 + 卡片圆角 10 + 项 16sp） | `T/SettingsActivity` | `settings_page.dart`(408) + `settings/{appearance,chats,general,other}_settings_page.dart` | ❓ 未逐行核 | P3 |
| H2 | 联系人 / 我的 / 好友资料 / 搜索页 | 无直接对应（QQ 侧功能） | `contacts_page.dart`(188)、`my_profile_page.dart`(182)、`friend_profile_page.dart`(246)、`search_page.dart`(319) | ❓ 未对照 | P3 |

---

## 结论：按优先级排队

1. **P1-A1**：平板是否要底部悬浮 tab —— 需要产品拍板（代码只有一处短路 `home_shell.dart:97-104`）。
2. **P1-D1**：气泡上下内边距 14 → 19.5（`message_bubble.dart:217-219`），这是"气泡之间的间隔也不对"的根因；相邻气泡之间是 0 间距，靠内边距撑呼吸感。
3. **P2-F1**：图片壁纸/图案/模糊 —— 缺口最大，工作量也最大。
4. P3 若干：会话行高 70→72、会话名字重 w600→BOLD、时间绝对定位、右侧键 48→44。

## 已核实「无差异」的硬事实（不要重复改）

- 气泡左右内边距 11 / 17（`ChatMessageCell.java:16628/16646` ↔ `message_bubble.dart:219`）
- 发送者名 14sp + id%7 七色（`Theme.java:8399`、`UserObject.java:212-216`）
- 消息头像 42dp、偏移 6dp（`ChatMessageCell.java:13839`）
- 输入栏结构（胶囊内左 emoji、内右 attach、右侧 send/mic）与 18sp/6 行/44dp 标准高
- 5 分钟合组、未读分隔线断组、底部 tab 的 56/28/344 胶囊形态
