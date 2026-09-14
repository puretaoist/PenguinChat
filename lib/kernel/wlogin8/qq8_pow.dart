/// L2 协议内核：防刷计算题（TLV `0x546` → `0x547`）
///
/// ## 结构（用真实样本核对过，见 `vectors/pow-0x546-real.hex`）
///
/// 挑战 `0x546`（实测 346 字节）：
///
/// ```text
/// u8 a ‖ u8 typ ‖ u8 c ‖ u8 ok ‖ u16 e ‖ u16 f
///   ‖ tlv16 src（实测 128B） ‖ tlv16 tgt（实测 32B） ‖ tlv16 cpy（实测 172B）
/// ```
///
/// 应答 `0x547`（照参考实现 `base-client.ts` 的 `calcPoW` 组装）：
/// 前 6 个字段原样回填（`ok` 写 1），`src/tgt/cpy` 原样包回，再追加
/// `tlv16 dst ‖ u32 用时(ms) ‖ u32 迭代数`。
///
/// ## 算法（**以官方 Java 为准**，2026-09-12 修正）
///
/// 先前的实现是照参考实现 oicq 猜的（"`sha256(dst) ≤ tgt`"）——**那个推断是错的**。
/// 官方 8.9.50 的 `oicq/wlogin_sdk/pow/ClientPow.java`（Java 回退实现，native
/// 版在 `libpow.so`）写得很清楚：
///
/// ```java
/// // typ == 1（alg 1）：e = 难度位数
/// while (true) {
///     sha256(srcBytes, hash);
///     // 全局位号从 255 往下数 e 位（= 最后一字节的最高位起），全 0 才算解出
///     for (int i = 255, n = 0; n < e; i--, n++)
///         if ((hash[i / 8] & (1 << (i % 8))) != 0) { 不满足; }
/// }
/// // typ == 2（alg 2）：要求 hash **逐字节等于 tgt**
/// if (Arrays.equals(hash, tgt)) { 解出 }
/// ```
///
/// 也就是说：
/// * `typ == 1` → 难度 = **e 位零**（与 `tgt` 无关）；位序是
///   **从 `digest[31]` 的 0x80 往下走**（`i = 255, 254, …`），
///   不是"最低位起"——e ≤ 8 时两种数法覆盖同一字节，e > 8 时**检查的位不是同一批**，
///   服务端按官方位序校验，所以必须照抄（2026-09-12 修正）。
/// * `typ == 2` → **预像搜索**：服务端把 tgt 选成 `sha256(src + k)`（k 很小），
///   客户端从 src 起逐 1 递增就能撞上。真机样本（09:43 那条 346B 挑战）
///   **就是在第 9046 次迭代撞上的**（`tool/qq8_pow_selftest.dart` 拿它当黄金值）。
///   官方 native 也是同款循环，Java 路径一直转到撞上或缓冲溢出为止。
///
/// 官方的应答尾部与结构（`ClientPow.b()` 的 writer）与本文件一致：
/// `a ‖ typ ‖ c ‖ ok=1 ‖ u16 e ‖ f[0] ‖ f[1] ‖ tlv(src) ‖ tlv(tgt) ‖ tlv(cpy) ‖
///  tlv(dst) ‖ i32 用时(ms) ‖ i32 迭代数`；长度字段官方按**有符号 i16** 读，
///  实测样本的字段都远小于 32767，此处按无符号处理（越界即报错）。
///
/// 本文件是纯 Dart。
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../../infra/coder.dart';

/// 挑战字段（`0x546` 的 body）。
class Qq8PowChallenge {
  final int a;
  final int typ;
  final int c;

  /// 挑战里带的 ok 标志（实测为 2；应答里统一写 1）。
  final int ok;

  final int e;
  final int f;

  /// 搜索起点（实测 128 字节，按大端整数逐 1 递增）。
  final Uint8List src;

  /// 难度目标（实测 32 字节；判定条件 `sha256(dst) <= tgt`）。
  final Uint8List tgt;

  /// 服务端回显的旧应答结构（实测 172 字节），原样包回。
  final Uint8List cpy;

  const Qq8PowChallenge({
    required this.a,
    required this.typ,
    required this.c,
    required this.ok,
    required this.e,
    required this.f,
    required this.src,
    required this.tgt,
    required this.cpy,
  });
}

/// 解出的应答。
class Qq8PowAnswer {
  /// `0x547` 的 body（不含 tag/len 头）。
  final Uint8List body;

