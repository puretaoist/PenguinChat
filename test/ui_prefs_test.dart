/// ui_prefs 的离线测试：默认值 / 单字段兜底 / 落盘读写 / 坏文件。
///
/// 这层刻意不依赖 Flutter（只用 File），所以能在 flutter test 里当纯 Dart 跑。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/ui/prefs/ui_prefs.dart';

void main() {
  group('UiPrefs 值对象', () {
    test('默认值：标准字号、通知开、动画开、紫色主题、纯色背景', () {
      const p = UiPrefs();
      expect(p.fontScale, 1.0);
      expect(p.notifications, isTrue);
      expect(p.messageAnimations, isTrue);
      expect(p.accentId, 'default');
      expect(p.wallpaperId, 'plain');
    });

    test('聊天列表四项默认：圆角 30（=圆形）、分隔线开、时间不带秒、未读数缩写', () {
      const p = UiPrefs();
      expect(p.avatarCorners, UiPrefs.avatarCornersDefault);
      expect(UiPrefs.avatarCornersDefault, 30.0);
      expect(p.disableDividers, isFalse);
      expect(p.timeWithSeconds, isFalse);
      // 字段是 disableNumberRounding，默认 false = 允许缩写
      expect(p.disableNumberRounding, isFalse);
      // 默认 30 必须落回"圆形"文案，别让用户以为默认是半圆
      expect(UiPrefs.avatarCornersLabel(30), '圆形');
      expect(UiPrefs.avatarCornersLabel(0), '方形');
      expect(UiPrefs.avatarCornersLabel(12), '12');
    });

    test('未读数文案：默认 K 缩写，noRounding 时原样', () {
      expect(formatUnreadCount(3), '3');
      expect(formatUnreadCount(999), '999');
      expect(formatUnreadCount(1234), '1.2K');
      expect(formatUnreadCount(12000), '12K');
      expect(formatUnreadCount(1234, noRounding: true), '1234');
    });

    test('九档主题色、五档聊天背景都有中文名，未知值退默认', () {
      expect(UiPrefs.accentIds.length, 9);
      expect(UiPrefs.accentIds.first, 'default');
      expect(UiPrefs.accentLabel('default'), '跟随主题');
      expect(UiPrefs.accentLabel('violet'), '紫色');
      expect(UiPrefs.accentLabel('blue'), '蓝色');
      expect(UiPrefs.accentLabel('nope'), '紫色');
      expect(UiPrefs.wallpaperIds.length, 5);
      expect(UiPrefs.wallpaperIds.first, 'plain');
      expect(UiPrefs.wallpaperLabel('plain'), '默认');
      expect(UiPrefs.wallpaperLabel('dusk'), '黄昏');
      expect(UiPrefs.wallpaperLabel('nope'), UiPrefs.wallpaperLabel('plain'));
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
        accentId: 'orange',
        wallpaperId: 'ocean',
        avatarCorners: 12,
        disableDividers: true,
        timeWithSeconds: true,
        disableNumberRounding: true,
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

    test('主题色/背景白名单外的值只回该字段', () {
      final p = UiPrefs.fromJson(<String, Object?>{
        'accent': 'rainbow',
        'wallpaper': 42,
        'font_scale': 1.2,
      });
      expect(p.accentId, 'default');
      expect(p.wallpaperId, 'plain');
      expect(p.fontScale, 1.2);
    });

    test('头像圆角越界/类型错都夹回 0–30', () {
      final tooBig = UiPrefs.fromJson(<String, Object?>{'avatar_corners': 99});
      expect(tooBig.avatarCorners, 30.0);
      final negative = UiPrefs.fromJson(<String, Object?>{'avatar_corners': -5});
      expect(negative.avatarCorners, 0.0);
      final wrongType = UiPrefs.fromJson(<String, Object?>{'avatar_corners': 'round'});
      expect(wrongType.avatarCorners, 30.0);
    });

    test('copyWith 只改指定字段', () {
      const p = UiPrefs();
      expect(p.copyWith(fontScale: 1.2).fontScale, 1.2);
      expect(p.copyWith(fontScale: 1.2).notifications, isTrue);
      expect(p.copyWith(notifications: false).fontScale, 1.0);
      expect(p.copyWith(accentId: 'red').wallpaperId, 'plain');
      expect(p.copyWith(wallpaperId: 'forest').accentId, 'default');
      expect(p.copyWith(accentId: 'red'), isNot(p.copyWith(accentId: 'gray')));
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

    test('改主题色/背景也立即写盘，重新构造能读回', () async {
      final target = prefsFile('look.json');
      final a = UiPrefsNotifier(target);
      await a.setAccentId('green');
      await a.setWallpaperId('sunset');
      final saved =
          jsonDecode(target.readAsStringSync()) as Map<String, Object?>;
      expect(saved['accent'], 'green');
      expect(saved['wallpaper'], 'sunset');

      final b = UiPrefsNotifier(target);
      await b.load();
      expect(b.state.accentId, 'green');
      expect(b.state.wallpaperId, 'sunset');
      expect(b.state.fontScale, 1.0);
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
