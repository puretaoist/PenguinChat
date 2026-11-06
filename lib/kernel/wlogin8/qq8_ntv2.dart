/// NT 富媒体（NTV2）上行：0x126d 申请 + Highway 传输 + MsgInfo 元素。
///
/// ## 为什么需要这一层
///
/// 老链路（`0x346` 申请 + `/qqcommfileupload` 上传 + 手拼 `RichText.ptt`）
/// 走不通：0x346 的回执里只有 `uuid/upload_key`，**没有 fileid/rkey**；而普通
/// GET 下载需要 `rkey`，rkey 是服务端在 `0x1200` 申请时按「已登记文件」签发的。
/// 文件没登记 → 对端点开一律「消息已过期」（真机 2026-11-02 复现）。
///
/// 官方 8.2.11 的语音走 **OIDB `0x126d_100`**（私聊）/ **`0x126e_100`**（群）
/// 富媒体上传，一次拿到：
///
/// ```
/// UploadResp {
///   1 UKey                // 上传票据
///   3 IPv4s               // 上传节点（highway 用）
///   6 MsgInfo             // ① 发给 highway 的 ext 里要带 ② 直接当消息体发出去
///   8 CompatQMsg          // 给旧协议的兼容消息（本实现不直接用）
/// }
/// ```
///
/// 发消息时把 **MsgInfo 原样序列化**塞进 `Elem.common_elem{1=48, 2=MsgInfo, 3=12}`
/// （Lagrange.Core `Message/Entities/RecordEntity.cs:Build()`）。服务端投递时按
/// MsgInfo 里的 `index.file_uuid` 生成下行直链，所以对端不会再判过期。
///
/// ## 字段号出处
///
/// 全部按 Lagrange.Core（NTQQ 协议实现）核对：
/// * 请求 `Internal/Packets/Service/NTV2RichMediaReq.cs`
/// * 上传服务 `Internal/Services/Message/NTV2RichMediaUploadService.cs`
///   （RecordUploadService：`[Service("OidbSvcTrpcTcp.0x126d_100")]`）
/// * 传输扩展 `Internal/Packets/Service/NTV2RichMediaHighwayExt.cs`
/// * 头/块 `Internal/Context/HighwayContext.cs`
///
/// 本文件是纯 Dart（L1/L2 禁 import Flutter）。
library;

import 'dart:typed_data';

import 'qq8_pb.dart';

/// NT 富媒体链路的异常（申请被拒 / 缺字段 / 解析失败）。
class Qq8Ntv2Exception implements Exception {
  Qq8Ntv2Exception(this.message);

  final String message;

  @override
  String toString() => 'Qq8Ntv2Exception: $message';
}

/// 一组上传节点（IP 点分串 + 端口）。
///
/// 注意这里存的是**已点分好的字符串**：协议里 IP 是 uint32 且第一段在最低字节，
/// 转换见 [Qq8Ntv2.ipv4Of]。
class Qq8Ntv2Endpoint {
  const Qq8Ntv2Endpoint(this.host, this.port);

  final String host;
  final int port;

  @override
  String toString() => '$host:$port';
}

/// 0x126d 申请回执。
class Qq8Ntv2UploadTicket {
  const Qq8Ntv2UploadTicket({
    required this.result,
    this.message = '',
    this.ukey = '',
    this.msgInfo,
    this.ipv4s = const <Qq8Ntv2Endpoint>[],
    this.compatQMsg,
  });

  /// OIDB 外层结果码（0 = 成功）。
  final int result;

  final String message;

  /// 上传票据（highway ext.2）。
  final String ukey;

  /// `UploadResp.6` 的**原始字节**——既用于拼 ext.6，也直接当消息体。
  final Uint8List? msgInfo;

  final List<Qq8Ntv2Endpoint> ipv4s;

  final Uint8List? compatQMsg;

  bool get ok => result == 0 && msgInfo != null && msgInfo!.isNotEmpty;

