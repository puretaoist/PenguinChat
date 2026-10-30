/// L3 客户端 API 层：**账号数据根目录**（P1 账号隔离的地基，纯 Dart）。
///
/// ## 为什么需要它
///
/// 此前 `ChatStore` 直接吃全局 `dataDir`，于是 `chats.json` / `chats/*.jsonl` /
/// `media/` / `media_index.json` 全在一个池子里。换号登录后：
///
/// * 会话列表会出现上个号的会话；
/// * **同 chatId**（私聊 id 就是对方 uin，群 id 就是群号）会互相命中——
///   A 与 B 都与同一个人聊过时，id 完全相同，媒体缓存、草稿、未读全部串；
/// * 两份 `ChatStore` 若并发 bootstrap，还会抢同一个索引文件。
///
/// 只把 `chats.json` 挪走是不够的：媒体与 media_index 也必须换根，否则
/// 「id 相同」这一层串号依然成立。所以规范定成**每个账号一个根**。
///
/// ## 目录规范
///
/// ```text
/// <dataDir>/accounts/<十进制uin>/
///     chats.json
///     chats/<chatId>.jsonl
///     media/<分类>/…
///     media_index.json
/// ```
///
/// ## 校验
///
/// 账号只接受**协议自己能写出去的 uin**：`1 ..= 0xFFFFFFFF`（TLV 里 uin 按
/// u32 写）。这里唯一的目的是**目录安全**——不允许 `..`、分隔符、空串、
/// 负数出现在路径段里；它**不是**账号合法性校验，也不代表 uin 只能是某个
/// 位数（历史上有 5 位号，也有 10 位号）。
///
/// 用十进制 `int` 拼路径段，本身就排除了 `../` 这类注入：`int.toString()`
/// 只会产出数字与 `-`，而负数已被范围挡掉。
library;

import 'dart:io';

/// 一个账号的数据根。
class AccountScope {
  const AccountScope._(this.root, this.uin);

  /// 该账号的数据根目录（`<dataDir>/accounts/<uin>`）。**不保证已存在**。
  final Directory root;

  /// 十进制 uin（`1 ..= 0xFFFFFFFF`）。
  final int uin;

  /// `dataDir` 下的账号目录名。
  static const String accountsDirName = 'accounts';

  /// 协议能表达的 uin 下界。0 在协议里是「还不知道是谁」（见
  /// `qq8_login_service.dart` 的手机号流程），不是一个真实账号。
  static const int minUin = 1;

  /// 协议能表达的 uin 上界：TLV / SSO 头里的 uin 是 u32。
  static const int maxUin = 0xFFFFFFFF;

  /// 是否是可落盘的账号号段。
  static bool isValidUin(int uin) => uin >= minUin && uin <= maxUin;

  /// 所有账号目录的父目录（`<dataDir>/accounts`）。**不保证已存在**。
  static Directory accountsRoot(Directory dataDir) => Directory(
      '${dataDir.path}${Platform.pathSeparator}$accountsDirName');

  /// 取（不创建）账号根。uin 不合法时抛 [ArgumentError]。
  ///
  /// 调用方：登录上线后建 `ChatStore` 前。**不要在 UI 里猜 uin**——
  /// 必须用登录服务确认过的那个号。
  static AccountScope of(Directory dataDir, int uin) {
    if (!isValidUin(uin)) {
      throw ArgumentError.value(
        uin,
        'uin',
        '账号不在可写盘范围（$minUin ..= 0xFFFFFFFF），拒绝拼进路径',
      );
    }
    return AccountScope._(
      Directory('${accountsRoot(dataDir).path}${Platform.pathSeparator}$uin'),
      uin,
    );
  }

  /// 同 [of]，但不合法时返回 null（给「手上有个可疑 uin，先别炸」的调用方）。
  static AccountScope? tryOf(Directory dataDir, int? uin) {
    if (uin == null || !isValidUin(uin)) return null;
    return of(dataDir, uin);
  }

  @override
  String toString() => 'AccountScope($uin → ${root.path})';
}
