/// L4 表现层：可配置主题色的色表。
///
/// 为什么单独一个文件：色值要用 Flutter 的 Color，而 lib/ui/prefs/ui_prefs.dart
/// 必须保持纯 Dart（tool 下的 selftest 用 `dart run` 跑，不能 import Flutter）。
/// 所以偏好里只存 id（UiPrefs.accentId），这里负责 id → Color。
library;

import 'package:flutter/material.dart';

import '../prefs/ui_prefs.dart';

/// 一个可选主题色。
class AccentChoice {
  const AccentChoice({
    required this.id,
    required this.color,
    this.isDefault = false,
  });

  final String id;

  /// 展示用色块。'default' 这档不是单一颜色（暗紫/亮蓝），
  /// 这里给的紫只用于画渐变的第一段。
  final Color color;

  /// 是否是「跟随主题」这一档（它不覆盖调色板自带强调色）。
  final bool isDefault;

  /// 人话名（来自 UiPrefs.accentLabel，设置页副标题与弹层共用一份文案）。
  String get name => UiPrefs.accentLabel(id);
}

/// 全部可选主题色（顺序与 UiPrefs.accentIds 保持一致，设置页按这个顺序铺色板）。
const List<AccentChoice> accentChoices = <AccentChoice>[
  AccentChoice(id: 'default', color: Color(0xFF8774E1), isDefault: true),
  AccentChoice(id: 'violet', color: Color(0xFF8774E1)),
  AccentChoice(id: 'blue', color: Color(0xFF3390EC)),
  AccentChoice(id: 'cyan', color: Color(0xFF1CA9C9)),
  AccentChoice(id: 'green', color: Color(0xFF4CAF50)),
  AccentChoice(id: 'orange', color: Color(0xFFFF9800)),
  AccentChoice(id: 'pink', color: Color(0xFFE91E63)),
  AccentChoice(id: 'red', color: Color(0xFFE53935)),
  AccentChoice(id: 'gray', color: Color(0xFF9E9E9E)),
];

/// 把 id 解析成真正要覆盖的强调色；'default'（跟随主题）返回 null，
/// 调用方此时应该直接用调色板自带的强调色（暗紫 / 亮蓝）。
Color? accentColorOrNull(String id) {
  final AccentChoice c = accentChoiceOf(id);
  return c.isDefault ? null : c.color;
}

/// 按 id 取颜色；认不出的 id 一律回第一档（跟随主题），不抛异常。
AccentChoice accentChoiceOf(String id) => accentChoices.firstWhere(
  (AccentChoice c) => c.id == id,
  orElse: () => accentChoices.first,
);
