/// L2 协议内核：发图片（本地探图 → PicUp 申请 → highway 传数据 → 元素回填）
///
/// ## 四步链路（参考实现 `oicq/lib/{message/image.ts, internal/contactable.ts,
/// internal/highway.ts}`，官方 highway 侧另有 APK 反编译对照）
///
/// ```text
/// ① 本地   Qq8ImageProbe：md5 / size / 宽高 / 类型（jpg=1000 png=1001 webp=1002
///          bmp=1005 gif=2000 face=4）
/// ② 主 SSO OffPicUp（私聊）/ GroupPicUp（群）：拿 fid / ticket / 图床 ip:port，
///          以及"服务端已有这张图"标志 —— 命中就不必传数据
/// ③ 另开 TCP  PicUp.DataUp：分片（1 MiB）上传，每片带片 md5 + 整文件 md5
/// ④ 回填   私聊写 NotOnlineImage 的 3/10，群写 CustomFace 的 7，再 PbSendMsg
/// ```
///
/// ## 证据等级（照 AGENTS 的规矩标清楚）
///
/// | 部分 | 出处 | 等级 |
/// |---|---|---|
/// | highway 帧 `[0x28][头长u32][体长u32][pb头][数据][0x29]` | 官方 `TcpProtocolDataCodec.encodeC2SData`（jadx-main）+ oicq `highway.ts` | **双源一致** |
/// | highway 头 `DataHighwayHead` / `SegHead` 字段号 | 官方 `CSDataHighwayHead.java`（jadx-main）+ oicq 同布局 | **双源一致** |
/// | highway 回包 `RspDataHighwayHead` 字段号 | 官方 `CSDataHighwayHead.java` | 官方 |
/// | PicUp 申请 / 回执的字段号 | oicq `contactable.ts`（社区实测可用） | **单源**——官方 transfile 模块不在我们的反编译集合里 |
/// | 图片元素（Elem 4/8）字段号 | 官方 pb（接收侧解析已核）+ oicq `image.ts` 同布局 | **双源一致** |
///
/// 单源那部分真机验证时以服务端是否接受为准；失败先怀疑它们。
///
/// 本文件是纯 Dart（除了 [Qq8Highway.upload] 用 `dart:io` 的 Socket）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../crypto/digest.dart';
import 'qq8_pb.dart';

/// 图片类型码（oicq `image.ts` 的 `TYPE` 表）。
abstract final class Qq8ImageType {
  static const int jpg = 1000;
  static const int png = 1001;
  static const int webp = 1002;
  static const int bmp = 1005;
  static const int gif = 2000;
  static const int face = 4;
}

/// 类型码 → 扩展名（oicq `image.ts` 的 `EXT` 表）。
String qq8ImageExt(int? type) => switch (type) {
      3 => 'png',
      4 => 'face',
      1000 => 'jpg',
      1001 => 'png',
      1002 => 'webp',
      1003 => 'jpg',
      1005 => 'bmp',
      2000 => 'gif',
      2001 => 'png',
      _ => 'jpg',
    };

/// `{md5}{size}-{宽}-{高}.{扩展名}`（oicq `buildImageFileParam`）。
String qq8BuildImageFileParam({
  required String md5,
  int size = 0,
  int width = 0,
  int height = 0,
  int? type,
}) =>
    '$md5$size-$width-$height.${qq8ImageExt(type)}';

/// 图片探测/上传的错误（消息直接给人看）。
class Qq8ImageException implements Exception {
  final String message;
  Qq8ImageException(this.message);

  @override
  String toString() => 'Qq8ImageException: $message';
}

/// 本地图片的属性。
class Qq8ImageInfo {
  /// md5（hex，小写 32 位）。
  final String md5Hex;

  /// md5 原始 16 字节（PicUp 请求里两种都要）。
  final Uint8List md5;

  final int size;
  final int width;
  final int height;

  /// [Qq8ImageType] 之一。
  final int type;

