/// L2 协议内核：ConfigPush（配置类推送）的请求解析与回执构造
///
/// ## 为什么单独一层
///
/// 官方对 `ConfigPushSvc.PushReq` 的处理是：外层 WUP 解开 → 按 type 分派
/// （1=SSO 列表 / 2=交应用进程 / 3=日志上传）→ **无论哪个分支都回执**
/// `ConfigPushSvc.PushResp`。而请求结构与回执结构的 **tag 号并不相同**：
///
/// * 请求 `serverconfig/f.java:20-36`：`1=a(int type)` / `2=b(byte[] data)`
///   / `3=c(long seq)`
/// * 回执 `serverconfig/g.java:20-38`：`1=a(int type)` / `2=b(long seq)`
///   / `3=c(byte[] data，仅非空才写)`
///
/// 处理与回执见 `com/tencent/mobileqq/msf/core/a/c.java:500-524`（dispatch）
/// 与 `:589-614`（`b()`：put("PushResp")、**仅 type==3 回带 data**、
/// `setNeedCallback(false)`、`setRequestSsoSeq(fromServiceMsg.getRequestSsoSeq())`）。
///
/// 之前实现把回执写成了 `{0: type, 2: seq}`——tag0 根本不存在，type3 也漏了
/// data；并且回执与 type2 的内层 pb 解析挤在同一个 try 里，内层一坏就漏回执。
/// 本文件把两件事拆成纯函数，便于逐字节自测。
///
/// 证据等级：官方 8.2.11 Java 反编译逐行对照（f/g 的 writeTo）。8.9.50/TIM
/// 只做过旁证，未逐行核；9.3.60 未核。
///
/// 本文件是纯 Dart。
library;

import 'dart:typed_data';

import 'qq8_jce.dart';

/// 解析后的 `PushReq`。
class Qq8ConfigPushReq {
  /// 配置类型：1=SSO 列表 / 2=应用配置(bigdata) / 3=日志上传。
  final int type;

  /// 原始 data（请求 tag2）。
  final Uint8List data;

  /// 服务端给的推送序号（请求 tag3，长整型，回执要带回）。
  final int seq;

  const Qq8ConfigPushReq({
    required this.type,
    required this.data,
    required this.seq,
  });

  @override
  String toString() => 'Qq8ConfigPushReq(type=$type, seq=$seq, data=${data.length}B)';
}

/// 解析 `ConfigPushSvc.PushReq` 的 SSO payload。
///
/// 返回 null = 不是可识别的 PushReq（此时**不应回执**——官方外层 decode
/// 失败直接进 catch，不构造回执，见 `a/c.java:519`）。
Qq8ConfigPushReq? decodePushReq(Uint8List payload) {
  var p = payload;
  // 真机 wupBuffer 带 4 字节长度前缀（parse 侧同样先剥 4 字节）。
  if (p.length > 4 && p[0] == 0) {
    p = Uint8List.sublistView(p, 4);
  }
  final Map<int, Object?> nested;
  try {
    nested = Qq8Jce.decodeWrapper(p);
  } on Object {
    return null;
  }
  final type = nested[1];
  if (type is! int) return null;
  final data = nested[2];
  final seq = nested[3];
  return Qq8ConfigPushReq(
    type: type,
    data: data is Uint8List ? data : Uint8List(0),
    seq: seq is int ? seq : 0,
  );
}

/// 构造 `ConfigPushSvc.PushResp` 的请求体（官方 g.java 字段序）。
///
/// 注意 tag 号与请求**不同**：回执是 `1=type` / `2=seq` / `3=data`，
/// 且只有 `type==3` 才回带 data（`a/c.java:598-600`）。
Uint8List buildPushRespBody({
  required int type,
  required int seq,
  Uint8List? data,
}) {
  return Qq8Jce.encodeWrapper(
    service: 'QQService.ConfigPushSvc.MainServant',
    method: 'PushResp',
    attributes: <String, Uint8List>{
      'PushResp': Qq8Jce.encodeStruct(<int, Object?>{
        1: type,
        2: seq,
        3: (type == 3 && data != null) ? data : null,
      }),
    },
  );
}
