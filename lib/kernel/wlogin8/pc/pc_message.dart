/// PC NTQQ 收消息：解析服务端推送 `trpc.msg.olpush.OlPushService.MsgPush` 的 `PushMsg`。
///
/// 结构（对齐 acidify `PushMsg/CommonMessage/RoutingHead/ContentHead/MessageBody/RichText/Elem/Text`）：
///   PushMsg{1:CommonMessage}
///   CommonMessage{1:RoutingHead, 2:ContentHead, 3:MessageBody}
///   RoutingHead{1:fromUin,2:fromUid,5:toUin,6:toUid,8:group{1:groupCode,7:groupName}}
///   ContentHead{1:type,2:subType,5:sequence,6:time,11:clientSequence,12:msgUid}
///   MessageBody{1:RichText} → RichText{2:elems[]} → Elem{1:text} → Text{1:textMsg}
library;

import 'dart:typed_data';

import 'pc_proto.dart';

class PcMessage {
  const PcMessage({
    required this.type,
    required this.subType,
    required this.fromUin,
    required this.toUin,
    required this.groupCode,
    required this.groupName,
    required this.time,
    required this.sequence,
    required this.clientSequence,
    required this.msgUid,
    required this.text,
    required this.isGroup,
  });

  final int type;
  final int subType;
  final int fromUin;
  final int toUin;
  final int groupCode;
  final String groupName;
  final int time;
  final int sequence;
  final int clientSequence;
  final int msgUid;
  final String text;
  final bool isGroup;

  @override
  String toString() =>
      'PcMessage(isGroup=$isGroup group=$groupCode from=$fromUin type=$type '
      'time=$time seq=$sequence text="$text")';
}

abstract final class PcMessageService {
  static const String msgPushCmd = 'trpc.msg.olpush.OlPushService.MsgPush';
  static const String pushAckCmd = 'trpc.msg.olpush.OlPushService.SsoPushAck';

  /// PushMsgType（acidify）：166 好友、82 群、141 临时。
  static const int typeFriend = 166;
  static const int typeGroup = 82;
  static const int typeTemp = 141;

  static PcMessage parsePushMsg(Uint8List bytes) {
    // PushMsg{1: message}
    final push = PbReader(bytes);
    Uint8List? msgBytes;
    while (!push.atEnd) {
      final (f, w) = push.readTag();
      if (f == 1) {
        msgBytes = push.readBytes();
      } else {
        push.skip(w);
      }
    }
    if (msgBytes == null) throw const FormatException('PushMsg 缺 message');
    return parseCommonMessage(msgBytes);
  }

  /// 解析 `CommonMessage`（拉历史消息也用同一结构）。
  static PcMessage parseCommonMessage(Uint8List bytes) {
    Uint8List? routing, content, body;
    final cm = PbReader(bytes);
    while (!cm.atEnd) {
      final (f, w) = cm.readTag();
      if (f == 1) {
        routing = cm.readBytes();
      } else if (f == 2) {
        content = cm.readBytes();
      } else if (f == 3) {
        body = cm.readBytes();
      } else {
        cm.skip(w);
      }
    }

    // RoutingHead
    var fromUin = 0, toUin = 0, groupCode = 0;
    var groupName = '';
    if (routing != null) {
      final r = PbReader(routing);
      while (!r.atEnd) {
        final (f, w) = r.readTag();
        if (f == 1) {
          fromUin = r.readVarint();
        } else if (f == 5) {
          toUin = r.readVarint();
        } else if (f == 8) {
          final g = PbReader(r.readBytes());
          while (!g.atEnd) {
            final (gf, gw) = g.readTag();
            if (gf == 1) {
              groupCode = g.readVarint();
            } else if (gf == 7) {
              groupName = g.readString();
            } else {
              g.skip(gw);
            }
          }
        } else {
          r.skip(w);
        }
      }
    }

    // ContentHead
    var type = 0, subType = 0, time = 0, sequence = 0, clientSeq = 0, msgUid = 0;
    if (content != null) {
      final c = PbReader(content);
      while (!c.atEnd) {
        final (f, w) = c.readTag();
        if (f == 1) {
          type = c.readVarint();
        } else if (f == 2) {
          subType = c.readVarint();
        } else if (f == 5) {
          sequence = c.readVarint();
        } else if (f == 6) {
          time = c.readVarint();
        } else if (f == 11) {
          clientSeq = c.readVarint();
        } else if (f == 12) {
          msgUid = c.readVarint();
        } else {
          c.skip(w);
        }
      }
    }

    // MessageBody → RichText → Elems → text
    final buf = StringBuffer();
    if (body != null) {
      _extractTextFromBody(body, buf);
    }

    return PcMessage(
      type: type,
      subType: subType,
      fromUin: fromUin,
      toUin: toUin,
      groupCode: groupCode,
      groupName: groupName,
      time: time,
      sequence: sequence,
      clientSequence: clientSeq,
      msgUid: msgUid,
      text: buf.toString(),
      isGroup: groupCode != 0,
    );
  }

  static void _extractTextFromBody(Uint8List body, StringBuffer out) {
    final b = PbReader(body);
    while (!b.atEnd) {
      final (f, w) = b.readTag();
      if (f == 1) {
        _extractTextFromRichText(b.readBytes(), out); // MessageBody.richText
      } else {
        b.skip(w);
      }
    }
  }

  static void _extractTextFromRichText(Uint8List rt, StringBuffer out) {
    final r = PbReader(rt);
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 2) {
        _extractTextFromElem(r.readBytes(), out); // RichText.elems[]
      } else {
        r.skip(w);
      }
    }
  }

  static void _extractTextFromElem(Uint8List e, StringBuffer out) {
    final r = PbReader(e);
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 1) {
        // Elem.text: Text{1:textMsg}
        final t = PbReader(r.readBytes());
        while (!t.atEnd) {
          final (tf, tw) = t.readTag();
          if (tf == 1) {
            out.write(t.readString());
          } else {
            t.skip(tw);
          }
        }
      } else {
        r.skip(w);
      }
    }
  }
}
