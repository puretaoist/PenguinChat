/// L2 协议内核：灯塔 QIMEI **取号**（OLA 接口）
///
/// ## 这是什么
///
/// QIMEI 不是本地算出来的——它是腾讯灯塔（Beacon）服务按上报的设备属性
/// **签发**的字符串（16 位 `q16` / 36 位 `q36`）。官方客户端由 `libQimei.so` /
/// `com.tencent.qimei.**` 走一次 HTTPS 换取，之后缓存进设备档案
/// （SharedPreferences `DENGTA_META` / 灯塔 sdk 的存储），TLV `0x545` 发的是它。
///
/// 所以"取号"**不是伪造指纹**：ID 由服务端签发，我们只是照官方/参考实现的做法
/// 去要一个。取不到就不发 `0x545`（官方行为，见 `Qq8LoginConditions.applies`）。
///
/// ## 两处出处（照 AGENTS 的规矩标清楚）
///
/// | 部分 | 出处 | 等级 |
/// |---|---|---|
/// | 端点 + 请求体形状 `{key, params, time, nonce, sign, extra}` | 参考实现 oicq `lib/core/device.ts` 的 `requestQImei()`（长期实测可用） | 参考 |
/// | 同款 POST、端点 `https://snowflake.qq.com/ola/v2` | 官方 TIM（9.0.75 代）`com/tencent/qimei/x/b.java` | **官方** |
/// | 请求字段清单（`androidId/beaconIdSrc/imei/...`）与 `reserved` 结构 | oicq `genRandomPayloadByDevice` | 参考 |
/// | RSA 公钥 / `secret` / `sdkVersion` | oicq 源码内嵌常量（灯塔 OLA 接口的公开常量） | 参考 |
///
/// ⚠️ **官方那侧的加密与签名实现不在我们手上的 dex 里**（`com.tencent.qimei`
/// 只有存储/策略/上报壳），所以请求体的加密细节只有参考实现一个来源。
/// 真机以"服务端是否回 `code=0` 且能解出 `q16/q36`"为准；失败就是这个原因，
/// 不要先去怀疑别处。
///
/// ## 端点差异（要注意）
///
/// oicq 用 `/ola/android`，官方新版 SDK 用 `/ola/v2`。两者都是 POST JSON，
/// 本实现**两个都试**（先 `/ola/android`，失败再 `/ola/v2`），并把每次尝试的
/// 结果记进日志——这样真机上一次就能看出哪个还活着。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/paddings/pkcs7.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/asymmetric/pkcs1.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/rsa.dart';

import '../crypto/digest.dart';
import 'qq8_device.dart';
import 'qq8_tlv.dart';

/// 取号失败（消息直接给人看）。
class Qq8QimeiException implements Exception {
  final String message;
  Qq8QimeiException(this.message);

  @override
  String toString() => 'Qq8QimeiException: $message';
}

/// 取到的 QIMEI。
class Qq8QimeiResult {
  /// 16 位短号（官方客户端缓存里的 `q16`）。
  final String q16;

  /// 36 位长号（`q36`）。
  final String q36;

  /// 命中哪个端点（排查用）。
  final String endpoint;

  const Qq8QimeiResult({
    required this.q16,
    required this.q36,
    required this.endpoint,
  });

  @override
  String toString() => 'Qq8QimeiResult(q16=$q16, q36=$q36, via=$endpoint)';
}

/// 灯塔 OLA 取号。
abstract final class Qq8Qimei {
  /// 参考实现用的端点（oicq `device.ts`）。
  static const String endpointOlaAndroid = 'https://snowflake.qq.com/ola/android';

  /// 官方新版 SDK 用的端点（TIM `com/tencent/qimei/x/b.java`）。
  static const String endpointOlaV2 = 'https://snowflake.qq.com/ola/v2';

  /// OLA 接口的签名密钥（oicq 源码内嵌常量）。
  static const String secret = 'ZdJqM15EeO2zWc08';

