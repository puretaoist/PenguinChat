# PenguinChat × Telegram/AyuGram UI 差异表

> 生成方式：只读源码对照，不靠截图猜。TG 侧源码根
> `C:/Users/Administrator/penguis/telegram-src/TelegramAndroid/TMessagesProj/src/main/java/org/telegram/ui/`（下表简称 `T/`），
> 我方路径相对项目根 `C:/Users/Administrator/penguis/qqclient/`。行号为 2026-11-07 实测。

图例：✅ 已一致 ｜ ⚠️ 有偏差（含刻意偏差）｜ ❌ 缺失 ｜ ❓ 尚未逐行核实

优先级：**P1** = 用户已明确抱怨/影响主干观感；**P2** = 明显落后 TG 的外观项；**P3** = 细节对齐

---

## 登记规则（强制，见 `AGENTS.md` §1.8）

动任何 UI 代码之前，先在本表里找到或新增对应行，然后才能写代码。

| 列 | 填写要求 |
|---|---|
| `TG 依据` | 必须是 `T/文件:行号`（`T/` = 上文 TG 源码根）。**没有行号 = 没读过 = 不许写代码** |
| `我方现状` | 本项目 `文件:行号` |
| `结论` | ✅ 一致 / ⚠️ 偏差（**必须写清是"待修"还是"刻意偏差+理由"**）/ ❌ 缺失 / ❓ 未核实 |
| 优先级 | P1 / P2 / P3 |

三条硬约束：

1. **新增 UI 组件必须先在本表登记**，再写代码 —— 不许写完再补表。
2. **拿不到官方出处** → 结论写 ⚠️ 并在末尾注明「自定值：<理由>」，
   **绝不许写 ✅**（✅ 的含义是"逐行对过官方源码"）。
3. **❓ 不等于 ✅**。❓ 表示还没逐行核实，任何基于它的"已对齐"结论都不成立。

---

## A. 主壳与导航（底部玻璃 tab 胶囊） — `lib/ui/pages/home_shell.dart`

> 2026-11-07 全量逐行对照，共 **70 项**（A1-A70）。
> 批次①②③④⑤ 落地后当前状态：✅ 已对齐 **50** ｜ ⚠️ 仍偏差 **13** ｜ ❌ 仍缺失 **4** ｜ — 不适用/平台差异 **3**。
> 官方参数唯一出处：`T/MainTabsActivity.java`、`T/MainTabsLayout.java`、`T/Components/glass/GlassTabView.java`、
> `T/Components/blur3/drawable/color/impl/BlurredBackgroundProviderImpl.java`、`T/Components/blur3/drawable/BlurredBackgroundDrawable.java`。
> 我方行号对应 2026-11-07 版 `home_shell.dart`（**1283 行**，批次①②③④⑤ 已落地；原 745 行的行号已失效）。

### A-1 布局与几何

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| A1 | 胶囊容器高：官方 wrapper 是 72dp 槽 | `T/MainTabsActivity.java:383` `createFrame(MATCH_PARENT, MAIN_TABS_HEIGHT_WITH_MARGINS=72, BOTTOM\|CENTER_HORIZONTAL)`；`T/DialogsActivity.java:291-293` `56 + 8*2 = 72` | `home_shell.dart:474` `wrapperHeight = 72`，`SizedBox(height: _MainTabBar.wrapperHeight)` | ✅ 已对齐 | — |
| A2 | 背景与内容的关系：官方背景在 72 内**四边内缩 7.666dp**（视觉胶囊 ≈56.67，内容区仅 48） | `T/MainTabsActivity.java:368` `setPadding(dp(7.666))`；`T/Components/blur3/drawable/BlurredBackgroundDrawable.java:256-271` `boundsWithPadding.inset(padding,padding)` 后建 path | `home_shell.dart:475` `capsuleInset = 7.666` + `Padding(EdgeInsets.all(capsuleInset))`；`:477` `tabHeight = 48`（= 72 - 12*2，`T/MainTabsLayout.java:63`） | ✅ 已对齐 | — |
| A3 | 四周 padding：官方 12dp **四周** | `T/MainTabsActivity.java:311` `setPadding(dp(MAIN_TABS_MARGIN + 4))` = 12dp | `home_shell.dart:479` `contentInset = 12`、`:476` `contentPadding = 12 - 7.666 = 4.334`（7.666 + 4.334 = 12，等效四周 12） | ✅ 已对齐 | — |
| A4 | 最大宽 344 | `T/MainTabsActivity.java:312` `setMaxWidth(dp(328 + 8*2))` = 344 | `home_shell.dart:390` `_maxWidth = 344`；`:477` `min(constraints.maxWidth, 344)` | ✅ 一致 | — |
| A5 | 圆角 28 | `T/MainTabsActivity.java:367` `setRadius(dp(MAIN_TABS_HEIGHT/2f))` = 28 | `home_shell.dart:493` `BorderRadius.circular(28)` | ✅ 一致 | — |
| A6 | 底边距 | `T/MainTabsActivity.java:948` `setPadding(insets.left, 0, insets.right, navigationBarHeight)` | `home_shell.dart:310-313` `bottom: 8 + bottomInset` | ✅ 近似 | — |
| A7 | 文字/内边距三档降级 | `T/MainTabsLayout.java:46-47` `PASS_TEXT_SIZES_DP={12,12,10}`、`PASS_PADDINGS_DP={16,8,4}` | `home_shell.dart:481-482` `passTextSizes` / `passPaddings` 常量 + `_slots()` 三档循环（照抄 `onMeasure` :73-90），`_textSize` 随之切换 | ✅ 已对齐 | — |
| A8 | tab 宽度分配 | `T/MainTabsLayout.java:59-154` 按 `measureTextWidth()+padding*2` 分配，超宽等比缩（`:121-125`），不足补到 `min(dp(320), avail)`（`:69,126-133`） | `home_shell.dart:918-982` `_slots()` 逐行照抄：三档 fits 判定、`maxTabTextWidthIfEq` 权重、超宽等比缩、不足补到 `min(320, contentWidth)`；`:966-975` `_measureTextWidths` 用 `TextPainter` 量 | ✅ 已对齐 | — |
| A9 | visualWidth（底板动画宽） | `T/MainTabsLayout.java:243-249` 把 ListAnimator rect 宽传给 `setVisualWidth`；`T/GlassTabView.java:108,152` `hasVisualWidth ? visualWidth : getWidth()` | 每个槽 `SizedBox(width: widths[i])` 内各自淡入淡出底板（`home_shell.dart:980-1003`），槽宽由 `_slots()` 一次算定、不做布局动画 | — 不适用：官方 visualWidth 只在 tab 被 `setViewVisible` 显隐（ListAnimator 驱动宽度动画）时才有意义，即 A63 通话 tab 显隐；我方 4 tab 常驻可见、槽宽恒定，没有触发条件。强行复刻会引入一套没有输入源的动画 | P3 |
| A10 | tab 数量 5 vs 4 | `T/MainTabsActivity.java:99-107` INDEX_CHATS/CONTACTS/SETTINGS/CALLS/PROFILE，`indexToPosition(index)=index>2?index-1:index`（设置与通话二选一占位） | `home_shell.dart:474-548` 聊天/联系人/设置/我的 | ⚠️ 有意裁剪（无通话），但官方"二选一占位"机制未移植 | P3 |

