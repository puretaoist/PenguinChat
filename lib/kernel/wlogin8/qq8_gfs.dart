/// L2 协议内核：群文件系统（GFS）
///
/// 参考实现：`../analysis/_ref/oicq-src/lib/gfs.ts`（Gfs 类，461 行）。
/// 命令字与 body 布局全部照抄该文件；本文件只做「组包 / 解包」，不碰网络。
///
/// ## 命令字一览（参考 gfs.ts 每一处 sendOidb）
///
/// | 动作 | 命令字 | body 主要字段 |
/// |---|---|---|
/// | 列目录 | `OidbSvc.0x6d8_1` | `{2: {1: gid, 2: 1, 3: pid, 5: limit, 13: start}}` |
/// | 取属性 | `OidbSvc.0x6d8_0` | `{1: {1: gid, 2: 0, 4: fid}}` |
/// | 申请上传 | `OidbSvc.0x6d6_0` | `{1: {1: gid, 2: 0, 3: 102, 4: 5, 5: pid, 6: name, 7: 本地路径, 8: size, 9: sha1, 11: md5, 15: 1}}` |
/// | 取下载地址 | `OidbSvc.0x6d6_2` | `{3: {1: gid, 2: 2, 3: busid, 4: fid}}` |
/// | 删除文件 | `OidbSvc.0x6d6_3` | `{4: {1: gid, 2: 3, 3: busid, 4: pid, 5: fid}}` |
/// | 上传完成回执 | `OidbSvc.0x6d9_4` | `{5: {1: gid, 2: 4, 3: {1: busid, 2: fid, 3: rand, 5: 1}}}` |
///
/// 上传数据本体走 highway（`CmdID.GroupFile = 71`），与图片同一套帧
/// （[Qq8Highway]），**但请求头必须带 `3: ext`**（见 [buildUploadExt]）。
///
/// ## 应答的固定层数
///
/// 所有 OIDB 应答都是 `payload[4]` = OIDB 身体，之后按动作取子号：
/// 0x6d8_1 → `[4][2]`、0x6d8_0 → `[4][1]`、0x6d6_0 → `[4][1]`、
/// 0x6d6_2 → `[4][3]`、0x6d6_3 → `[4][4]`、0x6d9_4 → `[4][5]`。
/// 每个子号里 `1` = 错误码（0 为成功）、`2` = 错误文案。
///
/// 黄金向量：`../analysis/scripts/gen_gfs_vectors.py`（独立第二实现），
/// 断言见 `tool/qq8_gfs_selftest.dart`。
library;

import 'dart:typed_data';

import 'qq8_pb.dart';

/// 群文件操作失败。
class Qq8GfsException implements Exception {
  final String message;
  Qq8GfsException(this.message);

  @override
  String toString() => 'Qq8GfsException: $message';
}

/// 一个群文件或群目录条目。
///
/// 字段号来源：参考实现 `genGfsFileStat` / `genGfsDirStat`。
class Qq8GfsEntry {
  /// 文件/目录 id（目录以 `/` 开头；根目录就是 `/`）。
  final String fid;

  /// 所在目录 id。
  final String pid;

  final String name;

  /// true = 目录。
  final bool isDir;

  /// 文件字节数（目录为 0）。
  final int size;

  /// 业务号（0x6d6_2/_3 要用它）。
  final int busid;

  /// 文件 md5（原始 16 字节）。
  final Uint8List? md5;

  /// 文件 sha1（原始 20 字节）。
  final Uint8List? sha1;

  /// 上传者 uin。
  final int uploaderUin;

  /// 上传时间（秒级）。
  final int createTime;

  final int downloadTimes;

  /// 视频/语音时长（秒）。
  final int duration;

  /// 目录内文件数（文件为 0）。
  final int fileCount;

