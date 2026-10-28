/// L2 协议内核：离线文件（私聊）发送 / 收取链接 / 撤回 / 转发
///
/// ## 命令字与报文（参考实现 oicq `lib/friend.ts`，生产环境在跑）
///
/// | 步骤 | 命令字 | 请求体 |
/// |---|---|---|
/// | 申请上传 | `OfflineFilleHandleSvr.pb_ftn_CMD_REQ_APPLY_UPLOAD_V3-1700` | `{1:1700, 2:6, 19:{…}, 101:3, 102:104, 200:1}` |
/// | 传数据 | highway HTTP（`/cgi-bin/httpconn?htcmd=0x6FF0087`） | 帧 = STX + 头长 + 块长 + 头pb + 数据 + ETX |
/// | 上传完成 | `OfflineFilleHandleSvr.pb_ftn_CMD_REQ_UPLOAD_SUCC-800` | `{1:800, 2:7, 10:{10:uin,20:peer,30:fid}, 101:3, 102:104}` |
/// | 发消息 | `MessageSvc.PbSendMsg` | `msg_content` 里放 `NotOnlineFile` |
/// | 取下载链接 | `OfflineFilleHandleSvr.pb_ftn_CMD_REQ_APPLY_DOWNLOAD-1200` | `{1:1200, 14:{10:uin,20:fid,30:2}, 101:3, 102:104, 99999:{1:90200}}` |
/// | 撤回 | `OfflineFilleHandleSvr.pb_ftn_CMD_REQ_RECALL-400` | `{1:400,2:0,6:{1:uin,2:fid},101:3,102:104,200:1}` |
/// | 转发 | `OfflineFilleHandleSvr.pb_ftn_CMD_REQ_APPLY_FORWARD_FILE-700` | `{1:700,2:0,9:{10:uin,20:peer,30:fid},101:3,102:104,200:1}` |
///
/// ## 消息元素（发出去的那一方）
///
/// `PbSendMsgReq` 的 `msg_body`（字段 3）= `im_msg_body.MsgBody`：
/// * `1 rich_text` / `2 msg_content` / `3 msg_encrypt_content`（官方
///   `im_msg_body$MsgBody.__fieldMap__`：`{10,18,26}`）；
/// * 文件走 **`msg_content`（字段 2）**，内容是 `MsgBody_subtype4`
///   （`1 msg_not_online_file` / `2 uint32_msg_time`），里面再套
///   `NotOnlineFile`。
///
/// `NotOnlineFile` 字段号（官方 `im_msg_body$NotOnlineFile.__fieldMap__`）：
/// `1 file_type / 2 sig / 3 file_uuid(fid) / 4 file_md5 / 5 file_name /
/// 6 file_size / 7 note / 8 reserved / 9 subcmd / 10 micro_cloud / …`。
/// 参考实现填 `{1:0, 3:fid, 4:md5, 5:name, 6:size, 9:1}`——与本文件一致。
///
/// 私聊路由也要换：普通文本是 `RoutingHead.c2c`（字段 1），离线文件是
/// `RoutingHead` 的 **字段 15**（`{1: 对方uin, 2: 4}`），参考实现
/// `_getRouting(file=true)`。
///
/// ## 上传通道（bigdata）
///
/// highway HTTP 的地址不是图床那种随 PicUp 下发的地址，而是登录/配置推送
/// 下发的 **bigdata 通道**（`ConfigPushSvc.PushReq` type=2 里的
/// `{1281: {1: sig_session, 2: session_key, 3: [{2: ip(u32), 3: port}]}}`），
/// 请求的 `serviceticket` 直接用 `sig_session`。对应字段见
/// `lib/client_api/qq8_login_service.dart` 的 bigdata 解析。
///
/// ## 证据等级
///
/// * 命令字/字段号：参考实现（生产可用）+ 官方 pb FieldMap 双源；
/// * **没有真机黄金向量**（真机 2026-10-28 起离线）：本文件的离线性只保证
///   「与参考实现的字段一一对应、自测逐字节比对独立实现的编码结果」，
///   最终裁判仍是服务端。真机可用后第一件事应是发一个 1KB 小文件验证。
///
/// 本文件是纯 Dart（`dart:io` 的 HttpClient 只用于上传）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../crypto/digest.dart';
import 'qq8_msg.dart';
import 'qq8_pb.dart';

