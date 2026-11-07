// SILK v3 编解码封装 —— Dart FFI 直接调用 Skype SILK SDK 的标准 C API。
//
// 动态库：
//   * Android：libsilkcodec.so（android/app/src/main/cpp/CMakeLists.txt 构建）
//   * Windows：silkcodec.dll（默认 build/host/silkcodec.dll，可用 SILK_LIB_PATH 覆盖）
//
// 不做 JNI：直接绑定 C 符号，C 侧由 silk_alloc.c 额外导出 silk_malloc/silk_free，
// 让 Dart 无需依赖 package:ffi 也能申请原生态缓冲。
library;

// 字符串拼接是为了避免在 run_code 的 JS 模板里写 Dart 的 ${} 插值；
// 语义完全一致，这里统一关闭该风格 lint。
// ignore_for_file: prefer_interpolation_to_compose_strings

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// 编码控制结构，布局必须与 SKP_Silk_SDK_EncControlStruct 完全一致
/// （vendor/silk/interface/SKP_Silk_control.h，8 个 32 位整型，共 32 字节）。
final class SilkEncControl extends Struct {
  @Int32()
  external int apiSampleRate; // API_sampleRate

  @Int32()
  external int maxInternalSampleRate; // maxInternalSampleRate

  @Int32()
  external int packetSize; // packetSize（毫秒）

  @Int32()
  external int bitRate; // bitRate（bps）

  @Int32()
  external int packetLossPercentage; // packetLossPercentage

  @Int32()
  external int complexity; // complexity 0..2

  @Int32()
  external int useInBandFec; // useInBandFEC

  @Int32()
  external int useDtx; // useDTX
}

/// 解码控制结构，布局必须与 SKP_Silk_SDK_DecControlStruct 完全一致
/// （5 个 32 位整型，共 20 字节）。
final class SilkDecControl extends Struct {
  @Int32()
  external int apiSampleRate;

  @Int32()
  external int frameSize;

  @Int32()
  external int framesPerPacket;

  @Int32()
  external int moreInternalDecoderFrames;

  @Int32()
  external int inBandFecOffset;
}

/// SILK 调用错误。[code] 为 SDK 返回的非零状态码（若可得）。
class SilkCodecException implements Exception {
  SilkCodecException(this.message, [this.code]);

  final String message;
  final int? code;

  @override
  String toString() => code == null
      ? 'SilkCodecException: ' + message
      : 'SilkCodecException(' + code.toString() + '): ' + message;
}

typedef _GetSizeNative = Int32 Function(Pointer<Int32>);
typedef _GetSizeDart = int Function(Pointer<Int32>);
typedef _InitEncoderNative = Int32 Function(
  Pointer<Void>,
  Pointer<SilkEncControl>,
);
typedef _InitEncoderDart = int Function(Pointer<Void>, Pointer<SilkEncControl>);
typedef _EncodeNative = Int32 Function(
  Pointer<Void>,
  Pointer<SilkEncControl>,
  Pointer<Int16>,
  Int32,
  Pointer<Uint8>,
  Pointer<Int16>,
);
typedef _EncodeDart = int Function(
  Pointer<Void>,
  Pointer<SilkEncControl>,
  Pointer<Int16>,
  int,
  Pointer<Uint8>,
  Pointer<Int16>,
);
typedef _InitDecoderNative = Int32 Function(Pointer<Void>);
typedef _InitDecoderDart = int Function(Pointer<Void>);
typedef _DecodeNative = Int32 Function(
  Pointer<Void>,
  Pointer<SilkDecControl>,
  Int32,
  Pointer<Uint8>,
  Int32,
  Pointer<Int16>,
  Pointer<Int16>,
);
typedef _DecodeDart = int Function(
  Pointer<Void>,
  Pointer<SilkDecControl>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Int16>,
  Pointer<Int16>,
);
typedef _VersionNative = Pointer<Uint8> Function();
typedef _VersionDart = Pointer<Uint8> Function();
typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

