/// L2 加密引擎：TEA 分组密码（QQ 变体）
///
/// ## 本文件的定位
///
/// 这里实现的是**裸分组密码**（64 位分组、ECB 单块变换）。
/// 它不等于 QQ 线上实际使用的加密——真实报文走 [qqTeaEncrypt] 那套
/// 「填充 + CBC 链式」模式，见 `qqtea.dart`。
/// 本文件保留裸分组，是为了让轮函数可被单测直接验证。
///
/// ## 算法参数（已由反编译证实，非推测）
///
/// 证据来源：`oicq.wlogin_sdk.tools.a`（由 `cryptor` 调用）
/// ```java
/// // 加密：sum 从 0 起，16 轮
/// j2 = (j2 + 2654435769L) & 0xFFFFFFFF;              // 0x9E3779B9
/// jB  += ((jB2<<4)+k0) ^ (jB2+j2) ^ ((jB2>>>5)+k1);
/// jB2 += ((jB<<4)+k2)  ^ (jB+j2)  ^ ((jB>>>5)+k3);
///
/// // 解密：sum 初值 3816266640
/// jB2 -= ((jB<<4)+k2)  ^ (jB+j2)  ^ ((jB>>>5)+k3);
/// jB  -= ((jB2<<4)+k0) ^ (jB2+j2) ^ ((jB2>>>5)+k1);
/// ```
/// → delta = `0x9E3779B9`、轮数 = **16**、解密 sum 初值 = `0xE3779B90`（= delta×16 取低 32 位）
///
/// ## 字节序：大端（关键修正）
///
/// 反编译证据 `oicq.wlogin_sdk.tools.a.b()`：
/// ```java
/// j2 = 0;
/// while (i < i3) { j2 = (j2 << 8) | ((long)(bArr[i] & 255)); i++; }
/// ```
/// 逐字节左移累加 → **首字节是最高位**，即大端。
/// 输出侧 `DataOutputStream.writeInt()` 同样是大端。
///
/// ⚠️ 本实现早期版本误用小端，已于 M2 依据上述证据修正。
library;

import 'dart:math';
import 'dart:typed_data';

/// 黄金比例常量，QQ TEA 的轮常量。
const int teaDelta = 0x9E3779B9;

/// QQ 变体使用 16 轮（标准 TEA 为 32 轮）。
const int teaRounds = 16;

/// 解密时 sum 的初值 = delta × 16 取低 32 位。
const int _sumInitDecrypt = (teaDelta * teaRounds) & 0xFFFFFFFF;

const int _mask = 0xFFFFFFFF;

/// 字节流 -> 32 位字列表（**大端**，与反编译证据一致）。
List<int> bytesToU32BE(List<int> data) {
  if (data.length % 4 != 0) {
    throw ArgumentError('分组长度必须是 4 的倍数，实际 ${data.length}');
  }
  final out = <int>[];
  for (var i = 0; i < data.length; i += 4) {
    out.add(((data[i] << 24) |
            (data[i + 1] << 16) |
            (data[i + 2] << 8) |
            data[i + 3]) &
        _mask);
  }
  return out;
}

/// 32 位字列表 -> 字节流（**大端**）。
Uint8List u32ToBytesBE(List<int> vals) {
  final b = Uint8List(vals.length * 4);
  for (var i = 0; i < vals.length; i++) {
    final v = vals[i];
    b[i * 4] = (v >> 24) & 0xFF;
    b[i * 4 + 1] = (v >> 16) & 0xFF;
    b[i * 4 + 2] = (v >> 8) & 0xFF;
    b[i * 4 + 3] = v & 0xFF;
  }
  return b;
}

/// 密钥解析：16 字节 -> 4 个 32 位字（大端）。
List<int> _keyInts(List<int> key) {
  if (key.length != 16) {
    throw ArgumentError('TEA 密钥必须是 16 字节，实际 ${key.length}');
  }
  return bytesToU32BE(key);
}

/// 取低 32 位的逻辑右移。
int _lsr32(int v, int n) => (v & _mask) >> n;

/// 加密单个 64 位分组。返回 (v0, v1)。
({int v0, int v1}) teaEncryptBlock(int v0, int v1, List<int> k) {
  var sum = 0;
  var a = v0 & _mask;
  var b = v1 & _mask;
  for (var i = 0; i < teaRounds; i++) {
    sum = (sum + teaDelta) & _mask;
    a = (a + ((((b << 4) & _mask) + k[0]) ^ (b + sum) ^ (_lsr32(b, 5) + k[1]))) & _mask;
    b = (b + ((((a << 4) & _mask) + k[2]) ^ (a + sum) ^ (_lsr32(a, 5) + k[3]))) & _mask;
  }
  return (v0: a, v1: b);
}

