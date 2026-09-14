/// L2 协议内核：在线推送（收消息 v1）
///
/// 登录上线后，服务端在**同一条长连接**上主动下发帧；会话层把"没人在等的帧"
/// 交给 [qq8ParsePush]，本文件把它们解成结构化事件。
///
/// ## 覆盖的命令字
///
/// | 命令字 | 含义 | 解成 |
/// |---|---|---|
/// | `OnlinePush.PbPushC2CMsg` | 私聊消息（直推） | [Qq8MessagePush] |
/// | `OnlinePush.PbC2CMsgSync` | 私聊消息（多端同步的回显） | [Qq8MessagePush] |
/// | `OnlinePush.PbPushGroupMsg` | 群消息 | [Qq8MessagePush] |
/// | `OnlinePush.PbPushDisMsg` | 讨论组消息 | [Qq8MessagePush] |
/// | `MessageSvc.PushForceOffline` / `StatSvc.ReqMSFOffline` | 被踢下线 | [Qq8KickPush] |
/// | `MessageSvc.PushNotify` | "有新消息，去拉"通知 | [Qq8NotifyPush] |
/// | 其它 | —— | [Qq8UnknownPush]（原样留给上层） |
///
/// ## 字段号出处（官方 8.9.50 pb 定义，逐项核对过）
///
/// ```text
/// msf.onlinepush.PbPushMsg
///   1 = msg（msg_comm.Msg；字节串，需再解一层）
///   2 = svrip   3 = bytes_push_token   4 = ping_flag
///   9 = uint32_general_flag             10 = uint64_bind_uin
/// msf.msgcomm.msg_comm.Msg
///   1 = msg_head   2 = content_head   3 = msg_body
/// msg_comm.MsgHead
///   1 = from_uin   2 = to_uin   3 = msg_type   4 = c2c_cmd
///   5 = msg_seq    6 = msg_time 7 = msg_uid
///   8 = c2c_tmp_msg_head（1=c2c_type 2=service_type 3=group_uin 4=group_code）
///   9 = group_info（1=group_code … 8=group_name）
///   13 = discuss_info（1=discuss_uin）
///   14 = from_nick
/// msg_comm.ContentHead
///   1 = pkg_num   2 = pkg_index   3 = div_seq   4 = auto_reply
/// im_msg_body.MsgBody
///   1 = rich_text
/// im_msg_body.RichText
///   1 = attr   2 = elems（repeated）
/// im_msg_body.Elem            ← 见 `qq8_elem.dart`（图片/表情/@ 的字段号与出处都在那）
/// im_msg_body.Attr
///   3 = random（消息 rand！）  9 = font_name
/// ```
///
/// 读法交叉验证：参考实现 `lib/internal/onlinepush.ts`（命令字注册）+ 
/// `lib/message/message.ts` / `parser.ts`（`rand = attr[3] || msg_uid 低 32 位`、
/// `text = elem.text.str`、`@` 信息在 `text[3]`）。
///
/// ⚠️ **没有真机推送样本**（我们还没上线成功），所以本模块没有黄金向量：
/// 自测用官方字段号手搓 pb 做往返。真机第一次收到推送时若字段对不上，
/// 先看 [Qq8UnknownPush.note] 与 `qq8-*.log` 里的原始帧。
///
/// 回执（`OnlinePush.RespPush`）：`PbC2CMsgSync` / 讨论组的推送要回一个空 items
/// 的回执（`PbPushGroupMsg` 不回）——见 [Qq8MessagePush.needsAck]。组包在
/// `Qq8Msg.buildRespPushAck`，由服务层在收到推送后发出去。
///
/// 本文件是纯 Dart。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'qq8_elem.dart';
import 'qq8_jce.dart';
import 'qq8_msg.dart';
import 'qq8_pb.dart';

/// 推送命令字。
abstract final class Qq8PushCmd {
  /// 私聊消息直推。
  static const String pushC2c = 'OnlinePush.PbPushC2CMsg';

  /// 私聊消息多端同步（自己别的端发的）。
  static const String c2cSync = 'OnlinePush.PbC2CMsgSync';

  /// 群消息。
  static const String pushGroup = 'OnlinePush.PbPushGroupMsg';

  /// 讨论组消息。
  static const String pushDiscuss = 'OnlinePush.PbPushDisMsg';

