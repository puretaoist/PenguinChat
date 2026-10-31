/// L2 协议内核：上线注册（`StatSvc.register`）
///
/// 登录成功后**必须发的第一个业务请求**：告诉服务器"我上线了"。
/// 信封走登录层（type=1 上线，SSO 层用 d2key 加密），命令字 `StatSvc.register`。
///
/// ## 请求体结构（40 个槽位，tag 0..39；参考实现里 15/25/35/37 传 null → 不写）
///
/// | tag | 值 | 说明 |
/// |---|---|---|
/// | 0 | uin | |
/// | 1 | `logout ? 0 : 7` | 注册类型 |
/// | 2/3 | 0 / "" | |
/// | 4 | `logout ? 21 : 11` | |
/// | 5..9 | 0 | |
/// | 10 | `logout ? 44 : 0` | |
/// | 11 | `device.version.sdk` | |
/// | 12 | 1 | |
/// | 13/14 | "" / 0 | |
/// | 16 | `device.guid` | 字节数组 |
/// | 17 | 2052 | |
/// | 18 | 0 | |
/// | 19/20 | `device.model` | |
/// | 21 | `device.version.release` | 字符串（如 "10"） |
/// | 22..24 | 1 / 0 / 0 | |
/// | 26..29 | 0 / 0 / "" / 0 | |
/// | 30/31 | `device.brand` | |
/// | 32 | "" | |
/// | 33 | pb blob | `{1: [{1:46, 2:ts}, {1:283, 2:0}]}`，见 [Qq8Pb] |
/// | 34 | 0 | |
/// | 36 | 0 | |
/// | 38/39 | 1000 / 98 | |
///
/// 外层是 JCE WUP 包装：service=`PushService`、method=`SvcReqRegister`。
///
/// ## 出处
///
/// 请求体字段表以参考实现 oicq `lib/core/base-client.ts:717-728` 的 `register()`
/// 为准；**响应判读以官方 Java 为准**（见 [Qq8Register.parseResponse]）。
///
/// 官方对应类已定位：`SvcReqRegister`（writeTo 见
/// `com/tencent/msf/service/protocol/push/SvcReqRegister.java:121-190`，
/// 唯一构造点 `com/tencent/mobileqq/msf/core/push/e.java:97-140`）。
/// 逐槽对照表明两边**表意不同**（官方 tag1 是 `lBid`=pushIds 位或=7、
/// tag16 是 `vecGuid`、tag22 是 `bOpenPush`=1、tag38 是
/// `uExtOnlineStatus` 默认 -1、tag39 是 `iBatteryStatus` 默认 0），
/// 但取值恰好能对上官方默认——oicq 那组常量**不是错的**，只是从另一条路
/// 推出来的。真正需要改的是响应判据（见下）。
///
/// 本文件是纯 Dart。
library;

import 'dart:typed_data';

import 'qq8_device.dart';
import 'qq8_jce.dart';
import 'qq8_pb.dart';

/// 在线状态值（参考实现 `icqq` 的 `OnlineStatus` 枚举）。
///
/// 只有 [online] 被真实使用；其余值保留，将来做「离开/勿扰」时不用再查表。
abstract final class Qq8OnlineStatus {
  static const int offline = 0;
  static const int online = 11;
  static const int absent = 31;
}

/// 上线注册请求的组装与响应判读。
abstract final class Qq8Register {
  /// 登录层信封的命令字。
  static const String cmd = 'StatSvc.register';

  /// 在线状态上报的命令字（**UNI 外壳 0x0B**，不是登录外壳 0x0A）。
  ///
  /// 与 [cmd] 是两件事，官方都发：
  /// - `StatSvc.register`（0x0A）：注册这条连接，判据 `SvcRespRegister`
  ///   的 `cReplyCode(tag 2) == 0`（见 [parseResponse]）；
  /// - `StatSvc.SetStatusFromClient`（0x0B）：上报"我现在是在线状态"。
  ///
  /// 出处：[icqq] `lib/internal/internal.js:22-39`（`setStatus`），
  /// 调用点 `lib/internal/listeners.js:93`（登录成功回调里立刻发一次）与
  /// `lib/client.js:225-229`（心跳里 `n++; if (n > 10) { n = 0; setOnlineStatus(); }`，
  /// 即**每 11 次心跳重发一次**）。
  static const String cmdSetStatus = 'StatSvc.SetStatusFromClient';

  /// 组装请求体：JCE 包装（PushService / SvcReqRegister）。
  ///
  /// [nowMillis] 供测试注入固定时间戳（pb blob 里带时间）。
  static Uint8List buildBody({
    required int uin,
    required Qq8Device device,
    bool logout = false,
    int? nowMillis,
  }) {
    final pbBlob = Qq8Pb.encode(<int, Object?>{
      1: <Object?>[
        <int, Object?>{
          1: 46,
          2: nowMillis ?? DateTime.now().millisecondsSinceEpoch,
        },
        <int, Object?>{1: 283, 2: 0},
      ],
    });

    final fields = <int, Object?>{
      0: uin,
      1: logout ? 0 : 7,
      2: 0,
      3: '',
      4: logout ? 21 : 11,
      5: 0,
      6: 0,
      7: 0,
      8: 0,
      9: 0,
      10: logout ? 44 : 0,
      11: device.version.sdk,
      12: 1,
      13: '',
      14: 0,
      // 15: null（参考实现不写）
      16: device.guid,
      17: 2052,
      18: 0,
      19: device.model,
      20: device.model,
      21: device.version.release,
      22: 1,
      23: 0,
      24: 0,
      // 25: null
      26: 0,
      27: 0,
      28: '',
      29: 0,
      30: device.brand,
      31: device.brand,
      32: '',
      33: pbBlob,
      34: 0,
      // 35: null
      36: 0,
      // 37: null
      38: 1000,
      39: 98,
    };

    return Qq8Jce.encodeWrapper(
      service: 'PushService',
      method: 'SvcReqRegister',
      attributes: <String, Uint8List>{
        'SvcReqRegister': Qq8Jce.encodeStruct(fields),
      },
    );
  }

