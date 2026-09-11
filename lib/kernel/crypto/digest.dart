/// L2 协议内核：摘要算法
///
/// QQ 登录流程里大量直接使用 MD5，且**用途各不相同**，容易混淆：
///
/// | 用途 | 计算对象 |
/// |---|---|
/// | ECDH 协商密钥 | `MD5(共享秘密[0..16))` |
/// | 设备 guid | `MD5(IMEI + MAC)` |
/// | TLV 0x109 | `MD5(IMEI)` |
/// | TLV 0x187 | `MD5(MAC 地址)` |
/// | TLV 0x188 | `MD5(android_id)` |
/// | TLV 0x106 的加密密钥 | `MD5(password_md5 + 0000 + uin_u32be)` |
///
/// 它们都是**裸 MD5，无盐、无 HMAC**，因此这里只提供一个函数。
///
/// 单独成文件的理由：早先 `md5Bytes` 放在 `crypto/ecdh.dart` 里，
/// 让 TLV 层从 ECDH 模块导入摘要函数语义上不通。已拆出，
/// `ecdh.dart` 做了 re-export 以保持既有 import 不变。
///
/// 本文件是纯 Dart，不依赖 Flutter。
library;

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// MD5，返回 16 字节。
Uint8List md5Bytes(List<int> data) {
  final digest = MD5Digest();
  final bytes = data is Uint8List ? data : Uint8List.fromList(data);
  final out = Uint8List(digest.digestSize);
  digest.update(bytes, 0, bytes.length);
  digest.doFinal(out, 0);
  return out;
}