  @override
  String toString() =>
      'Ntv2UploadTicket(result=$result, msg=$message, '
      'ukey=${ukey.length}B, msgInfo=${msgInfo?.length ?? 0}B, '
      'ipv4s=${ipv4s.length})';
}

abstract final class Qq8Ntv2 {
  /// 好友增量拉取（uid ↔ uin 映射的唯一来源）。
  ///
  /// 命令名不是 `OidbSvcTrpcTcp.0xfd4_1` 而是这个字面量——官方把 OIDB 外壳
  /// 包成 trpc 服务名（Lagrange `FetchFriendsService` 的 `[Service(...)]`）。
  static const String cmdFriendUidPull = 'OidbSvcTrpcTcp.0xfd4_1';

  /// 富媒体上传（私聊语音）。群语音是 `0x126e_100`。
  static const String cmdUploadPtt = 'OidbSvcTrpcTcp.0x126d_100';

  /// 富媒体上传（群语音）。字段与 0x126d 只差 SceneInfo / CompatQMsgSceneType /
  /// PttExtBizInfo 三处，见 [buildUploadGroupPttBody]。
  static const String cmdUploadGroupPtt = 'OidbSvcTrpcTcp.0x126e_100';

  static const int oidbFriendUidPull = 0xfd4;
  static const int oidbServiceFriendUidPull = 1;

  static const int oidbUploadPtt = 0x126d;
  static const int oidbServiceUploadPtt = 100;

  static const int oidbUploadGroupPtt = 0x126e;

  /// highway ext.10：分块大小 1 MiB（Lagrange `Common.BlockSize`）。
  static const int blockSize = 1048576;

  /// `Elem.common_elem` 的 serviceType / businessType（语音私聊）。
  static const int serviceTypePtt = 48;
  static const int businessTypeC2cPtt = 12;

  /// 语音文件类型：`FileType{1:Type=3(语音), 4:VoiceFormat=1(SILK)}`。
  static const int fileTypeVoice = 3;
  static const int voiceFormatSilk = 1;

  // ---------------------------------------------------------------------
  // ① 好友 uid 拉取（0xfd4_1）
  //
  // ⚠️ 现状（2026-11-05 真机实测）：服务端把 `IncPullResponseFriend.field1`
  // 填成 uin（varint），**不返回 uid 字符串**，所以这张表在本账号体系下永远是
  // 空的。语音上传因此改走 `AccountType=1 + uin`（见 [buildUploadPttBody]），
  // 不再依赖这里。保留这两个方法是因为它们是协议的正确定义，将来若服务端
  // 恢复返回 uid（例如换到真 NT 登录），可以直接接上。
  // ---------------------------------------------------------------------

  /// 组 `IncPullRequest`。
  ///
  /// 这些魔数全部照抄 Lagrange `FetchFriendsService.ProcessRequest`：
  /// `ReqCount=300 / LocalSeq=13 / Flag=1 / ProxySeq=int.MaxValue`，
  /// 两个 biz（1 要基础资料、4 要备注/签名），外加 sns/privateId 的 key 表。
  /// 少一个 biz 服务端也会回，但拿到的字段不全（uid 在 101 里，不受影响，
  /// 不过跟官方一致更省心）。
  static Uint8List buildFriendUidPullBody() => Qq8Pb.encode(<int, Object?>{
    2: 300, // req_count
    3: 0, // time
    4: 13, // local_seq
    6: 1, // flag
    7: 0x7FFFFFFF, // proxy_seq
    10001: <Object?>[
      <int, Object?>{
        1: 1,
        2: <int, Object?>{
          1: <int>[103, 102, 20002, 27394, 20009, 20037],
        },
      },
      <int, Object?>{
        1: 4,
        2: <int, Object?>{
          1: <int>[100, 101, 102],
        },
      },
    ],
    10002: <int>[13578, 13579, 13573, 13572, 13568],
    10003: <int>[4051],
  });

