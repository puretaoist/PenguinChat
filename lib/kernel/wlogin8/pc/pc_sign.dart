/// PC NTLogin 的 `sec_sign` 纯 Dart 实现（移植自 NTQQ-PureSignServer 的 sign.js）。
///
/// sign.js 把算法混淆成「一个字节码 VM + 两段 blob（blob27/blob41）」。这里用 Dart
/// 原样移植该 VM（`_Vm.step` 全指令集）+ chacha/crc32/md5，BigInt 用 Dart 原生。
/// blob 由调用方传入（从 assets 读）；常量见 `pc_sign_consts.dart`（脚本提取，勿手改）。
///
/// 验证依据：与 Node 跑 `computeSign53644` 的输出逐字节对比（见 tool/pc_sign_selftest.dart）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/md5.dart';

import 'pc_sign_blobs.dart';
import 'pc_sign_consts.dart';

/// 结果：sec_sign / sec_extra（均为 hex）。
class PcSignResult {
  const PcSignResult({required this.signHex, required this.extraHex});
  final String signHex;
  final String extraHex;
}

abstract final class PcSign {
  static const String defaultQua = 'V1_LNX_NQ_3.2.34_53644_GW_B';

  // ── 常量（脚本生成）──
  static final List<BigInt> _r64 = r64_27.trim().split(RegExp(r'\s+')).map((x) => BigInt.parse('0x$x')).toList();
  static final Uint32List _lo27 = Uint32List.fromList(_r64.map((x) => (x & BigInt.from(0xffffffff)).toInt()).toList());
  static final Uint32List _hi27 = Uint32List.fromList(_r64.map((x) => ((x >> 32) & BigInt.from(0xffffffff)).toInt()).toList());
  static final Uint8List _obj0_27 = _hexToBytes(obj0_27Hex);
  static final Uint32List _entryRegs = Uint32List.fromList(entryRegs2139);
  static final Uint8List _blob27 = base64.decode(signBlob27B64);
  static final Uint8List _blob41 = base64.decode(signBlob41B64);

  /// 计算签名。[blob27]/[blob41] 为解 base64 后的 blob 字节。
  static PcSignResult computeSign({
    required Uint8List body,
    Uint8List? blob27,
    Uint8List? blob41,
    String qua = defaultQua,
    int? us,
    Uint8List? rand16,
  }) {
    final b27 = blob27 ?? _blob27;
    final b41 = blob41 ?? _blob41;
    final quaBytes = utf8.encode(qua);
    final extra = Uint8List(2 + quaBytes.length);
    extra[0] = 0x12;
    extra[1] = 0x1b;
    extra.setAll(2, quaBytes);
    final dMsg = Uint8List(extra.length + body.length);
    dMsg.setAll(0, extra);
    dMsg.setAll(extra.length, body);
    final d16 = _md5(dMsg);

    final useUs = us != null ? (us & 0xffffffff) : 0;
    final us4 = Uint8List.fromList([
      (useUs >> 24) & 0xff,
      (useUs >> 16) & 0xff,
      (useUs >> 8) & 0xff,
      useUs & 0xff,
    ]);
    final n27out = _runN27(b27, d16, useUs);
    final out2 = _md5(n27out).sublist(0, 8);

    final crcInput = Uint8List(16);
    crcInput.setAll(0, [0x6f, 0x6f, 0xb5, 0xb5]);
    crcInput.setAll(4, us4);
    crcInput.setAll(8, out2);
    final c = _crc32(crcInput);
    final notC = (~c) & 0xffffffff;
    final p0 = (notC >> 24) & 0xff;
    final p1 = (notC >> 16) & 0xff;

    final rnd = rand16 ?? Uint8List(16);
    final obj0 = Uint8List(46);
    obj0[0] = p0;
    obj0[1] = p1;
    obj0[2] = 0x6f;
    obj0[3] = 0x00;
    obj0[4] = 0x6f;
    obj0[5] = 0xb5;
    obj0[6] = 0xb5;
    obj0.setAll(7, us4);
    obj0.setAll(11, out2);
    obj0.setAll(19, [0x06, 0x01, 0x00, 0x29, 0x03, 0x00, 0x00, 0x00, 0x00]);
    obj0.setAll(28, rnd);
    obj0[44] = 0x30;
    obj0[45] = 0x00;

    final sign = _runN41(b41, obj0);
    return PcSignResult(signHex: _hex(sign), extraHex: _hex(extra));
  }

