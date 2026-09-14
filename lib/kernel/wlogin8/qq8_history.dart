/// L2 协议内核：拉消息与历史（收消息的"主动取"那一半）
///
/// 推送是"服务端塞给你"，本模块是"你自己去取"：
///
/// | 命令字 | 用途 | 入口 |
/// |---|---|---|
/// | `MessageSvc.PbGetMsg` | 拉新消息（`PushNotify` 之后、上线时补漏） | [Qq8History.buildGetMsgBody] / [parseGetMsg] |
/// | `MessageSvc.PbGetOneDayRoamMsg` | 私聊历史（按时间往前翻页） | [Qq8History.buildOneDayRoamBody] / [parseOneDayRoam] |
/// | `MessageSvc.PbGetGroupMsg` | 群历史（按 seq 区间翻页） | [Qq8History.buildGroupMsgBody] / [parseGroupMsg] |
///
/// 解析出的消息统一走 [qq8ParseMsg]（与在线推送**同一套** `msg_comm.Msg` 解析）。
///
/// ## 字段号出处（官方 8.9.50 pb 定义，逐项核对）
///
/// ```text
/// msg_svc.PbGetMsgReq
///   1 sync_flag  2 sync_cookie(bytes)  3 ramble_flag  4 latest_ramble_number
///   5 other_ramble_number  6 online_sync_flag  7 context_flag
///   8 whisper_session_id  9 msg_req_type  10 pubaccount_cookie …
/// msg_svc.PbGetMsgResp
///   1 result  2 errmsg  3 sync_cookie  4 sync_flag  5 uin_pair_msgs  …
/// msg_comm.UinPairMsg（5 的每一项）
///   1 last_read_time  2 peer_uin  3 msg_completed  4 msg(repeated Msg)
///   5 unread_msg_num  8 c2c_type  9 service_type  11 uint64_to_tiny_id
/// msg_svc.PbGetOneDayRoamMsgReq
///   1 peer_uin  2 last_msgtime  3 random  4 read_cnt
/// msg_svc.PbGetOneDayRoamMsgResp
///   1 result  2 errmsg  3 peer_uin  4 last_msgtime  5 random  6 msg(repeated Msg)
///   7 iscomplete
/// msg_svc.PbGetGroupMsgReq
///   1 group_code  2 begin_seq  3 end_seq  4 filter  5 member_seq
///   6 public_group  7 shield_flag  8 save_traffic_flag
/// msg_svc.PbGetGroupMsgResp
///   1 result  2 errmsg  3 group_code  4 return_begin_seq  5 return_end_seq
///   6 msg(repeated Msg)
/// ```
///
/// 请求体取值（`sync_flag=0 / latest_ramble_number=20 / other_ramble_number=3 /
/// online_sync_flag=1 / context_flag=1 / msg_req_type=1`、群历史 `filter=0`、
/// 私聊历史 `random=0`）照参考实现 `lib/internal/pbgetmsg.ts` 与
/// `lib/friend.ts` / `lib/group.ts` 的 `getChatHistory`。
///
/// ⚠️ **没有真机样本**（还没上线成功）⇒ 无黄金向量，自测用手搓 pb 往返。
/// ⚠️ 拉取之后"消费"消息（参考实现会发 `MessageSvc.PbDeleteMsg`）与已读上报
/// （`PbMessageSvc.PbMsgReadedReport`）**本版未实现**：前者的 item 结构
/// （`PbDeleteMsgReq.MsgItem`）在反编译树里没落地，后者的嵌套字段号只有
/// 参考实现一侧的证据，等真机拿到响应再补。
///
/// 本文件是纯 Dart。
library;

import 'dart:typed_data';

import 'qq8_pb.dart';
import 'qq8_push.dart';

/// 一次拉取的通用结果头。
class Qq8HistoryPage {
  /// 服务端结果码（0 = 成功）。
  final int result;

  /// 错误文案（失败时）。
  final String? errmsg;

  /// 本次解出的消息（按服务端给的顺序）。
  final List<Qq8IncomingMessage> messages;

  /// 拉完后要回写到本地的同步 cookie（`PbGetMsgResp.sync_cookie`）。
  final Uint8List? syncCookie;

  /// 私聊历史：服务端说"这一天翻到头了"（`PbGetOneDayRoamMsgResp.iscomplete`）。
  final bool? isComplete;

  /// 群历史：服务端实际返回的 seq 区间。
  final int? returnBeginSeq;
  final int? returnEndSeq;

  const Qq8HistoryPage({
    required this.result,
    this.errmsg,
    this.messages = const <Qq8IncomingMessage>[],
    this.syncCookie,
    this.isComplete,
    this.returnBeginSeq,
    this.returnEndSeq,
  });

  bool get ok => result == 0;
}

/// `PbGetMsg` 的一个会话块：某个对端 + 它名下的消息。
class Qq8UinPairBlock {
  /// 对端 uin（私聊对象；群消息在 `uin_pair_msgs` 里也会出现，但 peer 是发消息的人）。
  final int peerUin;

  /// 该对端名下未读数（`UinPairMsg.unread_msg_num`）。
  final int unreadCount;

  /// 该对端名下的消息。
  final List<Qq8IncomingMessage> messages;

