/// 波形工具：没有真实波形时的确定性兜底，以及从 PCM16 抽峰值。
///
/// 放在 L1（infra）而不是 UI：播放控制器（infra）与气泡（ui）都要用，
/// 分层规则不允许 infra 反向 import ui。
library;

/// 同一个 seed 永远画出同一组柱子（长度 bars，值 0.25..1）。
List<double> voiceWaveformFor(String seed, {int bars = 30}) {
  var h = 0x811c9dc5;
  for (final unit in seed.codeUnits) {
    h ^= unit;
    h = (h * 0x01000193) & 0x7fffffff;
  }
  final out = <double>[];
  var x = h == 0 ? 1 : h;
  for (var i = 0; i < bars; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    out.add(0.25 + (x % 1000) / 1000 * 0.75);
  }
  return out;
}

/// 从 PCM16 样本里抽 bars 个峰值，归一化到 0.25..1。
List<double> voiceWaveformFromPcm(List<int> samples, {int bars = 30}) {
  if (samples.isEmpty) return const <double>[];
  final out = <double>[];
  final chunk = (samples.length / bars).ceil();
  var peak = 1;
  for (var i = 0; i < bars; i++) {
    final start = i * chunk;
    final end = (start + chunk).clamp(0, samples.length);
    if (start >= end) break;
    var maxAbs = 0;
    for (var j = start; j < end; j++) {
      final a = samples[j].abs();
      if (a > maxAbs) maxAbs = a;
    }
    out.add(maxAbs.toDouble());
    if (maxAbs > peak) peak = maxAbs;
  }
  return out.map((v) => (0.25 + v / peak * 0.75).clamp(0.25, 1.0)).toList();
}
