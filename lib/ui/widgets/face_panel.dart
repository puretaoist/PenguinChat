/// QQ 表情选择面板（输入框旁的表情按钮打开）。
///
/// ## 表情图从哪来
///
/// 来自 `assets/faces/faces.pqf`（265 条：110 个 Lottie 矢量 + 155 个 WebP，
/// 见 [FacePack]）。数据源是 [QFace](https://github.com/koishijs/QFace)（MIT，
/// 资源版权归腾讯）。按用户 2026-11-07 的决定：范围取全部数字 id、存成单文件
/// 二进制包、名字冲突以 QFace 为准、不要 Unicode 原生 emoji。
///
/// 包没加载（测试环境、资源缺失）时整个面板回退到旧的「中文名文字格」，所以
/// 既有测试断言 `face-微笑` 仍然成立——那种情况下点一下照样插入 `/微笑`。
///
/// ## 布局参数（全部照 TG `T/ui/Components/EmojiView.java`）
///
/// **分类条在顶部，不在底部**（2026-11-08 修正）：
/// * `EmojiView.java:1956` `emojiContainer.addView(emojiTabs, createFrame(MATCH_PARENT, 36))`
///   —— 分类条是**顶部 36dp**；
/// * `EmojiView.java:1958-1964` `emojiTabsShadow`，`topMargin = dp(36)`
///   —— 36dp 处一条阴影线；
/// * 底部那条 48dp 的 `bottomTabContainer`（`:2676`）是**贴纸包**分类条
///   （含退格 48×48 与贴纸设置），不是 emoji 分类条。旧版本注释把两者搞混了，
///   于是「位置抄 QQ、参数抄 TG」，几何全偏。
///
/// 网格：
/// * 每格宽 `45dp`（平板 60dp）自适应列数 —— `:3010-3013`
///   `emojiLayoutManager.setSpanCount(Math.max(1, width / dp(isTablet ? 60 : 45)))`
/// * 表情本身 `32dp`（平板 40dp）—— `:2819` `emojiSize = dp(isTablet ? 40 : 32)`
/// * 网格内边距左右 `5` —— `:1743`
///   `emojiGridView.setPadding(dp(5), dp(36), dp(5), dp(44))`
///   其中 **top 36 是给「浮在上面的分类条」让位**、bottom 44 是给「底部贴纸条」让位。
///   我方用 Column 顺序布局（分类条自己占 36），所以这两项都不需要了，
///   只留左右 5 与底部少量呼吸。
/// * 格子是正方形（边长 = 列宽）、内容居中、**无选中底色** —— `:1457` 的
///   `ImageViewEmoji` 用 `ScaleType.CENTER` + `:1744` `setItemSelectorColorProvider(p -> 0)`
///
/// 分类按钮（`EmojiTabsStrip.java`）：
/// * `30×30` 按钮、`24×24` 图标 —— `:1237` `setMeasuredDimension(dp(30), dp(30))`
///   + `:1240-1241` imageView 量 24
/// * 间距 `3dp` —— `:176` `x += child.getMeasuredWidth() + dp(3)`
/// * 选中态：**0.18 alpha 的 `key_chat_emojiPanelIcon` 圆角底色** —— `:748`
///   `Theme.multAlpha(getColor(key_chat_emojiPanelIcon), .18f)`，
///   圆角 `:259` `dp(lerp(8f, 16f, isEmojiTabs))`；`isEmojiTabs` 只在
///   「emoji 圆按钮」时为 1，普通分类按钮是 **8dp**。
/// * 选中横向微放大 `hw = rect.width()/2 * (1 + isMiddle*.3)` —— `:256-258`
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../kernel/wlogin8/qq8_elem.dart';
import '../face/face_image.dart';
import '../face/face_pack.dart';
import '../face/face_recents.dart';
import '../theme/telegram_theme.dart';
import 'glass_sheet.dart';

/// TG 的网格与分类条参数（`EmojiView.java` / `EmojiTabsStrip.java`，见文件头）。
const double _kCellExtent = 45;
const double _kEmojiSize = 32;
const double _kGridPadH = 5;

/// 顶部分类条高度（`EmojiView.java:1956`）。
const double _kTabStripHeight = 36;
const double _kTabButton = 30;
const double _kTabIcon = 24;