  /// 被踢下线（服务端）。
  static const String forceOffline = 'MessageSvc.PushForceOffline';

  /// 被踢下线（MSF）。
  static const String reqMsfOffline = 'StatSvc.ReqMSFOffline';

  /// 有新消息通知（JCE，要再去拉）。
  static const String notify = 'MessageSvc.PushNotify';

  /// 已读回执推送。
  static const String pushReaded = 'MessageSvc.PushReaded';

  /// 推送回执（**我们要发出去的**）。
  static const String respPush = 'OnlinePush.RespPush';
}

/// 会话类型。
enum Qq8IncomingKind { c2c, group, discuss }

/// 一条收到的消息（结构化）。
class Qq8IncomingMessage {
  final Qq8IncomingKind kind;

  /// 发送者 uin（群消息里 = 群成员 uin）。
  final int fromUin;

  /// 接收者 uin（群消息里通常 = 自己的 uin）。
  final int toUin;

  /// 群号：普通群来自 `group_info`，群临时会话来自 `c2c_tmp_msg_head.group_code`。
  final int? groupCode;

  /// 讨论组号（`discuss_info.discuss_uin`）。
  final int? discussUin;

  /// 消息序号（`msg_head.msg_seq`）。
  final int seq;

  /// 消息随机数：优先 `rich_text.attr.random`，缺失时取 `msg_uid` 低 32 位。
  final int rand;

  /// 服务端时间（秒）。
  final int time;

  /// `msg_head.msg_type`（82 = 群、83 = 讨论组、其余为私聊）。
  final int msgType;

  /// `msg_head.c2c_cmd`（141 = 来自群的临时会话）。
  final int c2cCmd;

  /// 文本内容（各 text 元素拼接；`@` 取元素自带文本，没有再退回 `@uin`）。
  final String text;

  /// 被 @ 的 uin 列表（`text.attr_6_buf` 里解出的目标；可能多个）。
  final List<int> atTargets;

  /// 是否 @ 全体成员。
  final bool atAll;

  /// 字体名（`attr.font_name`，缺省 `unknown`）。
  final String font;

  /// 分片：包序号 / 包内序号 / 分片键（`content_head` 1/2/3）。
  /// [pktNum] > 1 表示被分片，需要按 [divSeq] 归并。
  final int pktNum;
  final int pkgIndex;
  final int divSeq;

  /// 服务端给的发送者昵称（`msg_head.from_nick`，群消息里常见）。
  final String? fromNick;

  /// 群名（`group_info.group_name`）。
  final String? groupName;

  /// 扫到的元素类型名（`text`/`at`/`face`/`image`/`xml`/`unknown(53)`…），
  /// 用于日志与"这条消息我们只理解了一部分"的判断。
  final List<String> elemKinds;

  /// 解析出来的元素（有序）：文本 / @ / 表情 / 图片。
  ///
  /// 与 [text] 的关系：`text` 是**线上纯文本**（图片这类没有文本的元素会在
  /// 那里留一个 `[图片]` 占位），[elems] 才是给 UI 渲染的结构。两者各司其职，
  /// 不要拿其中一个去推另一个。
  final List<Qq8Elem> elems;

  const Qq8IncomingMessage({
    required this.kind,
    required this.fromUin,
    required this.toUin,
    this.groupCode,
    this.discussUin,
    required this.seq,
    required this.rand,
    required this.time,
    required this.msgType,
    required this.c2cCmd,
    required this.text,
    required this.atTargets,
    required this.atAll,
    required this.font,
    required this.pktNum,
    required this.pkgIndex,
    required this.divSeq,
    this.fromNick,
    this.groupName,
    required this.elemKinds,
    this.elems = const <Qq8Elem>[],
  });

  /// 是不是自己发的（多端同步回显 / 自己发的群消息）。
  bool isSelf(int selfUin) => fromUin == selfUin;

  /// 有没有 @ 到我（`@全体成员` 单列，见 [mentions]）。
  bool atMe(int selfUin) => atTargets.contains(selfUin);

  /// 这条消息是否"提及我"（含 @全体成员）——UI 高亮用。
  bool mentions(int selfUin) => atAll || atMe(selfUin);

