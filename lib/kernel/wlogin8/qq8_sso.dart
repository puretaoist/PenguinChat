/// L2 协议内核：QQ 8.2.11 的 SSO 包封装
///
/// ## 三个层次
///
/// 每个请求实际是三层嵌套：
///
/// ```text
///   ┌─ 登录信封 (buildLoginPacket)
///   │    ├ 长度前缀
///   │    ├ 0x0A、type、d2、uin
///   │    └─ SSO 负载 ─────────────┐
///   │                             │
///   └─ SSO 信封 (buildLoginPacket 内层)
///        ├ seq / subid ×2 / BUF_UNKNOWN
///        ├ tgt / cmd / session_id / imei / ksid
///        ├ 长度前缀(body)          │
///        └ [type=1 用 d2key 加密；type=2 用全零密钥]
///                                  │
///   └─ OICQ 信封 (buildOicqPacket)
///        ├ 0x02 0x01 / random_key / 0x131 / 0x01
///        ├ ECDH 公钥 (TLV 形式)
///        ├ TEA(body, ecdh.share_key)
///        └ 包头：长度 / 协议版本 8001 / 命令字 0x810 / uin / 加密类型
/// ```
///
/// ## 来源
///
/// 逐行移植自参考实现 `takayama-lily/oicq` 的 `lib/wtlogin/wt.js`
/// （`_buildOICQPacket` 与 `_buildLoginPacket`）。黄金向量由运行该模块
/// 原始代码生成，见 `tool/qq8_sso_selftest.dart`。
///
/// 本文件是纯 Dart。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../infra/coder.dart';
import '../crypto/tea.dart';
import 'qq8_device.dart';
import 'qq8_tlv.dart';

/// SSO 包头里的固定未知字段（oicq `BUF_UNKNOWN`）。
///
/// 12 字节，含义未明。**不要"顺手优化"成零** —— 它很可能参与服务端的
/// 版本/分支判定，改了就登不上，而且报错信息不会指向这里。
const List<int> qq8BufUnknown = <int>[
  0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
];

/// SSO 包头里的命令字。
const int qq8CmdWtLogin = 0x810;

/// SSO 包头里的协议版本。
const int qq8ProtocolVersion = 8001;

/// 登录层信封的命令字（[Qq8Sso.buildLoginPacket] 的 `cmd` 参数）。
///
/// 出处（8.9.50 反编译）：密码登录 `request/j.java:14`、
/// 票据续期/设备锁 `request/l.java:9`、扫码取票 `request/d0.java:12`。
/// 三个字符串都在 `oicq_request` 子类的 `f154l` 字段里，与类一一对应。
const String qq8LoginCmd = 'wtlogin.login';

/// 票据续期（token 登录，子命令 11）的命令字。
const String qq8ExchangeEmpCmd = 'wtlogin.exchange_emp';

/// 扫码取票的命令字（尚未实现对应流程）。
const String qq8TransEmpCmd = 'wtlogin.trans_emp';

/// 登录信封的传输类型。
abstract final class Qq8LoginType {
  /// 心跳。
  static const int heartbeat = 0;

  /// 上线。
  static const int online = 1;

  /// 登录（用全零密钥加密 SSO 层）。
  static const int login = 2;
}

/// 票据集合（对应 oicq 的 `this.sig`）。
///
/// 登录成功后由服务端下发，后续所有请求都要带上。字段名沿用协议内部叫法。
class Qq8SigInfo {
  /// 登录票据。
  final Uint8List tgt;

  /// 会话密钥与其加密密钥。
  final Uint8List d2;
  final Uint8List d2key;

  /// 签名相关的两个密钥（`emp=true` 的包会用到）。
  final Uint8List sigKey;
  final Uint8List ticketKey;

  /// 短信验证票据。
  final Uint8List srmToken;

  /// 全部字段可省略，未提供的按空字节处理（登录前就是这种状态）。
  Qq8SigInfo({
    Uint8List? tgt,
    Uint8List? d2,
    Uint8List? d2key,
    Uint8List? sigKey,
    Uint8List? ticketKey,
    Uint8List? srmToken,
  })  : tgt = tgt ?? _emptyBytes,
        d2 = d2 ?? _emptyBytes,
        d2key = d2key ?? _emptyBytes,
        sigKey = sigKey ?? _emptyBytes,
        ticketKey = ticketKey ?? _emptyBytes,
        srmToken = srmToken ?? _emptyBytes;
}

/// 共享的空字节常量（`Uint8List` 没有 const 构造，只能这样给默认值）。
final Uint8List _emptyBytes = Uint8List(0);

/// SSO 构包上下文。
class Qq8SsoContext {
  final int uin;
  final Qq8ApkInfo apk;
  final Qq8Device device;

  /// 4 字节会话标识。
  final Uint8List sessionId;

  /// 16 字节随机密钥。
  final Uint8List randomKey;

  /// 本次登录的 ECDH 公钥（65 字节未压缩点）。
  final Uint8List ecdhPublicKey;

  /// 由 ECDH 协商出的 16 字节共享密钥。
  final Uint8List ecdhShareKey;

  /// 票据。
  final Qq8SigInfo sig;

  /// 当前序列号。
  final int seqId;

  Qq8SsoContext({
    required this.uin,
    required this.apk,
    required this.device,
    required this.sessionId,
    required this.randomKey,
    required this.ecdhPublicKey,
    required this.ecdhShareKey,
    Qq8SigInfo? sig,
    this.seqId = 0,
  }) : sig = sig ?? Qq8SigInfo();