### A-2 底色

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| A11 | 叠色算法：官方 `solveSrcColor` 按 alpha **反解源色**，不是直接叠 alpha | `T/Components/blur3/drawable/color/impl/BlurredBackgroundProviderImpl.java:24-27`；`:304-332` `src = clamp(round((out - bg*(1-a))/a),0,255)` | `lib/ui/widgets/glass_capsule_border.dart` `solveSrcColor()` 逐通道复刻；`home_shell.dart:722-729` `_capsuleFill()` 调用它 | ✅ 已对齐 | — |
| A12 | alpha：0.76（普通）/ 0.85（`FLAG_LIQUID_GLASS`） | `T/BlurredBackgroundProviderImpl.java:24` `LiteMode.isEnabled(FLAG_LIQUID_GLASS) ? 0.85f : 0.76f` | `home_shell.dart:722-729` 已用官方普通档 **0.76**（原 0.80 硬叠）；0.85 液态玻璃档未做（见 A17） | ⚠️ 普通档已对齐，液态玻璃档缺失 | P4 |
| A13 | 源色 | 亮 `key_windowBackgroundWhite` 与 target `key_glass_targetMainTabs` 同为白；暗 `DarkThemeResourceProvider.java:94-95` 两者均 `0xFF181819`（**同色**） | `home_shell.dart:722-729` 喂 `bgApp` / `bgGlassPanel`，算法照官方、输入用我方主题色（见下方决策注记） | ⚠️ 有意偏差（已决策，非疏漏） | — |

> **决策（2026-11-07，用户 m00304）**：算法严格对齐官方 `solveSrcColor`，但**输入取我方主题色**
> （`bg = bgApp`、`target = bgGlassPanel`），因为官方暗色 bg 与 target 同值（0xFF181819）而
> 我方两者不同（0xFF1D2733 / 0xFF212D3B）。照搬官方绝对值会让胶囊比背景更暗、像凹槽。
> 反解结果：亮 `0xC2FFFFFF`（叠完 = 白）、暗 `0xC2222F3E`（叠完 = `bgGlassPanel`）。

### A-3 描边

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| A14 | 描边：官方 **0.4dp**、上下**双色不对称**（亮 top `0x11000000` / bottom `0x20000000`；暗 top `0x06FFFFFF` / bottom `0x11FFFFFF`） | `T/BlurredBackgroundProviderImpl.java:29-30` `setStrokeColorTop/Bottom`；`:33` `setStrokeWidth(dpf2(0.4), dpf2(0.4))` | `glass_capsule_border.dart` `GlassCapsuleBorder`（`CustomPaint` 上下两段各 0.4dp）；`home_shell.dart:731-741` 亮色 top `0x11000000` / bottom `0x20000000`，暗色按用户 m00304 决定不做白描边 | ✅ 已对齐（暗色按决策省略） | — |

> **决策（2026-11-07，用户 m00304「我们不加上类似玻璃的白色描边」）**：
> 暗色**不做**官方 `0x06FFFFFF/0x11FFFFFF` 白色描边；亮色做 0.4dp 黑色系上下双色。
> 实现方式：`CustomPaint` 手绘上下两条线（Flutter 的 `Border` 只支持 uniform，无法上下异色）。

### A-4 阴影

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| A15 | 阴影：色 `0x20000000`(亮)/`0x04FFFFFF`(暗)，`setShadowLayer(dpf2(2.667), 0, dpf2(0.85))` | `T/BlurredBackgroundProviderImpl.java:31-32` | `home_shell.dart:758-762` `BoxShadow(color: isDark ? 0x04FFFFFF : 0x20000000, blurRadius: 3.75, offset: Offset(0, 0.85))` —— 3.75 = `(2.667-0.5)/0.57735` 反算（`convertRadiusToSigma`） | ✅ 已对齐 | — |

