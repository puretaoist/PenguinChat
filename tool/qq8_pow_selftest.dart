/// 防刷计算题（`0x546` → `0x547`）离线自测
///
/// 用**真机抓到的样本**（`vectors/pow-0x546-real.hex`，2026-09-12 09:43 那条
/// `type=2` 响应里的 346 字节）验证：解析字段 → 求解 → 组装应答结构 → 自校验。
///
/// 运行：
/// ```bash
/// dart run tool/qq8_pow_selftest.dart
/// ```
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'package:qqclient/kernel/wlogin8/qq8_pow.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✓ $name${detail == null ? '' : '   ($detail)'}');
  } else {
    _fail++;
    stdout.writeln('  ✗ $name${detail == null ? '' : '  ($detail)'}');
  }
}

void section(String t) => stdout.writeln('\n$t');

Uint8List _hex(String s) {
  final clean = s.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hexOf(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

Uint8List _sha256(Uint8List d) => SHA256Digest().process(d);

/// 大端 +1（就地），用于独立复算"dst = src 递增了多少次"。
void _incr(Uint8List v) {
  for (var i = v.length - 1; i >= 0; i--) {
    if (v[i] == 0xFF) {
      v[i] = 0;
    } else {
      v[i]++;
      return;
    }
  }
}

/// 官方 alg1 的判定（**独立重写**，用来交叉验证实现）：
/// 全局位号 255, 254, … 往下数 bits 位，全为 0 才算解出。
/// 官方出处：`ClientPow.b()` 里 `i22 = 255; … bArr4[i22/8] & (1 << (i22%8))`。
bool _lowBitsZero(Uint8List digest, int bits) {
  for (var k = 0; k < bits; k++) {
    final i = digest.length * 8 - 1 - k;
    if (i < 0) return false;
    if ((digest[i ~/ 8] & (1 << (i % 8))) != 0) return false;
  }
  return true;
}

/// 旧实现的错位序（最低位起数）——只用于**演示 e>8 时两者不同**，不参与判定。
bool _lowBitsFirst(Uint8List digest, int bits) {
  for (var i = 0; i < bits; i++) {
    final byteIndex = digest.length - 1 - (i ~/ 8);
    if (byteIndex < 0) return false;
    if ((digest[byteIndex] & (1 << (i % 8))) != 0) return false;
  }
  return true;
}

void main() {
  stdout.writeln('QQ 防刷计算题（0x546 → 0x547）离线自测');
  stdout.writeln('=' * 62);

  final real = _hex(File('vectors/pow-0x546-real.hex').readAsStringSync());
  final fixedStart = DateTime(2026, 9, 12, 9, 43, 0);
  // 每次求解都要一只**新**时钟（求解内部只取两次：开始与结束）
  DateTime Function() mkClock() {
    var calls = 0;
    return () {
      calls++;
      return calls <= 1 ? fixedStart : fixedStart.add(const Duration(milliseconds: 7));
    };
  }

  section('1. 真实样本的字段解析');
  final ch = parseQq8Pow(real);
  check('总长 346 字节', real.length == 346, '${real.length}');
  check('a=1 typ=2 c=1 ok=2 e=1 f=0',
      ch.a == 1 && ch.typ == 2 && ch.c == 1 && ch.ok == 2 && ch.e == 1 && ch.f == 0,
      'a=${ch.a} typ=${ch.typ} c=${ch.c} ok=${ch.ok} e=${ch.e} f=${ch.f}');
  check('src=128B / tgt=32B / cpy=172B',
      ch.src.length == 128 && ch.tgt.length == 32 && ch.cpy.length == 172,
      '${ch.src.length}/${ch.tgt.length}/${ch.cpy.length}');
  check('cpy = 前 8 字节字段 + tlv(src) + tlv(tgt)（无 dst）',
      ch.cpy.length == 8 + 2 + ch.src.length + 2 + ch.tgt.length &&
          _hexOf(ch.cpy.sublist(0, 8)) == _hexOf(real.sublist(0, 8)) &&
          _hexOf(ch.cpy.sublist(10, 10 + 128)) == _hexOf(ch.src),
      'cpy[0..8]=${_hexOf(ch.cpy.sublist(0, 8))}');

  section('2. 求解：官方语义（typ=1 e 位零 / typ=2 预像搜索）');
  {
    // 真机样本是 typ=2：官方要求 hash 逐字节等于 tgt。tgt 是服务端挑的
    // sha256(src + k)（k 很小），客户端从 src 起逐 1 递增就能撞上——
    // 本样本在第 9046 次（黄金值，python 与 dart 两条路径都验过）。
    final ansTyp2 = qq8SolvePow(real, clock: mkClock());
    check('真样本 typ=2：解出（预像搜索，不是"不可解"）', ansTyp2 != null);
    if (ansTyp2 != null) {
      check('迭代数 = 9046（本样本实测黄金值）', ansTyp2.iterations == 9046,
          '${ansTyp2.iterations}');
      check('用时按注入时钟 = 7ms', ansTyp2.elapsedMs == 7, '${ansTyp2.elapsedMs}ms');
      check('自校验：sha256(dst) 逐字节 == tgt',
          _hexOf(_sha256(ansTyp2.dst)) == _hexOf(ch.tgt), '');
      final expect = Uint8List.fromList(ch.src);
      for (var i = 0; i < 9046; i++) {
        _incr(expect);
      }
      check('dst == src 逐 1 递增 9046 次',
          _hexOf(ansTyp2.dst) == _hexOf(expect), '');
    }
    check('上限 500（< 9046）→ null（有界，不编造）',
        qq8SolvePow(real, maxIterations: 500) == null);

    // 位序差异（这次修正的正是这里）：byte30 = 0x80 的 digest 在 e=9 时
    // 官方数法（255 往下）看到的是 bit247=1 → 不满足；旧实现的"最低位起"
    // 数法只看 byte31 的 8 位 → 误判为满足。
    final syn = Uint8List(32)..[30] = 0x80;
    check('位序对照：e=9 时官方判不满足、旧数法判满足（两者不是同一批位）',
        !_lowBitsZero(syn, 9) && _lowBitsFirst(syn, 9));

    // 自造 typ=1（e=8）挑战：验证搜索与判定
    final typ1 = Uint8List.fromList(real);
    typ1[1] = 1;
    typ1[4] = 0;
    typ1[5] = 8;
    final ans = qq8SolvePow(typ1, clock: mkClock());
    check('typ=1：能解出（不是 null）', ans != null);
    if (ans != null) {
      check('迭代数在 2^8 量级内（难度 8 位）', ans.iterations < 100000,
          '${ans.iterations} 次');
      check('用时按注入时钟 = 7ms', ans.elapsedMs == 7, '${ans.elapsedMs}ms');
      check('dst 与 src 等长（128B）', ans.dst.length == 128, '${ans.dst.length}');
      check('自校验：sha256(dst) 满足官方 e=8 位零',
          _lowBitsZero(_sha256(ans.dst), 8),
          'sha256[24..32)=${_hexOf(_sha256(ans.dst).sublist(24))}');
      final first = Uint8List.fromList(ch.src);
      check('起点确实从 src 开始（不是凭空造的）',
          _lowBitsZero(_sha256(first), 8)
              ? ans.iterations == 0
              : ans.iterations > 0,
          'src 本身是否已满足：${_lowBitsZero(_sha256(first), 8)}');

      // 跨字节难度（e=12）：位序一旦错就解不出/验不过，专门盯这次修正
      final typ1e12 = Uint8List.fromList(typ1)..[5] = 12;
      final ans12 = qq8SolvePow(typ1e12);
      check('e=12（跨字节）：解出且满足官方位序',
          ans12 != null && _lowBitsZero(_sha256(ans12.dst), 12),
          '${ans12?.iterations} 次');

      final typ1e0 = Uint8List.fromList(typ1)..[5] = 0;
      final ans0 = qq8SolvePow(typ1e0);
      check('e=0：0 次迭代即解出（官方同款）',
          ans0 != null && ans0.iterations == 0, '${ans0?.iterations}');
    }

    final typ3 = Uint8List.fromList(real)..[1] = 3;
    check('typ=3（未知算法）→ null，不猜', qq8SolvePow(typ3) == null);
    final sm3 = Uint8List.fromList(typ1)..[2] = 2;
    check('c=2（SM3，官方明说不支持）→ null', qq8SolvePow(sm3) == null);
  }

  section('3. 应答结构（0x547 body）');
  {
    final typ1 = Uint8List.fromList(real);
    typ1[1] = 1;
    typ1[4] = 0;
    typ1[5] = 8;
    final ans = qq8SolvePow(typ1, clock: mkClock());
    check('测试前提：typ=1 可解出', ans != null);
    if (ans != null) {
      final b = ans.body;
      final expectLen = 8 + (2 + 128) + (2 + 32) + (2 + 172) + (2 + 128) + 4 + 4;
      check('总长 = 8 + 3 个回填 TLV + dst + 用时 + 迭代数 = $expectLen',
          b.length == expectLen, '${b.length}');
      check('前 6 字段回填、ok 写 1',
          b[0] == ch.a && b[1] == 1 && b[2] == ch.c && b[3] == 1 &&
              ((b[4] << 8) | b[5]) == 8 && ((b[6] << 8) | b[7]) == ch.f,
          _hexOf(b.sublist(0, 8)));
      var p = 8;
      final echoed = <Uint8List>[];
      for (var i = 0; i < 3; i++) {
        final len = (b[p] << 8) | b[p + 1];
        p += 2;
        echoed.add(b.sublist(p, p + len));
        p += len;
      }
      check('src/tgt/cpy 原样包回',
          _hexOf(echoed[0]) == _hexOf(ch.src) &&
              _hexOf(echoed[1]) == _hexOf(ch.tgt) &&
              _hexOf(echoed[2]) == _hexOf(ch.cpy), '');
      final dstLen = (b[p] << 8) | b[p + 1];
      p += 2;
      check('dst 段 128B 且等于解出的值',
          dstLen == 128 && _hexOf(b.sublist(p, p + 128)) == _hexOf(ans.dst), '');
      p += 128;
      final elp = (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
      p += 4;
      final cnt = (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
      check('尾部用时/迭代数与结果一致',
          elp == ans.elapsedMs && cnt == ans.iterations, 'elp=$elp cnt=$cnt');
    }
  }

  section('4. 边界与不猜');
  {
    // e=0 ⇒ 官方判"恒成立"（0 位要求）：0 次迭代即解出（已在第 2 节断言过）。
    // 这里补"难度拉满"与"畸形输入"两类：
    final hard = Uint8List.fromList(real);
    hard[1] = 1;
    hard[4] = 0;
    hard[5] = 32;
    check('e=32 且上限 200 → null（有界，不死等）',
        qq8SolvePow(hard, maxIterations: 200) == null);

    final badType = Uint8List.fromList(real)..[1] = 3;
    check('typ=3（未知题型）→ 返回 null，不猜', qq8SolvePow(badType) == null);

    // tgt 的长度前缀在 [138,139]（8 字段 + 2 src 长度 + 128 src + 2）
    // 改小之后 cpy 段会越界 → 解析期就抛（畸形输入不允许静默通过）
    final badTgt = Uint8List.fromList(real);
    badTgt[139] = 31;
    var badThrew = false;
    try {
      qq8SolvePow(badTgt);
    } on FormatException {
      badThrew = true;
    }
    check('tgt 长度被改坏 → 抛 FormatException（不静默通过）', badThrew);

    var threw = false;
    try {
      parseQq8Pow(Uint8List.fromList(real.sublist(0, 8)));
    } on FormatException {
      threw = true;
    }
    check('字段越界抛 FormatException', threw);
  }

  section('5. 客户端自构造防刷块（0x548，维护版 oicq 路径）');
  {
    // 固定随机种子：src 确定 → dst/tgt/应答全部可复现。
    final rng = Random(20260913);
    Uint8List fixedRandom(int n) {
      final b = Uint8List(n);
      for (var i = 0; i < n; i++) {
        b[i] = rng.nextInt(256);
      }
      return b;
    }

    final ans = qq8BuildClientPow548(randomBytes: fixedRandom, clock: mkClock());
    final b = ans.body;
    // 与 0x547 应答同构：8 头 + src130 + tgt34 + cpy174 + dst130 + 8 尾 = 484。
    check('body 与 0x547 应答同构（484 字节）', b.length == 484, '${b.length}');
    check('头部 a=1 typ=2 c=1 ok=1 maxIndex=10 reserve=0',
        b[0] == 1 && b[1] == 2 && b[2] == 1 && b[3] == 1 &&
            ((b[4] << 8) | b[5]) == 10 && b[6] == 0 && b[7] == 0,
        _hexOf(b.sublist(0, 8)));

    // 把应答再当挑战解析：src/tgt/cpy 三段齐全且尺寸正确。
    final parsed = parseQq8Pow(b);
    check('src=128B / tgt=32B / cpy=172B',
        parsed.src.length == 128 && parsed.tgt.length == 32 &&
            parsed.cpy.length == 172,
        '${parsed.src.length}/${parsed.tgt.length}/${parsed.cpy.length}');
    check('src 首字节不为 0/255（构造约束，防 128B 加法溢出）',
        parsed.src[0] != 0 && parsed.src[0] != 255, '0x${parsed.src[0].toRadixString(16)}');

    // 核心语义：tgt = sha256(src + 10000)，所以求解器恰在第 10000 次撞上。
    check('迭代数恰为 10000（dst = src + 10000 的构造）',
        ans.iterations == 10000, '${ans.iterations}');
    check('sha256(dst) 逐字节 == tgt（服务端复核依据）',
        _hexOf(_sha256(ans.dst)) == _hexOf(parsed.tgt));
    final expectDst = Uint8List.fromList(parsed.src);
    for (var i = 0; i < 10000; i++) {
      _incr(expectDst);
    }
    check('dst == src 大端递增 10000 次',
        _hexOf(ans.dst) == _hexOf(expectDst));

    // 两次构造随机不同（不产生固定指纹），但都能自洽解出。
    final another = qq8BuildClientPow548(clock: mkClock());
    check('两次构造的 src 不同（随机源生效，非常量指纹）',
        _hexOf(parseQq8Pow(another.body).src) != _hexOf(parsed.src));
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