  // ── runN27 ──
  static Uint8List _runN27(Uint8List blob, Uint8List d16, int us) {
    final obj1 = Uint8List(20);
    obj1.setAll(0, d16.sublist(0, 16));
    obj1[16] = (us >> 24) & 0xff;
    obj1[17] = (us >> 16) & 0xff;
    obj1[18] = (us >> 8) & 0xff;
    obj1[19] = us & 0xff;
    final vm = _Vm(blob, _lo27, _hi27, [
      _Obj(8, 0x1e, Uint8List.fromList(_obj0_27)),
      _Obj(20, 0x1e, obj1),
    ]);
    var cur = 0x10;
    for (var i = 0; i < 400000; i++) {
      final n = vm.step(cur);
      if (n < 0 || n >= blob.length) break;
      cur = n;
    }
    return Uint8List.fromList(vm.objs[2].data.sublist(0, 20));
  }

  // ── runN41 ──
  static Uint8List _runN41(Uint8List blob, Uint8List obj0) {
    final regs = Uint32List(41);
    for (var i = 0; i < 19; i++) {
      regs[21 + i] = _entryRegs[i];
    }
    final vm = _Vm(blob, regs, null, [_Obj(46, 0x20, Uint8List.fromList(obj0))]);
    var cur = 0x10;
    for (var i = 0; i < 400000; i++) {
      final n = vm.step(cur);
      if (n < 0 || n >= blob.length) break;
      cur = n;
    }
    return Uint8List.fromList(vm.objs[15].data.sublist(0, 48));
  }

  static Uint8List _md5(Uint8List data) {
    final d = MD5Digest()..update(data, 0, data.length);
    final out = Uint8List(d.digestSize);
    d.doFinal(out, 0);
    return out;
  }

  static Uint8List _hexToBytes(String h) {
    if (h.length.isOdd) h = '0$h';
    final out = Uint8List(h.length >> 1);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

// ── 整数小工具（模拟 JS 32 位语义）──
int _u32(int v) => v & 0xffffffff;
int _s8(int v) {
  final b = v & 0xff;
  return b >= 0x80 ? b - 0x100 : b;
}

int _s16(int v) {
  final b = v & 0xffff;
  return b >= 0x8000 ? b - 0x10000 : b;
}

int _s32(int v) {
  final b = v & 0xffffffff;
  return b >= 0x80000000 ? b - 0x100000000 : b;
}

int _rotl(int x, int n) {
  n &= 31;
  return _u32((x << n) | (_u32(x) >> (32 - n)));
}

int _imul(int a, int b) => _u32(_s32(a) * _s32(b));

// CRC32 标准表（多项式 0xEDB88320，反射，与 sign.js 的标准表一致）
final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    }
    t[n] = c & 0xffffffff;
  }
  return t;
}();

int _crc32(Uint8List buf) {
  var crc = 0xffffffff;
  for (var i = 0; i < buf.length; i++) {
    crc = _u32((_u32(crc) >>> 8) ^ _crcTable[(_u32(crc) ^ buf[i]) & 0xff]);
  }
  return _u32(crc);
}

void _chachaQuarterRound(Uint32List x, int a, int b, int c, int d) {
  x[a] = _u32(x[a] + x[b]);
  x[d] = _rotl(x[d] ^ x[a], 16);
  x[c] = _u32(x[c] + x[d]);
  x[b] = _rotl(x[b] ^ x[c], 12);
  x[a] = _u32(x[a] + x[b]);
  x[d] = _rotl(x[d] ^ x[a], 8);
  x[c] = _u32(x[c] + x[d]);
  x[b] = _rotl(x[b] ^ x[c], 7);
}

Uint32List _chachaWords(
    Uint8List key, int w12, int w13, int w14, int w15) {
  final x = Uint32List(16);
  x[0] = 0x61707865;
  x[1] = 0x3320646e;
  x[2] = 0x79622d32;
  x[3] = 0x6b206574;
  for (var i = 0; i < 8; i++) {
    final k = i * 4;
    x[4 + i] = _u32(key[k] |
        (key[k + 1] << 8) |
        (key[k + 2] << 16) |
        (key[k + 3] << 24));
  }
  x[12] = _u32(w12);
  x[13] = _u32(w13);
  x[14] = _u32(w14);
  x[15] = _u32(w15);
  final orig = Uint32List.fromList(x);
  for (var r = 0; r < 10; r++) {
    _chachaQuarterRound(x, 0, 4, 8, 12);
    _chachaQuarterRound(x, 1, 5, 9, 13);
    _chachaQuarterRound(x, 2, 6, 10, 14);
    _chachaQuarterRound(x, 3, 7, 11, 15);
    _chachaQuarterRound(x, 0, 5, 10, 15);
    _chachaQuarterRound(x, 1, 6, 11, 12);
    _chachaQuarterRound(x, 2, 7, 8, 13);
    _chachaQuarterRound(x, 3, 4, 9, 14);
  }
  for (var i = 0; i < 16; i++) {
    x[i] = _u32(x[i] + orig[i]);
  }
  return x;
}

