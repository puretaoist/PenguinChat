/// QSec lite-sign（TLV 0x544）纯算法实现
///
/// ## 数据来源
/// 常量表来自同目录 [qq8_t544_tables]（由 `analysis/scripts/gen_t544_assets.mts`
/// 生成），本文件**不重复定义表**。唯一例外是「推导表」一节，见下。
///
/// ## 算法出处
/// 逐行移植自 oicq 2.3.1 `lib/internal/encryption.ts`
/// （commit 726958d，2023-05-24）的 `sign(curr, input)` 及其全部依赖：
/// `roll`、`tencentCrc32`、`transformInner`、`tencentEncryptionA`、
/// `_tencentEncryptB`、`tencentEncryptB`、`sub_a`/`sub_b`/`sub_c`/`sub_d`/
/// `sub_e`/`sub_ab`/`sub_f`/`sub_aa`、`initState`、`refreshState`、`state`
/// 类、`toBytes`、`readUint128`。
/// oicq 源码注释写明该实现移植自 **go-cqhttp 的 `encryption_generic.go`**
/// （其对应汇编为 `encryption_amd64.s`），即腾讯 QSec 的 lite-sign 设备码。
///
/// ## 可信度警告
/// **这是逆向得到的假设实现。** `vectors/t544.json` 里的黄金向量由参考实现
/// 自己生成，因此逐字节吻合只能证明「本次移植忠实于参考实现」，
/// **不能证明 QQ 服务端会接受这份签名**。
/// 此外 salt 的字节布局有两种候选（oicq `tlv.ts:334` 的布局 vs 官方
/// `tlv_t544.java` 交给 `ByteData.getCode` 的布局），
/// 究竟哪一种被服务端接受，**只有真机登录能裁决**。
///
/// ## 推导表（AES S-box 与 GF(2^8) 乘常数表）
/// 参考实现用到两张**不在** [qq8_t544_tables] 里的表：
///   - `encrypt.tableB`：16×16，即标准 AES S-box；
///   - `encrypt.tableC`：256×6，行 i 依次为
///     `gmul(2,i) gmul(3,i) gmul(9,i) gmul(11,i) gmul(13,i) gmul(14,i)`。
/// 两者都能从数学定义**唯一重建**，所以这里就地推导，而不是塞进 1800 多个
/// 字面量（那样也会违反「表都由生成脚本产出」的约定）：
///   - `tableB[v] = affin(inv(v))`，`inv` 为 GF(2^8) 乘法逆元；
///   - `tableC[v] = gmul(常数, v)`，`gmul` 为 GF(2^8) 乘法（模 0x11b）。
/// 推导结果已与参考实现的两张表**逐项全等**（256×1 与 256×6），
/// 且黄金向量本身会走遍这两张表——向量全过即证其正确；
/// 自测里另有对标准值的硬编码抽查。
///
/// ## JS → Dart 语义
/// 参考实现全程按 **32 位无符号**运算。Dart 的 `int` 是 64 位，
/// 因此所有位运算/加减都显式 `& 0xffffffff`（见 [_m32] 与各处 `& _m32`）。
///
/// 本文件是纯 Dart，不依赖 Flutter。
///
/// `sub_ad` 里的寄存器名（`R10`/`BP`/`DX`…）刻意保留参考实现 `sub_ad` 的
/// 原始拼写：这是逆向产物，逐行可对照的价值高于命名规范。
// ignore_for_file: non_constant_identifier_names
library;

import 'dart:math';
import 'dart:typed_data';

import '../crypto/digest.dart';
import 'qq8_t544_tables.dart';

/// 32 位掩码。参考实现里每个中间量都活在 u32/i32 里，Dart 必须手动截断。
const int _m32 = 0xFFFFFFFF;

// ───────────────────────────────────────────────────────────────────────────
// 熵（四处随机源）
// ───────────────────────────────────────────────────────────────────────────

/// 参考实现 `sign()` 里的四处随机源。
///
/// 全为 `null`（默认）时走 [Random.secure]；传入钉死值即可完全复现，
/// 黄金向量（`vectors/t544.json` 的 `entropy` 字段）就是靠它回放。
class Qq8T544Entropy {
  const Qq8T544Entropy({
    this.keyTablePicks,
    this.table2Picks,
    this.nonce,
    this.addition,
  });

  /// 类索引 [qq8T544KeyTable] 的两个下标（长度 2），对应参考实现的
  /// `keyTable[Math.floor(Math.random() * 50)]`。
  final List<int>? keyTablePicks;

  /// 类索引 [qq8T544Table2] 的两个下标（长度 2），对应 `table2[...]`。
  final List<int>? table2Picks;

  /// `nonce`，对应 `crypto.randomBytes(4).readUInt32BE(0)`。
  final int? nonce;

  /// `addition`，**必须为 1..8 内的奇数**（参考实现里抽到偶数就重抽）。
  final int? addition;
}

