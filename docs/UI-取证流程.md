# UI 取证流程 —— 把「读透官方调用链」变成可验收的动作

> 起因：2026-11-07 会话内搜索顶栏动画连续做错 5 版，用户原话「我一直强调读透官方调用链，
> 老是效果不好」。复盘后确认**不是框架问题、不是运气问题**，而是取证方法有结构性缺陷。
> 本文把方法固化成可逐条勾选的流程。违反本文 = 违反 `AGENTS.md` §1.8。

## 一、五版失败的真实归因（反面教材）

| 版本 | 我以为的 | 实际 | 错在哪一类 |
|---|---|---|---|
| v1 | 搜索动画 = `ActionBarMenuItem.toggleSearch` 的 150ms 淡入 | 那只是**内容**淡入；玻璃**背景**宽度是 `ActionBar.dispatchDraw` 里 320ms 形变 | 停在入口方法，没到绘制层 |
| v2 | 自己设计「从右往左挤压、群名被压掉」 | 官方没有这个动作 | 没取证就发明 |
| v3 | 搜索时消失的是 `headerItem` | `headerItem` 是**右上角 ⋮ 菜单**；消失的是 `avatarContainer`（头像+标题） | 名词指代错 |
| v4 | `AnimatedOpacity` 能做 150ms 淡入 | 首次挂载时目标值已是 1，没有 0→1 过程 | 没验证中间帧 |
| v5 | 照 `ActionBar.java:2232-2279` 的 lerp 公式 | 一次通过 | — |

**共同点：每次都「读了一个文件」，但从没读「一条链」。**

## 二、六条硬要求（按顺序执行，缺一条就是没做完）

### 要求 1：先交取证报告，用户确认后才准动代码

动 UI 代码前必须先输出一份报告，包含下文要求 2~5 的全部内容。
用户回「开始 / 可以 / 同意」才写第一行代码。

**为什么**：本仓库两次成功的 UI 重做（搜索 UI 四项、顶栏玻璃形变）都是先有报告；
四次失败全是直接动手。

### 要求 2：必须画出完整调用链，每个箭头带 `文件:行号`

固定格式，五段缺一不可：

```
触发点     ChatActivity.java:35378  openSearchWithText(text)
   ↓
状态字段   ChatActivity.java:47038  onFactorChanged → searchFactor
   ↓
动画器     ChatActivity.java:47069  BoolAnimator(320ms, EASE_OUT_QUINT)
   ↓
绘制方法   ActionBar.java:2232      dispatchDraw → width = lerp(...)
   ↓
参数       ActionBar.java:2233      p = dp(6), s = dp(46)
```

**画不出这条链，就说明没读完，不许动代码。**
可以直接对用户说「这块调用链我还没画出来，需要再挖 XXX」，不要硬写一版。

### 要求 3：必须读到「绘制层」，不能停在「入口方法」

动画的最终形态永远在这些方法里：

| 方法 | 找什么 |
|---|---|
| `onDraw` / `dispatchDraw` | 几何、宽度、位移、alpha、绘制顺序 |
| `onMeasure` / `onLayout` | 真实行高、内边距、子视图位置 |
| `onSizeChanged` | 尺寸变化的副作用（如重设 drawable bounds） |
| `getOutline` / `setBounds` | 裁剪与圆角 |

**搜 `dispatchDraw`，不要搜方法名。** 入口方法通常只 `setValue(true)` 改个标志位，
真正的插值在绘制层。

反例：`ActionBarMenuItem.toggleSearch`（`:935-1042`）里只有 150ms alpha；
玻璃宽度在 `ActionBar.dispatchDraw`（`:2232-2279`）里，**在另一个文件**。

### 要求 4：先做名词对齐表，再谈动画

官方术语逐个对应到我方哪个 widget，**动代码前必须列出来**：

| 官方 | 官方职责 | 我方对应 | 是否一致 |
|---|---|---|---|
| `headerItem` | 右上角 ⋮ 菜单（`ActionBarMenu` 的一项） | `PopupMenuButton(key:'group-menu')` | ✅ |
| `avatarContainer` | 头像 + 标题 + 副标题那一块 | `_middleContent` | ✅ |
| `searchItem` | 搜索框本体（`setIsSearchField(true)`） | `_SearchInput` | ✅ |
| `searchIconItem` | 独立放大镜（仅 self 且空间足才显示） | 已删除 | ✅ 官方普通群聊也 GONE |
| `otherIcon` | ⋮ 图标本体（`ComposeDrawable`） | `Icons.more_vert` | ✅ |
| `glassDrawable` | 标题玻璃背景 | 中间那颗 `GlassSurface.capsule` | ✅ |
| `glassDrawableBack` | 返回按钮玻璃 | 左侧返回胶囊 | ✅ |
| `glassDrawableMenu` | 菜单玻璃 | 右侧菜单胶囊 | ✅ |

