/// L2 协议内核：二维码扫码登录（`wtlogin.trans_emp` 的 code2d 通道）
///
/// ## 流程
///
/// ```text
///   取码   wtlogin.trans_emp + code2d(cmd=0x31, head=0x11100)  → 二维码图 + qrsig
///   轮询   wtlogin.trans_emp + code2d(cmd=0x12, head=0x6200)   → 扫描/确认状态
///   登录   wtlogin.login     + 子命令 9（把扫到的 t106/t16a/t318 注入）
/// ```
///
/// 三条都由客户端发起、**握手前**完成，所以信封用 `uin = 0`、OICQ 命令字
/// `0x812`、SSO 头 subid 取**手表档案**（537065138）——它是"手表协议扫码登录"
/// 的模拟（参考实现 `buildLoginPacket` 里 `cmd === "wtlogin.trans_emp"` 分支）。
///
/// ## 出处与证据等级
///
/// 逐行对照 `analysis/_ref/oicq-src/lib/core/base-client.ts` 的
/// `fetchQrcode` / `queryQrcodeResult` / `qrcodeLogin` / `buildCode2dPacket`
/// 与 `lib/core/tlv.ts` 的手表分支。
///
/// ⚠️ js 时代那份参考（本工程黄金向量的来源）**没有二维码**，因此本模块
/// **没有黄金向量**：离线自测只做"结构自洽 + 与参考实现逐字段对照"，
/// 真正的裁判是服务端（真机）。字段解析全部带边界检查，越界一律报错不猜。
///
/// ### 2026-09-12 官方 APK 对照（8.2.11 / 8.9.50）
///
/// 逐字段核对过 `oicq/wlogin_sdk/code2d/{c,fetch_code,e}.java` 与
/// `WtloginHelper.FetchCodeSig/QueryCodeResult`：
///
/// * 信封 43 字节头**逐字段吻合**（`u8 2 / u16 总长 / u16 _cmd / 21 字节 0 /
///   u8 3 / u16 0 / u16 _version=50 / u32 _seq / u64 uin` + 尾 `u8 3`）；
///   `_cmd`：取码 49(0x31)、轮询 18(0x12)、确认 19、关闭 20；
/// * 取码体（`fetch_code.get_request`）：`u16 0 / u32 appid(16) / u64 0 /
///   u8 8 / u16 0（空串） / u16 TLV 数 / TLV{17,22,27,29,31,51,53}` —— 逐字段吻合；
/// * 轮询体（`QueryCodeResult`）：`u16 5 / u8 1 / u32 u.u0(8) / u32 appid(16) /
///   tlv(qrsig) / u64 0 / u8 8 / u16 0` —— 逐字段吻合；
/// * TLV 27/29/31/51/53 的 body 布局与官方 `QRCodeCustom`/`getAppInfo` 同构；
/// * 响应解析：官方 code2d 层先剥 43 字节头，再读 `[u16][u32][u8 ret][u16 len]
///   [qrsig][u16 TLV 数]`（fetch，偏移 2/6/7/9）；轮询多一层 `u16 len` 子块。
///   传输层另有 5 字节前缀（`d0.a()` 的 `w=5`）⇒ 我们的 54/48 偏移 = 5+43+6 与
///   5+43，与官方读法一致（数值来自参考实现，结构对得上官方）；
/// * **两处只有参考实现有、官方包里没有**：① 头前面那 18 字节前导
///   （`u32 0x11100 / u32 0x1000 / u16 0 / u32 0x72000000 / u32 时间戳`）——
///   官方 8.2.11/8.9.50 用的是 13 字节传输前缀 + 把时间戳放在加密体最前；
///   ② 服务名写 `wtlogin.trans_emp` —— 官方 8.2.11 时代同名（8.9.50 起
///   `roleCmdMap` 把 role=114 改写成 `wtlogin.qrlogin`，手表 2.0.8 是 2019
///   年的包，取老写法）。
/// * 0x16（appInfo）：结构 = `u32 7 / u32 appid / u32 subid / guid /
///   tlv(包名) / tlv(版本) / tlv(sign)`，与 8.2.11 的 `getAppInfo`（也是 `u32 7`）
///   同构；8.9.50 把首字段升到 19。
/// * 轮询响应的 tag 对应关系两边一致：24(0x18)→t106 料、25(0x19)→免密 sig、
///   30(0x1E)→tgtgt、101(0x65)→tgtQR。但**用法不同**：我们（手表线）按参考
///   实现把 0x18/0x19/0x65 原样注入登录体；官方手 Q 是先把 0x18+0x1E 派生
///   `_tmp_pwd`（MD5 拼接）再重建 `0x106`（`WtloginHelper` 9783 一带 +
///   `j.java` 的 `o=true` 分支）。真机若在子命令 9 被拒，这里是第一处要改的。
///
/// 本文件是纯 Dart。
library;

import 'dart:typed_data';

import '../../infra/coder.dart';
import 'qq8_login.dart';
import 'qq8_sso.dart';
import 'qq8_tlv.dart';

