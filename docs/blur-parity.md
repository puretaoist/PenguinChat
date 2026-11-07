# 模糊（blur）覆盖对照：官方 13.1.1 vs 本项目

官方源码根：`C:/Users/Administrator/penguis/telegram-src/TelegramAndroid/TMessagesProj/src/main/java`
我方源码根：`C:/Users/Administrator/penguis/qqclient/lib`

## 一、官方模糊体系的构成

官方 13.x 的模糊不是零散 BackdropFilter，而是一套 blur3 框架（RenderNode 捕获 + RenderScript 实时模糊 + 液态玻璃参数）：

- 引擎/基础类（`org/telegram/ui/Components/blur3/`）：
  - `drawable/BlurredBackgroundDrawable.java`、`...RenderNode.java`、`...Source.java`
  - `drawable/color/BlurredBackgroundColorProvider*.java`、`...Provider{Build,rImpl}.java`
  - `source/BlurredBackgroundSource{Bitmap,Color,RenderNode,Wrapped}.java`
  - `BlurredBackgroundWithFadeDrawable.java`（模糊 + 按高度淡出，对应官方 fadeView）
  - `BlurredBackgroundDrawableViewFactory.java`（给任意 View 生成玻璃背景）
  - `Blur3HashImpl.java`、`utils/Blur3Utils.java`（缓存/工具）
- 宿主控件：`Components/BlurredRecyclerView.java`（列表上下边缘模糊）、`BlurredFrameLayout.java`、`BlurredLinearLayout.java`、`BluredView.java`（整页背景模糊层）、`BlurBehindDrawable.java`（把内容画进模糊源的 tag 机制）
- 专用玻璃控件：`Components/chat/buttons/ChatActivityBlurredRoundButton.java`、`ChatActivityBlurredRoundPageDownButton.java`

## 二、官方所有使用点（按界面）

| # | 界面/场景 | 官方位置 | 我方现状 |
|---|---|---|---|
| 1 | 聊天页顶栏（navbar）玻璃背景 | ChatActivity.java:2679-2703 `glassBackgroundDrawableFactory(Frosted)`，源 = wallpaper / navbarContent RenderNode | ❌ 缺（chat_header 实色） |
| 2 | 聊天页输入区玻璃 | 同上 factory（ChatActivity.java:2679-2703） | ✅ 已做（chat_input_bar 悬浮胶囊 + BackdropFilter σ20） |
| 3 | 聊天页消息列表顶部/底部淡出模糊 | Components/chat/layouts/ChatActivityFadeView.java:18-50（fadeDrawableTop + fadeDrawableBottom） | ⚠️ 只有底部 60dp（且在 tab 页，home_shell），聊天页内顶部缺 |
| 4 | 聊天页悬浮圆按钮（下滚、频道静音/加入、提及） | Components/chat/buttons/ChatActivityBlurredRoundButton.java（8 处）、ChatActivityBlurredRoundPageDownButton.java（7 处） | ❌ 缺（jump_to_latest 实色圆） |
| 5 | 聊天页整页背后模糊（抽屉/浮层打开时） | ChatActivity.java:595 `BluredView blurredView`、:11859 构造、:17789-17825 `BlurBehindDrawable.TAG_DRAWING_AS_BACKGROUND` | ❌ 缺（无整页模糊层） |
| 6 | 聊天页滚动遮罩模糊 | ChatActivity.java:1029 `scrimBlur3Factory` | ❌ 缺 |
| 7 | 会话列表（上下边缘模糊 + 液态玻璃按钮 + 转场） | DialogsActivity.java:1702 `DialogsRecyclerView extends BlurredRecyclerView`、:2808-2821 `iBlur3Factory{FrostedLiquidGlass,LiquidGlass,Blur,Fade}`、:4880 fadeDrawable、:5451 转场 BlurredRecyclerView | ❌ 缺（chat_list_panel 实色滚动） |
| 8 | 主界面底部 tab 胶囊玻璃 + 60dp 淡出 | MainTabsActivity.java:362-375（iBlur3SourceTabGlass + BlurredBackgroundWithFadeDrawable） | ⚠️ 已做但参数偏差，见下 |
| 9 | 附件面板 | Components/ChatAttachAlert.java（8 处，整屏面板玻璃） | ⚠️ 我方是底部弹层（已 GlassSheet 玻璃），形态与官方整屏 attach alert 不同 |
| 10 | 所有 BottomSheet 底部弹层 | Components/ActionBar/BottomSheet.java 等框架级 | ✅ 已做（glass_sheet.dart，9 处弹层） |
| 11 | 图片查看器背景模糊 | PhotoViewer.java（6 处） | ❌ 缺（我方无全屏查看器，message_content.dart:710 仅内联预览） |
| 12 | 资料页 / 头像预览 | ProfileActivity.java（8 处）、Components/ProfileGalleryBlurView.java、ProfileGalleryView.java（3 处） | ❌ 缺 |
| 13 | 公告条 / 分享 / 礼物 / 会员页 / 主题色页 / 话题 / 频道管理日志 / 快转头像 | Components/Bulletin.java（11）、ShareAlert.java（8）、Gifts/SelectGiftsBottomSheet.java（4）、PremiumPreviewFragment.java（9）、PeerColorActivity.java（8）、TopicsFragment.java（4）、ChannelAdminLogActivity.java（4）、quickforward/BlurVisibilityDrawable.java | ❌ 缺（多数功能我方尚未实现） |
| 14 | 模糊参数设置项（radius / alpha / saturation） | ui/BlurSettingsBottomSheet.java:22-107（`blurRadius`、`blurAlpha`、`Theme.key_chat_BlurAlpha`） | ❌ 缺（我方无模糊强度设置） |
| 15 | 图片 blur-up 占位（渐进加载） | 非 blur3，官方用 image loader 自带 | ✅ 已做（blur_up_image.dart，σ10 + 淡入） |
| 16 | 操作菜单 / 长按弹层玻璃 | ActionBar 系 BottomSheet | ✅ 已做（action_sheet σ18、message_action_popup σ18） |