/// 解密单个 64 位分组。返回 (v0, v1)。
({int v0, int v1}) teaDecryptBlock(int v0, int v1, List<int> k) {
  var sum = _sumInitDecrypt;
  var a = v0 & _mask;
  var b = v1 & _mask;
  for (var i = 0; i < teaRounds; i++) {
    b = (b - ((((a << 4) & _mask) + k[2]) ^ (a + sum) ^ (_lsr32(a, 5) + k[3]))) & _mask;
    a = (a - ((((b << 4) & _mask) + k[0]) ^ (b + sum) ^ (_lsr32(b, 5) + k[1]))) & _mask;
    sum = (sum - teaDelta) & _mask;
  }
  return (v0: a, v1: b);
}

/// ECB 模式整段加密（教学/单测用；真实协议请用 `qqTeaEncrypt`）。
Uint8List teaEncrypt(List<int> data, List<int> key) {
  final k = _keyInts(key);
  final vals = bytesToU32BE(data);
  final out = <int>[];
  for (var i = 0; i < vals.length; i += 2) {
    final r = teaEncryptBlock(vals[i], vals[i + 1], k);
    out..add(r.v0)..add(r.v1);
  }
  return u32ToBytesBE(out);
}

/// ECB 模式整段解密（教学/单测用；真实协议请用 `qqTeaDecrypt`）。
Uint8List teaDecrypt(List<int> data, List<int> key) {
  final k = _keyInts(key);
  final vals = bytesToU32BE(data);
  final out = <int>[];
  for (var i = 0; i < vals.length; i += 2) {
    final r = teaDecryptBlock(vals[i], vals[i + 1], k);
    out..add(r.v0)..add(r.v1);
  }
  return u32ToBytesBE(out);
}

int _mx(int z, int y, int s, int p, int e, List<int> k) {
  return ((((z >> 5) ^ ((y << 2) & _mask)) +
              ((y >> 3) ^ ((z << 4) & _mask))) ^
          ((s ^ y) + (k[(p & 3) ^ e] ^ z))) &
      _mask;
}

/// XXTEA（Corrected Block TEA）。
///
/// ⚠️ 归因说明：**尚无证据表明 QQ 使用 XXTEA**。
/// 目标 APK 的 `oicq.wlogin_sdk.tools.cryptor` 用的是 TEA + CBC（见上）。
/// 本函数作为通用实现保留，供对比与教学，不属于 QQ 协议链路。
Uint8List xxteaEncrypt(List<int> data, List<int> key, {bool padding = true}) {
  var d = List<int>.from(data);
  if (d.length % 4 != 0 && padding) {
    d = [...d, ...List.filled(4 - d.length % 4, 0)];
  }
  final v = bytesToU32BE(d);
  final n = v.length;
  if (n < 2) return Uint8List.fromList(d);
  final k = _keyInts(key);
  final q = 6 + 52 ~/ n;
  var s = 0;
  var z = v[n - 1];
  for (var i = 0; i < q; i++) {
    s = (s + teaDelta) & _mask;
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
  return u32ToBytesBE(v);
}

/// XXTEA 解密。参见 [xxteaEncrypt] 的归因说明。
Uint8List xxteaDecrypt(List<int> data, List<int> key) {
  final v = bytesToU32BE(data);
  final n = v.length;
  if (n < 2) return Uint8List.fromList(data);
  final k = _keyInts(key);
  final q = 6 + 52 ~/ n;
  var s = (q * teaDelta) & _mask;
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
    s = (s - teaDelta) & _mask;
  }
  return u32ToBytesBE(v);
}

/// 单个 8 字节分组的 CBC 链式加密（内部使用）。
Uint8List _cbcEncryptBlock(Uint8List block, Uint8List prev, List<int> k) {
  final x = Uint8List(8);
  for (var i = 0; i < 8; i++) {
    x[i] = block[i] ^ prev[i];
  }
  final v = bytesToU32BE(x);
  final r = teaEncryptBlock(v[0], v[1], k);
  return u32ToBytesBE([r.v0, r.v1]);
}

/// 单个 8 字节分组的 CBC 链式解密（内部使用）。
Uint8List _cbcDecryptBlock(Uint8List block, Uint8List prev, List<int> k) {
  final v = bytesToU32BE(block);
  final r = teaDecryptBlock(v[0], v[1], k);
  final dec = u32ToBytesBE([r.v0, r.v1]);
  final out = Uint8List(8);
  for (var i = 0; i < 8; i++) {
    out[i] = dec[i] ^ prev[i];
  }
  return out;
}