  /// OLA 接口的 RSA 公钥（1024 位；模数已剥掉 DER 的符号位前导 0）。
  ///
  /// 出处：oicq `device.ts` 里的 `rsaKey`（PEM），这里存**数值**以便零依赖使用。
  /// 用途是把随机 `cryptKey` 加密后放进 `key` 字段——**加密**用公钥，
  /// 服务端用私钥解，所以这里不需要（也没有）私钥。
  static final BigInt rsaModulus = BigInt.parse(
    'c4231830a2eb5fc2827170641e79d80fec51bda9a22e4b4ab37d1f205a4ae44'
    'd928cda25879f66a3429051663312a127faf8a246bdaaf63918417e90d7c95b5'
    '908aa6a2d0f852e4a6770294a548ac1c2fe8f1f252fb826f4ac86ab9a00e7ce4'
    '7d002a56e7c4b51eb889acc60ca6adbc9f72e81f4d31b1dd7464805264530ab1d',
    radix: 16,
  );

  /// 指数（65537，标准值）。
  static final BigInt rsaExponent = BigInt.from(65537);

  /// 请求体里的 SDK 版本串（oicq 内嵌 `sdkVersion: "1.2.13.6"`）。
  static const String olaSdkVersion = '1.2.13.6';

  /// 取号。
  ///
  /// [random] 可注入（自测用确定性随机）；[client] 可注入（自测用假 HttpClient）。
  /// 两个端点依次尝试，都失败就抛 [Qq8QimeiException]（**不返回空值糊弄**）。
  static Future<Qq8QimeiResult> fetch({
    required Qq8Device device,
    required Qq8ApkInfo apk,
    required String beaconAppKey,
    Random? random,
    HttpClient? client,
    Duration timeout = const Duration(seconds: 10),
    void Function(String line)? onLog,
  }) async {
    final rnd = random ?? Random.secure();
    final payload = buildPayload(
      device: device,
      apk: apk,
      beaconAppKey: beaconAppKey,
      random: rnd,
      now: DateTime.now(),
    );
    final req = buildRequest(payload, random: rnd);
    onLog?.call('取号请求: payload ${payload.length}B / 明文 params '
        '${req.plainParams.length}B / sign ${req.sign.length} 字符');

    final failures = <String>[];
    for (final endpoint in <String>[endpointOlaAndroid, endpointOlaV2]) {
      try {
        final result = await _post(
          endpoint: endpoint,
          body: req.body,
          cryptKey: req.cryptKey,
          client: client,
          timeout: timeout,
          onLog: onLog,
        );
        if (result != null) return result;
        failures.add('$endpoint：响应里没有 q16/q36');
      } on Object catch (e) {
        failures.add('$endpoint：$e');
      }
    }
    throw Qq8QimeiException('两个端点都没取到 QIMEI：${failures.join(' | ')}');
  }