### A-5 模糊与液态玻璃

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| A16 | blur 半径：官方**本机源码查不到具体值**（`setBlur` 只收外部传参，MainTabsActivity 未调用） | `T/Components/blur3/drawable/BlurredBackgroundSourceRenderNode.java:63-70`；对照 `T/Stories/PeerStoriesView.java:549` 用 `dp(8)`、`T/iv/RichMediaCell.java:153` 用 `dp(24)` | `home_shell.dart:506-507` `sigmaX/Y: 20` | ⚠️ **自定值**（无官方依据，已在 `docs/blur-parity.md` 登记） | P3 |
| A17 | 液态玻璃 | `T/MainTabsActivity.java:364` `setLiquidGlassEffectAllowed(LiteMode.isEnabled(FLAG_LIQUID_GLASS))`；开启时 alpha 切 0.85（`T/BlurredBackgroundProviderImpl.java:24`） | 无 | ❌ 缺失（Flutter 侧无法做折射/饱和度，见 `docs/blur-parity.md` §三） | P4 |
| A18 | 底部渐变带 | `T/MainTabsActivity.java:375-376` `setFadeHeight(dp(60), true)`；`T/Components/blur3/BlurredBackgroundWithFadeDrawable.java:211-232` `createGradient` 5 段 alpha | `home_shell.dart:311-356` `height: 60 + bottomInset` + `BackdropFilter(σ16)` + **5 段 alpha 渐变**（0x00/0x60/0xB0/0xE8/0xFF，stops 0/0.25/0.5/0.75/1） | ✅ 高度与 alpha 停靠点均对齐（blur 半径官方无取证，σ16 为自定值） | — |

### A-6 选中态底板

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| A19 | 底板范围：官方**铺满整个 tab 宽高** | `T/GlassTabView.java:158` `tmpRectF.set(0, 0, viewWidth, getHeight())` | `home_shell.dart:996-1020` `_slot` 改 `Stack(fit: StackFit.expand)` 直接铺满，原 2dp 内缩已删 | ✅ 已对齐 | — |
| A20 | 底板圆角：官方 `r = min(w,h)/2` = **短边一半（完整胶囊）** | `T/GlassTabView.java:159` | `home_shell.dart:1014-1016` `BorderRadius.circular(_MainTabBar.tabHeight / 2)` = 24（内容区高 48 恒小于槽宽，等效短边一半），原硬编码 16 已删 | ✅ 已对齐 | — |
| A21 | 缩放 `s = lerp(0.6,1,factor)*clamp(attachScale,0,1)` | `T/GlassTabView.java:160` | `home_shell.dart:573-574` `Transform.scale(0.6 + 0.4*t)` | ✅ 一致 | — |
| A22 | alpha `multAlpha(colorSelected, 0.09f*alpha)` | `T/GlassTabView.java:157` | `home_shell.dart:578` `accent.withValues(alpha: 0.09*t)` | ✅ 数值一致 | — |
| A23 | 选中色 `key_glass_tabSelected`，真实主题下走 fallback 到 `chat_messagePanelSend = 0xFF229AF0` | `T/GlassTabView.java:270-276` `updateColorsLottie()`；`T/Theme.java:3705-3716` fallback 链；`T/assets/darkblue.attheme:155`、`T/assets/day.attheme:96` 均为 `-14509328` | `telegram_theme.dart:96-97,126-127` 新增 `glassTabSelected = Color(0xFF229AF0)`，`home_shell.dart:929`（拖动 selector）、`:1065`（选中底板）、`:1103`（图标插值终点）全部改用它 | ✅ 已对齐（`ThemeColors.java:876` 的 `0xFF1a91e6` 在任何 .attheme 里都不存在，真实主题永远走不到） | — |
| A24 | 动画：`BoolAnimator(..., DECELERATE_INTERPOLATOR, 320)`，且 alpha 再走一次插值 | `T/GlassTabView.java:67`；`:156` `DECELERATE_INTERPOLATOR.getInterpolation(selectedFactor)` | `home_shell.dart:556` `TweenAnimationBuilder` 320ms `Curves.decelerate` | ✅ 时长/曲线一致，缺二次插值 | P3 |
| A25 | 长按期间禁画底板 | `T/MainTabsLayout.java:465-474` `setSkipDrawSelector(true)`；`:489-500` 450ms 后恢复 | `home_shell.dart:1003` `if (t > 0.001 && !_skipDrawSelector)`；`:573-595` 长按置真；`:650-676` 松手 `Timer(_kRestoreSelectorDelay = 450ms)` 恢复 | ✅ 已对齐 | — |

