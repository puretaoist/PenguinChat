/// L2 协议内核：群设置与成员管理（OIDB）
///
/// 参考实现：
/// * `../analysis/_ref/oicq-src/lib/group.ts`：`announce()` :413 / `setName()` :405 /
///   `muteAll()` :409 都走 **`OidbSvc.0x89a_0`** 的 `_setting()`（:416-423）：
///   body = `{1: 群号, 2: {3: 群名 | 4: 公告 | 17: 全员禁言}}`，判 `[3] === 0`。
/// * `../analysis/_ref/oicq-src/lib/member.ts`：`setAdmin()` :116（`OidbSvc.0x55c_1`，
///   9 字节二进制 gid/uid/开关）、`kick()` :160（`OidbSvc.0x8a0_0`）、
///   `mute()` :176（`OidbSvc.0x570_8`，15 字节二进制）。
///
/// 本文件只做「组包 / 解包」，不碰网络。
library;

import 'dart:typed_data';

import 'qq8_pb.dart';

/// 群管理操作在本地就失败（参数不合法、应答缺字段…）。
class Qq8GroupAdminException implements Exception {
  final String message;
  Qq8GroupAdminException(this.message);

  @override
  String toString() => 'Qq8GroupAdminException: $message';
}

/// 群设置 / 成员管理。
abstract final class Qq8GroupAdmin {
  // ---------------------------------------------------------------- 命令字

  /// 群设置（群名 / 群公告 / 全员禁言共用）。
  static const String cmdSetting = 'OidbSvc.0x89a_0';

  /// 踢人。
  static const String cmdKick = 'OidbSvc.0x8a0_0';

  /// 禁言单个成员（二进制 15 字节）。
  static const String cmdMuteMember = 'OidbSvc.0x570_8';

  /// 设/取消管理员（二进制 9 字节）。
  static const String cmdSetAdmin = 'OidbSvc.0x55c_1';

  /// 全员禁言的「开」值（参考实现 `0xffffffff`）。
  static const int wholeMuteOn = 0xffffffff;

  /// 单人禁言上限（参考实现 2592000 = 30 天，超了按上限算）。
  static const int maxMuteSeconds = 2592000;

  // ------------------------------------------------------------ 群设置

  /// 群设置请求体（`OidbSvc.0x89a_0`）。
  ///
  /// 三个开关可以一次给多个；一个都不给属于调用方写错，直接抛。
  static Uint8List buildSettingBody({
    required int gid,
    String? name,
    String? announce,
    bool? wholeMute,
  }) {
    if (name == null && announce == null && wholeMute == null) {
      throw Qq8GroupAdminException('群设置至少要改一项（群名/公告/全员禁言）');
    }
    return Qq8Pb.encode(<int, Object?>{
      1: gid,
      2: <int, Object?>{
        3: ?name,
        4: ?announce,
        if (wholeMute != null) 17: wholeMute ? wholeMuteOn : 0,
      },
    });
  }

  /// 群设置应答：顶层 `3` = 结果码（0 成功）。
  static ({bool ok, int? code, String? message}) parseSetting(
    Uint8List payload,
  ) {
    final top = Qq8Pb.decode(payload);
    final code = Qq8Pb.intAt(top, 3);
    if (code == null) {
      return (ok: false, code: null, message: '应答没有结果码（顶层 3 缺失）');
    }
    return (ok: code == 0, code: code, message: null);
  }

  // -------------------------------------------------------------- 踢人

  /// 踢人请求体（`OidbSvc.0x8a0_0`）。
  static Uint8List buildKickBody({
    required int gid,
    required int uid,
    bool rejectAddRequest = false,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: gid,
        2: <int, Object?>{
          1: 5,
          2: uid,
          3: rejectAddRequest ? 1 : 0,
        },
      });

  /// 踢人应答：`[4][2][1] == 0` 才算成功（参考实现同判据）。
  static ({bool ok, int? code, String? message}) parseKick(Uint8List payload) {
    final top = Qq8Pb.decode(payload);
    final rsp4 = _msg(top, 4);
    final rsp = rsp4 == null ? null : _msg(rsp4, 2);
    if (rsp == null) {
      return (ok: false, code: null, message: '应答缺少 [4][2]');
    }
    final code = Qq8Pb.intAt(rsp, 1);
    if (code == null) {
      return (ok: false, code: null, message: '应答缺少 [4][2][1]');
    }
    return (ok: code == 0, code: code, message: null);
  }

  // -------------------------------------------------------------- 禁言

  /// 禁言单个成员（`OidbSvc.0x570_8`，纯二进制 15 字节）。
  ///
  /// 布局：`u32 群号 ‖ u8 32 ‖ u16 1 ‖ u32 对方 uin ‖ u32 秒数`。
  /// 秒数会被夹到 `[0, 2592000]`；0 = 解除禁言。
  static Uint8List buildMuteMemberBody({
    required int gid,
    required int uid,
    int seconds = 1800,
  }) {
    var s = seconds;
    if (s < 0) s = 0;
    if (s > maxMuteSeconds) s = maxMuteSeconds;
    final b = BytesBuilder(copy: false);
    void u32(int v) {
      b.add(<int>[
        (v >> 24) & 0xff,
        (v >> 16) & 0xff,
        (v >> 8) & 0xff,
        v & 0xff,
      ]);
    }

    u32(gid);
    b.addByte(32);
    b.add(<int>[0, 1]);
    u32(uid);
    u32(s);
    return b.takeBytes();
  }

  /// 禁言应答：参考实现**不检查**（发完就算），这里只取顶层结果码，
  /// 取不到就返回 null 让调用方知道"没有确认"，不假装成功。
  static ({bool ok, int? code, String? message}) parseMuteMember(
    Uint8List payload,
  ) {
    final top = Qq8Pb.decode(payload);
    final code = Qq8Pb.intAt(top, 3);
    if (code == null) {
      return (ok: false, code: null, message: '应答没有结果码（顶层 3 缺失）');
    }
    return (ok: code == 0, code: code, message: null);
  }

  // ---------------------------------------------------------- 设管理员

  /// 设/取消管理员（`OidbSvc.0x55c_1`，9 字节二进制
  /// `u32 群号 ‖ u32 对方 uin ‖ u8 开关`）。
  static Uint8List buildSetAdminBody({
    required int gid,
    required int uid,
    bool enable = true,
  }) {
    final b = BytesBuilder(copy: false);
    void u32(int v) {
      b.add(<int>[
        (v >> 24) & 0xff,
        (v >> 16) & 0xff,
        (v >> 8) & 0xff,
        v & 0xff,
      ]);
    }

    u32(gid);
    u32(uid);
    b.addByte(enable ? 1 : 0);
    return b.takeBytes();
  }

  /// 设管理员应答：顶层 `3 == 0`。
  static ({bool ok, int? code, String? message}) parseSetAdmin(
    Uint8List payload,
  ) {
    final top = Qq8Pb.decode(payload);
    final code = Qq8Pb.intAt(top, 3);
    if (code == null) {
      return (ok: false, code: null, message: '应答没有结果码（顶层 3 缺失）');
    }
    return (ok: code == 0, code: code, message: null);
  }

  // ---------------------------------------------------------------- 助手

  /// 取子消息（`tag` 是一个 length-delimited 的嵌套结构）。
  static Map<int, List<Object>>? _msg(Map<int, List<Object>> top, int tag) {
    final bytes = Qq8Pb.bytesAt(top, tag);
    return bytes == null ? null : Qq8Pb.decode(bytes);
  }
}