// ───────────────────────────────────────────────────────────────────────────
// 小工具：大端/小端读写、循环左移
// ───────────────────────────────────────────────────────────────────────────

/// JS `roll(a, n)`：
/// ```js
/// a = a & 0xffffffff
/// return a << n | a >>> (32 - n)
/// ```
/// `a` 已掩码到 32 位，因此 Dart 的 `>>`（算术右移）等价于 JS 的 `>>>`。
int _roll(int a, int n) {
  a &= _m32;
  return ((a << n) | (a >> (32 - n))) & _m32;
}

/// `Buffer.writeUInt32BE`：4 字节**大端**。
void _writeU32BE(Uint8List d, int off, int v) {
  d[off] = (v >> 24) & 0xFF;
  d[off + 1] = (v >> 16) & 0xFF;
  d[off + 2] = (v >> 8) & 0xFF;
  d[off + 3] = v & 0xFF;
}

/// `Buffer.writeUint32LE`（注意参考实现里大小写两种都出现过）：4 字节**小端**。
void _writeU32LE(Uint8List d, int off, int v) {
  d[off] = v & 0xFF;
  d[off + 1] = (v >> 8) & 0xFF;
  d[off + 2] = (v >> 16) & 0xFF;
  d[off + 3] = (v >> 24) & 0xFF;
}

/// `Buffer.writeBigUint64LE`：8 字节**小端**。
void _writeU64LE(Uint8List d, int off, int v) {
  var x = v;
  for (var i = 0; i < 8; i++) {
    d[off + i] = x & 0xFF;
    x >>= 8;
  }
}

// ───────────────────────────────────────────────────────────────────────────
// 推导表：AES S-box（= tableB）与 GF(2^8) 乘常数表（= tableC）
// ───────────────────────────────────────────────────────────────────────────

/// GF(2^8)（模多项式 0x11b）的指数/对数表与由它推出的 S-box、乘常数表。
///
/// 生成元取 3：`x_{n+1} = x_n * 3`，这正好是参考实现所隐含的那种域表示
/// （否则 S-box 不会等于标准 AES S-box）。
class _Aes {
  _Aes._() {
    // ── 指数/对数表（生成元 3）──
    var x = 1;
    for (var n = 0; n < 255; n++) {
      _exp[n] = x;
      _log[x] = n;
      // x *= 3 在 GF(2^8) 上 = x ^ (x<<1) ^ (0x11b if 溢出)
      x ^= (x << 1) ^ ((x & 0x80) != 0 ? 0x11B : 0);
      x &= 0xFF;
    }
    _exp[255] = _exp[0];

    // ── S-box：先求乘法逆元，再仿射变换 s ^= rotl8(s, k) (k=1..4)，最后 ^0x63 ──
    for (var v = 0; v < 256; v++) {
      final iv = _inv(v);
      var s = iv;
      for (var k = 1; k <= 4; k++) {
        s ^= ((iv << k) | (iv >> (8 - k))) & 0xFF;
      }
      _sbox[v] = (s ^ 0x63) & 0xFF;
    }

    // ── tableC：行 v = [gmul(2,v), gmul(3,v), gmul(9,v), gmul(11,v), gmul(13,v), gmul(14,v)] ──
    // 这六个常数正是 AES MixColumns 矩阵的系数。
    const coefs = [2, 3, 9, 11, 13, 14];
    for (var v = 0; v < 256; v++) {
      for (var j = 0; j < 6; j++) {
        _mulTab[v][j] = _mul(coefs[j], v);
      }
    }
  }

  static final _Aes i = _Aes._();

  final Uint8List _exp = Uint8List(256);
  final Uint8List _log = Uint8List(256);
  final Uint8List _sbox = Uint8List(256);
  final List<List<int>> _mulTab =
      List<List<int>>.generate(256, (_) => List<int>.filled(6, 0));

  int _mul(int a, int b) =>
      (a == 0 || b == 0) ? 0 : _exp[(_log[a] + _log[b]) % 255];

  int _inv(int a) => a == 0 ? 0 : _exp[(255 - _log[a]) % 255];
}

/// 推导出的 AES S-box（256 字节，行优先，即 `[v]` 直接对应 `tableB[v>>4][v&15]`）。
final Uint8List _aesSbox = _Aes.i._sbox;

/// 推导出的 GF(2^8) 乘常数表，等价于参考实现的 `encrypt.tableC`。
final List<List<int>> _gfMul = _Aes.i._mulTab;

/// 参考实现 `encrypt.tableA` 是 `[16][2][16][16]` 的四维嵌套置换表，
/// 生成脚本把它导成了 `List<dynamic>`；这里做逐层下标的取值而**不复制数据**。
int _tableAAt(int i1, int i2, int i3, int i4) {
  final l1 = qq8T544TableA[i1] as List<dynamic>;
  final l2 = l1[i2] as List<dynamic>;
  final l3 = l2[i3] as List<dynamic>;
  return l3[i4] as int;
}