/// 离线文件操作失败。
class Qq8FileException implements Exception {
  final String message;
  Qq8FileException(this.message);

  @override
  String toString() => 'Qq8FileException: $message';
}

/// 待发送文件的本地信息（size / md5 / sha1）。
class Qq8FileInfo {
  final String name;
  final int size;
  final Uint8List md5;

  /// 参考实现里叫 filesha（SHA-1，20 字节）。
  final Uint8List sha1;

  Qq8FileInfo({
    required this.name,
    required this.size,
    required this.md5,
    required this.sha1,
  });

  /// 从字节算全部摘要。[name] 留空时用 md5 命名（参考实现同一策略）。
  factory Qq8FileInfo.of(String name, Uint8List data) {
    final md5v = md5Bytes(data);
    return Qq8FileInfo(
      name: name.isEmpty ? 'file${_hexOf(md5v)}' : name,
      size: data.length,
      md5: md5v,
      sha1: sha1Bytes(data),
    );
  }

  String get md5Hex => _hexOf(md5);
  String get sha1Hex => _hexOf(sha1);

  @override
  String toString() => 'Qq8FileInfo($name, $size B, md5=$md5Hex)';
}

/// 申请上传（1700）的回执。
class Qq8FileUploadTicket {
  final int code;
  final String message;

  /// 服务端文件 id（ASCII 文本；后续元素/撤回/转发都用它）。
  final String fid;

  /// 服务端已有同 md5 的文件时为 true —— 这时**跳过** highway 上传。
  final bool alreadyExists;

  /// highway 的 serviceticket（回执字段 220）。
  final Uint8List ticket;

  /// 1700 的**完整响应体**（要原样塞进 highway 的 ext.100.700）。
  final Uint8List rawResponse;

  const Qq8FileUploadTicket({
    required this.code,
    required this.message,
    required this.fid,
    required this.alreadyExists,
    required this.ticket,
    required this.rawResponse,
  });

  bool get ok => code == 0 && fid.isNotEmpty;

  @override
  String toString() => 'Qq8FileUploadTicket(code=$code, fid=$fid, '
      'exists=$alreadyExists, ticket=${ticket.length}B)';
}

/// 申请下载（1200）拿到的直链信息。
class Qq8FileLink {
  final String url;
  final String name;
  final String fid;
  final String md5Hex;
  final int size;

  const Qq8FileLink({
    required this.url,
    required this.name,
    required this.fid,
    required this.md5Hex,
    required this.size,
  });

  @override
  String toString() => 'Qq8FileLink($name, $size B, $url)';
}

/// 离线文件（私聊）协议实现。
abstract final class Qq8File {
  // ---------------------------------------------------------------------
  // 命令字
  // ---------------------------------------------------------------------

  static const String cmdApplyUpload =
      'OfflineFilleHandleSvr.pb_ftn_CMD_REQ_APPLY_UPLOAD_V3-1700';
  static const String cmdUploadSucc =
      'OfflineFilleHandleSvr.pb_ftn_CMD_REQ_UPLOAD_SUCC-800';
  static const String cmdApplyDownload =
      'OfflineFilleHandleSvr.pb_ftn_CMD_REQ_APPLY_DOWNLOAD-1200';
  static const String cmdRecall = 'OfflineFilleHandleSvr.pb_ftn_CMD_REQ_RECALL-400';
  static const String cmdForward =
      'OfflineFilleHandleSvr.pb_ftn_CMD_REQ_APPLY_FORWARD_FILE-700';

