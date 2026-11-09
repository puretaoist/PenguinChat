/// PC NTLogin 的 `EasyLogin` / `UnusualEasyLogin`（免密续期）。
///
/// ## 出处（Acidify，逐项核过）
/// - `internal/service/system/NTLogin.kt`
/// - `internal/proto/login/NTLogin.kt`、`internal/proto/login/NTEcdh.kt`（NTLoginForwardRequest）
///
/// ## 结构（build）
/// ```
/// NTLoginForwardRequest {
///  1: sessionTicket                      ← KeyExchange 拿到
///  3: buffer = AES-GCM( NTLoginCommon, sessionKey )
///  4: type = 1
///  // 5: secBuffer —— Acidify 不赋值
/// }
/// NTLoginCommon {
///  1: head {
///       1: userInfo  { 1: account(uin 字符串) }
///       2: clientInfo{ 1: deviceType=os, 2: deviceName, 3: platform(int), 4: guid }
///       3: appInfo   { 1: version=kernel, 2: appId, 3: appName=packageName, 5: qua }
///       4: errorInfo （响应里才有）
///       5: cookie    { 1: cookieContent = unusualCookies }
///       7: sdkInfo   { 1: version = 1 }
///   }
///  2: body = EasyLoginReqBody{ 1: a1 }
/// }
/// ```
/// ## 响应
/// ```
/// NTLoginCommon.head.errorInfo.errCode:
///   0          → body.pbDecode<EasyLoginRspBody>{1:tickets{3:a1,4:a2,5:d2,6:d2Key}}
///   140022011  → body.pbDecode<EasyLoginRspBody>.secProtect{2:unusualDeviceCheckSig}
///   其他        → Failure(errCode, strTipsTitle, strTipsContent)
/// ```
library;

import 'dart:typed_data';

import 'pc_crypto.dart';
import 'pc_proto.dart';

/// 平台整数（Acidify `NTLogin.kt` 的 `AppInfo.platform`）。
int pcPlatformFor(String os) {
  switch (os.toLowerCase()) {
    case 'windows':
      return 4;
    case 'mac':
    case 'macos':
      return 5;
    case 'linux':
      return 7;
    default:
      return 0;
  }
}

/// QUA（Acidify `NTLogin.kt` 的 `AppInfo.qua`）：`V1_{WIN|MAC|LNX}_NQ_{ver}_GW_B`。
/// 注意 version 的 `-` 要换成 `_`。
String pcQuaFor(String os, String currentVersion) {
  final String p;
  switch (os.toLowerCase()) {
    case 'windows':
      p = 'WIN';
      break;
    case 'mac':
    case 'macos':
      p = 'MAC';
      break;
    case 'linux':
      p = 'LNX';
      break;
    default:
      throw ArgumentError('Unsupported NTLogin platform: $os');
  }
  return 'V1_${p}_NQ_${currentVersion.replaceAll('-', '_')}_GW_B';
}

/// EasyLogin 结果状态。
enum PcNtLoginStatus { success, unusualDevice, failure }

/// 解析结果。
class PcNtLoginResult {
  PcNtLoginResult({
    required this.status,
    Uint8List? a1,
    Uint8List? a2,
    Uint8List? d2,
    Uint8List? d2Key,
    Uint8List? unusualSig,
    this.errCode = 0,
    this.errTag = '',
    this.errMsg = '',
    this.newUnusualCookies,
  })  : a1 = a1 ?? Uint8List(0),
        a2 = a2 ?? Uint8List(0),
        d2 = d2 ?? Uint8List(0),
        d2Key = d2Key ?? Uint8List(0),
        unusualSig = unusualSig ?? Uint8List(0);

  final PcNtLoginStatus status;
  final Uint8List a1;
  final Uint8List a2;
  final Uint8List d2;
  final Uint8List d2Key;
  final Uint8List unusualSig;
  final int errCode;
  final String errTag;
  final String errMsg;

  /// 响应 head.cookie 里回传的 unusualCookies（若有，调用方应回写会话）。
  final String? newUnusualCookies;