/// 自测钩子：把推导出的 AES S-box 暴露出来，用于与标准值独立对照。
Uint8List qq8T544AesSboxForTest() => Uint8List.fromList(_aesSbox);

/// 自测钩子：把推导出的 GF(2^8) 乘常数表暴露出来（浅拷贝外层）。
List<List<int>> qq8T544GfMulTableForTest() =>
    List<List<int>>.generate(256, (v) => List<int>.from(_gfMul[v]));

// ───────────────────────────────────────────────────────────────────────────
// RC4（dart 侧无标准库实现，自己写）
// ───────────────────────────────────────────────────────────────────────────

/// 标准 RC4（KSA + PRGA），`out[i] = data[i] ^ keystream[i]`。
///
/// 参考实现用的是 `crypto.createCipheriv('rc4', key, '')`（空 IV、无 padding、
/// 无 keystream 丢弃），就是教科书 RC4，因此这里逐字节对齐。
///
/// 公开导出是为了让自测能拿 RFC 6229 / 公开向量**独立**校验它——
/// 它是整条链路上唯一非项目自有的原语，值得单独钉住。
Uint8List qq8T544Rc4(List<int> key, List<int> data) {
  if (key.isEmpty) {
    throw ArgumentError.value(key, 'key', 'RC4 密钥不能为空');
  }
  final s = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    s[i] = i;
  }
  // KSA
  var j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j + s[i] + key[i % key.length]) & 0xFF;
    final t = s[i];
    s[i] = s[j];
    s[j] = t;
  }
  // PRGA
  final out = Uint8List(data.length);
  var i = 0;
  j = 0;
  for (var k = 0; k < data.length; k++) {
    i = (i + 1) & 0xFF;
    j = (j + s[i]) & 0xFF;
    final t = s[i];
    s[i] = s[j];
    s[j] = t;
    out[k] = (data[k] ^ s[(s[i] + s[j]) & 0xFF]) & 0xFF;
  }
  return out;
}

// ───────────────────────────────────────────────────────────────────────────
// ChaCha 家族流密码（go-cqhttp encryption_generic.go 的 state）
// ───────────────────────────────────────────────────────────────────────────

/// 参考实现的 `state` 类。
///
/// 注意 `state` 与 `orgState` 在 `encrypt()` 里会被**赋成同一个数组**
/// （原代码 `this.state = this.orgState`）。这里如实保留该行为——
/// 虽然本次用到的数据长度（< 64 字节）永远走不到那条分支。
class _ChaChaState {
  _ChaChaState(this.state, this.orgState, this.nr, this.p);

  Uint32List state;
  Uint32List orgState;
  int nr;
  int p;

  void init(Uint8List key, Uint8List data, Uint32List d, int nrIn) {
    nr = nrIn;
    p = 0;
    _initState(this, key, data, d);
  }

  /// `state.encrypt(data)`：就地异或一段 keystream。
  ///
  /// keystream 由 `state` 按**小端**（`writeUint32LE`）序列化成 64 字节块，
  /// 每块的首个字节之前若 `p == 0` 则先 `refreshState`（counter 加在
  /// `orgState[12]`）。
  void encrypt(Uint8List data) {
    var bp = 0;
    var dataLen = data.length;
    while (dataLen > 0) {
      if (p == 0) {
        _refreshState(this);
      }
      final sb = Uint8List(64);
      for (var i = 0; i < 16; i++) {
        _writeU32LE(sb, i * 4, state[i]);
      }
      while (p != 64 && dataLen != 0) {
        data[bp] ^= sb[p];
        p++;
        bp++;
        dataLen--;
      }
      if (p >= 64) {
        p = 0;
        orgState[12]++; // Uint32List 赋值自带 2^32 回绕
        state = orgState;
      }
    }
  }
}

/// `initState(a, b, c, d)`：构造初始 state。
///
/// 参数映射（来自 `state.init`）：`b = key`（32B），`c = data`（8B），
/// `d = [0, 0]`。注意 `orgState[12..15]` **从不被显式赋值**，
/// 保持构造时的 0；而 `state[12..15]` 取 `d` 与 `c`（即 data）。
void _initState(_ChaChaState a, Uint8List b, Uint8List c, Uint32List d) {
  a.orgState[0] = a.state[0] = 1634760805; // "expa"
  a.orgState[1] = a.state[1] = 857760878; // "nd 3"
  a.orgState[2] = a.state[2] = 2036477234; // "2-by"
  a.orgState[3] = a.state[3] = 1797285236; // "te k"
  final w1 = _readUint128(b, 0);
  for (var i = 0; i < 4; i++) {
    a.state[4 + i] = w1[i];
    a.orgState[4 + i] = w1[i];
  }
  a.state[12] = d[1];
  a.state[13] = d[0];
  final w2 = _readUint128(b, 16);
  for (var i = 0; i < 4; i++) {
    a.state[8 + i] = w2[i];
    a.orgState[8 + i] = w2[i];
  }
  final w3 = _readUint128(c, 0);
  a.state[14] = w3[0];
  a.state[15] = w3[1];
}

