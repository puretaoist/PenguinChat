/// L2 协议内核：发消息（`MessageSvc.PbSendMsg`）
///
/// ## 报文结构（UNI 包，线上线后发）
///
/// 请求体是 protobuf，字段照参考实现 `lib/friend.ts` / `lib/group.ts` 的
/// `_sendMsg`：
///
/// | tag | 私聊（c2c） | 群聊 |
/// |---|---|---|
/// | 1 | `{1: {1: uin}}` 路由 | `{2: {1: gid}}` 路由 |
/// | 2 | 固定 `PB_CONTENT = {1:1,2:0,3:0}` | 同 |
/// | 3 | `{1: rich}` | 同 |
/// | 4 | 消息 seq（**= 包序号**） | `u16` 随机 |
/// | 5 | `u32` 随机 | `u32` 随机 |
/// | 6 | 同步 cookie（见 [buildSyncCookie]） | —— |
/// | 8 | —— | `0` |
///
/// `rich = {2: elems}`（参考实现里还带一个 `4: null`，编码期被跳过；
/// 本实现不写死字段，行为等价）。`elems` = 各消息元素，末尾必须追加
/// **保留元素** `PB_RESERVER = {37:{17:0, 19:{15:0,31:0,41:0}}}`。
/// 纯文本元素 = `{1: {1: 文本}}`。
///
/// 响应（protobuf）：`{1: 结果码, 2: 错误文案, 3: 服务端时间}`；
/// 结果码 0 = 成功。
///
/// ## 证据等级
///
/// 逐行对照新版参考实现（js 时代那份没有发消息的 pb 路径），**没有黄金向量**；
/// 离线自测只保证"结构自洽 + 与参考字段一一对应"，最终裁判是服务端。
///
/// 2026-09-12 用官方 8.9.50 的 pb 定义（`msf/msgsvc/msg_svc$PbSendMsgReq.java`
/// 与 `$RoutingHead.java` 的 `__fieldMap__`）逐字段核对过，字段号/类型全对：
///
/// * `PbSendMsgReq`：1 routing_head / 2 content_head / 3 msg_body / 4 msg_seq /
///   5 msg_rand / 6 sync_cookie / 8 msg_via；
/// * `RoutingHead`：**1=c2c（`{1: to_uin}`）/ 2=grp（`{1: group_code}`）/
///   4=dis（`{1: dis_uin}`，讨论组）**。
///
/// ⚠️ 据此修正过一处真错：群聊路由原先写 `{4: {1: gid}}`——那是参考实现
/// `Discuss`（讨论组）类的写法（`group.ts` 的 `class Discuss`），
/// 普通群应是 `{2: {1: gid}}`（同文件 `Group.sendMsg`）。
///
/// 本文件是纯 Dart。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../infra/coder.dart';
import 'qq8_elem.dart';
import 'qq8_jce.dart';
import 'qq8_pb.dart';

/// 引用回复的"被引用消息"信息（发出去的那个 `src_msg` 元素用它）。
class Qq8ReplyInfo {
  /// 被引用消息的序号。
  final int seq;

  /// 被引用消息的发送者 uin。
  final int senderUin;

  /// 被引用消息的时间（秒）。
  final int time;

  /// 引用条里显示的文本（取不到就是空串）。
  final String preview;

  const Qq8ReplyInfo({
    required this.seq,
    required this.senderUin,
    required this.time,
    this.preview = '',
  });
}

/// 一次发送的结果。
class Qq8MsgSendResult {
  /// 结果码（0 = 成功）。
  final int code;

  /// 错误文案（失败时服务端给的，可能为空）。
  final String message;

  /// 服务端时间（秒；私聊有，群聊参考实现不解析）。
  final int time;

  /// 本次用的消息 seq 与随机数（私聊用来算 message_id）。
  final int seq;
  final int rand;

  const Qq8MsgSendResult({
    required this.code,
    required this.message,
    required this.time,
    required this.seq,
    required this.rand,
  });

