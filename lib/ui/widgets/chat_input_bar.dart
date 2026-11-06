/// L4 表现层：聊天输入栏（回复条 + 表情/附件/文本框/发送钮）。
///
/// 从 home_page.dart 抽出的**纯哑视图**：输入控制器与回调由 [HomePage]
/// 注入，本组件不读 provider、不发网络。附件与表情不依赖连接状态
/// （没连线也能选图/选表情），只有文本框与发送钮受 [enabled] 控制。
///
/// 版面照 TG `ChatActivityEnterView`（13.1.1）：
///   - **悬浮胶囊**：不再有整宽面板底色，只有一颗浮在消息之上的圆角胶囊，
///     左右各 8dp、离底 8dp，壁纸/消息从胶囊下方穿过（对齐 AyuGram 截图）；
///   - 胶囊内左侧表情键 44×44、右侧回形针 44×44（:2755 / :2840）；
///   - 文字内距左 52 / 右 50（:5822 createFrame(..., 52, 0, isChat ? 50 : 2, 1.5f)）；
///   - 最小高 44（DEFAULT_HEIGHT :6469，onMeasure 里 max(dp(44), ...) :2665）；
///   - 18sp、最多 6 行（:5810-5811）；
///   - 有字时回形针 alpha→0 / scale 0.5 隐藏，发送键 0.1 缩放淡入
///     （:7945-7979 / :8061-8069 checkSendButton）；
///   - 高度变化 150ms 动画（animatorInputFieldHeight :15608-15613）；
///   - 多行滚动时输入框上下 13dp 渐隐（drawMessageEditText :15539-15583）。
/// 整条仍用 Positioned 浮在列表上（列表底部按 [reserve] 留白），是"浮层"。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../client_api/objects.dart';
import '../theme/motion.dart';
import '../theme/telegram_theme.dart';
import 'glass_sheet.dart';
import 'voice_record_button.dart';

/// 聊天输入栏。[replyTarget] 非空时在输入行上方显示"正在回复"条。
class ChatInputBar extends StatelessWidget {
  const ChatInputBar({
    super.key,
    required this.enabled,
    required this.controller,
    this.replyTarget,
    required this.onSend,
    required this.onAttachImage,
    this.onAttachImagePath,
    required this.onAttachFile,
    required this.onOpenFaces,
    required this.onCancelReply,
    this.onVoiceRecorded,
  });

  /// 输入栏整体高度（48dp 胶囊 + 8dp 离底间隙）。它仍以浮层方式压在列表上，
  /// 消息列表底部要按这个值留白，否则最后一条会被胶囊压住。
  static const double overlayHeight = 56;

  /// 浮层实际压住的底部高度：overlayHeight 之外还要算上 SafeArea 的手势条。
  /// 只写 44 的话，真机上（手势条 24dp）最后一条会被胶囊压掉一截。
  /// 留白请统一调这个函数。
  static double reserve(BuildContext context) =>
      overlayHeight + MediaQuery.paddingOf(context).bottom;

  /// false = 未连接：输入框禁用、发送钮变灰（提示文案换成"未连接"）。
  final bool enabled;
  final TextEditingController controller;

  /// 正在回复的消息；null = 不显示回复条。
  final ChatMessage? replyTarget;
  final VoidCallback onSend;
  final VoidCallback onAttachImage;

  /// "填路径发送图片"的兜底入口；为空时不显示那一项（桌面/测试环境）。
  final VoidCallback? onAttachImagePath;
  final VoidCallback onAttachFile;
  final VoidCallback onOpenFaces;
  final VoidCallback onCancelReply;