/// 分类按钮之间的间距（`EmojiTabsStrip.java:176`）。
const double _kTabGap = 3;

/// 选中底色的 alpha（`EmojiTabsStrip.java:748` 的 `.18f`）。
const double _kTabSelectedAlpha = 0.18;

/// 选中底色的圆角（`EmojiTabsStrip.java:259`，普通分类按钮取 lerp 的 8 端）。
const double _kTabSelectedRadius = 8;

/// 网格上下边缘淡出的高度。
///
/// **出处与语义的诚实说明**：TG 在 `EmojiView.java:1741-1742` 里调的是
/// `setTopGlowOffset(dp(38))` / `setBottomGlowOffset(dp(36))`，而这两个值
/// 在 `androidx/recyclerview/widget/RecyclerView.java:4448-4485` 里是
/// **EdgeEffect 辉光的平移量**（滚动到边界时的「拉一下」光晕），
/// **不是**「内容渐隐成透明」。
///
/// 我方要的是后者（滚动时内容在上下边缘淡出，避免「切一半的表情」）。
/// 所以这里取 TG 那两个偏移值当**高度参照**，用 `ShaderMask` 实现淡出：
/// 38 与 36 平均后取整到 36，与 TG 底部值一致。
/// 这是**刻意的语义偏差**，不是「已对齐 TG」——按 `AGENTS.md` §1.8 登记为
/// 自定值。
const double _kFadeHeight = 36;


/// 弹出表情面板。选中一个就把它的 `/名字` 交给 [onPick]。
///
/// [recentsFile] 给了就会记录并展示「最近使用」；不给就不记录（测试用）。
///
/// [onBackspace] 给了才显示退格键（`EmojiView.java:2650` 的
/// `backspaceButton`）。面板本身不持有输入框，所以删除动作必须由调用方
/// 注入——这与 TG 一致（官方也是把点击转给 `delegate`）。
Future<void> showFacePicker(
  BuildContext context, {
  required void Function(String token) onPick,
  File? recentsFile,
  VoidCallback? onBackspace,
}) {
  return showGlassSheet<void>(
    context: context,
    builder: (ctx) => _FacePanel(
      onPick: onPick,
      recentsFile: recentsFile,
      onBackspace: onBackspace,
    ),
  );
}

class _FacePanel extends StatefulWidget {
  const _FacePanel({
    required this.onPick,
    this.recentsFile,
    this.onBackspace,
  });

  final void Function(String token) onPick;
  final File? recentsFile;
  final VoidCallback? onBackspace;

  @override
  State<_FacePanel> createState() => _FacePanelState();
}