/// 轮询返回码（参考实现 `QrcodeResult` 枚举）。
abstract final class Qq8QrcodeResult {
  /// 扫码 + 确认都完成，可以带着 t106/t16a/t318 去登录。
  static const int confirmed = 0;

  /// 二维码超时，要重新取码。
  static const int timeout = 0x11;

  /// 还没被扫。
  static const int waitingForScan = 0x30;

  /// 扫了但没在手机上确认。
  static const int waitingForConfirm = 0x35;

  /// 被取消。
  static const int canceled = 0x36;

  /// 给人看的一句话。
  static String describe(int retcode) => switch (retcode) {
        confirmed => '已确认，正在登录',
        timeout => '二维码超时，请重新获取',
        waitingForScan => '二维码尚未扫描',
        waitingForConfirm => '已扫描，请在手机上确认',
        canceled => '二维码被取消，请重新获取',
        _ => '扫码遇到未知错误（retcode=$retcode），请重新获取',
      };
}

/// 取码结果。
class Qq8QrFetch {
  final int retcode;

  /// 轮询凭据（参考实现里的 `sig.qrsig`）。
  final Uint8List qrsig;

  /// 二维码内容（TLV `0x17`，通常是二维码图片字节或一个二维码链接）。
  final Uint8List qrToken;

  const Qq8QrFetch({
    required this.retcode,
    required this.qrsig,
    required this.qrToken,
  });

  bool get ok => retcode == 0 && qrToken.isNotEmpty;
}

/// 一次轮询的结果。
class Qq8QrQuery {
  final int retcode;

  /// 确认后才有：扫码账号。
  final int? uin;

  /// 确认后才有：服务端给的三个登录材料（原样注入子命令 9）。
  final Uint8List? t106;
  final Uint8List? t16a;
  final Uint8List? t318;

  /// 确认后才有：扫码得到的 tgtgt（登录 body 的 0x106 与 0x119 解密都用它）。
  final Uint8List? tgtgt;

  const Qq8QrQuery({
    required this.retcode,
    this.uin,
    this.t106,
    this.t16a,
    this.t318,
    this.tgtgt,
  });

  bool get confirmed =>
      retcode == Qq8QrcodeResult.confirmed &&
      t106 != null &&
      t16a != null &&
      t318 != null &&
      tgtgt != null;

  String get message => Qq8QrcodeResult.describe(retcode);
}

/// 二维码登录的三段组包与解析。
abstract final class Qq8Qrcode {
  /// 取码的 code2d 命令字。
  static const int cmdFetch = 0x31;

  /// 取码的 code2d 头部常量。
  static const int headFetch = 0x11100;

  /// 轮询的 code2d 命令字。
  static const int cmdQuery = 0x12;

  /// 轮询的 code2d 头部常量。
  static const int headQuery = 0x6200;

  /// OICQ 信封的命令字：`wtlogin.trans_emp` 用 0x812。
  static const int cmdIdTransEmp = 0x812;

  /// 取码请求体（子命令 0）：
  /// `u16 0 ‖ u32 16 ‖ u64 0 ‖ u8 8 ‖ tlv(空) ‖ u16 6 ‖ tlv(0x16 手表版) ‖
  ///  tlv(0x1B) ‖ tlv(0x1D) ‖ tlv(0x1F) ‖ tlv(0x33) ‖ tlv(0x35)`。
  static Uint8List buildFetchBody(Qq8TlvContext ctx, Qq8ApkInfo watch) {
    final w = ByteWriter()
      ..u16(0)
      ..u32(16)
      ..u64(0)
      ..u8(8)
      ..u16(0) // tlv(BUF0)：空长度 + 空内容
      ..u16(6); // 后面跟 6 个 TLV

    // 0x16 在二维码流程里用**手表档案**（与手 Q 的固定值不同，见 qq8_tlv.dart）
    final b16 = ByteWriter()
      ..u32(7)
      ..u32(watch.appid)
      ..u32(watch.subid)
      ..raw(ctx.device.guid);
    for (final s in <String>[watch.id, watch.ver]) {
      final bytes = s.codeUnits;
      b16
        ..u16(bytes.length)
        ..raw(bytes);
    }
    b16
      ..u16(watch.sign.length)
      ..raw(watch.sign);
    final inner16 = b16.build();
    w
      ..u16(0x16)
      ..u16(inner16.length)
      ..raw(inner16);

    for (final tag in const <int>[0x1B, 0x1D, 0x1F, 0x33, 0x35]) {
      final body = Qq8Tlv.body(ctx, tag);
      w
        ..u16(tag)
        ..u16(body.length)
        ..raw(body);
    }
    return w.build();
  }

  /// 轮询请求体（子命令 5）：
  /// `u16 5 ‖ u8 1 ‖ u32 8 ‖ u32 16 ‖ tlv(qrsig) ‖ u64 0 ‖ u8 8 ‖ tlv(空) ‖ u16 0`。
  static Uint8List buildQueryBody(Uint8List qrsig) => (ByteWriter()
        ..u16(5)
        ..u8(1)
        ..u32(8)
        ..u32(16)
        ..u16(qrsig.length)
        ..raw(qrsig)
        ..u64(0)
        ..u8(8)
        ..u16(0) // tlv(BUF0)
        ..u16(0))
      .build();

