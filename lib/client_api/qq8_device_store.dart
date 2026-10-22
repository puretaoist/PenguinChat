/// L3 客户端 API 层：本机设备身份的持久化
///
/// ## 为什么需要这个文件
///
/// 「读本机设备」解决了大部分字段（机型、指纹、boot_id、/proc/version、基带
/// 都是系统给的真值，重启也不变）。但有**三个值不能每次现算**，必须持久化，
/// 否则每次启动都是一台"新设备"：
///
/// | 值 | 来源 | 不持久化的后果 |
/// |---|---|---|
/// | `androidId` | 系统 `ANDROID_ID`；读不到时官方生成 15 位随机数字 | guid 跟着变 → `guid = MD5(androidId ‖ mac)` 也变 → 设备信任归零 |
/// | `ksid` | **服务端**在响应 TLV `0x108` 下发 | 每次登录都自称"没有 ksid"，等于新设备 |
/// | `qimei` | 灯塔按设备属性签发（36 字符） | 每次启动换号 → 服务端看到设备标识漂移 |
///
/// 三个都有官方先例（都在 SharedPreferences 里只写一次）：
/// * `util.java:415-430` `getRandomAndroidId()`：SP `WLOGIN_DEVICE_INFO` 的
///   `random_AndroidId`，空则生成 **15 位随机数字**并持久化。
/// * `util.java:683-698` `set_ksid()`：SP 的 `ksid`，**只在为空时写**。
/// * QIMEI 在官方 SP `DENGTA_META`（8.2.11）或 `QimeiSDK` 文件（8.9.50+）里缓存。
///
/// ## 为什么不用 SharedPreferences
///
/// 本项目所有持久化都在应用私有目录里自己管（`ChatStore`、票据、日志），
/// 一致性比"用平台的偏好设置"更重要；而且这样纯 Dart 就能读写，
/// 自测里可以直接指到临时目录。
///
/// ## 与 `identity.json` 的关系
///
/// `identity.json` 是**人工导出**的完整身份（含官方客户端的 guid/QIMEI），
/// 用于诊断与对照实验。本文件是**运行时自采**的最小持久状态。
/// 两者同时存在时**以本文件为准**（它是本机真实采集的），
/// `identity.json` 降级为覆盖来源——它的值来自同一台机器的官方客户端，
/// 比自采更接近官方，但需要手动 adb push。
///
/// 实际优先级（见 `qq8DeviceIdentityProvider`）：
/// ```text
///   identity.json（人工注入，含官方 guid/qimei）   ← 最高
///     ↓ 不存在时
///   本文件（自采快照 + 持久化的 androidId/ksid/qimei）
///     ↓ 都没有时
///   Qq8Device.generate(uin)（合成派生，兜底）
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../infra/log/logger.dart';

final Logger _log = Log.get('QQ8DEVICE');

/// 本机设备身份里那些**必须跨进程稳定**的值。
///
/// 全部可空：任何一个没有就表示"还没采到/还没下发"，调用方据此决定要不要生成。
class Qq8DeviceState {
  /// 系统 `ANDROID_ID`，或读不到时官方风格生成的 15 位随机数字。
  final String? androidId;

  /// 服务端下发的 `ksid`（32 位十六进制串）。
  final String? ksid;

  /// 灯塔签发的 QIMEI 原文（36 字符）。
  final String? qimei;

  const Qq8DeviceState({this.androidId, this.ksid, this.qimei});

  Qq8DeviceState copyWith({
    String? androidId,
    String? ksid,
    String? qimei,
  }) =>
      Qq8DeviceState(
        androidId: androidId ?? this.androidId,
        ksid: ksid ?? this.ksid,
        qimei: qimei ?? this.qimei,
      );