  /// 组装上报 JSON（字段清单照 oicq `genRandomPayloadByDevice`）。
  static String buildPayload({
    required Qq8Device device,
    required Qq8ApkInfo apk,
    required String beaconAppKey,
    required Random random,
    required DateTime now,
  }) {
    String randFrom(String alphabet, int n) {
      final sb = StringBuffer();
      for (var i = 0; i < n; i++) {
        sb.write(alphabet[random.nextInt(alphabet.length)]);
      }
      return sb.toString();
    }

    final month = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-01';
    final rand1 = 100000 + random.nextInt(900000);
    final rand2 = 100000000 + random.nextInt(900000000);

    // beaconIdSrc：40 个 `ki:...;` 片段，16 个用"月+两个随机数"、k3 固定 0、
    // k4 是 16 位十六进制、其余是 0..9999 的随机数（oicq 原样）。
    final beacon = StringBuffer();
    for (var i = 1; i <= 40; i++) {
      switch (i) {
        case 1:
        case 2:
        case 13:
        case 14:
        case 17:
        case 18:
        case 21:
        case 22:
        case 25:
        case 26:
        case 29:
        case 30:
        case 33:
        case 34:
        case 37:
        case 38:
          beacon.write('k$i:$month$rand1.$rand2');
        case 3:
          beacon.write('k3:0000000000000000');
        case 4:
          beacon.write('k4:${randFrom('123456789abcdef', 16)}');
        default:
          beacon.write('k$i:${random.nextInt(10000)}');
      }
      beacon.write(';');
    }

    final reserved = <String, Object?>{
      'harmony': '0',
      'clone': '0',
      'containe': '',
      'oz': 'UhYmelwouA+V2nPWbOvLTgN2/m8jwGB+yUB5v9tysQg=',
      'oo': 'Xecjt+9S1+f8Pz2VLSxgpw==',
      'kelong': '0',
      'uptimes': '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')} '
          '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}:'
          '${now.second.toString().padLeft(2, '0')}',
      'multiUser': '0',
      'bod': device.board,
      'brd': device.brand,
      'dv': device.device,
      'firstLevel': '',
      'manufact': device.brand,
      'name': device.model,
      'host': 'se.infra',
      'kernel': device.fingerprint,
    };

    final payload = <String, Object?>{
      'androidId': device.androidId,
      'platformId': 1,
      'appKey': beaconAppKey,
      // oicq 传 apk.version（如 8.9.35.10440）；我们用 sdkver/ver 拼不出那就用 ver
      'appVersion': apk.ver,
      'beaconIdSrc': beacon.toString(),
      'brand': device.brand,
      'channelId': '2017',
      'cid': '',
      'imei': device.imei,
      'imsi': '',
      'mac': '',
      'model': device.model,
      'networkType': 'unknown',
      'oaid': '',
      'osVersion': 'Android ${device.version.release},level ${device.version.sdk}',
      'qimei': '',
      'qimei36': '',
      'sdkVersion': olaSdkVersion,
      'audit': '',
      'userId': '{}',
      'packageId': apk.id,
      'deviceType': 'Phone',
      'sdkName': '',
      'reserved': jsonEncode(reserved),
    };
    return jsonEncode(payload);
  }

  /// 组装请求：`{key, params, time, nonce, sign, extra}`。
  static Qq8QimeiRequest buildRequest(String payloadJson, {Random? random}) {
    final rnd = random ?? Random.secure();
    const alphabet = 'abcdef1234567890';
    String rand16() {
      final sb = StringBuffer();
      for (var i = 0; i < 16; i++) {
        sb.write(alphabet[rnd.nextInt(alphabet.length)]);
      }
      return sb.toString();
    }

    final cryptKey = rand16();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final nonce = rand16();
    final keyB64 = _rsaEncryptB64(cryptKey);
    final paramsB64 = aesCbcEncryptB64(payloadJson, cryptKey);
    final sign = _hex(md5Bytes(Uint8List.fromList(
        utf8.encode('$keyB64$paramsB64$ts$nonce$secret'))));
    final body = jsonEncode(<String, Object?>{
      'key': keyB64,
      'params': paramsB64,
      'time': ts,
      'nonce': nonce,
      'sign': sign,
      'extra': '',
    });
    return Qq8QimeiRequest(
      body: body,
      cryptKey: cryptKey,
      plainParams: payloadJson,
      sign: sign,
    );
  }

  /// 解开响应里 `data` 字段（AES-CBC，密钥就是本次的 cryptKey）。
  ///
  /// 响应格式：`{"code":0,"data":"<base64>"}`；解出来的 JSON 里有 `q16/q36`。
  static ({String q16, String q36}) decodeResponse(
      String responseJson, String cryptKey) {
    final m = jsonDecode(responseJson);
    if (m is! Map) {
      throw Qq8QimeiException('取号响应不是 JSON 对象');
    }
    final code = m['code'];
    if (code is num && code != 0) {
      throw Qq8QimeiException('取号被拒：code=$code');
    }
    final data = m['data'];
    if (data is! String || data.isEmpty) {
      throw Qq8QimeiException('取号响应里没有 data 字段');
    }
    final plain = aesCbcDecrypt(data, cryptKey);
    final inner = jsonDecode(plain);
    if (inner is! Map) {
      throw Qq8QimeiException('取号响应解出来不是 JSON 对象');
    }
    final q16 = inner['q16'];
    final q36 = inner['q36'];
    if (q16 is! String || q16.isEmpty || q36 is! String || q36.isEmpty) {
      throw Qq8QimeiException('取号响应里没有 q16/q36');
    }
    return (q16: q16, q36: q36);
  }

  // -- 内部 ---------------------------------------------------------------

  static Future<Qq8QimeiResult?> _post({
    required String endpoint,
    required String body,
    required String cryptKey,
    HttpClient? client,
    required Duration timeout,
    void Function(String line)? onLog,
  }) async {
    final c = client ?? HttpClient();
    try {
      c.connectionTimeout = timeout;
      final req = await c.postUrl(Uri.parse(endpoint));
      req.headers.contentType = ContentType('application', 'json');
      final bytes = utf8.encode(body);
      req.headers.contentLength = bytes.length;
      req.add(bytes);
      final rsp = await req.close().timeout(timeout);
      final text = await rsp.transform(utf8.decoder).join().timeout(timeout);
      onLog?.call('取号响应（$endpoint）：HTTP ${rsp.statusCode} / '
          '${text.length} 字节');
      if (rsp.statusCode != 200) return null;
      final r = decodeResponse(text, cryptKey);
      return Qq8QimeiResult(q16: r.q16, q36: r.q36, endpoint: endpoint);
    } finally {
      if (client == null) c.close(force: true);
    }
  }

  static String _rsaEncryptB64(String text) {
    // 类型参数必须写死 RSAPublicKey：`RSAEngine.init` 要的是
    // `AsymmetricKeyParameter<RSAAsymmetricKey>`，让 Dart 推断会退化成
    // `PublicKeyParameter<PublicKey>` 而运行时类型不符（踩过一次）。
    final eng = PKCS1Encoding(RSAEngine())
      ..init(
          true,
          PublicKeyParameter<RSAPublicKey>(
              RSAPublicKey(rsaModulus, rsaExponent)));
    final out = eng.process(Uint8List.fromList(utf8.encode(text)));
    return base64.encode(out);
  }

  /// AES-128-CBC（PKCS7）+ base64。密钥与 IV 都是本次的 cryptKey（照参考实现）。
  static String aesCbcEncryptB64(String plain, String key) {
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(true, PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>,
            KeyParameter>(
        ParametersWithIV<KeyParameter>(
            KeyParameter(Uint8List.fromList(utf8.encode(key))),
            Uint8List.fromList(utf8.encode(key))),
        null));
    final out = cipher.process(Uint8List.fromList(utf8.encode(plain)));
    return base64.encode(out);
  }

  /// 与 [aesCbcEncryptB64] 对称（解取号响应 / 自测往返用）。
  static String aesCbcDecrypt(String b64, String key) {
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(false, PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>,
            KeyParameter>(
        ParametersWithIV<KeyParameter>(
            KeyParameter(Uint8List.fromList(utf8.encode(key))),
            Uint8List.fromList(utf8.encode(key))),
        null));
    final out = cipher.process(base64.decode(b64));
    return utf8.decode(out);
  }

  static String _hex(List<int> b) =>
      b.map((x) => (x & 0xFF).toRadixString(16).padLeft(2, '0')).join();
}

/// 一次取号请求的三个关键产物（分开存是为了自测能逐项核对）。
class Qq8QimeiRequest {
  /// 真发出去的 JSON 体。
  final String body;

  /// 本次 AES 密钥（也是 IV）。
  final String cryptKey;

  /// 未加密的上报 JSON 明文。
  final String plainParams;

  /// `sign` 字段。
  final String sign;

  const Qq8QimeiRequest({
    required this.body,
    required this.cryptKey,
    required this.plainParams,
    required this.sign,
  });
}