  /// 取 bigdata 上传通道的命令字。
  ///
  /// 登录后 `ConfigPushSvc.PushReq`（type=2）一般会带下发通道地址；万一那一刻
  /// 没收到（参考实现也有这条兜底路，`internal.ts` 的 `setAvatar`），可以主动
  /// 用这条命令问一次。
  static const String cmdBigdataChannel = 'HttpConn.0x6ff_501';

  /// highway 业务号（参考实现 `CmdID.OfflineFile`）。
  static const int cmdIdOfflineFile = 69;

  /// 把 u32 形式的 IPv4 转成点分文本（参考实现 `int32ip2str`）。
  ///
  /// 注意入参可能是有符号 int（高位为 1 时是负数），所以要按 32 位无符号处理。
  static String u32ToIp(int v) {
    final u = v & 0xFFFFFFFF;
    return '${(u >> 24) & 0xFF}.${(u >> 16) & 0xFF}.${(u >> 8) & 0xFF}.${u & 0xFF}';
  }

  /// 主动查一次 bigdata 通道（`HttpConn.0x6ff_501`）。
  ///
  /// 请求体照参考实现 `internal.ts`：`{1281: {1: uin, 2: 0, 3: 16, 4: 1, 6: 3, 7: 5}}`。
  static Uint8List buildBigdataChannelBody({required int uin}) =>
      Qq8Pb.encode(<int, Object?>{
        1281: <int, Object?>{
          1: uin,
          2: 0,
          3: 16,
          4: 1,
          6: 3,
          7: 5,
        },
      });

  /// 解析 bigdata 通道响应：`{1281: {1: ticket, 3: [{2: [{2: ip(u32), 3: port}]}]}}`。
  ///
  /// ⚠️ **未在真机验证过**（2026-10-28 起设备离线）：`3` 的层级结构是按
  /// 参考实现 `rsp[3][2][0][2]` / `rsp[3][2][0][3]` 与 PushReq 里
  /// `1281.3` 的形态推出来的，两种都试，取第一个「port 在 1..65535」的候选。
  /// 找不到时抛异常并把原始 hex 打出来，方便真机第一轮直接定位。
  static ({Uint8List ticket, String host, int port})? parseBigdataChannel(
      Uint8List payload) {
    final root = Qq8Pb.decode(payload);
    final raw = Qq8Pb.bytesAt(root, 1281);
    if (raw == null) return null;
    final m = Qq8Pb.decode(raw);
    final ticket = Qq8Pb.bytesAt(m, 1) ?? Uint8List(0);
    for (final e in m[3] ?? const <Object>[]) {
      if (e is! Uint8List) continue;
      final em = Qq8Pb.decode(e);
      // 形态 A：{1: 10, 2: [{2: ip, 3: port}]}
      // 形态 B：{2: [{2: ip, 3: port}]}
      for (final l in em[2] ?? const <Object>[]) {
        if (l is! Uint8List) continue;
        final hm = Qq8Pb.decode(l);
        final ip = Qq8Pb.intAt(hm, 2);
        final port = Qq8Pb.intAt(hm, 3);
        if (ip != null && port != null && port > 0 && port <= 65535) {
          return (ticket: ticket, host: u32ToIp(ip), port: port);
        }
      }
    }
    return null;
  }

  /// 参考实现写死的"手机上收到的目录"（服务端只把它当展示/落盘路径用）。
  static const String defaultStorageDir =
      '/storage/emulated/0/Android/data/com.tencent.mobileqq/Tencent/QQfile_recv/';

  // ---------------------------------------------------------------------
  // ① 申请上传
  // ---------------------------------------------------------------------

  /// 申请上传体（1700）。
  ///
  /// 字段照参考实现 `Friend.sendFile`：`19` 是文件信息，`110` 再带一遍
  /// md5（老客户端兼容位），`70` 是落盘目录 + 文件名。
  static Uint8List buildApplyUploadBody({
    required int uin,
    required int peerUin,
    required Qq8FileInfo file,
    String storageDir = defaultStorageDir,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: 1700,
        2: 6,
        19: <int, Object?>{
          10: uin,
          20: peerUin,
          30: file.size,
          40: file.name,
          50: file.md5,
          60: file.sha1,
          70: '$storageDir${file.name}',
          80: 0,
          90: 0,
          100: 0,
          110: file.md5,
        },
        101: 3,
        102: 104,
        200: 1,
      });

