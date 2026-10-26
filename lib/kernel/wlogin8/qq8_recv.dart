/// L2 协议内核：响应帧的外层拆壳（raw-TCP 路径）
///
/// ## 为什么需要这一层
///
/// 传输层剥掉 4 字节分帧头之后，拿到的**不是**能直接交给
/// [Qq8LoginResponse.parse] 的负载——中间还有两层壳。2026-09-11 真机 dump
/// （716 字节）逐字段核对如下：
///
/// ```text
/// ① 外壳（回显请求登录信封的字段）
///    u32 magic = 0x0A
///    u8  flag        0=明文 / 1=TEA(d2key) / 2=TEA(全零)
///    u32 d2len       （首登为 0）
///    u8  uinLenField 含自身 4 字节（14 = 4 + 10）
///    uin             ASCII
///    —— 此后是密文，TEA 密钥按 flag 选
///
/// ② SSO 应答（字段顺序与 oicq `parseSSO` 逐项一致）
///    u32 headlen     payload 起点 = headlen + 4
///    i32 seq / i32 retcode（非 0 抛错）
///    u32 ?（观测为 4） / u32 cmdLen（含自身） / cmd
///    u32 sessLen（含自身） / session / i32 flag（0=明文 1=gzip 8=整体偏移）
///
/// ③ payload（交给 [Qq8LoginResponse.parse]，对应官方 `oicq_request.d()`）
///    [u8 0x02][u16 len][u16 8001][u16 0x810][u16 1][u32 uin][u16 rspFlag][u8 ?]
///    [TEA(ECDH share key)][0x03]
/// ```
///
/// ## 出处
///
/// * ①的解密语义与 ③ 的内层定界：官方 8.9.50 `request/oicq_request.java` 的
///   `d()`——`d = len - 17`、`u16@13` 是 rsp flag、`rspFlag == 0` 用 ECDH
///   共享密钥解密 `[16, len-1)`。
/// * ②的逐字段布局：oicq `lib/oicq.js` 的 `parseSSO`（js 时代，与目标版本
///   同代；`lib/client.js` 把 `packetListener` 挂在每个收到的包上）。
/// * ①的字段取值：2026-09-11 真机 dump（716 字节）——测试里用的是**脱敏版**
///   （账号替换为 10001，密文原样保留），见 `tool/qq8_recv_selftest.dart`。
///
/// 非空 d2 的字段顺序**尚无样本**，遇到时显式报错不猜（见下方 `d2Len` 分支）。
///
/// 本文件是纯 Dart。
library;

import 'dart:io' show Platform, gzip, zlib;
import 'dart:typed_data';

import '../crypto/tea.dart';
import 'qq8_login.dart';

/// 拆壳后的 SSO 应答。
class Qq8SsoResponse {
  /// 外壳 flag：0=明文 / 1=TEA(d2key) / 2=TEA(全零)。
  final int flag;

  /// SSO 头里的序列号（对应请求的 seq）。
  ///
  /// 配对用 SSO 头里的 seq（与 icqq `base-client.js:1429` 一致）。
  /// `magic=0x0B`（UNI 应答）时外壳里另有一个 seq，仅在 SSO 头那位为 0
  /// 时兜底。
  final int seq;

  /// SSO 命令字（如 `wtlogin.login`）。
  final String cmd;

  /// SSO 返回码（非 0 在拆壳时已抛错，这里保留供诊断）。
  final int retcode;

  /// 交给 [Qq8LoginResponse.parse] 的负载。
  final Uint8List payload;

  const Qq8SsoResponse({
    required this.flag,
    required this.seq,
    required this.cmd,
    required this.retcode,
    required this.payload,
  });

  String describe() =>
      'flag=$flag seq=$seq cmd=$cmd payload=${payload.length} 字节';
}

/// 拆掉 ① 外壳 + ② SSO 头，只取负载。
Uint8List qq8UnwrapRecvPayload(Uint8List frame, {Uint8List? d2key}) =>
    qq8UnwrapRecv(frame, d2key: d2key).payload;