  /// 会话标识：群 = 群号、讨论组 = 讨论组号、私聊 = 对方 uin。
  ///
  /// 私聊里"对方" = `fromUin == selfUin ? toUin : fromUin`。
  int chatId(int selfUin) => switch (kind) {
        Qq8IncomingKind.group => groupCode ?? 0,
        Qq8IncomingKind.discuss => discussUin ?? 0,
        Qq8IncomingKind.c2c => isSelf(selfUin) ? toUin : fromUin,
      };

  /// 消息 ID：私聊 `genDmMessageId` / 群 `genGroupMessageId`（参考实现同款）。
  ///
  /// 打包规则与"自己发出的消息"共用 [Qq8Msg.dmMessageId] / [Qq8Msg.groupMessageId]
  /// ——两边同一套，回显配对才对得上。
  String messageId(int selfUin) => kind == Qq8IncomingKind.group
      ? Qq8Msg.groupMessageId(
          gid: groupCode ?? 0,
          senderUin: fromUin,
          seq: seq,
          rand: rand,
          time: time,
          pktNum: pktNum,
        )
      : Qq8Msg.dmMessageId(
          peerUin: chatId(selfUin),
          seq: seq,
          rand: rand,
          time: time,
          outgoing: isSelf(selfUin),
        );

  /// 一句话摘要（日志用）。
  String brief({int maxChars = 60}) {
    final t = text.replaceAll('\n', ' ');
    final s = t.length <= maxChars ? t : '${t.substring(0, maxChars)}…';
    return '${kind.name} from=$fromUin${groupCode == null ? '' : ' gid=$groupCode'}'
        ' seq=$seq: $s';
  }
}

/// 推送事件（判别联合）。
sealed class Qq8PushEvent {
  /// 原始命令字。
  final String cmd;

  const Qq8PushEvent(this.cmd);
}

/// 收到一条消息。
final class Qq8MessagePush extends Qq8PushEvent {
  final Qq8IncomingMessage message;

  /// 服务端 IP（`PbPushMsg.svrip`，回执要带）。
  final int? svrip;

  /// 推送令牌（`PbPushMsg.bytes_push_token`，去重/回执用）。
  final Uint8List? pushToken;

  /// `PbPushMsg.ping_flag` / `uint32_general_flag`（原样带出）。
  final int? pingFlag;
  final int? generalFlag;

  /// 是否需要回 `OnlinePush.RespPush`。
  ///
  /// 参考实现的行为：`PbC2CMsgSync` 与讨论组回执、`PbPushGroupMsg` 不回；
  /// `PbPushC2CMsg` 官方命令表里有，但参考实现没注册，回执与否无证据——
  /// 这里按"不回"处理并记录，等真机验证。
  final bool needsAck;

  const Qq8MessagePush(
    super.cmd, {
    required this.message,
    this.svrip,
    this.pushToken,
    this.pingFlag,
    this.generalFlag,
    required this.needsAck,
  });
}

/// 被踢下线。
final class Qq8KickPush extends Qq8PushEvent {
  /// 服务端给的提示（`[标题]内容`，JCE 解不出时为空串）。
  final String hint;

  const Qq8KickPush(super.cmd, {required this.hint});
}

/// 有新消息通知（要去拉）。
final class Qq8NotifyPush extends Qq8PushEvent {
  /// JCE 包装里的推送类型（tag 5）：33 群员入群 / 38 建群 / 85 群申请通过 /
  /// 141 陌生人 / 166 好友 / 167 单向好友 / 208 好友语音 / 529 离线文件 …
  final int? notifyType;

  const Qq8NotifyPush(super.cmd, {required this.notifyType});
}

/// 我们不认识的推送（原样交给上层，附一句说明）。
final class Qq8UnknownPush extends Qq8PushEvent {
  final int payloadLength;

  /// 为什么没认出来（缺字段 / JCE 解不开 / 命令字没注册）。
  final String? note;

  const Qq8UnknownPush(super.cmd, {
    required this.payloadLength,
    this.note,
  });
}