  const Qq8GfsEntry({
    required this.fid,
    required this.pid,
    required this.name,
    required this.isDir,
    this.size = 0,
    this.busid = 0,
    this.md5,
    this.sha1,
    this.uploaderUin = 0,
    this.createTime = 0,
    this.downloadTimes = 0,
    this.duration = 0,
    this.fileCount = 0,
  });

  String get md5Hex => _hex(md5);
  String get sha1Hex => _hex(sha1);

  /// 人类可读大小（B/KB/MB/GB，一位小数）。
  String get sizeText {
    if (isDir) return '$fileCount 个文件';
    if (size < 1024) return '$size B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var v = size / 1024;
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(1)} ${units[i]}';
  }

  @override
  String toString() =>
      'Qq8GfsEntry($fid, $name, dir=$isDir, size=$size, busid=$busid)';
}

/// 群文件系统的组包 / 解包。
abstract final class Qq8Gfs {
  // ---------------------------------------------------------------- 命令字

  static const String cmdDir = 'OidbSvc.0x6d8_1';
  static const String cmdStat = 'OidbSvc.0x6d8_0';
  static const String cmdApplyUpload = 'OidbSvc.0x6d6_0';
  static const String cmdDownload = 'OidbSvc.0x6d6_2';
  static const String cmdDelete = 'OidbSvc.0x6d6_3';
  static const String cmdFeed = 'OidbSvc.0x6d9_4';
  static const String cmdMkdir = 'OidbSvc.0x6d7_0';
  static const String cmdDeleteDir = 'OidbSvc.0x6d7_1';
  static const String cmdRenameDir = 'OidbSvc.0x6d7_2';
  static const String cmdRenameFile = 'OidbSvc.0x6d6_4';
  static const String cmdMoveFile = 'OidbSvc.0x6d6_5';

  /// 0x6d8 系列（目录/属性）。
  static const int type1Dir = 0x6d8;

  /// 0x6d6 系列（文件写操作）。
  static const int type1File = 0x6d6;

  /// 0x6d9 系列（上传完成回执）。
  static const int type1Feed = 0x6d9;

  /// 0x6d7 系列（目录写操作：建/删/改名）。
  static const int type1DirWrite = 0x6d7;

  /// highway 上的群文件业务号（参考实现 `CmdID.GroupFile`）。
  static const int highwayCmdIdGroupFile = 71;

  /// 上传扩展里的固定客户端串（参考实现硬编码 `"9e9c09dc"`）。
  static const String clientKey = '9e9c09dc';

  /// 官方 Android 端上传时上报的本地路径（会被服务端展示成来源路径）。
  static const String defaultUploadPathPrefix =
      '/storage/emulated/0/Pictures/files/s/';

  /// 根目录 id。
  static const String rootPid = '/';

  // ------------------------------------------------------------ 列目录

  /// 列目录请求体（`OidbSvc.0x6d8_1`）。
  static Uint8List buildDirBody({
    required int gid,
    String pid = rootPid,
    int start = 0,
    int limit = 100,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        2: <int, Object?>{
          1: gid,
          2: 1,
          3: pid,
          5: limit <= 0 ? 100 : limit,
          13: start,
        },
      });

  /// 解列目录应答：`[4][2]`，其中 `5` 是 repeated（每个元素里 `2`=目录、`3`=文件）。
  static ({int code, String? message, List<Qq8GfsEntry> entries}) parseDir(
    Uint8List payload,
  ) {
    final top = Qq8Pb.decode(payload);
    final rsp = _msg(_msg(top, 4), 2);
    if (rsp == null) return (code: -1, message: '应答缺少 [4][2]', entries: const []);
    final code = Qq8Pb.intAt(rsp, 1) ?? 0;
    final message = Qq8Pb.textAt(rsp, 2);
    final entries = <Qq8GfsEntry>[];
    for (final item in rsp[5] ?? const <Object>[]) {
      if (item is! Uint8List) continue;
      final inner = Qq8Pb.decode(item);
      final dirBytes = Qq8Pb.bytesAt(inner, 2);
      final fileBytes = Qq8Pb.bytesAt(inner, 3);
      if (fileBytes != null) {
        entries.add(_fileStat(Qq8Pb.decode(fileBytes)));
      } else if (dirBytes != null) {
        entries.add(_dirStat(Qq8Pb.decode(dirBytes)));
      }
    }
    return (code: code, message: message, entries: entries);
  }

