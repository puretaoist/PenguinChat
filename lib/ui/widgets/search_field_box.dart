/// 搜索输入框——会话列表与聊天页共用一套几何。
///
/// 官方两套实现并存，参数一致到只差圆角：
/// * `Components/SearchField.java`（ActionBar 内用，聊天页走这条）：
///   高 `dp(36)`、圆角 `dp(18)`、文字 `16sp`、高 `40` / top `9`、
///   左 `margin+2+38`、右 `margin+2+30`；放大镜独立 `36×36`，left = margin+2；
///   清除钮 `36×36`、`setSide(dp(7))`、初始 `scale 0.1 / alpha 0`，
///   有字时 `150ms` 补间；点清除后重新弹键盘（`:81-84`）。
/// * `Components/FragmentSearchField.java`（会话列表走这条）：
///   圆角 `dp(20)`、内边距 `dp(3)`、文字左右各 `dp(48)`、
///   底色暗色 `key_windowBackgroundWhiteBlackText` alpha **0.07**（`:279`）。
///
/// 底色沿用官方：亮色 `key_dialogSearchBackground = 0xfff2f4f5`
/// （`ThemeColors.java:57`），暗色白色 7%（`FragmentSearchField.java:279`）。
/// 暗色不能用 `bgHover`——它和顶栏 `bgHeader` 几乎同色，框会看不见边界。
library;

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';

class SearchFieldBox extends StatefulWidget {
  const SearchFieldBox({
    super.key,
    required this.controller,
    required this.focusNode,
    this.hintText = '搜索',
    this.height = 36,
    this.radius = 18,
    this.onSubmitted,
    this.onChanged,
    this.onCleared,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;

  /// 框高。`SearchField.java:44` 是 36；聊天页顶栏变形后与胶囊同高时传 46。
  final double height;

  /// 圆角。`SearchField.java:44` 是 18，`FragmentSearchField.java:212` 是 20。
  final double radius;

  final ValueChanged<String>? onSubmitted;

  /// 输入变化。注意 [TextEditingController.clear] 不会触发它，
  /// 所以清空得单独用 [onCleared] 告诉调用方。
  final ValueChanged<String>? onChanged;

  /// 点了清除按钮（已经清空文本并重新拿到焦点）。
  ///
  /// 官方 `SearchField.java:77-84` 清空后页面得自己知道「查询词变空了」。
  final VoidCallback? onCleared;

  final bool autofocus;

  @override
  State<SearchFieldBox> createState() => _SearchFieldBoxState();
}

class _SearchFieldBoxState extends State<SearchFieldBox> {
  /// 清除钮的动画时长：`SearchField.java:139-144` 的 `setDuration(150)`。
  static const Duration _clearDuration = Duration(milliseconds: 150);

  /// 文字字号：`SearchField.java:104` 的 `setTextSize(16)`。
  static const double _fontSize = 16;

  /// 光标：`SearchField.java:114-116` 高 `dp(20)`、宽 `1.5`。
  static const double _cursorHeight = 20;
  static const double _cursorWidth = 1.5;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: Stack(
        children: <Widget>[
          // 底色：整块圆角矩形。
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: TelegramColors.isDark
                    ? Colors.white.withValues(alpha: 0.07)
                    : const Color(0xFFF2F4F5),
                borderRadius: BorderRadius.circular(widget.radius),
              ),
            ),
          ),
          // 放大镜：独立 36×36，left = 2（SearchField.java:57-59 的 margin+2）。
          Positioned(
            left: 2,
            top: 0,
            width: 36,
            height: widget.height,
            child: Icon(
              Icons.search,
              size: 18,
              color: TelegramColors.textMuted,
            ),
          ),
          // 文字区：左 40 / 右 32（官方 dp(54)/dp(46) 扣掉 margin dp(14)）。
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.only(left: 40, right: 32),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextField(
                  key: const ValueKey<String>('search-input'),
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  autofocus: widget.autofocus,
                  onChanged: widget.onChanged,
                  onSubmitted: widget.onSubmitted,
                  textInputAction: TextInputAction.search,
                  cursorColor: TelegramColors.accent,
                  cursorHeight: _cursorHeight,
                  cursorWidth: _cursorWidth,
                  style: TextStyle(
                    color: TelegramColors.textPrimary,
                    fontSize: _fontSize,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    hintText: widget.hintText,
                    hintStyle: TextStyle(
                      color: TelegramColors.textMuted,
                      fontSize: _fontSize,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 清除钮：36×36 贴右，150ms alpha + scale(0.1→1)。
          Positioned(
            right: 0,
            top: 0,
            width: 36,
            height: widget.height,
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (BuildContext context, TextEditingValue value, _) {
                final bool hasText = value.text.isNotEmpty;
                return IgnorePointer(
                  ignoring: !hasText,
                  child: AnimatedOpacity(
                    duration: _clearDuration,
                    opacity: hasText ? 1 : 0,
                    child: AnimatedScale(
                      duration: _clearDuration,
                      scale: hasText ? 1 : 0.1,
                      child: IconButton(
                        key: const ValueKey<String>('search-clear'),
                        onPressed: () {
                          widget.controller.clear();
                          // 官方清空后重新弹键盘（SearchField.java:81-84）。
                          widget.focusNode.requestFocus();
                          widget.onCleared?.call();
                        },
                        padding: EdgeInsets.zero,
                        iconSize: 18,
                        icon: Icon(
                          Icons.cancel,
                          color: TelegramColors.textMuted,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
