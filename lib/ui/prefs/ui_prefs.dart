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
  }) =>
      UiPrefs(
        fontScale: fontScale ?? this.fontScale,
        notifications: notifications ?? this.notifications,
        messageAnimations: messageAnimations ?? this.messageAnimations,
        accentId: accentId ?? this.accentId,
        wallpaperId: wallpaperId ?? this.wallpaperId,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'font_scale': fontScale,
        'notifications': notifications,
        'message_animations': messageAnimations,
        'accent': accentId,
        'wallpaper': wallpaperId,
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

    return UiPrefs(
      fontScale: scale,
      notifications: readBool('notifications', true),
      messageAnimations: readBool('message_animations', true),
      accentId: readChoice('accent', accentIds, 'default'),
      wallpaperId: readChoice('wallpaper', wallpaperIds, 'plain'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UiPrefs &&
      other.fontScale == fontScale &&
      other.notifications == notifications &&
      other.messageAnimations == messageAnimations &&
      other.accentId == accentId &&
      other.wallpaperId == wallpaperId;

  @override
  int get hashCode => Object.hash(
      fontScale, notifications, messageAnimations, accentId, wallpaperId);

  @override
  String toString() =>
      'UiPrefs(fontScale: $fontScale, notifications: $notifications, '
      'messageAnimations: $messageAnimations, accentId: $accentId, '
      'wallpaperId: $wallpaperId)';
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
final uiPrefsProvider =
    StateNotifierProvider<UiPrefsNotifier, UiPrefs>((ref) {
  final dir = ref.watch(dataDirProvider);
  final notifier = UiPrefsNotifier(
    File('${dir.path}${Platform.pathSeparator}ui_prefs.json'),
  );
  unawaited(notifier.load());
  return notifier;
});
