/// L2 协议内核：合并转发（MultiMsg / "聊天记录"）
///
/// ## 链路（参考实现 `oicq/lib/internal/contactable.ts` 的
/// `makeForwardMsg` / `_uploadMultiMsg` / `_downloadMultiMsg`）
///
/// ```text
/// ① 节点   每条被转发的消息编成一个 MultiMsg 节点（发送者/时间/seq/rand + rich）
/// ② 内容   {1: nodes, 2: {1: "MultiMsg", 2: {1: nodes}}}  → gzip
/// ③ 申请   MultiMsg.ApplyUp（主 SSO）：拿 resid / 上传 key / 上传 ip:port / ticket
/// ④ 上传   highway TCP，业务号 27（复用 Qq8Image.upload 的帧与分片逻辑）
/// ⑤ 发送   把 resid 包进一张 XML 卡片（action="viewMultiMsg"）当普通消息发出去
/// ```
///
/// ## 证据等级
///
/// | 部分 | 出处 | 等级 |
/// |---|---|---|
/// | ApplyUp / 上传体 / 节点字段号 | oicq `internal/contactable.ts`（社区实测可用） | **单源** |
/// | highway 帧与业务号 27 | oicq `highway.ts` 的 `CmdID.MultiMsg` | **单源** |
/// | XML 卡片模板 | oicq 同函数里的模板字符串（官方客户端同款） | **单源** |
///
/// 单源部分真机验证时以服务端是否接受为准；失败先怀疑它们。
///
/// 本文件是纯 Dart（gzip 用 `dart:io`；不碰 Flutter）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'qq8_pb.dart';

/// `MultiMsg.ApplyUp` 的应答（成功时 [ok] 为真）。
class Qq8MultiMsgTicket {
  /// 服务端结果码（0 = 成功）。
  final int code;

  /// 失败文案（服务端一般不填）。
  final String message;

  /// 转发资源 ID（消息里的 `m_resid`，下载/展开时用它）。
  final String resid;

  /// 上传主机。
  final String host;

  /// 上传端口。
  final int port;

  /// 上传体里第 6 号字段要用的不透明 key。
  final Uint8List uploadKey;

  /// highway 上传要用的 ticket。
  final Uint8List ticket;

  const Qq8MultiMsgTicket({
    required this.code,
    required this.message,
    required this.resid,
    required this.host,
    required this.port,
    required this.uploadKey,
    required this.ticket,
  });

  bool get ok => code == 0 && resid.isNotEmpty;

  @override
  String toString() =>
      'Qq8MultiMsgTicket(code=$code, resid=$resid, $host:$port)';
}

/// 合并转发里的一条原始消息（服务层/适配层填好后交给 [Qq8MultiMsg.buildNode]）。
class Qq8MultiMsgNode {
  /// 原消息发送者 uin。
  final int senderUin;

  /// 群名片/昵称（群里显示用；私聊节点走 14 号字段）。
  final String nickname;

  /// 卡片里的摘要行用的文本（"昵称: 前 50 字"里的后半段）。
  final String brief;

  /// 原消息时间（秒）。
  final int time;

  /// 已编好的内容元素（[Qq8Msg.textElem] / [Qq8Msg.faceElem]…）。
  final List<Uint8List> elems;

  const Qq8MultiMsgNode({
    required this.senderUin,
    this.nickname = '',
    this.brief = '',
    required this.time,
    required this.elems,
  });
}

/// 合并转发（MultiMsg）协议。
abstract final class Qq8MultiMsg {
  /// 申请上传（主 SSO 命令字）。
  static const String cmdApplyUp = 'MultiMsg.ApplyUp';

  /// 拉取内容（主 SSO 命令字，做"展开聊天记录"时用）。
  static const String cmdApplyDown = 'MultiMsg.ApplyDown';

  /// highway 业务号（oicq `CmdID.MultiMsg`）。
  static const int cmdIdMultiMsg = 27;

  /// 节点的消息类型：群 82 / 私聊 166。
  static const int groupElemType = 82;
  static const int dmElemType = 166;

  /// 私聊节点的第 4 号字段（群节点不发）。
  static const int dmNodeFlag = 11;

  /// XML 卡片的 `serviceID`。
  static const int serviceId = 35;

  /// 节点时间戳来源（服务端只当展示用，本地时间即可）。
  static int nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// `rand2uuid`：`0x1000000 << 32 | rand`（参考实现 `message.ts`）。
  ///
  /// 节点的 7 号字段是 uint64，低 32 位才是 rand——展开时官方客户端按
  /// `uuid & 0xffffffff` 还原随机数。
  static int rand2uuid(int rand) => (0x1000000 << 32) | (rand & 0xFFFFFFFF);

  /// 编一个节点（`MultiMsg` 的 `Msg`）。
  ///
  /// 群节点带 `9: {1: 群号, 4: 群名片}`，私聊节点带 `4: 11` 与 `14: 昵称`。
  /// [rich] 是 Qq8Msg.richElems 的产物（`{2: [...元素]}`）。
  static Uint8List buildNode({
    required int senderUin,
    required int target,
    required bool dm,
    required int seq,
    required int time,
    required int rand,
    required Uint8List rich,
    String? nickname,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: <int, Object?>{
          1: senderUin,
          2: target,
          3: dm ? dmElemType : groupElemType,
          4: dm ? dmNodeFlag : null,
          5: seq & 0xFFFF,
          6: time,
          7: rand2uuid(rand),
          9: dm
              ? null
              : <int, Object?>{
                  1: target,
                  4: nickname ?? '',
                },
          14: dm ? (nickname ?? '') : null,
          20: <int, Object?>{
            1: 0,
            2: rand & 0xFFFFFFFF,
          },
        },
        3: <int, Object?>{1: rich},
      });