### A-7 图标与头像

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| A26 | 主图标 24×24、top 4 | `T/GlassTabView.java:406` `createFrame(24, 24, ..., 0, 4, 0, 0)` | `home_shell.dart:1064` `Icon(size: 24)` + `:1057` `Padding(EdgeInsets.only(top: 4))` | ✅ 已对齐 | — |
| A27 | 头像 22×22、圆角 11、**无描边圈** | `T/GlassTabView.java:424` `setRoundRadius(dp(11))`；`:427` `createFrame(22, 22, ..., 0, 5, 0, 0)` | `home_shell.dart:1106-1135` 22×22 + `BorderRadius.circular(11)` + `Padding(only(top: 5))`，选中描边圈已删 | ✅ 已对齐 | — |
| A28 | 图标染色 `blendARGB(colorDefault, colorSelected, factor)`，`colorDefault = key_glass_tabUnselected` | `T/GlassTabView.java:254-265`；`T/Theme.java:3705-3716` → `windowBackgroundWhiteBlackText`；`T/assets/darkblue.attheme:89` = 纯白、`T/assets/day.attheme:49` = `0xFF333333` | `telegram_theme.dart:98,128` 新增 `glassTabUnselected`；`home_shell.dart:1101-1104` 图标单独插值 `glassTabUnselected → glassTabSelected` | ✅ 已对齐（原先用 `textSecondary 0xFF8091A0` 当起点，官方暗色是纯白） | — |
| A29 | 图标动画：每 tab 一条 **lottie 双向**，选中播到 `endFrameMid`/末帧，取消 `setPlayInDirectionOfCustomEndFrame(true)` 倒放 | `T/GlassTabView.java:280-398` `checkPlayAnimation`；`:545-614` `TabAnimation`；资源 `res/raw/tab_{chats,contacts,settings,calls}.json` | `home_shell.dart:1095-1112` `AnimatedSwitcher` 交叉淡入 + 0.82→1 缩放，320ms（`_kIconMorphDuration`），曲线 easeOutCubic/easeInCubic | ⚠️ 近似（自定值）：按用户 2026-11-07 决策（m01702 方案 B）不引 lottie 依赖。本机 tgs 帧数自相矛盾（`tab_chats.json` 根 `op:6`、layer `op:179`），直接喂 lottie 只播前 6 帧；官方是路径变形，我方是图标交叉淡入，中间帧效果不同 | P4 |
| A30 | 图标/文字基线：图标 top4+24 → 底边 28；文字 top **28.33**，间隙 0.33dp | `T/GlassTabView.java:406,96` | `home_shell.dart:1078` `SizedBox(height: 0.33)`（原 2dp） | ✅ 已对齐 | — |

### A-8 文字

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| A31 | 字号 12dp | `T/GlassTabView.java:88` `setTextSize(COMPLEX_UNIT_DIP, 12f)` | `home_shell.dart:632` `fontSize: 12` | ✅ 一致 | — |
| A32 | 字重：默认 `AndroidUtilities.bold()` 实为 **medium(500)**，选中 `TYPEFACE_ROBOTO_EXTRA_BOLD` | `T/GlassTabView.java:92,237`；`T/messenger/AndroidUtilities.java:253-267`（`useSystemBoldFont && SDK>=P` → `Typeface.create(null,500,false)`，否则 `TYPEFACE_ROBOTO_MEDIUM`） | `home_shell.dart:1088`（及 `:1149`）未选中 `w500`、选中 `w800` | ✅ 已对齐 | — |
| A33 | 垂直位置：文字绝对定位 top 28.33 | `T/GlassTabView.java:96` `createFrame(MATCH_PARENT, WRAP_CONTENT, CENTER_HORIZONTAL\|TOP, 0, 28.33f, 0, 0)` | `home_shell.dart:1057-1078` 改为顶部对齐（`MainAxisAlignment.start` + top 4 + 0.33 间隙 = 等效 top 28.33），原 Column 居中已删 | ✅ 已对齐 | — |
| A34 | 文字色 `blendARGB(colorDefault, colorSelectedText)`，端点 `glass_tabUnselected → glass_tabSelectedText` | `T/GlassTabView.java:255,270-276`；`T/Theme.java:3705-3716`（两个 key 都 fallback 到 `chat_messagePanelSend`） | `telegram_theme.dart:97,127` 新增 `glassTabSelectedText = Color(0xFF229AF0)`；`home_shell.dart:1106-1109` 文字单独插值，`:1212-1215` 头像槽文字同款 | ✅ 已对齐（官方两套端点同源，但代码路径独立，我方也拆成 iconColor/textColor 两条） | — |
| A35 | 单行 + 尾部截断 | `T/GlassTabView.java:89-91` `setSingleLine(true)` / `setLines(1)` / `setEllipsize(END)` | `home_shell.dart:1081-1082`（及 `:1140-1141`）`maxLines: 1` + `TextOverflow.ellipsis` | ✅ 已对齐 | — |
| A36 | 居中对齐 | `T/GlassTabView.java:93` `setGravity(CENTER)` + 宽 MATCH_PARENT | `home_shell.dart:616` Column 居中 | ✅ 一致 | — |