/// SILK v3 编解码器。
///
/// 一次构造即加载动态库并绑定符号；编码器/解码器状态在实例内复用，
/// 因而连续帧具备正常的流式上下文（PLC/平滑）。
class SilkCodec {
  factory SilkCodec({String? libraryPath}) {
    final DynamicLibrary lib;
    try {
      lib = _openLibrary(libraryPath);
    } catch (e) {
      throw SilkCodecException('加载 SILK 动态库失败: ' + e.toString());
    }
    final codec = SilkCodec._(lib);
    codec._bind();
    return codec;
  }

  SilkCodec._(this._lib);

  final DynamicLibrary _lib;

  late final _GetSizeDart _getEncoderSize;
  late final _GetSizeDart _getDecoderSize;
  late final _InitEncoderDart _initEncoder;
  late final _EncodeDart _encode;
  late final _InitDecoderDart _initDecoder;
  late final _DecodeDart _decode;
  late final _VersionDart _getVersion;

  late final _MallocDart _malloc;
  late final _FreeDart _free;

  Pointer<Void>? _encState;
  Pointer<SilkEncControl>? _encControl;
  int _encSampleRate = 0;
  int _encBitRate = 0;

  Pointer<Void>? _decState;
  int _decSampleRate = 0;

  void _bind() {
    _getEncoderSize = _lib.lookupFunction<_GetSizeNative, _GetSizeDart>(
      'SKP_Silk_SDK_Get_Encoder_Size',
    );
    _getDecoderSize = _lib.lookupFunction<_GetSizeNative, _GetSizeDart>(
      'SKP_Silk_SDK_Get_Decoder_Size',
    );
    _initEncoder = _lib.lookupFunction<_InitEncoderNative, _InitEncoderDart>(
      'SKP_Silk_SDK_InitEncoder',
    );
    _encode = _lib.lookupFunction<_EncodeNative, _EncodeDart>(
      'SKP_Silk_SDK_Encode',
    );
    _initDecoder = _lib.lookupFunction<_InitDecoderNative, _InitDecoderDart>(
      'SKP_Silk_SDK_InitDecoder',
    );
    _decode = _lib.lookupFunction<_DecodeNative, _DecodeDart>(
      'SKP_Silk_SDK_Decode',
    );
    _getVersion = _lib.lookupFunction<_VersionNative, _VersionDart>(
      'SKP_Silk_SDK_get_version',
    );
    _malloc = _lib.lookupFunction<_MallocNative, _MallocDart>('silk_malloc');
    _free = _lib.lookupFunction<_FreeNative, _FreeDart>('silk_free');

    _assertLayout(
      'SKP_Silk_SDK_EncControlStruct',
      sizeOf<SilkEncControl>(),
      32,
    );
    _assertLayout(
      'SKP_Silk_SDK_DecControlStruct',
      sizeOf<SilkDecControl>(),
      20,
    );
  }

  static void _assertLayout(String name, int actual, int expected) {
    if (actual != expected) {
      throw SilkCodecException(
        name +
            ' 布局异常：期望 ' +
            expected.toString() +
            ' 字节，实际 ' +
            actual.toString(),
      );
    }
  }

