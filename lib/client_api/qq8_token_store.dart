/// L3 客户端 API 层：票据存储（明文 / AES-GCM 加密两种实现）
///
/// ## 票据是什么、为什么不能明文躺着
///
/// 登录成功后的 `tgt / d2 / d2key / sig_key / ticket_key / srm_token`
/// 是**会话凭据**：拿到 d2key 就等于拿到这个账号的上线资格（不需要口令）。
/// 明文落盘意味着"任何能读这个文件的人/程序都能顶替这个账号上线"。
///
/// ## 两个实现
///
/// | 实现 | 用途 | 强度 |
/// |---|---|---|
/// | [FileQq8TokenStore] | 开发期 / 自测 | 无（明文 JSON） |
/// | [EncryptedFileQq8TokenStore] | 默认推荐 | AES-GCM；密钥来源可注入 |
///
/// ⚠️ 关于加密强度的**实话**：
/// [EncryptedFileQq8TokenStore] 的默认密钥来源是"同目录下的一把随机密钥文件"，
/// 它防的是**随手翻看文件内容**（比如把目录拷走、日志误采、备份泄露），
/// **不防**能读整个文件系统的攻击者（他能连密钥一起读走）。要防那一档，
/// 必须把 [EncryptedFileQq8TokenStore.keyProvider] 接到平台密钥库
/// （Android Keystore / iOS Keychain / Windows DPAPI）——那时本文件不用改。
///
/// 本文件是纯 Dart（`package:cryptography` 不依赖 Flutter）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../infra/log/logger.dart';
import '../kernel/wlogin8/qq8_login.dart';

final Logger _log = Log.get('QQ8TOKEN');

/// 票据存储接口（可替换：加密存储、系统钥匙串都从这里接）。
abstract class Qq8TokenStore {
  Future<Qq8TokenData?> load(int uin);
  Future<void> save(Qq8TokenData data);
  Future<void> clear(int uin);

  /// 目录下已保存票据的账号（升序）。启动自动登录用它挑最近用过的号；
  /// 没有票据可列时返回空列表——**不抛异常**（目录不存在也当空）。
  ///
  /// 文件型实现都重写它；内存/测试实现用默认空表即可。
  Future<List<int>> listUins() async => const <int>[];

  /// 票据文件的最后修改时间（自动登录挑"最近用过的号"用）。
  /// 没有文件 / 不支持时返回 null，绝不抛异常。
  Future<DateTime?> lastModified(int uin) async => null;
}

/// 一份票据（与 `tool/qq8_live_smoke.dart --save-token` 的文件同构）。
class Qq8TokenData {
  final int uin;
  final String savedAt;
  final Uint8List tgt;
  final Uint8List d2;
  final Uint8List d2key;
  final Uint8List sigKey;
  final Uint8List ticketKey;
  final Uint8List srmToken;

  /// 长期凭据 A1（响应 0x119 里的 TLV `0x106`）。
  ///
  /// 官方每次成功登录后 `A1 version` 自增并把 A1 存进 `tk_file`；icqq 的
  /// `decodeT119` 也是 `sig.a1 = t[0x106]` 并随 token 文件落盘。不存它，
  /// 每次登录在服务端眼里都像一台从没成功过的裸设备。
  ///
  /// 2026-10-24 起持久化。**刻意不改变任何发包行为**：官方把 A1 当
  /// `tlv_t106` 的密钥喂回快速重登（`WtloginHelper.java:699` 的
  /// GetA1ByAccount 路径），那是独立的、有风险的协议变化；这里只先存下来。
  /// 旧票据文件没有 `a1` 键 → 读成空（向后兼容，不报错）。
  final Uint8List a1;

  /// 续期材料 A2KEY（官方 `WtloginHelper.java:607-755` 的 A2+A2KEY 分支）。
  ///
  /// **默认 null**：旧票据文件没有这个键，读出来就是 null，行为不变。
  /// 存下来不等于会用它发包——用不用由 `recovery_planner.dart` 决策。
  final Uint8List? a2Key;

  /// 快速重登材料 noPicSig（配合 A1 走子命令 15，`request.z(u=15)`）。
  ///
  /// **默认 null**：同上，旧文件照旧能读。
  final Uint8List? noPicSig;

  /// 这张票**首次**成功登录的时刻（毫秒）。续期不改它。
  final int? issuedAtMs;

  /// 最近一次**续期成功**的时刻（毫秒）；从未续期为 null。
  final int? renewedAtMs;

  /// 服务端明确给出的到期时刻（毫秒）。**拿不到就是 null，不许拿 savedAt 推算**。
  final int? expireAtMs;

  /// 响应 0x130 里服务端给的时间（毫秒），用来估本地时钟偏差。
  final int? serverTimeMs;