  /// 原图标记（0/1；我们发原图）。
  final int origin;

  const Qq8ImageInfo({
    required this.md5Hex,
    required this.md5,
    required this.size,
    required this.width,
    required this.height,
    required this.type,
    this.origin = 1,
  });

  /// `{md5}{size}-{宽}-{高}.{ext}` —— 会话层拿这个当"图片定位串"。
  String get fileParam => qq8BuildImageFileParam(
        md5: md5Hex,
        size: size,
        width: width,
        height: height,
        type: type,
      );

  @override
  String toString() =>
      'Qq8ImageInfo(${width}x$height, $size B, type=$type, md5=$md5Hex)';
}

/// 本地图片探测：只读文件头取宽高，整块算 md5 与长度。
///
/// 支持 PNG / JPEG / GIF / BMP / WebP（官方与参考实现支持的就是这几类；
/// 认不出来**显式拒绝**，不按 jpg 兜底硬发）。
abstract final class Qq8ImageProbe {
  /// 上传体积上限（oicq `MAX_UPLOAD_SIZE` = 30 MiB）。
  static const int maxUploadSize = 31457280;

  /// 从内存字节探测。
  static Qq8ImageInfo probe(Uint8List bytes) {
    if (bytes.isEmpty) throw Qq8ImageException('空文件，不是图片');
    if (bytes.length > maxUploadSize) {
      throw Qq8ImageException(
          '图片 ${bytes.length} 字节，超过上限 $maxUploadSize（30 MiB）');
    }
    final dim = _dimensions(bytes);
    if (dim == null) {
      throw Qq8ImageException(
          '认不出图片格式（只看头部 ${bytes.length < 32 ? bytes.length : 32} 字节）：'
          '支持 PNG / JPEG / GIF / BMP / WebP');
    }
    final md5 = md5Bytes(bytes);
    return Qq8ImageInfo(
      md5Hex: _hex(md5),
      md5: md5,
      size: bytes.length,
      width: dim.$1,
      height: dim.$2,
      type: dim.$3,
    );
  }

  /// 从本地文件探测。
  static Future<Qq8ImageInfo> probeFile(String path) async {
    final f = File(path);
    if (!f.existsSync()) throw Qq8ImageException('文件不存在：$path');
    final len = f.lengthSync();
    if (len <= 0) throw Qq8ImageException('空文件：$path');
    if (len > maxUploadSize) {
      throw Qq8ImageException('图片 $len 字节，超过上限 $maxUploadSize（30 MiB）');
    }
    return probe(await f.readAsBytes());
  }

  /// 返回 `(宽, 高, 类型码)`；认不出来返回 null。
  static (int, int, int)? _dimensions(Uint8List b) {
    int u16be(int o) => (b[o] << 8) | b[o + 1];
    int u32be(int o) =>
        ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) &
        0xFFFFFFFF;
    int u16le(int o) => b[o] | (b[o + 1] << 8);
    int u32le(int o) =>
        (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) &
        0xFFFFFFFF;

    // PNG：89 50 4E 47 0D 0A 1A 0A，IHDR 的宽高在 16/20
    if (b.length >= 24 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      return (u32be(16), u32be(20), Qq8ImageType.png);
    }