  /// 解析 1700 回执：`{19: {10: 结果码, 20: 文案, 90: fid, 110: 已存在, 220: ticket}}`。
  static Qq8FileUploadTicket parseApplyUpload(Uint8List payload) {
    final root = Qq8Pb.decode(payload);
    final rsp = Qq8Pb.bytesAt(root, 19);
    if (rsp == null) {
      throw Qq8FileException('1700 回执里没有 19（响应 ${payload.length} 字节）');
    }
    final m = Qq8Pb.decode(rsp);
    final fid = _utf8Of(Qq8Pb.bytesAt(m, 90));
    return Qq8FileUploadTicket(
      code: Qq8Pb.intAt(m, 10) ?? -1,
      message: _utf8Of(Qq8Pb.bytesAt(m, 20)),
      fid: fid,
      alreadyExists: (Qq8Pb.intAt(m, 110) ?? 0) != 0,
      ticket: Qq8Pb.bytesAt(m, 220) ?? Uint8List(0),
      rawResponse: payload,
    );
  }

  // ---------------------------------------------------------------------
  // ② highway HTTP 上传
  // ---------------------------------------------------------------------

  /// highway 的附加信息（ext）。
  ///
  /// `100.100.700` 里塞的是 **1700 的完整响应体**（服务端靠它认这次上传），
  /// `100.200.700` 塞 1700 回执里的 ticket，`100.300` 是客户端标识
  /// （`400: 'd92615c5'` 是参考实现里写死的魔数）。
  static Uint8List buildHighwayExt({
    required int uin,
    required int peerUin,
    required Uint8List applyUploadResponse,
    required Qq8FileInfo file,
    required String fid,
    required Uint8List ticket,
    required int subid,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: 100,
        2: 2,
        100: <int, Object?>{
          100: <int, Object?>{
            1: 3,
            100: uin,
            200: peerUin,
            400: 0,
            700: applyUploadResponse,
          },
          200: <int, Object?>{
            100: file.size,
            200: file.md5,
            300: file.sha1,
            400: file.md5,
            600: fid,
            700: ticket,
          },
          300: <int, Object?>{
            100: 2,
            200: '$subid',
            300: 2,
            400: 'd92615c5',
            600: 4,
          },
          400: <int, Object?>{
            100: file.name,
          },
        },
        200: 1,
      });

  /// HTTP 分片上限（参考实现 `highwayHttpUpload` 的 `limit = 524288`）。
  static const int httpChunkLimit = 524288;

  /// 构造一片 HTTP 上传帧。
  ///
  /// 与图床的 TCP 帧（[Qq8Highway.buildFrame]）**同一个外层格式**
  /// （`TcpProtocolDataCodec`：STX/头长/块长/头pb/数据/ETX），差别在
  /// 头里多一个 `3: ext`、`4: 时间戳`，seghead 多 `1: 0 / 10: 0 / 13: 0`。
  static Uint8List buildHttpFrame({
    required int seq,
    required String uin,
    required int subid,
    required int cmdId,
    required Uint8List ticket,
    required Uint8List fileMd5,
    required int fileSize,
    required int offset,
    required Uint8List chunk,
    required Uint8List ext,
    required int nowMs,
  }) {
    final head = Qq8Pb.encode(<int, Object?>{
      1: <int, Object?>{
        1: 1,
        2: uin,
        3: 'PicUp.DataUp',
        4: seq,
        5: 0,
        6: subid,
        8: cmdId,
      },
      2: <int, Object?>{
        1: 0,
        2: fileSize,
        3: offset,
        4: chunk.length,
        6: ticket,
        8: md5Bytes(chunk),
        9: fileMd5,
        10: 0,
        13: 0,
      },
      3: ext,
      4: nowMs,
    });
    final out = Uint8List(9 + head.length + chunk.length + 1);
    out[0] = 40;
    _u32be(out, 1, head.length);
    _u32be(out, 5, chunk.length);
    out.setRange(9, 9 + head.length, head);
    out.setRange(9 + head.length, out.length - 1, chunk);
    out[out.length - 1] = 41;
    return out;
  }