  /// 从 `IncPullResponse` 里取 `uin → uid`。
  ///
  /// 101 是 repeated `IncPullResponseFriend{1=uid(string), 2=categoryId, 3=uin}`。
  /// 只收两者都齐的项；解析失败抛 [Qq8Ntv2Exception]，不静默返回空表
  /// （空表会被上层误判成「不是好友」）。
  static Map<int, String> parseFriendUidPull(Uint8List payload) {
    final inner = _unwrapOidb(payload, '好友 uid 拉取');
    final rsp = Qq8Pb.decode(inner);
    final list = rsp[101];
    if (list == null) return const <int, String>{};
    final out = <int, String>{};
    for (final raw in list) {
      if (raw is! Uint8List) continue;
      final f = Qq8Pb.decode(raw);
      // uid 一般是 UTF-8 字符串；少数版本塞 bytes，两种都收。
      final uidBytes = Qq8Pb.bytesAt(f, 1);
      final uidText = Qq8Pb.textAt(f, 1);
      final uid = (uidText != null && uidText.isNotEmpty)
          ? uidText
          : (uidBytes == null ? '' : String.fromCharCodes(uidBytes));
      // uin 官方是 uint32（varint），也见过字符串形态，都收。
      final uinRaw = (f[3] == null || f[3]!.isEmpty) ? null : f[3]!.first;
      int? uin;
      if (uinRaw is int) {
        uin = uinRaw;
      } else if (uinRaw is Uint8List) {
        uin = int.tryParse(String.fromCharCodes(uinRaw));
      }
      if (uid.isEmpty || uin == null || uin <= 0) continue;
      out[uin] = uid;
    }
    return out;
  }

  // ---------------------------------------------------------------------
  // ② 富媒体上传申请（私聊 0x126d_100 / 群 0x126e_100）
  // ---------------------------------------------------------------------

  /// 组 `NTV2RichMediaReq{1:ReqHead, 2:Upload}`（私聊语音 0x126d）。
  ///
  /// [targetUid] 与 [accountType] 是一对，必须配套：
  /// - `accountType = 2`（官方 NT 默认）→ targetUid 必须是 uid `u_xxxxxxxx`；
  /// - `accountType = 1` → targetUid 直接填 **uin 数字串**。
  /// 本账号体系只有 uin（0xfd4 与老 friendlist 都不回 uid），所以调用方一律传
  /// `accountType: 1` + uin（2026-11-05 真机实测通过；2 + uin 会回
  /// `result=170019001 illegal params`）。
  /// [clientRandomId] 官方用随机 u64，由调用方传入便于自测复现。
  static Uint8List buildUploadPttBody({
    required String targetUid,
    required int fileSize,
    required String md5Hex,
    required String sha1Hex,
    required String fileName,
    required int seconds,
    required int clientRandomId,
    int accountType = 2,
  }) {
    if (targetUid.isEmpty) {
      throw Qq8Ntv2Exception('0x126d 私聊必须给 targetUid（uin 或 NT uid），当前为空');
    }
    return _buildUploadBody(
      // SceneInfo{101:RequestType=2(上传), 102:BusinessType=3(语音),
      //           200:SceneType=1(私聊), 201:C2C{1:AccountType, 2:TargetUid}}
      scene: <int, Object?>{
        101: 2,
        102: 3,
        200: 1,
        201: <int, Object?>{1: accountType, 2: targetUid},
      },
      // CompatQMsgSceneType：私聊 = 1
      compatSceneType: 1,
      // PttExtBizInfo{11:BytesReserve, 13:BytesGeneralFlags}（私聊 12 为空，不写）
      pttExt: <int, Object?>{
        11: Uint8List.fromList(const <int>[0x08, 0x00, 0x38, 0x00]),
        13: Uint8List.fromList(const <int>[
          0x9a,
          0x01,
          0x0b,
          0xaa,
          0x03,
          0x08,
          0x08,
          0x04,
          0x12,
          0x04,
          0x00,
          0x00,
          0x00,
          0x00,
        ]),
      },
      fileSize: fileSize,
      md5Hex: md5Hex,
      sha1Hex: sha1Hex,
      fileName: fileName,
      seconds: seconds,
      clientRandomId: clientRandomId,
    );
  }

