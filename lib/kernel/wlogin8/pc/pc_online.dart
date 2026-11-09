/// PC 登录后的长连接服务：`Register`（上线）/ `Alive` / `Heartbeat` / `UnRegister`（下线）。
///
/// ## 出处（Acidify，逐项核过）
/// - `internal/service/system/BotOnline.kt` / `Alive.kt` / `Heartbeat.kt` / `BotOffline.kt`
/// - `internal/proto/system/{RegisterInfo,UnRegisterInfo,DeviceInfo,OnlineBusinessInfo,SsoHeartBeat}.kt`
/// - `internal/context/PacketContext.kt` 的 `postOnline()`：每 10s `Alive`，每 27 次发一次 `Heartbeat`。
///
/// ## 传输差异
/// - `Register` / `Heartbeat` / `UnRegister`：`RequestType.D2Auth` → protocol12，`EncryptType.WithD2Key`
/// - `Alive`：`RequestType.Simple` → **protocol13**，`EncryptType.None`，payload 固定 `[0,0,0,4]`
library;

import 'dart:async';
import 'dart:typed_data';

import 'pc_proto.dart';
import 'pc_sso.dart';

/// 一个长连接服务的发送参数。
class PcOnlineService {
  const PcOnlineService(this.cmd, {this.simple = false});

  final String cmd;

  /// true = 走 protocol13（Simple/None）；false = protocol12（D2Auth/WithD2Key）。
  final bool simple;
}

abstract final class PcOnline {
  static const aliveCmd = 'Heartbeat.Alive';
  static const heartbeatCmd =
      'trpc.qq_new_tech.status_svc.StatusService.SsoHeartBeat';
  static const registerCmd =
      'trpc.qq_new_tech.status_svc.StatusService.Register';
  static const unregisterCmd =
      'trpc.qq_new_tech.status_svc.StatusService.UnRegister';

  static const aliveService = PcOnlineService(aliveCmd, simple: true);
  static const heartbeatService = PcOnlineService(heartbeatCmd);
  static const registerService = PcOnlineService(registerCmd);
  static const unregisterService = PcOnlineService(unregisterCmd);

  /// `Alive` payload：`[0,0,0,4]`（Acidify `Alive.build`）。
  static Uint8List buildAlivePayload() => Uint8List.fromList(<int>[0, 0, 0, 4]);

  /// `Heartbeat` payload：`SsoHeartBeat{ 1: type=1 }`。
  static Uint8List buildHeartbeatPayload() =>
      (PbWriter()..writeInt(1, 1)).toBytes();

  /// `DeviceInfo`（Acidify `util/GenerateDeviceInfo.kt`）。
  static Uint8List _device({
    required String deviceName,
    required String kernel,
    required String os,
    required String vendorOs,
  }) {
    String osVer;
    if (os == 'Windows') {
      osVer = 'Windows 10.0.19042';
    } else if (os == 'Mac') {
      osVer = 'macOS 14.4.1';
    } else if (os == 'Linux') {
      osVer = 'Ubuntu 22.04.4 LTS';
    } else {
      osVer = '';
    }
    return (PbWriter()
          ..writeString(1, deviceName) // devName
          ..writeString(2, kernel) // devType
          ..writeString(3, osVer) // osVer
          ..writeString(5, vendorOs)) // vendorOsName
        .toBytes();
  }

  /// `RegisterInfo`（Acidify `BotOnline.build`）：
  /// `{1: guid(hex), 3: currentVersion, 6: device, 10: businessInfo{1:1,2:1}}`。
  static Uint8List buildRegisterPayload({
    required String guidHex,
    required String currentVersion,
    required String deviceName,
    required String kernel,
    required String os,
    required String vendorOs,
  }) {
    final device = _device(
      deviceName: deviceName,
      kernel: kernel,
      os: os,
      vendorOs: vendorOs,
    );
    final businessInfo = (PbWriter()
          ..writeInt(1, 1) // notifySwitch
          ..writeInt(2, 1)) // bindUinNotifySwitch
        .toBytes();
    return (PbWriter()
          ..writeString(1, guidHex)
          ..writeString(3, currentVersion)
          ..writeBytes(6, device)
          ..writeBytes(10, businessInfo))
        .toBytes();
  }

  /// `UnRegisterInfo{ 2: device }`（Acidify `BotOffline.build`，注意 device 在字段 2）。
  static Uint8List buildUnRegisterPayload({
    required String deviceName,
    required String kernel,
    required String os,
    required String vendorOs,
  }) {
    final device = _device(
      deviceName: deviceName,
      kernel: kernel,
      os: os,
      vendorOs: vendorOs,
    );
    return (PbWriter()..writeBytes(2, device)).toBytes();
  }