/// 与 [qq8UnwrapRecvPayload] 相同，但把 SSO 头的元信息一并返回（诊断用）。
Qq8SsoResponse qq8UnwrapRecv(Uint8List frame, {Uint8List? d2key}) {
  if (frame.length < 12) {
    throw Qq8LoginException('响应太短（${frame.length} 字节），不可能是 SSO 应答');
  }

  // ---------- ① 外壳 ----------
  final magic = (frame[0] << 24) | (frame[1] << 16) | (frame[2] << 8) | frame[3];
  if (magic == 0x0B) {
    return _unwrapUni(frame, d2key: d2key);
  }
  if (magic != 0x0A) {
    throw Qq8LoginException(
      '响应外壳 magic=0x${magic.toRadixString(16)}（期望 0x0A 或 0x0B）——'
      '报文布局与已知模型不符，请保留原始字节排查',
    );
  }
  final flag = frame[4];
  final d2Len = (frame[5] << 24) | (frame[6] << 16) | (frame[7] << 8) | frame[8];
  if (d2Len != 0) {
    throw Qq8LoginException(
      '响应外壳里 d2 长度=$d2Len：非空 d2 的字段顺序尚无样本核对，'
      '请保留原始字节（qq8-response-*.hex）后再实现',
    );
  }
  final uinLenField = frame[9];
  final uinLen = uinLenField >= 4 ? uinLenField - 4 : uinLenField;
  final ctStart = 10 + uinLen;
  if (ctStart >= frame.length) {
    throw Qq8LoginException('响应外壳声明的 uin 长度超出报文（$ctStart/${frame.length}）');
  }
  final ct = Uint8List.sublistView(frame, ctStart);

  final Uint8List plain;
  if (flag == 0) {
    plain = ct;
  } else if (flag == 1) {
    if (d2key == null || d2key.isEmpty) {
      throw Qq8LoginException('响应外壳 flag=1 需要 d2key，但当前没有（首登不应出现）');
    }
    plain = qqTeaDecrypt(ct, d2key);
  } else if (flag == 2) {
    plain = qqTeaDecrypt(ct, Uint8List(16));
  } else {
    throw Qq8LoginException('未知的响应外壳 flag=$flag');
  }

  // ---------- ② SSO 头 ----------
  final head = _parseSsoHead(plain);

  return Qq8SsoResponse(
    flag: flag,
    seq: head.seq,
    cmd: head.cmd,
    retcode: head.retcode,
    payload: head.payload,
  );
}

/// `magic=0x0B` 的 UNI 应答外壳。
///
/// ## 与 `0x0A` 的区别（实测 2026-10-22，`tool/qq8_raw_probe.dart`）
///
/// 请求侧 `icqq` 的 `buildUniPkt`（`lib/core/base-client.js:1636-1660`）写的是：
/// ```text
/// u32 0x0B ‖ u8 type(=1) ‖ i32 seq ‖ u8 0 ‖ withLen(uin 字符串) ‖ TEA(sso, d2key)
/// ```
/// —— 比 `0x0A` 少了 d2 段（`0x0A` 是 `u32 0x0A ‖ u8 type ‖ withLen(d2) ‖ u8 0 ‖ withLen(uin)`），
/// 并且 seq 就在外壳里（`0x0A` 外壳没有 seq）。
///
/// 应答同样以 `0x0B` 打头。此前 `qq8UnwrapRecv` 只认 `0x0A`，遇到 UNI
/// 应答直接抛「magic=0xb」，导致 `OidbSvc.0x480_9_IMCore` 等到超时——
/// 这就是补这个分支的原因。
Qq8SsoResponse _unwrapUni(Uint8List frame, {Uint8List? d2key}) {
  if (frame.length < 11) {
    throw Qq8LoginException('UNI 应答太短（${frame.length} 字节）');
  }
  final flag = frame[4];
  final seq = (frame[5] << 24) | (frame[6] << 16) | (frame[7] << 8) | frame[8];
  final uinLenField = frame[9];
  final uinLen = uinLenField >= 4 ? uinLenField - 4 : uinLenField;
  final ctStart = 10 + uinLen;
  if (ctStart >= frame.length) {
    throw Qq8LoginException('UNI 应答声明的 uin 长度超出报文（$ctStart/${frame.length}）');
  }
  final ct = Uint8List.sublistView(frame, ctStart);

  final Uint8List plain;
  if (flag == 0) {
    plain = ct;
  } else if (flag == 1) {
    if (d2key == null || d2key.isEmpty) {
      throw Qq8LoginException('UNI 应答 flag=1 需要 d2key，但当前没有');
    }
    plain = qqTeaDecrypt(ct, d2key);
  } else if (flag == 2) {
    plain = qqTeaDecrypt(ct, Uint8List(16));
  } else {
    throw Qq8LoginException('未知的 UNI 应答外壳 flag=$flag');
  }

  final head = _parseSsoHead(plain);
  return Qq8SsoResponse(
    flag: flag,
    // 与 icqq 一致：配对用 SSO 头里的 seq（`base-client.js:1429`
    // `if (this[HANDLERS].has(sso.seq))`）。外壳 seq 只在 SSO 头那位为 0
    // 时兜底——UNI 路径上服务端确实回填了 SSO seq，2026-10-22 实测。
    seq: head.seq != 0 ? head.seq : seq,
    cmd: head.cmd,
    retcode: head.retcode,
    payload: head.payload,
  );
}