  /// 组群语音上传申请（0x126e_100）。
  ///
  /// 与 [buildUploadPttBody]（0x126d）只有三处不同（Lagrange
  /// `NTV2RichMedia.cs` 的 `CreateGroupUpload`）：
  /// * SceneInfo 改 `200:SceneType=2` + `202:Group{1:GroupUin}`；
  /// * UploadInfo.5 CompatQMsgSceneType = 2；
  /// * PttExtBizInfo 的 11/12 互换、13 换成群专用 flags。
  static Uint8List buildUploadGroupPttBody({
    required int groupUin,
    required int fileSize,
    required String md5Hex,
    required String sha1Hex,
    required String fileName,
    required int seconds,
    required int clientRandomId,
  }) {
    if (groupUin <= 0) {
      throw Qq8Ntv2Exception('0x126e 群语音必须给 groupUin，当前 $groupUin');
    }
    return _buildUploadBody(
      // SceneInfo{101:2, 102:3, 200:SceneType=2(群), 202:Group{1:GroupUin}}
      scene: <int, Object?>{
        101: 2,
        102: 3,
        200: 2,
        202: <int, Object?>{1: groupUin},
      },
      compatSceneType: 2,
      // 群：11 BytesReserve 空（不写）、12 BytesPbReserve=[08 00 38 00]、
      //     13 BytesGeneralFlags 用群 flags
      pttExt: <int, Object?>{
        12: Uint8List.fromList(const <int>[0x08, 0x00, 0x38, 0x00]),
        13: Uint8List.fromList(const <int>[
          0x9a,
          0x01,
          0x07,
          0xaa,
          0x03,
          0x04,
          0x08,
          0x08,
          0x12,
          0x00,
        ]),
      },
      fileSize: fileSize,
      md5Hex: md5Hex,
      sha1Hex: sha1Hex,
      fileName: fileName,
      seconds: seconds,
      clientRandomId: clientRandomId,
    );
  }

  /// 私聊/群共用的上传体（差异只在 [scene] / [compatSceneType] / [pttExt]）。
  static Uint8List _buildUploadBody({
    required Map<int, Object?> scene,
    required int compatSceneType,
    required Map<int, Object?> pttExt,
    required int fileSize,
    required String md5Hex,
    required String sha1Hex,
    required String fileName,
    required int seconds,
    required int clientRandomId,
  }) => Qq8Pb.encode(<int, Object?>{
    1: <int, Object?>{
      // CommonHead{1:RequestId=1, 2:Command=100}
      1: <int, Object?>{1: 1, 2: oidbServiceUploadPtt},
      2: scene,
      // ClientMeta{1:AgentType=2}
      3: <int, Object?>{1: 2},
    },
    2: <int, Object?>{
      // UploadInfo[0]{1:FileInfo, 2:SubFileType=0}
      1: <Object?>[
        <int, Object?>{
          1: <int, Object?>{
            1: fileSize, // FileSize
            2: md5Hex, // FileHash（十六进制串）
            3: sha1Hex, // FileSha1
            4: fileName,
            // FileType{1:Type=3, 4:VoiceFormat=1(SILK)}
            5: <int, Object?>{1: fileTypeVoice, 4: voiceFormatSilk},
            8: seconds, // Time：语音时长（秒）
          },
          2: 0,
        },
      ],
      2: 1, // TryFastUploadCompleted
      3: 0, // SrvSendMsg（我们自己在外面发消息）
      4: clientRandomId,
      5: compatSceneType, // CompatQMsgSceneType
      // ExtBizInfo{1:Pic{2:''}, 2:Video{3:空}, 3:Ptt{...}}
      6: <int, Object?>{
        1: <int, Object?>{2: ''},
        2: <int, Object?>{3: Uint8List(0)},
        3: pttExt,
      },
      7: 10, // ClientSeq（官方固定 10）
      8: 0, // NoNeedCompatMsg：要兼容消息
    },
  });