/// `readUint128(a, i)`：按**小端**把最多 16 字节读成 4 个 u32。
///
/// JS 的运算符优先级要注意：`ans | (a[..]) << shift & 0xffffffff`
/// 实际是 `ans | (((a[..]) << shift) & 0xffffffff)`（`<<` > `&` > `|`）。
Uint32List _readUint128(Uint8List a, int i) {
  var ans = 0;
  final w = Uint32List(4);
  for (var cnt = 1; cnt <= 16 && i + cnt <= a.length; cnt++) {
    ans = (ans | ((a[i + cnt - 1] << (8 * ((cnt - 1) % 4))) & _m32)) & _m32;
    if (cnt % 4 == 0) {
      w[cnt ~/ 4 - 1] = ans;
      ans = 0;
    }
  }
  return w;
}

/// `refreshState(a)`：做 `nr/2` 次 [_subAd]，再把 orgState 加回 state。
void _refreshState(_ChaChaState a) {
  final cx = a.nr ~/ 2; // Math.floor(a.nr / 2)
  for (var i = 0; i < cx; i++) {
    _subAd(a);
  }
  for (var i = 0; i < 16; i++) {
    a.state[i] = (a.state[i] + a.orgState[i]) & _m32;
  }
}

/// `sub_ad(a)`：参考实现里手写展开的一整个 ChaCha 双轮。
///
/// **逐行照抄**（变量名与源码一致），只在每个 `+` 之后补 `& 0xffffffff`——
/// JS 里 `+` 产生的是普通 number，落到 `Uint32Array` 时才截断，
/// 而 Dart 必须在每步显式截断，否则后续 `^`/`>>` 会看到 64 位高位。
void _subAd(_ChaChaState a) {
  final st = a.state;
  var R10 = st[10];
  var R12 = st[3];
  var BP = st[11];
  var DX = st[4];
  var R15 = st[0];
  var R9 = st[12];
  var SI = st[5];
  var R11 = st[8];
  R15 = (R15 + DX) & _m32;
  var R14 = st[1];
  var R8 = st[13];
  R9 = (R9 ^ R15) & _m32;
  var CX = st[6];
  var R13 = st[2];
  R9 = _roll(R9, 16);
  R14 = (R14 + SI) & _m32;
  var BX = st[9];
  var DI = st[14];
  R11 = (R11 + R9) & _m32;
  R8 = (R8 ^ R14) & _m32;
  R13 = (R13 + CX) & _m32;
  DX = (DX ^ R11) & _m32;
  R8 = _roll(R8, 16);
  DI = (DI ^ R13) & _m32;
  DX = _roll(DX, 12);
  BX = (BX + R8) & _m32;
  DI = _roll(DI, 16);
  R15 = (R15 + DX) & _m32;
  SI = (SI ^ BX) & _m32;
  R10 = (R10 + DI) & _m32;
  R9 = (R9 ^ R15) & _m32;
  SI = _roll(SI, 12);
  CX = (CX ^ R10) & _m32;
  R9 = _roll(R9, 8);
  R14 = (R14 + SI) & _m32;
  CX = _roll(CX, 12);
  R11 = (R11 + R9) & _m32;
  R8 = (R8 ^ R14) & _m32;
  R13 = (R13 + CX) & _m32;
  DX = (DX ^ R11) & _m32;
  R8 = _roll(R8, 8);
  DI = (DI ^ R13) & _m32;
  DX = _roll(DX, 7);
  BX = (BX + R8) & _m32;
  DI = _roll(DI, 8);
  final tmp0 = DX;
  DX = st[7];
  SI = (SI ^ BX) & _m32;
  final tmp1 = BX;
  BX = R10;
  R10 = st[15];
  SI = _roll(SI, 7);
  BX = (BX + DI) & _m32;
  R12 = (R12 + DX) & _m32;
  R15 = (R15 + SI) & _m32;
  R10 = (R10 ^ R12) & _m32;
  CX = (CX ^ BX) & _m32;
  R10 = _roll(R10, 16);
  CX = _roll(CX, 7);
  BP = (BP + R10) & _m32;
  R14 = (R14 + CX) & _m32;
  DX = (DX ^ BP) & _m32;
  R9 = (R9 ^ R14) & _m32;
  DX = _roll(DX, 12);
  R9 = _roll(R9, 16);
  R12 = (R12 + DX) & _m32;
  R10 = (R10 ^ R12) & _m32;
  R10 = _roll(R10, 8);
  BP = (BP + R10) & _m32;
  R10 = (R10 ^ R15) & _m32;
  R10 = _roll(R10, 16);
  DX = (DX ^ BP) & _m32;
  BP = (BP + R9) & _m32;
  BX = (BX + R10) & _m32;
  DX = _roll(DX, 7);
  CX = (CX ^ BP) & _m32;
  SI = (SI ^ BX) & _m32;
  SI = _roll(SI, 12);
  R15 = (R15 + SI) & _m32;
  R10 = (R10 ^ R15) & _m32;
  st[0] = R15;
  R10 = _roll(R10, 8);
  BX = (BX + R10) & _m32;
  st[15] = R10;
  SI = (SI ^ BX) & _m32;
  final X1 = BX;
  SI = _roll(SI, 7);
  CX = _roll(CX, 12);
  R13 = (R13 + DX) & _m32;
  R8 = (R8 ^ R13) & _m32;
  R14 = (R14 + CX) & _m32;
  st[5] = SI;
  R8 = _roll(R8, 16);
  R9 = (R9 ^ R14) & _m32;
  st[1] = R14;
  R11 = (R11 + R8) & _m32;
  R9 = _roll(R9, 8);
  DX = (DX ^ R11) & _m32;
  BP = (BP + R9) & _m32;
  st[12] = R9;
  DX = _roll(DX, 12);
  CX = (CX ^ BP) & _m32;
  final X2 = BP;
  R13 = (R13 + DX) & _m32;
  CX = _roll(CX, 7);
  R8 = (R8 ^ R13) & _m32;
  st[6] = CX;
  R8 = _roll(R8, 8);
  st[2] = R13;
  R11 = (R11 + R8) & _m32;
  DX = (DX ^ R11) & _m32;
  final X0 = R11;
  DX = _roll(DX, 7);
  st[7] = DX;
  st[13] = R8;
  SI = tmp0;
  CX = tmp1;
  R12 = (R12 + SI) & _m32;
  DI = (DI ^ R12) & _m32;
  DI = _roll(DI, 16);
  CX = (CX + DI) & _m32;
  SI = (SI ^ CX) & _m32;
  DX = SI;
  DX = _roll(DX, 12);
  R12 = (R12 + DX) & _m32;
  DI = (DI ^ R12) & _m32;
  st[3] = R12;
  DI = _roll(DI, 8);
  CX = (CX + DI) & _m32;
  st[14] = DI;
  final X3 = CX;
  DX = (DX ^ CX) & _m32;
  DX = _roll(DX, 7);
  st[4] = DX;
  st[8] = X0;
  st[9] = X3;
  st[10] = X1;
  st[11] = X2;
}