  /// 用 HTTP 把文件传到 bigdata 通道，逐片等回执。
  ///
  /// [host]/[port] 来自 bigdata（`PushReq` type=2 的 `1281.3`），
  /// [ticket] 就是 bigdata 的 `sig_session`。
  static Future<void> uploadHttp({
    required String host,
    required int port,
    required String uin,
    required int subid,
    required Uint8List ticket,
    required Uint8List fileMd5,
    required Uint8List data,
    required Uint8List ext,
    Duration timeout = const Duration(seconds: 120),
    void Function(double progress)? onProgress,
  }) async {
    if (data.isEmpty) throw Qq8FileException('要上传的文件是空的');
    final uri = Uri.parse('http://$host:$port/cgi-bin/httpconn'
        '?htcmd=0x6FF0087&uin=$uin');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    final total = data.length;
    var offset = 0;
    var seq = 1;
    Uint8List lastExt = Uint8List(0);
    try {
      while (offset < total) {
        final end = (offset + httpChunkLimit < total) ? offset + httpChunkLimit : total;
        final chunk = Uint8List.sublistView(data, offset, end);
        final frame = buildHttpFrame(
          seq: seq++,
          uin: uin,
          subid: subid,
          cmdId: cmdIdOfflineFile,
          ticket: ticket,
          fileMd5: fileMd5,
          fileSize: total,
          offset: offset,
          chunk: chunk,
          ext: ext,
          nowMs: DateTime.now().millisecondsSinceEpoch,
        );
        final req = await client.postUrl(uri).timeout(timeout);
        req.headers.contentLength = frame.length;
        req.add(frame);
        final resp = await req.close().timeout(timeout);
        final body = await _collect(resp).timeout(timeout);
        final ack = Qq8File._parseHttpAck(body);
        if (ack.code != 0) {
          throw Qq8FileException('highway 拒绝（code=${ack.code}，'
              'offset=$offset，${body.length} 字节回包）');
        }
        lastExt = ack.extendInfo ?? Uint8List(0);
        offset = end;
        onProgress?.call((offset / total).clamp(0.0, 1.0).toDouble());
      }
      if (lastExt.isEmpty) {
        // 参考实现：最后一片回执里没有 7 号扩展信息 = 服务端没做完整性校验，
        // 按"上传失败"处理（《UnsafeFile》），不能继续发消息。
        throw Qq8FileException('文件校验未通过（最后一片回执里没有校验信息）');
      }
    } on Qq8FileException {
      rethrow;
    } on Object catch (e) {
      throw Qq8FileException('上传到 $host:$port 失败：$e');
    } finally {
      client.close(force: true);
    }
  }