class _FacePanelState extends State<_FacePanel> {
  late final FaceRecents _recents = FaceRecents(widget.recentsFile);
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _loadRecents();
  }

  Future<void> _loadRecents() async {
    await _recents.load();
    if (mounted) setState(() {});
  }

  void _pick(FaceEntry entry) {
    _recents.touch(entry.id);
    widget.onPick(entry.token);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final pack = FacePack.instance;
    if (pack == null) return _textFallback();

    final groups = <({String label, IconData icon, List<FaceEntry> items})>[
      (label: '经典', icon: Icons.emoji_emotions_outlined, items: pack.classic),
      (label: '超级', icon: Icons.auto_awesome_outlined, items: pack.others),
    ].where((g) => g.items.isNotEmpty).toList(growable: false);
    final safeTab = _tab.clamp(0, groups.length - 1);

    final recent = <FaceEntry>[
      for (final id in _recents.ids)
        if (pack.byId(id) case final FaceEntry e) e,
    ];

    return SafeArea(
      top: false,
      child: SizedBox(
        // 面板高度：TG 的 `emojiGridView` 撑满剩余空间，分类条固定 36。
        height: 340,
        child: Column(
          children: <Widget>[
            // 分类条在**顶部**（`EmojiView.java:1956`）。
            _tabStrip(groups, safeTab),
            // 分类条下方的分隔阴影（`EmojiView.java:1958-1964` 的
            // `emojiTabsShadow`，`topMargin = dp(36)` 即紧贴分类条底边）。
            Container(height: 0.5, color: TelegramColors.divider),
            if (recent.isNotEmpty) _recentsRow(recent),
            Expanded(
              // 上下边缘淡出：滚动时内容在边界处渐隐，而不是被硬切一半。
              // 见 [_kFadeHeight] 的出处说明（自定值，不是「已对齐 TG」）。
              child: ShaderMask(
                key: const ValueKey('face-grid-fade'),
                // `dstIn` = 用渐变 alpha 裁剪子树的输出。
                blendMode: BlendMode.dstIn,
                shaderCallback: (Rect bounds) {
                  // 按**实际高度**把 [_kFadeHeight] 换算成 stop：
                  // 固定百分比在不同面板高度下淡出距离会变，用像素更稳。
                  final h = bounds.height;
                  final f = h <= 0 ? 0.0 : (_kFadeHeight / h).clamp(0.0, 0.5);
                  return LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: const <Color>[
                      Color(0x00000000), // 顶部完全透明
                      Color(0xFF000000), // 进入 fadeHeight 后完全不透明
                      Color(0xFF000000), // 保持
                      Color(0x00000000), // 底部完全透明
                    ],
                    stops: <double>[0, f, 1 - f, 1],
                  ).createShader(bounds);
                },
                child: GridView.builder(
                  key: const ValueKey('face-grid'),
                  // `:1743` 左右 5；上下的 36/44 是给浮层让位的，我方用 Column
                  // 顺序布局，所以只留左右与底部少量呼吸。
                  padding: const EdgeInsets.fromLTRB(
                    _kGridPadH,
                    2,
                    _kGridPadH,
                    _kGridPadH,
                  ),
                  clipBehavior: Clip.none,
                  // `:3010-3013` 每格 45dp 自适应列数。
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: _kCellExtent,
                  ),
                  itemCount: groups[safeTab].items.length,
                  itemBuilder: (context, i) {
                    final e = groups[safeTab].items[i];
                    return _FaceCell(
                      entry: e,
                      onTap: () => _pick(e),
                      onLongPress: () => _preview(e),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 最近使用：一行 32dp 的图，横向滚动。
  Widget _recentsRow(List<FaceEntry> recent) {
    return SizedBox(
      height: 44,
      child: ListView(
        key: const ValueKey<String>('face-recents'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: _kGridPadH),
        children: <Widget>[
          for (final e in recent)
            _FaceCell(
              entry: e,
              size: _kEmojiSize,
              onTap: () => _pick(e),
              onLongPress: () => _preview(e),
            ),
        ],
      ),
    );
  }

  /// 顶部分类条（`EmojiView.java:1956` 的 `emojiTabs`，高 36dp）。
  ///
  /// 与旧实现的差别（都是「抄错对象」造成的）：
  /// * 位置从底部移到**顶部**；
  /// * 高度 48 → **36**；
  /// * 按钮之间补 **3dp 间距**（`EmojiTabsStrip.java:176`）；
  /// * 选中态从「只换图标颜色」改成 **0.18 alpha 的圆角底色 + 图标变强调色**
  ///   （`EmojiTabsStrip.java:748` + `:259`）；
  /// * 右侧补**退格键**（`EmojiView.java:2650-2661` 的 `backspaceButton`）。
  Widget _tabStrip(
    List<({String label, IconData icon, List<FaceEntry> items})> groups,
    int active,
  ) {
    return SizedBox(
      height: _kTabStripHeight,
      child: Row(
        children: <Widget>[
          const SizedBox(width: 6),
          for (int i = 0; i < groups.length; i++) ...<Widget>[
            _TabButton(
              key: ValueKey<String>('face-tab-$i'),
              icon: groups[i].icon,
              tooltip: groups[i].label,
              active: i == active,
              onTap: () => setState(() => _tab = i),
            ),
            if (i != groups.length - 1) const SizedBox(width: _kTabGap),
          ],
          const Spacer(),
          // 退格键（`EmojiView.java:2650-2661`）。
          //
          // 官方是 48×48 贴在底部条右侧（`:2677` `createFrame(48, 48,
          // Gravity.BOTTOM | Gravity.RIGHT, 2, 0, 2, 0)`）。我方分类条在顶部
          // 且只有 36 高，所以按 30×30 放进这一条（与分类按钮同尺寸），
          // 右边距 2 —— 与官方那个 2dp 一致。
          //
          // 官方还给这个键挂了 `setHapticFeedbackEnabled(true)`（`:2647`），
          // 这里用 `HapticFeedback.selectionClick()` 对齐「按一下有轻微反馈」。
          if (widget.onBackspace != null)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Tooltip(
                message: '退格',
                child: InkWell(
                  key: const ValueKey('face-backspace'),
                  borderRadius: BorderRadius.circular(_kTabSelectedRadius),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    widget.onBackspace!();
                  },
                  child: SizedBox(
                    width: _kTabButton,
                    height: _kTabButton,
                    child: Icon(
                      Icons.backspace_outlined,
                      size: _kTabIcon,
                      // `:2651` 官方用 `key_chat_emojiPanelBackspace`，
                      // 我方对应 `textMuted`。
                      color: TelegramColors.textMuted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 长按预览：一张放大的图 + 名字。
  void _preview(FaceEntry entry) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (ctx) => GestureDetector(
        onTap: () => Navigator.of(ctx).pop(),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FaceImage.preview(entry),
              const SizedBox(height: 10),
              Text(
                entry.token,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 没有资源包时的旧行为：一格一个中文名。
  Widget _textFallback() {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Row(
              children: <Widget>[
                Text(
                  'QQ 表情',
                  style: TextStyle(
                    color: TelegramColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '点一下插入 /名字，发送时变成表情',
                  style: TextStyle(
                    color: TelegramColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: GridView.count(
              key: const ValueKey('face-grid'),
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              crossAxisCount: 6,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              childAspectRatio: 1.25,
              shrinkWrap: true,
              children: <Widget>[
                for (final id in Qq8FaceNames.common)
                  _FaceTile(
                    name: Qq8FaceNames.nameOf('$id') ?? '',
                    onTap: () {
                      final name = Qq8FaceNames.nameOf('$id');
                      if (name == null) return;
                      widget.onPick('/$name');
                      Navigator.of(context).pop();
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一格表情：正方形、内容居中、无选中底色（`EmojiView.java:1457`）。
class _FaceCell extends StatelessWidget {
  const _FaceCell({
    required this.entry,
    required this.onTap,
    required this.onLongPress,
    this.size = _kEmojiSize,
  });

  final FaceEntry entry;
  final double size;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey<String>('face-${entry.name}'),
      // `:1458` 背景是 `createRadSelectorDrawable(key_listSelector, dp(2), dp(2))`
      // ——按下才有一点圆角反馈，选中态没有底色。
      borderRadius: BorderRadius.circular(2),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Center(child: FaceImage.grid(entry, size: size)),
    );
  }
}

/// 分类条上的一个按钮（`EmojiTabsStrip.java:1237` 的 30×30）。
///
/// 选中态照官方两处：
/// * 底色 `Theme.multAlpha(key_chat_emojiPanelIcon, .18f)`（`:748`）；
/// * 圆角 `dp(lerp(8, 16, isEmojiTabs))`，普通分类按钮取 8（`:259`）。
class _TabButton extends StatelessWidget {
  const _TabButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(_kTabSelectedRadius),
        onTap: onTap,
        child: Container(
          width: _kTabButton,
          height: _kTabButton,
          decoration: active
              ? BoxDecoration(
                  // 官方用 `key_chat_emojiPanelIcon` 的 0.18 alpha。
                  // 我方调色板里与之对应的是 `textMuted`（都是「面板图标色」）。
                  color: TelegramColors.textMuted.withValues(
                    alpha: _kTabSelectedAlpha,
                  ),
                  borderRadius: BorderRadius.circular(_kTabSelectedRadius),
                )
              : null,
          child: Icon(
            icon,
            size: _kTabIcon,
            color: active ? TelegramColors.accent : TelegramColors.textMuted,
          ),
        ),
      ),
    );
  }
}

/// 无包回退用的文字格。
class _FaceTile extends StatelessWidget {
  const _FaceTile({required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey('face-$name'),
      borderRadius: BorderRadius.circular(8),
      onTap: name.isEmpty ? null : onTap,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: TelegramColors.bgHover,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: TelegramColors.textPrimary, fontSize: 12.5),
        ),
      ),
    );
  }
}