// ───────────────────────────────────────────────────────────────────────────
// 位/字节置换原语（sub_* 系列）
// ───────────────────────────────────────────────────────────────────────────

/// `toBytes(a)`（**小端**）：把 4 个 u32 摊成 16 字节。
///
/// 参考实现是 `a.forEach`，`a` 恒为 4 元素切片，所以这里用 `off` 定位
/// 而不真的切片（省一次分配）。
void _toBytes(Uint32List a, int off, Uint8List out16) {
  for (var i = 0; i < 4; i++) {
    final v = a[off + i];
    out16[4 * i] = v & 0xFF;
    out16[4 * i + 1] = (v >> 8) & 0xFF;
    out16[4 * i + 2] = (v >> 16) & 0xFF;
    out16[4 * i + 3] = (v >> 24) & 0xFF;
  }
}

/// `sub_a(a, b)`：固定字节序异或。
void _subA(Uint8List a, Uint32List b, int off) {
  final byteB = Uint8List(16);
  _toBytes(b, off, byteB);
  const seq = [3, 2, 1, 0, 7, 6, 5, 4, 11, 10, 9, 8, 15, 14, 13, 12];
  for (var i = 0; i < 16; i++) {
    a[i] = a[i] ^ byteB[seq[i]];
  }
}

/// `sub_b(a, b)`：另一种字节序异或。
void _subB(Uint8List a, Uint32List b, int off) {
  final byteB = Uint8List(16);
  _toBytes(b, off, byteB);
  const seq = [3, 6, 9, 12, 7, 10, 13, 0, 11, 14, 1, 4, 15, 2, 5, 8];
  for (var i = 0; i < 16; i++) {
    a[i] = a[i] ^ byteB[seq[i]];
  }
}

/// `sub_c(tableB, p)`：查 AES S-box 做字节替换。
///
/// 原式 `a[Math.floor(t / 16)][t % 16]` 在行优先摊平后正好是 `a_flat[t]`，
/// 因为 `(t >> 4) * 16 + (t & 15) == t`。
void _subC(Uint8List b) {
  for (var i = 0; i < 16; i++) {
    var t = b[i] & 0xFF;
    t = ((t & 15) + ((t >> 4) << 4)) & 0xFF; // 半字节互换
    b[i] = _aesSbox[t];
  }
}

