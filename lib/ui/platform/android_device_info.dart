/// L4 平台能力：读本机 Android 设备信息（`MethodChannel` 实现）
///
/// 这一层是 [DeviceInfo] 的真实现。放在 L4 而不是 L1，原因是它必须
/// `import 'package:flutter/services.dart'` —— 而 L1/L2 要能在纯 Dart 里跑自测。
/// 注入方式与 `path_provider` / [ForegroundKeepAlive] 一致：`main.dart` 里 override。
///
/// ## 通道协议（与 `MainActivity.kt` 的 `qqclient/device` 一一对应）
///
/// ```text
///   snapshot → Map<String, Object?>（字段名与 identity.json 的键完全一致，
///              缺项不出现该键，不用 null 占位）
///            → null（平台不支持 / 全部读失败）
/// ```
///
/// **键名与 `Qq8DeviceIdentity.fromJson` 对齐**是刻意的：这样 L4 采到的快照
/// 能原样喂给 `Qq8DeviceIdentity.fromJson`，不必再维护一套映射表
/// （两套映射迟早会漂移，而且漂移的表现是"某个字段悄悄丢失"，很难查）。
///
/// ## 为什么不在这里做推导
///
/// 官方 `generateGuid()` 是 `MD5(androidId ‖ mac)`，`getRandomAndroidId()` 是
/// "读不到就生成 15 位数字并持久化"。这些都是**协议语义**，属于 `lib/kernel/
/// wlogin8/` 的职责。这里只负责"如实把系统 API 的返回值带上来"。
library;

import 'package:flutter/services.dart';

import '../../infra/device/device_info.dart';

class AndroidDeviceInfo implements DeviceInfo {
  AndroidDeviceInfo();

  static const MethodChannel _channel = MethodChannel('qqclient/device');

  @override
  Future<DeviceSnapshot?> snapshot() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('snapshot');
      if (raw == null || raw.isEmpty) return null;

      String? s(String k) {
        final v = raw[k];
        if (v == null) return null;
        final t = '$v'.trim();
        return t.isEmpty ? null : t;
      }

      final snap = DeviceSnapshot(
        androidId: s('android_id'),
        macAddress: s('mac'),
        wifiBssid: s('wifi_bssid'),
        wifiSsid: s('wifi_ssid'),
        model: s('model'),
        brand: s('brand'),
        product: s('product'),
        device: s('device'),
        board: s('board'),
        bootloader: s('bootloader'),
        fingerprint: s('fingerprint'),
        bootId: s('boot_id'),
        procVersion: s('proc_version'),
        baseband: s('baseband'),
        incremental: s('incremental'),
        display: s('display'),
        release: s('release'),
        codename: s('codename'),
        sdk: raw['sdk'] is num ? (raw['sdk']! as num).toInt() : null,
        sim: s('sim'),
        apn: s('apn'),
        osType: s('os_type') ?? 'android',
      );

      // 核心项缺失就不算「读到了」——上层据此退回合成派生，
      // 而不是拿一台半个字段的设备去登录（那比全合成更可疑）。
      return snap.usable ? snap : null;
    } on MissingPluginException {
      // 桌面 / 未接原生通道：静默降级。
      return null;
    } on PlatformException {
      // 权限被拒、ROM 裁剪等：同样是降级，不抛给上层。
      return null;
    }
  }

  @override
  void dispose() {}
}