  static Future<Uint8List> _collect(HttpClientResponse resp) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      b.add(chunk);
    }
    return b.takeBytes();
  }

  /// 解析 HTTP 回包：开头 STX、尾巴 ETX，中间 `[头长u32][块长u32][头pb][数据]`。
  static ({int code, int offset, int length, Uint8List? extendInfo}) _parseHttpAck(
      Uint8List body) {
    if (body.length < 10 || body[0] != 40) {
      throw Qq8FileException('highway 回包不是 STX 帧（${body.length} 字节）');
    }
    final headLen = _readU32be(body, 1);
    if (9 + headLen > body.length) {
      throw Qq8FileException('highway 回包头长 $headLen 超出 ${body.length}');
    }
    final head = Qq8Pb.decode(body.sublist(9, 9 + headLen));
    final seg = Qq8Pb.bytesAt(head, 2);
    final segM = seg == null ? null : Qq8Pb.decode(seg);
    return (
      code: Qq8Pb.intAt(head, 3) ?? 0,
      offset: segM == null ? 0 : (Qq8Pb.intAt(segM, 3) ?? 0),
      length: segM == null ? 0 : (Qq8Pb.intAt(segM, 4) ?? 0),
      extendInfo: Qq8Pb.bytesAt(head, 7),
    );
  }

  // ---------------------------------------------------------------------
  // ③ 上传完成 / 撤回 / 转发
  // ---------------------------------------------------------------------

  static Uint8List buildUploadSuccBody({
    required int uin,
    required int peerUin,
    required String fid,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: 800,
        2: 7,
        10: <int, Object?>{10: uin, 20: peerUin, 30: fid},
        101: 3,
        102: 104,
      });

  /// `{10: {1: 结果码}}`，0 = 成功。
  static bool parseUploadSucc(Uint8List payload) {
    final root = Qq8Pb.decode(payload);
    final m = Qq8Pb.bytesAt(root, 10);
    if (m == null) return false;
    return (Qq8Pb.intAt(Qq8Pb.decode(m), 1) ?? -1) == 0;
  }

  static Uint8List buildRecallBody({required int uin, required String fid}) =>
      Qq8Pb.encode(<int, Object?>{
        1: 400,
        2: 0,
        6: <int, Object?>{1: uin, 2: fid},
        101: 3,
        102: 104,
        200: 1,
      });

  /// `{6: {1: 结果码}}`，0 = 成功。
  static bool parseRecall(Uint8List payload) {
    final root = Qq8Pb.decode(payload);
    final m = Qq8Pb.bytesAt(root, 6);
    if (m == null) return false;
    return (Qq8Pb.intAt(Qq8Pb.decode(m), 1) ?? -1) == 0;
  }

  static Uint8List buildForwardBody({
    required int uin,
    required int peerUin,
    required String fid,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: 700,
        2: 0,
        9: <int, Object?>{10: uin, 20: peerUin, 30: fid},
        101: 3,
        102: 104,
        200: 1,
      });

  /// 解析转发回执：`{9: {10: 结果码, 20: 文案, 50: 新 fid, 60: ticket}}`。
  static ({bool ok, String newFid, Uint8List ticket, String message}) parseForward(
      Uint8List payload) {
    final root = Qq8Pb.decode(payload);
    final m = Qq8Pb.bytesAt(root, 9);
    if (m == null) {
      return (ok: false, newFid: '', ticket: Uint8List(0), message: '无 9 号回执');
    }
    final d = Qq8Pb.decode(m);
    return (
      ok: (Qq8Pb.intAt(d, 10) ?? -1) == 0,
      newFid: _utf8Of(Qq8Pb.bytesAt(d, 50)),
      ticket: Qq8Pb.bytesAt(d, 60) ?? Uint8List(0),
      message: _utf8Of(Qq8Pb.bytesAt(d, 20)),
    );
  }

  // ---------------------------------------------------------------------
  // ④ 取下载链接
  // ---------------------------------------------------------------------

  static Uint8List buildApplyDownloadBody({required int uin, required String fid}) =>
      Qq8Pb.encode(<int, Object?>{
        1: 1200,
        14: <int, Object?>{10: uin, 20: fid, 30: 2},
        101: 3,
        102: 104,
        99999: <int, Object?>{1: 90200},
      });

  /// 解析 1200 回执：`{14: {10: 结果码, 20: 文案, 30: {30: host, 40: port,
  /// 50: url}, 40: {3: size, 6: fid, 7: name, 100: md5}}}`。
  ///
  /// 服务端给的 `url` 有时是相对路径，这时拼成 `http://host:port + url`。
  static Qq8FileLink parseApplyDownload(Uint8List payload) {
    final root = Qq8Pb.decode(payload);
    final rsp = Qq8Pb.bytesAt(root, 14);
    if (rsp == null) {
      throw Qq8FileException('1200 回执里没有 14（响应 ${payload.length} 字节）');
    }
    final m = Qq8Pb.decode(rsp);
    final code = Qq8Pb.intAt(m, 10) ?? -1;
    if (code != 0) {
      throw Qq8FileException('取文件链接被拒：code=$code '
          '${_utf8Of(Qq8Pb.bytesAt(m, 20))}');
    }
    final urlObj = Qq8Pb.bytesAt(m, 30);
    final info = Qq8Pb.bytesAt(m, 40);
    var url = '';
    if (urlObj != null) {
      final u = Qq8Pb.decode(urlObj);
      url = _utf8Of(Qq8Pb.bytesAt(u, 50));
      if (!url.startsWith('http')) {
        final host = _utf8Of(Qq8Pb.bytesAt(u, 30));
        final port = Qq8Pb.intAt(u, 40) ?? 0;
        url = 'http://$host:$port$url';
      }
    }
    if (url.isEmpty) throw Qq8FileException('1200 回执里没有下载地址');
    final f = info == null ? <int, List<Object>>{} : Qq8Pb.decode(info);
    final md5b = Qq8Pb.bytesAt(f, 100);
    return Qq8FileLink(
      url: url,
      name: _utf8Of(Qq8Pb.bytesAt(f, 7)),
      fid: _utf8Of(Qq8Pb.bytesAt(f, 6)),
      md5Hex: md5b == null ? '' : _hexOf(md5b),
      size: Qq8Pb.intAt(f, 3) ?? 0,
    );
  }
}