  bool get ok => code == 0;
}

/// 发消息（`MessageSvc.PbSendMsg`, 目前只有纯文本）。
abstract final class Qq8Msg {
  /// UNI 命令字。
  static const String sendCmd = 'MessageSvc.PbSendMsg';

  /// 固定内容头（参考实现 `common.ts` 的 `PB_CONTENT`）。
  static final Uint8List pbContent = Qq8Pb.encode(<int, Object?>{
    1: 1,
    2: 0,
    3: 0,
  });

  /// 每条消息末尾的保留元素（参考实现 `converter.ts` 的 `PB_RESERVER`）。
  static final Uint8List pbReserver = Qq8Pb.encode(<int, Object?>{
    37: <int, Object?>{
      17: 0,
      19: <int, Object?>{15: 0, 31: 0, 41: 0},
    },
  });

  /// 文本元素（`Elem.text`，字段 1）。
  static Uint8List textElem(String text) => Qq8Pb.encode(<int, Object?>{
        1: <int, Object?>{1: text},
      });

  /// 表情元素。id ≤ 0xFF 走 `Elem.face`（字段 2），更大的"超级表情"走
  /// `Elem.common_elem`（字段 53）。
  ///
  /// 两个分支的字段号与"兼容尾巴"都来自参考实现 `converter.ts` 的 `face()`：
  /// 小表情要带上旧版表情码（`0x1441 + id` 的 u16）和固定尾巴 `FACE_OLD_BUF`，
  /// 少了官方客户端那头会显示不出来；超级表情的 `2: {1: id, 2/3: 名字}` 里
  /// 名字是**服务端要回显的文案**，用 [Qq8FaceNames] 查，查不到退回 `/{id}`。
  static Uint8List faceElem(int id) {
    if (id <= 0xFF) {
      final old = Uint8List.fromList(<int>[0x14, 0x41 + id]);
      return Qq8Pb.encode(<int, Object?>{
        2: <int, Object?>{
          1: id,
          2: old,
          11: Uint8List.fromList(
              const <int>[0x00, 0x01, 0x00, 0x04, 0x52, 0xCC, 0xF5, 0xD0]),
        },
      });
    }
    final name = Qq8FaceNames.nameOf('$id') ?? '/$id';
    return Qq8Pb.encode(<int, Object?>{
      53: <int, Object?>{
        1: 33, // serviceType = 33：大表情
        2: Qq8Pb.encode(<int, Object?>{1: id, 2: name, 3: name}),
        3: 1,
      },
    });
  }

  /// 推送回执的命令字（**我们要发出去的**）。
  static const String respPushCmd = 'OnlinePush.RespPush';

  /// 推送回执：告诉服务端"这条推送我收到了"。
  ///
  /// 结构照参考实现 `onlinepush.ts` 的 `handleOnlinePush`：
  /// ```js
  /// const resp = jce.encodeStruct([this.uin, items, svrip & 0xffffffff, null, 0])
  /// const body = jce.encodeWrapper({ resp }, "OnlinePush", "SvcRespPushMsg", seq)
  /// this.writeUni("OnlinePush.RespPush", body)
  /// ```
  /// * `items` 是"没收到、要服务端重发的消息"，正常处理完就是**空列表**；
  /// * 第 4 个字段（iRequestId）= 推送的 seq；
  /// * 只对 `Qq8MessagePush.needsAck` 的推送发（多端同步 / 讨论组；
  ///   `PbPushC2CMsg` 与 `PbPushGroupMsg` 参考实现都不回）。
  ///
  /// ⚠️ 真机没验证过：这条回执是"收消息链路的最后一环"，第一次真机上线时
  /// 如果消息被反复重推，先看这里的日志。
  static Uint8List buildRespPushAck({
    required int uin,
    required int svrip,
    required int seq,
  }) =>
      Qq8Jce.encodeWrapper(
        service: 'OnlinePush',
        method: 'SvcRespPushMsg',
        requestId: seq,
        attributes: <String, Uint8List>{
          'r': Qq8Jce.encodeStruct(<int, Object?>{
            0: uin,
            1: <Object?>[], // items：空
            2: svrip & 0xFFFFFFFF,
            // 3 号参考实现给 null（不写这个字段）
            4: 0,
          }),
        },
      );

