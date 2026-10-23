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

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/digest.dart';
import '../../infra/device/device_info.dart';

/// Android 版本信息。
class Qq8AndroidVersion {
  final String release;
  final String codename;
  final String incremental;
  final int sdk;

  /// `android.os.Build.DISPLAY`（官方 `getInnerVersion` 的首选来源）。
  ///
  /// 缺省为空串：此时 [innerVersion] 退回 [incremental]，与旧行为等价。
  final String display;

  const Qq8AndroidVersion({
    this.release = '10',
    this.codename = 'REL',
    this.incremental = '0',
    this.sdk = 29,
    this.display = '',
  });

  /// 官方 `oicq.wlogin_sdk.tools.util.getInnerVersion()` 的等价物。
  ///
  /// 原文（jadx-main `oicq/wlogin_sdk/tools/util.java:803-808`）：
  /// ```java
  /// if (android.os.Build.DISPLAY.contains(android.os.Build.VERSION.INCREMENTAL)) {
  ///     return android.os.Build.DISPLAY;
  /// }
  /// return android.os.Build.VERSION.INCREMENTAL;
  /// ```
  /// ⚠️ 判定方向是「DISPLAY **包含** INCREMENTAL」。真机上二者通常相同，
  /// 于是返回 DISPLAY；只有厂商定制 build 里 DISPLAY 不含 INCREMENTAL 时才退回
  /// INCREMENTAL。TLV `0x52d` 的 protobuf 字段 9（`bytes_inner_ver`）用的就是它。
  String get innerVersion => display.isNotEmpty && display.contains(incremental)
      ? display
      : incremental;
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