  /// 判读响应：**官方判据是 `SvcRespRegister.cReplyCode(tag 2) == 0`**。
  ///
  /// 出处：`SvcRespRegister.java:63-85` 的 writeTo 字段序——
  /// 0 lUin / 1 lBid / **2 cReplyCode** / 3 strResult / 4 lServerTime /
  /// 5 bLogQQ / 6 bNeedKik / 7 bUpdateFlag / 8 timeStamp / **9 bCrashFlag** / …；
  /// 判据在 `msf/core/push/e.java:196-235`：取出 `b5 = cReplyCode`，
  /// `if (b5 == 0)` 才继续取 `uClientBatteryGetInterval`——即 **0 = 成功**。
  ///
  /// 参考实现（oicq `lib/core/base-client.ts:733-734`）读的 `rsp[9]` 是
  /// **bCrashFlag**（崩溃标记），不是应答码，语义错位。真机上 register 是
  /// **服务端根本没回包**（10s 超时），错位本身没暴露；但一旦服务端回了
  /// 非 0 的 cReplyCode，旧口径会把它误判成成功，所以照官方改。
  ///
  /// 三态解析：`ok` = cReplyCode==0；`rejected` = 有 cReplyCode 但非 0；
  /// `malformed` = 解不开或没有 tag2。
  ///
  /// **不再用 tag9(bCrashFlag) 兜底判成功**：tag9 是崩溃标记，与应答码无关
  /// （oicq 读错的就是这个字段）。缺 tag2 的包属于畸形，既不等于成功，也
  /// 不能当明确被拒——上层按「未确认」处理（可能只是坏包，不等于会话失效）。
  static Qq8RegisterParse parseResponseDetailed(Uint8List payload) {
    final Map<int, Object?> rsp;
    try {
      rsp = Qq8Jce.decodeWrapper(payload);
    } on Object {
      return Qq8RegisterParse.malformed;
    }
    final replyCode = rsp[2];
    if (replyCode is! int) return Qq8RegisterParse.malformed;
    return replyCode == 0 ? Qq8RegisterParse.ok : Qq8RegisterParse.rejected;
  }

  /// 兼容旧调用的布尔版：只有 `ok` 才算成功（畸形/被拒都 false）。
  static bool parseResponse(Uint8List payload) =>
      parseResponseDetailed(payload) == Qq8RegisterParse.ok;

  /// 组装在线状态上报的请求体（**UNI 外壳，命令字见 [cmdSetStatus]**）。
  ///
  /// 结构与 [buildBody] 同源（都是 `SvcReqRegister` 那 40 个槽位），
  /// 但**有 9 处取值不同**——照抄 register 的字段表会得到一个服务端
  /// 不认识的状态包，所以这里逐槽对齐参考实现 `internal.js:22-39`：
  ///
  /// | 槽 | register(在线) | SetStatusFromClient | 说明 |
  /// |---|---|---|---|
  /// | 10 | 0 | **248** | 状态上报专用常量 |
  /// | 12 | 1 | **0** | register 的"是否首次"标志 |
  /// | 23 | 0 | **473** | |
  /// | 30/31 | brand | **""** | 状态包不带厂商 |
  /// | 33 | pb blob | **null** | 状态包不带 pb |
  /// | 34 | 0 | **1** | |
  /// | 38/39 | 1000 / 98 | **0 / 0** | 心跳参数只在 register 里 |
  ///
  /// [status] 用 [Qq8OnlineStatus]；只有在线（11）是实测走过的路径。
  static Uint8List buildSetStatusBody({
    required int uin,
    required Qq8Device device,
    int status = Qq8OnlineStatus.online,
  }) {
    final fields = <int, Object?>{
      0: uin,
      1: 7,
      2: 0,
      3: '',
      4: status,
      5: 0,
      6: 0,
      7: 0,
      8: 0,
      9: 0,
      10: 248,
      11: device.version.sdk,
      12: 0,
      13: '',
      14: 0,
      // 15: null
      16: device.guid,
      17: 2052,
      18: 0,
      19: device.model,
      20: device.model,
      21: device.version.release,
      22: 1,
      23: 473,
      24: 0,
      // 25: null
      26: 0,
      27: 0,
      28: '',
      29: 0,
      30: '',
      31: '',
      32: '',
      // 33: null（状态包没有 pb blob）
      34: 1,
      // 35: null
      36: 0,
      // 37: null
      38: 0,
      39: 0,
    };

    return Qq8Jce.encodeWrapper(
      service: 'PushService',
      method: 'SvcReqRegister',
      attributes: <String, Uint8List>{
        'SvcReqRegister': Qq8Jce.encodeStruct(fields),
      },
    );
  }
}

/// `SvcRespRegister` 的三态解析结果（见 [Qq8Register.parseResponseDetailed]）。
enum Qq8RegisterParse {
  /// `cReplyCode(tag 2) == 0`。
  ok,

  /// 收到应答，但 `cReplyCode != 0`（明确被拒）。
  rejected,

  /// 解不开 / 缺 tag2：畸形包，不能当成功也不能当被拒。
  malformed,
}