  /// 解 `NTV2RichMediaResp`。
  static Qq8Ntv2UploadTicket parseUploadPttResponse(Uint8List payload) {
    final top = Qq8Pb.decode(payload);
    final outerResult = Qq8Pb.intAt(top, 3) ?? 0;
    final outerMsg = Qq8Pb.textAt(top, 5) ?? '';
    if (outerResult != 0) {
      return Qq8Ntv2UploadTicket(result: outerResult, message: outerMsg);
    }
    final body = Qq8Pb.bytesAt(top, 4);
    if (body == null) {
      throw Qq8Ntv2Exception('0x126d 回包缺 body（OIDB 层）');
    }
    final rsp = Qq8Pb.decode(body);
    final head = Qq8Pb.bytesAt(rsp, 1);
    var retCode = 0;
    var retMsg = '';
    if (head != null) {
      final h = Qq8Pb.decode(head);
      retCode = Qq8Pb.intAt(h, 2) ?? 0;
      retMsg = Qq8Pb.textAt(h, 3) ?? '';
    }
    final upload = Qq8Pb.bytesAt(rsp, 2);
    if (upload == null) {
      return Qq8Ntv2UploadTicket(
        result: retCode == 0 ? -1 : retCode,
        message: retMsg.isEmpty ? '缺 Upload' : retMsg,
      );
    }
    final u = Qq8Pb.decode(upload);
    final ukey = Qq8Pb.textAt(u, 1) ?? '';
    final msgInfo = Qq8Pb.bytesAt(u, 6);
    return Qq8Ntv2UploadTicket(
      result: retCode,
      message: retMsg,
      ukey: ukey,
      msgInfo: msgInfo,
      ipv4s: parseIpv4List(u[3]),
      compatQMsg: Qq8Pb.bytesAt(u, 8),
    );
  }

  /// 解 repeated `IPv4{1:OutIP(uint32), 2:OutPort(uint32)}`。
  static List<Qq8Ntv2Endpoint> parseIpv4List(List<Object>? list) {
    if (list == null || list.isEmpty) return const <Qq8Ntv2Endpoint>[];
    final out = <Qq8Ntv2Endpoint>[];
    for (final raw in list) {
      if (raw is! Uint8List) continue;
      final m = Qq8Pb.decode(raw);
      final ip = Qq8Pb.intAt(m, 1);
      final port = Qq8Pb.intAt(m, 2);
      if (ip == null || port == null || port <= 0) continue;
      out.add(Qq8Ntv2Endpoint(ipv4Of(ip), port));
    }
    return out;
  }

  /// uint32 → 点分 IP。
  ///
  /// **第一段在最低字节**（Lagrange `ProtocolHelper.UInt32ToIPV4Addr`）。
  /// 反过来解会得到 226.x / 82.x 这类保留段——真机日志里见过，别改。
  static String ipv4Of(int v) {
    final a = v & 0xFF;
    final b = (v >> 8) & 0xFF;
    final c = (v >> 16) & 0xFF;
    final d = (v >> 24) & 0xFF;
    return '$a.$b.$c.$d';
  }

  // ---------------------------------------------------------------------
  // ③ highway 传输扩展 + 消息元素
  // ---------------------------------------------------------------------