  /// 服务端下发的 `ksid`（32 位十六进制串）。空 = 未注入，退回本地派生。
  ///
  /// 官方语义见 [Qq8DeviceIdentity.ksid] 的注释。它同时进 SSO 头的
  /// 16 字节槽位（`u16('|'+imei+'|'+apkName)` 那份是错的）与 TLV `0x108`。
  final String ksid;

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
    this.ksid = '',
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
      tgtgt: _deriveTgtgt(rnd, guid),
      guid: guid,
    );
  }

  /// 由**真机身份材料**构造设备（对齐官方采集/派生链，2026-09-19）。
  ///
  /// 与 [Qq8Device.generate] 的区别：那条是 uin 合成派生（oicq 传习，
  /// 服务端看到的是"一台不存在的设备"）；这条用真机上报的真实值，用于
  /// **让服务端认成已知设备**。
  ///
  /// 几处按官方语义处理（都有反编译/真机日志出处，见
  /// `analysis/QQ-官方三版本登录流程对照.md` §11）：
  ///
  /// * `guid`：缺省按官方 `util.generateGuid` 派生 = `MD5(androidId ‖ mac)`；
  /// * `imsi`：官方 0x194 = `MD5(imsi 原文)`，**读不到则整条不发**（k.java
  ///   case 404 guard，不是 MD5 空串）；identity 无 imsi 时设备里就是空；
  /// * `mac`：Android 6+ 上普通应用读到的是常量 `02:00:00:00:00:00`，
  ///   真机身份文件里应如实填它。
  factory Qq8Device.fromIdentity(
    Qq8DeviceIdentity id, {
    Uint8List? tgtgt,
    Uint8List Function(int n)? randomBytes,
  }) {
    final rnd = randomBytes ?? _defaultRandom;
    final guid = id.guidBytes ?? qq8DeriveGuid(id.androidId, id.macAddress);
    return Qq8Device(
      product: id.product ?? '',
      device: id.device ?? '',
      board: id.board ?? '',
      brand: id.brand ?? '',
      model: id.model ?? '',
      bootloader: id.bootloader ?? '',
      fingerprint: id.fingerprint ?? '',
      bootId: id.bootId ?? '',
      procVersion: id.procVersion ?? '',
      baseband: id.baseband ?? '',
      sim: id.sim ?? '',
      apn: id.apn ?? 'wifi',
      osType: id.osType ?? 'android',
      macAddress: id.macAddress,
      ipAddress: id.ipAddress ?? '',
      // 官方 0x202 第一段是 MD5(bssid 小写)；没有独立 bssid 时退回 mac
      wifiBssid: id.wifiBssid ?? id.macAddress,
      wifiSsid: id.wifiSsid ?? '',
      imei: id.imei ?? '',
      androidId: id.androidId,
      version: Qq8AndroidVersion(
        release: id.release ?? '10',
        codename: id.codename ?? 'REL',
        incremental: id.incremental ?? '0',
        display: id.display ?? '',
        sdk: id.sdk ?? 29,
      ),
      // 0x194 官方语义：t.L（MD5(IMSI)）**为空则整条跳过**（k.java case 404
      // guard：`if (t.L == null || t.L.length == 0) skip`），不是 MD5 空串。
      // 真机日志 wtlogin_20260919.txt：无 SIM 平板登录时不发 0x194。identity
      // 无 imsi 键 → 留空 → guard 跳过，与官方一致。
      imsi: (id.imsi == null || id.imsi!.isEmpty)
          ? Uint8List(0)
          : md5Bytes(utf8.encode(id.imsi!)),
      tgtgt: tgtgt ?? _deriveTgtgt(rnd, guid),
      guid: guid,
      ksid: id.ksid ?? '',
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
        ksid: ksid,
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

  /// `tgtgt` 的官方派生：**`MD5(随机 16 字节 ‖ guid)`**。
  ///
  /// 出处：`analysis/_decompiled/jadx-main/sources/oicq/wlogin_sdk/request/k.java:445`
  /// ```java
  /// async_contextVarB._tgtgt_key =
  ///     oicq.wlogin_sdk.tools.util.get_rand_16byte(oicq.wlogin_sdk.request.t.B);
  /// ```
  /// 其中 `t.B` 是 guid（`t.java:285` `B = (byte[]) bArr.clone()`，bArr 来自 `t.d()`
  /// 里算出的 guid），而 `util.get_rand_16byte(byte[] bArr)`
  /// （`tools/util.java:165-175`）是
  /// ```java
  /// byte[] seed = SecureRandom.getSeed(16);
  /// byte[] out = new byte[seed.length + bArr.length];
  /// arraycopy(seed, 0, out, 0, seed.length);
  /// arraycopy(bArr, 0, out, seed.length, bArr.length);
  /// return MD5.toMD5Byte(out);
  /// ```
  ///
  /// 2026-10-23 修正：此前是**纯随机 `rnd(16)`**（oicq 的传习，不看 guid）。
  /// 这个值决定 `0x106` 里的一个槽 + 整个 `0x144` 的 TEA 密钥，而 `0x144`
  /// 里包着 0x109/0x52D/0x124/0x128/0x16E 全部设备信息 —— 掺不掺 guid
  /// 会让服务端看到两种不同的设备摘要。
  static Uint8List _deriveTgtgt(
    Uint8List Function(int n) rnd,
    Uint8List guid,
  ) {
    final seed = rnd(16);
    return md5Bytes(<int>[...seed, ...guid]);
  }

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

/// 官方 `util.generateGuid`：`guid = MD5(androidId ‖ mac)`。
///
/// 原串**直接拼接**，无分隔符、无截断（反编译 8.2.11 `tools/util.java:402-413`；
/// 8.9.50 `utils/a.java` 同）。
///
/// 真机验证（Redmi 25091RP04C，Android 16）：
/// `MD5("25cf6881290b58f7" + "02:00:00:00:00:00")` 正好等于官方日志与
/// `WLOGIN_DEVICE_INFO` 里的 guid `7d9cf98da15d5c95f87507273280cbbf`。
Uint8List qq8DeriveGuid(String androidId, String mac) =>
    md5Bytes(utf8.encode('$androidId$mac'));

/// 真机身份材料——喂给 [Qq8Device.fromIdentity] 就能上报"本机真实身份"。
///
/// ## 为什么要它
///
/// [Qq8Device.generate] 是 uin 合成派生（oicq 传习），服务端看到的是
/// "一台不存在的设备"。而服务端的**设备信任是按身份值记的**：官方客户端
/// 在同一账号上登录成功后，服务端就把那套 guid/指纹/QIMEI 记为已知设备。
/// 用真值上报，才可能被直接放行（而不是被要验证码）。
///
/// ## 值从哪来
///
/// 官方自己写的材料，两个来源（都无需猜测）：
///
/// | 字段 | 来源 |
/// |---|---|
/// | `android_id` / `mac` / `guid` / 设备串 | 官方 wlogin 文件日志（`decode_wtlogin_log.py` 解码） |
/// | `qimei` | `shared_prefs/DENGTA_META.xml` 的 `QIMEI_DENGTA` |
/// | 指纹快照（自校验用） | `shared_prefs/WLOGIN_DEVICE_INFO.xml` 的 `last_*` |
///
/// JSON 形状见 `analysis/_ref/official-logs/identity-25091RP04C.json`。
class Qq8DeviceIdentity {
  /// Android ID 原文（16 hex 字符；Android 8+ 按应用签名隔离，必须取官方的值）。
  final String androidId;

  /// mac 原文。Android 6+ 普通应用读到的是常量 `02:00:00:00:00:00`。
  final String macAddress;

  /// Wi-Fi BSSID / SSID 原文（0x202 用；缺省退回 mac / 空）。
  final String? wifiBssid;
  final String? wifiSsid;

  /// IMSI 原文（Android 10+ 普通应用读不到 → 留空，官方按 `MD5("")` 发 0x194）。
  final String? imsi;

  final String? imei;

  /// 服务端下发的 `ksid`（32 位十六进制串）。
  ///
  /// ⚠️ 2026-10-22 修正：`ksid` **不是** `|imei|apkName` 本地派生。
  /// 它由服务端在响应 TLV `0x108` 里下发，客户端 `util.set_ksid()` 只在
  /// SP 为空时写入 `WLOGIN_DEVICE_INFO.xml` 的 `ksid` 项，之后每次登录
  /// 原样回带（`k.java` case 264 只在非空时才发 0x108）。
  /// 真机 SP 实测值 `188ca8765de720b5207b0adc6c51d3d7`。
  final String? ksid;

  /// guid 的 32 位 hex。**缺省按官方算法派生**（`MD5(androidId ‖ mac)`）。
  final String? guidHex;

  final String? model;
  final String? brand;
  final String? product;
  final String? device;
  final String? board;
  final String? bootloader;
  final String? fingerprint;
  final String? bootId;
  final String? procVersion;
  final String? baseband;
  final String? sim;
  final String? apn;
  final String? osType;
  final String? ipAddress;

  /// 安卓版本（0x124 / 0x52D 用）。
  final String? release;
  final String? codename;
  final String? incremental;

  /// `android.os.Build.DISPLAY`。0x52D 字段 9（`bytes_inner_ver`）优先取它
  /// （见 [Qq8AndroidVersion.innerVersion]）。缺省时退回 [incremental]。
  final String? display;
  final int? sdk;

  /// QIMEI 原文（36 位）。0x545 的 body 按版本取 `MD5(它)` 或它本身。
  final String? qimei;

  const Qq8DeviceIdentity({
    required this.androidId,
    required this.macAddress,
    this.wifiBssid,
    this.wifiSsid,
    this.imsi,
    this.imei,
    this.ksid,
    this.guidHex,
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
    this.sim,
    this.apn,
    this.osType,
    this.ipAddress,
    this.release,
    this.codename,
    this.incremental,
    this.display,
    this.sdk,
    this.qimei,
  });

  /// guid 的字节形式；[guidHex] 非法（非 32 位 hex）时返回 null（走派生）。
  Uint8List? get guidBytes {
    final h = guidHex;
    if (h == null || h.length != 32) return null;
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      final b = int.tryParse(h.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return null;
      out[i] = b;
    }
    return out;
  }

  /// 从**本机采集的快照**构造身份（对齐官方 `util` 的读取链）。
  ///
  /// 与 [fromJson] 的区别：那个读人工导出的 `identity.json`，这个直接吃
  /// [DeviceSnapshot]（L1 `lib/infra/device/device_info.dart`，由原生
  /// `DeviceProbe.kt` 用官方同一套系统 API 读出）。**用户不再需要 adb
  /// push 任何文件**。
  ///
  /// ## 为什么这不等于"伪装成官方"
  ///
  /// Android 8+ 的 `ANDROID_ID` 按「应用签名 + 用户 + 设备」隔离，官方 QQ 与
  /// TIM 装在同一台机器上读到的都不同（`25cf6881290b58f7` vs
  /// `f23dd554a9f43c9a`）。所以**我们永远拿不到官方那个值**，也不该往这个
  /// 方向使劲。能做到的是让**其余字段全部真实**：机型、指纹、boot_id、
  /// /proc/version、基带都从本机读真值，"这台设备在现实里存在"这一条成立
  /// ——而合成设备（`brand=OICQX`、`model=Konata 2020`、自称 Android 10
  /// 却跑在 Android 16 上）在这一条上直接露。
  ///
  /// ## `androidId` 缺失时的处理
  ///
  /// 官方不是留空，而是生成 **15 位随机数字**并持久化到 SP
  /// `WLOGIN_DEVICE_INFO` 的 `random_AndroidId`（`util.java:415-430`），
  /// 之后每次登录都用它。持久化需要可写目录（L3 的事），所以这里接受
  /// [androidIdFallback]——由调用方从磁盘读回或首次生成。两者都没有就返回
  /// null（**不编**，让上层退回合成派生）。
  ///
  /// [ksid] / [qimei] 同理：都是服务端下发或跨会话共享的值，必须由上层
  /// 从持久化存储带进来，这里不生成。
  static Qq8DeviceIdentity? fromSnapshot(
    DeviceSnapshot snapshot, {
    String? androidIdFallback,
    String? ksid,
    String? qimei,
  }) {
    var androidId = snapshot.androidId;
    if (androidId == null || androidId.isEmpty) {
      androidId = androidIdFallback;
    }
    if (androidId == null || androidId.isEmpty) return null;

    // mac 在 Android 6+ 恒为常量；真读不到就用官方同一个常量，
    // 因为 guid = MD5(androidId ‖ mac) 少了它就算不出来。
    final mac = (snapshot.macAddress == null || snapshot.macAddress!.isEmpty)
        ? '02:00:00:00:00:00'
        : snapshot.macAddress!;

    return Qq8DeviceIdentity(
      androidId: androidId,
      macAddress: mac,
      wifiBssid: snapshot.wifiBssid,
      wifiSsid: snapshot.wifiSsid,
      // IMSI 在 Android 10+ 普通应用读不到，官方同样读不到 → 留空 → 不发 0x194。
      imsi: null,
      ksid: ksid,
      model: snapshot.model,
      brand: snapshot.brand,
      product: snapshot.product,
      device: snapshot.device,
      board: snapshot.board,
      bootloader: snapshot.bootloader,
      fingerprint: snapshot.fingerprint,
      bootId: snapshot.bootId,
      procVersion: snapshot.procVersion,
      baseband: snapshot.baseband,
      sim: snapshot.sim,
      apn: snapshot.apn,
      osType: snapshot.osType,
      release: snapshot.release,
      codename: snapshot.codename,
      incremental: snapshot.incremental,
      display: snapshot.display,
      sdk: snapshot.sdk,
      qimei: qimei,
    );
  }

  /// 从 JSON 解析。`android_id` 与 `mac` 是必需项，缺任一返回 null（不猜）。
  static Qq8DeviceIdentity? fromJson(Map<String, Object?> json) {
    String? s(String k) {
      final v = json[k];
      if (v == null) return null;
      final t = '$v'.trim();
      return t.isEmpty ? null : t;
    }

    final aid = s('android_id');
    final mac = s('mac');
    if (aid == null || mac == null) return null;
    return Qq8DeviceIdentity(
      androidId: aid,
      macAddress: mac,
      wifiBssid: s('wifi_bssid'),
      wifiSsid: s('wifi_ssid'),
      imsi: s('imsi'),
      imei: s('imei'),
      ksid: s('ksid'),
      guidHex: s('guid'),
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
      sim: s('sim'),
      apn: s('apn'),
      osType: s('os_type'),
      ipAddress: s('ip_address'),
      release: s('release'),
      codename: s('codename'),
      incremental: s('incremental'),
      display: s('display'),
      sdk: json['sdk'] is num ? (json['sdk']! as num).toInt() : null,
      qimei: s('qimei'),
    );
  }

  /// 诊断用（**不打印 qimei 全值**，它是跨业务共享的设备标识）。
  @override
  String toString() => 'Qq8DeviceIdentity(androidId=$androidId, mac=$macAddress, '
      'guid=${guidHex ?? '(派生)'}, qimei=${qimei == null ? '无' : '有(${qimei!.length}字符)'})';
}