/// 解析 SSO 头（`0x0A` 与 `0x0B` 共用）。
///
/// 与 `icqq` 的 `parseSso`（`lib/core/base-client.js:1342-1399`）逐字段一致：
/// ```text
/// u32 headlen
/// i32 seq
/// i32 retcode
/// withLen(retmsg)      ← 只在 retcode != 0 时非空
/// withLen(cmd)
/// withLen(session)
/// i32 compressed       0=明文 / 1=gzip（zlib.unzip）/ 8=整体偏移
/// withLen(?)
/// withLen(payload)
/// ```
/// `compressed == 1` 时 `payload` 要过 `zlib.unzip`（icqq `constants.js:41`
/// `exports.unzip = promisify(zlib.unzip)`，`base-client.js:1389` 直接调用）。
({int seq, int retcode, String cmd, Uint8List payload}) _parseSsoHead(
  Uint8List plain,
) {
  int u32At(int off) {
    if (off < 0 || off + 4 > plain.length) {
      throw Qq8LoginException('SSO 头越界：读 u32@$off，共 ${plain.length} 字节');
    }
    return ((plain[off] << 24) |
            (plain[off + 1] << 16) |
            (plain[off + 2] << 8) |
            plain[off + 3]) &
        0xFFFFFFFF;
  }

  int i32At(int off) {
    final v = u32At(off);
    return v >= 0x80000000 ? v - 0x100000000 : v;
  }

  final headlen = u32At(0);
  final seq = i32At(4);
  final retcode = i32At(8);
  // 诊断开关：QQ8_RECV_TRACE=1 时打印 SSO 头前 64 字节，便于定位
  // 「seq/cmd 解出垃圾」这类问题（无帧格式信息则无从下手）。
  final trace = Platform.environment['QQ8_RECV_TRACE'] == '1';
  if (trace) {
    final n = plain.length < 64 ? plain.length : 64;
    final hex = List<String>.generate(
        n, (i) => plain[i].toRadixString(16).padLeft(2, '0')).join();
    // ignore: avoid_print
    print('[recv] SSO 头 headlen=$headlen seq=$seq retcode=$retcode 前$n=$hex');
  }
  if (retcode != 0) {
    // **不在这里抛**：这一帧是配对到某个请求的合法应答，只是服务端拒绝了它。
    // 在这里抛等于把整帧丢掉——会话层的 `_pending` 永远等不到人，
    // 请求侧只能熬到超时，上层完全看不到服务端说了什么。
    // 真机 2026-10-26 21:46 现场：服务端连着回 -10003 / -10008，
    // 我们每一帧都当"解析失败"丢弃，于是 15 个请求各自超时 → 心跳连败 → 断线。
    //
    // 官方语义（`msf/core/ag.java:1782-1793`）：-10008 是"要求重发"，
    // 官方 `D.reSendMsg(toServiceMsgC)` 自动重发一次；参考实现 icqq
    // `base-client.ts:650-653` 虽然也抛，但它先 `emit("internal.error.token")`
    // 把信号交给了上层，我们的等价动作是保留 retcode 让会话层处理。
    //
    // 注意：retcode != 0 时 SSO 头里 retcode 后面跟的是 withLen(retmsg)，
    // 与成功路径的字段顺序不同，**不能**再往下按成功布局解析 cmd/payload。
    return (seq: seq, retcode: retcode, cmd: '', payload: Uint8List(0));
  }

  var offset = u32At(12) + 12;
  final cmdLen = u32At(offset);
  if (cmdLen < 4 || offset + cmdLen > plain.length) {
    throw Qq8LoginException('SSO cmd 长度非法：$cmdLen（off=$offset/${plain.length}）');
  }
  final cmd = String.fromCharCodes(plain.sublist(offset + 4, offset + cmdLen));
  offset += cmdLen;

  final sessLen = u32At(offset);
  if (sessLen < 4 || offset + sessLen > plain.length) {
    throw Qq8LoginException('SSO session 长度非法：$sessLen（off=$offset/${plain.length}）');
  }
  offset += sessLen;
  final compressed = i32At(offset);
  offset += 4;

  final int payloadStart;
  switch (compressed) {
    case 0:
      payloadStart = headlen + 4;
    case 8:
      payloadStart = headlen;
    case 1:
      // gzip：负载仍在 headlen+4，但要解压。见下方。
      payloadStart = headlen + 4;
    default:
      throw Qq8LoginException('未知的 SSO 压缩标志 flag=$compressed');
  }
  if (payloadStart < 0 || payloadStart > plain.length) {
    throw Qq8LoginException('SSO headlen=$headlen 使负载起点越界（${plain.length} 字节）');
  }

  var payload = Uint8List.sublistView(plain, payloadStart);
  if (compressed == 1) {
    payload = _inflate(payload);
  }

  return (seq: seq, retcode: retcode, cmd: cmd, payload: payload);
}

/// zlib / gzip 解压。
///
/// `icqq` 用 Node 的 `zlib.unzip`（自动识别 zlib 与 gzip 两种头），Dart 的
/// `ZLibDecoder` 只吃 zlib、`GZipDecoder` 只吃 gzip，所以这里按魔数分派：
/// `0x1F 0x8B` → gzip，否则 zlib。两者都失败则原样返回（不让解压问题掩盖
/// 协议问题，解出来的垃圾交给调用方判断）。
Uint8List _inflate(Uint8List data) {
  final isGzip = data.length >= 2 && data[0] == 0x1F && data[1] == 0x8B;
  try {
    final out = isGzip ? gzip.decode(data) : zlib.decode(data);
    return Uint8List.fromList(out);
  } catch (_) {
    return data;
  }
}