  /// 把有序的内容元素编成 `RichText`：`{2: [引用?, ...元素, 保留元素]}`。
  ///
  /// 顺序就是元素在消息里的顺序——文本和表情可以交替，别指望在这里排序。
  static Uint8List richElems(List<Uint8List> elems, {Qq8ReplyInfo? reply}) =>
      Qq8Pb.encode(<int, Object?>{
        2: <Object?>[
          if (reply != null) srcMsgElem(reply),
          ...elems,
          pbReserver,
        ],
      });

  /// 纯文本的 `rich`（即 `{2: elems}` 编码后的字节）。
  static Uint8List textRich(String text, {Qq8ReplyInfo? reply}) =>
      richElems(<Uint8List>[textElem(text)], reply: reply);

  /// 引用回复元素（`Elem` 字段 45 → 官方 `im_msg_body.SourceMsg`）。
  ///
  /// 官方 8.9.50 的 `SourceMsg` 字段：`1 uint32_orig_seqs / 2 uint64_sender_uin /
  /// 3 uint32_time / 4 uint32_flag / 5 elems（被引用消息的元素）/ 6 uint32_type`。
  /// 参考实现里那个 `8: {3: rand2uuid}` 是旧版本字段（官方 8 号是
  /// `bytes_pb_reserve`），**不发**。
  ///
  /// [Qq8ReplyInfo.preview] 作为被引用消息的唯一元素带上——官方客户端会拿它
  /// 渲染引用条；真机上若显示异常，先看这里。
  static Uint8List srcMsgElem(Qq8ReplyInfo reply) => Qq8Pb.encode(<int, Object?>{
        45: <int, Object?>{
          1: reply.seq & 0xFFFFFFFF,
          2: reply.senderUin,
          3: reply.time & 0xFFFFFFFF,
          4: 1, // flag：参考实现固定 1
          5: <Uint8List>[
            Qq8Pb.encode(<int, Object?>{
              1: <int, Object?>{1: reply.preview},
            }),
          ],
          6: 0, // type
        },
      });

  /// 同步 cookie（参考实现 `internal/pbgetmsg.ts` 的 `buildSyncCookie`）。
  ///
  /// [seed] 取会话标识的前 4 字节（u32）；三个随机数由调用方注入，便于自测。
  static Uint8List buildSyncCookie({
    required int seed,
    required int nowSeconds,
    required int r5,
    required int r9,
    required int r11,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: nowSeconds,
        2: nowSeconds,
        3: seed,
        4: (0xFFFFFFFF - seed) & 0xFFFFFFFF,
        5: r5,
        9: r9,
        11: r11,
        12: seed & 0xFF,
        13: nowSeconds,
        14: 0,
      });

  /// 私聊请求体。
  ///
  /// [elems] 是**有序的内容元素**（文本/表情…），引用元素由 [reply] 单独给，
  /// 组装顺序由 [richElems] 负责。
  /// [seq] 必须与包序号一致（见 `Qq8Session.sendUni` 的 `seq` 参数）。
  static Uint8List buildC2cTextBody({
    required int uid,
    required List<Uint8List> elems,
    required int seq,
    required int rand,
    required int syncCookieSeed,
    required int nowSeconds,
    required int syncR5,
    required int syncR9,
    required int syncR11,
    Qq8ReplyInfo? reply,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: <int, Object?>{
          1: <int, Object?>{1: uid},
        },
        2: pbContent,
        3: <int, Object?>{
          1: richElems(elems, reply: reply),
        },
        4: seq,
        5: rand,
        6: buildSyncCookie(
          seed: syncCookieSeed,
          nowSeconds: nowSeconds,
          r5: syncR5,
          r9: syncR9,
          r11: syncR11,
        ),
      });