  // ------------------------------------------------------------ 取属性

  /// 取文件/目录属性请求体（`OidbSvc.0x6d8_0`）。
  static Uint8List buildStatBody({required int gid, required String fid}) =>
      Qq8Pb.encode(<int, Object?>{
        1: <int, Object?>{
          1: gid,
          2: 0,
          4: fid,
        },
      });

  /// 解属性应答：`[4][1]`，条目在 `4`。
  static ({int code, String? message, Qq8GfsEntry? entry}) parseStat(
    Uint8List payload,
  ) {
    final top = Qq8Pb.decode(payload);
    final rsp = _msg(_msg(top, 4), 1);
    if (rsp == null) return (code: -1, message: '应答缺少 [4][1]', entry: null);
    final code = Qq8Pb.intAt(rsp, 1) ?? 0;
    final message = Qq8Pb.textAt(rsp, 2);
    final bytes = Qq8Pb.bytesAt(rsp, 4);
    final entry = bytes == null ? null : _fileStat(Qq8Pb.decode(bytes));
    return (code: code, message: message, entry: entry);
  }

  // ------------------------------------------------------------ 申请上传

  /// 申请上传请求体（`OidbSvc.0x6d6_0`）。
  ///
  /// [localPath] 只是**上报字符串**（服务端不会去读），参考实现固定写
  /// `/storage/emulated/0/Pictures/files/s/<name>`。
  static Uint8List buildApplyUploadBody({
    required int gid,
    required String name,
    required int size,
    required Uint8List md5,
    required Uint8List sha1,
    String pid = rootPid,
    String? localPath,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: <int, Object?>{
          1: gid,
          2: 0,
          3: 102,
          4: 5,
          5: pid,
          6: name,
          7: localPath ?? '$defaultUploadPathPrefix$name',
          8: size,
          9: sha1,
          11: md5,
          15: 1,
        },
      });

  /// 解申请上传应答：`[4][1]`。
  ///
  /// * `10` 非 0 ⇒ 服务端已有同 md5 文件（秒传），不需要再传数据；
  /// * `6` = busid、`7` = fid、`9` = 上传会话票据（进 ext 的 100.200.700）；
  /// * `12` / `14` 是 ext 500 段的两个原样回带值。
  static ({
    int code,
    String? message,
    bool exists,
    int busid,
    String fid,
    String uploadTicket,
    Uint8List? ext500a,
    int? ext500b,
  }) parseApplyUpload(Uint8List payload) {
    final top = Qq8Pb.decode(payload);
    final rsp = _msg(_msg(top, 4), 1);
    if (rsp == null) {
      return (
        code: -1,
        message: '应答缺少 [4][1]',
        exists: false,
        busid: 0,
        fid: '',
        uploadTicket: '',
        ext500a: null,
        ext500b: null,
      );
    }
    return (
      code: Qq8Pb.intAt(rsp, 1) ?? 0,
      message: Qq8Pb.textAt(rsp, 2),
      exists: (Qq8Pb.intAt(rsp, 10) ?? 0) != 0,
      busid: Qq8Pb.intAt(rsp, 6) ?? 0,
      fid: Qq8Pb.textAt(rsp, 7) ?? '',
      uploadTicket: Qq8Pb.textAt(rsp, 9) ?? '',
      ext500a: Qq8Pb.bytesAt(rsp, 12),
      ext500b: Qq8Pb.intAt(rsp, 14),
    );
  }