/// `sub_d(table, b)`：对 16 字节做一次置换（b[i] = old[table[i]]）。
void _subD(Uint8List b, List<int> table) {
  final tb = Uint8List.fromList(b);
  for (var i = 0; i < table.length; i++) {
    b[i] = tb[table[i]];
  }
}

/// `sub_e(tableC, p)`：按 4 字节一组做 MixColumns（列 = gmul 2/3/9/11/13/14）。
///
/// 从 i=4 倒着做；每轮先把 4 个字节读进局部量再写回（原代码也是解构赋值，
/// 所以是「读完全部再写」，不是原地滚动）。
void _subE(Uint8List p) {
  for (var i = 4; i > 0; i--) {
    final a = p[4 * i - 4];
    final b = p[4 * i - 3];
    final c = p[4 * i - 2];
    final d = p[4 * i - 1];
    p[4 * i - 4] = (c ^ d) ^ (_gfMul[a][0] ^ _gfMul[b][1]);
    p[4 * i - 3] = (a ^ d) ^ (_gfMul[b][0] ^ _gfMul[c][1]);
    p[4 * i - 2] = (a ^ b) ^ (_gfMul[d][1] ^ _gfMul[c][0]);
    p[4 * i - 1] = (b ^ c) ^ (_gfMul[a][1] ^ _gfMul[d][0]);
  }
}

/// `sub_ab(tableB, b)`：u32 → 逐字节过 S-box 再重组（RotWord+SubWord 的核心）。
///
/// 原式里的 4 个下标其实各自就是一个字节，这里保留原表达式形态：
/// `((b>>>28)<<4)+((b>>>24)&15)` 是 byte0，后面三个分别是 byte1/2/3。
int _subAb(int b, Uint8List sbox) {
  b &= _m32;
  final ia = (((b >> 28) << 4) + ((b >> 24) & 15)) & 0xFF;
  final ax = sbox[ia];
  final ib = b & 0xFF;
  final bx = sbox[ib];
  final ic = (((b >> 8) & 15) + ((b >> 8) & 240)) & 0xFF;
  final cx = sbox[ic];
  final id = (((b >> 16) & 15) + ((b >> 16) & 240)) & 0xFF;
  final dx = sbox[id];
  return ((ax << 24) | bx | (cx << 8) | (dx << 16)) & _m32;
}

/// `sub_f(tableE, tableF, tableB)`：AES-128 key schedule，产出 44 个 u32。
///
/// `tableE` 是初始 128 位密钥，`tableF` 是每 4 轮异或的轮常量。
Uint32List _subF(List<int> a, List<int> b, Uint8List sbox) {
  final w = Uint32List(44);
  for (var k = 0; k < 4; k++) {
    w[k] = ((a[4 * k] << 24) |
            (a[4 * k + 1] << 16) |
            (a[4 * k + 2] << 8) |
            a[4 * k + 3]) &
        _m32;
  }
  for (var bx = 4; bx < 44; bx++) {
    var ax = w[bx - 1];
    if (bx % 4 == 0) {
      // 循环左移 8 位（RotWord），再 SubWord，再异或轮常量
      ax = ((ax << 8) | (ax >> 24)) & _m32;
      ax = _subAb(ax, sbox);
      final dx = (bx - 1) >> 2; // (bx-1) >>> 2，bx%4==0 时即 bx/4 - 1
      ax = (ax ^ b[dx]) & _m32;
    }
    ax = (ax ^ w[bx - 4]) & _m32;
    w[bx] = ax;
  }
  return w;
}

/// `sub_aa(i, tableA, buf, m)`：按 i 从 `tableA` 里取两个半字节拼成一个字节。
///
/// `ax`/`dx` 都是「cnt/高半字节」拼出来的 9 位下标，所以四层下标的位分解
/// 可以直接写成 `[>>9][(>>8)&1][(>>4)&15][&15]`。
int _subAa(int a, Uint8List buf, Uint8List m) {
  final di = ((buf[a & 15] >> 4) & 15);
  final ax = (((m[a] >> 4) & 15) << 4) + ((a & 15) << 9) + di;
  var res = _tableAAt(ax >> 9, (ax >> 8) & 1, (ax >> 4) & 15, ax & 15);
  res = (res << 4) & 0xFF;
  final dx = ((a & 15) << 9) + ((m[a] & 15) << 4) + (buf[a & 15] & 15) + 256;
  res =
      (res | _tableAAt(dx >> 9, (dx >> 8) & 1, (dx >> 4) & 15, dx & 15)) & 0xFF;
  return res;
}

/// `transformInner(a, b)`：**就地**把 21 字节用 ts 表（encode/decode）重编码。
///
/// `cnt` 走 1,3,5,…,41 共 21 次，每次吃掉一个字节。
void _transformInner(Uint8List a, List<List<int>> b) {
  var si = 0;
  for (var cnt = 1; cnt < 43;) {
    final ai = (((cnt - 1) & 31) << 4) + (a[si] >> 4);
    final bi = ((cnt & 31) << 4) + (a[si] & 15);
    a[si] = ((b[ai >> 4][ai & 15] << 4) | b[bi >> 4][bi & 15]) & 0xFF;
    si++;
    cnt += 2;
  }
}

