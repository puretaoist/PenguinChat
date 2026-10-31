// 新消息系统通知的判定逻辑自测（纯 Dart，不需要 Flutter / 设备）。
//
// 跑法：dart run tool/notify_policy_selftest.dart
//
// 只测 L3 的 `lib/client_api/notify_policy.dart`。平台侧（MethodChannel +
// NotificationChannel）只能真机验证，但「这条消息该不该弹」是最容易写错的
// 部分：弹多了是骚扰（尤其上线补拉的几十条历史），弹少了是漏消息。
import 'dart:io';

import 'package:qqclient/client_api/notify_policy.dart';

int passed = 0;
int failed = 0;

void ok(String name, [String? note]) {
  passed++;
  stdout.writeln('  ok  $name' + (note == null ? '' : '  ($note)'));
}

void bad(String name, String why) {
  failed++;
  stdout.writeln('FAIL  $name\n      $why');
}

void check(String name, bool cond, [String note = '']) {
  if (cond) {
    ok(name, note.isEmpty ? null : note);
  } else {
    bad(name, note.isEmpty ? '条件为假' : note);
  }
}

final DateTime now = DateTime(2026, 10, 31, 15, 30);

NotifyDecision decide({
  bool outgoing = false,
  bool system = false,
  bool muted = false,
  bool appForeground = false,
  String chatId = 'private_10001',
  String? activeChatId,
  Duration age = Duration.zero,
  bool hasContent = true,
}) =>
    qq8DecideNotify(
      outgoing: outgoing,
      system: system,
      muted: muted,
      appForeground: appForeground,
      chatId: chatId,
      activeChatId: activeChatId,
      messageTime: now.subtract(age),
      now: now,
      hasContent: hasContent,
    );

void main() {
  stdout.writeln('notify_policy_selftest');

  // ---- 排除项：顺序与理由 ----
  final d1 = decide(outgoing: true);
  check('[1] 自己发的消息不通知', !d1.notify && d1.skip == NotifySkip.outgoing, d1.toString());

  final d2 = decide(system: true);
  check('[2] 系统提示不通知', !d2.notify && d2.skip == NotifySkip.system, d2.toString());

  final d3 = decide(muted: true);
  check('[3] 免打扰会话不通知', !d3.notify && d3.skip == NotifySkip.muted, d3.toString());

  final d4 = decide(appForeground: true, activeChatId: 'private_10001');
  check('[4] 前台且正在看这个会话 → 不通知',
      !d4.notify && d4.skip == NotifySkip.appVisible, d4.toString());

  final d5 = decide(appForeground: true, activeChatId: 'private_20002');
  check('[5] 前台但在看别的会话 → 也不通知（应用内可见即可）',
      !d5.notify && d5.skip == NotifySkip.appVisible, d5.toString());

  final d6 = decide(hasContent: false);
  check('[6] 没有可显示内容不通知', !d6.notify && d6.skip == NotifySkip.empty, d6.toString());

  // ---- 正例 ----
  final d7 = decide();
  check('[7] 后台 + 实时 + 有内容 → 通知', d7.notify && d7.skip == null, d7.toString());

  final d8 = decide(age: const Duration(seconds: 30));
  check('[8] 后台 + 30 秒前 → 通知', d8.notify, d8.toString());

  final d9 = decide(age: qq8NotifyMaxAge);
  check('[9] 恰好 5 分钟边界 → 仍通知（<= 阈值）', d9.notify, d9.toString());

  final d10 = decide(age: const Duration(minutes: 6));
  check('[10] 6 分钟前的补拉历史 → 不通知（防轰炸）',
      !d10.notify && d10.skip == NotifySkip.stale, d10.toString());

  final d11 = decide(age: const Duration(seconds: -20));
  check('[11] 时钟偏差（未来 20 秒）→ 照常通知', d11.notify, d11.toString());

  // 上线补拉的典型场景：20 条历史，时间多为数小时前。
  final d12 = decide(age: const Duration(hours: 3));
  check('[12] 上线补拉（3 小时前）→ 不通知', !d12.notify && d12.skip == NotifySkip.stale,
      d12.toString());

  // ---- 判定顺序：多个排除项同时成立时，报最贴近用户意图的那个 ----
  final d13 = decide(outgoing: true, muted: true, appForeground: true);
  check('[13] 同时自己发 + 免打扰 + 前台 → 先报 outgoing',
      d13.skip == NotifySkip.outgoing, d13.toString());

  final d14 = decide(system: true, muted: true);
  check('[14] 同时系统消息 + 免打扰 → 先报 system', d14.skip == NotifySkip.system,
      d14.toString());

  final d15 = decide(muted: true, appForeground: true);
  check('[15] 同时免打扰 + 前台 → 先报 muted', d15.skip == NotifySkip.muted,
      d15.toString());

  // ---- 全组合穷举：只有「非自己发、非系统、非免打扰、后台、新鲜、有内容」才通知 ----
  var notified = 0;
  var total = 0;
  var mismatched = 0;
  for (final outgoing in [false, true]) {
    for (final system in [false, true]) {
      for (final muted in [false, true]) {
        for (final foreground in [false, true]) {
          for (final age in [Duration.zero, const Duration(hours: 1)]) {
            for (final content in [false, true]) {
              total++;
              final d = decide(
                outgoing: outgoing,
                system: system,
                muted: muted,
                appForeground: foreground,
                age: age,
                hasContent: content,
              );
              final expect = !outgoing &&
                  !system &&
                  !muted &&
                  !foreground &&
                  age <= qq8NotifyMaxAge &&
                  content;
              if (d.notify != expect) {
                mismatched++;
                bad(
                  '[16] 组合与预期不符',
                  'outgoing=$outgoing system=$system muted=$muted fg=$foreground '
                      'age=$age content=$content → $d（预期 $expect）',
                );
              } else if (d.notify) {
                notified++;
              }
            }
          }
        }
      }
    }
  }
  check('[16] 64 种组合穷举全部符合预期（仅 1 种会通知）', mismatched == 0 && notified == 1,
      '共 ' + total.toString() + ' 种，通知 ' + notified.toString() + ' 种');

  // ---- 预览与标题 ----
  check('[17] 空文本兜底', qq8NotifyPreview('   ') == '新消息', qq8NotifyPreview('   '));
  check('[18] 普通文本原样', qq8NotifyPreview('在吗') == '在吗');
  final long = 'a' * 200;
  final preview = qq8NotifyPreview(long);
  check('[19] 超长截断到 120 字符 + 省略号', preview.length == 121 && preview.endsWith('…'),
      preview.length.toString() + ' 字符');

  check('[20] 私聊标题=对方昵称',
      qq8NotifyTitle(chatTitle: '小林', isGroup: false, senderName: '小林') == '小林');
  check('[21] 私聊无标题时退回发送者名',
      qq8NotifyTitle(chatTitle: '', isGroup: false, senderName: '小林') == '小林');
  check('[22] 群标题=群名 · 发言人',
      qq8NotifyTitle(chatTitle: '追梦群', isGroup: true, senderName: '老王') == '追梦群 · 老王');
  check('[23] 群发言人缺失时只显示群名',
      qq8NotifyTitle(chatTitle: '追梦群', isGroup: true, senderName: '') == '追梦群');

  stdout.writeln('');
  stdout.writeln('pass=$passed fail=$failed');
  if (failed > 0) exitCode = 1;
}