    // JPEG：FF D8，往后扫 SOFn（0xC0-0xCF，跳过 C4/C8/CC）
    if (b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = b[i + 1];
        if (marker == 0xFF) {
          i++;
          continue;
        }
        if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7)) {
          i += 2; // 无长度字段的标记
          continue;
        }
        final len = u16be(i + 2);
        if (len < 2) return null;
        final isSof = marker >= 0xC0 &&
            marker <= 0xCF &&
            marker != 0xC4 &&
            marker != 0xC8 &&
            marker != 0xCC;
        if (isSof) {
          if (i + 9 >= b.length) return null;
          return (u16be(i + 7), u16be(i + 5), Qq8ImageType.jpg);
        }
        i += 2 + len;
      }
      return null;
    }

    // GIF：GIF87a / GIF89a，宽高是小端 u16
    if (b.length >= 10 &&
        b[0] == 0x47 &&
        b[1] == 0x49 &&
        b[2] == 0x46) {
      return (u16le(6), u16le(8), Qq8ImageType.gif);
    }

    // BMP：BM，宽高是**有符号**小端 i32（高为负表示自上而下）
    if (b.length >= 26 && b[0] == 0x42 && b[1] == 0x4D) {
      final w = _i32le(b, 18);
      final h = _i32le(b, 22);
      return (w.abs(), h.abs(), Qq8ImageType.bmp);
    }

    // WebP：RIFF....WEBP，再分 VP8 / VP8L / VP8X
    if (b.length >= 30 &&
        b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      final fourcc = String.fromCharCodes(b.sublist(12, 16));
      switch (fourcc) {
        case 'VP8 ':
          // 帧头：3 字节 tag + 同步码 9D 01 2A，宽高各 u16le（低 14 位）
          if (b.length < 30 || b[23] != 0x9D || b[24] != 0x01 || b[25] != 0x2A) {
            return null;
          }
          return (u16le(26) & 0x3FFF, u16le(28) & 0x3FFF, Qq8ImageType.webp);
        case 'VP8L':
          // 1 字节签名 2F，然后 14+14 位宽高（各减 1），小端位打包
          if (b.length < 25 || b[20] != 0x2F) return null;
          final bits = u32le(21);
          final w = (bits & 0x3FFF) + 1;
          final h = ((bits >> 14) & 0x3FFF) + 1;
          return (w, h, Qq8ImageType.webp);
        case 'VP8X':
          if (b.length < 30) return null;
          final w = (b[24] | (b[25] << 8) | (b[26] << 16)) + 1;
          final h = (b[27] | (b[28] << 8) | (b[29] << 16)) + 1;
          return (w, h, Qq8ImageType.webp);
      }
      return null;
    }
    return null;
  }

  static int _i32le(Uint8List b, int o) {
    final v = (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24));
    return v & 0x80000000 != 0 ? v - 0x100000000 : v;
  }
}

/// 一次 PicUp 申请的回执（每张图一条）。
class Qq8PicUpReply {
  /// 服务端结果码（0 = 可以传 / 已存在）。
  final int code;

  /// 失败原因（服务端文案；成功时为空）。
  final String message;

  /// 文件 id（私聊图的下载路径 / 群图的 file_id）。
  final String fid;

  /// 服务端已有这张图 ⇒ **不必上传数据**。
  final bool alreadyExists;

  /// 图床地址（要传数据时用）。
  final String? host;
  final int? port;

  /// 上传凭证。
  final Uint8List ticket;

  const Qq8PicUpReply({
    required this.code,
    required this.message,
    required this.fid,
    required this.alreadyExists,
    required this.ticket,
    this.host,
    this.port,
  });

  bool get ok => code == 0 && fid.isNotEmpty;

  @override
  String toString() => 'Qq8PicUpReply(code=$code, fid=$fid, '
      'exists=$alreadyExists, $host:$port, ticket=${ticket.length}B)';
}

/// PicUp 申请（主 SSO）与 highway 数据帧的构造/解析。
abstract final class Qq8ImageUp {
  /// 私聊图申请的命令字。
  static const String cmdOffPicUp = 'LongConn.OffPicUp';

  /// 群图申请的命令字。
  static const String cmdGroupPicUp = 'ImgStore.GroupPicUp';