  /// 录音完成（裸 PCM 文件路径 + 时长 + 波形）。为空时麦克风键只提示"按住说话"，
  /// 不做任何上行——widget 测试与未接线的场景都走这条路。
  final Future<void> Function(
    String pcmPath,
    int durationMs,
    List<double> waveform,
  )?
  onVoiceRecorded;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    // 胶囊填充色：深色用 bgSidebar（比壁纸只亮一档；之前用 bgHover 亮太多，
    // 像贴了块浅灰板）。真正透出来的模糊由外层 BackdropFilter 负责，这里只
    // 决定玻璃的浓淡，浅色主题用 bgChat。
    final Color fieldColor = dark
        ? TelegramColors.bgSidebar
        : TelegramColors.bgChat;
    return Container(
      // 悬浮胶囊：外层不再画整宽面板底色/顶线/阴影，改成透明的安全区容器，
      // 只由里面那颗胶囊 + 右侧圆键表现"浮起"。
      color: Colors.transparent,
      child: SafeArea(
        top: false,
        child: Padding(
          // 左右各 8dp、离底 8dp（AyuGram 胶囊四周都留边，不贴屏幕边）。
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // 回复条用尺寸 + 淡入过渡：直接 if 插进来会让整个输入区"跳"
                  // 一下，TG 的 reply panel 是从上往下展开的。
                  AnimatedSwitcher(
                    duration: Motion.fast,
                    switchInCurve: Motion.enter,
                    switchOutCurve: Motion.exit,
                    transitionBuilder: (child, animation) => SizeTransition(
                      sizeFactor: animation,
                      alignment: Alignment.topCenter,
                      child: FadeTransition(opacity: animation, child: child),
                    ),
                    child: replyTarget == null
                        ? const SizedBox.shrink()
                        : _replyStrip(replyTarget!),
                  ),
                  // 高度动画：换行/多行时 150ms 平滑长高（官方
                  // animatorInputFieldHeight，:15608-15613）。
                  AnimatedSize(
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.bottomCenter,
                    child: Row(
                      // 输入框长高时（最多 6 行）两侧按钮贴着底边——同 TG：
                      // 键盘弹起、正文变高时按钮不跟着浮到中间。
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        Expanded(
                          // 悬浮胶囊 + 真毛玻璃：AyuGram 那颗胶囊的玻璃感来自
                          // 背后一层 blur，而不是单纯换个填充色。阴影必须留在
                          // 最外层 Container——画在被 ClipRRect 裁的内部会被裁掉。
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: <BoxShadow>[
                                BoxShadow(
                                  color: Colors.black.withValues(
                                    alpha: dark ? 0.22 : 0.06,
                                  ),
                                  blurRadius: 10,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(24),
                              child: BackdropFilter(
                                filter: ui.ImageFilter.blur(
                                  sigmaX: 20,
                                  sigmaY: 20,
                                ),
                                child: Container(
                                  constraints:
                                      const BoxConstraints(minHeight: 48),
                                  decoration: BoxDecoration(
                                    // 半透明填充：让下面 blur 上来的壁纸透一点，
                                    // 这才是玻璃；完全不透明会把 blur 盖死。
                                    color: fieldColor.withValues(
                                      alpha: dark ? 0.72 : 0.86,
                                    ),
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                  // 描边放 foregroundDecoration：写进 decoration
                                  // 会和圆角裁剪打架、还可能吃内边距。
                                  foregroundDecoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(24),
                                    border: Border.all(
                                      color: TelegramColors.divider.withValues(
                                        alpha: dark ? 0.6 : 0.9,
                                      ),
                                      width: 0.5,
                                    ),
                                  ),
                                  child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: <Widget>[
                                // 表情键在**胶囊内左侧** 44×44：TG
                                // `ChatActivityEnterView.java:2755`
                                // createFrame(DEFAULT_HEIGHT, DEFAULT_HEIGHT,
                                //   BOTTOM|LEFT, 2, 0, 0, 0)，padding 7.5。
                                _ghostIcon(
                                  key: const ValueKey('open-faces'),
                                  icon: Icons.emoji_emotions_outlined,
                                  tooltip: 'QQ 表情',
                                  onTap: onOpenFaces,
                                  size: 26,
                                  box: 48,
                                ),
                                Expanded(
                                  child: _GrowingField(
                                    controller: controller,
                                    enabled: enabled,
                                    onSubmitted: onSend,
                                    fieldColor: fieldColor,
                                  ),
                                ),
                                // 📎 回形针在**胶囊内右侧** 44×44（:2840）。
                                // 有字时官方把它 alpha→0 / scale 0.5 收起来
                                // （checkSendButton :7945-7979），空输入才显示。
                                ValueListenableBuilder<TextEditingValue>(
                                  valueListenable: controller,
                                  builder: (context, value, child) {
                                    final bool show =
                                        value.text.trim().isEmpty;
                                    return AnimatedOpacity(
                                      opacity: show ? 1 : 0,
                                      duration: const Duration(
                                        milliseconds: 100,
                                      ),
                                      child: AnimatedScale(
                                        scale: show ? 1 : 0.5,
                                        duration: const Duration(
                                          milliseconds: 100,
                                        ),
                                        curve: Curves.easeOut,
                                        child: IgnorePointer(
                                          ignoring: !show,
                                          child: child,
                                        ),
                                      ),
                                    );
                                  },
                                  child: _ghostIcon(
                                    key: const ValueKey('attach'),
                                    icon: Icons.attach_file_rounded,
                                    tooltip: '附件',
                                    size: 24,
                                    box: 48,
                                    onTap: () => _pickAttachment(context),
                                  ),
                                ),
                              ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // 右侧：有字才是发送（纸飞机，accent 底）；空输入时是麦克风。
                        // 胶囊外独立一个圆键（AyuGram 的麦克风/发送圆与胶囊之间
                        // 留 8dp），直径与胶囊同高 48。
                        SizedBox(
                          width: 48,
                          height: 48,
                          child: Center(
                            child: ValueListenableBuilder<TextEditingValue>(
                              valueListenable: controller,
                              builder: (context, value, _) {
                                final bool hasText =
                                    value.text.trim().isNotEmpty;
                                final Widget action;
                                if (!hasText) {
                                  final onVoice = onVoiceRecorded;
                                  action = VoiceRecordButton(
                                    key: const ValueKey('send-or-mic'),
                                    enabled: enabled,
                                    size: 48,
                                    onRecorded: (pcm, waveform) async {
                                      if (onVoice == null) return;
                                      await onVoice(
                                        pcm.path,
                                        pcm.durationMs,
                                        waveform,
                                      );
                                    },
                                    onError: (message) {
                                      final messenger =
                                          ScaffoldMessenger.maybeOf(context);
                                      messenger?.showSnackBar(
                                        SnackBar(
                                          content: Text(message),
                                          duration: const Duration(seconds: 2),
                                        ),
                                      );
                                    },
                                  );
                                } else {
                                  action = _SendButton(
                                    key: const ValueKey('send-button'),
                                    active: enabled,
                                    onTap: onSend,
                                  );
                                }
                                // 两态之间 150ms 淡入 + 0.1→1 缩放：官方
                                // checkSendButton 把发送键从 scale 0.1 / alpha 0
                                // 拉起来（:8061-8069），不是硬切。
                                return AnimatedSwitcher(
                                  duration: Motion.fast,
                                  switchInCurve: Motion.enter,
                                  switchOutCurve: Motion.exit,
                                  transitionBuilder: (child, animation) =>
                                      FadeTransition(
                                        opacity: animation,
                                        child: ScaleTransition(
                                          scale: Tween<double>(
                                            begin: 0.1,
                                            end: 1,
                                          ).animate(animation),
                                          child: child,
                                        ),
                                      ),
                                  child: action,
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 一个不带底色/水波纹的图标键（输入栏两侧的小按钮都用它，尺寸统一）。
  Widget _ghostIcon({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    double size = 22,
    double box = 44,
  }) => IconButton(
    key: key,
    onPressed: onTap,
    tooltip: tooltip,
    iconSize: size,
    padding: EdgeInsets.zero,
    constraints: BoxConstraints.tightFor(width: box, height: box),
    icon: Icon(icon, color: TelegramColors.textSecondary, size: size),
  );

  /// 附件入口：TG 的点回形针 = 底部弹出「图片 / 文件」两项。
  Future<void> _pickAttachment(BuildContext context) async {
    final picked = await showGlassSheet<String>(
      context: context,
      radius: 16,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      // 毛玻璃外壳由 GlassSheet 提供（内部就是 Material，ListTile 的水波纹
      // 不会像夹一层 DecoratedBox 那样被遮住）。
      builder: (sheetContext) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                key: const ValueKey('attach-file'),
                leading: Icon(
                  Icons.image_outlined,
                  color: TelegramColors.textSecondary,
                ),
                title: Text(
                  '发送图片',
                  style: TextStyle(color: TelegramColors.textPrimary),
                ),
                onTap: () => Navigator.of(sheetContext).pop('image'),
              ),
              if (onAttachImagePath != null)
                ListTile(
                  key: const ValueKey('attach-image-path'),
                  leading: Icon(
                    Icons.folder_open_outlined,
                    color: TelegramColors.textSecondary,
                  ),
                  title: Text(
                    '按路径发送图片',
                    style: TextStyle(color: TelegramColors.textPrimary),
                  ),
                  onTap: () => Navigator.of(sheetContext).pop('image-path'),
                ),
              ListTile(
                key: const ValueKey('attach-local-file'),
                leading: Icon(
                  Icons.insert_drive_file_outlined,
                  color: TelegramColors.textSecondary,
                ),
                title: Text(
                  '发送文件',
                  style: TextStyle(color: TelegramColors.textPrimary),
                ),
                onTap: () => Navigator.of(sheetContext).pop('file'),
              ),
            ],
          ),
        ),
    );
    if (!context.mounted) return;
    if (picked == 'image') onAttachImage();
    if (picked == 'image-path') onAttachImagePath?.call();
    if (picked == 'file') onAttachFile();
  }

  /// 输入框上方的"正在回复"条（点 ✕ 取消）。
  Widget _replyStrip(ChatMessage target) => Container(
    key: const ValueKey('reply-strip'),
    margin: const EdgeInsets.only(bottom: 6),
    padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
    decoration: BoxDecoration(
      color: TelegramColors.bgHover,
      borderRadius: BorderRadius.circular(10),
      border: Border(left: BorderSide(color: TelegramColors.accent, width: 3)),
    ),
    child: Row(
      children: <Widget>[
        Icon(Icons.reply_rounded, size: 16, color: TelegramColors.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '回复 ${target.senderName.isEmpty ? target.senderId : target.senderName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: TelegramColors.accent,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                target.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: TelegramColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          key: const ValueKey('reply-cancel'),
          onPressed: onCancelReply,
          icon: Icon(
            Icons.close_rounded,
            size: 18,
            color: TelegramColors.textSecondary,
          ),
          tooltip: '取消回复',
        ),
      ],
    ),
  );
}

/// 会随内容长高（最多 6 行）的输入区：滚动到底/顶时，上下各叠 13dp 渐隐，
/// 同官方 drawMessageEditText（`ChatActivityEnterView.java:15539-15583`）。
class _GrowingField extends StatefulWidget {
  const _GrowingField({
    required this.controller,
    required this.enabled,
    required this.onSubmitted,
    required this.fieldColor,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSubmitted;
  final Color fieldColor;

  @override
  State<_GrowingField> createState() => _GrowingFieldState();
}

class _GrowingFieldState extends State<_GrowingField> {
  final ScrollController _scroll = ScrollController();
  bool _canUp = false;
  bool _canDown = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_syncOverflow);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncOverflow());
  }

  @override
  void dispose() {
    _scroll.removeListener(_syncOverflow);
    _scroll.dispose();
    super.dispose();
  }

  void _syncOverflow() {
    if (!mounted || !_scroll.hasClients) return;
    final ScrollPosition p = _scroll.position;
    final bool up = p.pixels > 0.5;
    final bool down = p.pixels < p.maxScrollExtent - 0.5;
    if (up != _canUp || down != _canDown) {
      setState(() {
        _canUp = up;
        _canDown = down;
      });
    }
  }

  Widget _fade(bool top) => Positioned(
    top: top ? 0 : null,
    bottom: top ? null : 0,
    left: 0,
    right: 0,
    height: 13,
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: top ? Alignment.topCenter : Alignment.bottomCenter,
            end: top ? Alignment.bottomCenter : Alignment.topCenter,
            colors: <Color>[
              widget.fieldColor,
              widget.fieldColor.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        TextField(
          controller: widget.controller,
          scrollController: _scroll,
          enabled: widget.enabled,
          onSubmitted: (_) => widget.onSubmitted(),
          // 输入框随内容长高，最多 6 行后内部滚动——TG 的
          // `ChatActivityEnterView.java:5810` setMaxLines(6)。
          minLines: 1,
          maxLines: 6,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.send,
          // 18sp：TG `ChatActivityEnterView.java:5811` setTextSize(18sp)。
          style: TextStyle(
            color: TelegramColors.textPrimary,
            fontSize: 18,
          ),
          decoration: InputDecoration(
            hintText: widget.enabled ? '输入消息…' : '未连接',
            // hint 只占一行：窄栏（平板分栏右栏）里长 hint 会被换行、把胶囊撑高。
            hintMaxLines: 1,
            hintStyle: TextStyle(color: TelegramColors.textSecondary),
            border: InputBorder.none,
            isDense: true,
            // 官方文字内距左 52 / 右 50（:5822），emoji 键 44+2、回形针 44
            // 已占掉 46/44，这里再补左 6 / 右 4 就是 52/50。
            contentPadding: const EdgeInsets.only(
              left: 6,
              right: 4,
              top: 12,
              bottom: 12,
            ),
          ),
        ),
        if (_canUp) _fade(true),
        if (_canDown) _fade(false),
      ],
    );
  }
}

/// 发送键：44dp 实心圆 accent 底，按下 0.9 缩放（官方 SendButton 无外发光，
/// 只做按压缩小 + 图标居中）。
class _SendButton extends StatefulWidget {
  const _SendButton({super.key, required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.active ? (_) => setState(() => _pressed = true) : null,
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.active ? widget.onTap : null,
      child: AnimatedScale(
        scale: _pressed ? 0.9 : 1,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: widget.active
                ? TelegramColors.accent
                : TelegramColors.bgHover,
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.send_rounded,
            color: widget.active ? Colors.white : TelegramColors.textMuted,
            size: 22,
          ),
        ),
      ),
    );
  }
}