  /// 群聊请求体（普通群，路由 `RoutingHead.grp`）。
  ///
  /// ⚠️ 群的 tag4 是 **u16 随机**、tag5 是 u32 随机，且没有同步 cookie、
  /// 多一个 `8: 0`（参考实现 `group.ts` 的 `Group.sendMsg`）。
  static Uint8List buildGroupTextBody({
    required int gid,
    required List<Uint8List> elems,
    required int rand16,
    required int rand32,
    Qq8ReplyInfo? reply,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: <int, Object?>{
          // RoutingHead.grp（字段 2）：普通群。讨论组才是字段 4（dis）。
          2: <int, Object?>{1: gid},
        },
        2: pbContent,
        3: <int, Object?>{
          1: richElems(elems, reply: reply),
        },
        4: rand16,
        5: rand32,
        8: 0,
      });

  /// 解析发送响应（protobuf）：`{1: 结果码, 2: 错误文案, 3: 时间}`。
  static Qq8MsgSendResult parseSendResponse(
    Uint8List payload, {
    required int seq,
    required int rand,
  }) {
    final m = Qq8Pb.decode(payload);
    return Qq8MsgSendResult(
      code: Qq8Pb.intAt(m, 1) ?? -1,
      message: Qq8Pb.textAt(m, 2) ?? '',
      time: Qq8Pb.intAt(m, 3) ?? 0,
      seq: seq,
      rand: rand,
    );
  }

  /// 群号 → uin 的变换（参考实现 `common.ts` 的 `code2uin`）。
  ///
  /// ⚠️ **只有讨论组（discuss）路由用得上**（`{3: {1: code2uin(gid), 2: uid}}`）；
  /// 普通群走 `{4: {1: gid}}`，不需要这个变换。将来做讨论组再接线。
  static int code2uin(int code) {
    var left = code ~/ 1000000;
    if (left >= 0 && left <= 10) {
      left += 202;
    } else if (left >= 11 && left <= 19) {
      left += 469;
    } else if (left >= 20 && left <= 66) {
      left += 2080;
    } else if (left >= 67 && left <= 156) {
      left += 1943;
    } else if (left >= 157 && left <= 209) {
      left += 1990;
    } else if (left >= 210 && left <= 309) {
      left += 3890;
    } else if (left >= 310 && left <= 335) {
      left += 3490;
    } else if (left >= 336 && left <= 386) {
      left += 2265;
    } else if (left >= 387 && left <= 499) {
      left += 3490;
    }
    return left * 1000000 + code % 1000000;
  }

  /// 文本消息的预览串（对应参考实现的 `brief`，用于日志/列表）。
  static String brief(String text) {
    final t = text.replaceAll('\n', ' ');
    return t.length <= 60 ? t : '${t.substring(0, 60)}…';
  }

  /// 调试用：把请求体解成可读结构（自测与排查）。
  static String describeBody(Uint8List body) {
    final m = Qq8Pb.decode(body);
    final route = Qq8Pb.bytesAt(m, 1);
    final rich = Qq8Pb.bytesAt(m, 3);
    return 'route=${route?.length ?? 0}B rich=${rich?.length ?? 0}B '
        't4=${Qq8Pb.intAt(m, 4)} t5=${Qq8Pb.intAt(m, 5)} '
        't6=${Qq8Pb.bytesAt(m, 6)?.length ?? 0}B t8=${Qq8Pb.intAt(m, 8)}';
  }

  /// 纯文本消息的 UTF-8 字节（便于调用方统计长度/分片）。
  static Uint8List textBytes(String text) => Uint8List.fromList(utf8.encode(text));

