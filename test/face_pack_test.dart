/// 表情包（`assets/faces/faces.pqf`）的解析与内容校验。
///
/// 这些用例的意义：表情包是外部生成的二进制文件，打包脚本改了格式、或者资源
/// 站换了图，都只会在**运行时**炸（白格、解码失败）。在这里钉住"能解析、条目
/// 数对、每条都能解出图、关键几条的名字对得上"，打包脚本一改就会红。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:penguinchat/kernel/wlogin8/qq8_elem.dart';
import 'package:penguinchat/ui/face/face_pack.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('包能加载，条目数与格式自洽', () async {
    final pack = await FacePack.ensureLoaded();

    // 265 = 333 个可见表情里剔除 68 个 Unicode 原生 emoji 后剩下的数字 id。
    expect(pack.all.length, 265);
    expect(pack.byteLength, greaterThan(3 * 1024 * 1024));

    // 每条都能取出非空字节，且偏移不越界（_parse 已校验，这里再钉一次）。
    for (final e in pack.all) {
      final bytes = pack.bytesOf(e);
      expect(bytes, isNotEmpty, reason: '${e.id} 的 payload 为空');
      if (e.kind == FaceKind.lottie) {
        // gzip 头
        expect(bytes[0], 31, reason: '${e.id} 不是 gzip');
        expect(bytes[1], 139, reason: '${e.id} 不是 gzip');
      } else {
        // WebP 容器头：RIFF....WEBP
        expect(
          String.fromCharCodes(bytes.sublist(0, 4)),
          'RIFF',
          reason: '${e.id} 不是 WebP',
        );
        expect(
          String.fromCharCodes(bytes.sublist(8, 12)),
          'WEBP',
          reason: '${e.id} 不是 WebP',
        );
      }
    }
  });

  test('Lottie 与 WebP 两路都有，且 Lottie 是多帧', () async {
    final pack = await FacePack.ensureLoaded();
    final lottie = pack.all.where((e) => e.kind == FaceKind.lottie).toList();
    final webp = pack.all.where((e) => e.kind == FaceKind.webp).toList();

    expect(lottie.length, 110, reason: '矢量表情数量');
    expect(webp.length, 155, reason: '位图表情数量（静态 149 + 互动 6）');
    for (final e in lottie) {
      expect(e.frames, greaterThan(1), reason: '${e.id} 是 lottie 但只有一帧');
    }
    for (final e in webp) {
      expect(e.frames, 1, reason: '${e.id} 是位图却标了多帧');
    }
  });

  test('Lottie 条目能被 decodeGZip 解出动画', () async {
    final pack = await FacePack.ensureLoaded();
    // 抽查 3 个（含多段表情 114 篮球），全部解一遍太慢。
    for (final id in <String>['14', '5', '114']) {
      final e = pack.byId(id)!;
      if (e.kind != FaceKind.lottie) continue;
      final comp = await LottieComposition.decodeGZip(pack.bytesOf(e));
      expect(comp, isNotNull, reason: '$id 解不出来');
      expect(comp!.endFrame, greaterThan(0));
    }
  });

  test('经典 / 超级两段划分正确，且不含 Unicode 原生 emoji', () async {
    final pack = await FacePack.ensureLoaded();

    // 经典：数字 id 且 ≤ 340。
    for (final e in pack.classic) {
      final n = int.tryParse(e.id);
      expect(n, isNotNull);
      expect(n! <= 340, isTrue);
    }
    // 非经典：全是 > 340 的数字 id（用户决定不要 Unicode）。
    for (final e in pack.others) {
      final n = int.tryParse(e.id);
      expect(n, isNotNull, reason: '${e.id} 是 Unicode，不该进包');
      expect(n! > 340, isTrue);
    }
    expect(pack.classic.length + pack.others.length, pack.all.length);
  });

  test('关键几条按 QFace 的名字查得到（名字以 QFace 为准）', () async {
    final pack = await FacePack.ensureLoaded();

    // 14 = /微笑（最常用，也是测试里被断言的那一个）
    expect(pack.byId('14')?.name, '微笑');
    expect(pack.byName('微笑')?.id, '14');
    // 109 我方名字表叫「亲亲」，QFace 叫「左亲亲」——按用户决定取 QFace。
    expect(pack.byId('109')?.name, '左亲亲');
    // Unicode 已被剔除，包里查不到。
    expect(pack.byId('☀'), isNull);
  });

  test('token 走协议能解析的名字，不会打出无法发送的 /左亲亲', () async {
    final pack = await FacePack.ensureLoaded();

    // 14 两边同名，直接用。
    expect(pack.byId('14')?.token, '/微笑');
    // 109 展示名是 QFace 的「左亲亲」，但协议名字表里叫「亲亲」。
    final e109 = pack.byId('109')!;
    expect(e109.name, '左亲亲');
    expect(e109.token, '/亲亲', reason: '发送侧只认协议名字表里的写法');
    // 注册别名后，**所有数字 id 的 token 都必须能被协议层反查回同一个 id**。
    // 常量名字表只覆盖 id ≤ 340 的一段（缺 106 个），registerProtocolAliases
    // 把它们补齐；这条断言就是防止有人删掉那次注册。
    pack.registerProtocolAliases();
    var checked = 0;
    var suffixed = 0;
    for (final e in pack.all) {
      final n = int.tryParse(e.id);
      if (n == null) continue;
      final body = e.token.substring(1);
      final hash = body.indexOf('#');
      final resolved = hash >= 0
          ? int.tryParse(body.substring(hash + 1))
          : Qq8FaceNames.idOf(body);
      if (hash >= 0) suffixed++;
      expect(resolved, n, reason: '${e.id} 的 token ${e.token} 协议层解析不出来');
      checked++;
    }
    expect(checked, 265, reason: '数字 id 的条目数');
    // 名字被常量表里的别的 id 占用时只能带后缀（例：353 与 200 都叫「拜托」）。
    expect(suffixed, greaterThan(0), reason: '应当存在带 #id 后缀的 token');
    expect(pack.byId('353')?.token, '/拜托#353');
  });

  test('解析能识别出损坏的包', () {
    // 魔数不对
    final bad = Uint8List(64)..setRange(0, 4, 'XXXX'.codeUnits);
    expect(() => FacePack.parseForTest(bad), throwsA(isA<FormatException>()));
  });
}
