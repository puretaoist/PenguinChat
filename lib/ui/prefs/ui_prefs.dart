/// L4 界面偏好（字号、通知开关、入场动画开关）。
///
/// ## 为什么另起一个文件，不并进 ui_settings.json
///
/// ui_settings.json 只有 {"dark": bool} 一个键，而且被
/// test/ui_test.dart:237-287 逐字断言（切主题落盘、坏文件回暗色）。
/// 那个格式是**已有契约**，往里塞新字段会让"坏文件"语义变模糊；
/// 所以新偏好单独落 ui_prefs.json，读坏了只影响本文件（回默认值），
/// 不会连累主题选择。
///
/// 与 ThemeModeNotifier 同样只用 File 而不是引入 Flutter 依赖——
/// 这一层仍然是 L4，但保持"纯状态 + 落盘"的形状便于离线自测。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/session_providers.dart';
import '../../infra/log/logger.dart';

/// 一份界面偏好快照（不可变）。
class UiPrefs {
  const UiPrefs({
    this.fontScale = 1.0,
    this.notifications = true,
    this.messageAnimations = true,
    this.accentId = 'default',
    this.wallpaperId = 'plain',
    this.avatarCorners = avatarCornersDefault,
    this.disableDividers = false,
    this.timeWithSeconds = false,
    this.disableNumberRounding = false,
    this.bubbleRadius = bubbleRadiusDefault,
    this.useSystemFonts = true,
    this.centerTitle = false,
    this.hideHeaderStatus = false,
    this.hideKeyboardOnScroll = true,
    this.menuShowCopy = true,
    this.menuShowForward = true,
    this.menuShowDelete = true,
    this.menuShowRecall = true,
  });

  /// 全局字号倍率（作用在 MaterialApp 的 MediaQuery.textScaler 上）。
  final double fontScale;

  /// 后台收到消息是否弹系统通知（总开关，单聊/群聊都受它管）。
  final bool notifications;

  /// 新消息气泡是否播入场动画（淡入 + 轻微上浮）。
  final bool messageAnimations;

  /// 主题色 id（颜色表在 lib/ui/theme/theme_accent.dart 的 accentChoices，
  /// 这里只存 id：本文件必须保持纯 Dart，不能 import Flutter 的 Color）。
  final String accentId;

  /// 聊天背景 id（预设表在 lib/ui/widgets/chat_wallpaper.dart）。
  /// 'plain' = 跟随主题的纯色底（暗色近黑 / 亮色浅灰），也是默认值。
  final String wallpaperId;

  /// 头像圆角：绝对半径，基准 56dp（抄 exteraGram `ExteraConfig.avatarCorners`，
  /// 绘制时按 `corners * size / 56` 缩放）。
  ///
  /// 取值 0–30：0 = 方形，30 = 圆形。上界不是随便定的——TG 的会话头像恒为
  /// 圆形，`Cells/DialogCell.java` 按尺寸给 `setRoundRadius(dp(28))`（54dp）/
  /// `dp(26)`（52dp），换算到 56 基准正好 30，所以 30 就是"和 TG 完全一致"。
  final double avatarCorners;

  /// 会话列表是否隐藏行间 1px 分隔线（抄 `ExteraConfig.disableDividers`）。
  final bool disableDividers;

  /// 会话时间是否带秒（抄 `ExteraConfig.formatTimeWithSeconds`）。
  final bool timeWithSeconds;

  /// 未读数是否不缩写（抄 `ExteraConfig.disableNumberRounding`）：
  /// 打开后 1234 显示 1234，而不是 1.2K。
  final bool disableNumberRounding;

  /// 气泡圆角（抄 TG `TelegramMetrics.bubbleRadius` 的可调版）：
  /// 0 = 直角，17 = 与 TG 官方一致（默认），20 = 更圆。
  /// 只作用自己/对方两侧的"大头"角，贴着屏幕那侧的小尾巴角固定 5。
  final double bubbleRadius;