  /// 私聊消息 ID（参考实现 `genDmMessageId` 同款打包，base64）。
  ///
  /// `u32 对方uin ‖ u32 seq ‖ u32 rand ‖ u32 time ‖ u8 flag`（flag：0 收到 / 1 自己发）。
  /// 收到的消息走 `Qq8IncomingMessage.messageId`，自己发的（发送响应里有
  /// seq/rand/time）走这里——**两边必须是同一套**，否则回显配对会错位。
  static String dmMessageId({
    required int peerUin,
    required int seq,
    required int rand,
    required int time,
    required bool outgoing,
  }) =>
      base64.encode((ByteWriter()
            ..u32(peerUin & 0xFFFFFFFF)
            ..u32(seq & 0xFFFFFFFF)
            ..u32(rand & 0xFFFFFFFF)
            ..u32(time & 0xFFFFFFFF)
            ..u8(outgoing ? 1 : 0))
          .build());

  /// 群消息 ID（参考实现 `genGroupMessageId` 同款打包，base64）。
  ///
  /// `u32 群号 ‖ u32 发送者uin ‖ u32 seq ‖ u32 rand ‖ u32 time ‖ u8 pktnum`。
  /// 分片消息把 [pktNum] 写进去（>1 表示这是第几片）。
  static String groupMessageId({
    required int gid,
    required int senderUin,
    required int seq,
    required int rand,
    required int time,
    int pktNum = 1,
  }) =>
      base64.encode((ByteWriter()
            ..u32(gid & 0xFFFFFFFF)
            ..u32(senderUin & 0xFFFFFFFF)
            ..u32(seq & 0xFFFFFFFF)
            ..u32(rand & 0xFFFFFFFF)
            ..u32(time & 0xFFFFFFFF)
            ..u8(pktNum > 1 ? pktNum : 1))
          .build());

  // -------------------------------------------------------------------------
  // 消息 ID 反解（撤回 / 已读上报要拿 seq/rand/time 去定位消息）
  // -------------------------------------------------------------------------