  /// 迭代次数（写进应答尾部，供服务端复核）。
  final int iterations;

  /// 用时（毫秒，写进应答尾部）。
  final int elapsedMs;

  /// 解出的 `dst`（与 `src` 等长的 256 位大端值）。
  final Uint8List dst;

  const Qq8PowAnswer({
    required this.body,
    required this.iterations,
    required this.elapsedMs,
    required this.dst,
  });
}

/// 解析挑战。字段不足或长度越界抛 [FormatException]。
Qq8PowChallenge parseQq8Pow(Uint8List blob) {
  if (blob.length < 12) {
    throw FormatException('0x546 太短（${blob.length} 字节）');
  }
  var p = 0;
  final a = blob[p++];
  final typ = blob[p++];
  final c = blob[p++];
  final ok = blob[p++];
  final e = (blob[p] << 8) | blob[p + 1];
  p += 2;
  final f = (blob[p] << 8) | blob[p + 1];
  p += 2;

  Uint8List take() {
    if (p + 2 > blob.length) {
      throw const FormatException('0x546 字段越界');
    }
    final len = (blob[p] << 8) | blob[p + 1];
    p += 2;
    if (p + len > blob.length) {
      throw const FormatException('0x546 字段长度越界');
    }
    final seg = Uint8List.fromList(blob.sublist(p, p + len));
    p += len;
    return seg;
  }

  return Qq8PowChallenge(
    a: a,
    typ: typ,
    c: c,
    ok: ok,
    e: e,
    f: f,
    src: take(),
    tgt: take(),
    cpy: take(),
  );
}

/// 求解并组装 `0x547`；题型不认识或超出迭代上限时返回 null（不猜、不死等）。
///
/// [clock] 只影响写进应答的"用时"，便于自测确定性。
Qq8PowAnswer? qq8SolvePow(
  Uint8List blob, {
  int maxIterations = 1 << 20,
  DateTime Function()? clock,
}) {
  final ch = parseQq8Pow(blob);
  if (ch.src.isEmpty || ch.tgt.isEmpty) return null;
  // c = 1 是 SHA-256；c = 2 是 SM3（官方日志明说 "hash func not support sm3"）——不猜
  if (ch.c != 1) return null;

  final now = clock ?? DateTime.now;
  final start = now();

  // 起点 = src 当大端整数（官方用 BigInteger；正负号差异不影响服务端校验，
  // 它只看解出来的 hash 是否满足条件），逐 1 递增。
  final counter = Uint8List.fromList(ch.src);
  var iterations = 0;
  var solved = false;
  while (true) {
    final digest = _sha256(counter);
    if (ch.typ == 1) {
      // 官方 alg1：最低 e 位全 0（e = 难度位数，与 tgt 无关）
      if (ch.e < 0 || ch.e > 32) return null; // 官方对 e>32 直接判"不满足"
      solved = _lowBitsZero(digest, ch.e);
    } else if (ch.typ == 2) {
      // 官方 alg2：hash 逐字节等于 tgt —— 预像问题，实际不可解
      solved = ch.tgt.length == 32 && _bytesEqual(digest, ch.tgt);
    } else {
      return null; // 未知算法，不猜
    }
    if (solved) break;
    if (iterations >= maxIterations) return null; // 有界：解不出就说不出口
    _increment(counter);
    iterations++;
  }

  final elapsedMs = now().difference(start).inMilliseconds;
  final body = (ByteWriter()
        ..u8(ch.a)
        ..u8(ch.typ)
        ..u8(ch.c)
        ..u8(1) // ok：解出来就是 1（官方写完把 d 置 1）
        ..u16(ch.e)
        ..u16(ch.f)
        ..bytes16(ch.src)
        ..bytes16(ch.tgt)
        ..bytes16(ch.cpy)
        ..bytes16(counter)
        ..u32(elapsedMs)
        ..u32(iterations))
      .build();
  return Qq8PowAnswer(
    body: body,
    iterations: iterations,
    elapsedMs: elapsedMs,
    dst: counter,
  );
}

