/// PC NTLogin 登录相关的 Riverpod 装配（L3，纯 Dart）。
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:riverpod/riverpod.dart';

import 'pc_login_service.dart';
import 'session_providers.dart' show dataDirProvider;

/// PC NTLogin 签名服务地址（Diana/PureSignServer 的 `/sign`）。
///
/// ⚠️ App 跑在手机上时，这里要改成手机可达的地址（如同一局域网 PC 的 `http://<ip>:8099/sign`），
/// `127.0.0.1` 只在 PC 本机运行 tool 时有效。
final pcSignServerProvider = StateProvider<String>((_) => '');
// 空字符串 = 用纯 Dart 内置签名（pc_sign.dart）；填地址则改走外部签名服务。

/// PC 扫码登录服务。
final pcLoginServiceProvider = Provider<PcLoginService>((ref) {
  final dataDir = ref.watch(dataDirProvider);
  final svc = PcLoginService(
    signServer: ref.watch(pcSignServerProvider),
    guid: _loadOrCreatePcGuid(dataDir),
    deviceName: _loadOrCreatePcDeviceName(dataDir),
    pcDataDir: dataDir,
  );
  ref.onDispose(svc.dispose);
  return svc;
});

/// PC 登录使用的 16 字节设备 guid（持久化到 `<dataDir>/pc/device_guid.bin`）。
/// guid 是客户端自证身份，任意 16 字节随机即可（服务端只存不校验）。
Uint8List _loadOrCreatePcGuid(Directory dataDir) {
  try {
    final dir = Directory('${dataDir.path}${Platform.pathSeparator}pc');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File('${dir.path}${Platform.pathSeparator}device_guid.bin');
    if (f.existsSync()) {
      final b = f.readAsBytesSync();
      if (b.length == 16) return Uint8List.fromList(b);
    }
    final r = Random.secure();
    final g = Uint8List.fromList(List<int>.generate(16, (_) => r.nextInt(256)));
    f.writeAsBytesSync(g);
    return g;
  } catch (_) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(16, (_) => r.nextInt(256)));
  }
}

/// 设备名：必须是**正常 PC 主机名**（`DESKTOP-XXXXXXX`），持久化到 `<dataDir>/pc/device_name.txt`。
///
/// ⚠️ 千万不能用 `ACIDIFY`/`Lagrange`/`DESKTOP-ACIDIFY` 这类**第三方库特征名**——
/// 腾讯风控会直接把它识别成「外挂/风险设备」并下线+限制（实测截图：设备名 Lagrange-130DB3 被抓）。
String _loadOrCreatePcDeviceName(Directory dataDir) {
  // Linux 桌面主机名风格（小写），与 os=Linux 自洽；不要 DESKTOP-/库名。
  const chars = 'abcdefghijkmnpqrstuvwxyz0123456789';
  String gen() {
    final r = Random.secure();
    return 'ubuntu-${List<String>.generate(6, (_) => chars[r.nextInt(chars.length)]).join()}';
  }

  try {
    final dir = Directory('${dataDir.path}${Platform.pathSeparator}pc');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File('${dir.path}${Platform.pathSeparator}device_name.txt');
    if (f.existsSync()) {
      final s = f.readAsStringSync().trim();
      if (s.isNotEmpty) return s;
    }
    final name = gen();
    f.writeAsStringSync(name);
    return name;
  } catch (_) {
    return gen();
  }
}
