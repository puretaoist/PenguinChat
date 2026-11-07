/// 搜索输入框——会话列表、聊天页顶栏、设置页、群成员面板共用一套实现。
///
/// 官方有**两套**搜索框，参数只差在几处细节，这里用 [SearchFieldBox.fragment]
/// 区分：
///
/// ### 一、`Components/SearchField.java`（ActionBar 内联，聊天页/设置页/群成员）
/// * 高 `dp(36)`、圆角 `dp(18)`、top `11`、左右 `horizontalMargin`（`:44-48`）
/// * 放大镜独立 `36×36`、left = `margin+2`、top `11`（`:57-59`）
/// * 文字 `16sp`（`:104`）、高 `40` / top `9`、
///   左 `margin+2+38`、右 `margin+2+30`（`:118-120`）
/// * 清除钮 `36×36`、right = `margin`、`setSide(dp(7))`，
///   初始 `scale 0.1 / alpha 0`，有字时 `150ms` 补间（`:141-144`）
/// * 光标高 `dp(20)`、宽 `1.5`（`:114-116`）；`IME_ACTION_SEARCH`（`:113`）
/// * 底色 `key_dialogSearchBackground`，亮色 `0xfff2f4f5`（`ThemeColors.java:57`）
///
/// ### 二、`Components/FragmentSearchField.java`（会话列表，`DialogsActivity:3281`）
/// * 圆角 **`dp(20)`**、`setPadding(dp(3))`（`:212`、`:263-265`）
/// * 文字 **`15sp`**、`cursorWidth 1.5`、单行（`:104`）
/// * 文字左右内距 **各 `dp(48)`**（`:241-249` 的
///   `pStart = max(filtersWidth + dp(6), dp(48))`、`pEnd = dp(48) + iconsWidth`）
/// * 放大镜 **`24×24`**、左 **`12`**（`:117`）
/// * 关闭钮 **`24×24`**、右 **`12`**、波纹半径 `dp(17)`（`:153`、`:285`）
/// * 关闭钮 `380ms EASE_OUT_QUINT` + **旋转 `(1-t)×90°`**（`:57`、`:336`）
/// * 底色 暗 `white×0.07` / 亮 **`blackText×0.05`**（`:279-281`）
/// * 图标 `blackText×0.6`、hint `blackText×0.5`（`:283-286`）
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
    this.fragment = false,
    this.onSubmitted,
    this.onChanged,
    this.onCleared,
    this.autofocus = false,
  });

  /// 会话列表那套（`FragmentSearchField`）。开启后圆角/字号/图标/内距/底色
  /// 全部按官方那套走，[radius] 被忽略。
  const SearchFieldBox.fragment({
    super.key,
    required this.controller,
    required this.focusNode,
    this.hintText = '搜索',
    this.height = 36,
    this.onSubmitted,
    this.onChanged,
    this.onCleared,
    this.autofocus = false,
  }) : radius = 20,
       fragment = true;

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;

  /// 框高。`SearchField.java:44` 是 36；聊天页顶栏变形后与胶囊同高时传 46。
  final double height;

  /// 圆角。`SearchField.java:44` 是 18，`FragmentSearchField.java:212` 是 20。
  final double radius;

  /// 是否是会话列表那套（`FragmentSearchField`）。
  final bool fragment;

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
  /// 清除钮补间：`SearchField.java:141` 150ms；`FragmentSearchField.java:57` 380ms。
  Duration get _clearDuration =>
      Duration(milliseconds: widget.fragment ? 380 : 150);

  /// 文字字号：`SearchField.java:104` 是 16；`FragmentSearchField.java:104` 是 15。
  double get _fontSize => widget.fragment ? 15 : 16;

  /// 光标：`SearchField.java:114-116` 高 `dp(20)`、宽 `1.5`。
  static const double _cursorHeight = 20;
  static const double _cursorWidth = 1.5;

  /// 放大镜：官方那套 `36×36` 贴 left 2；列表那套 `24×24` 贴 left 12。
  double get _iconSize => widget.fragment ? 24 : 18;
  double get _iconLeft => widget.fragment ? 12 : 2;

  /// 文字内距：官方 `dp(54)/dp(46)` 扣掉 `margin dp(14)` → 40/32；
  /// 列表那套直接是 `dp(48)/dp(48)`（`FragmentSearchField.java:241-249`）。
  double get _textLeft => widget.fragment ? 48 : 40;
  double get _textRight => widget.fragment ? 48 : 32;

  /// 清除钮：官方 `36×36` 贴 right 0；列表那套 `24×24` 贴 right 12。
  double get _clearSize => widget.fragment ? 24 : 36;
  double get _clearRight => widget.fragment ? 12 : 0;

  /// 底色。
  ///
  /// * 官方那套：`key_dialogSearchBackground`，亮 `0xfff2f4f5`
  ///   （`ThemeColors.java:57`），暗色白色 7%。
  /// * 列表那套：`FragmentSearchField.java:279-281` ——
  ///   暗 `white×0.07`、亮 **`blackText×0.05`**（不是固定灰，压在页面上看）。
  ///
  /// 暗色不能用 `bgHover`：它和顶栏 `bgHeader` 几乎同色，框会看不见边界。
  Color get _fill => TelegramColors.isDark
      ? Colors.white.withValues(alpha: 0.07)
      : (widget.fragment
            ? Colors.black.withValues(alpha: 0.05)
            : const Color(0xFFF2F4F5));

  /// 图标色：列表那套是 `blackText×0.6`（`FragmentSearchField.java:283`）。
  Color get _iconColor => widget.fragment
      ? TelegramColors.textPrimary.withValues(alpha: 0.6)
      : TelegramColors.textMuted;

  /// hint 色：列表那套是 `blackText×0.5`（`FragmentSearchField.java:286`）。
  Color get _hintColor => widget.fragment
      ? TelegramColors.textPrimary.withValues(alpha: 0.5)
      : TelegramColors.textMuted;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _fill,
                borderRadius: BorderRadius.circular(widget.radius),
              ),
            ),
          ),
          // 放大镜：官方那套 36×36 贴 left 2；列表那套 24×24 贴 left 12。
          Positioned(
            left: _iconLeft,
            top: 0,
            width: widget.fragment ? 24 : 36,
            height: widget.height,
            child: Icon(Icons.search, size: _iconSize, color: _iconColor),
          ),
          // 文字区。
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(left: _textLeft, right: _textRight),
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
                      color: _hintColor,
                      fontSize: _fontSize,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 清除钮。
          Positioned(
            right: _clearRight,
            top: 0,
            width: _clearSize,
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
                    curve: Curves.easeOutQuint,
                    child: AnimatedScale(
                      duration: _clearDuration,
                      scale: hasText ? 1 : 0.1,
                      curve: Curves.easeOutQuint,
                      // 列表那套的关闭钮还会转：`(1 - t) × 90°`
                      // （`FragmentSearchField.java:336`）。
                      child: AnimatedRotation(
                        duration: _clearDuration,
                        turns: hasText || !widget.fragment ? 0 : 0.25,
                        curve: Curves.easeOutQuint,
                        child: IconButton(
                          key: const ValueKey<String>('search-clear'),
                          onPressed: () {
                            widget.controller.clear();
                            // 官方清空后重新弹键盘（SearchField.java:81-84）。
                            widget.focusNode.requestFocus();
                            widget.onCleared?.call();
                          },
                          padding: EdgeInsets.zero,
                          iconSize: widget.fragment ? 20 : 18,
                          icon: Icon(
                            widget.fragment ? Icons.close : Icons.cancel,
                            color: _iconColor,
                          ),
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
