/// TEA 兼容性诊断：`kernel/crypto/tea.dart` 对照 QQ 8.2.11 的真实算法
///
/// ## 为什么单独跑这个
///
/// `tea.dart` 的链式模式取自「9.3.60 的 `cryptor`」，而本次反编译 8.2.11 的
/// 同名字段用的是**另一个变体**。两者在首块之后就会分叉，若不先确认，
/// 登录包加密错了会极难定位——服务端只会回一个含糊的登录失败码。
///
/// ## Ground truth
///
/// `oicq.wlogin.sdk.tools.a`（8.2.11 APK `classes.dex`）的 `a()` 方法：
///
/// ```java
/// if (this.i) a ^= b;                    // 首块 b = 0
/// else        a ^= c[e + f];             // a ^= 前一块密文 C_{i-1}
/// System.arraycopy(a(this.a), 0, c, d, 8);   // c = TEA(a)
/// c[d + f] ^= b[f];                      // c ^= 前一块的「加密前 a」B_{i-1}
/// System.arraycopy(this.a, 0, this.b, 0, 8); // B_i = a
/// ```
///
/// 即：`B_i = P_i ⊕ C_{i-1}`，`C_i = E(B_i) ⊕ B_{i-1}`。
/// 第二项是标准 CBC 没有的。
///
/// 参考密文由 oicq 自己的 `lib/algo/tea.js` 在 Node 里生成（本工作区
/// `gen_tea_vectors.cjs`），不是手算的。
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/tea_compat_check.dart
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/crypto/tea.dart';

int _pass = 0;
int _fail = 0;

void ok(String name, [String? note]) {
  _pass++;
  stdout.writeln('  \u2713 $name${note == null ? '' : '   ($note)'}');
}

void bad(String name, String detail) {
  _fail++;
  stdout.writeln('  \u2717 $name\n      → $detail');
}

void section(String t) => stdout.writeln('\n$t');

Uint8List hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String toHex(List<int> b) =>
    b.map((x) => (x & 0xff).toRadixString(16).padLeft(2, '0')).join();

/// 把 16 字节密钥拆成 4 个 u32（大端），复刻 tea.dart 内部的 _keyInts。
List<int> keyInts(String keyHex) => bytesToU32BE(hex(keyHex));

// ---------------------------------------------------------------------------
// 参考数据（由 gen_tea_vectors.cjs 生成）
// ---------------------------------------------------------------------------

const _key = '00112233445566778899aabbccddeeff';

/// oicq tea.js 加密的密文（随机填充，但可逆性已在其侧验证为 true）
const _oicqVectors = <({String plainHex, String cipherHex})>[
  (plainHex: '68656c6c6f', cipherHex: '16cdc18066bf9b8b8de27fdce32911bc'),
  (
    plainHex: '30313233343536373839616263646566',
    cipherHex: '63dce1464cb641f2293941a271f5d2b8509e8015f78d7d2abf52dbe6687e1d4d'
  ),
  (
    plainHex: '515120382e322e31312070726f746f636f6c',
    cipherHex: 'cc215e24b08afb2d5060e72374b9e605e22a43f2b78f82aeaab56290b272db6b'
  ),
];

/// 8.2.11 的分组链输出（32 字节定长输入，确定性）
const _chainInput =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
const _chainCipher =
    '3fb45ff15db5abecd996bf809fcf0a6bcc28c60ba8bd821734d4218e9e4852a0';

/// 标准 CBC 输出（当前 tea.dart 的链式方式）
const _standardCbcCipher =
    '3fb45ff15db5abecd997bd839bca0c6caeac4a8905949bda0d3a9b34235baa28';

// ---------------------------------------------------------------------------
// 1. 块密码（轮函数）—— 应当一致
// ---------------------------------------------------------------------------

void checkBlockCipher() {
  section('1. TEA 轮函数（单块）');

  final k = keyInts(_key);
  final input = hex(_chainInput);
  final vals = bytesToU32BE(input.sublist(0, 8));

  final r = teaEncryptBlock(vals[0], vals[1], k);
  final got = toHex(u32ToBytesBE([r.v0, r.v1]));

  // 首块 B_0=0、C_0=0 → C_1 = E(P_1)，所以链式密文的头 8 字节就是 E(P_1)
  final expected = _chainCipher.substring(0, 16);

  if (got == expected) {
    ok('E(P₁) 与 8.2.11 分组链首块一致', got);
  } else {
    bad('E(P₁) 与 8.2.11 分组链首块不一致', '期望 $expected，实际 $got');
  }

  // 解密应当还原
  final d = teaDecryptBlock(r.v0, r.v1, k);
  final back = toHex(u32ToBytesBE([d.v0, d.v1]));
  if (back == _chainInput.substring(0, 16)) {
    ok('D(E(P₁)) 往返一致');
  } else {
    bad('D(E(P₁)) 往返不一致', '得到 $back');
  }
}

// ---------------------------------------------------------------------------
// 2. 填充长度公式 —— 应当一致
// ---------------------------------------------------------------------------

void checkPadding(int len, int expectedPad) {
  final pad = qqTeaPadLength(len);
  if (pad == expectedPad) {
    ok('填充长度公式 len=$len → pad=$pad');
  } else {
    bad('填充长度公式 len=$len', '期望 $expectedPad，实际 $pad');
  }
}

