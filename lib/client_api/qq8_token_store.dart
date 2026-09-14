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

  const Qq8TokenData({
    required this.uin,
    required this.savedAt,
    required this.tgt,
    required this.d2,
    required this.d2key,
    required this.sigKey,
    required this.ticketKey,
    required this.srmToken,
  });

  bool get usable => d2.isNotEmpty && d2key.isNotEmpty;

  static Qq8TokenData fromSigBundle(int uin, Qq8SigBundle b) => Qq8TokenData(
        uin: uin,
        savedAt: DateTime.now().toIso8601String(),
        tgt: b.tgt ?? Uint8List(0),
        d2: b.d2 ?? Uint8List(0),
        d2key: b.d2key ?? Uint8List(0),
        sigKey: b.sigKey ?? Uint8List(0),
        ticketKey: b.ticketKey ?? Uint8List(0),
        srmToken: b.srmToken ?? Uint8List(0),
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
      };

  static Qq8TokenData fromJson(Map<String, dynamic> j) {
    final uin = j['uin'];
    if (uin is! int) throw const FormatException('票据缺少 uin');
    Uint8List hexField(String k) {
      final v = j[k];
      if (v is! String || v.isEmpty) return Uint8List(0);
      return _hex(v);
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
    );
  }
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