  static Qq8DeviceState fromJson(Map<String, Object?> json) {
    String? s(String k) {
      final v = json[k];
      if (v == null) return null;
      final t = '$v'.trim();
      return t.isEmpty ? null : t;
    }

    return Qq8DeviceState(
      androidId: s('android_id'),
      ksid: s('ksid'),
      qimei: s('qimei'),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        if (androidId != null) 'android_id': androidId,
        if (ksid != null) 'ksid': ksid,
        if (qimei != null) 'qimei': qimei,
      };

  /// 诊断用。**不打印 qimei 全值**（它是跨业务共享的设备标识）。
  @override
  String toString() => 'Qq8DeviceState('
      'androidId=${androidId ?? '无'}, '
      'ksid=${ksid == null ? '无' : '有'}, '
      'qimei=${qimei == null ? '无' : '${qimei!.length}字符'})';
}

/// 设备状态的读写接口。
///
/// [MemoryQq8DeviceStore] 供自测用；生产用 [FileQq8DeviceStore]。
abstract class Qq8DeviceStore {
  Future<Qq8DeviceState> load();

  /// 合并保存（只覆盖非空字段）。
  Future<void> save(Qq8DeviceState state);

  /// 同步读。**启动路径专用**：`androidId` 必须在第一帧 UI 之前就确定，
  /// 否则 provider 会在异步间隙里先后产出两台不同设备（guid 跟着变）。
  ///
  /// 文件只有几百字节，同步读的代价可以忽略；换成异步会让调用方被迫
  /// 引入 `AsyncValue`，把整条 provider 链污染成可空/加载态。
  Qq8DeviceState loadSync();

  /// 同步写。同样只用于启动路径（首次生成 `androidId` 时立即落盘）。
  void saveSync(Qq8DeviceState state);
}

/// 只存在内存里的实现（自测 / 桌面）。
class MemoryQq8DeviceStore implements Qq8DeviceStore {
  Qq8DeviceState _state = const Qq8DeviceState();

  @override
  Future<Qq8DeviceState> load() async => _state;

  @override
  Future<void> save(Qq8DeviceState state) async => saveSync(state);

  @override
  Qq8DeviceState loadSync() => _state;

  @override
  void saveSync(Qq8DeviceState state) {
    _state = _state.copyWith(
      androidId: state.androidId,
      ksid: state.ksid,
      qimei: state.qimei,
    );
  }
}

/// 落盘实现：`<dir>/device.json`。
class FileQq8DeviceStore implements Qq8DeviceStore {
  FileQq8DeviceStore(this.dir);

  /// 存放目录（通常是 `<dataDir>/qq8`）。
  final Directory dir;

  File get _file => File('${dir.path}${Platform.pathSeparator}device.json');

  @override
  Future<Qq8DeviceState> load() async => loadSync();

  @override
  Qq8DeviceState loadSync() {
    final f = _file;
    if (!f.existsSync()) return const Qq8DeviceState();
    try {
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is! Map) {
        _log.w('device.json 不是 JSON 对象，按空状态处理');
        return const Qq8DeviceState();
      }
      final state = Qq8DeviceState.fromJson(Map<String, Object?>.from(decoded));
      _log.i('已加载设备状态: $state');
      return state;
    } catch (e) {
      // 损坏就丢：这三项都能重新采集/重新下发，不值得为它让整个后端起不来。
      _log.w('device.json 读取失败，按空状态处理', error: e);
      return const Qq8DeviceState();
    }
  }

  @override
  Future<void> save(Qq8DeviceState state) async => saveSync(state);

  @override
  void saveSync(Qq8DeviceState state) {
    final merged = loadSync().copyWith(
      androidId: state.androidId,
      ksid: state.ksid,
      qimei: state.qimei,
    );
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f = _file;
      // 先写临时文件再 rename：进程在写一半时被杀，不会留下半个 JSON
      // （半个 JSON 会让下次启动读失败 → androidId 重新生成 → 设备信任归零）。
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(
        merged.toJson(),
      ));
      tmp.renameSync(f.path);
      _log.i('设备状态已保存: $merged');
    } catch (e) {
      _log.w('device.json 写入失败', error: e);
    }
  }
}

/// 官方 `util.getRandomAndroidId()` 的等价物：**15 位随机数字**。
///
/// 原文（`jadx-main sources/oicq/wlogin_sdk/tools/util.java:415-430`）在 SP 为空时
/// 生成这样一串并持久化。位数是 15，首位允许 0（它只是一个字符串标识）。
String qq8RandomAndroidId([Random? random]) {
  final rnd = random ?? Random.secure();
  final sb = StringBuffer();
  for (var i = 0; i < 15; i++) {
    sb.write(rnd.nextInt(10));
  }
  return sb.toString();
}
