/// L2 加密引擎：TEA / XXTEA
///
/// QQ 传统包加密算法。TEA 系（Tiny Encryption Algorithm）是 QQ 自 2000 年代
/// 沿用至今的对称加密，64 位分组、128 位密钥、Feistel 结构。
///
/// 算法参数（QQ 使用的变体）：
///   - delta = 0x9E3779B9（黄金比例常量）
///   - 轮数 = 16（QQ 变体，标准 TEA 为 32 轮）
///   - 字节序 = 小端
///
/// ⚠ 待验证：轮数与 delta 需通过与 native 实现（Ghidra 分析 .so）交叉确认。
///
/// 对应 Python 实现：qqclient-python/kernel/crypto/tea.py
library;

import 'dart:typed_data';

const int _delta = 0x9E3779B9;
const int _rounds = 16;
const int _mask = 0xFFFFFFFF;

/// 字节流 -> 32 位字列表（小端）
List<int> _toU32(List<int> data) {
  if (data.length % 4 != 0) {
    throw ArgumentError('TEA 分组长度必须是 4 的倍数');
  }
  final out = <int>[];
  for (var i = 0; i < data.length; i += 4) {
    out.add(data[i] | (data[i + 1] << 8) | (data[i + 2] << 16) | (data[i + 3] << 24));
  }
  return out;
}

/// 32 位字列表 -> 字节流（小端）
Uint8List _fromU32(List<int> vals) {
  final b = Uint8List(vals.length * 4);
  for (var i = 0; i < vals.length; i++) {
    final v = vals[i];
    b[i * 4] = v & 0xFF;
    b[i * 4 + 1] = (v >> 8) & 0xFF;
    b[i * 4 + 2] = (v >> 16) & 0xFF;
    b[i * 4 + 3] = (v >> 24) & 0xFF;
  }
  return b;
}

List<int> _keyInts(List<int> key) {
  if (key.length != 16) {
    throw ArgumentError('TEA 密钥必须是 16 字节');
  }
  return _toU32(key);
}

/// 加密单个 64 位分组，返回 (v0, v1)
(List<int>, List<int>) _encryptBlock(int v0, int v1, List<int> k) {
  var s = 0;
  for (var i = 0; i < _rounds; i++) {
    s = (s + _delta) & _mask;
    v0 = (v0 + ((((v1 << 4) & _mask) + k[0]) ^ (v1 + s) ^ ((v1 >> 5) + k[1]))) & _mask;
    v1 = (v1 + ((((v0 << 4) & _mask) + k[2]) ^ (v0 + s) ^ ((v0 >> 5) + k[3]))) & _mask;
  }
  return ([v0], [v1]);
}

/// 解密单个 64 位分组，返回 (v0, v1)
(List<int>, List<int>) _decryptBlock(int v0, int v1, List<int> k) {
  var s = (_delta * _rounds) & _mask;
  for (var i = 0; i < _rounds; i++) {
    v1 = (v1 - ((((v0 << 4) & _mask) + k[2]) ^ (v0 + s) ^ ((v0 >> 5) + k[3]))) & _mask;
    v0 = (v0 - ((((v1 << 4) & _mask) + k[0]) ^ (v1 + s) ^ ((v1 >> 5) + k[1]))) & _mask;
    s = (s - _delta) & _mask;
  }
  return ([v0], [v1]);
}

/// ECB 模式整段加密（QQ 历史上即 ECB）
Uint8List teaEncrypt(List<int> data, List<int> key) {
  final k = _keyInts(key);
  final vals = _toU32(data);
  final out = <int>[];
  for (var i = 0; i < vals.length; i += 2) {
    final r = _encryptBlock(vals[i], vals[i + 1], k);
    out..add(r.$1[0])..add(r.$2[0]);
  }
  return _fromU32(out);
}

/// ECB 模式整段解密
Uint8List teaDecrypt(List<int> data, List<int> key) {
  final k = _keyInts(key);
  final vals = _toU32(data);
  final out = <int>[];
  for (var i = 0; i < vals.length; i += 2) {
    final r = _decryptBlock(vals[i], vals[i + 1], k);
    out..add(r.$1[0])..add(r.$2[0]);
  }
  return _fromU32(out);
}

int _mx(int z, int y, int s, int p, int e, List<int> k) {
  return ((((z >> 5) ^ ((y << 2) & _mask)) +
              ((y >> 3) ^ ((z << 4) & _mask))) ^
          ((s ^ y) + (k[(p & 3) ^ e] ^ z))) &
      _mask;
}

/// XXTEA 变体（Corrected Block TEA），常用于自定义长度数据
Uint8List xxteaEncrypt(List<int> data, List<int> key, {bool padding = true}) {
  var d = List<int>.from(data);
  if (d.length % 4 != 0 && padding) {
    d = [...d, ...List.filled(4 - d.length % 4, 0)];
  }
  final v = _toU32(d);
  final n = v.length;
  if (n < 2) return Uint8List.fromList(d);
  final k = _keyInts(key);
  final q = 6 + 52 ~/ n;
  var s = 0;
  var z = v[n - 1];
  for (var i = 0; i < q; i++) {
    s = (s + _delta) & _mask;
    final e = (s >> 2) & 3;
    for (var p = 0; p < n - 1; p++) {
      final y = v[p + 1];
      v[p] = (v[p] + _mx(z, y, s, p, e, k)) & _mask;
      z = v[p];
    }
    final y = v[0];
    v[n - 1] = (v[n - 1] + _mx(z, y, s, n - 1, e, k)) & _mask;
    z = v[n - 1];
  }
  return _fromU32(v);
}

/// XXTEA 解密
Uint8List xxteaDecrypt(List<int> data, List<int> key) {
  final v = _toU32(data);
  final n = v.length;
  if (n < 2) return Uint8List.fromList(data);
  final k = _keyInts(key);
  final q = 6 + 52 ~/ n;
  var s = (q * _delta) & _mask;
  var y = v[0];
  for (var i = 0; i < q; i++) {
    final e = (s >> 2) & 3;
    for (var p = n - 1; p > 0; p--) {
      final z = v[p - 1];
      v[p] = (v[p] - _mx(z, y, s, p, e, k)) & _mask;
      y = v[p];
    }
    final z = v[n - 1];
    v[0] = (v[0] - _mx(z, y, s, 0, e, k)) & _mask;
    y = v[0];
    s = (s - _delta) & _mask;
  }
  return _fromU32(v);
}
