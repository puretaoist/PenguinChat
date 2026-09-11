/// L2 协议内核：设备信息（QQ 8.2.11 登录用）
///
/// ## 关于"设备指纹"
///
/// 本文件按参考实现 `takayama-lily/oicq` 的 `lib/device.js` 移植。它的特点
/// 值得说明：**设备信息由账号（uin）确定性派生，而不是采集真实设备**。
///
/// 参考实现里那套值一眼是梗名：
///
/// ```js
/// "product": "MRS4S",     // Mirai-S
/// "device":  "HIM188MOE",
/// "board":   "MIRAI-YYDS",
/// "brand":   "OICQX",
/// "model":   "Konata 2020",
/// ```
///
/// 也就是说 **8.2.11 时代服务端不校验设备信息的真实性**。本项目同样使用
/// 合成设备信息，理由有二：
///
///   1. 不采集用户真实设备信息，隐私上更干净；
///   2. 同一账号始终得到同一设备，避免"设备频繁变化"这个明显的风控信号。
///
/// ⚠️ 注意这是**协议层的数据构造**，不是设备指纹伪造或反检测手段。
/// 本模块不含任何规避风控的机制，也不提供真实机型伪装。
///
/// ## 确定性
///
/// [Qq8Device.generate] 对同一 `uin` 恒定输出同一份设备信息
/// （除 `imsi` / `tgtgt` 两个随机字段外），便于排障与复现。
///
/// 本文件是纯 Dart。
library;

import 'dart:math';
import 'dart:typed_data';

import '../crypto/digest.dart';

/// Android 版本信息。
class Qq8AndroidVersion {
  final String release;
  final String codename;
  final String incremental;
  final int sdk;

  const Qq8AndroidVersion({
    this.release = '10',
    this.codename = 'REL',
    this.incremental = '0',
    this.sdk = 29,
  });
}

/// 一份设备信息。
class Qq8Device {
  // -- 构建信息（TLV 0x52d / 0x16e / 0x128 会用到）--
  final String product;
  final String device;
  final String board;
  final String brand;
  final String model;
  final String bootloader;
  final String fingerprint;
  final String bootId;
  final String procVersion;
  final String baseband;

  // -- 网络与标识 --
  final String sim;
  final String apn;
  final String osType;
  final String macAddress;
  final String ipAddress;
  final String wifiBssid;
  final String wifiSsid;
  final String imei;
  final String androidId;

  /// 安卓版本。
  final Qq8AndroidVersion version;

  /// IMSI（16 字节，随机）。
  final Uint8List imsi;

  /// TGTGT 的随机种子（16 字节）。TLV 0x106 / 0x144 的加密密钥之一。
  final Uint8List tgtgt;

  /// 设备 guid：`MD5(IMEI + MAC)`。
  ///
  /// 多个 TLV 直接使用它（0x33 / 0x128 / 0x145 / 0x202 等）。
  final Uint8List guid;

  const Qq8Device({
    required this.product,
    required this.device,
    required this.board,
    required this.brand,
    required this.model,
    required this.bootloader,
    required this.fingerprint,
    required this.bootId,
    required this.procVersion,
    required this.baseband,
    required this.sim,
    required this.apn,
    required this.osType,
    required this.macAddress,
    required this.ipAddress,
    required this.wifiBssid,
    required this.wifiSsid,
    required this.imei,
    required this.androidId,
    required this.version,
    required this.imsi,
    required this.tgtgt,
    required this.guid,
  });

  /// 由账号确定性派生一份设备信息（移植自 oicq `lib/device.js`）。
  ///
  /// [randomBytes] 用于注入随机源，测试时可换成确定性的实现。
  factory Qq8Device.generate(
    int uin, {
    Uint8List Function(int n)? randomBytes,
  }) {
    final rnd = randomBytes ?? _defaultRandom;
    final hash = md5Bytes(_ascii('$uin'));

    // guid = MD5(IMEI + MAC)，与参考实现一致
    final imei = _syntheticImei(uin);
    final mac = _syntheticMac(hash);
    final guid = md5Bytes(<int>[
      ..._ascii(imei),
      ..._ascii(mac),
    ]);

    return Qq8Device(
      product: 'MRS4S',
      device: 'HIM188MOE',
      board: 'MIRAI-YYDS',
      brand: 'OICQX',
      model: 'Konata 2020',
      bootloader: 'U-boot',
      fingerprint: 'OICQX/MRS4S/HIM188MOE:10/${_androidId(uin, hash)}/'
          '${_incremental(hash)}:user/release-keys',
      bootId: _uuidFrom(hash),
      procVersion: 'Linux version 4.19.71-${_u16(hash, 4)} '
          '(konata@takayama.github.com)',
      baseband: '',
      sim: 'T-Mobile',
      apn: 'wifi',
      osType: 'android',
      macAddress: mac,
      ipAddress: '10.0.${hash[10]}.${hash[11]}',
      wifiBssid: mac,
      wifiSsid: 'TP-LINK-${uin.toRadixString(16)}',
      imei: imei,
      androidId: _androidId(uin, hash),
      version: Qq8AndroidVersion(
        release: '10',
        codename: 'REL',
        incremental: '${_incremental(hash)}',
        sdk: 29,
      ),
      imsi: rnd(16),
      tgtgt: rnd(16),
      guid: guid,
    );
  }