  /// 构造 highway 请求头里的 `ext`（参考实现 `gfs.ts:325-363`）。
  ///
  /// 是**群文件上传独有的**：图片上传的 ext 只有 300 段，群文件要多
  /// 100（路径/会话）、200（大小与哈希）、400（文件名）、500（服务端回带）。
  static Uint8List buildUploadExt({
    required int uin,
    required int gid,
    required String name,
    required int size,
    required Uint8List md5,
    required Uint8List sha1,
    required int busid,
    required String fid,
    required String uploadTicket,
    required int subid,
    Uint8List? ext500a,
    int? ext500b,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: 100,
        2: 1,
        3: 0,
        100: <int, Object?>{
          100: <int, Object?>{1: busid, 100: uin, 200: gid, 400: gid},
          200: <int, Object?>{
            100: size,
            200: md5,
            300: sha1,
            600: fid,
            700: uploadTicket,
          },
          300: <int, Object?>{
            100: 2,
            200: '$subid',
            300: 2,
            400: clientKey,
            600: 4,
          },
          400: <int, Object?>{100: name},
          if (ext500a != null || ext500b != null)
            500: <int, Object?>{
              200: <int, Object?>{
                1: ext500a == null ? null : <int, Object?>{1: 1, 2: ext500a},
                2: ?ext500b,
              },
            },
        },
        200: 1,
      });

  // ------------------------------------------------------------ 取下载地址

  /// 取下载地址请求体（`OidbSvc.0x6d6_2`）。
  static Uint8List buildDownloadBody({
    required int gid,
    required int busid,
    required String fid,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        3: <int, Object?>{
          1: gid,
          2: 2,
          3: busid,
          4: fid,
        },
      });

  /// 解下载地址应答：`[4][3]`，`4` = 主机（host 或 host:port）、`6` = 路径 token。
  static ({int code, String? message, String host, String tokenHex})
      parseDownload(Uint8List payload) {
    final top = Qq8Pb.decode(payload);
    final rsp = _msg(_msg(top, 4), 3);
    if (rsp == null) {
      return (code: -1, message: '应答缺少 [4][3]', host: '', tokenHex: '');
    }
    return (
      code: Qq8Pb.intAt(rsp, 1) ?? 0,
      message: Qq8Pb.textAt(rsp, 2),
      host: Qq8Pb.textAt(rsp, 4) ?? '',
      tokenHex: _hex(Qq8Pb.bytesAt(rsp, 6)),
    );
  }

  /// 拼出真正的下载 URL（参考实现 `gfs.ts:422`：
  /// `http://<host>/ftn_handler/<token hex>/?fname=<urlencoded name>`）。
  static String buildDownloadUrl({
    required String host,
    required String tokenHex,
    required String name,
  }) =>
      'http://$host/ftn_handler/$tokenHex/?fname=${Uri.encodeComponent(name)}';

  // ------------------------------------------------------------ 删除

  /// 删除文件请求体（`OidbSvc.0x6d6_3`）；删目录走 `OidbSvc.0x6d7_1`。
  static Uint8List buildDeleteBody({
    required int gid,
    required int busid,
    required String pid,
    required String fid,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        4: <int, Object?>{
          1: gid,
          2: 3,
          3: busid,
          4: pid,
          5: fid,
        },
      });

  /// 解删除应答：`[4][4]`。
  static ({int code, String? message}) parseDelete(Uint8List payload) {
    final rsp = _msg(_msg(Qq8Pb.decode(payload), 4), 4);
    if (rsp == null) return (code: -1, message: '应答缺少 [4][4]');
    return (code: Qq8Pb.intAt(rsp, 1) ?? 0, message: Qq8Pb.textAt(rsp, 2));
  }

  // ------------------------------------------------------------ 上传完成回执