### A-9 角标

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| A37 | 高度 16 | `T/GlassTabView.java:181` `height = dpf2(16)` | `home_shell.dart:1197` `height: 16`（原 15） | ✅ 已对齐 | — |
| A38 | 圆角 `rOuter=dpf2(9.333)` / `rInner=dpf2(8)` + `gap=dpf2(1.33)` 挖洞环 | `T/GlassTabView.java:178-193`（先 `Theme.PAINT_CLEAR` 画圆角矩形挖洞再 `inset(gap,gap)`） | `home_shell.dart:1249-1250` `radius: 8`，无挖洞环 | ⚠️ 不做：Flutter 侧复刻需 `saveLayer` + `BlendMode.clear` 包裹整个胶囊，每帧多一次离屏合成；16dp 角标上 1.33dp 的环肉眼不可辨。按用户「性能优先」决策跳过 | — |
| A39 | 宽度 `max(height, counter.getCurrentWidth() + dp(8))` | `T/GlassTabView.java:183` | `home_shell.dart:1196-1197` `minWidth: 16` + `height: 16`，宽度由 `IntrinsicWidth` + `padding: horizontal 4` 撑开（等效 +8） | ✅ 已对齐 | — |
| A40 | 位置 `cx = viewWidth/2 + dpf2(11)`、`cy = dpf2(10)` —— 相对 **tab** 定位 | `T/GlassTabView.java:179-180` | `home_shell.dart:1071-1072` `right: -7, top: 2`（相对 24dp 图标折算，等效中心 +11/+10，原 -8/-4） | ✅ 已对齐 | — |
| A41 | 文本 `LocaleController.formatNumber(unreadCount, ',')` —— 千位逗号、**无上限** | `T/MainTabsActivity.java:400-412` | `home_shell.dart:1174-1183` `_TabBadge._format` 每 3 位插逗号、负数带前缀、无 99+ 截断 | ✅ 已对齐 | — |
| A42 | 底色 `blendARGB(key_telegram_color 0xFF229AF0, key_fill_RedNormal 0xffeb5e5e, errorFactor)` | `T/GlassTabView.java:208`；`T/ThemeColors.java:14,98` | `home_shell.dart:1228` `_kBadgeFill = Color(0xFF229AF0)` 固定品牌蓝（**不再用 `TelegramColors.accent`**：我方强调色暗 0xFF61A3D7 / 亮 0xFF3390EC 都不是官方品牌蓝） | ✅ 静止态对齐（errorFactor 恒 0；错误态角标我方无调用方） | — |
| A43 | 字号 10dp + bold + 白 | `T/GlassTabView.java:98-103` | `home_shell.dart:735-739` `fontSize: 10` + `w700` + 白 | ✅ 字号/色一致（字重见 A32） | — |
| A44 | 出现动画 380ms `EASE_OUT_QUINT` | `T/GlassTabView.java:68` | `home_shell.dart:709,716` 380ms `Cubic(0.22,1,0.36,1)` | ✅ 一致 | — |
| A45 | 数字变化 | `T/GlassTabView.java:98` `AnimatedTextView.AnimatedTextDrawable` 自带位移/渐变 | `home_shell.dart:730-731` `AnimatedSwitcher(160ms)` | ⚠️ 实现不同，观感近似 | P3 |
| A46 | Premium 角标 `usePremiumCounter` → `PremiumGradient` + 星形 | `T/GlassTabView.java:167-218` | 无 | ❌ 缺失（功能不存在） | P4 |
| A47 | 角标 alpha/几何乘 `attachScale` | `T/GlassTabView.java:167` | 无 | ❌ 缺失 | P4 |

### A-10 按下 / 长按 / 拖动

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| A48 | 按下缩放 `lerp(1,1.019f,factor)`，380ms `EASE_OUT_QUINT`，作用于**整个 layout** | `T/MainTabsLayout.java:436-439` | `home_shell.dart:462-464` `_kPressDuration=380ms` / `_kEaseOutQuint` / `_kPressScale=1.019`；`:494-498` `_pressCtrl`；`:762-775` `Matrix4` 作用于整个底栏 | ✅ 已对齐 | — |
| A49 | 长按时长 `500ms × 750/1000` = **375ms** | `T/me/vkryl/android/util/ClickHelper.java:49` 默认 `ViewConfiguration.getLongPressTimeout()`=500；`T/MainTabsLayout.java:484-486` 覆写 `*750/1000` | `home_shell.dart:471` `_kLongPress = Duration(milliseconds: 375)` | ✅ 已对齐 | — |
| A50 | 长按后拖动不因 slop 取消 | `T/MainTabsLayout.java:461-463` `needCancelTouchBySlopMove()` 返回 false | `home_shell.dart:425-471` 拖动中不取消 | ✅ 一致 | — |
| A51 | 拖动命中：`findNearestVisibleChildByX` 取**最近 tab 中心** + `clampXToChildrenCenters` 夹首末 | `T/MainTabsLayout.java:613-670` | `home_shell.dart:693-710` `_indexAt` 按 `_tabLefts[i] + _tabWidths[i]/2` 取最近中心；`:625-637` `_clampToCenters` 夹首末；硬编码 4 等分已删 | ✅ 已对齐 | — |
| A52 | 落定回弹：`SpringAnimation` 到 `found.getX()+vw/2`，`STIFFNESS_MEDIUM`+`DAMPING_RATIO_LOW_BOUNCY` | `T/MainTabsLayout.java:357-359,396-429` | `home_shell.dart:482-487` `SpringDescription(mass:1, stiffness:1500, damping:0.6*2*sqrt(1500))`；`:650-676` 松手 `animateWith(SpringSimulation)` 弹到 `_centerOf(target)` | ✅ 已对齐 | — |
| A53 | 拖动中 selector：layout 自绘，宽在**两 tab 宽之间线性插值**（`getInterpolatedWidthByX`），高 `getHeight()-padding`，圆角 高/2，色 `multAlpha(key_glass_tabSelected, 0.09)` | `T/MainTabsLayout.java:289,310-324,672-718` | `home_shell.dart:862-889` `_dragSelector()`：`:605-623` `_widthAt` 相邻宽度线性插值、高 `tabHeight`=48、圆角 24、`accent × 0.09` | ✅ 已对齐 | — |
| A54 | pivot：`checkPivot` `mappedR=1.5r/(r+0.5)`、`pivotY=lerp(cy,pivotY,3f)` —— 纵向放大 3 倍 | `T/MainTabsLayout.java:563-604` | `home_shell.dart:548-570` `_updatePivot` 复刻 `mappedR = 1.5*r/(r+0.5)`，`pivotY` 纵向 3 倍，`Matrix4` 以该 pivot 缩放 | ✅ 已对齐 | — |
| A55 | 长按弹层：CHATS→`openFoldersSelector`、CONTACTS→`openContactsSelector`、CALLS→`openCallsSelector`、PROFILE→`openAccountSelector` | `T/MainTabsActivity.java:320-323`、`:414-520`、`:604-660` | `home_shell.dart:1098` / `:1152` `onLongPress: () {}` —— **官方四个弹层对应的功能我方全部不存在**：CHATS 是会话文件夹（官方 `filters.size() <= 1` 时也 `return false`，等于无操作）、CONTACTS 是新建联系人 + 最近通话、CALLS 是建群通话/显隐通话 tab、PROFILE 是多账号切换。我方是单账号、无文件夹、无通话的 QQ 客户端，硬造这四个弹层等于凭空造功能 | — 功能不存在（等同官方 `filters.size()<=1` 的 return false 分支） | — |
| A56 | 点击归属：`addTabToIgnoreClick` 让 layout 的 `ClickHelper` 接管 | `T/MainTabsActivity.java:325-328`；`T/MainTabsLayout.java:441-470` | `home_shell.dart:609` 每个 tab 各自 `InkWell` | ⚠️ 架构不同（不影响观感） | P4 |