  /// 响应 0x138 原文 hex：只作诊断留证，**不参与任何判定**（各项时长的语义未证实）。
  final String? lifetimeTlvHex;

  /// 服务端判定这张票失效的时刻（毫秒）+ 当时的返回码（16/155）。
  final int? invalidatedAtMs;
  final int? invalidatedType;

  Qq8TokenData({
    required this.uin,
    required this.savedAt,
    required this.tgt,
    required this.d2,
    required this.d2key,
    required this.sigKey,
    required this.ticketKey,
    required this.srmToken,
    Uint8List? a1,
    this.a2Key,
    this.noPicSig,
    this.issuedAtMs,
    this.renewedAtMs,
    this.expireAtMs,
    this.serverTimeMs,
    this.lifetimeTlvHex,
    this.invalidatedAtMs,
    this.invalidatedType,
  }) : a1 = a1 ?? Uint8List(0);

  bool get usable => d2.isNotEmpty && d2key.isNotEmpty;

  /// 服务端是否已经判过这张票失效（冷启动别白试）。
  bool get invalidated => invalidatedAtMs != null;

  /// 复制并覆盖部分字段。**传 null 表示保持原值**——不引入哨兵值。
  Qq8TokenData copyWith({
    String? savedAt,
    Uint8List? tgt,
    Uint8List? d2,
    Uint8List? d2key,
    Uint8List? sigKey,
    Uint8List? ticketKey,
    Uint8List? srmToken,
    Uint8List? a1,
    Uint8List? a2Key,
    Uint8List? noPicSig,
    int? issuedAtMs,
    int? renewedAtMs,
    int? expireAtMs,
    int? serverTimeMs,
    String? lifetimeTlvHex,
    int? invalidatedAtMs,
    int? invalidatedType,
  }) =>
      Qq8TokenData(
        uin: uin,
        savedAt: savedAt ?? this.savedAt,
        tgt: tgt ?? this.tgt,
        d2: d2 ?? this.d2,
        d2key: d2key ?? this.d2key,
        sigKey: sigKey ?? this.sigKey,
        ticketKey: ticketKey ?? this.ticketKey,
        srmToken: srmToken ?? this.srmToken,
        a1: a1 ?? this.a1,
        a2Key: a2Key ?? this.a2Key,
        noPicSig: noPicSig ?? this.noPicSig,
        issuedAtMs: issuedAtMs ?? this.issuedAtMs,
        renewedAtMs: renewedAtMs ?? this.renewedAtMs,
        expireAtMs: expireAtMs ?? this.expireAtMs,
        serverTimeMs: serverTimeMs ?? this.serverTimeMs,
        lifetimeTlvHex: lifetimeTlvHex ?? this.lifetimeTlvHex,
        invalidatedAtMs: invalidatedAtMs ?? this.invalidatedAtMs,
        invalidatedType: invalidatedType ?? this.invalidatedType,
      );

  /// 这张票现在还能用吗。**纯函数**（时间由调用方给，便于自测）。
  ///
  /// 原则：只认服务端明确告诉我们的东西。没给到期时间就是 [Qq8TokenValidity.unknown]，
  /// 而 unknown **仍然要去试**——服务端才是最终裁决者，本地不许猜 TTL。
  Qq8TokenValidity evaluateValidity(DateTime now) {
    if (invalidated) return Qq8TokenValidity.invalidated;
    final expire = expireAtMs;
    if (expire != null) {
      final nowMs = now.millisecondsSinceEpoch;
      if (nowMs >= expire) return Qq8TokenValidity.expired;
      const soon = 30 * 60 * 1000;
      if (expire - nowMs <= soon) return Qq8TokenValidity.expiringSoon;
      return Qq8TokenValidity.valid;
    }
    return Qq8TokenValidity.unknown;
  }

