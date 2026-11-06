/// L4 组件：TG 的消息操作浮层（**单击气泡**在气泡旁弹出的小菜单）。
///
/// 为什么要这个：TG Android 的交互是两套 ——
/// * **单击**气泡 → 贴着气泡弹一个 popup（200dp 宽、12dp 圆角、48dp 行高、
///   图标列 43dp、文字 15sp，其余区域压 20% 黑），见
///   `ChatMessageCell` 的 `NeedDivider`/`MessageMenu` 与 `ActionBarPopupWindow`
///   （`ui/Components/ActionBar/ActionBarPopupWindow.java`：宽度 dp(200)、
///   `setAnimationStyle` 200ms、背景 `Theme.chat_actionsBackground`）；
/// * **长按**气泡 → 直接进多选（不是弹菜单），由 `home_page.dart` 的
///   `_enterMessageSelection` 负责。
///
/// 我们以前只有「长按 → 底部 ActionSheet」一种形态，跟 TG 差一整套交互。
/// 动作清单仍由 [MessageActionsSheet.itemsFor] 生成（一份清单两套版面，
/// 避免两处各写一遍后漂掉）。
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';
import 'action_sheet.dart';

/// 浮层宽度：TG `ActionBarPopupWindow` 的 dp(200)。
const double kMessagePopupWidth = 200;

/// 单行高度：`ActionBarPopupWindow` 的 item 48dp。
const double kMessagePopupItemHeight = 48;

/// 圆角：12dp。
const double kMessagePopupRadius = 12;

/// 在 [anchor]（气泡的全局矩形）旁弹出操作菜单；返回的 Future 在浮层关闭后完成。
///
/// [outgoing] 决定贴在气泡哪一侧：自己发的气泡靠右，菜单出现在它的**左边**；
/// 别人发的靠左，菜单出现在它的**右边**（TG 的 popup 就是这么避让的）。
Future<void> showMessageActionPopup(
  BuildContext context, {
  required Rect anchor,
  required bool outgoing,
  required List<ActionSheetItem> items,
}) {
  final overlay = Overlay.of(context);
  final size = MediaQuery.sizeOf(context);
  final completer = Completer<void>();
  late OverlayEntry entry;
  var removed = false;

  void close() {
    if (removed) return;
    removed = true;
    entry.remove();
    if (!completer.isCompleted) completer.complete();
  }

  entry = OverlayEntry(
    builder: (_) => _MessageActionPopup(
      anchor: anchor,
      outgoing: outgoing,
      items: items,
      screenSize: size,
      onClosed: close,
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _MessageActionPopup extends StatefulWidget {
  const _MessageActionPopup({
    required this.anchor,
    required this.outgoing,
    required this.items,
    required this.screenSize,
    required this.onClosed,
  });

  final Rect anchor;
  final bool outgoing;
  final List<ActionSheetItem> items;
  final Size screenSize;
  final VoidCallback onClosed;

  @override
  State<_MessageActionPopup> createState() => _MessageActionPopupState();
}

class _MessageActionPopupState extends State<_MessageActionPopup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..forward();

  bool _closing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 先播完 200ms 的退场，再摘 OverlayEntry / 执行动作。
  void _close([VoidCallback? then]) {
    if (_closing) return;
    _closing = true;
    _controller.reverse().whenComplete(() {
      widget.onClosed();
      then?.call();
    });
  }

  /// 分隔线只画在危险动作（删除）前面，与 TG 的 `needDivider` 一致。
  int get _dividerCount {
    var n = 0;
    for (var i = 0; i < widget.items.length; i++) {
      if (i > 0 && widget.items[i].danger) n++;
    }
    return n;
  }

  double get _menuHeight =>
      widget.items.length * kMessagePopupItemHeight + _dividerCount;

  @override
  Widget build(BuildContext context) {
    final screen = widget.screenSize;
    // 贴边避让：左右各留 8dp，上边不压状态栏（16dp），下边留 16dp。
    final double rawLeft = widget.outgoing
        ? widget.anchor.left - kMessagePopupWidth - 8
        : widget.anchor.right + 8;
    final double maxLeft = screen.width - kMessagePopupWidth - 8;
    final double left = rawLeft.clamp(8.0, maxLeft < 8 ? 8.0 : maxLeft);
    final double maxTop = screen.height - _menuHeight - 16;
    final double top = widget.anchor.top.clamp(
      16.0,
      maxTop < 16 ? 16.0 : maxTop,
    );

    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    return Stack(
      children: <Widget>[
        // 20% 黑遮罩：点它关闭（TG 的 popup 外层就是这么收的）。
        Positioned.fill(
          child: GestureDetector(
            key: const ValueKey('message-popup-barrier'),
            behavior: HitTestBehavior.opaque,
            onTap: _close,
            child: FadeTransition(
              opacity: _controller,
              child: Container(color: Colors.black.withValues(alpha: 0.20)),
            ),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: kMessagePopupWidth,
          // TG 的 ActionBarPopupWindow 是"从锚点那侧弹出来"：0.85 → 1 的缩放 +
          // 200ms 淡入，并带一点点朝气泡方向的位移。只做淡入会像凭空出现，
          // 只做缩放又缺少方向感，两个一起才像从气泡边上长出来。
          child: AnimatedBuilder(
            animation: curve,
            builder: (_, Widget? inner) => Transform.translate(
              offset: Offset(
                (1 - curve.value) * (widget.outgoing ? 10 : -10),
                (1 - curve.value) * -6,
              ),
              child: inner,
            ),
            child: FadeTransition(
              opacity: _controller,
              child: ScaleTransition(
                // 从贴气泡那条边展开（自己发的从右上，别人的从左上）。
                alignment: widget.outgoing
                    ? Alignment.topRight
                    : Alignment.topLeft,
                scale: Tween<double>(begin: 0.85, end: 1).animate(curve),
                child: _menu(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _menu() {
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kMessagePopupRadius),
          boxShadow: <BoxShadow>[
            // 阴影收一档（原来 blur 18 / 45% 太重，像贴了一张黑胶带）：
            // TG 的 ActionBarPopupWindow 是 elevation 8 级别的柔和投影。
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.38),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        // 毛玻璃：菜单背后是照片时，纯色块会显得"贴"在图上；模糊一层
        // 既保住可读性，又让浮层和底下的内容有层次（TG 12+ 的 popup 也
        // 开始用 blur backdrops）。
        child: ClipRRect(
          borderRadius: BorderRadius.circular(kMessagePopupRadius),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              decoration: BoxDecoration(
                color: TelegramColors.bgHover.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(kMessagePopupRadius),
              ),
              // 描边画在 foregroundDecoration：Border.all 若写进 decoration
              // 会占掉左右 1dp 内边距，把行宽从 200 挤成 198。
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(kMessagePopupRadius),
                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (var i = 0; i < widget.items.length; i++) ...<Widget>[
                    if (i > 0 && widget.items[i].danger)
                      Container(height: 1, color: TelegramColors.divider),
                    _row(widget.items[i]),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(ActionSheetItem item) {
    final color = item.danger
        ? TelegramColors.danger
        : TelegramColors.textPrimary;
    return InkWell(
      key: item.key,
      onTap: item.onTap == null ? null : () => _close(item.onTap),
      child: SizedBox(
        height: kMessagePopupItemHeight,
        child: Padding(
          // 图标列 43dp：左边距 12 + 图标 20 + 间隔 11。
          padding: const EdgeInsets.only(left: 12, right: 12),
          child: Row(
            children: <Widget>[
              Icon(item.icon, size: 20, color: color),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontSize: 15),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
