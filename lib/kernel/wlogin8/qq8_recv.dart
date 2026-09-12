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

import 'dart:typed_data';

import '../crypto/tea.dart';
import 'qq8_login.dart';

/// 拆壳后的 SSO 应答。
class Qq8SsoResponse {
  /// 外壳 flag：0=明文 / 1=TEA(d2key) / 2=TEA(全零)。
  final int flag;

  /// SSO 头里的序列号（对应请求的 seq）。
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
  if (magic != 0x0A) {
    throw Qq8LoginException(
      '响应外壳 magic=0x${magic.toRadixString(16)}（期望 0x0A）——'
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
  int u32At(int off) {
    if (off < 0 || off + 4 > plain.length) {
      throw Qq8LoginException('SSO 头越界：读 u32@$off，共 ${plain.length} 字节');
    }
    return ((plain[off] << 24) | (plain[off + 1] << 16) |
            (plain[off + 2] << 8) | plain[off + 3]) &
        0xFFFFFFFF;
  }

  int i32At(int off) {
    final v = u32At(off);
    return v >= 0x80000000 ? v - 0x100000000 : v;
  }

  final headlen = u32At(0);
  final seq = i32At(4);
  final retcode = i32At(8);
  if (retcode != 0) {
    throw Qq8LoginException('SSO 返回码非 0：retcode=$retcode（seq=$seq）');
  }

  var offset = u32At(12) + 12;
  final cmdLen = u32At(offset);
  if (cmdLen < 4 || offset + cmdLen > plain.length) {
    throw Qq8LoginException('SSO cmd 长度非法：$cmdLen（off=$offset/${plain.length}）');
  }
  final cmd = String.fromCharCodes(plain.sublist(offset + 4, offset + cmdLen));
  offset += cmdLen;

  final sessLen = u32At(offset);
  offset += sessLen;
  final compressed = i32At(offset);

  final int payloadStart;
  if (compressed == 0) {
    payloadStart = headlen + 4;
  } else if (compressed == 8) {
    payloadStart = headlen;
  } else if (compressed == 1) {
    throw Qq8LoginException('SSO 负载是 gzip（flag=1），本实现未支持');
  } else {
    throw Qq8LoginException('未知的 SSO 压缩标志 flag=$compressed');
  }
  if (payloadStart < 0 || payloadStart > plain.length) {
    throw Qq8LoginException('SSO headlen=$headlen 使负载起点越界（${plain.length} 字节）');
  }

  return Qq8SsoResponse(
    flag: flag,
    seq: seq,
    cmd: cmd,
    retcode: retcode,
    payload: Uint8List.sublistView(plain, payloadStart),
  );
}