  /// 私聊图申请体（oicq `_offPicUp`；字段号单源，见文件头）。
  static Uint8List buildOffPicUpBody({
    required int uin,
    required int uid,
    required List<Qq8ImageInfo> images,
    required int apkVersion,
  }) {
    final req = <Uint8List>[];
    for (final img in images) {
      req.add(Qq8Pb.encode(<int, Object?>{
        1: uin,
        2: uid,
        3: 0,
        4: img.md5,
        5: img.size,
        6: img.md5Hex,
        7: 5,
        8: 9,
        9: 0,
        10: 0,
        11: 0, // retry
        12: 1, // bu
        13: img.origin,
        14: img.width,
        15: img.height,
        16: img.type,
        17: apkVersion,
        22: 0,
      }));
    }
    return Qq8Pb.encode(<int, Object?>{1: 1, 2: req});
  }

  /// 群图申请体（oicq `_groupPicUp`）。
  static Uint8List buildGroupPicUpBody({
    required int gid,
    required int uin,
    required List<Qq8ImageInfo> images,
    required int apkVersion,
  }) {
    final req = <Uint8List>[];
    for (final img in images) {
      req.add(Qq8Pb.encode(<int, Object?>{
        1: gid,
        2: uin,
        3: 0,
        4: img.md5,
        5: img.size,
        6: img.md5Hex,
        7: 5,
        8: 9,
        9: 1, // bu
        10: img.width,
        11: img.height,
        12: img.type,
        13: apkVersion,
        14: 0,
        15: 1052,
        16: img.origin,
        18: 0,
        19: 0,
      }));
    }
    return Qq8Pb.encode(<int, Object?>{1: 3, 2: 1, 3: req});
  }

  /// 私聊图申请回执：`{2: [每条]}`，条目字段 = `3 码 / 4 文案 / 5 已存在 /
  /// 7 ip / 8 port / 9 ticket / 10 fid`（oicq `_uploadImage` 的 j=1 分支）。
  static List<Qq8PicUpReply> parseOffPicUpResponse(Uint8List payload) =>
      _parseItems(payload, topTag: 2, offset: 1);

  /// 群图申请回执：`{3: [每条]}`，条目字段 = `2 码 / 3 文案 / 4 已存在 /
  /// 6 ip / 7 port / 8 ticket / 9 fid`（oicq `_uploadImage` 的 j=0 分支）。
  static List<Qq8PicUpReply> parseGroupPicUpResponse(Uint8List payload) =>
      _parseItems(payload, topTag: 3, offset: 0);

  static List<Qq8PicUpReply> _parseItems(
    Uint8List payload, {
    required int topTag,
    required int offset,
  }) {
    final top = Qq8Pb.decode(payload);
    final raw = top[topTag];
    if (raw == null || raw.isEmpty) return const <Qq8PicUpReply>[];
    final out = <Qq8PicUpReply>[];
    for (final item in raw) {
      if (item is! Uint8List) continue;
      final m = Qq8Pb.decode(item);
      final code = Qq8Pb.intAt(m, 2 + offset) ?? -1;
      final message = Qq8Pb.textAt(m, 3 + offset) ?? '';
      final fid = Qq8Pb.textAt(m, 9 + offset) ?? '';
      final exists = (Qq8Pb.intAt(m, 4 + offset) ?? 0) != 0;
      final ipRaw = m[6 + offset];
      final ip = ipRaw == null || ipRaw.isEmpty ? null : ipRaw.first;
      final port = Qq8Pb.intAt(m, 7 + offset);
      final ticket = Qq8Pb.bytesAt(m, 8 + offset) ?? Uint8List(0);
      out.add(Qq8PicUpReply(
        code: code,
        message: message,
        fid: fid,
        alreadyExists: exists,
        host: ip is int ? qq8Int32IpToStr(ip) : (ip is String ? ip : null),
        port: port,
        ticket: ticket,
      ));
    }
    return out;
  }
}

/// 服务端给的 ip 可能是 u32（网络字节序按低字节在前拆成点分十进制）。
///
/// 出处：oicq `common.ts` 的 `int32ip2str`：
/// `${ip & 0xFF}.${(ip>>8)&0xFF}.${(ip>>16)&0xFF}.${(ip>>24)&0xFF}`。
String qq8Int32IpToStr(int ip) {
  final v = ip & 0xFFFFFFFF;
  return '${v & 0xFF}.${(v >> 8) & 0xFF}.${(v >> 16) & 0xFF}.${(v >> 24) & 0xFF}';
}

