/// SILK v3 编解码自测（Windows 宿主）
///
/// 运行前先编 Windows 版动态库：
///   bash tool/build_silk_host.sh
/// 然后：
///   dart tool/silk_codec_selftest.dart
///
/// 覆盖：SDK 版本、20ms 分帧编码、SILK v3 容器 build/parse 往返、
/// 逐帧解码、时域相关系数、AMR 头识别。
// ignore_for_file: avoid_print, avoid_relative_lib_imports, prefer_interpolation_to_compose_strings
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../lib/infra/audio/silk_codec.dart';
import '../lib/infra/audio/silk_file.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    print('  [OK] ' + name);
  } else {
    _failed++;
    print('  [FAIL] ' + name + (detail == null ? '' : ' -> ' + detail));
  }
}

void checkEq(String name, Object? actual, Object? expected) {
  check(name, actual == expected,
      '期望 ' + expected.toString() + '，实际 ' + actual.toString());
}

/// 在 [-maxLag, maxLag] 内搜索使皮尔逊相关系数最大的平移量。
double bestCorrelation(List<int> a, List<int> b, int maxLag) {
  var best = -1.0;
  for (var lag = -maxLag; lag <= maxLag; lag++) {
    final startA = lag < 0 ? -lag : 0;
    final startB = lag > 0 ? lag : 0;
    final len = math.min(a.length - startA, b.length - startB);
    if (len < 32) {
      continue;
    }
    var sumA = 0.0, sumB = 0.0, sumAB = 0.0, sumAA = 0.0, sumBB = 0.0;
    for (var i = 0; i < len; i++) {
      final x = a[startA + i].toDouble();
      final y = b[startB + i].toDouble();
      sumA += x;
      sumB += y;
      sumAB += x * y;
      sumAA += x * x;
      sumBB += y * y;
    }
    final meanA = sumA / len;
    final meanB = sumB / len;
    final cov = sumAB / len - meanA * meanB;
    final varA = sumAA / len - meanA * meanA;
    final varB = sumBB / len - meanB * meanB;
    if (varA <= 1e-9 || varB <= 1e-9) {
      continue;
    }
    final c = cov / math.sqrt(varA * varB);
    if (c > best) {
      best = c;
    }
  }
  return best;
}

void main() {
  print('=== SILK v3 编解码自测 ===');

  final SilkCodec codec;
  try {
    codec = SilkCodec();
  } catch (e) {
    print('[FATAL] 无法加载 SILK 动态库: ' + e.toString());
    print('       请先执行: bash tool/build_silk_host.sh');
    _failed++;
    print('结果: ' + _passed.toString() + ' 通过, ' + _failed.toString() + ' 失败');
    return;
  }

  // 1) SDK 版本
  final ver = codec.version();
  print('SDK 版本: ' + ver);
  check('SDK 版本非空', ver.isNotEmpty && ver != 'unknown');

  // 2) 生成 1 秒 440Hz 正弦 PCM16 / 16k
  const fs = 16000;
  const n = fs; // 1 秒
  const freq = 440.0;
  final pcm = Int16List(n);
  for (var i = 0; i < n; i++) {
    final v = 0.6 * 32767.0 * math.sin(2 * math.pi * freq * i / fs);
    pcm[i] = v.round().clamp(-32768, 32767);
  }
  final pcmBytes = Uint8List.view(pcm.buffer, pcm.offsetInBytes, pcm.lengthInBytes);

  // 3) 编码
  final frames = codec.encodePcm16(pcmBytes);
  print('编码帧数: ' + frames.length.toString());
  check('编码帧数约 50（1s / 20ms）', (frames.length - 50).abs() <= 1,
      '实际 ' + frames.length.toString());
  var allNonEmpty = true;
  for (final f in frames) {
    if (f.isEmpty) {
      allNonEmpty = false;
    }
  }
  check('每帧非空', allNonEmpty);

  // 4) 容器 build / parse 往返
  final fileBytes = SilkFile.build(frames);
  check('build 后识别为 SILK v3', SilkFile.looksLikeSilk(fileBytes));
  final parsed = SilkFile.parse(fileBytes);
  checkEq('parse 格式 = silkV3', parsed.format, SilkFormat.silkV3);
  checkEq('parse 帧数一致', parsed.frames.length, frames.length);
  var framesEqual = true;
  for (var i = 0; i < frames.length && i < parsed.frames.length; i++) {
    if (frames[i].length != parsed.frames[i].length) {
      framesEqual = false;
      break;
    }
    for (var j = 0; j < frames[i].length; j++) {
      if (frames[i][j] != parsed.frames[i][j]) {
        framesEqual = false;
        break;
      }
    }
  }
  check('parse 帧内容与原始一致', framesEqual);

  // 5) 逐帧解码
  final decoded = <int>[];
  for (final fr in parsed.frames) {
    final out = codec.decodeFrame(fr);
    final s = out.buffer.asInt16List(out.offsetInBytes, out.lengthInBytes ~/ 2);
    decoded.addAll(s);
  }
  print('解码样本数: ' + decoded.length.toString() + '（原始 ' + n.toString() + '）');
  check('解码样本数与原始同量级',
      (decoded.length - n).abs() < (n * 0.1).round(),
      '实际 ' + decoded.length.toString());

  // 6) 相关系数
  final corr = bestCorrelation(pcm, decoded, 80);
  print('相关系数(max over lag): ' + corr.toStringAsFixed(4));
  check('相关系数 > 0.9', corr > 0.9, corr.toStringAsFixed(4));

  // 7) AMR 头识别（仅识别，不解析）
  final amr = Uint8List.fromList(
      <int>[0x23, 0x21, 0x41, 0x4D, 0x52, 0x0A, 0x3C, 0x00]);
  check('识别 AMR 头', SilkFile.looksLikeAmr(amr));
  checkEq('AMR parse 给出 amr 标记', SilkFile.parse(amr).isAmr, true);
  check('AMR 不被当作 SILK', !SilkFile.looksLikeSilk(amr));

  codec.dispose();
  print('结果: ' + _passed.toString() + ' 通过, ' + _failed.toString() + ' 失败');
  if (_failed > 0) {
    throw StateError('SILK 自测失败: ' + _failed.toString() + ' 项');
  }
}