  static Qq8TokenData fromSigBundle(
    int uin,
    Qq8SigBundle b, {
    int? issuedAtMs,
    int? serverTimeMs,
    String? lifetimeTlvHex,
  }) =>
      Qq8TokenData(
        uin: uin,
        savedAt: DateTime.now().toIso8601String(),
        tgt: b.tgt ?? Uint8List(0),
        d2: b.d2 ?? Uint8List(0),
        d2key: b.d2key ?? Uint8List(0),
        sigKey: b.sigKey ?? Uint8List(0),
        ticketKey: b.ticketKey ?? Uint8List(0),
        srmToken: b.srmToken ?? Uint8List(0),
        a1: b.t106 ?? Uint8List(0),
        issuedAtMs: issuedAtMs,
        serverTimeMs: serverTimeMs,
        lifetimeTlvHex: lifetimeTlvHex,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'uin': uin,
        'saved_at': savedAt,
        'tgt': _plainHex(tgt),
        'd2': _plainHex(d2),
        'd2key': _plainHex(d2key),
        'sig_key': _plainHex(sigKey),
        'ticket_key': _plainHex(ticketKey),
        'srm_token': _plainHex(srmToken),
        'a1': _plainHex(a1),
        if (a2Key != null && a2Key!.isNotEmpty) 'a2_key': _plainHex(a2Key!),
        if (noPicSig != null && noPicSig!.isNotEmpty)
          'no_pic_sig': _plainHex(noPicSig!),
        if (issuedAtMs != null) 'issued_at_ms': issuedAtMs,
        if (renewedAtMs != null) 'renewed_at_ms': renewedAtMs,
        if (expireAtMs != null) 'expire_at_ms': expireAtMs,
        if (serverTimeMs != null) 'server_time_ms': serverTimeMs,
        if (lifetimeTlvHex != null) 'lifetime_tlv': lifetimeTlvHex,
        if (invalidatedAtMs != null) 'invalidated_at_ms': invalidatedAtMs,
        if (invalidatedType != null) 'invalidated_type': invalidatedType,
      };

  static Qq8TokenData fromJson(Map<String, dynamic> j) {
    final uin = j['uin'];
    if (uin is! int) throw const FormatException('票据缺少 uin');
    Uint8List hexField(String k) {
      final v = j[k];
      if (v is! String || v.isEmpty) return Uint8List(0);
      return _hex(v);
    }

    /// 宽松读取：键缺失或类型不对一律 → null（旧文件必须仍能读）。
    int? intField(String k) {
      final v = j[k];
      if (v is int) return v;
      if (v is num) return v.toInt();
      return null;
    }

    final lifetime = j['lifetime_tlv'];

    /// 宽松读取可选 hex：缺键 / 空串 / 脏值 → null（旧文件与坏文件都别抛）。
    Uint8List? nullableHexField(String k) {
      final v = j[k];
      if (v is! String || v.isEmpty) return null;
      try {
        final b = _hex(v);
        return b.isEmpty ? null : b;
      } on Object {
        return null;
      }
    }

    return Qq8TokenData(
      uin: uin,
      savedAt: '${j['saved_at'] ?? '?'}',
      tgt: hexField('tgt'),
      d2: hexField('d2'),
      d2key: hexField('d2key'),
      sigKey: hexField('sig_key'),
      ticketKey: hexField('ticket_key'),
      srmToken: hexField('srm_token'),
      a1: hexField('a1'),
      a2Key: nullableHexField('a2_key'),
      noPicSig: nullableHexField('no_pic_sig'),
      issuedAtMs: intField('issued_at_ms'),
      renewedAtMs: intField('renewed_at_ms'),
      expireAtMs: intField('expire_at_ms'),
      serverTimeMs: intField('server_time_ms'),
      lifetimeTlvHex: lifetime is String && lifetime.isNotEmpty ? lifetime : null,
      invalidatedAtMs: intField('invalidated_at_ms'),
      invalidatedType: intField('invalidated_type'),
    );
  }
}

/// 票据可用性结论（见 [Qq8TokenData.evaluateValidity]）。
enum Qq8TokenValidity {
  /// 服务端已判失效（16/155）：不要再发。
  invalidated,

  /// 服务端给过到期时间且已过：不要再发。
  expired,

  /// 30 分钟内到期：可以发，但日志要提示。
  expiringSoon,

  /// 有到期时间且还早。
  valid,

  /// 服务端没给到期时间：**照常尝试**，服务端会裁决。
  unknown,
}

/// 文件版票据存储：`<dir>/qq8-token-<uin>.json`，**明文**（只适合开发/自测）。
class FileQq8TokenStore implements Qq8TokenStore {
  final Directory dir;
  FileQq8TokenStore(this.dir);

  File _file(int uin) =>
      File('${dir.path}${Platform.pathSeparator}qq8-token-$uin.json');

  @override
  Future<Qq8TokenData?> load(int uin) async {
    final f = _file(uin);
    if (!await f.exists()) return null;
    try {
      final raw = jsonDecode(await f.readAsString());
      if (raw is Map<String, dynamic>) return Qq8TokenData.fromJson(raw);
    } on Object catch (e) {
      _log.w('票据文件损坏，按没有处理', error: e);
    }
    return null;
  }

  @override
  Future<void> save(Qq8TokenData data) async {
    await dir.create(recursive: true);
    await _file(data.uin).writeAsString(jsonEncode(data.toJson()), flush: true);
  }

  @override
  Future<void> clear(int uin) async {
    final f = _file(uin);
    if (await f.exists()) await f.delete();
  }

