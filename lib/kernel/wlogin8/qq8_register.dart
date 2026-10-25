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
/// 参考实现 oicq `lib/core/base-client.ts` 的 `register()`（含信封与响应判读）。
/// ⚠️ 官方对应的 Java 类**尚未定位**（`SvcReqRegister` 字符串在
/// `classes14/18.dex` 可见，但类名混淆）；字段表暂以参考实现为准，
/// **最终裁判是服务端**——发出后看响应 `rsp[9]`。
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
  /// - `StatSvc.register`（0x0A）：注册这条连接，判据 `rsp[9]`；
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

  /// 判读响应：`decodeWrapper(payload)[9]` 真值 = 注册成功（参考实现同款）。
  static bool parseResponse(Uint8List payload) {
    final rsp = Qq8Jce.decodeWrapper(payload);
    final v = rsp[9];
    return v != null && v != 0;
  }

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