### A-11 收起 / 显隐 / fade

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| A57 | 收起动画：`BoolAnimator(..., EASE_OUT_QUINT, 380, true)`，`translationY = lerp(hiddenY, normalY, factor)`，`hiddenY = normalY + dp(40)` | `T/MainTabsActivity.java:1073-1087`；`:110-111` | 窄屏 `home_shell.dart:322-336` `AnimatedSlide(150ms easeOutCubic, Offset(0,0.35))` + `AnimatedOpacity(150ms)` —— 窄屏收起由"进对话"触发，故意与 `_kPaneShift`(150ms) 同节拍；宽屏滚动收起**已删除**（见 A61），故 40dp/380ms 那套当前无调用方 | ⚠️ 窄屏时长为有意耦合；宽屏已无此行为 | P3 |
| A58 | 收起时缩放：`scale = lerp(0.85f,1f,factor)` **算出后从未使用（死变量）** | `T/MainTabsActivity.java:1080` | `home_shell.dart:338-368` 宽屏 `AnimatedScale(0.85)` 380ms | ⚠️ **我方做了官方没启用的行为** | — |
| A59 | 收起时交互：`setClickable(factor>1)`、`setEnabled(factor>1)` | `T/MainTabsActivity.java:1083-1084` | `home_shell.dart:322-323` 窄屏 `IgnorePointer(ignoring: !showBar)`、`:363-364` 宽屏 `IgnorePointer(ignoring: _barHidden)` | ✅ 已对齐（用布尔量近似连续因子） | — |
| A60 | 收起时可见性：`setAlpha(factor)` + `setVisibility(factor>0)` | 同上 | `home_shell.dart:310-328` `AnimatedOpacity` 150ms | ✅ 近似 | — |
| A61 | 触发源：**不是滚动**。官方底栏只在「搜索态」或「进会话转场 blurredView 可见」时收起，由 `animatorTabsVisible` 连续因子驱动 | `T/DialogsActivity.java:14076-14082` `checkUi_mainTabsVisible()`：`mainTabsVisible = !searching && (blurredView == null \|\| getBackground() == null \|\| getAlpha() < 0.01f \|\| getVisibility() == GONE)`；调用点 8 处（搜索开关 :3363/:3394、转场 :8975/:9001 等） | `home_shell.dart` 已**删除** `_onBarScroll` / `_scrollAccum` / `_barHidden` 与宽屏 `NotificationListener` 整套滚动收起逻辑（2026-11-07），`_collapsibleBar` 改名 `_sidebarBar` 只做定位 | ✅ 已删除自造行为（我方无搜索态、进会话由 `showBar` 让位，见 A70） | — |
| A62 | fade 进"我的"页：`setTranslationY(isProfile * dp(48))`，三键导航时 `hide` 淡出，`tabletLayout` 强制 0 | `T/MainTabsActivity.java:1055-1071` | `home_shell.dart:311-322` `AnimatedPositioned(380ms easeOut, bottom: _tab == 3 ? -48 : 0)`，内部 blur σ16 + 双色渐变 + `AnimatedOpacity` 保留 | ✅ 已对齐（下移 48dp；三键导航淡出未做，平板不叠底栏见 A69） | — |
| A63 | 通话 tab 显隐：`setChildVisibilityFactor` `alpha=factor`、`scale=lerp(0.7f,1f,factor)` | `T/MainTabsLayout.java:223-229`；`T/MainTabsActivity.java:354` | 无通话 tab，故无此机制 | ❌ 缺失（前提是 tab 数不同，见 A10） | P4 |