/// 构造客户端自有的防刷块 **TLV `0x548`** 的 body。
///
/// ## 这不是服务端下发的 0x546 应答
///
/// 维护版 oicq（`oicq-icalingua-plus-plus` v1.26.25，2026-09 仍在更新）
/// 的密码登录包在 `0x545` 之后**无条件**带 `0x548`（`lib/wtlogin/tlv.js`
/// 的 `0x548` 打包函数）。它由客户端自己造一个**与 0x546 同构**的挑战、
/// 再用同一个 `calcPoW` 解出：
///
/// ```js
/// src = 随机 128 字节（首字节不为 0/255，保证 128B 不溢出）
/// dst = src 当大端整数 + 10000（固定 128 字节）
/// tgt = sha256(dst)
/// inner = u8(1,2,1,2) u16(10) u8(0,0) tlv(src) tlv(tgt)
/// 挑战体 = inner ‖ tlv(inner)   // 解析器读 src/tgt 后，cpy 正好取到尾部
/// 0x548 body = calcPoW(挑战体)
/// ```
///
/// 因为 `tgt = sha256(src+10000)`，求解器从 src 起逐 1 递增，**恰好在
/// 10000 次迭代撞上**（维护版同名字段 `cnt = 10000`）。结构与真实 0x546
/// 完全一致（`a typ c ok ‖ maxIndex ‖ reserve ‖ tlv(src) ‖ tlv(tgt) ‖ tlv(cpy)`），
/// 所以直接复用 [qq8SolvePow]。
///
/// 返回的 [Qq8PowAnswer.body] 就是 `0x548` 的 TLV body（不含 tag/len）。
Qq8PowAnswer qq8BuildClientPow548({
  Uint8List Function(int n)? randomBytes,
  DateTime Function()? clock,
  int maxIterations = 1 << 20,
}) {
  final rng = randomBytes ?? _defaultRandomBytes;
  Uint8List src;
  do {
    src = rng(128);
  } while (src[0] == 0 || src[0] == 0xFF);

  final dst = _bigIntToBytes(_bytesToBigInt(src) + BigInt.from(10000), 128);
  final tgt = _sha256(dst);

  final inner = (ByteWriter()
        ..u8(1)
        ..u8(2)
        ..u8(1)
        // 构造时 ok 写 2（≠0 表示未解出）；calcPoW 解完会重写成 1。
        ..u8(2)
        ..u16(10) // maxIndex
        ..u8(0)
        ..u8(0) // reserve
        ..bytes16(src)
        ..bytes16(tgt))
      .build();

  // raw(inner) 提供头部+src+tgt，尾部 tlv(inner) 作为解析器读回的 cpy。
  final challenge = (ByteWriter()
        ..raw(inner)
        ..bytes16(inner))
      .build();

  final answer =
      qq8SolvePow(challenge, clock: clock, maxIterations: maxIterations);
  if (answer == null) {
    throw StateError('0x548 自构造 PoW 解不出（题型固定为 typ=2，不应发生）');
  }
  return answer;
}

// ---------------------------------------------------------------------------
// 内部
// ---------------------------------------------------------------------------

/// 128 字节随机源（PoW 自构造块用；与设备随机无关，不参与设备身份）。
Uint8List _defaultRandomBytes(int n) {
  final b = Uint8List(n);
  final r = Random.secure();
  for (var i = 0; i < n; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

BigInt _bytesToBigInt(Uint8List b) {
  var v = BigInt.zero;
  for (final x in b) {
    v = (v << 8) | BigInt.from(x);
  }
  return v;
}

Uint8List _bigIntToBytes(BigInt v, int len) {
  final out = Uint8List(len);
  var x = v;
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xFF)).toInt();
    x >>= 8;
  }
  return out;
}

/// `digest` 是否满足官方 `ClientPow` alg1 的"e 位零"判定。
///
/// 位序照抄官方：全局位号 `i` 从 255 往下走（= `digest[31]` 的 0x80 起），
/// 逐位要求为 0。**不是**从最低位起数——e > 8 时两者检查的位不同。
bool _lowBitsZero(Uint8List digest, int bits) {
  final top = digest.length * 8 - 1;
  for (var k = 0; k < bits; k++) {
    final i = top - k;
    if (i < 0) return false;
    if ((digest[i ~/ 8] & (1 << (i % 8))) != 0) return false;
  }
  return true;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _sha256(Uint8List data) {
  final d = SHA256Digest();
  return d.process(data);
}

/// 大端整数 +1（就地）。
void _increment(Uint8List v) {
  for (var i = v.length - 1; i >= 0; i--) {
    if (v[i] == 0xFF) {
      v[i] = 0;
    } else {
      v[i]++;
      return;
    }
  }
}