class _Obj {
  _Obj(this.len, this.flags, this.data);
  int len;
  int flags;
  Uint8List data;
}

/// sign.js 的 `VM` 逐指令移植。
class _Vm {
  _Vm(this.P, this.r, Uint32List? rhs, this.objs)
      : rh = rhs == null ? Uint32List(r.length) : Uint32List.fromList(rhs);
  final Uint8List P;
  final Uint32List r;
  final Uint32List rh;
  final List<_Obj> objs;

  int _hi(int i) => i < rh.length ? rh[i] : 0;

  List<int> _shr64(int lo, int hi, int sh) {
    sh &= 63;
    lo = _u32(lo);
    hi = _u32(hi);
    if (sh == 0) return [lo, hi];
    if (sh < 32) {
      return [_u32((lo >>> sh) | (hi << (32 - sh))), _u32(hi >>> sh)];
    }
    return [_u32(hi >>> (sh - 32)), (hi >= 0x80000000) ? 0xffffffff : 0];
  }

  _Obj? _getobj(int i) {
    if (i >= 41) return null;
    final oi = i < r.length ? r[i] : 0;
    return (oi < objs.length) ? objs[oi] : null;
  }

  int _newslot(_Obj o) {
    objs.add(o);
    return objs.length - 1;
  }

  int _r(int i) => i < r.length ? r[i] : 0;
  void _w(int i, int v) {
    if (i < r.length) r[i] = _u32(v);
  }

  void _wh(int i, int v) {
    if (i < rh.length) rh[i] = _u32(v);
  }

