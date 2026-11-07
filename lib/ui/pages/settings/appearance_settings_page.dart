/// L4 设置二级页：外观（抄 ayu `AppearancePreferencesActivity` 的适用项，
/// 再补 TG 原生外观项：主题/主题色/聊天背景/文字大小/气泡圆角）。
///
/// ayu 的 Appearance 里抽屉元素、底部 tab、图标包、图标集这些东西我们
/// 没有对应界面，按用户授权（"只需排除不适用的"）直接排除；这里保留的是
/// 每一项都能被现有渲染层真正消费的开关。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../prefs/ui_prefs.dart';
import '../../theme/telegram_theme.dart';
import '../../theme/theme_accent.dart';
import '../../theme/theme_mode.dart';
import '../../widgets/chat_list_preview.dart';
import '../../widgets/glass_sheet.dart';
import '../../widgets/chat_wallpaper.dart';
import '../../widgets/telegram_list_item.dart';
import '../../widgets/capped_content.dart';
import '../../widgets/tg_action_bar.dart';

class AppearanceSettingsPage extends ConsumerWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // watch 了 themeModeProvider，必须先 applyThemePalette（切暗色整页重画）。
    final dark = applyThemePalette(ref);
    final prefs = ref.watch(uiPrefsProvider);

    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: <Widget>[
            // 二级页的 ActionBar：占状态栏、左侧返回（ActionBar.java:1400
            // 把 statusBar 高度算进条高），主 Tab 根视图没有这个箭头。
            TgActionBar(
              title: '外观',
              topInset: MediaQuery.paddingOf(context).top,
              onBack: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.only(
                  top: 8,
                  bottom: 24,
                  left: contentHorizontalInset(context),
                  right: contentHorizontalInset(context),
                ),
                children: <Widget>[
                  const TelegramSectionHeader(text: '主题'),
                  TelegramTileGroup(
                    children: <Widget>[
                      TgListTile(
                        icon: Icons.dark_mode_outlined,
                        title: '外观',
                        subtitle: dark ? '暗色（当前）' : '亮色（当前）',
                        trailing: Switch(
                          activeThumbColor: TelegramColors.accent,
                          value: dark,
                          onChanged: (bool value) => unawaited(
                            ref.read(themeModeProvider.notifier).setDark(value),
                          ),
                        ),
                      ),
                      TgListTile(
                        key: const ValueKey('settings-font-scale'),
                        icon: Icons.format_size,
                        title: '文字大小',
                        subtitle: UiPrefs.fontScaleLabel(prefs.fontScale),
                        onTap: () => _pickFontScale(context, ref),
                      ),
                      TgListTile(
                        key: const ValueKey('settings-accent'),
                        icon: Icons.palette_outlined,
                        title: '主题色',
                        subtitle: UiPrefs.accentLabel(prefs.accentId),
                        trailing: _AccentDot(id: prefs.accentId),
                        onTap: () => _pickAccent(context, ref),
                      ),
                      TgListTile(
                        key: const ValueKey('settings-wallpaper'),
                        icon: Icons.wallpaper_outlined,
                        title: '聊天背景',
                        subtitle: UiPrefs.wallpaperLabel(prefs.wallpaperId),
                        onTap: () => _pickWallpaper(context, ref),
                      ),
                      TgListTile(
                        icon: Icons.font_download_outlined,
                        title: '使用系统字体',
                        subtitle: '关闭后强制用内置 Roboto，跨机型字形一致',
                        trailing: Switch(
                          activeThumbColor: TelegramColors.accent,
                          value: prefs.useSystemFonts,
                          onChanged: (bool value) => unawaited(
                            ref
                                .read(uiPrefsProvider.notifier)
                                .setUseSystemFonts(value),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const TelegramSectionHeader(text: '气泡'),
                  _BubbleRadiusPreview(radius: prefs.bubbleRadius),
                  TelegramTileGroup(
                    children: <Widget>[
                      TgListTile(
                        key: const ValueKey('settings-bubble-radius'),
                        icon: Icons.rounded_corner,
                        title: '气泡圆角',
                        subtitle: UiPrefs.bubbleRadiusLabel(prefs.bubbleRadius),
                        showChevron: false,
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
                        child: Slider(
                          value: prefs.bubbleRadius,
                          min: UiPrefs.bubbleRadiusMin,
                          max: UiPrefs.bubbleRadiusMax,
                          divisions:
                              (UiPrefs.bubbleRadiusMax -
                                      UiPrefs.bubbleRadiusMin)
                                  .round(),
                          activeColor: TelegramColors.accent,
                          label: UiPrefs.bubbleRadiusLabel(prefs.bubbleRadius),
                          onChanged: (double value) => unawaited(
                            ref
                                .read(uiPrefsProvider.notifier)
                                .setBubbleRadius(value),
                          ),
                        ),
                      ),
                      TgListTile(
                        icon: Icons.animation,
                        title: '消息入场动画',
                        subtitle: '新消息气泡淡入并轻微上浮',
                        trailing: Switch(
                          activeThumbColor: TelegramColors.accent,
                          value: prefs.messageAnimations,
                          onChanged: (bool value) => unawaited(
                            ref
                                .read(uiPrefsProvider.notifier)
                                .setMessageAnimations(value),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const TelegramSectionHeader(text: '聊天列表'),
                  // 实时预览（抄 exteraGram 的 ChatListPreviewCell）：
                  // 拖动下面的滑块时这一行会立刻变形。
                  ChatListPreview(prefs: prefs),
                  const SizedBox(height: 10),
                  TelegramTileGroup(
                    children: <Widget>[
                      TgListTile(
                        key: const ValueKey('settings-avatar-corners'),
                        icon: Icons.crop_free,
                        title: '头像圆角',
                        subtitle: UiPrefs.avatarCornersLabel(
                          prefs.avatarCorners,
                        ),
                        showChevron: false,
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
                        child: Slider(
                          value: prefs.avatarCorners,
                          min: UiPrefs.avatarCornersMin,
                          max: UiPrefs.avatarCornersMax,
                          divisions: 30,
                          activeColor: TelegramColors.accent,
                          label: UiPrefs.avatarCornersLabel(
                            prefs.avatarCorners,
                          ),
                          onChanged: (double value) => unawaited(
                            ref
                                .read(uiPrefsProvider.notifier)
                                .setAvatarCorners(value),
                          ),
                        ),
                      ),
                      TgListTile(
                        key: const ValueKey('settings-disable-dividers'),
                        icon: Icons.horizontal_rule,
                        title: '不显示分隔线',
                        subtitle: '会话行之间不画那条细线',
                        trailing: Switch(
                          activeThumbColor: TelegramColors.accent,
                          value: prefs.disableDividers,
                          onChanged: (bool value) => unawaited(
                            ref
                                .read(uiPrefsProvider.notifier)
                                .setDisableDividers(value),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const TelegramSectionHeader(text: '聊天顶栏'),
                  TelegramTileGroup(
                    children: <Widget>[
                      TgListTile(
                        key: const ValueKey('settings-center-title'),
                        icon: Icons.format_align_center,
                        title: '标题居中',
                        subtitle: '聊天顶栏的会话名居中对齐',
                        trailing: Switch(
                          activeThumbColor: TelegramColors.accent,
                          value: prefs.centerTitle,
                          onChanged: (bool value) => unawaited(
                            ref
                                .read(uiPrefsProvider.notifier)
                                .setCenterTitle(value),
                          ),
                        ),
                      ),
                      TgListTile(
                        key: const ValueKey('settings-hide-header-status'),
                        icon: Icons.visibility_off_outlined,
                        title: '隐藏顶栏状态',
                        subtitle: '不显示在线状态 / 群成员数',
                        trailing: Switch(
                          activeThumbColor: TelegramColors.accent,
                          value: prefs.hideHeaderStatus,
                          onChanged: (bool value) => unawaited(
                            ref
                                .read(uiPrefsProvider.notifier)
                                .setHideHeaderStatus(value),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 字号选择：底部弹层里给四档（UiPrefs.fontScaleChoices）。
  Future<void> _pickFontScale(BuildContext context, WidgetRef ref) async {
    final current = ref.read(uiPrefsProvider).fontScale;
    final picked = await showGlassSheet<double>(
      context: context,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _sheetHeader('文字大小'),
            Divider(height: 1, color: TelegramColors.divider),
            for (final double value in UiPrefs.fontScaleChoices)
              TgUserRow(
                key: ValueKey<String>('font-scale-$value'),
                leading: SizedBox(
                  width: 28,
                  child: Icon(
                    Icons.text_fields,
                    size: 18,
                    color: value == current
                        ? TelegramColors.accent
                        : TelegramColors.textMuted,
                  ),
                ),
                title: UiPrefs.fontScaleLabel(value),
                subtitle: 'x$value',
                trailing: value == current
                    ? Icon(Icons.check, size: 18, color: TelegramColors.accent)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(value),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      await ref.read(uiPrefsProvider.notifier).setFontScale(picked);
    }
  }

  /// 主题色选择：底部弹层里铺全部色板。
  Future<void> _pickAccent(BuildContext context, WidgetRef ref) async {
    final current = ref.read(uiPrefsProvider).accentId;
    final picked = await showGlassSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _sheetHeader('主题色'),
            Divider(height: 1, color: TelegramColors.divider),
            for (final AccentChoice choice in accentChoices)
              TgUserRow(
                key: ValueKey<String>('accent-${choice.id}'),
                leading: SizedBox(
                  width: 28,
                  child: Center(child: _AccentDot(id: choice.id, size: 20)),
                ),
                title: choice.name,
                trailing: choice.id == current
                    ? Icon(Icons.check, size: 18, color: TelegramColors.accent)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(choice.id),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      await ref.read(uiPrefsProvider.notifier).setAccentId(picked);
    }
  }

  /// 聊天背景选择：每行左侧给一个小预览块。
  Future<void> _pickWallpaper(BuildContext context, WidgetRef ref) async {
    final current = ref.read(uiPrefsProvider).wallpaperId;
    final picked = await showGlassSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _sheetHeader('聊天背景'),
            Divider(height: 1, color: TelegramColors.divider),
            for (final ChatWallpaper wall in wallpaperChoices)
              TgUserRow(
                key: ValueKey<String>('wallpaper-${wall.id}'),
                leading: SizedBox(
                  width: 28,
                  child: Center(
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: wall.isPlain ? TelegramColors.bgChat : null,
                        gradient: wall.isPlain
                            ? null
                            : LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: wall.colors,
                              ),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: TelegramColors.divider),
                      ),
                    ),
                  ),
                ),
                title: wall.name,
                trailing: wall.id == current
                    ? Icon(Icons.check, size: 18, color: TelegramColors.accent)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(wall.id),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      await ref.read(uiPrefsProvider.notifier).setWallpaperId(picked);
    }
  }

  Widget _sheetHeader(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
    child: Row(
      children: <Widget>[
        Text(
          title,
          style: TextStyle(
            color: TelegramColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        Text(
          '立即生效',
          style: TextStyle(color: TelegramColors.textMuted, fontSize: 12),
        ),
      ],
    ),
  );
}

/// 主题色小圆点（设置行尾 / 色板弹层共用）。
class _AccentDot extends StatelessWidget {
  const _AccentDot({required this.id, this.size = 18});

  final String id;
  final double size;

  @override
  Widget build(BuildContext context) {
    final AccentChoice c = accentChoiceOf(id);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.isDefault ? null : c.color,
        gradient: c.isDefault
            ? const LinearGradient(
                colors: <Color>[Color(0xFF8774E1), Color(0xFF3390EC)],
              )
            : null,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// 气泡圆角实时预览：左右各一个气泡，拖动滑块时圆角立刻变。
class _BubbleRadiusPreview extends StatelessWidget {
  const _BubbleRadiusPreview({required this.radius});

  final double radius;

  @override
  Widget build(BuildContext context) {
    final Radius big = Radius.circular(radius);
    final Radius tail = const Radius.circular(TelegramMetrics.bubbleTailRadius);

    Widget bubble({required bool out}) => Container(
      width: 96,
      height: 34,
      decoration: BoxDecoration(
        color: out ? TelegramColors.bubbleOut : TelegramColors.bubbleIn,
        borderRadius: BorderRadius.only(
          topLeft: big,
          topRight: big,
          bottomLeft: out ? big : tail,
          bottomRight: out ? tail : big,
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        children: <Widget>[
          bubble(out: false),
          const Spacer(),
          bubble(out: true),
        ],
      ),
    );
  }
}