  static DynamicLibrary _openLibrary(String? override) {
    if (override != null && override.isNotEmpty) {
      return DynamicLibrary.open(override);
    }
    final env = Platform.environment['SILK_LIB_PATH'];
    if (env != null && env.isNotEmpty) {
      return DynamicLibrary.open(env);
    }
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libsilkcodec.so');
    }
    if (Platform.isWindows) {
      final candidates = <String>['build/host/silkcodec.dll', 'silkcodec.dll'];
      Object? lastError;
      for (final p in candidates) {
        try {
          return DynamicLibrary.open(p);
        } catch (e) {
          lastError = e;
        }
      }
      throw SilkCodecException(
        '无法加载 silkcodec.dll（尝试过 ' +
            candidates.join(', ') +
            '）。请先执行 tool/build_silk_host.sh，或设置环境变量 SILK_LIB_PATH。底层错误: ' +
            lastError.toString(),
      );
    }
    if (Platform.isLinux) {
      return DynamicLibrary.open('libsilkcodec.so');
    }
    throw SilkCodecException('当前平台不支持 SILK 动态库: ' + Platform.operatingSystem);
  }

  /// SDK 版本字符串（SKP_Silk_SDK_get_version），例如 1.0.9.6。
  String version() {
    final p = _getVersion();
    if (p == nullptr) {
      return 'unknown';
    }
    final buf = <int>[];
    for (var i = 0; i < 256; i++) {
      final b = p[i];
      if (b == 0) {
        break;
      }
      buf.add(b);
    }
    return String.fromCharCodes(buf);
  }

  /// 将 16 位小端 PCM 按 20ms 分帧编码为 SILK 帧列表。
  ///
  /// [pcm] 长度须为偶数（s16le）。最后一帧不足 20ms 时以静音补零。
  /// [sampleRate] 默认 16000；[bitRate] 默认 16000bps。
  List<Uint8List> encodePcm16(
    Uint8List pcm, {
    int sampleRate = 16000,
    int bitRate = 16000,
  }) {
    if (pcm.length.isOdd) {
      throw SilkCodecException(
        'PCM 字节数必须为偶数（s16le），实际 ' + pcm.length.toString(),
      );
    }
    final samplesPerFrame = (sampleRate / 50).round(); // 20ms
    if (samplesPerFrame <= 0) {
      throw SilkCodecException('非法采样率: ' + sampleRate.toString());
    }
    _ensureEncoder(sampleRate, bitRate);

    final totalSamples = pcm.length ~/ 2;
    final pcmData = ByteData.sublistView(pcm);
    final outFrames = <Uint8List>[];

    final inBuf = _malloc(samplesPerFrame * 2).cast<Int16>();
    final outBuf = _malloc(1024).cast<Uint8>();
    final outLenPtr = _malloc(2).cast<Int16>();
    try {
      final inList = inBuf.asTypedList(samplesPerFrame);
      for (var offset = 0; offset < totalSamples; offset += samplesPerFrame) {
        final remain = totalSamples - offset;
        final n = remain < samplesPerFrame ? remain : samplesPerFrame;
        for (var i = 0; i < n; i++) {
          inList[i] = pcmData.getInt16((offset + i) * 2, Endian.little);
        }
        for (var i = n; i < samplesPerFrame; i++) {
          inList[i] = 0;
        }
        outLenPtr.value = 1024;
        final ret = _encode(
          _encState!,
          _encControl!,
          inBuf,
          samplesPerFrame,
          outBuf,
          outLenPtr,
        );
        if (ret != 0) {
          throw SilkCodecException('SKP_Silk_SDK_Encode 失败', ret);
        }
        final len = outLenPtr.value;
        outFrames.add(Uint8List.fromList(outBuf.asTypedList(len)));
      }
    } finally {
      _free(inBuf.cast<Void>());
      _free(outBuf.cast<Void>());
      _free(outLenPtr.cast<Void>());
    }
    return outFrames;
  }

  /// 解码单个 SILK 帧，返回 16 位小端 PCM 字节。
  Uint8List decodeFrame(Uint8List frame, {int sampleRate = 16000}) {
    _ensureDecoder(sampleRate);

    final ctrl = _malloc(sizeOf<SilkDecControl>()).cast<SilkDecControl>();
    final outBuf = _malloc(2048 * 2).cast<Int16>();
    final outLenPtr = _malloc(2).cast<Int16>();
    final inBuf = _malloc(frame.isEmpty ? 1 : frame.length).cast<Uint8>();
    try {
      ctrl.ref
        ..apiSampleRate = sampleRate
        ..frameSize = 0
        ..framesPerPacket = 0
        ..moreInternalDecoderFrames = 0
        ..inBandFecOffset = 0;
      if (frame.isNotEmpty) {
        inBuf.asTypedList(frame.length).setAll(0, frame);
      }

      final samples = <int>[];
      var guard = 0;
      do {
        outLenPtr.value = 2048;
        final ret = _decode(
          _decState!,
          ctrl,
          0,
          inBuf,
          frame.length,
          outBuf,
          outLenPtr,
        );
        if (ret != 0) {
          throw SilkCodecException('SKP_Silk_SDK_Decode 失败', ret);
        }
        final n = outLenPtr.value;
        final view = outBuf.asTypedList(n);
        for (var i = 0; i < n; i++) {
          samples.add(view[i]);
        }
        guard++;
      } while (ctrl.ref.moreInternalDecoderFrames != 0 && guard < 16);

      final out = Uint8List(samples.length * 2);
      final bd = ByteData.view(out.buffer);
      for (var i = 0; i < samples.length; i++) {
        bd.setInt16(i * 2, samples[i], Endian.little);
      }
      return out;
    } finally {
      _free(ctrl.cast<Void>());
      _free(outBuf.cast<Void>());
      _free(outLenPtr.cast<Void>());
      _free(inBuf.cast<Void>());
    }
  }

  void _ensureEncoder(int sampleRate, int bitRate) {
    if (_encState != null &&
        _encSampleRate == sampleRate &&
        _encBitRate == bitRate &&
        _encControl != null) {
      return;
    }
    _freeEncoder();

    final sizePtr = _malloc(4).cast<Int32>();
    // InitEncoder 的第二个参数是「输出」控制结构：它内部会调用 QueryEncoder，
    // 把编码器当前（尚未设置的）参数写进去——此时全是 0。因此必须用独立的结构体
    // 接收，绝不能与 Encode 使用的 _encControl 共用，否则 API_sampleRate 会被清零，
    // 导致 SKP_Silk_SDK_Encode 立即返回 -2（FS_NOT_SUPPORTED）。
    final statusPtr = _malloc(sizeOf<SilkEncControl>()).cast<SilkEncControl>();
    try {
      final ret = _getEncoderSize(sizePtr);
      if (ret != 0) {
        throw SilkCodecException('SKP_Silk_SDK_Get_Encoder_Size 失败', ret);
      }
      final size = sizePtr.value;
      _encState = _malloc(size);
      final initRet = _initEncoder(_encState!, statusPtr);
      if (initRet != 0) {
        throw SilkCodecException('SKP_Silk_SDK_InitEncoder 失败', initRet);
      }
      _encControl = _malloc(sizeOf<SilkEncControl>()).cast<SilkEncControl>();
      // packetSize 的单位是「每包样本数」，20ms@16k = 320，不是毫秒数。
      final samplesPerPacket = (sampleRate / 50).round();
      _encControl!.ref
        ..apiSampleRate = sampleRate
        ..maxInternalSampleRate = sampleRate
        ..packetSize = samplesPerPacket
        ..bitRate = bitRate
        ..packetLossPercentage = 0
        ..complexity = 2
        ..useInBandFec = 0
        ..useDtx = 0;
      _encBitRate = bitRate;
      _encSampleRate = sampleRate;
    } finally {
      _free(sizePtr.cast<Void>());
      _free(statusPtr.cast<Void>());
    }
  }

  void _ensureDecoder(int sampleRate) {
    if (_decState != null && _decSampleRate == sampleRate) {
      return;
    }
    _freeDecoder();
    final sizePtr = _malloc(4).cast<Int32>();
    try {
      final ret = _getDecoderSize(sizePtr);
      if (ret != 0) {
        throw SilkCodecException('SKP_Silk_SDK_Get_Decoder_Size 失败', ret);
      }
      _decState = _malloc(sizePtr.value);
      final initRet = _initDecoder(_decState!);
      if (initRet != 0) {
        throw SilkCodecException('SKP_Silk_SDK_InitDecoder 失败', initRet);
      }
      _decSampleRate = sampleRate;
    } finally {
      _free(sizePtr.cast<Void>());
    }
  }

  void _freeEncoder() {
    if (_encState != null) {
      _free(_encState!);
      _encState = null;
    }
    if (_encControl != null) {
      _free(_encControl!.cast<Void>());
      _encControl = null;
    }
    _encSampleRate = 0;
    _encBitRate = 0;
  }

  void _freeDecoder() {
    if (_decState != null) {
      _free(_decState!);
      _decState = null;
    }
    _decSampleRate = 0;
  }

  /// 释放原生状态，释放后实例不可再用（除非重新构造）。
  void dispose() {
    _freeEncoder();
    _freeDecoder();
  }
}