  /// 是否用系统字体（抄 `ExteraConfig.useSystemFonts`）。
  /// 关掉则强制用包内 Roboto，保证跨机型字形一致（截图/金样也稳）。
  final bool useSystemFonts;

  /// 顶栏标题是否居中（抄 `ExteraConfig.centerTitle`）。
  final bool centerTitle;

  /// 是否隐藏顶栏副标题（在线状态/成员数，抄 `ExteraConfig.hideActionBarStatus`）。
  final bool hideHeaderStatus;

  /// 滚动消息列表时是否收起键盘（抄 `ExteraConfig.hideKeyboardOnScroll`）。
  final bool hideKeyboardOnScroll;

  /// 长按消息菜单里是否显示「复制」。
  final bool menuShowCopy;

  /// 长按消息菜单里是否显示「转发」。
  final bool menuShowForward;

  /// 长按消息菜单里是否显示「删除（仅本地）」。
  final bool menuShowDelete;

  /// 长按消息菜单里是否显示「撤回」。
  final bool menuShowRecall;

  /// 气泡圆角范围与默认值（17 = 与 TG 官方一致）。
  static const double bubbleRadiusMin = 0;
  static const double bubbleRadiusMax = 20;
  static const double bubbleRadiusDefault = 17;

  /// 圆角滑块的人话显示。
  static String bubbleRadiusLabel(double v) {
    if (v <= bubbleRadiusMin + 0.5) return '直角';
    if (v >= bubbleRadiusMax - 0.5) return '很圆';
    return v.toStringAsFixed(0);
  }

  /// 头像圆角范围与默认值（30 = 圆形，见 [avatarCorners]）。
  static const double avatarCornersMin = 0;
  static const double avatarCornersMax = 30;
  static const double avatarCornersDefault = 30;

  /// 圆角滑块的人话显示。
  static String avatarCornersLabel(double v) {
    if (v <= avatarCornersMin + 0.5) return '方形';
    if (v >= avatarCornersMax - 0.5) return '圆形';
    return v.toStringAsFixed(0);
  }

  /// 可选主题色 id（顺序即设置页里的展示顺序）。'default' = 跟随主题
  /// （暗色紫 #8774E1 / 亮色蓝 #3390EC），也是默认值。
  static const List<String> accentIds = <String>[
    'default',
    'violet',
    'blue',
    'cyan',
    'green',
    'orange',
    'pink',
    'red',
    'gray',
  ];

  /// 可选聊天背景 id（'plain' 排第一 = 默认）。
  static const List<String> wallpaperIds = <String>[
    'plain',
    'dusk',
    'forest',
    'ocean',
    'sunset',
  ];

  /// 主题色的人话名（设置页副标题用；认不出的 id 一律说「紫色」）。
  static String accentLabel(String id) => switch (id) {
    'default' => '跟随主题',
    'blue' => '蓝色',
    'cyan' => '青色',
    'green' => '绿色',
    'orange' => '橙色',
    'pink' => '粉色',
    'red' => '红色',
    'gray' => '灰色',
    _ => '紫色',
  };

  /// 聊天背景的人话名。
  static String wallpaperLabel(String id) => switch (id) {
    'dusk' => '黄昏',
    'forest' => '森林',
    'ocean' => '海洋',
    'sunset' => '晚霞',
    _ => '默认',
  };

  /// 可选的字号档位。刻意只给四档：自由滑块会让不同档位下的行高/气泡
  /// 全都落在没验证过的中间值上，反而更容易挤坏布局。
  static const List<double> fontScaleChoices = <double>[0.9, 1.0, 1.1, 1.2];

  /// 档位的人话名（设置页副标题用）。
  static String fontScaleLabel(double value) => switch (value) {
    0.9 => '小',
    1.0 => '标准',
    1.1 => '大',
    1.2 => '特大',
    _ => '标准',
  };

