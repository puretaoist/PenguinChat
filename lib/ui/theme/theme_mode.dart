/// L4 表现层：当前主题模式（暗/亮）+ 落盘
///
/// 只存"是暗色吗"这一个布尔：亮色值 [TelegramPalette.light] 与暗色
/// [TelegramPalette.dark] 是同一套字段，没有第三种中间态。
///
/// 为什么不做"跟随系统"：`MediaQuery.platformBrightness` 在桌面端不可靠，
/// 而本项目的主题切换入口只有会话列表头部这一个按钮——加一档"自动"只会让
/// 按钮多一个状态、少一分可预期。要做时把它换成三值枚举即可，其余代码不用动。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/session_providers.dart';
import 'telegram_theme.dart';

/// 主题模式的读写。落盘 `<dataDir>/ui_settings.json`（与
/// `connection.json` 同一套路：L4 不碰 `shared_preferences`，它依赖平台通道，
/// 而文件读写能被 widget 测试直接覆盖）。
class ThemeModeNotifier extends StateNotifier<bool> {
  /// [file] 为 null 表示不落盘（测试里只想验证内存行为时用）。
  ThemeModeNotifier(this._file) : super(true);

  final File? _file;

  /// 读回上次的选择。**不抛异常**：文件坏了大不了回暗色，不该拦住启动。
  Future<void> load() async {
    final f = _file;
    if (f == null) return;
    try {
      if (!f.existsSync()) return;
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map && decoded['dark'] is bool) {
        state = decoded['dark'] as bool;
      }
    } catch (e) {
      // 只回暗色，不抛：这里没有日志通道（L4 不引 Log），
      // 坏文件的表现就是"回到默认主题"，无副作用。
      state = true;
    }
  }

  /// 改主题并落盘（写盘失败不回滚：内存里的选择已经生效，
  /// 大不了下次启动回到默认，不值得为它弹错误）。
  Future<void> setDark(bool dark) async {
    state = dark;
    final f = _file;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(<String, dynamic>{'dark': state}));
    } catch (_) {
      // 见上：静默
    }
  }

  Future<void> toggle() => setDark(!state);
}

/// true = 暗色（默认，和现行 Telegram 的默认一致）。
final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, bool>((ref) {
  final notifier = ThemeModeNotifier(
    File('${ref.watch(dataDirProvider).path}${Platform.pathSeparator}ui_settings.json'),
  );
  // load() 内部已吞掉所有异常，这里不 await 不会产生未处理的异步错误
  unawaited(notifier.load());
  return notifier;
});

/// 读模式 + 把调色板切成对应的那套，返回是否为暗色。
///
/// **每个 watch 了 [themeModeProvider] 的 build 都要先调它**。原因：调色板是
/// 全局单例，谁先重建谁负责把它设对——只让根组件设的话，先于根组件重建的
/// 子树会读到上一帧的调色板（Riverpod 的通知顺序不保证根在前）。
///
/// 放在 theme_mode.dart 而不是 telegram_theme.dart，是为了让"能切主题的代码"
/// 才依赖 riverpod：金样测试直接 pump 气泡时不需要 ProviderScope。
bool applyThemePalette(WidgetRef ref) {
  final dark = ref.watch(themeModeProvider);
  TelegramColors.use(dark ? TelegramPalette.dark : TelegramPalette.light);
  return dark;
}
