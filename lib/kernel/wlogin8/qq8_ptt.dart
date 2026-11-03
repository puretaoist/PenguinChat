/// 语音（PTT）上行：申请上传 + 元素组包。
///
/// 只做"发"这一侧（收在 [Qq8ElemScan.scanPtt] 里，用 RichText.ptt 的 4/6/19/20）。
///
/// 字段号出处（QQ 8.2.11 反编译，classes2.dex 的 `tencent/im/cs/cmd0x346/cmd0x346.java`
/// 与 `tencent/im/msg/im_msg_body.java:601-626`）：
///
/// * 申请上传 ReqBody：1=uint32_cmd(500) / 2=uint32_seq /
///   7=msg_apply_upload_req{10=sender_uin, 20=recver_uin, 30=file_type,
///   40=file_size, 50=file_name, 60=10m_md5} / 101=business_id(17) / 102=client_type(104)
///   —— 注意 ApplyUploadReq 的字段号都是"十位段"（10/20/30…），照抄 PB tag 会全错。
/// * 回执：10=ret_code / 20=ret_msg / 60=upload_ip / 70=upload_domain /
///   80=upload_port / 90=uuid / 100=upload_key / 110=file_exist / 120=pack_size
/// * RichText.ptt（收侧同结构）：1=file_type / 2=src_uin / 3=file_uuid /
///   4=file_md5 / 5=file_name / 6=file_size / 8=file_id / 14=file_key /
///   18=group_file_key / 19=uint32_time / 20=down_para / 21=format
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../crypto/digest.dart';
import 'qq8_pb.dart';

/// 语音链路的异常（申请被拒 / 上传失败 / 缺字段）。
class Qq8PttException implements Exception {
  Qq8PttException(this.message);

  final String message;

  @override
  String toString() => 'Qq8PttException: $message';
}

/// 申请上传回执。
class Qq8PttUploadTicket {
  const Qq8PttUploadTicket({
    required this.code,
    this.message = '',
    this.ip,
    this.domain,
    this.port,
    this.uuid,
    this.uploadKey,
    this.fileExists = false,
    this.packSize = 0,
    this.ipList = const <String>[],
    this.dns,
  });

  final int code;
  final String message;
  final String? ip;
  final String? domain;
  final int? port;
  final Uint8List? uuid;
  final Uint8List? uploadKey;
  final bool fileExists;
  final int packSize;

  /// 备用上传 IP（回执 #130 rpt_str_uploadip_list）。
  final List<String> ipList;

  /// 备用上传域名（回执 #140 str_upload_dns）。
  final String? dns;

  bool get ok => code == 0;

  /// 上传地址：优先 ip，退回 domain。
  String? get host => (ip != null && ip!.isNotEmpty) ? ip : domain;

  bool get hasEndpoint =>
      host != null && host!.isNotEmpty && port != null && port! > 0;

  @override
  String toString() => 'PttUploadTicket(code=$code, host=$host, port=$port, '
      'uuid=${uuid?.length ?? 0}B, key=${uploadKey?.length ?? 0}B, '
      'exist=$fileExists, packSize=$packSize, ipList=${ipList.length}, '
      'dns=$dns)';
}