  bool get ok => status == PcNtLoginStatus.success;
}

abstract final class PcNtLogin {
  static const int unusualDeviceErrCode = 140022011;

  /// 构造 NTLoginForwardRequest 的 payload（EasyLogin 与 UnusualEasyLogin 的 body 相同，仅 SSO 命令不同）。
  static Uint8List buildEasyLoginPayload({
    required Uint8List sessionTicket,
    required Uint8List sessionKey,
    required Uint8List encryptedA1,
    required String account, // uin 字符串
    required String os,
    required String kernel,
    required String deviceName,
    required int appId,
    required String packageName,
    required String currentVersion,
    required Uint8List guid,
    String? unusualCookies,
  }) {
    // body = EasyLoginReqBody{ 1: a1 }
    final body = (PbWriter()..writeBytes(1, encryptedA1)).toBytes();
    final common = _encodeCommon(
      account: account,
      os: os,
      kernel: kernel,
      deviceName: deviceName,
      appId: appId,
      packageName: packageName,
      currentVersion: currentVersion,
      guid: guid,
      unusualCookies: unusualCookies,
      body: body,
    );
    final buffer = PcAesGcm.encrypt(sessionKey, common);
    return (PbWriter()
          ..writeBytes(1, sessionTicket)
          ..writeBytes(3, buffer)
          ..writeInt(4, 1))
        .toBytes();
  }

  static Uint8List _encodeCommon({
    required String account,
    required String os,
    required String kernel,
    required String deviceName,
    required int appId,
    required String packageName,
    required String currentVersion,
    required Uint8List guid,
    required String? unusualCookies,
    required Uint8List body,
  }) {
    final userInfo = (PbWriter()..writeString(1, account)).toBytes();
    final clientInfo = (PbWriter()
          ..writeString(1, os)
          ..writeString(2, deviceName)
          ..writeInt(3, pcPlatformFor(os))
          ..writeBytes(4, guid))
        .toBytes();
    final appInfo = (PbWriter()
          ..writeString(1, kernel)
          ..writeInt(2, appId)
          ..writeString(3, packageName)
          ..writeString(5, pcQuaFor(os, currentVersion)))
        .toBytes();
    final sdkInfo = (PbWriter()..writeInt(1, 1)).toBytes();

    final head = PbWriter()
      ..writeBytes(1, userInfo)
      ..writeBytes(2, clientInfo)
      ..writeBytes(3, appInfo);
    if (unusualCookies != null && unusualCookies.isNotEmpty) {
      head.writeBytes(5, (PbWriter()..writeString(1, unusualCookies)).toBytes());
    }
    head.writeBytes(7, sdkInfo);

    return (PbWriter()
          ..writeBytes(1, head.toBytes())
          ..writeBytes(2, body))
        .toBytes();
  }