  /// code2d 包：先套 code2d 内层，再走 `wtlogin.trans_emp` 信封
  /// （uin=0 / cmdid=0x812 / subid=手表档案）。
  static Uint8List buildPacket(
    Qq8SsoContext ctx,
    int cmdid,
    int head,
    Uint8List body, {
    required Qq8ApkInfo watch,
    required int timestampSeconds,
  }) {
    final inner = (ByteWriter()
          ..u32(head)
          ..u32(0x1000)
          ..u16(0)
          ..u32(0x72000000)
          ..u32(timestampSeconds)
          ..u8(2)
          ..u16(44 + body.length)
          ..u16(cmdid)
          ..raw(Uint8List(21))
          ..u8(3)
          ..u16(0)
          ..u16(50)
          ..u32(ctx.seqId + 1)
          ..u64(0)
          ..raw(body)
          ..u8(3))
        .build();

    return Qq8Sso.buildLoginPacket(
      ctx,
      qq8TransEmpCmd,
      Qq8Sso.buildOicqPacket(ctx, inner,
          uinOverride: 0, cmdIdOverride: cmdIdTransEmp),
      Qq8LoginType.login,
      uinOverride: 0,
      subIdOverride: watch.subid,
    );
  }

  /// 解析取码响应。
  ///
  /// 明文布局（参考实现 `fetchQrcode` 的读法）：
  /// `[54 字节 固定头] ‖ u8 retcode ‖ u16-len qrsig ‖ u16(跳过) ‖ TLV…`。
  /// TLV `0x17` 是二维码内容。
  static Qq8QrFetch parseFetch(Uint8List payload, Uint8List shareKey) {
    final plain = qq8DecryptLoginPayload(payload, shareKey);
    if (plain.length < 57) {
      throw Qq8LoginException('取码响应解密后太短（${plain.length} 字节）');
    }
    var p = 54;
    final retcode = plain[p++];
    final qrsigLen = (plain[p] << 8) | plain[p + 1];
    p += 2;
    if (p + qrsigLen > plain.length) {
      throw Qq8LoginException('qrsig 长度越界（$qrsigLen）');
    }
    final qrsig = Uint8List.fromList(plain.sublist(p, p + qrsigLen));
    p += qrsigLen;
    if (p + 2 > plain.length) {
      throw Qq8LoginException('取码响应在 qrsig 之后截断');
    }
    p += 2; // 参考实现里跳过的 2 字节
    final tlvs = qq8ReadTlv(plain, offset: p, tolerateTruncated: true);
    return Qq8QrFetch(
      retcode: retcode,
      qrsig: qrsig,
      qrToken: tlvs[0x17] ?? Uint8List(0),
    );
  }

  /// 解析轮询响应。
  ///
  /// 明文布局（参考实现 `queryQrcodeResult` 的读法）：
  /// `[48 字节] ‖ u16 len [‖ 变长子块] ‖ u32(跳过) ‖ u8 retcode
  ///   [‖ u32(跳过) ‖ u32 uin ‖ u6(跳过) ‖ TLV…]`（方括号内仅 retcode=0 时）。
  ///
  /// 确认后的 TLV 号是**子块内的号**：`0x18`=t106、`0x19`=t16a、`0x65`=t318、
  /// `0x1e`=tgtgt（与登录响应的 `0x106/0x16A/0x318` 不是一套编号，别混）。
  static Qq8QrQuery parseQuery(Uint8List payload, Uint8List shareKey) {
    final plain = qq8DecryptLoginPayload(payload, shareKey);
    if (plain.length < 55) {
      throw Qq8LoginException('轮询响应解密后太短（${plain.length} 字节）');
    }
    var p = 48;
    var len = (plain[p] << 8) | plain[p + 1];
    p += 2;
    if (len > 0) {
      len -= 1;
      if (p >= plain.length) throw Qq8LoginException('轮询响应在子块处截断');
      final marker = plain[p++];
      if (marker == 2) {
        p += 8;
        len -= 8;
      }
      if (len > 0) p += len;
    }
    p += 4;
    if (p >= plain.length) throw Qq8LoginException('轮询响应在 retcode 处截断');
    final retcode = plain[p++];
    if (retcode != 0) return Qq8QrQuery(retcode: retcode);

    p += 4;
    if (p + 4 > plain.length) throw Qq8LoginException('轮询响应在 uin 处截断');
    final uin = (plain[p] << 24) | (plain[p + 1] << 16) | (plain[p + 2] << 8) | plain[p + 3];
    p += 4 + 6;
    if (p > plain.length) throw Qq8LoginException('轮询响应在 TLV 区处截断');
    final tlvs = qq8ReadTlv(plain, offset: p, tolerateTruncated: true);
    return Qq8QrQuery(
      retcode: retcode,
      uin: uin,
      t106: tlvs[0x18],
      t16a: tlvs[0x19],
      t318: tlvs[0x65],
      tgtgt: tlvs[0x1E],
    );
  }
}