// ============================================================
//  以下为 QQ 实际使用的「填充 + CBC」模式实现。
//
//  证据：oicq.wlogin_sdk.tools.cryptor.encrypt / decrypt
//    加密：pad = (8 - (len + 10) % 8) % 8
//          输出长度 = pad + len + 10
//          明文布局 = [ (rand&0xF8)|pad ][ pad 字节随机 ][ 2 字节随机 ]
//                     [ len 字节正文 ][ 7 字节 0 ]
//    解密：pad = D(C0)[0] & 7
//          len = total - pad - 10
//          跳过 pad + 3 字节后取出 len 字节，再校验 7 个 0
//
//  注意：随机填充字节由 java.util.Random 产生（非密码学安全）。
//  因此同一明文的密文不可复现——这是算法本身的特性，不是实现缺陷。
//  为可测试性，填充字节支持注入。
// ============================================================

/// 计算 QQ TEA 的填充长度：`(8 - (len + 10) % 8) % 8`。
int qqTeaPadLength(int dataLen) {
  final r = (dataLen + 10) % 8;
  return r == 0 ? 0 : 8 - r;
}

/// QQ TEA 加密（填充 + CBC，零 IV）。
///
/// [paddingBytes] 用于注入确定性的填充（测试用）；为 null 时使用
/// 密码学随机源。传入长度须为 `2 + qqTeaPadLength(plain.length)`。
Uint8List qqTeaEncrypt(
  List<int> plain,
  List<int> key, {
  List<int>? paddingBytes,
}) {
  final k = _keyInts(key);
  final len = plain.length;
  final pad = qqTeaPadLength(len);
  final total = pad + len + 10;

  // 组装带填充的明文
  final buf = Uint8List(total);
  // 布局：[0] 首字节  [1..pad] 随机  [pad+1][pad+2] 随机  -> 共 pad+3 字节
  final need = pad + 3;
  if (paddingBytes != null) {
    if (paddingBytes.length < need) {
      throw ArgumentError('填充字节不足：需 $need，得 ${paddingBytes.length}');
    }
  }
  final rnd = paddingBytes ?? Uint8List.fromList(_secureRandom(need));

  buf[0] = (rnd[0] & 0xF8) | pad & 0x07;
  for (var i = 1; i <= pad; i++) {
    buf[i] = rnd[i];
  }
  // buf[pad+1], buf[pad+2] 为 2 字节随机
  buf[pad + 1] = rnd[pad + 1];
  buf[pad + 2] = rnd[pad + 2];
  buf.setRange(pad + 3, pad + 3 + len, plain);
  // 末尾 7 字节保持 0

  // CBC 链式加密
  final out = Uint8List(total);
  final prev = Uint8List(8); // 零 IV
  final block = Uint8List(8);
  for (var off = 0; off < total; off += 8) {
    block.setRange(0, 8, buf, off);
    final c = _cbcEncryptBlock(block, prev, k);
    out.setRange(off, off + 8, c);
    prev.setRange(0, 8, c);
  }
  return out;
}

/// QQ TEA 解密。填充不合法时抛 [FormatException]。
Uint8List qqTeaDecrypt(List<int> cipher, List<int> key) {
  final k = _keyInts(key);
  final total = cipher.length;
  if (total % 8 != 0 || total < 16) {
    throw FormatException('密文长度必须为 8 的倍数且 >= 16，实际 $total');
  }

  // 先解出首块以取填充长度
  final first = Uint8List.fromList(cipher.sublist(0, 8));
  final firstPlain = _cbcDecryptBlock(first, Uint8List(8), k);
  final pad = firstPlain[0] & 0x07;
  final dataLen = total - pad - 10;
  if (dataLen < 0) {
    throw const FormatException('填充长度非法，报文损坏');
  }

  // 全量 CBC 解密
  final plain = Uint8List(total);
  final prev = Uint8List(8);
  final block = Uint8List(8);
  for (var off = 0; off < total; off += 8) {
    block.setRange(0, 8, cipher, off);
    final p = _cbcDecryptBlock(block, prev, k);
    plain.setRange(off, off + 8, p);
    prev.setRange(0, 8, cipher, off);
  }

  // 校验末尾 7 字节为 0（数据完整性检查）
  for (var i = pad + 3 + dataLen; i < total; i++) {
    if (plain[i] != 0) {
      throw const FormatException('尾部校验失败：存在非零填充字节');
    }
  }

  return Uint8List.fromList(plain.sublist(pad + 3, pad + 3 + dataLen));
}

/// 产生 [n] 字节随机填充。
///
/// 说明：QQ 客户端用 `java.util.Random`（线性同余，可预测）。
/// 本实现改用 `Random.secure()`——填充字节不参与协议语义，
/// 服务端也不会校验其随机性，因此换成安全源严格更优。
List<int> _secureRandom(int n) {
  final rnd = _secureRnd ??= Random.secure();
  return List<int>.generate(n, (_) => rnd.nextInt(256));
}

Random? _secureRnd;