  /// 上传完成回执（`OidbSvc.0x6d9_4`）。数据传完后必须调一次，服务端才归档。
  ///
  /// [rand] 是 4 字节随机数（按 int32 传），参考实现用 `randomBytes(4).readInt32BE()`。
  static Uint8List buildFeedBody({
    required int gid,
    required int busid,
    required String fid,
    int? rand,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        5: <int, Object?>{
          1: gid,
          2: 4,
          3: <int, Object?>{
            1: busid,
            2: fid,
            3: ?rand,
            5: 1,
          },
        },
      });

  /// 解回执应答：`[4][5]` → 里面再一层 `4` → `3` 是最终 fid。
  static ({int code, String? message, String fid}) parseFeed(Uint8List payload) {
    final outer = _msg(_msg(Qq8Pb.decode(payload), 4), 5);
    if (outer == null) return (code: -1, message: '应答缺少 [4][5]', fid: '');
    final code1 = Qq8Pb.intAt(outer, 1) ?? 0;
    if (code1 != 0) {
      return (code: code1, message: Qq8Pb.textAt(outer, 2), fid: '');
    }
    final inner = _msg(outer, 4);
    if (inner == null) return (code: -1, message: '回执缺少 [4]', fid: '');
    return (
      code: Qq8Pb.intAt(inner, 1) ?? 0,
      message: Qq8Pb.textAt(inner, 2),
      fid: Qq8Pb.textAt(inner, 3) ?? '',
    );
  }

  // ------------------------------------------- 建目录 / 删目录 / 改名 / 移动

  /// 建目录请求体（`OidbSvc.0x6d7_0`）。官方只允许在**根目录**下建，
  /// 所以字段 3 恒为 `/`（参考实现 `gfs.ts:166-179`）。
  static Uint8List buildMkdirBody({
    required int gid,
    required String name,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: <int, Object?>{
          1: gid,
          2: 0,
          3: rootPid,
          4: name,
        },
      });

  /// 解建目录应答：`[4][1]` 判码，目录属性在 `[4][1][4]`（与文件属性的布局不同）。
  static ({int code, String? message, Qq8GfsEntry? entry}) parseMkdir(
    Uint8List payload,
  ) {
    final rsp = _msg(_msg(Qq8Pb.decode(payload), 4), 1);
    if (rsp == null) return (code: -1, message: '应答缺少 [4][1]', entry: null);
    final code = Qq8Pb.intAt(rsp, 1) ?? 0;
    final message = Qq8Pb.textAt(rsp, 2);
    final bytes = Qq8Pb.bytesAt(rsp, 4);
    return (
      code: code,
      message: message,
      entry: bytes == null ? null : _dirStat(Qq8Pb.decode(bytes)),
    );
  }

  /// 删目录请求体（`OidbSvc.0x6d7_1`）。**删目录会连带删掉里面的所有文件**，
  /// 调用方必须先给用户明确的二次确认。
  static Uint8List buildDeleteDirBody({
    required int gid,
    required String fid,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        2: <int, Object?>{
          1: gid,
          2: 1,
          3: fid,
        },
      });

  /// 解删目录应答：`[4][2]`。
  static ({int code, String? message}) parseDeleteDir(Uint8List payload) =>
      _parseCode(_msg(_msg(Qq8Pb.decode(payload), 4), 2), '[4][2]');

  /// 改文件名请求体（`OidbSvc.0x6d6_4`）。
  static Uint8List buildRenameFileBody({
    required int gid,
    required int busid,
    required String fid,
    required String pid,
    required String name,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        5: <int, Object?>{
          1: gid,
          2: 4,
          3: busid,
          4: fid,
          5: pid,
          6: name,
        },
      });

  /// 解改文件名应答：`[4][5]`。
  static ({int code, String? message}) parseRenameFile(Uint8List payload) =>
      _parseCode(_msg(_msg(Qq8Pb.decode(payload), 4), 5), '[4][5]');