  /// ksid：**由设备与客户端名派生**，不是随机值。
  ///
  /// 格式 `|<IMEI>|<apkName>`。
  Uint8List get ksid =>
      Uint8List.fromList(utf8.encode('|${device.imei}|${apk.name}'));
}

/// SSO 包构建器。
abstract final class Qq8Sso {
  /// 构建 OICQ 层信封，把业务 [body] 包成可直接发送的字节。
  ///
  /// [emp] 为真时走"设备锁/短信验证"分支，使用 [Qq8SigInfo.sigKey] 与
  /// [Qq8SigInfo.ticketKey]；否则用 ECDH 协商密钥。
  static Uint8List buildOicqPacket(
    Qq8SsoContext ctx,
    Uint8List body, {
    bool emp = false,
  }) {
    final wrapped = emp ? _wrapEmp(ctx, body) : _wrapEcdh(ctx, body);

    return (ByteWriter()
          ..u8(0x02)
          // 长度 = 1(本字节) + 27(固定字段) + body + 1(尾部 0x03)
          ..u16(29 + wrapped.length)
          ..u16(qq8ProtocolVersion)
          ..u16(qq8CmdWtLogin)
          ..u16(1) // 常量
          ..u32(ctx.uin)
          ..u8(3) // 常量
          ..u8(emp ? 69 : 0x87) // 加密类型：0x87=4，69=设备锁
          ..u8(0) // 常量
          ..u32(2) // 常量
          ..u32(0) // 客户端版本
          ..u32(0) // 常量
          ..raw(wrapped)
          ..u8(0x03))
        .build();
  }

  /// ECDH 分支的 body 包装。
  static Uint8List _wrapEcdh(Qq8SsoContext ctx, Uint8List body) {
    return (ByteWriter()
          ..u8(0x02)
          ..u8(0x01)
          ..raw(ctx.randomKey)
          ..u16(0x131)
          ..u16(0x01)
          ..bytes16(ctx.ecdhPublicKey) // writeTlv
          ..raw(qqTeaEncrypt(body, ctx.ecdhShareKey)))
        .build();
  }

  /// 设备锁 / 短信验证分支的 body 包装。
  static Uint8List _wrapEmp(Qq8SsoContext ctx, Uint8List body) {
    return (ByteWriter()
          ..bytes16(ctx.sig.sigKey)
          ..raw(qqTeaEncrypt(body, ctx.sig.ticketKey)))
        .build();
  }

  /// 构建登录层信封。
  ///
  /// [cmd] 是 SSO 命令字（如 `wtlogin.trans_emp`）；[type] 见 [Qq8LoginType]。
  static Uint8List buildLoginPacket(
    Qq8SsoContext ctx,
    String cmd,
    Uint8List body,
    int type,
  ) {
    final ksid = ctx.ksid;

    // 内层：SSO 信封
    var sso = (ByteWriter()
          ..u32(ctx.seqId)
          ..u32(ctx.apk.subid)
          ..u32(ctx.apk.subid)
          ..raw(qq8BufUnknown)
          ..let((w) => _withLength(w, ctx.sig.tgt))
          ..let((w) => _withLength(w, utf8.encode(cmd)))
          ..let((w) => _withLength(w, ctx.sessionId))
          ..let((w) => _withLength(w, utf8.encode(ctx.device.imei)))
          ..u32(4)
          ..u16(ksid.length + 2)
          ..raw(ksid)
          ..u32(4))
        .build();

    sso = (ByteWriter()
          ..let((w) => _withLength(w, sso))
          ..let((w) => _withLength(w, body)))
        .build();

    if (type == Qq8LoginType.online) {
      sso = qqTeaEncrypt(sso, ctx.sig.d2key);
    } else if (type == Qq8LoginType.login) {
      sso = qqTeaEncrypt(sso, Uint8List(16)); // 全零密钥
    }

    // 外层：登录信封
    final outer = (ByteWriter()
          ..u32(0x0A)
          ..u8(type)
          ..let((w) => _withLength(w, ctx.sig.d2))
          ..u8(0)
          ..let((w) => _withLength(w, utf8.encode('${ctx.uin}')))
          ..raw(sso))
        .build();

    return (ByteWriter()..let((w) => _withLength(w, outer))).build();
  }
}

/// 长度前缀字节串，其中**长度字段包含它自己那 4 字节**。
///
/// 对应参考实现的 `Writer.writeWithLength`：
/// ```js
/// writeWithLength(v) { return this.writeU32(Buffer.byteLength(v) + 4).writeBytes(v); }
/// ```
///
/// ⚠️ 与 `ByteWriter.bytes32` 不同：后者写入的是**裸长度**（不含自身）。
/// 本协议这一层的多个字段（tgt / cmd / session_id / imei / d2 / uin）
/// 用的都是**含自身**的写法，不要混用——写错了服务端只会回一个含糊的
/// 登录失败码，极难定位。
void _withLength(ByteWriter w, List<int> data) {
  final bytes = data is Uint8List ? data : Uint8List.fromList(data);
  w.u32(bytes.length + 4);
  w.raw(bytes);
}

/// 让链式写法保持可读的小工具。
extension _ChainLet on ByteWriter {
  ByteWriter let(void Function(ByteWriter w) fn) {
    fn(this);
    return this;
  }
}
