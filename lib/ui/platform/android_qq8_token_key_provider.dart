/// L4 平台能力：从 Android Keystore 取票据加密密钥。
///
/// 通道协议（对应 `MainActivity.kt` 的 `penguinchat/token_keystore`）：
///
/// ```text
///   getOrCreateDataKey({hasEncryptedTokens: bool}) → Uint8List(32)
///   错误码：
///     key_unavailable   Keystore 不可用 / 包裹密钥丢失
///     key_conflict      已有密文但密钥元数据缺失（拒绝生成新密钥）
///     unsupported       低于 API 23
/// ```
///
/// 放在 L4 是因为它必须 `import package:flutter/services.dart`；L3 的
/// `EncryptedFileQq8TokenStore` 只接收一个 `Future<List<int>> Function()`，
/// 由 `main.dart` 在这里注入。
library;

import 'dart:io';

import 'package:flutter/services.dart';

import '../../client_api/qq8_token_store.dart';

class AndroidQq8TokenKeyProvider {
  AndroidQq8TokenKeyProvider(this.tokenDirectory);

  static const MethodChannel _channel = MethodChannel('penguinchat/token_keystore');
  static final RegExp _encryptedName = RegExp(r'^qq8-token-\d+\.json\.enc$');

  final Directory tokenDirectory;

  /// 是否已有密文票据。有密文时原生侧不会再生成新密钥——宁可报错也不能
  /// 让既有票据变成永久解不开的死数据。
  Future<bool> _hasEncryptedTokens() async {
    if (!await tokenDirectory.exists()) return false;
    await for (final entity in tokenDirectory.list()) {
      if (entity is File && _encryptedName.hasMatch(entity.uri.pathSegments.last)) {
        return true;
      }
    }
    return false;
  }

  Future<List<int>> call() async {
    final hasEncrypted = await _hasEncryptedTokens();
    try {
      final bytes = await _channel.invokeMethod<Uint8List>(
        'getOrCreateDataKey',
        <String, Object?>{'hasEncryptedTokens': hasEncrypted},
      );
      if (bytes == null || bytes.length != 32) {
        throw const FormatException('Android Keystore returned invalid token key');
      }
      return bytes;
    } on PlatformException catch (e) {
      throw Qq8TokenStoreKeyUnavailable(
        'Android Keystore could not provide the session key (${e.code})',
      );
    } on MissingPluginException {
      throw const Qq8TokenStoreKeyUnavailable(
        'Android Keystore platform channel is unavailable',
      );
    }
  }
}