/// PTT 的 HTTP 上传（官方 8.2.11 \`Layow\` 组 URL、\`Laylx\` 发 POST）。
///
/// 官方把 URL 逐段拼出来（C2C 私聊）：
/// \`http://{ip或domain}[:port]/qqcommfileupload?ver=100&ukey={uploadKey}\`
/// \`&filekey={md5hex}&filesize={size}&bmd5={md5hex}&range=0&voice_codec=0\`
/// * 端口 80 时省略 \`:port\`；协议写死 http（8.2.11 的 C2C 分支不走 https 回执）；
/// * **uuid 不进 URL**，它只写进 \`RichText.ptt.bytes_file_uuid\`；
/// * 方法 POST，body 就是原始 SILK 字节（不是 multipart、不额外包头）；
/// * 只显式设两个头：\`Range: bytes=0-\` 与 \`Accept-Encoding: identity\`；
/// * 成功判据是响应头 \`User-ReturnCode\` 为 0（或 9223372036854775807）。
///
/// 群 PTT 是另一条 URL（\`/?ver=4679&...&mType=pttGu\`，走 BDH 上传），本实现暂不做。
abstract final class Qq8PttHttp {
  /// 上传整段 SILK。[progress] 只在上传前后打点（单请求没有片进度）。
  static Future<void> upload({
    required String host,
    required int port,
    required String uploadKeyHex,
    required String fileKeyHex,
    required Uint8List data,
    Duration timeout = const Duration(seconds: 120),
    Duration connectTimeout = const Duration(seconds: 6),
    void Function(double progress)? onProgress,
  }) async {
    if (data.isEmpty) throw Qq8PttException('要上传的语音是空的');
    final authority = port == 80 ? host : '$host:$port';
    final bmd5 = _md5HexLower(data);
    final uri = Uri.parse('http://$authority/qqcommfileupload'
        '?ver=100'
        '&ukey=${Uri.encodeQueryComponent(uploadKeyHex)}'
        '&filekey=$fileKeyHex'
        '&filesize=${data.length}'
        '&bmd5=$bmd5'
        '&range=0'
        '&voice_codec=0');
    final client = HttpClient()
      ..connectionTimeout = connectTimeout;
    try {
      final req = await client.postUrl(uri).timeout(timeout);
      req.headers.set('Range', 'bytes=0-');
      req.headers.set('Accept-Encoding', 'identity');
      req.headers.contentLength = data.length;
      req.add(data);
      onProgress?.call(0.05);
      final resp = await req.close().timeout(timeout);
      final body = await resp
          .fold<BytesBuilder>(BytesBuilder(copy: false), (b, chunk) => b..add(chunk))
          .timeout(timeout);
      final ret = resp.headers.value('user-returncode') ??
          resp.headers.value('User-ReturnCode');
      final ok = resp.statusCode == 200 &&
          (ret == null || ret == '0' || ret == '9223372036854775807');
      if (!ok) {
        final text = String.fromCharCodes(body.toBytes().take(200).toList());
        throw Qq8PttException('PTT 上传被拒：HTTP ${resp.statusCode} '
            'User-ReturnCode=$ret 回包=$text');
      }
      onProgress?.call(1);
    } on Qq8PttException {
      rethrow;
    } on Object catch (e) {
      throw Qq8PttException('PTT 上传到 $authority 失败：$e');
    } finally {
      client.close(force: true);
    }
  }
}