## 三、结论

- 官方模糊 = 16 个可感知面，我方已覆盖 6 个（2/8/10/15/16 + 部分 3/9）。
- **缺口集中在聊天页与会话列表**：#1 顶栏玻璃、#3 聊天页顶部 fade、#4 悬浮圆按钮玻璃、#5 整页背景模糊、#6 滚动遮罩、#7 列表边缘模糊。
- 其中 #1/#3/#4 是每天可见的细节；#5/#6 是抽屉/浮层场景；#7 是会话列表滚动质感。
- 我方实现手段是 Flutter `BackdropFilter`（每帧采样，配合 `ClipRect` 限制范围）；官方是 RenderNode 捕获 + RenderScript，能做"液态玻璃"（折射/饱和度）。Flutter 侧只能近似，无法 1:1 复刻折射。

## 四、主 tab 胶囊的模糊参数取证结果（2026-11-07）

| 参数 | 官方值 | 取证 | 我方现值 | 状态 |
|---|---|---|---|---|
| blur 半径 | **查不到** | `Components/blur3/drawable/BlurredBackgroundSourceRenderNode.java:63-70` `setBlur(float radius)` 只接收外部传参；`BlurredBackgroundDrawableViewFactory`、`BlurredBackgroundDrawable` 均未写死；`MainTabsActivity.java:362-369` 创建玻璃背景时**没有**调用 `setBlur` | `sigmaX/Y: 20`（`home_shell.dart:506-507`） | ⚠️ **自定值**。参照物：`Stories/PeerStoriesView.java:549` 用 `dp(8)`、`iv/RichMediaCell.java:153` 用 `dp(24)`、`community/cells/CommunityPendingRequestCell.java:76` 用 `dp(7)` |
| 底色 alpha | 0.76 / 0.85 | `BlurredBackgroundProviderImpl.java:24` | 0.80 | ❌ 待改为 `solveSrcColor` 反解 |
| 叠色算法 | 反解源色 | `BlurredBackgroundProviderImpl.java:304-332` `src = clamp(round((out - bg*(1-a))/a),0,255)` | 直接叠 alpha | ❌ 待改 |
| 描边宽 | 0.4dp | `BlurredBackgroundProviderImpl.java:33` | 1.0dp | ❌ 待改 |
| 描边色（亮） | top `0x11000000` / bottom `0x20000000` | `BlurredBackgroundProviderImpl.java:29-30` | `divider` 单色 | ❌ 待改 |
| 描边色（暗） | top `0x06FFFFFF` / bottom `0x11FFFFFF` | 同上 | `divider` 单色 | ⚠️ **用户已决定不做白色玻璃描边**（m00304） |
| 阴影 | `0x20000000`(亮)/`0x04FFFFFF`(暗)、σ`2.667dp`、dy`0.85dp` | `BlurredBackgroundProviderImpl.java:31-32` | 黑 0.28、σ16、dy4 | ❌ 待改 |
| 底部淡出高度 | 60dp，`setFadeHeight(dp(60), true)` | `MainTabsActivity.java:375-376` | `60 + bottomInset` | ✅ 一致 |
| 液态玻璃 | `LiteMode.isEnabled(FLAG_LIQUID_GLASS)` | `MainTabsActivity.java:364` | 无 | ❌ Flutter 无法做折射/饱和度 |

**结论**：官方主 tab 胶囊的 blur 半径在本机源码中**无法取证**（只传参不写死），我方 σ20 只能登记为自定值；
其余 5 项参数（alpha 算法、描边、阴影）有明确出处，可严格对齐。完整 68 项见 `docs/ui-parity-matrix.md` §A。

## 五、建议优先级

- P1：聊天页顶栏玻璃、聊天页底部 fade 改为聊天页内实现、下滚圆按钮玻璃。
- P2：会话列表上下边缘模糊 + 会话列表 FAB 玻璃。
- P3：图片查看器（先补功能再加模糊背景）。
- P4：资料页 / 其余弹层，随功能实现补。