/// highway 回包（每片一条）。
class Qq8HighwayAck {
  /// 0 = 这一片收好了。
  final int errorCode;

  /// 服务端确认的偏移/长度（用来算进度）。
  final int offset;
  final int dataLength;

  /// 服务端附加信息（`bytes_rsp_extendinfo`，可能是给下一次 request 用的）。
  final Uint8List? extendInfo;

  const Qq8HighwayAck({
    required this.errorCode,
    required this.offset,
    required this.dataLength,
    this.extendInfo,
  });

  @override
  String toString() => 'Qq8HighwayAck(code=$errorCode, '
      'offset=$offset, len=$dataLength)';
}

/// highway（`PicUp.DataUp`）上传：帧构造 + 解析 + 一条 TCP 传完。
///
/// 帧格式官方出处：`com/tencent/mobileqq/highway/codec/TcpProtocolDataCodec.java`
/// 的 `encodeC2SData`：
/// ```text
///   [0]=40(STX)  [1..4]=头长 u32be  [5..8]=体长 u32be  [9..]=pb 头  [..]=数据  [last]=41(ETX)
/// ```
/// 头 pb（`CSDataHighwayHead`）：`msg_basehead`(1) + `msg_seghead`(2)。
abstract final class Qq8Highway {
  static const String cmd = 'PicUp.DataUp';
  static const int stx = 40;
  static const int etx = 41;

  /// 单包上限（官方 `TcpProtocolDataCodec.MAX_PKG_SIZE` = 1 MiB）。
  static const int maxChunk = 1048576;

  /// 固定标志位（官方 `DataFlag.FLAG_NORMAL` / `HwRequest.dataFlag` = 4096）。
  static const int dataFlag = 4096;

  /// 私聊图业务号（oicq `CmdID.DmImage`）。
  static const int cmdIdDmImage = 1;

  /// 群图业务号（oicq `CmdID.GroupImage`）。
  static const int cmdIdGroupImage = 2;

  /// 构造一片的上传帧。
  static Uint8List buildFrame({
    required int seq,
    required String uin,
    required int appid,
    required int buCmdId,
    required Uint8List ticket,
    required Uint8List fileMd5,
    required int fileSize,
    required int offset,
    required Uint8List chunk,
  }) {
    final head = Qq8Pb.encode(<int, Object?>{
      1: <int, Object?>{
        1: 1, // version（非 openup 通道；官方 isOpenUpEnable=false → 1）
        2: uin, // bytes_uin（十进制字符串）
        3: cmd, // bytes_command
        4: seq & 0xFFFFFFFF, // uint32_seq
        // 5 = uint32_retry_times（首传 0，不写）
        6: appid, // uint32_appid（oicq 用档案的 subid）
        7: dataFlag, // uint32_dataflag
        8: buCmdId, // uint32_command_id
      },
      2: <int, Object?>{
        2: fileSize, // uint64_filesize
        3: offset, // uint64_dataoffset
        4: chunk.length, // uint32_datalength
        6: ticket, // bytes_serviceticket
        8: md5Bytes(chunk), // bytes_md5（本片）
        9: fileMd5, // bytes_file_md5（整文件）
      },
    });
    final out = Uint8List(9 + head.length + chunk.length + 1);
    out[0] = stx;
    _u32be(out, 1, head.length);
    _u32be(out, 5, chunk.length);
    out.setRange(9, 9 + head.length, head);
    out.setRange(9 + head.length, out.length - 1, chunk);
    out[out.length - 1] = etx;
    return out;
  }

