/// `AccountScope` 自测（纯 Dart，离线）。
///
/// 只验目录规范与路径安全，不碰真机、不联网、不写系统目录：
/// 全部在临时目录里跑，结束删掉。
///
/// 运行：
/// ```text
/// dart run tool/account_scope_selftest.dart
/// ```
library;

import 'dart:io';

import 'package:qqclient/client_api/account_scope.dart';

int passed = 0;
int failed = 0;

void check(String name, bool cond, [String? detail]) {
  if (cond) {
    passed++;
    print('  ✓ $name');
  } else {
    failed++;
    print('  ✗ $name${detail == null ? '' : ' — $detail'}');
  }
}

void main() {
  final tmp = Directory.systemTemp.createTempSync('qqclient_scope_');
  try {
    print('AccountScope');

    // ---- 目录规范 ----
    final a = AccountScope.of(tmp, 10001);
    final b = AccountScope.of(tmp, 10002);
    check('两个账号根的路径不同', a.root.path != b.root.path);
    check('根在 accounts/ 之下',
        a.root.path.contains('${Platform.pathSeparator}accounts'
            '${Platform.pathSeparator}'));
    check('路径段是十进制 uin', a.root.path.endsWith('${Platform.pathSeparator}10001'));
    check('dataDir 不变（accounts 只是子目录）',
        AccountScope.accountsRoot(tmp).parent.path == tmp.path);
    check('同 uin 两次取到同一路径', AccountScope.of(tmp, 10001).root.path == a.root.path);

    // ---- 范围 ----
    check('uin=1 可用', AccountScope.isValidUin(1));
    check('uin=0xFFFFFFFF 可用', AccountScope.isValidUin(0xFFFFFFFF));
    check('uin=0 不可用（协议里 0 = 还不知道是谁）',
        !AccountScope.isValidUin(0));
    check('uin=-1 不可用', !AccountScope.isValidUin(-1));
    check('uin=0x100000000 不可用（超出 u32）',
        !AccountScope.isValidUin(0x100000000));

    // ---- 拒绝非法输入（不得进路径）----
    bool rejected(int uin) {
      try {
        AccountScope.of(tmp, uin);
        return false;
      } on ArgumentError {
        return true;
      }
    }

    check('of(0) 抛 ArgumentError', rejected(0));
    check('of(-1) 抛 ArgumentError', rejected(-1));
    check('of(0x100000000) 抛 ArgumentError', rejected(0x100000000));

    check('tryOf(null) = null', AccountScope.tryOf(tmp, null) == null);
    check('tryOf(0) = null', AccountScope.tryOf(tmp, 0) == null);
    check('tryOf(合法) 非 null', AccountScope.tryOf(tmp, 42) != null);

    check('tryOf 与 of 对同一 uin 路径一致',
        AccountScope.tryOf(tmp, 42)!.root.path ==
            AccountScope.of(tmp, 42).root.path);

    // ---- 不隐式建目录（建目录是 ChatStore.bootstrap 的事）----
    check('of() 不创建目录', !a.root.existsSync());
    check('accounts 根也不创建',
        !AccountScope.accountsRoot(tmp).existsSync());

    // ---- toString 不泄露票据（这里只是防以后加字段）----
    final s = a.toString();
    check('toString 含 uin', s.contains('10001'));
    check('toString 不含 "null"', !s.contains('null'));
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }

  print('\n通过 $passed 项，失败 $failed 项');
  exit(failed == 0 ? 0 : 1);
}
