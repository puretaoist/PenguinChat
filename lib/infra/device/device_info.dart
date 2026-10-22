/// L1 基础设施：本机设备信息采集（纯 Dart，不 import Flutter）
///
/// ## 要解决的问题
///
/// 服务端判"这是不是一台它见过的设备"时，看的是**一组固定的字段**：
/// android_id、`Build.MODEL/BRAND/…`、boot_id、/proc/version、基带、指纹串。
/// 这些字段我们不提供，就只能自己编一台——而编出来的设备有两个硬伤：
///
/// 1. **在现实里不存在**。`brand=OICQX`、`model=Konata 2020` 不是任何厂商的
///    任何机型；服务端一比对机型库就知道是假的。
/// 2. **自相矛盾**。合成设备自称 Android 10 / SDK 29，而真机是 Android 16 /
///    SDK 36；`boot_id` 是哈希切片拼的 UUID，而真实的是内核随机值。
///
/// 所以我们改成**读本机真实值**：同机同装的官方客户端读到什么，我们就读什么。
///
/// ## 为什么仍然不是"完全等于官方"
///
/// Android 8+ 起 `Settings.Secure.ANDROID_ID` 是**按「应用签名密钥 + 用户 + 设备」
/// 三元组隔离**的。官方 QQ 与 TIM 装在同一台机器上，读到的值都不同：
///
/// ```text
///   QQ  日志:  android_id 25cf6881290b58f7
///   TIM 日志:  android_id f23dd554a9f43c9a   (同机同时刻)
/// ```
///
/// 我们换一个签名就是第三个值。**这个目标本身不成立**，不要往这个方向使劲：
/// `android_id` 只是「这台机器上的这个应用」的标识，不是机器标识。
/// 我们能做的是让 **其余字段全部真实**，把"假设备"这个嫌疑降到最低。
///
/// ## 为什么要抽象成接口
///
/// 1. **L1 不能 import Flutter**（`tool/layering_selftest.dart` 会拦，
///    更重要的是 L1 要能在纯 Dart 里跑自测）。真实现走 `MethodChannel`，
///    在 L4（`lib/ui/platform/`），由 `main.dart` 注入。
/// 2. **桌面 / 测试环境没有 Android API**。[NoopDeviceInfo] 让这些场景返回
///    null，调用方据此退回旧的合成派生——零配置可用，也不破坏既有测试。
library;

/// 一次设备信息采集的快照。字段全部是可空的原始字符串，
/// **不在这里做任何推导**（guid 派生、MD5、限长都在上层做）。
///
/// 取不到就是 null/空——调用方必须能接受"只拿到一部分"，
/// 因为权限被拒、ROM 裁剪、SELinux 限制都会让个别字段读不到。
class DeviceSnapshot {
  const DeviceSnapshot({
    this.androidId,
    this.macAddress,
    this.wifiBssid,
    this.wifiSsid,
    this.model,
    this.brand,
    this.product,
    this.device,
    this.board,
    this.bootloader,
    this.fingerprint,
    this.bootId,
    this.procVersion,
    this.baseband,
    this.incremental,
    this.display,
    this.release,
    this.codename,
    this.sdk,
    this.sim,
    this.apn,
    this.osType = 'android',
  });

  /// `Settings.Secure.ANDROID_ID`。**16 位 hex**。
  ///
  /// ⚠️ 读不到时官方不是留空，而是生成一个 **15 位随机数字**并持久化到
  /// SP `WLOGIN_DEVICE_INFO` 的 `random_AndroidId`（`util.java:415-430`）。
  /// 那个持久化由上层负责，这里只如实返回 null。
  final String? androidId;

  /// `WifiInfo.getMacAddress()`。Android 6+ 恒为 `02:00:00:00:00:00`。
  final String? macAddress;

  /// `WifiInfo.getBSSID().toLowerCase()`。**需 `ACCESS_FINE_LOCATION`**。
  final String? wifiBssid;

  /// `WifiInfo.getSSID()`（带引号原文）。同样需定位权限。
  final String? wifiSsid;

  final String? model;
  final String? brand;
  final String? product;
  final String? device;
  final String? board;
  final String? bootloader;
  final String? fingerprint;

  /// `/proc/sys/kernel/random/boot_id` 首行（标准 UUID 文本）。
  final String? bootId;

  /// `/proc/version` 首行。
  final String? procVersion;

  /// `gsm.version.baseband`。读不到时官方回 `""`（不是 null）。
  final String? baseband;

  final String? incremental;
  final String? display;
  final String? release;
  final String? codename;
  final int? sdk;

  /// SIM 运营商名（`TelephonyManager.getSimOperatorName()`）。
  final String? sim;

  /// APN 名：移动网取 `NetworkInfo.getExtraInfo()`，Wi-Fi 恒为 `'wifi'`。
  final String? apn;

  final String? osType;

  /// 是否至少拿到 Android 身份的核心两项。
  ///
  /// 判据刻意宽松：`androidId` 是必须的（它是 guid 的一半），
  /// `macAddress` 在 Android 6+ 恒为常量，读不到也能用常量补。
  bool get usable => androidId != null && androidId!.isNotEmpty;

  @override
  String toString() => 'DeviceSnapshot(model=$model, brand=$brand, '
      'product=$product, device=$device, sdk=$sdk, '
      'androidId=${androidId == null ? 'null' : '有'})';
}

/// 平台侧的设备信息采集能力。
///
/// 实现必须**不抛异常**：任何读失败都返回 null（部分字段取不到就在快照里留空）。
/// 理由——调用方是 provider 初始化路径，抛异常会让整个 QQ8 后端起不来，
/// 而"拿不到设备信息"的合理降级是退回合成派生，不是黑屏。
abstract class DeviceInfo {
  /// 采集一次快照。不支持采集的平台返回 null。
  Future<DeviceSnapshot?> snapshot();

  /// 释放资源（本接口无长生命周期资源，默认空实现）。
  void dispose() {}
}

/// 什么都不做的实现：永远返回 null。
///
/// 用于桌面、单元测试、以及"用户明确不要读设备信息"的场景。
/// 调用方看到 null 就退回 `Qq8Device.generate(uin)` 那条合成派生路径。
class NoopDeviceInfo implements DeviceInfo {
  const NoopDeviceInfo();

  @override
  Future<DeviceSnapshot?> snapshot() async => null;

  @override
  void dispose() {}
}