  UiPrefs copyWith({
    double? fontScale,
    bool? notifications,
    bool? messageAnimations,
    String? accentId,
    String? wallpaperId,
    double? avatarCorners,
    bool? disableDividers,
    bool? timeWithSeconds,
    bool? disableNumberRounding,
    double? bubbleRadius,
    bool? useSystemFonts,
    bool? centerTitle,
    bool? hideHeaderStatus,
    bool? hideKeyboardOnScroll,
    bool? menuShowCopy,
    bool? menuShowForward,
    bool? menuShowDelete,
    bool? menuShowRecall,
  }) => UiPrefs(
    fontScale: fontScale ?? this.fontScale,
    notifications: notifications ?? this.notifications,
    messageAnimations: messageAnimations ?? this.messageAnimations,
    accentId: accentId ?? this.accentId,
    wallpaperId: wallpaperId ?? this.wallpaperId,
    avatarCorners: avatarCorners ?? this.avatarCorners,
    disableDividers: disableDividers ?? this.disableDividers,
    timeWithSeconds: timeWithSeconds ?? this.timeWithSeconds,
    disableNumberRounding: disableNumberRounding ?? this.disableNumberRounding,
    bubbleRadius: bubbleRadius ?? this.bubbleRadius,
    useSystemFonts: useSystemFonts ?? this.useSystemFonts,
    centerTitle: centerTitle ?? this.centerTitle,
    hideHeaderStatus: hideHeaderStatus ?? this.hideHeaderStatus,
    hideKeyboardOnScroll: hideKeyboardOnScroll ?? this.hideKeyboardOnScroll,
    menuShowCopy: menuShowCopy ?? this.menuShowCopy,
    menuShowForward: menuShowForward ?? this.menuShowForward,
    menuShowDelete: menuShowDelete ?? this.menuShowDelete,
    menuShowRecall: menuShowRecall ?? this.menuShowRecall,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'font_scale': fontScale,
    'notifications': notifications,
    'message_animations': messageAnimations,
    'accent': accentId,
    'wallpaper': wallpaperId,
    'avatar_corners': avatarCorners,
    'disable_dividers': disableDividers,
    'time_with_seconds': timeWithSeconds,
    'disable_number_rounding': disableNumberRounding,
    'bubble_radius': bubbleRadius,
    'use_system_fonts': useSystemFonts,
    'center_title': centerTitle,
    'hide_header_status': hideHeaderStatus,
    'hide_keyboard_on_scroll': hideKeyboardOnScroll,
    'menu_show_copy': menuShowCopy,
    'menu_show_forward': menuShowForward,
    'menu_show_delete': menuShowDelete,
    'menu_show_recall': menuShowRecall,
  };