  /// 从 MsgInfo 里抽 highway ext 需要的三样东西。
  ///
  /// 结构：`MsgInfo{1:[MsgInfoBody{1:IndexNode{1:FileInfo{3:FileSha1}, 2:FileUuid}}]}`。
  /// 返回 `(fileUuid, sha1Hex, msgInfoBodies)`；msgInfoBodies 是各 body 的**原始
  /// 字节**（ext.6 是 repeated message，直接原样塞，避免重建导致字段丢失）。
  static ({String fileUuid, String sha1Hex, List<Uint8List> bodies})
  splitMsgInfo(Uint8List msgInfo) {
    final m = Qq8Pb.decode(msgInfo);
    final bodies = <Uint8List>[];
    String fileUuid = '';
    String sha1Hex = '';
    for (final raw in (m[1] ?? const <Object>[])) {
      if (raw is! Uint8List) continue;
      bodies.add(raw);
      if (fileUuid.isNotEmpty) continue;
      final body = Qq8Pb.decode(raw);
      final index = Qq8Pb.bytesAt(body, 1);
      if (index == null) continue;
      final idx = Qq8Pb.decode(index);
      fileUuid = Qq8Pb.textAt(idx, 2) ?? '';
      final info = Qq8Pb.bytesAt(idx, 1);
      if (info != null) {
        sha1Hex = Qq8Pb.textAt(Qq8Pb.decode(info), 3) ?? '';
      }
    }
    if (fileUuid.isEmpty || bodies.isEmpty) {
      throw Qq8Ntv2Exception('MsgInfo 缺 file_uuid 或 MsgInfoBody');
    }
    return (fileUuid: fileUuid, sha1Hex: sha1Hex, bodies: bodies);
  }

  /// 组 `NTV2RichMediaHighwayExt`（highway 帧的 `f3 bytes_req_extendinfo`）。
  ///
  /// `{1:FileUuid, 2:UKey, 5:Network{1:[{1:{1:true, 2:ip}, 2:port}]},
  ///   6:MsgInfoBody[], 10:BlockSize, 11:Hash{1:[sha1]}}`
  static Uint8List buildHighwayExt({
    required String fileUuid,
    required String ukey,
    required List<Qq8Ntv2Endpoint> endpoints,
    required List<Uint8List> msgInfoBodies,
    required String sha1Hex,
  }) {
    final sha1 = sha1Hex.isEmpty ? Uint8List(0) : hexToBytes(sha1Hex);
    return Qq8Pb.encode(<int, Object?>{
      1: fileUuid,
      2: ukey,
      5: <int, Object?>{
        1: <Object?>[
          for (final e in endpoints)
            <int, Object?>{
              1: <int, Object?>{1: 1, 2: e.host},
              2: e.port,
            },
        ],
      },
      6: msgInfoBodies,
      10: blockSize,
      11: <int, Object?>{
        1: <Object?>[sha1],
      },
    });
  }

  /// 组语音消息元素：`Elem.common_elem{1=48, 2=MsgInfo 原始字节, 3=12}`。
  ///
  /// 私聊 businessType=12，群聊是 22（官方 `RecordEntity.Build`）。
  static Uint8List buildPttMsgElem(Uint8List msgInfo, {bool group = false}) =>
      Qq8Pb.encode(<int, Object?>{
        53: <int, Object?>{
          1: serviceTypePtt,
          2: msgInfo,
          3: group ? 22 : businessTypeC2cPtt,
        },
      });

  // ---------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------

  /// 去掉 OIDB 外壳：`{1:cmd, 2:svc, 3:result, 4:body, 5:msg}`。
  ///
  /// 有些服务（大表情等）回包直接是 body，所以这里「有 4 就取 4，没有就用原包」
  /// ——不猜成功，只做拆壳。
  static Uint8List _unwrapOidb(Uint8List payload, String what) {
    final m = Qq8Pb.decode(payload);
    final body = Qq8Pb.bytesAt(m, 4);
    if (body != null && body.isNotEmpty) {
      final result = Qq8Pb.intAt(m, 3);
      if (result != null && result != 0) {
        throw Qq8Ntv2Exception(
          '$what 失败：result=$result ${Qq8Pb.textAt(m, 5) ?? ''}',
        );
      }
      return body;
    }
    return payload;
  }
}

/// 十六进制串 → 字节（奇数长度或非法字符抛错，不静默截断）。
Uint8List hexToBytes(String hex) {
  if (hex.length.isOdd) {
    throw Qq8Ntv2Exception('十六进制串长度不是偶数：${hex.length}');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final v = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (v == null) {
      throw Qq8Ntv2Exception('非法十六进制字符：${hex.substring(i * 2, i * 2 + 2)}');
    }
    out[i] = v;
  }
  return out;
}