  /// 解私聊消息 ID（[dmMessageId] 的逆运算）。格式不对返回 null。
  static ({int peerUin, int seq, int rand, int time, int flag})? parseDmMessageId(
    String id,
  ) {
    try {
      final b = base64.decode(id);
      if (b.length < 17) return null;
      int u32(int i) =>
          ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) &
          0xFFFFFFFF;
      return (
        peerUin: u32(0),
        seq: u32(4),
        rand: u32(8),
        time: u32(12),
        flag: b[16],
      );
    } on Object {
      return null;
    }
  }

  /// 解群消息 ID（[groupMessageId] 的逆运算）。格式不对返回 null。
  static ({int gid, int senderUin, int seq, int rand, int time, int pktNum})?
      parseGroupMessageId(String id) {
    try {
      final b = base64.decode(id);
      if (b.length < 21) return null;
      int u32(int i) =>
          ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) &
          0xFFFFFFFF;
      return (
        gid: u32(0),
        senderUin: u32(4),
        seq: u32(8),
        rand: u32(12),
        time: u32(16),
        pktNum: b[20],
      );
    } on Object {
      return null;
    }
  }

  /// 消息 rand → `msg_uid`（参考实现 `rand2uuid`：高位固定 `16777216 << 32`）。
  static int rand2uuid(int rand) => (16777216 << 32) | (rand & 0xFFFFFFFF);

  // -------------------------------------------------------------------------
  // 撤回（`PbMessageSvc.PbMsgWithDraw`）
  // -------------------------------------------------------------------------

  /// 撤回命令字。私聊与群共用它，靠**外层字段**区分：1 = 私聊、2 = 群。
  static const String withdrawCmd = 'PbMessageSvc.PbMsgWithDraw';

  /// 私聊撤回体。
  ///
  /// 外层 `1:` 是私聊分支；里面就是官方 `PbC2CMsgWithDrawReq`：
  /// `1 msg_info`（`MsgInfo{1 from_uin, 2 to_uin, 3 msg_seq, 4 msg_uid,
  /// 5 msg_time, 6 msg_random, 7 pkg_num, 8 pkg_index, 9 div_seq, 10 msg_type}`）、
  /// `2 uint32_long_message_flag`、`3 bytes_reserved`。
  ///
  /// 我们填 from/to/seq/uid/time/rand 六项（`msg_uid` 用 [rand2uuid] 重建，
  /// 参考实现同款）；`pkg_*`/`div_seq`/`msg_type` 留默认，
  /// `bytes_reserved` 官方是 bytes、内容只有旧参考实现有（`{1: 0|1}`），
  /// **不发**（等真机确认要不要）。
  static Uint8List buildC2cWithdrawBody({
    required int selfUin,
    required int peerUin,
    required int seq,
    required int rand,
    required int time,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: <int, Object?>{
          1: <int, Object?>{
            1: selfUin,
            2: peerUin,
            3: seq & 0xFFFFFFFF,
            4: rand2uuid(rand),
            5: time & 0xFFFFFFFF,
            6: rand & 0xFFFFFFFF,
          },
          2: 0, // long_message_flag
        },
      });

  /// 群撤回体。
  ///
  /// 外层 `2:` 是群分支；里面就是官方 `PbGroupMsgWithDrawReq`：
  /// `1 uint32_sub_cmd`（参考实现填 1）、`2 uint32_group_type`（0）、
  /// `3 uint64_group_code`、`4 msg_list`（`MessageInfo{1 序号, 2 随机数}`）、
  /// `5 bytes_userdef`。
  ///
  /// ⚠️ 只支持**单包**消息（分片消息的撤回体参考实现另有一套写法，
  /// 与官方 `MessageInfo` 字段对不上，等真机再说）。
  static Uint8List buildGroupWithdrawBody({
    required int gid,
    required int seq,
    required int rand,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        2: <int, Object?>{
          1: 1, // sub_cmd
          2: 0, // group_type
          3: gid & 0xFFFFFFFF,
          4: <int, Object?>{
            1: seq & 0xFFFFFFFF,
            2: rand & 0xFFFFFFFF,
          },
        },
      });

  /// 解析撤回响应。返回 `(result, errmsg)`。
  ///
  /// 响应与请求同构（外层 1 = 私聊、2 = 群）。参考实现的成功判据是
  /// 私聊 `result <= 2`、群 `result == 0`——**「≤2 也算成功」是它那代的经验**，
  /// 这里原样回传 result，判据交给调用方。
  static ({int result, String errmsg}) parseWithdrawResponse(
    Uint8List payload, {
    required bool group,
  }) {
    final m = Qq8Pb.decode(payload);
    final inner = Qq8Pb.bytesAt(m, group ? 2 : 1);
    if (inner == null) {
      return (result: -1, errmsg: '响应里没有${group ? '群' : '私聊'}分支');
    }
    final r = Qq8Pb.decode(inner);
    return (
      result: Qq8Pb.intAt(r, 1) ?? -1,
      errmsg: Qq8Pb.textAt(r, 2) ?? '',
    );
  }

  // -------------------------------------------------------------------------
  // 已读上报（`PbMessageSvc.PbMsgReadedReport`）
  // -------------------------------------------------------------------------

  /// 已读上报命令字。
  static const String readedReportCmd = 'PbMessageSvc.PbMsgReadedReport';

  /// 私聊已读体：`3 c2c_read_report` → `2 pair_info` →
  /// `UinPairReadInfo{1 peer_uin, 2 last_read_time}`（官方字段名，逐项核过）。
  static Uint8List buildC2cReadReportBody({
    required int peerUin,
    required int lastReadTime,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        3: <int, Object?>{
          2: <int, Object?>{
            1: peerUin,
            2: lastReadTime & 0xFFFFFFFF,
          },
        },
      });

  /// 群已读体：`1 grp_read_report` → `{1 group_code, 2 last_read_seq}`。
  static Uint8List buildGroupReadReportBody({
    required int gid,
    required int lastReadSeq,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: <int, Object?>{
          1: gid & 0xFFFFFFFF,
          2: lastReadSeq & 0xFFFFFFFF,
        },
      });
}