  /// 读回时对每个字段单独兜底：某一项坏了不该把整份偏好打回默认。
  factory UiPrefs.fromJson(Map<String, Object?> json) {
    double scale = 1.0;
    final Object? rawScale = json['font_scale'];
    if (rawScale is num) {
      final double v = rawScale.toDouble();
      if (v.isFinite && v >= 0.8 && v <= 1.6) scale = v;
    }
    bool readBool(String key, bool fallback) {
      final Object? v = json[key];
      return v is bool ? v : fallback;
    }

    String readChoice(String key, List<String> allowed, String fallback) {
      final Object? v = json[key];
      return v is String && allowed.contains(v) ? v : fallback;
    }

    // 头像圆角：坏值/超范围一律夹回 0–30，别让一个脏数字把头像画成怪形状。
    double corners = avatarCornersDefault;
    final Object? rawCorners = json['avatar_corners'];
    if (rawCorners is num) {
      final double v = rawCorners.toDouble();
      if (v.isFinite) corners = v.clamp(avatarCornersMin, avatarCornersMax);
    }

    // 气泡圆角：坏值/超范围一律夹回 0–20。
    double bubble = bubbleRadiusDefault;
    final Object? rawBubble = json['bubble_radius'];
    if (rawBubble is num) {
      final double v = rawBubble.toDouble();
      if (v.isFinite) bubble = v.clamp(bubbleRadiusMin, bubbleRadiusMax);
    }

    return UiPrefs(
      fontScale: scale,
      notifications: readBool('notifications', true),
      messageAnimations: readBool('message_animations', true),
      accentId: readChoice('accent', accentIds, 'default'),
      wallpaperId: readChoice('wallpaper', wallpaperIds, 'plain'),
      avatarCorners: corners,
      disableDividers: readBool('disable_dividers', false),
      timeWithSeconds: readBool('time_with_seconds', false),
      disableNumberRounding: readBool('disable_number_rounding', false),
      bubbleRadius: bubble,
      useSystemFonts: readBool('use_system_fonts', true),
      centerTitle: readBool('center_title', false),
      hideHeaderStatus: readBool('hide_header_status', false),
      hideKeyboardOnScroll: readBool('hide_keyboard_on_scroll', true),
      menuShowCopy: readBool('menu_show_copy', true),
      menuShowForward: readBool('menu_show_forward', true),
      menuShowDelete: readBool('menu_show_delete', true),
      menuShowRecall: readBool('menu_show_recall', true),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UiPrefs &&
      other.fontScale == fontScale &&
      other.notifications == notifications &&
      other.messageAnimations == messageAnimations &&
      other.accentId == accentId &&
      other.wallpaperId == wallpaperId &&
      other.avatarCorners == avatarCorners &&
      other.disableDividers == disableDividers &&
      other.timeWithSeconds == timeWithSeconds &&
      other.disableNumberRounding == disableNumberRounding &&
      other.bubbleRadius == bubbleRadius &&
      other.useSystemFonts == useSystemFonts &&
      other.centerTitle == centerTitle &&
      other.hideHeaderStatus == hideHeaderStatus &&
      other.hideKeyboardOnScroll == hideKeyboardOnScroll &&
      other.menuShowCopy == menuShowCopy &&
      other.menuShowForward == menuShowForward &&
      other.menuShowDelete == menuShowDelete &&
      other.menuShowRecall == menuShowRecall;

  @override
  int get hashCode => Object.hash(
    fontScale,
    notifications,
    messageAnimations,
    accentId,
    wallpaperId,
    avatarCorners,
    disableDividers,
    timeWithSeconds,
    disableNumberRounding,
    bubbleRadius,
    useSystemFonts,
    centerTitle,
    hideHeaderStatus,
    hideKeyboardOnScroll,
    menuShowCopy,
    menuShowForward,
    menuShowDelete,
    menuShowRecall,
  );

  @override
  String toString() =>
      'UiPrefs(fontScale: $fontScale, notifications: $notifications, '
      'messageAnimations: $messageAnimations, accentId: $accentId, '
      'wallpaperId: $wallpaperId, avatarCorners: $avatarCorners, '
      'disableDividers: $disableDividers, timeWithSeconds: $timeWithSeconds, '
      'disableNumberRounding: $disableNumberRounding, '
      'bubbleRadius: $bubbleRadius, useSystemFonts: $useSystemFonts, '
      'centerTitle: $centerTitle, hideHeaderStatus: $hideHeaderStatus, '
      'hideKeyboardOnScroll: $hideKeyboardOnScroll, '
      'menuShowCopy: $menuShowCopy, menuShowForward: $menuShowForward, '
      'menuShowDelete: $menuShowDelete, '
      'menuShowRecall: $menuShowRecall)';
}

/// 未读数文案（会话列表与设置页预览共用）。
///
/// 默认带 K 缩写，口径同 TG 的 `LocaleController.formatNumber(count, 0)`
/// （DialogsActivity 里会话行的未读数就是这么写的）；[noRounding] 打开后
/// 原样输出，方便需要精确数字的场景。
String formatUnreadCount(int n, {bool noRounding = false}) {
  if (noRounding || n < 1000) return '$n';
  final double k = n / 1000.0;
  return '${k.toStringAsFixed(k >= 10 ? 0 : 1)}K';
}

/// 界面偏好的状态机。与 ThemeModeNotifier 同构：读一次、改就落盘。
class UiPrefsNotifier extends StateNotifier<UiPrefs> {
  UiPrefsNotifier(this._file) : super(const UiPrefs());

  final File? _file;

  /// 读盘失败不拦启动：偏好只是外观，回默认值最差也就是"字号变回标准"。
  Future<void> load() async {
    try {
      final file = _file;
      if (file == null || !file.existsSync()) return;
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        state = UiPrefs.fromJson(decoded.cast<String, Object?>());
      }
    } catch (e) {
      Log.get('UiPrefs').w('界面偏好读取失败，使用默认值', error: e);
    }
  }

  Future<void> setFontScale(double value) =>
      _update(state.copyWith(fontScale: value));

  Future<void> setNotifications(bool value) =>
      _update(state.copyWith(notifications: value));

  Future<void> setMessageAnimations(bool value) =>
      _update(state.copyWith(messageAnimations: value));

  Future<void> setAccentId(String value) =>
      _update(state.copyWith(accentId: value));

  Future<void> setWallpaperId(String value) =>
      _update(state.copyWith(wallpaperId: value));

  Future<void> setAvatarCorners(double value) => _update(
    state.copyWith(
      avatarCorners: value.clamp(
        UiPrefs.avatarCornersMin,
        UiPrefs.avatarCornersMax,
      ),
    ),
  );

  Future<void> setDisableDividers(bool value) =>
      _update(state.copyWith(disableDividers: value));

  Future<void> setTimeWithSeconds(bool value) =>
      _update(state.copyWith(timeWithSeconds: value));

  Future<void> setDisableNumberRounding(bool value) =>
      _update(state.copyWith(disableNumberRounding: value));

  Future<void> setBubbleRadius(double value) => _update(
    state.copyWith(
      bubbleRadius: value.clamp(
        UiPrefs.bubbleRadiusMin,
        UiPrefs.bubbleRadiusMax,
      ),
    ),
  );

  Future<void> setUseSystemFonts(bool value) =>
      _update(state.copyWith(useSystemFonts: value));

  Future<void> setCenterTitle(bool value) =>
      _update(state.copyWith(centerTitle: value));

  Future<void> setHideHeaderStatus(bool value) =>
      _update(state.copyWith(hideHeaderStatus: value));

  Future<void> setHideKeyboardOnScroll(bool value) =>
      _update(state.copyWith(hideKeyboardOnScroll: value));

  Future<void> setMenuShowCopy(bool value) =>
      _update(state.copyWith(menuShowCopy: value));

  Future<void> setMenuShowForward(bool value) =>
      _update(state.copyWith(menuShowForward: value));

  Future<void> setMenuShowDelete(bool value) =>
      _update(state.copyWith(menuShowDelete: value));

  Future<void> setMenuShowRecall(bool value) =>
      _update(state.copyWith(menuShowRecall: value));

  /// 恢复出厂外观（抄 ayu 的 ResetSettings）：把全部字段写回默认值。
  Future<void> reset() => _update(const UiPrefs());

  Future<void> _update(UiPrefs next) async {
    if (next == state) return;
    state = next;
    await _save();
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.writeAsString(jsonEncode(state.toJson()), flush: true);
    } catch (e) {
      Log.get('UiPrefs').w('界面偏好写盘失败（本次会话内仍生效）', error: e);
    }
  }
}

/// 界面偏好。目录来自 dataDirProvider（由 main.dart 注入）。
final uiPrefsProvider = StateNotifierProvider<UiPrefsNotifier, UiPrefs>((ref) {
  final dir = ref.watch(dataDirProvider);
  final notifier = UiPrefsNotifier(
    File('${dir.path}${Platform.pathSeparator}ui_prefs.json'),
  );
  unawaited(notifier.load());
  return notifier;
});