/// `tencentCrc32(tab, b)`：查表 CRC32（反射多项式，初值/末值全 1）。
///
/// JS 里 `crc = 0; crc = ~crc` 得到 i32 的 -1，其 u32 位型即 `0xffffffff`，
/// 所以 Dart 侧直接从 `_m32` 起步；末尾 `(~crc) >>> 0` 等价于 `crc ^ _m32`。
///
/// `start` 代替参考实现的 `crcData.slice(2)`（避免一次拷贝）。
int _tencentCrc32(List<int> tab, Uint8List b, int start) {
  var crc = _m32;
  for (var i = start; i < b.length; i++) {
    crc = (tab[(crc & 0xFF) ^ b[i]] ^ (crc >> 8)) & _m32;
  }
  return crc ^ _m32;
}

// ───────────────────────────────────────────────────────────────────────────
// 两段对称加密原语
// ───────────────────────────────────────────────────────────────────────────

/// `_tencentEncryptB(p1, p2)`：9 轮 AES 轮函数 + 最后一轮。
void _tencentEncryptBRounds(Uint8List p1, Uint32List p2) {
  const c = 10;
  for (var r = 0; r < 9; r++) {
    _subD(p1, qq8T544TableD);
    _subB(p1, p2, r * 4);
    _subC(p1);
    _subE(p1);
  }
  _subD(p1, qq8T544TableD);
  _subB(p1, p2, (c - 1) * 4);
  _subC(p1);
  _subA(p1, p2, c * 4);
}

/// `tencentEncryptB(c, m)`：产出 21 字节。
///
/// 每 16 个输出字节用一个新的 `buf`（由 `c` 拷来并做 AES 轮变换），
/// 且在每次刷新前把 `c` 当作**大端 128 位数 +1**。
///
/// 参考实现传给这里的 `c` 是 `kt.slice(0, 16)`——Node 里 `Buffer.slice`
/// 是**共享内存的视图**，所以那个 `+1` 会写回 `kt[0..16)`。但 `sign()` 随后
/// 会把 `kt[0..38]` 全部重写，故此处传独立副本（[kt] 的 sublist）等价。
Uint8List _tencentEncryptB(Uint8List c, Uint8List m) {
  final buf = Uint8List(16);
  final w = _subF(qq8T544TableE, qq8T544TableF, _aesSbox);
  final out = Uint8List(21);
  for (var i = 0; i < 21; i++) {
    if ((i & 0xF) == 0) {
      buf.setAll(0, c);
      _tencentEncryptBRounds(buf, w);
      // 大端 +1（进位从最低位字节 j=15 往 14… 走）
      for (var j = 15; j >= 0; j--) {
        c[j]++; // Uint8List 赋值自带 & 0xff
        if (c[j] != 0) {
          break;
        }
      }
    }
    out[i] = _subAa(i, buf, m);
  }
  return out;
}

/// `tencentEncryptionA(input, key, data)`：ChaCha 家族流密码，**就地**加密 input。
void _tencentEncryptionA(Uint8List input, Uint8List key, Uint8List data) {
  final s = _ChaChaState(Uint32List(16), Uint32List(16), 0, 0);
  s.init(key, data, Uint32List.fromList([0, 0]), 20);
  s.encrypt(input);
}

// ───────────────────────────────────────────────────────────────────────────
// 顶层 API
// ───────────────────────────────────────────────────────────────────────────