/// 解析一条推送（纯函数）。
///
/// 畸形负载（pb 被截断等）会抛 [Qq8PbException]——调用方（会话/服务层）
/// 应在接收循环里兜底，别让一条坏包打断整个流。
Qq8PushEvent qq8ParsePush(String cmd, Uint8List payload) {
  switch (cmd) {
    case Qq8PushCmd.pushC2c:
    case Qq8PushCmd.c2cSync:
    case Qq8PushCmd.pushGroup:
    case Qq8PushCmd.pushDiscuss:
      return _parseMessagePush(cmd, payload);
    case Qq8PushCmd.forceOffline:
    case Qq8PushCmd.reqMsfOffline:
      return _parseKick(cmd, payload);
    case Qq8PushCmd.notify:
      return _parseNotify(cmd, payload);
    default:
      return Qq8UnknownPush(cmd,
          payloadLength: payload.length, note: '命令字未注册');
  }
}

// ---------------------------------------------------------------------------
// 内部：消息推送
// ---------------------------------------------------------------------------

Qq8PushEvent _parseMessagePush(String cmd, Uint8List payload) {
  final top = Qq8Pb.decode(payload);
  final msgBytes = Qq8Pb.bytesAt(top, 1);
  if (msgBytes == null) {
    return Qq8UnknownPush(cmd,
        payloadLength: payload.length, note: '没有 msg(1) 字段');
  }
  final kind = switch (cmd) {
    Qq8PushCmd.pushGroup => Qq8IncomingKind.group,
    Qq8PushCmd.pushDiscuss => Qq8IncomingKind.discuss,
    _ => Qq8IncomingKind.c2c,
  };
  final message = qq8ParseMsg(msgBytes, kindHint: kind);
  if (message == null) {
    return Qq8UnknownPush(cmd,
        payloadLength: payload.length, note: 'msg 里没有 msg_head(1)');
  }
  return Qq8MessagePush(
    cmd,
    message: message,
    svrip: Qq8Pb.intAt(top, 2),
    pushToken: Qq8Pb.bytesAt(top, 3),
    pingFlag: Qq8Pb.intAt(top, 4),
    generalFlag: Qq8Pb.intAt(top, 9),
    needsAck: cmd == Qq8PushCmd.c2cSync || cmd == Qq8PushCmd.pushDiscuss,
  );
}

/// 解析一条 `msg_comm.Msg`（**推送与拉历史共用**）。
///
/// [kindHint] 是来源命令字/接口给出的会话类型；不传就按 `msg_head.msg_type`
/// 判断（82 = 群、83 = 讨论组、其余私聊——参考实现 `Message.deserialize` 同款）。
/// `msg_head(1)` 缺失时返回 null（调用方决定怎么兜）。
Qq8IncomingMessage? qq8ParseMsg(
  Uint8List msgBytes, {
  Qq8IncomingKind? kindHint,
}) {
  final msg = Qq8Pb.decode(msgBytes);
  final headBytes = Qq8Pb.bytesAt(msg, 1);
  if (headBytes == null) return null;
  final head = Qq8Pb.decode(headBytes);

  final msgType = Qq8Pb.intAt(head, 3) ?? 0;
  final kind = kindHint ??
      switch (msgType) {
        82 => Qq8IncomingKind.group,
        83 => Qq8IncomingKind.discuss,
        _ => Qq8IncomingKind.c2c,
      };

  final uid = Qq8Pb.intAt(head, 7) ?? 0;
  var groupCode = _nestedInt(head, 9, 1);
  final groupName = _nestedText(head, 9, 8);
  final discussUin = _nestedInt(head, 13, 1);
  groupCode ??= _nestedInt(head, 8, 4); // c2c_tmp_msg_head.group_code

  final content = Qq8Pb.bytesAt(msg, 2);
  var pktNum = 1, pkgIndex = 0, divSeq = 0;
  if (content != null) {
    final c = Qq8Pb.decode(content);
    pktNum = Qq8Pb.intAt(c, 1) ?? 1;
    pkgIndex = Qq8Pb.intAt(c, 2) ?? 0;
    divSeq = Qq8Pb.intAt(c, 3) ?? 0;
  }

  var attrRand = 0;
  var hasAttrRand = false;
  var font = 'unknown';
  final scan = Qq8ElemScan();
  final bodyBytes = Qq8Pb.bytesAt(msg, 3);
  if (bodyBytes != null) {
    final richBytes = Qq8Pb.bytesAt(Qq8Pb.decode(bodyBytes), 1);
    if (richBytes != null) {
      final rich = Qq8Pb.decode(richBytes);
      final attrBytes = Qq8Pb.bytesAt(rich, 1);
      if (attrBytes != null) {
        final attr = Qq8Pb.decode(attrBytes);
        final r = Qq8Pb.intAt(attr, 3);
        if (r != null) {
          attrRand = r;
          hasAttrRand = true;
        }
        font = Qq8Pb.textAt(attr, 9) ?? 'unknown';
      }
      scan.scanAll(rich[2] ?? const <Object>[]);
      // 语音不在 elems 里，是 RichText.ptt（字段 4，见 qq8_elem.dart 的 scanPtt）
      final ptt = Qq8Pb.bytesAt(rich, 4);
      if (ptt != null && ptt.isNotEmpty) scan.scanPtt(ptt);
    }
  }

  return Qq8IncomingMessage(
    kind: kind,
    fromUin: Qq8Pb.intAt(head, 1) ?? 0,
    toUin: Qq8Pb.intAt(head, 2) ?? 0,
    groupCode: groupCode,
    discussUin: discussUin,
    seq: Qq8Pb.intAt(head, 5) ?? 0,
    rand: hasAttrRand ? attrRand : (uid & 0xFFFFFFFF),
    time: Qq8Pb.intAt(head, 6) ?? 0,
    msgType: msgType,
    c2cCmd: Qq8Pb.intAt(head, 4) ?? 0,
    text: scan.text.toString(),
    atTargets: scan.atTargets,
    atAll: scan.atAll,
    font: font,
    pktNum: pktNum,
    pkgIndex: pkgIndex,
    divSeq: divSeq,
    fromNick: Qq8Pb.textAt(head, 14),
    groupName: groupName,
    elemKinds: scan.kinds,
    elems: scan.elems,
  );
}