  int step(int off) {
    final P = this.P;
    final op = off < P.length ? P[off] : 0;
    final i0 = op;
    final i1 = (off + 1 < P.length) ? P[off + 1] : 0;
    final i2 = (off + 2 < P.length) ? P[off + 2] : 0;
    final i3 = (off + 3 < P.length) ? P[off + 3] : 0;
    final W = i0 | (i1 << 8);
    final A = i1;
    final Af = i1 & 0xf;
    final D = (W >> 8) & 0xf;
    final E = (W >> 12) & 0xf;
    var nxt = off;
    switch (op) {
      case 0x00:
        nxt = off + 2;
        break;
      case 0x01:
        _w(Af, _s16(W) >> 12);
        nxt = off + 2;
        break;
      case 0x02:
        _w(A, _u32(_s16(i2 | (i3 << 8))));
        nxt = off + 4;
        break;
      case 0x04:
        _w(A, _u32(P[off + 2] | (P[off + 3] << 8) | (P[off + 4] << 16) | (P[off + 5] << 24)));
        nxt = off + 6;
        break;
      case 0x05:
        _w(A, _u32(_r(i2) + _s8(i3)));
        nxt = off + 4;
        break;
      case 0x06:
        _w(A, _u32(_r(i2) + _r(i3)));
        nxt = off + 4;
        break;
      case 0x07:
        _w(D, _u32(_r(D) + _r(E)));
        nxt = off + 2;
        break;
      case 0x08:
        _w(D, _u32(_r(D) - _r(E)));
        nxt = off + 2;
        break;
      case 0x09:
        _w(D, _u32(_r(D) ^ _r(E)));
        nxt = off + 2;
        break;
      case 0x0a:
        _w(A, _u32(_r(i2) - _r(i3)));
        nxt = off + 4;
        break;
      case 0x0d:
        _w(Af, _u32(_r(E) & _s16(i2 | (i3 << 8))));
        nxt = off + 4;
        break;
      case 0x0f:
        _w(Af, _u32(_s8(_r(E) & 0xff)));
        nxt = off + 2;
        break;
      case 0x11:
        _w(Af, _u32(_r(E) + _s16(i2 | (i3 << 8))));
        nxt = off + 4;
        break;
      case 0x12: {
        final a = _s32(_r(i2));
        final sd = _s8(i3);
        if (sd == 0 || (a == -2147483648 && sd == -1)) {
          nxt = off + 4;
          break;
        }
        final q = _truncDiv(a, sd);
        _w(A, _u32(a - q * sd));
        nxt = off + 4;
        break;
      }
      case 0x34: {
        final a = _s32(_r(i2));
        final sd = _s8(i3);
        if (sd == 0 || (a == -2147483648 && sd == -1)) {
          nxt = off + 4;
          break;
        }
        _w(A, _u32(_truncDiv(a, sd)));
        nxt = off + 4;
        break;
      }
      case 0x36: {
        _w(i1, _u32(P[off + 2] | (P[off + 3] << 8) | (P[off + 4] << 16) | (P[off + 5] << 24)));
        _wh(i1, _u32(P[off + 6] | (P[off + 7] << 8) | (P[off + 8] << 16) | (P[off + 9] << 24)));
        nxt = off + 10;
        break;
      }
      case 0x13:
        _w(A, _u32(_s8(i3) - _r(i2)));
        nxt = off + 4;
        break;
      case 0x14:
        _w(i1, _u32(_s32(_r(i2)) >> (i3 & 31)));
        nxt = off + 4;
        break;
      case 0x15:
        _w(A, _u32(_imul(_s8(i3), _s32(_r(i2)))));
        nxt = off + 4;
        break;
      case 0x16:
        _w(Af, _u32(_r(E) ^ _s16(i2 | (i3 << 8))));
        nxt = off + 4;
        break;
      case 0x17:
        _w(A, _u32(_r(i2) & _s8(i3)));
        nxt = off + 4;
        break;
      case 0x18:
        _w(Af, _u32(_r(Af) << (_r(E) & 31)));
        nxt = off + 2;
        break;
      case 0x19:
        _w(A, _u32(_r(i2) << (i3 & 31)));
        nxt = off + 4;
        break;
      case 0x1b:
        _w(Af, _r(E));
        _wh(Af, _hi(E));
        nxt = off + 2;
        break;
      case 0x1a: {
        final sh = _r(i3) & 0xff;
        final s = _shr64(_r(i2), _hi(i2), sh);
        _w(A, s[0]);
        _wh(A, s[1]);
        nxt = off + 4;
        break;
      }
      case 0x1c: {
        final sh = _r(E) & 0x3f;
        final s = _shr64(_r(Af), _hi(Af), sh);
        _w(Af, s[0]);
        _wh(Af, s[1]);
        nxt = off + 2;
        break;
      }
      case 0x1d:
        _w(Af, _u32(_imul(_s32(_r(Af)), _s32(_r(E)))));
        nxt = off + 2;
        break;
      case 0x20: {
        final o = _getobj(E);
        if (o == null) return -1;
        _w(Af, _u32(o.len));
        nxt = off + 2;
        break;
      }
      case 0x21: {
        final typ = i2 | (i3 << 8);
        final size = _u32(_r(E));
        final esz = (typ == 0x0a)
            ? 8
            : (typ == 0x1f || typ == 0x21 || typ == 0x33)
                ? 4
                : 1;
        _w(Af, _u32(_newslot(_Obj(size, typ, Uint8List(size * esz + 1)))));
        _wh(Af, 0);
        nxt = off + 4;
        break;
      }
      case 0x22: {
        final o = _getobj(A);
        if (o == null) return -1;
        final tgt =
            off + 2 * _u32(P[off + 2] | (P[off + 3] << 8) | (P[off + 4] << 16) | (P[off + 5] << 24));
        final cnt = (P[tgt + 2] | (P[tgt + 3] << 8)) *
            _u32(P[tgt + 4] | (P[tgt + 5] << 8) | (P[tgt + 6] << 16) | (P[tgt + 7] << 24));
        final lim = cnt < o.data.length ? cnt : o.data.length;
        for (var k = 0; k < lim; k++) {
          o.data[k] = (tgt + 8 + k < P.length) ? P[tgt + 8 + k] : 0;
        }
        nxt = off + 6;
        break;
      }
      case 0x23:
        _w(Af, _r(E));
        nxt = off + 2;
        break;
      case 0x26:
        _w(Af, _r(E));
        _wh(Af, 0);
        nxt = off + 2;
        break;
      case 0x27:
        _w(i1, _u32(_r(i2) ^ _s8(i3)));
        nxt = off + 4;
        break;
      case 0x29:
        _w(Af, _r(E));
        nxt = off + 2;
        break;
      case 0x24:
        _w(A, _r(i2 | (i3 << 8)));
        nxt = off + 4;
        break;
      case 0x2a: {
        final s = i2 | (i3 << 8);
        _w(A, _r(s));
        _wh(A, _hi(s));
        nxt = off + 4;
        break;
      }
      case 0x2b: {
        final o = _getobj(i2);
        final k = _s32(_r(i3)) * 8;
        if (o != null && k >= 0 && k + 8 <= o.data.length) {
          _w(A, _u32(o.data[k] | (o.data[k + 1] << 8) | (o.data[k + 2] << 16) | (o.data[k + 3] << 24)));
          _wh(A, _u32(o.data[k + 4] | (o.data[k + 5] << 8) | (o.data[k + 6] << 16) | (o.data[k + 7] << 24)));
        } else {
          _w(A, 0);
          _wh(A, 0);
        }
        nxt = off + 4;
        break;
      }
      case 0x25:
        _w(A, _u32(_r(i2) ^ _r(i3)));
        nxt = off + 4;
        break;
      case 0x28:
        _w(A, _r(i2 | (i3 << 8)));
        _wh(A, 0);
        nxt = off + 4;
        break;
      case 0x30:
      case 0x31: {
        final o = _getobj(i2);
        if (o == null) return -1;
        final j = _u32(_r(i3));
        if (o.flags == 0x1f || o.flags == 0x21 || o.flags == 0x33) {
          final k = j * 4;
          if (k + 4 <= o.data.length) {
            final v = _u32(_r(i1));
            o.data[k] = v & 0xff;
            o.data[k + 1] = (v >> 8) & 0xff;
            o.data[k + 2] = (v >> 16) & 0xff;
            o.data[k + 3] = (v >> 24) & 0xff;
          }
        } else if (j < o.data.length) {
          o.data[j] = _r(i1) & 0xff;
        }
        nxt = off + 4;
        break;
      }
      case 0x32: {
        final o = _getobj(i2);
        final j = _u32(_r(i3));
        _w(A, (o != null && j < o.data.length) ? o.data[j] : 0);
        nxt = off + 4;
        break;
      }
      case 0x33: {
        final o = _getobj(i2);
        final j = _u32(_r(i3)) * 4;
        _w(A, (o != null && j + 4 <= o.data.length)
            ? _u32(o.data[j] | (o.data[j + 1] << 8) | (o.data[j + 2] << 16) | (o.data[j + 3] << 24))
            : 0);
        nxt = off + 4;
        break;
      }
      case 0x3b:
        _w(A, _u32(_r(i2) | _r(i3)));
        nxt = off + 4;
        break;
      case 0x40:
        nxt = (_s32(_r(Af)) >= _s32(_r(E))) ? off + 2 * _s16(i2 | (i3 << 8)) : off + 4;
        break;
      case 0x42:
        nxt = (_r(Af) == _r(E)) ? off + 4 : off + 2 * _s16(i2 | (i3 << 8));
        break;
      case 0x45:
        nxt = (_r(A) == 0) ? off + 2 * _s16(i2 | (i3 << 8)) : off + 4;
        break;
      case 0x46:
        nxt = (_r(A) != 0) ? off + 2 * _s16(i2 | (i3 << 8)) : off + 4;
        break;
      case 0x50:
        nxt = off + 2 * _s8(i1);
        break;
      case 0x51:
        nxt = off + 2 * _s16(i2 | (i3 << 8));
        break;
      case 0x53:
        _w(Af, _u32(_r(Af) | _r(E)));
        nxt = off + 2;
        break;
      case 0x54:
        _w(A, _u32(_u32(_r(i2)) >> (i3 & 31)));
        nxt = off + 4;
        break;
      case 0x73:
        nxt = off + 6;
        break;
      case 0x74:
        _w(i2, 0x5a5a5a5a);
        nxt = off + 6;
        break;
      case 0x75:
        _w(Af, 0);
        nxt = off + 6;
        break;
      case 0x76:
        _w(Af, 0);
        nxt = off + 6;
        break;
      case 0x72: {
        final o5 = _getobj(5);
        final o6 = _getobj(6);
        if (o5 != null && o6 != null && o6.data.length >= 32) {
          final w = _chachaWords(o6.data, _r(9), _hi(9), _r(7), _hi(7));
          for (var i = 0; i < 16; i++) {
            final b = 8 * i;
            final v = w[i];
            if (b + 4 <= o5.data.length) {
              o5.data[b] = v & 0xff;
              o5.data[b + 1] = (v >> 8) & 0xff;
              o5.data[b + 2] = (v >> 16) & 0xff;
              o5.data[b + 3] = (v >> 24) & 0xff;
            }
            if (b + 8 <= o5.data.length) {
              o5.data[b + 4] = 0;
              o5.data[b + 5] = 0;
              o5.data[b + 6] = 0;
              o5.data[b + 7] = 0;
            }
          }
        }
        nxt = off + 6;
        break;
      }
      default:
        return -1;
    }
    return nxt;
  }
}

int _truncDiv(int a, int b) {
  return a ~/ b;
}
