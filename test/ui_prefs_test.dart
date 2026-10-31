/// ui_prefs 的离线测试：默认值 / 单字段兜底 / 落盘读写 / 坏文件。
///
/// 这层刻意不依赖 Flutter（只用 File），所以能在 flutter test 里当纯 Dart 跑。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qqclient/ui/prefs/ui_prefs.dart';

void main() {
  group('UiPrefs 值对象', () {
    test('默认值：标准字号、通知开、动画开', () {
      const p = UiPrefs();
      expect(p.fontScale, 1.0);
      expect(p.notifications, isTrue);
      expect(p.messageAnimations, isTrue);
    });

    test('四档字号都有中文名，未知值退标准', () {
      expect(UiPrefs.fontScaleChoices, <double>[0.9, 1.0, 1.1, 1.2]);
      expect(UiPrefs.fontScaleLabel(0.9), '小');
      expect(UiPrefs.fontScaleLabel(1.0), '标准');
      expect(UiPrefs.fontScaleLabel(1.1), '大');
      expect(UiPrefs.fontScaleLabel(1.2), '特大');
      expect(UiPrefs.fontScaleLabel(1.37), '标准');
    });

    test('toJson → fromJson 往返无损', () {
      const p = UiPrefs(
        fontScale: 1.1,
        notifications: false,
        messageAnimations: false,
      );
      expect(UiPrefs.fromJson(p.toJson()), p);
      final decoded = jsonDecode(jsonEncode(p.toJson())) as Map<String, Object?>;
      expect(UiPrefs.fromJson(decoded), p);
    });

    test('单字段坏了只回该字段，不牵连其它两项', () {
      // 字号越界（0.5 < 0.8）→ 回 1.0；两个 bool 保持
      final p = UiPrefs.fromJson(<String, Object?>{
        'font_scale': 0.5,
        'notifications': false,
        'message_animations': false,
      });
      expect(p.fontScale, 1.0);
      expect(p.notifications, isFalse);
      expect(p.messageAnimations, isFalse);

      // 字号是字符串 → 回默认；notifications 类型错 → 回默认 true
      final q = UiPrefs.fromJson(<String, Object?>{
        'font_scale': 'big',
        'notifications': 1,
      });
      expect(q.fontScale, 1.0);
      expect(q.notifications, isTrue);
      expect(q.messageAnimations, isTrue);
    });

    test('copyWith 只改指定字段', () {
      const p = UiPrefs();
      expect(p.copyWith(fontScale: 1.2).fontScale, 1.2);
      expect(p.copyWith(fontScale: 1.2).notifications, isTrue);
      expect(p.copyWith(notifications: false).fontScale, 1.0);
    });
  });

  group('UiPrefsNotifier 落盘', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ui_prefs_test_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    File prefsFile(String name) =>
        File(dir.path + Platform.pathSeparator + name);

    test('改一项就立即写盘，重新构造能读回', () async {
      final target = prefsFile('ui_prefs.json');
      final a = UiPrefsNotifier(target);
      await a.setFontScale(1.2);
      await a.setNotifications(false);
      expect(target.existsSync(), isTrue);

      final saved =
          jsonDecode(target.readAsStringSync()) as Map<String, Object?>;
      expect(saved['font_scale'], 1.2);
      expect(saved['notifications'], false);

      final b = UiPrefsNotifier(target);
      await b.load();
      expect(b.state.fontScale, 1.2);
      expect(b.state.notifications, isFalse);
      expect(b.state.messageAnimations, isTrue);
    });

    test('文件不存在时不抛，保持默认', () async {
      final n = UiPrefsNotifier(prefsFile('nope.json'));
      await n.load();
      expect(n.state, const UiPrefs());
    });

    test('内容坏掉时不抛，保持默认（并允许后续写入覆盖）', () async {
      final target = prefsFile('bad.json');
      target.writeAsStringSync('{not json');
      final n = UiPrefsNotifier(target);
      await n.load();
      expect(n.state, const UiPrefs());
      await n.setMessageAnimations(false);
      expect(n.state.messageAnimations, isFalse);
      final saved =
          jsonDecode(target.readAsStringSync()) as Map<String, Object?>;
      expect(saved['message_animations'], false);
    });

    test('文件句柄为 null 时只改内存不抛', () async {
      final n = UiPrefsNotifier(null);
      await n.setFontScale(0.9);
      expect(n.state.fontScale, 0.9);
    });

    test('设成当前值不重复写盘（不建文件）', () async {
      final target = prefsFile('same.json');
      final n = UiPrefsNotifier(target);
      await n.setFontScale(1.0); // 与默认相同 → _update 早退
      expect(target.existsSync(), isFalse);
    });
  });
}