void checkPaddingFormula() {
  section('2. 填充长度公式');

  // oicq: n = (6 - len) % 8 + 2，其中 n = pad + 2
  //   → pad = ((6 - len) % 8 + 2) - 2 = (6 - len) % 8   （len <= 6 时）
  checkPadding(0, 6);
  checkPadding(1, 5);
  checkPadding(6, 0);

  // 长度必须落在 0..7
  var allInRange = true;
  for (var len = 0; len <= 64; len++) {
    final p = qqTeaPadLength(len);
    if (p < 0 || p > 7) allInRange = false;
    if ((p + len + 10) % 8 != 0) allInRange = false;
  }
  if (allInRange) {
    ok('对 0..64 全部长度，pad ∈ [0,7] 且总长为 8 的倍数');
  } else {
    bad('填充长度公式存在越界或未对齐', '检查 0..64 失败');
  }
}

// ---------------------------------------------------------------------------
// 3. 链式模式 —— 这是关键差异
// ---------------------------------------------------------------------------

/// 加密侧黄金向量：固定填充字节 + 8.2.11 分组链
/// （由 gen_tea_encrypt_vectors.cjs 生成，填充给足 pad+3 字节）
const _encryptVectors = <({String text, String rndHex, String cipherHex})>[
  (
    text: 'hello',
    rndHex: 'a5b6c7d8112233445566778899aabbcc',
    cipherHex: '7b28e78477053ca663e6eb83b418f695',
  ),
  (
    text: '0123456789abcdef',
    rndHex: '112233445566778899aabbccddeeff01',
    cipherHex:
        '1e4b509452826ba42fe24d27e7a4db817d699184fcbc16be86de7868eddf311e',
  ),
  (
    text: 'QQ 8.2.11 protocol',
    rndHex: 'deadbeef0102030405060708090a0b0c',
    cipherHex:
        'd27a29bdc6aa9674496643c1b9619f867338005412e38bf71c5e4b86a482e579',
  ),
];

void checkChain() {
  section('3. 分组链：加密侧跨实现验证');

  // 历史对照（仅作说明，不再参与判定）
  final prefixLen = _commonPrefixLen(_chainCipher, _standardCbcCipher);
  stdout.writeln('     8.2.11 实际 ：$_chainCipher');
  stdout.writeln('     旧标准 CBC ：$_standardCbcCipher');
  stdout.writeln('     两者公共前缀 $prefixLen 个 hex 字符 '
      '（首块必然相同，B₀=0、C₀=0）');
  stdout.writeln('     → 已按 8.2.11 的变体修正，以下为实证');

  for (final v in _encryptVectors) {
    final cipher = qqTeaEncrypt(
      v.text.codeUnits,
      hex(_key),
      paddingBytes: hex(v.rndHex),
    );
    final got = toHex(cipher);
    if (got == v.cipherHex) {
      ok('加密 "${v.text}" 与参考实现逐字节一致');
    } else {
      bad('加密 "${v.text}" 密文不一致',
          '期望 ${v.cipherHex}\n        实际 $got');
    }
  }

  section('4. 分组链：解密侧互操作性实测（oicq 密文）');

  for (var i = 0; i < _oicqVectors.length; i++) {
    final v = _oicqVectors[i];
    final cipher = hex(v.cipherHex);
    final expected = hex(v.plainHex);
    try {
      final got = qqTeaDecrypt(cipher, hex(_key));
      if (toHex(got) == toHex(expected)) {
        ok('向量 $i 解密成功（${v.plainHex.length ~/ 2} 字节明文）');
      } else {
        bad('向量 $i 解出的明文不对',
            '期望 ${v.plainHex}\n        实际 ${toHex(got)}');
      }
    } on Object catch (e) {
      bad('向量 $i 解密抛异常', '$e');
    }
  }

  // 自己加密再用自己的解密还原（往返自洽）
  section('5. 往返自洽');

  for (final v in _encryptVectors) {
    final cipher = qqTeaEncrypt(
      v.text.codeUnits,
      hex(_key),
      paddingBytes: hex(v.rndHex),
    );
    final back = qqTeaDecrypt(cipher, hex(_key));
    if (String.fromCharCodes(back) == v.text) {
      ok('往返一致 "${v.text}"');
    } else {
      bad('往返不一致 "${v.text}"', '解出 ${String.fromCharCodes(back)}');
    }
  }
}

int _commonPrefixLen(String a, String b) {
  var i = 0;
  while (i < a.length && i < b.length && a[i] == b[i]) {
    i++;
  }
  return i;
}

// ---------------------------------------------------------------------------

void main() {
  stdout.writeln('TEA 兼容性诊断：tea.dart vs QQ 8.2.11 实际算法');
  stdout.writeln('=' * 64);
  stdout.writeln('参考密文由 oicq lib/algo/tea.js 在 Node 中生成；');
  stdout.writeln('链式规格由 8.2.11 APK 的 oicq.wlogin.sdk.tools.a 反编译得出。');

  checkBlockCipher();
  checkPaddingFormula();
  checkChain();

  stdout.writeln('\n${'=' * 64}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