  static final _plainName = RegExp(r'^qq8-token-(\d+)\.json$');

  @override
  Future<DateTime?> lastModified(int uin) async {
    final f = _file(uin);
    if (!await f.exists()) return null;
    return f.lastModifiedSync();
  }

  @override
  Future<List<int>> listUins() async {
    if (!await dir.exists()) return const <int>[];
    final uins = <int>[];
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final m = _plainName.firstMatch(e.uri.pathSegments.last);
      if (m != null) uins.add(int.parse(m.group(1)!));
    }
    uins.sort();
    return uins;
  }
}

/// AES-GCM 加密的票据存储：`<dir>/qq8-token-<uin>.json.enc`。
///
/// 文件格式（JSON）：`{"v":1,"nonce":b64,"ct":b64,"mac":b64}`。
/// 密钥来源：[keyProvider]（不注入则用同目录的 `qq8-token.key`，见文件头说明）。
class EncryptedFileQq8TokenStore implements Qq8TokenStore {
  final Directory dir;

  /// 返回 32 字节密钥。生产建议接平台密钥库。
  final Future<List<int>> Function()? keyProvider;

  final _algo = AesGcm.with256bits();
  List<int>? _cachedKey;

  EncryptedFileQq8TokenStore(this.dir, {this.keyProvider});

  File _file(int uin) =>
      File('${dir.path}${Platform.pathSeparator}qq8-token-$uin.json.enc');
  File get _keyFile =>
      File('${dir.path}${Platform.pathSeparator}qq8-token.key');

  Future<List<int>> _key() async {
    if (_cachedKey != null) return _cachedKey!;
    if (keyProvider != null) return _cachedKey = await keyProvider!();
    await dir.create(recursive: true);
    if (await _keyFile.exists()) {
      final bytes = await _keyFile.readAsBytes();
      if (bytes.length != 32) {
        throw const FormatException('票据密钥文件损坏（长度不是 32 字节）');
      }
      return _cachedKey = bytes;
    }
    final fresh = _randomBytes(32);
    await _keyFile.writeAsBytes(fresh, flush: true);
    // 尽力收紧权限（Windows 上 chmod 是空操作，忽略失败）
    try {
      await Process.run('chmod', <String>['600', _keyFile.path]);
    } on Object {
      // 平台不支持就算了：强度差异写在文件头注释里，不装作做到了
    }
    return _cachedKey = fresh;
  }

  @override
  Future<void> save(Qq8TokenData data) async {
    await dir.create(recursive: true);
    final key = SecretKey(await _key());
    final box = await _algo.encrypt(
      utf8.encode(jsonEncode(data.toJson())),
      secretKey: key,
    );
    await _file(data.uin).writeAsString(
      jsonEncode(<String, Object?>{
        'v': 1,
        'nonce': base64Encode(box.nonce),
        'ct': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      }),
      flush: true,
    );
  }

  @override
  Future<Qq8TokenData?> load(int uin) async {
    final f = _file(uin);
    if (!await f.exists()) return null;
    try {
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map<String, dynamic>) return null;
      final box = SecretBox(
        base64Decode('${raw['ct']}'),
        nonce: base64Decode('${raw['nonce']}'),
        mac: Mac(base64Decode('${raw['mac']}')),
      );
      final clear = await _algo.decrypt(box, secretKey: SecretKey(await _key()));
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is Map<String, dynamic>) return Qq8TokenData.fromJson(decoded);
    } on Object catch (e) {
      // 密钥不对 / 密文被改 / 文件损坏都落这里：**一律当作没有票据**，
      // 由上层走"重新登录"，绝不把半截数据交给协议层。
      _log.w('票据解密失败（密钥不对或文件被改），按没有处理', error: e);
    }
    return null;
  }

  @override
  Future<void> clear(int uin) async {
    final f = _file(uin);
    if (await f.exists()) await f.delete();
  }

  static final _encName = RegExp(r'^qq8-token-(\d+)\.json\.enc$');

  @override
  Future<DateTime?> lastModified(int uin) async {
    final f = _file(uin);
    if (!await f.exists()) return null;
    return f.lastModifiedSync();
  }

  @override
  Future<List<int>> listUins() async {
    if (!await dir.exists()) return const <int>[];
    final uins = <int>[];
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final m = _encName.firstMatch(e.uri.pathSegments.last);
      if (m != null) uins.add(int.parse(m.group(1)!));
    }
    uins.sort();
    return uins;
  }
}

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(n, (_) => r.nextInt(256), growable: false),
  );
}

Uint8List _hex(String s) {
  final clean = s.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _plainHex(List<int> b) =>
    b.map((v) => (v & 0xff).toRadixString(16).padLeft(2, '0')).join();
