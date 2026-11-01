/// 录音上行：把裸 PCM16 编码成 QQ 用的 SILK v3 文件。
///
/// 与 [SilkVoicePreparer] 正好相反：那边是收（SILK→PCM），这边是发（PCM→SILK）。
/// 放在 infra 是因为它只用 dart:io + SilkCodec（FFI），没有任何 Flutter 依赖。
library;

import 'dart:io';
import 'dart:typed_data';

import 'silk_codec.dart';
import 'silk_file.dart';

class SilkVoiceEncoder {
  SilkVoiceEncoder([this._codec]);

  SilkCodec? _codec;

  SilkCodec _ensureCodec() => _codec ??= SilkCodec();

  /// 把 [pcmPath]（裸 PCM16 小端单声道）编成 SILK v3，写到 [outPath]。
  ///
  /// [outPath] 为空时写到同目录同名 .slk。返回写出的路径；失败返回 null
  /// （空文件、奇数长度、编码器异常都算失败——绝不产出半截文件）。
  Future<String?> encodeFile(
    String pcmPath, {
    String? outPath,
    int sampleRate = 16000,
    int bitRate = 16000,
  }) async {
    final src = File(pcmPath);
    if (!src.existsSync()) return null;
    final Uint8List pcm;
    try {
      pcm = await src.readAsBytes();
    } on FileSystemException {
      return null;
    }
    if (pcm.isEmpty || pcm.length.isOdd) return null;

    final List<Uint8List> frames;
    try {
      frames = _ensureCodec().encodePcm16(
        pcm,
        sampleRate: sampleRate,
        bitRate: bitRate,
      );
    } on SilkCodecException {
      return null;
    }
    if (frames.isEmpty) return null;

    final target = outPath ??
        (pcmPath.endsWith('.pcm')
            ? '${pcmPath.substring(0, pcmPath.length - 4)}.slk'
            : '$pcmPath.slk');
    try {
      await File(target).writeAsBytes(SilkFile.build(frames), flush: true);
    } on FileSystemException {
      return null;
    }
    return target;
  }

  void dispose() {
    _codec?.dispose();
    _codec = null;
  }
}