int? _nestedInt(Map<int, List<Object>> m, int tag, int sub) {
  final b = Qq8Pb.bytesAt(m, tag);
  return b == null ? null : Qq8Pb.intAt(Qq8Pb.decode(b), sub);
}

String? _nestedText(Map<int, List<Object>> m, int tag, int sub) {
  final b = Qq8Pb.bytesAt(m, tag);
  return b == null ? null : Qq8Pb.textAt(Qq8Pb.decode(b), sub);
}

// ---------------------------------------------------------------------------
// 内部：JCE 类推送
// ---------------------------------------------------------------------------

/// 被踢下线：`[标题]内容`（参考实现 `ssoListener` 同款）。
Qq8PushEvent _parseKick(String cmd, Uint8List payload) {
  try {
    final nested = Qq8Jce.decodeWrapper(payload);
    final kind = _str(nested[4]);
    final text = _str(nested[3]);
    final hint = kind != null
        ? '[$kind]${text ?? ''}'
        : '[${_str(nested[1]) ?? ''}]${_str(nested[2]) ?? ''}';
    return Qq8KickPush(cmd, hint: hint);
  } on Object catch (e) {
    return Qq8UnknownPush(cmd,
        payloadLength: payload.length, note: '被踢包 JCE 解不开：$e');
  }
}

/// 新消息通知：JCE 包装的 tag 5 = 推送类型。
///
/// 参考实现会先按 `payload[4:]` 解，失败再按 `payload[15:]` 解——服务端
/// 两种前缀都出现过，这里同序尝试。
Qq8PushEvent _parseNotify(String cmd, Uint8List payload) {
  for (final skip in const <int>[4, 15]) {
    if (payload.length <= skip) continue;
    try {
      final nested = Qq8Jce.decodeWrapper(payload.sublist(skip));
      return Qq8NotifyPush(cmd, notifyType: _int(nested[5]));
    } on Object {
      continue;
    }
  }
  try {
    final nested = Qq8Jce.decodeWrapper(payload);
    return Qq8NotifyPush(cmd, notifyType: _int(nested[5]));
  } on Object catch (e) {
    return Qq8UnknownPush(cmd,
        payloadLength: payload.length, note: '通知 JCE 解不开：$e');
  }
}

String? _str(Object? v) {
  if (v is String) return v;
  if (v is Uint8List) return utf8.decode(v, allowMalformed: true);
  return v == null ? null : '$v';
}

int? _int(Object? v) => v is int ? v : null;