  /// 解析一条服务端回帧（`RspDataHighwayHead`：1 基础头 / 2 分段头 /
  /// 3 error_code / 7 扩展信息）。
  static Qq8HighwayAck parseAck(Uint8List frame) {
    if (frame.isEmpty || frame[0] != stx) {
      throw Qq8ImageException('highway 回帧没有 STX（${frame.isEmpty ? 0 : frame[0]}）');
    }
    if (frame.length < 10) throw Qq8ImageException('highway 回帧过短（${frame.length}）');
    final headLen = _readU32be(frame, 1);
    if (9 + headLen > frame.length) {
      throw Qq8ImageException('highway 回帧头长 $headLen 超出帧长 ${frame.length}');
    }
    final head = Qq8Pb.decode(frame.sublist(9, 9 + headLen));
    final code = Qq8Pb.intAt(head, 3) ?? 0;
    final seg = _nested(head[2]);
    final offset = seg == null ? 0 : (Qq8Pb.intAt(seg, 3) ?? 0);
    final len = seg == null ? 0 : (Qq8Pb.intAt(seg, 4) ?? 0);
    return Qq8HighwayAck(
      errorCode: code,
      offset: offset,
      dataLength: len,
      extendInfo: Qq8Pb.bytesAt(head, 7),
    );
  }

  /// 把一个文件传完（分片 + 等回执）。
  ///
  /// [onProgress] 收到服务端确认时回调 `0.0..1.0`。
  static Future<void> upload({
    required String host,
    required int port,
    required String uin,
    required int appid,
    required int buCmdId,
    required Uint8List ticket,
    required Uint8List fileMd5,
    required Uint8List data,
    Duration timeout = const Duration(seconds: 60),
    Duration connectTimeout = const Duration(seconds: 10),
    void Function(double progress)? onProgress,
  }) async {
    final fileSize = data.length;
    if (fileSize <= 0) throw Qq8ImageException('要上传的数据是空的');
    Socket socket;
    try {
      socket = await Socket.connect(host, port, timeout: connectTimeout);
    } on Object catch (e) {
      throw Qq8ImageException('连图床 $host:$port 失败：$e');
    }
    socket.setOption(SocketOption.tcpNoDelay, true);

    final done = Completer<void>();
    final buf = BytesBuilder(copy: false);

    void handleAck(Qq8HighwayAck ack) {
      if (ack.errorCode != 0) {
        if (!done.isCompleted) {
          done.completeError(Qq8ImageException(
              '图床拒绝（highway code=${ack.errorCode}）'));
        }
        return;
      }
      final sent = ack.offset + ack.dataLength;
      if (fileSize > 0) {
        onProgress?.call((sent / fileSize).clamp(0.0, 1.0));
      }
      if (sent >= fileSize && !done.isCompleted) done.complete();
    }

    void feed(Uint8List chunk) {
      buf.add(chunk);
      final acc = buf.takeBytes();
      var pos = 0;
      while (acc.length - pos >= 10) {
        if (acc[pos] != stx) {
          pos++;
          continue;
        }
        final headLen = _readU32be(acc, pos + 1);
        final bodyLen = _readU32be(acc, pos + 5);
        final total = 9 + headLen + bodyLen + 1;
        if (acc.length - pos < total) break;
        handleAck(parseAck(acc.sublist(pos, pos + total)));
        pos += total;
      }
      // 半包（含"第一个字节就不是完整帧"的情形）**必须留回缓冲**：
      // 曾经写成 `if (pos > 0)`，结果一帧都没解析出来时整段数据被丢掉，
      // 服务端下面的回包永远对不齐（自测里假图床就是这么炸的）。
      if (pos < acc.length) {
        buf.add(Uint8List.sublistView(acc, pos));
      }
    }

    final sub = socket.listen(
      feed,
      onError: (Object e) {
        if (!done.isCompleted) {
          done.completeError(Qq8ImageException('图床连接出错：$e'));
        }
      },
      onDone: () {
        if (!done.isCompleted) {
          done.completeError(Qq8ImageException('图床连接被关闭（上传未确认完成）'));
        }
      },
    );

    var seq = 1;
    var offset = 0;
    try {
      while (offset < fileSize) {
        final end = (offset + maxChunk < fileSize) ? offset + maxChunk : fileSize;
        final chunk = Uint8List.sublistView(data, offset, end);
        socket.add(buildFrame(
          seq: seq++,
          uin: uin,
          appid: appid,
          buCmdId: buCmdId,
          ticket: ticket,
          fileMd5: fileMd5,
          fileSize: fileSize,
          offset: offset,
          chunk: chunk,
        ));
        offset = end;
      }
      await socket.flush();
      await done.future.timeout(timeout);
    } finally {
      await sub.cancel();
      socket.destroy();
    }
  }