### A-12 页面切换与行为

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| A64 | 同 tab 点击：**任意** tab → `TabFragmentDelegate.onParentScrollToTop()` | `T/MainTabsActivity.java:334-349` | `home_shell.dart:109-126` 按索引分片 `tabScrollToTopProvider(index)`；`contacts_page.dart`/`settings_page.dart`/`my_profile_page.dart` 各套 `ScrollToTopScope(tab: 1/2/3)`，`home_page.dart:1281` 监听 `tab: 0` | ✅ 已对齐（四个 tab 都回顶，220ms 动画属自定值） | — |
| A65 | 手势中忽略点击：`viewPager.isManualScrolling() \|\| isTouch()` 直接 return | `T/MainTabsActivity.java:334-349` | `lib/ui/widgets/horizontal_pager.dart:79-82` 新增 `_notifyAnimating`（microtask 派发避开 build 期 setState）；`home_shell.dart:95` `_pagerAnimating` 字段 + `:112` 为真时 `_selectTab` 直接 return | ✅ 已对齐 | — |
| A66 | 让位高度：`normalY = -(updateLayoutHeight)` 由内容动态算 | `T/MainTabsActivity.java:1073-1087` | `home_shell.dart:185,195` 改用 `_MainTabBar.wrapperHeight`（72）+ `bottomInset`，不再写死 56+8+8 | ⚠️ 已消写死值，但仍非内容动态测量 | P3 |
| A67 | 切页动画 | `T/MainTabsActivity.java:334-349` `selectTab(position,true)` + `scrollToPosition` | `lib/ui/widgets/horizontal_pager.dart` 320ms `Cubic(0.22,1,0.36,1)`，旧页新页相向平移 | ⚠️ 实现不同，观感近似 | P3 |
| A68 | 硬件层：`checkLayerType` scale≠1 时切 `LAYER_TYPE_HARDWARE` | `T/MainTabsLayout.java:552-560` | Flutter 自动 | — 平台差异，不计为偏差 | — |

### A-13 既有条目（保留）

| # | 差异项 | TG 依据 | 我方现状 | 结论 | 优先级 |
|---|---|---|---|---|---|
| A69 | 宽屏（平板）没有底部悬浮 tab | `T/MainTabsActivity.java:99-103`；`:314` `new GlassTabView[5]`；`:307` 写死 `tabletLayout = false`（`isTablet()` 已注释）→ 官方平板也叠同一套底栏 | `home_shell.dart:151-183` `if (wide)` 分支走的是三栏工作台 + 左栏胶囊，**不是**官方那套「全屏列表 + 底部悬浮胶囊」；`_sidebarBar`（`:346`）只定位不收起 | ⚠️ **刻意偏差**，注释写在 `:10-18`。要不要改成官方那样（平板也全屏列表 + 底部胶囊）待拍板 | **P1** 待拍板 |
| A70 | 进会话时底栏让位（滑出+淡出） | 官方聊天页全屏 push | `home_shell.dart:109` `showBar = !(_tab == 0 && _chatPaneOpen)`；`:167-175` AnimatedSlide/Opacity | ✅ 一致（还额外做了 150ms 同步节拍） | — |

### A-14 "板感"五个根因（按影响排序）—— 2026-11-07 全部已修

1. **A1/A2** 没有 72dp 槽 + 背景内缩 7.666dp —— 官方是"一片玻璃浮在 72 高的槽里，四周留 7.666dp 空气"，我方是"胶囊撑满 56"。**已修**：`home_shell.dart:472-478` `wrapperHeight=72` / `capsuleInset=7.666` / `contentPadding=12-7.666`。
2. **A11/A12** 底色 0.80 硬叠 —— 官方 `solveSrcColor` 反解，叠完正好等于目标色；硬叠会让玻璃发"脏"。**已修**：`lib/ui/widgets/glass_capsule_border.dart` `solveSrcColor()` + `home_shell.dart:722+` `_capsuleFill()`。
3. **A14** 描边 1.0dp 单色 —— 官方 0.4dp + 上下异色，是"边缘反光"；单色线框视觉上变"卡片"。**已修**：`glass_capsule_border.dart` `GlassCapsuleBorder`（`CustomPaint` 上下两段，暗色按用户 m00304 决定不做白描边）。
4. **A15** 阴影 σ16/dy4 —— 官方 σ2.667/dy0.85 是贴地薄影，σ16/dy4 是卡片投影。**已修**：`blurRadius: 3.75`（= `(2.667-0.5)/0.57735`）+ `offset(0, 0.85)` + 亮 `0x20000000` / 暗 `0x04FFFFFF`。
5. **A19/A20** 选中底板 radius16 + 内缩 2dp —— 官方 `min(w,h)/2` 铺满的完整胶囊。**已修**：`home_shell.dart:996-1020` 铺满 + 圆角 24。

### A-15 修复顺序（2026-11-07 用户 m00304 已拍板「顺序可以按照你的想法」）

| 批次 | 项 | 内容 | 状态 |
|---|---|---|---|
| ① | A11 A12 A13 A14 A15 | 底色反解 + 0.4dp 描边 + 贴地薄影（纯参数） | ✅ 2026-11-07 完成 |
| ② | A1 A2 A3 A4-A10 | 72dp 槽 + 背景内缩 7.666dp + 四周 12dp + 三档降级 + 320dp 最小总宽 | ✅ 2026-11-07 完成 |
| ③ | A19 A20 A26 A27 A30 A32 A33 A35 A37 A39 A40 A41 | 底板铺满胶囊 + 图标 24 + 头像 22 圆角 11 + 字重/基线/角标 | ✅ 2026-11-07 完成 |
| ④ | A48 A49 A51 A52 A53 A54 A25 | 长按 375ms + 按下 1.019/380ms + 最近中心 + 弹簧 + selector 插值 + pivot + 长按禁画底板 | ✅ 2026-11-07 完成 |