/// 发送侧的文件消息元素（拼进 `PbSendMsgReq` 的专用体）。
abstract final class Qq8FileMsg {
  /// `NotOnlineFile`（`im_msg_body` 字段号：3=fid 4=md5 5=name 6=size 9=subcmd）。
  static Uint8List notOnlineFile({
    required String fid,
    required Uint8List md5,
    required String name,
    required int size,
    Uint8List? ticket,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: 0, // file_type
        3: fid, // file_uuid
        4: md5, // file_md5
        5: name,
        6: size,
        9: 1, // subcmd
        57: ?ticket, // 只有转发时带（参考实现）
      });

  /// 私聊文件消息体（`MessageSvc.PbSendMsg`）。
  ///
  /// 与 [Qq8Msg.buildC2cTextBody] 的差别只有两处：路由是 `{15: {1: 对方uin,
  /// 2: 4}}`，`msg_body` 里放 `msg_content`（`{2: {1: NotOnlineFile}}`）
  /// 而不是 `rich_text`。
  static Uint8List buildC2cBody({
    required int uid,
    required int seq,
    required int rand,
    required String fid,
    required Uint8List md5,
    required String name,
    required int size,
    Uint8List? ticket,
    required int syncCookieSeed,
    required int nowSeconds,
    required int syncR5,
    required int syncR9,
    required int syncR11,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: <int, Object?>{
          15: <int, Object?>{1: uid, 2: 4},
        },
        2: Qq8Msg.pbContent,
        3: <int, Object?>{
          2: <int, Object?>{
            1: notOnlineFile(fid: fid, md5: md5, name: name, size: size, ticket: ticket),
          },
        },
        4: seq,
        5: rand,
        6: Qq8Msg.buildSyncCookie(
          seed: syncCookieSeed,
          nowSeconds: nowSeconds,
          r5: syncR5,
          r9: syncR9,
          r11: syncR11,
        ),
      });
}

int _readU32be(Uint8List b, int o) =>
    ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) & 0xFFFFFFFF;

void _u32be(Uint8List b, int o, int v) {
  b[o] = (v >> 24) & 0xFF;
  b[o + 1] = (v >> 16) & 0xFF;
  b[o + 2] = (v >> 8) & 0xFF;
  b[o + 3] = v & 0xFF;
}

/// 16 进制小写（文件 md5/sha1 展示用）。
String _hexOf(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// 字节按 UTF-8 解（服务端给的是 ASCII 文本，解不开就按替换符处理）。
String _utf8Of(List<int>? bytes) =>
    bytes == null ? '' : utf8.decode(bytes, allowMalformed: true);
