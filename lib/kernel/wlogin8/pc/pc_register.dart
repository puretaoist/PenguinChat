/// PC 上线/下线报文（对齐 Diana `packet/system.ts`）。
///
/// 上线命令：`trpc.msg.register_proxy.RegisterProxy.SsoInfoSync`
/// 下线命令：`trpc.qq_new_tech.status_svc.StatusService.UnRegister`
/// 心跳：`trpc.qq_new_tech.status_svc.StatusService.SsoHeartBeat`；Alive：`Heartbeat.Alive`
library;

import 'dart:typed_data';

import 'pc_proto.dart';

abstract final class PcRegister {
  static const registerCommand = 'trpc.msg.register_proxy.RegisterProxy.SsoInfoSync';
  static const unregisterCommand =
      'trpc.qq_new_tech.status_svc.StatusService.UnRegister';

  /// `RegisterDeviceInfo`：1 user, 2 os, 3 osVer, 4 vendorName?, 5 osLower。
  static Uint8List _device({
    required String deviceName,
    required String kernel,
    required String systemKernel,
    required String vendorOs,
  }) =>
      (PbWriter()
            ..writeString(1, deviceName) // user
            ..writeString(2, kernel) // os
            ..writeString(3, systemKernel) // osVer
            ..writeString(5, vendorOs)) // osLower
          .toBytes();

  /// 构造 `SsoInfoSync` 上线包（字段号见 `packet/system.ts`）。
  static Uint8List buildSsoInfoSync({
    required String guidHex,
    required String currentVersion,
    required String deviceName,
    required String kernel,
    required String systemKernel,
    required String vendorOs,
    int? reqRandom,
  }) {
    final dev = _device(
      deviceName: deviceName,
      kernel: kernel,
      systemKernel: systemKernel,
      vendorOs: vendorOs,
    );
    final biz = (PbWriter()
          ..writeInt(1, 1) // notifySwitch
          ..writeInt(2, 1)) // bindUinNotifySwitch
        .toBytes();
    final reg = (PbWriter()
          ..writeString(1, guidHex) // guid
          ..writeInt(2, 0) // kickPC
          ..writeString(3, currentVersion)
          ..writeInt(4, 1) // isFirstRegisterProxyOnline
          ..writeInt(5, 2052) // localeId
          ..writeBytes(6, dev) // device
          ..writeInt(7, 0) // setMute
          ..writeInt(8, 6) // registerVendorType
          ..writeInt(9, 0) // regType
          ..writeBytes(10, biz) // businessInfo
          ..writeInt(11, 0) // batteryStatus
          ..writeInt(12, 1)) // field12
        .toBytes();
    final cookie = (PbWriter()..writeInt(1, 0)).toBytes(); // c2cLastMsgTime u64=0
    final c2c = (PbWriter()
          ..writeBytes(1, cookie) // c2cMsgCookie
          ..writeInt(2, 0) // c2cLastMsgTime
          ..writeBytes(3, cookie)) // lastC2cMsgCookie
        .toBytes();
    final unknown = (PbWriter()
          ..writeInt(1, 0) // groupCode
          ..writeInt(2, 2)) // flag2
        .toBytes();
    final appState = (PbWriter()
          ..writeInt(1, 0)
          ..writeInt(2, 0)
          ..writeInt(3, 0))
        .toBytes();
    final rnd = reqRandom ??
        (DateTime.now().microsecondsSinceEpoch & 0x7fffffff);
    return (PbWriter()
          ..writeInt(1, 735) // syncFlag
          ..writeInt(2, rnd) // reqRandom
          ..writeInt(4, 2) // curActiveStatus
          ..writeInt(5, 0) // groupLastMsgTime u64=0
          ..writeBytes(6, c2c) // c2cInfoSync
          ..writeBytes(9, reg) // registerInfo
          ..writeBytes(10, unknown) // unknownStructure
          ..writeBytes(11, appState)) // appState
        .toBytes();
  }

  /// 解析 `SsoInfoSyncResponse.registerInfoResponse.message`（7→2）。
  static String parseSsoInfoSyncResponse(Uint8List bytes) {
    final r = PbReader(bytes);
    Uint8List? rir;
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 7) {
        rir = r.readBytes();
      } else {
        r.skip(w);
      }
    }
    if (rir == null) return '';
    final rr = PbReader(rir);
    var msg = '';
    while (!rr.atEnd) {
      final (f, w) = rr.readTag();
      if (f == 2) {
        msg = rr.readString();
      } else {
        rr.skip(w);
      }
    }
    return msg;
  }

  /// `UnRegisterInfo{ 2: device }`。
  static Uint8List buildUnRegister({
    required String deviceName,
    required String kernel,
    required String systemKernel,
    required String vendorOs,
  }) {
    final dev = _device(
      deviceName: deviceName,
      kernel: kernel,
      systemKernel: systemKernel,
      vendorOs: vendorOs,
    );
    return (PbWriter()..writeBytes(2, dev)).toBytes();
  }

  /// `SsoHeartBeat{ 1: type=1 }`。
  static Uint8List buildHeartbeat() => (PbWriter()..writeInt(1, 1)).toBytes();
}