  /// 把节点列表编成转发内容（未压缩）。
  static Uint8List buildContent(List<Uint8List> nodes) =>
      Qq8Pb.encode(<int, Object?>{
        1: nodes,
        2: <int, Object?>{
          1: 'MultiMsg',
          2: <int, Object?>{1: nodes},
        },
      });

  /// gzip 压缩转发内容（官方是 gzip，不是裸 deflate）。
  static Uint8List gzipContent(Uint8List content) =>
      Uint8List.fromList(gzip.encode(content));

  /// `MultiMsg.ApplyUp` 的请求体。
  static Uint8List buildApplyUpBody({
    required int target,
    required int size,
    required Uint8List md5,
    required String apkVersion,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: 1,
        2: 5,
        3: 9,
        4: 3,
        5: apkVersion,
        6: <Object?>[
          <int, Object?>{
            1: target,
            2: size,
            3: md5,
            4: 3,
            5: 0,
          },
        ],
        8: 1,
      });

  /// 解析 `MultiMsg.ApplyUp` 的应答。
  ///
  /// 结构：`{2: {1: 码, 2: resid, 3: 上传 key, 4: ip, 5: 端口, 10: ticket}}`。
  static Qq8MultiMsgTicket? parseApplyUp(Uint8List payload) {
    final top = Qq8Pb.decode(payload);
    final rspBytes = Qq8Pb.bytesAt(top, 2);
    if (rspBytes == null) return null;
    final rsp = Qq8Pb.decode(rspBytes);
    final ip = Qq8Pb.intAt(rsp, 4);
    final port = Qq8Pb.intAt(rsp, 5);
    final resid = Qq8Pb.textAt(rsp, 2) ?? '';
    if (resid.isEmpty && ip == null) return null;
    return Qq8MultiMsgTicket(
      code: Qq8Pb.intAt(rsp, 1) ?? -1,
      message: '',
      resid: resid,
      host: ip == null ? '' : u32ToIp(ip),
      port: port ?? 0,
      uploadKey: Qq8Pb.bytesAt(rsp, 3) ?? Uint8List(0),
      ticket: Qq8Pb.bytesAt(rsp, 10) ?? Uint8List(0),
    );
  }

  /// highway 要传的请求体（官方把压缩后的内容嵌在里面，外面再套 highway 帧）。
  static Uint8List buildUploadBody({
    required int target,
    required Uint8List compressed,
    required Uint8List uploadKey,
  }) =>
      Qq8Pb.encode(<int, Object?>{
        1: 1,
        2: 5,
        3: 9,
        4: <Object?>[
          <int, Object?>{
            2: target,
            4: compressed,
            5: 2,
            6: uploadKey,
          },
        ],
      });

  /// 生成"聊天记录"XML 卡片（`action="viewMultiMsg"`）。
  ///
  /// [previews] 是前几行的摘要（官方只放前 4 条）；[fileName] 是卡片里的
  /// `m_fileName`（官方用一个大写 UUID，这里允许调用方给，默认 `MULTIMSG`）。
  static String buildXmlCard({
    required String resid,
    required int total,
    required int fileSize,
    required List<String> previews,
    String fileName = 'MULTIMSG',
  }) {
    final sb = StringBuffer();
    sb.write('<?xml version="1.0" encoding="utf-8"?>\n');
    sb.write('<msg brief="[聊天记录]" m_fileName="');
    sb.write(_escapeXml(fileName));
    sb.write('" action="viewMultiMsg" tSum="');
    sb.write(total);
    sb.write('" flag="3" m_resid="');
    sb.write(_escapeXml(resid));
    sb.write('" serviceID="');
    sb.write(serviceId);
    sb.write('" m_fileSize="');
    sb.write(fileSize);
    sb.write(
        '"><item layout="1"><title color="#000000" size="34">转发的聊天记录</title>');
    for (final p in previews) {
      sb.write('<title color="#777777" size="26">');
      sb.write(_escapeXml(p));
      sb.write('</title>');
    }
    sb.write('<hr></hr><summary color="#808080" size="26">查看');
    sb.write(total);
    sb.write('条转发消息</summary></item><source name="聊天记录"></source></msg>');
    return sb.toString();
  }

  /// 把 XML 包成 `Elem`（字段 12：`{1: [1, 裸 deflate(xml)], 2: serviceID}`）。
  ///
  /// 官方这条元素是"先写一个 0x01 标志字节，再写裸 deflate 数据"，
  /// 接收侧看到第一个字节 `> 0` 就 inflate（见 `qq8_elem.dart` 的 Qq8CardElem）。
  static Uint8List buildXmlElem(String xml) {
    final raw = utf8.encode(xml);
    final packed = ZLibEncoder(raw: true).convert(raw);
    final body = Uint8List(1 + packed.length);
    body[0] = 0x01;
    body.setRange(1, body.length, packed);
    return Qq8Pb.encode(<int, Object?>{
      12: <int, Object?>{
        1: body,
        2: serviceId,
      },
    });
  }

  /// 32 位无符号整数 → 点分十进制 IP。
  ///
  /// 服务端给的是 uint32（高位为 1 时在 Dart 里是负数），先按 32 位截断。
  static String u32ToIp(int v) {
    final u = v & 0xFFFFFFFF;
    return <int>[
      (u >> 24) & 0xFF,
      (u >> 16) & 0xFF,
      (u >> 8) & 0xFF,
      u & 0xFF,
    ].join('.');
  }

  static String _escapeXml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