  /// 解析 EasyLogin 响应。[sessionKey] 必须是本次 KeyExchange 拿到的 exchangeKey。
  ///
  /// [expectUnusualDeviceResponse] = true 时解析 `UnusualEasyLogin` 的响应
  /// （body = UnusualDeviceRspBody{1:tickets}，无 secProtect 分支）。
  static PcNtLoginResult parseEasyLoginResponse(
    Uint8List payload,
    Uint8List sessionKey, {
    bool expectUnusualDeviceResponse = false,
  }) {
    // 1) 解 NTLoginForwardRequest → buffer(3)
    Uint8List? buffer;
    final r = PbReader(payload);
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 3) {
        buffer = r.readBytes();
      } else {
        r.skip(w);
      }
    }
    if (buffer == null) {
      throw const FormatException('NTLogin 响应缺 buffer(field 3)');
    }

    // 2) AES-GCM 解密 → NTLoginCommon
    final commonBytes = PcAesGcm.decrypt(sessionKey, buffer);
    Uint8List? head;
    Uint8List? bodyBytes;
    final c = PbReader(commonBytes);
    while (!c.atEnd) {
      final (f, w) = c.readTag();
      if (f == 1) {
        head = c.readBytes();
      } else if (f == 2) {
        bodyBytes = c.readBytes();
      } else {
        c.skip(w);
      }
    }
    if (head == null) throw const FormatException('NTLogin 响应缺 head(field 1)');
    bodyBytes ??= Uint8List(0);

    // 3) head：errorInfo(4) / cookie(5)
    var errCode = 0;
    var errTag = '';
    var errMsg = '';
    String? cookies;
    final h = PbReader(head);
    while (!h.atEnd) {
      final (f, w) = h.readTag();
      if (f == 4) {
        final e = PbReader(h.readBytes());
        while (!e.atEnd) {
          final (ef, ew) = e.readTag();
          if (ef == 1) {
            errCode = e.readVarint();
          } else if (ef == 2) {
            errTag = e.readString();
          } else if (ef == 3) {
            errMsg = e.readString();
          } else {
            e.skip(ew);
          }
        }
      } else if (f == 5) {
        final ck = PbReader(h.readBytes());
        while (!ck.atEnd) {
          final (cf, cw) = ck.readTag();
          if (cf == 1) {
            cookies = ck.readString();
          } else {
            ck.skip(cw);
          }
        }
      } else {
        h.skip(w);
      }
    }

    // 4) 分支
    if (errCode == 0) {
      return _successFromBody(bodyBytes, cookies);
    }
    if (!expectUnusualDeviceResponse && errCode == unusualDeviceErrCode) {
      final sig = _unusualSigFromBody(bodyBytes);
      return PcNtLoginResult(
        status: PcNtLoginStatus.unusualDevice,
        unusualSig: sig,
        errCode: errCode,
        newUnusualCookies: cookies,
      );
    }
    return PcNtLoginResult(
      status: PcNtLoginStatus.failure,
      errCode: errCode,
      errTag: errTag,
      errMsg: errMsg,
      newUnusualCookies: cookies,
    );
  }

  static PcNtLoginResult _successFromBody(Uint8List bodyBytes, String? cookies) {
    // EasyLoginRspBody{ 1: tickets }
    Uint8List? tickets;
    final b = PbReader(bodyBytes);
    while (!b.atEnd) {
      final (f, w) = b.readTag();
      if (f == 1) {
        tickets = b.readBytes();
      } else {
        b.skip(w);
      }
    }
    if (tickets == null) {
      throw const FormatException('EasyLogin 响应缺 tickets(field 1)');
    }
    // NTLoginTickets{ 3:a1, 4:a2, 5:d2, 6:d2Key }
    var a1 = Uint8List(0), a2 = Uint8List(0), d2 = Uint8List(0), d2Key = Uint8List(0);
    final t = PbReader(tickets);
    while (!t.atEnd) {
      final (f, w) = t.readTag();
      switch (f) {
        case 3:
          a1 = Uint8List.fromList(t.readBytes());
        case 4:
          a2 = Uint8List.fromList(t.readBytes());
        case 5:
          d2 = Uint8List.fromList(t.readBytes());
        case 6:
          d2Key = Uint8List.fromList(t.readBytes());
        default:
          t.skip(w);
      }
    }
    return PcNtLoginResult(
      status: PcNtLoginStatus.success,
      a1: a1,
      a2: a2,
      d2: d2,
      d2Key: d2Key,
      newUnusualCookies: cookies,
    );
  }

  static Uint8List _unusualSigFromBody(Uint8List bodyBytes) {
    // EasyLoginRspBody{ 3: secProtect{ 2: unusualDeviceCheckSig } }
    Uint8List? secProtect;
    final b = PbReader(bodyBytes);
    while (!b.atEnd) {
      final (f, w) = b.readTag();
      if (f == 3) {
        secProtect = b.readBytes();
      } else {
        b.skip(w);
      }
    }
    if (secProtect == null) return Uint8List(0);
    final s = PbReader(secProtect);
    while (!s.atEnd) {
      final (f, w) = s.readTag();
      if (f == 2) return Uint8List.fromList(s.readBytes());
      s.skip(w);
    }
    return Uint8List(0);
  }
}