  static int _readU32be(Uint8List b, int o) =>
      ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) &
      0xFFFFFFFF;

  static void _u32be(Uint8List b, int o, int v) {
    b[o] = (v >> 24) & 0xFF;
    b[o + 1] = (v >> 16) & 0xFF;
    b[o + 2] = (v >> 8) & 0xFF;
    b[o + 3] = v & 0xFF;
  }
}

/// 发送侧的图片元素（pb 直接进 `PbSendMsg` 的 elems）。
///
/// 返回的是**整个 Elem**（外层就是 `{4: …}` / `{8: …}`），与
/// `Qq8Msg.textElem`（`{1: …}`）同构，可以直接塞进 `sendC2c/sendGroup` 的
/// `elems` 列表。字段号与接收侧解析（`qq8_elem.dart`）同源，且与 oicq
/// `image.ts` 的 `setProto` 一致（双源）；`fid` 由 [Qq8ImageUp] 回执回填。
///
/// ⚠️ 类名是复数：`Qq8ImageElem` 这个名字已经被 `qq8_elem.dart` 的**模型类**
/// 占了（那个是解析出来的元素，这个是构造器），撞名会让类型判断静默解析到
/// 另一个类上——踩过一次，别再改回去。
abstract final class Qq8ImageElems {
  /// 私聊图：`Elem 4` = `NotOnlineImage`。
  ///
  /// 官方语义：字段 3 与 10 都是 fid（下载路径 / res_id）；字段 1 是 md5 hex
  /// 字符串、7 是 md5 原始字节（两种存法官方都有，同时给最稳）。
  static Uint8List dm({
    required Qq8ImageInfo info,
    required String fid,
    bool asFace = false,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        4: <int, Object?>{
          1: info.md5Hex,
          2: info.size,
          3: fid,
          5: info.type,
          7: info.md5,
          8: info.height,
          9: info.width,
          10: fid,
          13: info.origin,
          16: info.type == Qq8ImageType.face ? 5 : 0,
          24: 0,
          25: 0,
          29: <int, Object?>{1: asFace ? 1 : 0},
        },
      });

  /// 群图：`Elem 8` = `CustomFace`。
  static Uint8List group({
    required Qq8ImageInfo info,
    required String fid,
    bool asFace = false,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        8: <int, Object?>{
          2: '${info.md5Hex}.gif',
          7: fid,
          8: 0,
          9: 0,
          10: 66,
          12: 1,
          13: info.md5,
          20: info.type,
          22: info.width,
          23: info.height,
          24: 200,
          25: info.size,
          26: info.origin,
          29: 0,
          30: 0,
          34: <int, Object?>{1: asFace ? 1 : 0},
        },
      });
}

/// `Map<int, List<Object>>` 里取嵌套消息（第一个是 Uint8List 的值）。
Map<int, List<Object>>? _nested(List<Object>? v) {
  if (v == null || v.isEmpty) return null;
  final first = v.first;
  if (first is Uint8List) return Qq8Pb.decode(first);
  return null;
}

String _hex(List<int> b) =>
    b.map((x) => (x & 0xFF).toRadixString(16).padLeft(2, '0')).join();