  /// 改目录名请求体（`OidbSvc.0x6d7_2`）。注意它和改文件名**不是**一条命令。
  static Uint8List buildRenameDirBody({
    required int gid,
    required String fid,
    required String name,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        3: <int, Object?>{
          1: gid,
          2: 2,
          3: fid,
          4: name,
        },
      });

  /// 解改目录名应答：`[4][3]`。
  static ({int code, String? message}) parseRenameDir(Uint8List payload) =>
      _parseCode(_msg(_msg(Qq8Pb.decode(payload), 4), 3), '[4][3]');

  /// 移动文件请求体（`OidbSvc.0x6d6_5`）：`5` 是原目录 pid、`6` 是目标目录 pid。
  static Uint8List buildMoveFileBody({
    required int gid,
    required int busid,
    required String fid,
    required String pid,
    required String toPid,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        6: <int, Object?>{
          1: gid,
          2: 5,
          3: busid,
          4: fid,
          5: pid,
          6: toPid,
        },
      });

  /// 解移动文件应答：`[4][6]`。
  static ({int code, String? message}) parseMoveFile(Uint8List payload) =>
      _parseCode(_msg(_msg(Qq8Pb.decode(payload), 4), 6), '[4][6]');

  /// 所有写操作的应答形状都一样（`1`=码、`2`=文案），抽出来。
  static ({int code, String? message}) _parseCode(
    Map<int, List<Object>>? rsp,
    String where,
  ) {
    if (rsp == null) return (code: -1, message: '应答缺少 $where');
    return (code: Qq8Pb.intAt(rsp, 1) ?? 0, message: Qq8Pb.textAt(rsp, 2));
  }

  // ------------------------------------------------------------ 内部

  /// 取嵌套消息（`tag` 对应的是 bytes，解成 map）。
  static Map<int, List<Object>>? _msg(Map<int, List<Object>>? m, int tag) {
    if (m == null) return null;
    final b = Qq8Pb.bytesAt(m, tag);
    return b == null ? null : Qq8Pb.decode(b);
  }

  static Qq8GfsEntry _fileStat(Map<int, List<Object>> f) {
    var fid = Qq8Pb.textAt(f, 1) ?? '';
    // 目录型 fid 在文件属性里可能带前导 '/'，参考实现会剥掉（genGfsFileStat）。
    if (fid.startsWith('/')) fid = fid.substring(1);
    return Qq8GfsEntry(
      fid: fid,
      pid: Qq8Pb.textAt(f, 16) ?? '',
      name: Qq8Pb.textAt(f, 2) ?? '',
      isDir: false,
      busid: Qq8Pb.intAt(f, 4) ?? 0,
      size: Qq8Pb.intAt(f, 5) ?? 0,
      createTime: Qq8Pb.intAt(f, 6) ?? 0,
      duration: Qq8Pb.intAt(f, 7) ?? 0,
      downloadTimes: Qq8Pb.intAt(f, 9) ?? 0,
      sha1: Qq8Pb.bytesAt(f, 10),
      md5: Qq8Pb.bytesAt(f, 12),
      uploaderUin: Qq8Pb.intAt(f, 15) ?? 0,
    );
  }

  static Qq8GfsEntry _dirStat(Map<int, List<Object>> d) => Qq8GfsEntry(
        fid: Qq8Pb.textAt(d, 1) ?? '',
        pid: Qq8Pb.textAt(d, 2) ?? '',
        name: Qq8Pb.textAt(d, 3) ?? '',
        isDir: true,
        createTime: Qq8Pb.intAt(d, 4) ?? 0,
        uploaderUin: Qq8Pb.intAt(d, 6) ?? 0,
        fileCount: Qq8Pb.intAt(d, 8) ?? 0,
      );
}

String _hex(Uint8List? b) {
  if (b == null) return '';
  final sb = StringBuffer();
  for (final x in b) {
    sb.write((x & 0xFF).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

