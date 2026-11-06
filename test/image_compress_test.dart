import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:penguinchat/infra/media/image_compress.dart';

/// 发送前压缩的单测。
///
/// 只测"决策"不测"画质"：像素级断言（缩放后某个点的颜色）会被插值算法
/// 和编码器版本牵着走，测起来脆；这里断言的是**行为契约**——
/// 什么时候原样直传、什么时候必须缩到 2560、坏数据怎么报错。
void main() {
  test('小图原样直传：不重编码，字节完全一致', () async {
    final src = img.Image(width: 320, height: 200);
    img.fill(src, color: img.ColorRgb8(20, 120, 200));
    final bytes = Uint8List.fromList(img.encodePng(src));

    final out = await ImageCompressor.prepare(bytes, name: 'small.png');
    expect(out.changed, isFalse, reason: '320x200 远小于阈值，不该被动过');
    expect(out.format, 'original');
    expect(out.bytes.length, bytes.length, reason: '原样直传，一个字节都不该变');
    expect(out.width, 320);
    expect(out.height, 200);
  });

  test('长边超过 2560：缩到 2560，体积不涨', () async {
    // 用噪声图而不是纯色图：纯色 PNG 本身就极小，重编码只会更大，实现会
    // 正确地"退回原图"，测不到缩放路径。噪声图才代表相机照片。
    final rnd = math.Random(7);
    final src = img.Image(width: 3000, height: 1000);
    for (final p in src) {
      p.r = rnd.nextInt(256);
      p.g = rnd.nextInt(256);
      p.b = rnd.nextInt(256);
    }
    final bytes = Uint8List.fromList(img.encodePng(src));

    final out = await ImageCompressor.prepare(bytes, name: 'wide.png');
    expect(out.changed, isTrue);
    expect(out.width, 2560, reason: '长边必须被压到上限');
    expect(
      out.height,
      inInclusiveRange(850, 856),
      reason: '等比缩放，1000 * 2560/3000 ≈ 853.3',
    );
    expect(out.bytes.length, lessThan(bytes.length), reason: '压完必须更小，否则不如原样发');
  });

  test('不是图片的字节：抛 ImageFormatException', () async {
    final junk = Uint8List.fromList(List<int>.generate(64, (i) => i));
    expect(
      () => ImageCompressor.prepare(junk, name: 'x.bin'),
      throwsA(isA<ImageFormatException>()),
    );
  });

  test('空文件：同样按"认不出格式"处理', () async {
    expect(
      () => ImageCompressor.prepare(Uint8List(0), name: 'empty'),
      throwsA(isA<ImageFormatException>()),
    );
  });

  test('GIF 动图：永不重编码（重编码会丢帧），原样返回', () async {
    final a = img.Image(width: 40, height: 40);
    img.fill(a, color: img.ColorRgb8(0, 0, 0));
    final b = img.Image(width: 40, height: 40);
    img.fill(b, color: img.ColorRgb8(255, 255, 255));
    final gif = img.GifEncoder();
    gif.addFrame(a);
    gif.addFrame(b);
    final bytes = Uint8List.fromList(gif.finish()!);

    final out = await ImageCompressor.prepare(bytes, name: 'anim.gif');
    expect(out.animated, isTrue);
    expect(out.changed, isFalse);
    expect(out.bytes.length, bytes.length);
  });

  group('prepareFile：从路径读图', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('img_compress'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('小图：读盘后原样直传', () async {
      final src = img.Image(width: 128, height: 64);
      img.fill(src, color: img.ColorRgb8(1, 2, 3));
      final file = File('${dir.path}/a.png')
        ..writeAsBytesSync(img.encodePng(src));

      final out = await ImageCompressor.prepareFile(file.path, name: 'a.png');
      expect(out.changed, isFalse);
      expect(out.width, 128);
      expect(out.height, 64);
    });

    test('空文件：抛 ImageFormatException', () async {
      final file = File('${dir.path}/empty.png')..writeAsBytesSync(<int>[]);
      expect(
        () => ImageCompressor.prepareFile(file.path),
        throwsA(isA<ImageFormatException>()),
      );
    });

    test('超过 30 MiB：不读内容，直接拒绝', () async {
      final file = File('${dir.path}/huge.bin');
      final raf = file.openSync(mode: FileMode.write);
      raf.truncateSync(imageMaxUploadBytes + 1);
      raf.closeSync();
      expect(
        () => ImageCompressor.prepareFile(file.path),
        throwsA(isA<ImageTooLargeException>()),
      );
    });
  });
}