  /// 复制一份设备，只替换 [tgtgt]。
  ///
  /// token 续期路径要求 `tgtgt = MD5(d2key)`：没有密码就没法用 t106 派生
  /// 新的 tgtgt，只能沿用这个约定值（oicq `login-password.js` 的 token 分支
  /// 同款）。其余字段（imei/guid/mac…）必须保持与上次登录一致，否则
  /// "同一账号同一设备"的前提就破了。
  Qq8Device withTgtgt(Uint8List newTgtgt) => Qq8Device(
        product: product,
        device: device,
        board: board,
        brand: brand,
        model: model,
        bootloader: bootloader,
        fingerprint: fingerprint,
        bootId: bootId,
        procVersion: procVersion,
        baseband: baseband,
        sim: sim,
        apn: apn,
        osType: osType,
        macAddress: macAddress,
        ipAddress: ipAddress,
        wifiBssid: wifiBssid,
        wifiSsid: wifiSsid,
        imei: imei,
        androidId: androidId,
        version: version,
        imsi: imsi,
        tgtgt: newTgtgt,
        guid: guid,
      );

  /// 诊断用。
  @override
  String toString() =>
      'Qq8Device($brand $model, androidId=$androidId, guid=${_hex(guid)})';

  // -- 派生细节（与 oicq 逐行对应）----------------------------------------

  static Uint8List _defaultRandom(int n) {
    final r = Random.secure();
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = r.nextInt(256);
    }
    return out;
  }

  static Uint8List _ascii(String s) =>
      Uint8List.fromList(s.codeUnits.map((c) => c & 0xFF).toList());

  /// oicq `_genIMEI`：由 uin 派生一个格式合法的 IMEI（含 Luhn 校验位）。
  static String _syntheticImei(int uin) {
    var p = uin.isOdd ? '86' : '35';
    // uin 的大端 4 字节
    final buf = Uint8List(4);
    buf[0] = (uin >> 24) & 0xFF;
    buf[1] = (uin >> 16) & 0xFF;
    buf[2] = (uin >> 8) & 0xFF;
    buf[3] = uin & 0xFF;

    var a = (buf[0] << 8) | buf[1];
    var b = ((0 << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3]) & 0xFFFFFFFF;

    if (a > 9999) {
      a = a ~/ 10;
    } else if (a < 1000) {
      a = int.parse('$uin'.substring(0, min(4, '$uin'.length)));
    }
    while (b > 9999999) {
      b = b >> 1;
    }
    if (b < 1000000) {
      final s = '$uin';
      b = int.parse(s.substring(0, min(4, s.length)) +
          s.substring(0, min(3, s.length)));
    }
    p += '$a' '0' '$b';

    // Luhn
    var sum = 0;
    for (var i = 0; i < p.length; i++) {
      if (i.isOdd) {
        final j = int.parse(p[i]) * 2;
        sum += j % 10 + j ~/ 10;
      } else {
        sum += int.parse(p[i]);
      }
    }
    return '$p${(100 - sum) % 10}';
  }

  static String _syntheticMac(Uint8List hash) {
    String h(int i) => hash[i].toRadixString(16).padLeft(2, '0').toUpperCase();
    return '00:50:${h(6)}:${h(7)}:${h(8)}:${h(9)}';
  }

  static String _androidId(int uin, Uint8List hash) =>
      'OICQX.${_u16(hash, 0)}${hash[2]}.${hash[3]}${'$uin'[0]}';

  static int _incremental(Uint8List hash) => _u32(hash, 12);

  static String _uuidFrom(Uint8List hash) {
    final h = _hex(hash);
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
        '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  static int _u16(Uint8List b, int off) => (b[off] << 8) | b[off + 1];

  static int _u32(Uint8List b, int off) =>
      ((b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3]) &
      0xFFFFFFFF;

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