**v3 就是死在这张表没做**——把 `headerItem`（⋮ 菜单）当成「头像+标题」，
于是以为「搜索时标题消失」是 `headerItem` 的可见性变化。

### 要求 5：参数表逐项带出处，缺项写「未取证」

| 参数 | 官方值 | 出处 | 我方值 | 状态 |
|---|---|---|---|---|
| 玻璃高度 | 58 | `ActionBar.java:2232` `s + 2p` | 58 | ✅ |
| 玻璃圆角 | 23 | `ActionBar.java:218` | 23 | ✅ |
| blur 半径 | **查不到** | `BlurredBackgroundSourceRenderNode.java:63` 只接外部传参 | 20 | ⚠️ 自定值 |

**官方查不到就写「未取证 / 自定值」**，并登记进 `docs/ui-parity-matrix.md`。
不许拿一个「差不多」的数冒充已对齐——`docs/PITFALLS.md` C123 就是这条债。

### 要求 6：中间帧测试 + 三张截图，不能只看终态

**测试**：必须 `pump(时长/2)` 断言中间值。

```dart
// ✅ 正确：证明它是渐变
await tester.pump(const Duration(milliseconds: 160));
final mid = tester.getSize(find.byKey(...)).width;
expect(mid, greaterThan(collapsed));
expect(mid, lessThan(expanded));

// ❌ 错误：只证明终态，一步到位也能过
await tester.pumpAndSettle();
expect(tester.getSize(find.byKey(...)).width, expanded);
```

**真机**：截开始 / 中间 / 结束三张。150ms 淡入不生效（v4）就是靠中间帧测试才发现的。

## 三、验收清单（提交前逐条打勾）

动 UI 代码的提交，在 commit message 正文里必须能回答这 6 个问题：

- [ ] 调用链画出来了吗？五段都有 `文件:行号` 吗？
- [ ] 读到 `dispatchDraw` / `onMeasure` / `onLayout` 了吗？
- [ ] 名词对齐表列了吗？有搞混的词吗？
- [ ] 每个常量都有出处吗？没有的标「自定值」了吗？
- [ ] 有中间帧测试吗？pump 到一半断言了吗？
- [ ] 真机截了三张吗（开始/中间/结束）？

## 四、什么时候可以跳过

只有两种情况：

1. **改的不是「形态」，只是「颜色/文案/纯数据」**——例如把 `0x20000000` 改成 `0x11000000`，
   前提是该常量已经在 `docs/ui-parity-matrix.md` 里有出处。
2. **已取证表里有现成的值**——`docs/HANDOFF.md` §8、`docs/blur-parity.md`、
   `docs/ui-parity-matrix.md`。这时**不许重复翻源码**，直接引用表里的行号。

其余一切形态类改动（尺寸、间距、圆角、动画、位移、透明度曲线）都必须走完六条。

## 五、常见误判对照

| 症状 | 真正原因 | 该去读哪 |
|---|---|---|
| 动画「一下就跳过去了」 | 组件首次挂载时目标值已是终值 | `TweenAnimationBuilder(begin: 0, ...)`，别用 `AnimatedXxx` |
| 动画「方向反了」 | 参数顺序/坐标系搞反 | 官方 `lerp(a, b, t)` 的 a/b 语义 |
| 「两个东西重叠」 | 官方本来就允许重叠（同一套 padding 体系） | 两个 drawable 的 `setBounds` 是否本就相交 |
| 「大小不对」 | 官方尺寸含/不含 padding | `onMeasure` 里是 `s` 还是 `s + 2p` |
| 「位置不对」 | 锚点算错（left/right/center） | `dispatchDraw` 里的 `left`/`right` 表达式 |

## 六、本次会话的正面例子（照这个做）

会话内搜索顶栏 v5 一次通过，过程是：

1. 读 `ChatActivity.java:35378-35418 openSearchWithText` → 知道谁 GONE、谁 VISIBLE
2. 读 `ChatActivity.java:46995-47004` → 知道 `avatarContainer` 的 `factor = 1 - searchFactor`
3. 读 `ChatActivity.java:47069-47070` → 拿到 320ms `EASE_OUT_QUINT`
4. **读 `ActionBar.java:2232-2279 dispatchDraw`** → 拿到宽度 lerp 公式与 `left` 居中算法
5. 读 `ActionBar.java:2171-2175` → 确认 320ms 属于玻璃宽度、150ms 属于内容
6. 列名词对齐表 → 确认「同一块玻璃扩宽」，不是「另摆一个搜索框」
7. 写代码 + 中间帧测试 + 三张真机截图

**关键差别在第 4 步**——前面 4 版都没读到绘制层。