String _md5HexLower(Uint8List data) {
  // RFC 1321 太少用，这里复用 kernel 已有的 md5Bytes（登录/文件都在用）。
  final v = md5Bytes(data);
  return v.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// 十六进制串（小写）。官方 \`HexUtil.bytes2HexStr\` 用的就是小写；
/// 若真机 \`User-ReturnCode\` 非 0，第一嫌疑是这张串的大小写或是否需要 URL 编码。
String hexOfBytes(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

abstract final class Qq8Ptt {
  /// 申请上传（C2C/群共用；群另有 BDH 路径，本实现先走这条）。
  static const String cmdApplyDownload =
      'PttCenterSvr.pb_pttCenter_CMD_REQ_APPLY_DOWNLOAD-1200';

  static const String cmdApplyUpload =
      'PttCenterSvr.pb_pttCenter_CMD_REQ_APPLY_UPLOAD-500';

  /// 业务号与客户端类型（官方 Layuw 里的常量）。
  static const int businessId = 17;
  static const int clientType = 104;

  /// 上传申请里的 file_type（官方 const/4 2）。
  static const int applyFileType = 2;

  /// 消息元素里的 file_type（官方 getRichText() 固定 4）。
  static const int elemFileType = 4;

  static const int formatSilk = 1;

  /// 构造申请上传请求体。
  ///
  /// 官方 \`Layuw.a(List)\` 每次都会挂 \`msg_extension_req\`（#99999，注意是十万位段的
  /// 大 tag，不是普通 7 号字段）：语音要 ptt_format/ptt_time/net_type/voice_type，
  /// 缺它服务端可能按"未知子业务"处理。
  static Uint8List buildApplyUploadBody({
    required int uin,
    required int peerUin,
    required String fileName,
    required int fileSize,
    required Uint8List md5,
    required int seq,
    int voiceSeconds = 0,
    int pttFormat = formatSilk,
    int netType = 1,
    int voiceType = 0,
    int bdhCmdId = 500,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: 500,
        2: seq,
        7: <int, Object?>{
          10: uin,
          20: peerUin,
          30: applyFileType,
          40: fileSize,
          50: fileName,
          60: md5,
        },
        101: businessId,
        102: clientType,
        99999: <int, Object?>{
          1: 3,
          2: bdhCmdId,
          90200: pttFormat,
          90400: netType,
          90500: voiceType,
          90800: voiceSeconds,
        },
      });

  static Qq8PttUploadTicket parseApplyUploadResponse(Uint8List payload) {
    // 回包是 \`cmd0x346.RspBody\`：真正的内容在 7=msg_apply_upload_rsp（V2/V3 是 18/19）。
    // 直接按 ApplyUploadRsp 解会拿不到 ret_code（线上实测 code=-1）。
    var m = Qq8Pb.decode(payload);
    for (final tag in const <int>[7, 18, 19]) {
      final inner = Qq8Pb.bytesAt(m, tag);
      if (inner != null && inner.isNotEmpty) {
        m = Qq8Pb.decode(inner);
        break;
      }
    }
    return Qq8PttUploadTicket(
      code: Qq8Pb.intAt(m, 10) ?? -1,
      message: Qq8Pb.textAt(m, 20) ?? '',
      ip: Qq8Pb.textAt(m, 60),
      domain: Qq8Pb.textAt(m, 70),
      port: Qq8Pb.intAt(m, 80),
      uuid: Qq8Pb.bytesAt(m, 90),
      uploadKey: Qq8Pb.bytesAt(m, 100),
      fileExists: (Qq8Pb.intAt(m, 110) ?? 0) != 0,
      packSize: Qq8Pb.intAt(m, 120) ?? 0,
      ipList: (m[130] ?? const <Object>[])
          .whereType<Uint8List>()
          .map((b) => utf8.decode(b, allowMalformed: true))
          .where((s) => s.isNotEmpty)
          .toList(growable: false),
      dns: Qq8Pb.textAt(m, 140),
    );
  }

  /// 申请下载（1200）：拿这条语音的可下载地址。
  ///
  /// 字段号出处（2026-11-02 核对 8.2.11 反编译
  /// tencent/im/cs/cmd0x346/cmd0x346$ReqBody$ApplyDownloadReq 的 FieldMap）：
  /// uint64_uin=10、**bytes_uuid=20**、**uint32_owner_type=30**、
  /// uint32_filetype=50、str_fileidcrc=60、uint32_ext_uintype=500、
  /// uint32_need_https_url=501、str_fileid=600。
  /// 早期版本把 bytes_uuid 写成 2、把 owner_type 写成 501，
  /// 服务端因此找不到文件，回包里只会是 fileid= 空的坏直链
  /// （GET 它必得 400 -5503023 appid is not match）。
  static Uint8List buildApplyDownloadBody({
    required int uin,
    required Uint8List uuid,
    int seq = 0,
    int filetype = elemFileType,
    int ownerType = ownerTypeSelf,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: 1200,
        2: seq,
        14: <int, Object?>{
          10: uin,
          20: uuid,
          30: ownerType,
          50: filetype,
        },
        101: businessId,
        102: clientType,
      });

  /// ApplyDownloadReq.uint32_owner_type：1=自己（发送方回读），2=对方。
  static const int ownerTypeSelf = 1;
  static const int ownerTypePeer = 2;

  /// 从 1200 的回包里取直链：`RspBody.14(ApplyDownloadRsp).30(DownloadInfo).50`。
  static String? parseApplyDownloadUrl(Uint8List payload) {
    try {
      final root = Qq8Pb.decode(payload);
      final rsp = Qq8Pb.bytesAt(root, 14);
      if (rsp == null) return null;
      final info = Qq8Pb.bytesAt(Qq8Pb.decode(rsp), 30);
      if (info == null) return null;
      final url = Qq8Pb.textAt(Qq8Pb.decode(info), 50);
      return (url == null || url.isEmpty) ? null : url;
    } on Object {
      return null;
    }
  }
  /// 构造 RichText.ptt。
  ///
  /// [dm] 为 true 走私聊（官方不填 server_ip/port/time）；群聊要 file_id、
  /// format、time 与 group_file_key。
  static Uint8List buildPttElem({
    required int fileType,
    required Uint8List fileMd5,
    required String fileName,
    required int fileSize,
    required Uint8List fileUuid,
    required String downPara,
    required int seconds,
    bool dm = true,
    int? fileId,
    Uint8List? groupFileKey,
    int format = formatSilk,
    Uint8List? pbReserve,
    int srcUin = 0,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: fileType,
        if (srcUin > 0) 2: srcUin,
        3: fileUuid,
        4: fileMd5,
        5: fileName,
        6: fileSize,
        // C2C 的 reserve 走 #7，群走 #22（官方 getRichText 两个分支不同）。
        if (dm) 7: ?pbReserve,
        if (!dm && fileId != null && fileId > 0) 8: fileId,
        if (!dm) 18: ?groupFileKey,
        if (!dm) 19: seconds,
        20: downPara,
        if (!dm) 21: format,
        if (!dm) 22: ?pbReserve,
      });
}

/// PTT 真实上传通道（2026-11-01 真机实证：3547B SILK → HTTP 200 / ack code=0 →
/// `MessageSvc.PbSendMsg` code=0，对端可见）。
///
/// 为什么不用 [Qq8PttHttp]：`0x346` 回执里的 `upload_ip` 是**运营商边缘节点**，
/// 在宽带 Wi-Fi 上完全不可达（实测 11.180.x / 30.176.x 全部超时）。真正的
/// 上传节点与鉴权 ticket 来自 bigdata 通道（`HttpConn.0x6ff_501`），帧格式
/// 按 TIM 抓包（`_ptt_tim2.pcap`）逐字段复刻：
///
/// ```
/// 0x28 | u32be 头长 | u32be 片长 | 头PB | 数据 | 0x29
/// 头PB = {1:{1:1, 2:uin, 3:'PicUp.DataUp', 4:seq, 5:0, 6:0, 7:16, 8:1007},
///         2:{1:0, 2:总长, 3:偏移, 4:片长, 6:ticket, 8:md5(片), 9:md5(整),
///            10:0, 13:0},
///         3:ext{6: 0x346 回执原始字节, 10: 1048576}, 4:0}
/// ```
///
/// 回包同样是 STX 包：头的 `f3 uint32_error_code` 是结果码，0 = 成功。
abstract final class Qq8PttHighway {
  /// 取上传节点的命令字（bigdata 通道）。
  static const String cmdBigdataChannel = 'HttpConn.0x6ff_501';

  /// httpconn 的服务标识（TIM 抓包里就是这个字面量）。
  static const String htcmd = '0x6FF0087';

  /// 帧头里的子命令号：语音上传是 1007（离线文件才是 69）。
  static const int cmdIdUpload = 1007;

  /// 单包上限（0x346 回执 pack_size 默认 524288）。
  static const int defaultChunkLimit = 524288;

  /// 组一帧上传包。
  static Uint8List buildFrame({
    required int seq,
    required String uin,
    required int totalSize,
    required int offset,
    required Uint8List chunk,
    required Uint8List ticket,
    required Uint8List fileMd5,
    required Uint8List ext,
  }) {
    final head = Qq8Pb.encode(<int, Object?>{
      1: <int, Object?>{
        1: 1,
        2: uin,
        3: 'PicUp.DataUp',
        4: seq,
        5: 0,
        6: 0,
        7: 16,
        8: cmdIdUpload,
      },
      2: <int, Object?>{
        1: 0,
        2: totalSize,
        3: offset,
        4: chunk.length,
        6: ticket,
        8: md5Bytes(chunk),
        9: fileMd5,
        10: 0,
        13: 0,
      },
      3: ext,
      4: 0,
    });
    final out = Uint8List(9 + head.length + chunk.length + 1);
    out[0] = 0x28;
    out[1] = (head.length >> 24) & 0xFF;
    out[2] = (head.length >> 16) & 0xFF;
    out[3] = (head.length >> 8) & 0xFF;
    out[4] = head.length & 0xFF;
    out[5] = (chunk.length >> 24) & 0xFF;
    out[6] = (chunk.length >> 16) & 0xFF;
    out[7] = (chunk.length >> 8) & 0xFF;
    out[8] = chunk.length & 0xFF;
    out.setRange(9, 9 + head.length, head);
    out.setRange(9 + head.length, 9 + head.length + chunk.length, chunk);
    out[out.length - 1] = 0x29;
    return out;
  }

  /// 解回包里的结果码（`RspDataHighwayHead.f3 uint32_error_code`）。
  ///
  /// 2026-11-03 修正：旧实现读 `f2.f1`（SegHead 的 uint32_serviceid，服务端恒回 0），
  /// 于是服务端真的回 error_code=372 时我方也判「上传成功」，日志打「PTT 上传完成」
  /// 而文件其实没登记（对端因此显示「消息已过期」）。官方字段表见
  /// `com/tencent/mobileqq/highway/protocol/CSDataHighwayHead.java` 的 initFieldMap：
  /// RspDataHighwayHead = {1 basehead, 2 seghead, 3 error_code, 4 allow_retry,
  /// 5 cachecost, 6 htcost, 7 rsp_extendinfo, 8 timestamp, 9 range, 10 is_reset}。
  static int ackCode(Uint8List body) {
    final head = _ackHead(body);
    if (head == null) return -1;
    return Qq8Pb.intAt(head, 3) ?? -1;
  }

  /// 回包里的扩展信息（`RspDataHighwayHead.f7 bytes_rsp_extendinfo`）。
  ///
  /// 官方 presend 的 0x346 RspBody（含 bytes_uuid）就从这里回，我方当前
  /// 上传路径还没用到，但保留取用入口便于后续接 presend 流程。
  static Uint8List? ackExtendInfo(Uint8List body) {
    final head = _ackHead(body);
    if (head == null) return null;
    final ext = Qq8Pb.bytesAt(head, 7);
    return (ext == null || ext.isEmpty) ? null : ext;
  }

  static Map<int, List<Object>>? _ackHead(Uint8List body) {
    if (body.length < 9 || body[0] != 0x28) return null;
    final headLen = (body[1] << 24) | (body[2] << 16) | (body[3] << 8) | body[4];
    if (9 + headLen > body.length) return null;
    try {
      return Qq8Pb.decode(body.sublist(9, 9 + headLen));
    } on Object {
      return null;
    }
  }

}