  const Qq8UinPairBlock({
    required this.peerUin,
    required this.unreadCount,
    required this.messages,
  });
}

/// `PbGetMsg` 的结果（按对端分组）。
class Qq8GetMsgPage {
  final int result;
  final String? errmsg;

  /// **必须回写**：下一次请求要带它（服务端靠它增量同步）。
  final Uint8List? syncCookie;

  final List<Qq8UinPairBlock> blocks;

  const Qq8GetMsgPage({
    required this.result,
    this.errmsg,
    this.syncCookie,
    this.blocks = const <Qq8UinPairBlock>[],
  });

  bool get ok => result == 0;

  /// 摊平成一条流（按会话块的顺序）。
  List<Qq8IncomingMessage> get messages =>
      <Qq8IncomingMessage>[for (final b in blocks) ...b.messages];
}

/// 拉消息与历史的组包 / 解析。
abstract final class Qq8History {
  /// `MessageSvc.PbGetMsg`。
  static const String cmdGetMsg = 'MessageSvc.PbGetMsg';

  /// `MessageSvc.PbGetOneDayRoamMsg`。
  static const String cmdOneDayRoam = 'MessageSvc.PbGetOneDayRoamMsg';

  /// `MessageSvc.PbGetGroupMsg`。
  static const String cmdGetGroupMsg = 'MessageSvc.PbGetGroupMsg';

  /// 拉新消息的请求体。
  ///
  /// [syncCookie] 空时服务端会给全量首个 cookie（首次登录用空、之后用响应里的）。
  static Uint8List buildGetMsgBody({
    Uint8List? syncCookie,
    int latestRambleNumber = 20,
    int otherRambleNumber = 3,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: 0, // sync_flag
        if (syncCookie != null && syncCookie.isNotEmpty) 2: syncCookie,
        3: 0, // ramble_flag
        4: latestRambleNumber,
        5: otherRambleNumber,
        6: 1, // online_sync_flag
        7: 1, // context_flag
        9: 1, // msg_req_type
      });

  /// 私聊历史请求体（`getChatHistory` 同款：只给 uin / 时间 / 条数）。
  static Uint8List buildOneDayRoamBody({
    required int peerUin,
    required int lastMsgTime,
    int readCnt = 20,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: peerUin,
        2: lastMsgTime,
        3: 0, // random
        4: readCnt,
      });

  /// 群历史请求体（按 seq 区间取；`endSeq=0` 由服务端补成"最新"）。
  static Uint8List buildGroupMsgBody({
    required int groupCode,
    required int beginSeq,
    required int endSeq,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: groupCode,
        2: beginSeq,
        3: endSeq,
        6: 0, // public_group
      });

  /// 解析 `PbGetMsg` 响应。
  static Qq8GetMsgPage parseGetMsg(Uint8List payload) {
    final m = Qq8Pb.decode(payload);
    final blocks = <Qq8UinPairBlock>[];
    for (final pair in m[5] ?? const <Object>[]) {
      if (pair is! Uint8List) continue;
      final p = Qq8Pb.decode(pair);
      final msgs = <Qq8IncomingMessage>[];
      for (final raw in p[4] ?? const <Object>[]) {
        if (raw is! Uint8List) continue;
        final msg = qq8ParseMsg(raw);
        if (msg != null) msgs.add(msg);
      }
      blocks.add(Qq8UinPairBlock(
        peerUin: Qq8Pb.intAt(p, 2) ?? 0,
        unreadCount: Qq8Pb.intAt(p, 5) ?? 0,
        messages: msgs,
      ));
    }
    return Qq8GetMsgPage(
      result: Qq8Pb.intAt(m, 1) ?? -1,
      errmsg: Qq8Pb.textAt(m, 2),
      syncCookie: Qq8Pb.bytesAt(m, 3),
      blocks: blocks,
    );
  }

  /// 解析私聊历史响应。
  static Qq8HistoryPage parseOneDayRoam(Uint8List payload) {
    final m = Qq8Pb.decode(payload);
    return Qq8HistoryPage(
      result: Qq8Pb.intAt(m, 1) ?? -1,
      errmsg: Qq8Pb.textAt(m, 2),
      isComplete: (Qq8Pb.intAt(m, 7) ?? 0) != 0,
      messages: _msgs(m[6], kindHint: Qq8IncomingKind.c2c),
    );
  }

  /// 解析群历史响应。
  static Qq8HistoryPage parseGroupMsg(Uint8List payload) {
    final m = Qq8Pb.decode(payload);
    return Qq8HistoryPage(
      result: Qq8Pb.intAt(m, 1) ?? -1,
      errmsg: Qq8Pb.textAt(m, 2),
      returnBeginSeq: Qq8Pb.intAt(m, 4),
      returnEndSeq: Qq8Pb.intAt(m, 5),
      messages: _msgs(m[6], kindHint: Qq8IncomingKind.group),
    );
  }

  static List<Qq8IncomingMessage> _msgs(
    Object? list, {
    required Qq8IncomingKind kindHint,
  }) {
    final out = <Qq8IncomingMessage>[];
    for (final raw in (list as List<Object>?) ?? const <Object>[]) {
      if (raw is! Uint8List) continue;
      final msg = qq8ParseMsg(raw, kindHint: kindHint);
      if (msg != null) out.add(msg);
    }
    return out;
  }
}