/// oicq `sign(curr, input)`：返回 39 字节的 TLV 0x544 签名。
///
/// [curr] 是毫秒时间戳（参考实现对 1e6 取余）；[input] 是 salt 字节
/// （长度 22 或 42，取决于布局假设）。
/// [entropy] 为空时四处随机源走 [Random.secure]；传入即完全确定。
Uint8List qq8T544Sign(int curr, Uint8List input, {Qq8T544Entropy? entropy}) {
  final rnd = Random.secure();
  final kPicks = entropy?.keyTablePicks;
  final tPicks = entropy?.table2Picks;
  final addPin = entropy?.addition;
  if (kPicks != null) {
    assert(kPicks.length >= 2, 'keyTablePicks 需要 2 个元素');
    assert(kPicks[0] >= 0 && kPicks[0] < 50, 'keyTablePicks[0] 应在 0..49');
    assert(kPicks[1] >= 0 && kPicks[1] < 50, 'keyTablePicks[1] 应在 0..49');
  }
  if (tPicks != null) {
    assert(tPicks.length >= 2, 'table2Picks 需要 2 个元素');
    assert(tPicks[0] >= 0 && tPicks[0] < 50, 'table2Picks[0] 应在 0..49');
    assert(tPicks[1] >= 0 && tPicks[1] < 50, 'table2Picks[1] 应在 0..49');
  }
  if (addPin != null) {
    assert(addPin >= 1 && addPin <= 8 && addPin.isOdd,
        'addition 必须是 1..8 的奇数');
  }

  // JS: `curr = curr % 1000000`。JS 的 `%` 符号随被除数，
  // Dart 的 `remainder()` 与之逐位等价（`%` 在负数上不同）。
  final cur = curr.remainder(1000000);

  final crcData = Uint8List(21);
  _writeU32BE(crcData, 0, cur & _m32);
  // JS: `input = Buffer.concat([input, crcData.slice(0, 4)])`（新缓冲区，
  // 不会改到调用方的 input）
  final buf = Uint8List(input.length + 4)
    ..setRange(0, input.length, input)
    ..setRange(input.length, input.length + 4, crcData);

  final kt = Uint8List(40);
  // 参考实现：`kt[i] = keyTable[floor(random()*50)].charCodeAt(0) + 50`
  kt[0] = qq8T544KeyTable.codeUnitAt(kPicks != null ? kPicks[0] : rnd.nextInt(50)) + 50;
  kt[1] = qq8T544KeyTable.codeUnitAt(kPicks != null ? kPicks[1] : rnd.nextInt(50)) + 50;
  kt[2] = kt[1] + 20;
  kt[3] = kt[2] + 20;
  kt.setRange(6, 10, qq8T544Key1); // key1.copy(kt, 6, 0, 4)：只取前 4 字节
  for (var i = 0; i < 4; i++) {
    kt[10 + i] = qq8T544Key2[i] ^ kt[i];
  }
  kt[4] = kt[12]; // 此时 kt[12] == 0
  kt[5] = kt[13]; // 此时 kt[13] == 0
  kt[12] = 0;
  kt[13] = 0;
  // JS: `let key = kt.slice(4, 12)`（视图）；下面 RC4 用它加密它自己，
  // 原代码也是 `cipher.update(key)`，所以两个参数同一份内容。
  final key = Uint8List.fromList(kt.sublist(4, 12));
  kt.setRange(4, 12, qq8T544Rc4(key, key));

  // `writeBigUint64LE(BigInt(0x6EEDCF0DC4675540n), 4)`
  _writeU64LE(crcData, 4, 0x6EEDCF0DC4675540);
  // 这一步会**就地**把 buf（= salt + curr_be4）异或加密，
  // 因此随后的 MD5 是对**加密后**的 buf 求的（参考实现同样如此）。
  _tencentEncryptionA(
    buf,
    Uint8List.fromList(kt.sublist(4, 36)),
    Uint8List.fromList(crcData.sublist(4, 12)),
  );
  final md5 = md5Bytes(buf);

  crcData[2] = 1;
  crcData[4] = 1;
  crcData.setRange(5, 9, kt.sublist(0, 4)); // kt.copy(crcData, 5, 0, 4)
  _writeU32BE(crcData, 9, cur & _m32);
  crcData.setRange(13, 21, md5.sublist(0, 8));
  final calcCrc = _tencentCrc32(qq8T544CrcTab, crcData, 2);
  _writeU32LE(kt, 36, calcCrc);
  crcData[0] = kt[36];
  crcData[1] = kt[39];

  // nonce：`crypto.randomBytes(4).readUInt32BE(0)`
  final nonce = entropy?.nonce ?? rnd.nextInt(0x100000000);
  _writeU32BE(kt, 0, nonce);
  kt.setRange(4, 8, kt.sublist(0, 4));
  kt.setRange(8, 16, kt.sublist(0, 8));
  _transformInner(crcData, qq8T544TsEncode);
  final encrypted = _tencentEncryptB(Uint8List.fromList(kt.sublist(0, 16)), crcData);
  _transformInner(encrypted, qq8T544TsDecode);

  kt[0] = 0x0C;
  kt[1] = 0x05;
  _writeU32BE(kt, 2, nonce);
  kt.setRange(6, 27, encrypted); // encrypted.copy(kt, 6)
  _writeU32LE(kt, 27, 0);
  kt[31] = qq8T544Table2.codeUnitAt(tPicks != null ? tPicks[0] : rnd.nextInt(50));
  kt[32] = qq8T544Table2.codeUnitAt(tPicks != null ? tPicks[1] : rnd.nextInt(50));
  // 参考实现抽 `floor(random()*9)` 后重抽到奇数，等价于在 {1,3,5,7} 上均匀取。
  final addition = addPin ?? (1 + 2 * rnd.nextInt(4));
  kt[33] = (kt[31] + addition) & 0xFF;
  kt[34] = (kt[32] + ((9 - addition) & 0xFF) + 1) & 0xFF;
  _writeU32LE(kt, 35, 0);

  return Uint8List.fromList(kt.sublist(0, 39));
}