**剩余未做（批次⑤）**：A16 blur 半径自定值、A17/A18 液态玻璃、A23/A28/A34 主题色仍不等于官方值、A29 lottie 图标动画、A38 角标挖洞环、A42 角标错误态、A45 数字切换、A55 长按弹层空实现、A57 收起 150ms vs 380ms、A58 保留（官方死变量）、A59 收起后仍可点、A61 二值判定、A62 fade 进"我的"下移 48dp、A64 同 tab 回顶只覆盖 1/4、A65 手势中忽略点击、A66 让位仍非动态测量、A69 平板是否叠底栏待拍板。

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
| D1 | 气泡垂直布局 | `T/Cells/ChatMessageCell.java:7759,20579-20605` 正文+19.5；bounds按上下相邻分别调整 | 上8/下11.5，不额外增加组首外距；shape负责bounds及2dp内缩 | ✅ 已修正文背景度量；Flutter文字度量仍有平台差异 | — |
| D2 | 正文水平定位 | `T/Cells/ChatMessageCell.java:16657-16682` 出站11；入站有后继时相对背景11，否则17 | 入站无尾背景向内6，加正文11，总坐标仍17；出站11 | ✅ 文本坐标关系已对齐 | — |
| D3 | 发送者名 bold 14sp + 七色轮转（顺序固定 Red/Orange/Violet/Green/Cyan/Blue/Pink） | `T/Theme.java:8038-8039` namePaint = bold(dp(14))；`UserObject.java:212-216` `(int)(id % 7)` | `telegram_theme.dart` `_nameColorsDark` 抄 darkblue.attheme、`_nameColorsLight` 抄 day.attheme 覆写+内置 default；`message_bubble.dart` fontSize 14 / **w700** / height 1.2 | ✅ 已删掉旧代码在暗色下 `lerp(white,0.18)` 的自造提亮 | — |
| D4 | 名字区高度 | `:18989` `namesOffset += getNameHeight()`，其中 `getNameHeight() = dp(5) + namePaint.getTextSize() = 19` | `message_bubble.dart` 名字 `height: 1.2`（16.8）+ `bottom: 3` ≈ 19.8 | ✅ 与官方 19 基本一致 | — |
| D5 | 消息左侧头像 42dp、x=6 | `:13839` `avatarImage.setImageCoords(dp(6), y, dp(42), dp(42))` | `telegram_theme.dart:292` `bubbleAvatarSize = 42`；槽宽 42+14（`home_page.dart:2541-2544`） | ✅ | — |
| D6 | 近角只收发送者侧 | `T/ActionBar/MessageDrawable.java:704-731` 上近角及无尾下近角=min(6,rad)，另一侧恒rad | `TgBubbleShape(isFirst,isLast)`；不再把四角改成直角 | ✅ 普通文本近角条件已对齐 | — |
| D7 | 时间戳 | `Theme.java:8408` timePaint = dp(12)；`:13826/13828` timeX 出站 `layoutWidth-timeWidth-dp(38.5)`、入站 `backgroundWidth-dp(9)-timeWidth`；`:16712` 行尾留 `timeWidth + dp(4 + (isOut?20:0))` | 时间用 `WidgetSpan` 贴正文行底（`PlaceholderAlignment.bottom`），左边距 4dp、出站再跟 14dp 状态勾 | ⚠️ 结构仍是行内流式，非绝对定位；字号/间距已按官方 | P3 |

| D10 | 普通连发每条独立背景，文本只有末条带尾巴 | `T/ChatActivity.java:37905-38047` → `T/Cells/ChatMessageCell.java:6884-6919,20531-20617` → `T/ActionBar/MessageDrawable.java:675-803` | 非末条选择无尾近角路径，末条83°尾弧；`lastInGroup`贯通列表、聊天页与金样helper | ✅ 已撤回“currentMessagesGroup=普通连发共用背景”的错误解释；19952实际是复选框绘制，不是证据 | — |
| D11 | 投影不等同于无投影 | 官方存在阴影drawable；Flutter BoxShadow曾造成明显黑边 | 当前不设shadows，避免假黑边 | ⚠️ 明确取舍，并非与官方像素完全等同 | P3 |
| D12 | 图片无尾背景 | `T/ActionBar/MessageDrawable.java:725-731` TYPE_MEDIA无尾、近角仍保留 | 图片用无尾shape+ClipPath，纯图inset=0 | ⚠️ 已纠正直角拼接；相册多格、媒体专属裁剪/边距未完整移植 | P3 |
| D8 | 五分钟分组边界 | `T/ChatActivity.java:37905-38047` 同方向、同发送者、时间差≤300秒 | `sameGroup`精确比较Duration≤5分钟，保留跨天、系统消息与未读分隔断组 | ✅ 时间边界已修正；QQ消息类型映射不声称全等 | — |
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
2. ~~**P1-D1**：气泡上下内边距 14 → 19.5~~ —— 2026-11-06 已修（见 D1/D10/D11）。
3. **P2-F1**：图片壁纸/图案/模糊 —— 缺口最大，工作量也最大。
4. P3 若干：会话行高 70→72、会话名字重 w600→BOLD、时间绝对定位、右侧键 48→44。

## 已核实的参数与边界（不代表整体无差异）

- 气泡左右内边距 11 / 17（`ChatMessageCell.java:16657-16718` ↔ `message_bubble.dart` `fromLTRB`）
- 发送者名 14sp bold + id%7 七色两套真值（`Theme.java:8038-8039`、`UserObject.java:212-216`、darkblue/day.attheme）
- 普通文本背景选择、发送者侧6dp近角、83°尾弧已按源码修正；阴影、媒体相册、文字与时间布局仍存在差异。
- 消息头像 42dp、偏移 6dp（`ChatMessageCell.java:13839`）
- 输入栏结构（胶囊内左 emoji、内右 attach、右侧 send/mic）与 18sp/6 行/44dp 标准高
- 5 分钟合组、未读分隔线断组、底部 tab 的 56/28/344 胶囊形态