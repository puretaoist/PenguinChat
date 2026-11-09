/// PC 发消息：`MessageSvc.PbSendMsg`（对齐 acidify `SendFriendMessage/SendGroupMessage` + `PbSendMsg`）。
///
/// 请求 PbSendMsgReq：
///   1:routingHead{1:c2c{1:peerUin,2:peerUid} | 2:group{1:groupUin}}
///   2:contentHead{1:pkgNum=1}
///   3:messageBody{1:richText{2:elems[]}, elem{1:text{1:textMsg}}}
///   4:clientSequence  5:random
/// 响应 PbSendMsgResp：1:result 2:errMsg 3:sendTime 11:sequence 14:clientSequence
library;

import 'dart:typed_data';

import 'pc_proto.dart';

class PcSendMsgResult {
  const PcSendMsgResult({
    required this.result,
    required this.errMsg,
    required this.sendTime,
    required this.sequence,
    required this.clientSequence,
  });
  final int result;
  final String errMsg;
  final int sendTime;
  final int sequence;
  final int clientSequence;

  bool get ok => result == 0;
}

abstract final class PcSendMsgService {
  static const String cmd = 'MessageSvc.PbSendMsg';

  // Elem{1:Text{1:textMsg}}
  static Uint8List _elemText(String s) =>
      (PbWriter()..writeBytes(1, (PbWriter()..writeString(1, s)).toBytes()))
          .toBytes();

  // MessageBody{1:RichText{2:elems[]}}
  static Uint8List _messageBody(String text) {
    final richText = (PbWriter()..writeBytes(2, _elemText(text))).toBytes();
    return (PbWriter()..writeBytes(1, richText)).toBytes();
  }

  static Uint8List _contentHead() =>
      (PbWriter()..writeInt(1, 1)).toBytes(); // pkgNum=1

  static Uint8List _req({
    required Uint8List routingHead,
    required String text,
    required int clientSequence,
    required int random,
  }) {
    return (PbWriter()
          ..writeBytes(1, routingHead)
          ..writeBytes(2, _contentHead())
          ..writeBytes(3, _messageBody(text))
          ..writeInt(4, clientSequence)
          ..writeInt(5, random))
        .toBytes();
  }

  /// 好友(C2C)文本消息。
  static Uint8List buildC2C({
    required int peerUin,
    required String peerUid,
    required String text,
    required int clientSequence,
    required int random,
  }) {
    final c2c = (PbWriter()
          ..writeInt(1, peerUin)
          ..writeString(2, peerUid))
        .toBytes();
    final routing = (PbWriter()..writeBytes(1, c2c)).toBytes(); // SendRoutingHead{1:c2c}
    return _req(
        routingHead: routing,
        text: text,
        clientSequence: clientSequence,
        random: random);
  }

  /// 群文本消息。
  static Uint8List buildGroup({
    required int groupUin,
    required String text,
    required int clientSequence,
    required int random,
  }) {
    final grp = (PbWriter()..writeInt(1, groupUin)).toBytes();
    final routing = (PbWriter()..writeBytes(2, grp)).toBytes(); // SendRoutingHead{2:group}
    return _req(
        routingHead: routing,
        text: text,
        clientSequence: clientSequence,
        random: random);
  }

  static PcSendMsgResult parseResp(Uint8List bytes) {
    final r = PbReader(bytes);
    var result = 0, sendTime = 0, sequence = 0, clientSequence = 0;
    var errMsg = '';
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 1) {
        result = r.readVarint();
      } else if (f == 2) {
        errMsg = r.readString();
      } else if (f == 3) {
        sendTime = r.readVarint();
      } else if (f == 11) {
        sequence = r.readVarint();
      } else if (f == 14) {
        clientSequence = r.readVarint();
      } else {
        r.skip(w);
      }
    }
    return PcSendMsgResult(
        result: result,
        errMsg: errMsg,
        sendTime: sendTime,
        sequence: sequence,
        clientSequence: clientSequence);
  }
}