  /// 解析 `RegisterInfoResponse`，返回 `message`（字段 2）。
  /// Acidify：`message == "register success"` 才算成功。
  static String parseRegisterResponse(Uint8List payload) {
    final r = PbReader(payload);
    var msg = '';
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 2) {
        msg = r.readString();
      } else {
        r.skip(w);
      }
    }
    return msg;
  }

  static bool isRegisterSuccess(String message) => message == 'register success';
}

/// 心跳节奏（Acidify `PacketContext.postOnline`）：每 10s 一次 `Alive`，
/// 每 `heartbeatEveryNAlive` 次 `Alive`（=270s）补发一次 `Heartbeat` 并把计数清零。
class PcHeartbeatScheduler {
  static const int aliveIntervalSeconds = 10;
  static const int heartbeatEveryNAlive = 27;

  int _aliveCount = 0;
  int get aliveCount => _aliveCount;

  /// 返回本次 tick 应依次发送的命令字（正常为 `[Alive]`，第 27 个 tick 为 `[Alive, Heartbeat]`）。
  List<String> nextTick() {
    _aliveCount++;
    final out = <String>[PcOnline.aliveCmd];
    if (_aliveCount % heartbeatEveryNAlive == 0) {
      out.add(PcOnline.heartbeatCmd);
      _aliveCount = 0;
    }
    return out;
  }
}

/// 长连接发送抽象：把「命令 + payload + 是否 Simple」发出去，返回 SSO 响应。
///
/// 真机实现基于 Socket（见 `tool/pc_qr_login_flow.dart` 的 `_ConnTransport`）；
/// 离线测试可用 Fake 实现，从而不联网即可验证 `PcOnlineSession` 的收发布局。
abstract class PcPacketTransport {
  Future<PcSsoResponse> send({
    required String command,
    required Uint8List payload,
    required bool simple,
  });
}

/// 长连接异常（Register/Alive/Heartbeat 失败）。
class PcOnlineException implements Exception {
  PcOnlineException(this.message);
  final String message;
  @override
  String toString() => 'PcOnlineException: $message';
}

/// 长连接会话管理：`online()` 发 Register 并校验，[tick] 驱动一次心跳，
/// [startHeartbeat] 起 10s 定时器（真机用），[offline] 停心跳并发 UnRegister。
///
/// 心跳顺序完全由 [PcHeartbeatScheduler] 决定（10s Alive，每 27 次补 Heartbeat）。
class PcOnlineSession {
  PcOnlineSession({
    required this.transport,
    required this.registerPayload,
    required this.unRegisterPayload,
    PcHeartbeatScheduler? scheduler,
  }) : scheduler = scheduler ?? PcHeartbeatScheduler();

  final PcPacketTransport transport;
  final Uint8List registerPayload;
  final Uint8List unRegisterPayload;
  final PcHeartbeatScheduler scheduler;

  Timer? _timer;
  bool _online = false;
  bool get isOnline => _online;

  /// 发送 Register 上线包。仅当响应 `message == "register success"` 才视为成功。
  Future<void> online() async {
    final resp = await transport.send(
      command: PcOnline.registerCmd,
      payload: registerPayload,
      simple: false,
    );
    if (resp.retCode != 0) {
      throw PcOnlineException('Register retCode=${resp.retCode} ${resp.extra}');
    }
    final msg = PcOnline.parseRegisterResponse(resp.payload);
    if (!PcOnline.isRegisterSuccess(msg)) {
      throw PcOnlineException('Register 失败：$msg');
    }
    _online = true;
  }

  /// 执行一次心跳 tick（Alive，必要时附加 Heartbeat）。可被定时器或测试手动调用。
  Future<void> tick() async {
    for (final cmd in scheduler.nextTick()) {
      if (cmd == PcOnline.aliveCmd) {
        final r = await transport.send(
          command: PcOnline.aliveCmd,
          payload: PcOnline.buildAlivePayload(),
          simple: true,
        );
        if (r.retCode != 0) {
          throw PcOnlineException('Alive retCode=${r.retCode} ${r.extra}');
        }
      } else {
        final r = await transport.send(
          command: PcOnline.heartbeatCmd,
          payload: PcOnline.buildHeartbeatPayload(),
          simple: false,
        );
        if (r.retCode != 0) {
          throw PcOnlineException('Heartbeat retCode=${r.retCode} ${r.extra}');
        }
      }
    }
  }

  /// 启动 10s 周期定时器驱动 [tick]（真机在线期间调用）。
  void startHeartbeat() {
    _timer ??= Timer.periodic(
      const Duration(seconds: PcHeartbeatScheduler.aliveIntervalSeconds),
      (_) {
        // 心跳异常不应导致未捕获错误，交由上层通过 isOnline 或日志观察。
        tick();
      },
    );
  }

  /// 停心跳并发 UnRegister 下线。
  Future<void> offline() async {
    _timer?.cancel();
    _timer = null;
    if (!_online) return;
    _online = false;
    await transport.send(
      command: PcOnline.unregisterCmd,
      payload: unRegisterPayload,
      simple: false,
    );
  }
}

