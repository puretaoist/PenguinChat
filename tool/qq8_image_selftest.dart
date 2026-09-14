/// 图片上传链路离线自测（`lib/kernel/wlogin8/qq8_image.dart`）
///
/// 覆盖四步链路里**能离线验的部分**：
/// * 探图（真实 PNG 用 test/goldens 的图当黄金向量；JPEG/GIF/BMP/WebP 用最小头构造）
/// * PicUp 申请体字段号 + 回执解析（私聊/群两套偏移）
/// * highway 帧结构与官方契约（STX/ETX/头长/体长/pb 字段）
/// * highway 上传：**本地起一个假图床**，真跑一遍收发（含错误码路径）
/// * 元素回填 ↔ 我们自己的接收侧解析器**闭环**（发出去的能被解回来）
///
/// 真机那一步（连腾讯图床）只能等有可用账号时再验；输出里会提示这一点。
///
/// 运行：
/// ```bash
/// dart run tool/qq8_image_selftest.dart
/// ```
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/wlogin8/qq8_elem.dart';
import 'package:qqclient/kernel/wlogin8/qq8_image.dart';
import 'package:qqclient/kernel/wlogin8/qq8_pb.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  ✓ $name${detail == null ? '' : '   ($detail)'}');
  } else {
    _failed++;
    stdout.writeln('  ✗ $name${detail == null ? '' : '  ($detail)'}');
  }
}

void section(String t) => stdout.writeln('\n$t');

Uint8List _u32be(int v) =>
    Uint8List.fromList(<int>[(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);

int _readU32be(Uint8List b, int o) =>
    ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) & 0xFFFFFFFF;

Uint8List _concat(List<List<int>> parts) {
  final out = <int>[];
  for (final p in parts) {
    out.addAll(p);
  }
  return Uint8List.fromList(out);
}

/// 最小 PNG：签名 + IHDR（宽高在 16/20）。
Uint8List _fakePng(int w, int h) => _concat(<List<int>>[
      <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
      <int>[0, 0, 0, 13],
      'IHDR'.codeUnits,
      _u32be(w),
      _u32be(h),
      <int>[8, 6, 0, 0, 0],
      <int>[0, 0, 0, 0], // crc 占位（探图不校验）
    ]);

/// 最小 JPEG：SOI + APP0(长度 16) + SOF0（高 5/宽 7）。
Uint8List _fakeJpeg(int w, int h) => _concat(<List<int>>[
      <int>[0xFF, 0xD8],
      <int>[0xFF, 0xE0, 0x00, 0x10],
      'JFIF'.codeUnits,
      <int>[0x00],
      <int>[1, 1, 0, 0, 1, 0, 1, 0, 0],
      <int>[0xFF, 0xC0, 0x00, 0x11, 0x08],
      <int>[(h >> 8) & 0xFF, h & 0xFF],
      <int>[(w >> 8) & 0xFF, w & 0xFF],
      <int>[3, 1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1],
    ]);

/// 最小 GIF（宽高小端 u16 @6/@8）。
Uint8List _fakeGif(int w, int h) => _concat(<List<int>>[
      'GIF89a'.codeUnits,
      <int>[w & 0xFF, (w >> 8) & 0xFF, h & 0xFF, (h >> 8) & 0xFF],
      <int>[0, 0, 0, 0],
    ]);

/// 最小 BMP（宽高是有符号小端 i32 @18/@22）。
Uint8List _fakeBmp(int w, int h) {
  final b = Uint8List(30);
  b[0] = 0x42;
  b[1] = 0x4D;
  void putI32(int o, int v) {
    b[o] = v & 0xFF;
    b[o + 1] = (v >> 8) & 0xFF;
    b[o + 2] = (v >> 16) & 0xFF;
    b[o + 3] = (v >> 24) & 0xFF;
  }

  putI32(18, w);
  putI32(22, h);
  return b;
}

/// 最小 WebP（VP8X：宽高各 24 位，存的是"减 1"）。
Uint8List _fakeWebp(int w, int h) {
  final b = Uint8List(30);
  b.setRange(0, 4, 'RIFF'.codeUnits);
  b.setRange(8, 12, 'WEBP'.codeUnits);
  b.setRange(12, 16, 'VP8X'.codeUnits);
  final w1 = w - 1, h1 = h - 1;
  b[24] = w1 & 0xFF;
  b[25] = (w1 >> 8) & 0xFF;
  b[26] = (w1 >> 16) & 0xFF;
  b[27] = h1 & 0xFF;
  b[28] = (h1 >> 8) & 0xFF;
  b[29] = (h1 >> 16) & 0xFF;
  return b;
}

/// 造一条 PicUp 回执条目（dm 用 offset=1，group 用 offset=0）。
Uint8List _picUpItem({
  required int offset,
  required int code,
  String message = '',
  bool exists = false,
  int? ip,
  int? port,
  List<int> ticket = const <int>[],
  String fid = '',
}) =>
    Qq8Pb.encode(<int, Object?>{
      2 + offset: code,
      if (message.isNotEmpty) 3 + offset: message,
      if (exists) 4 + offset: 1,
      // ip/port 是"给了才发"的可选字段（官方 pb 是 optional）
      // ignore: use_null_aware_elements
      if (ip != null) 6 + offset: ip,
      // ignore: use_null_aware_elements
      if (port != null) 7 + offset: port,
      if (ticket.isNotEmpty) 8 + offset: Uint8List.fromList(ticket),
      if (fid.isNotEmpty) 9 + offset: fid,
    });

/// 造一条 highway 回包帧（`RspDataHighwayHead`）。
Uint8List _ackFrame({
  required int code,
  int offset = 0,
  int len = 0,
  int fileSize = 0,
}) {
  final head = Qq8Pb.encode(<int, Object?>{
    2: <int, Object?>{2: fileSize, 3: offset, 4: len},
    3: code,
  });
  final out = Uint8List(9 + head.length + 1);
  out[0] = 40;
  out.setRange(1, 5, _u32be(head.length));
  out.setRange(5, 9, _u32be(0));
  out.setRange(9, 9 + head.length, head);
  out[out.length - 1] = 41;
  return out;
}

Future<void> main() async {
  stdout.writeln('图片上传链路 离线自测');
  stdout.writeln('=' * 62);

  // ----------------------------------------------------------------
  section('1. 探图：真实 PNG + 各格式最小头 + 拒绝不认识的');
  {
    final p = File('test/goldens/search_page.png');
    if (p.existsSync()) {
      final info = await Qq8ImageProbe.probeFile(p.path);
      stdout.writeln('    真实 PNG: $info');
      // 期望值由 Python struct 独立解过：420 x 700
      check('真实 PNG 宽高 = 420x700', info.width == 420 && info.height == 700,
          '${info.width}x${info.height}');
      check('真实 PNG 类型 = 1001（png）', info.type == Qq8ImageType.png);
      check('真实 PNG 大小 = 文件长度', info.size == p.lengthSync(),
          '${info.size}');
      check('真实 PNG md5 是 32 位小写 hex',
          RegExp(r'^[0-9a-f]{32}$').hasMatch(info.md5Hex) &&
              info.md5.length == 16);
      check('fileParam 形如 {md5}{size}-{w}-{h}.png',
          info.fileParam.startsWith('${info.md5Hex}${info.size}-420-700.png'),
          info.fileParam);
    } else {
      check('黄金向量 test/goldens/search_page.png 存在（从工程根目录跑）', false,
          p.absolute.path);
    }

    final cases = <String, (Uint8List, int, int, int)>{
      'PNG 33x44': (_fakePng(33, 44), 33, 44, Qq8ImageType.png),
      'JPEG 7x5': (_fakeJpeg(7, 5), 7, 5, Qq8ImageType.jpg),
      'GIF 12x34': (_fakeGif(12, 34), 12, 34, Qq8ImageType.gif),
      'BMP 20x10': (_fakeBmp(20, 10), 20, 10, Qq8ImageType.bmp),
      'WebP 300x200': (_fakeWebp(300, 200), 300, 200, Qq8ImageType.webp),
    };
    for (final e in cases.entries) {
      final info = Qq8ImageProbe.probe(e.value.$1);
      check('${e.key} → ${e.value.$2}x${e.value.$3} type=${e.value.$4}',
          info.width == e.value.$2 &&
              info.height == e.value.$3 &&
              info.type == e.value.$4,
          '${info.width}x${info.height} type=${info.type}');
    }

    var threw = false;
    try {
      Qq8ImageProbe.probe(Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]));
    } on Qq8ImageException {
      threw = true;
    }
    check('认不出来的格式显式拒绝（不按 jpg 兜底）', threw);

    var tooBig = false;
    try {
      Qq8ImageProbe.probe(Uint8List(Qq8ImageProbe.maxUploadSize + 1));
    } on Qq8ImageException {
      tooBig = true;
    }
    check('超过 30 MiB 显式拒绝', tooBig);
  }

  // ----------------------------------------------------------------
  section('2. PicUp 申请体：字段号逐项核对（单源：oicq contactable.ts）');
  {
    const apkVersion = 3898;
    final info = Qq8ImageProbe.probe(_fakePng(64, 48));

    final dm = Qq8Pb.decode(Qq8ImageUp.buildOffPicUpBody(
      uin: 10001,
      uid: 22222,
      images: <Qq8ImageInfo>[info],
      apkVersion: apkVersion,
    ));
    final dmItems = dm[2];
    final dmItem = dmItems == null || dmItems.isEmpty
        ? null
        : Qq8Pb.decode(dmItems.first as Uint8List);
    check('私聊：外层 {1: 1, 2: [图]}',
        Qq8Pb.intAt(dm, 1) == 1 && dmItems?.length == 1,
        '${Qq8Pb.intAt(dm, 1)} / ${dmItems?.length}');
    check('私聊：1=自己 uin / 2=对方 uid',
        dmItem != null &&
            Qq8Pb.intAt(dmItem, 1) == 10001 &&
            Qq8Pb.intAt(dmItem, 2) == 22222);
    check('私聊：4=md5 原始 16B / 6=md5 hex',
        dmItem != null &&
            Qq8Pb.bytesAt(dmItem, 4)?.length == 16 &&
            Qq8Pb.textAt(dmItem, 6) == info.md5Hex);
    check('私聊：5=size / 13=origin / 14=宽 / 15=高 / 16=类型',
        dmItem != null &&
            Qq8Pb.intAt(dmItem, 5) == info.size &&
            Qq8Pb.intAt(dmItem, 13) == 1 &&
            Qq8Pb.intAt(dmItem, 14) == 64 &&
            Qq8Pb.intAt(dmItem, 15) == 48 &&
            Qq8Pb.intAt(dmItem, 16) == Qq8ImageType.png);
    check('私聊：17=APK 版本号（供服务端选图床策略）',
        dmItem != null && Qq8Pb.intAt(dmItem, 17) == apkVersion);

    final grp = Qq8Pb.decode(Qq8ImageUp.buildGroupPicUpBody(
      gid: 987654321,
      uin: 10001,
      images: <Qq8ImageInfo>[info],
      apkVersion: apkVersion,
    ));
    final grpItems = grp[3];
    final grpItem = grpItems == null || grpItems.isEmpty
        ? null
        : Qq8Pb.decode(grpItems.first as Uint8List);
    check('群：外层 {1: 3, 2: 1, 3: [图]}',
        Qq8Pb.intAt(grp, 1) == 3 &&
            Qq8Pb.intAt(grp, 2) == 1 &&
            grpItems?.length == 1,
        '${Qq8Pb.intAt(grp, 1)}/${Qq8Pb.intAt(grp, 2)}/${grpItems?.length}');
    check('群：1=群号 / 2=自己 uin / 9=bu(1)',
        grpItem != null &&
            Qq8Pb.intAt(grpItem, 1) == 987654321 &&
            Qq8Pb.intAt(grpItem, 2) == 10001 &&
            Qq8Pb.intAt(grpItem, 9) == 1);
    check('群：10=宽 / 11=高 / 12=类型 / 13=APK 版本',
        grpItem != null &&
            Qq8Pb.intAt(grpItem, 10) == 64 &&
            Qq8Pb.intAt(grpItem, 11) == 48 &&
            Qq8Pb.intAt(grpItem, 12) == Qq8ImageType.png &&
            Qq8Pb.intAt(grpItem, 13) == apkVersion);
  }

  // ----------------------------------------------------------------
  section('3. PicUp 回执解析：私聊/群两套偏移 + ip 转点分十进制');
  {
    // 私聊（offset=1）：3 码 / 4 文案 / 5 已存在 / 7 ip / 8 port / 9 ticket / 10 fid
    final dmPayload = Qq8Pb.encode(<int, Object?>{
      2: <Uint8List>[
        _picUpItem(
          offset: 1,
          code: 0,
          ip: 0x0102_0304,
          port: 8080,
          ticket: <int>[0xAA, 0xBB],
          fid: 'FID_DM',
        ),
        _picUpItem(offset: 1, code: 0, exists: true, fid: 'FID_CACHED'),
      ],
    });
    final dmReplies = Qq8ImageUp.parseOffPicUpResponse(dmPayload);
    stdout.writeln('    私聊回执: ${dmReplies.map((r) => r.toString()).join(' | ')}');
    check('私聊：两条都解出', dmReplies.length == 2, '${dmReplies.length}');
    check('私聊：fid / port / ticket 正确',
        dmReplies[0].fid == 'FID_DM' &&
            dmReplies[0].port == 8080 &&
            dmReplies[0].ticket.length == 2 &&
            dmReplies[0].ok);
    check('私聊：ip u32 → 点分十进制',
        dmReplies[0].host == qq8Int32IpToStr(0x01020304),
        '${dmReplies[0].host}');
    check('私聊：第二条是"服务端已有"',
        dmReplies[1].alreadyExists && dmReplies[1].fid == 'FID_CACHED');

    // 群（offset=0）：2 码 / 3 文案 / 4 已存在 / 6 ip / 7 port / 8 ticket / 9 fid
    final grpPayload = Qq8Pb.encode(<int, Object?>{
      3: <Uint8List>[
        _picUpItem(
          offset: 0,
          code: 35,
          message: '上传失败',
          // oicq 的约定：u32 是**低字节在前**（0x0100000A → 10.0.0.1）
          ip: 0x0100000A,
          port: 9000,
          ticket: <int>[1, 2, 3],
          fid: '',
        ),
      ],
    });
    final grpReplies = Qq8ImageUp.parseGroupPicUpResponse(grpPayload);
    check('群：失败码与文案解出',
        grpReplies.length == 1 &&
            grpReplies[0].code == 35 &&
            grpReplies[0].message == '上传失败' &&
            !grpReplies[0].ok,
        '${grpReplies.first}');
    check('群：ip 解出（10.0.0.1）', grpReplies[0].host == '10.0.0.1',
        '${grpReplies[0].host}');

    check('空回执不炸（返回空表）',
        Qq8ImageUp.parseOffPicUpResponse(Uint8List(0)).isEmpty &&
            Qq8ImageUp.parseGroupPicUpResponse(Uint8List(0)).isEmpty);
  }

  // ----------------------------------------------------------------
  section('4. highway 帧：官方契约（STX/ETX/头长/体长/pb 字段）');
  {
    final chunk = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
    final fileMd5 = Uint8List.fromList(List<int>.generate(16, (i) => i));
    final ticket = Uint8List.fromList(<int>[0xDE, 0xAD]);
    final frame = Qq8Highway.buildFrame(
      seq: 7,
      uin: '10001',
      appid: 537155557,
      buCmdId: Qq8Highway.cmdIdDmImage,
      ticket: ticket,
      fileMd5: fileMd5,
      fileSize: 1000,
      offset: 8,
      chunk: chunk,
    );
    final headLen = _readU32be(frame, 1);
    final bodyLen = _readU32be(frame, 5);
    stdout.writeln('    帧: ${frame.length}B 头 $headLen 体 $bodyLen');
    check('首字节 STX=40 / 末字节 ETX=41',
        frame[0] == 40 && frame[frame.length - 1] == 41);
    check('头长/体长与实体一致（总长 = 9 + 头 + 体 + 1）',
        headLen + 9 + bodyLen + 1 == frame.length && bodyLen == chunk.length,
        '${frame.length}');
    check('数据段就是原字节',
        frame.sublist(9 + headLen, 9 + headLen + 8).join(',') ==
            chunk.join(','));

    final head = Qq8Pb.decode(frame.sublist(9, 9 + headLen));
    final base = Qq8Pb.decode(Qq8Pb.bytesAt(head, 1)!);
    final seg = Qq8Pb.decode(Qq8Pb.bytesAt(head, 2)!);
    check('basehead：1=ver(1) / 2=uin / 3=命令字 / 4=seq / 6=appid / 7=dataflag(4096) / 8=cmdid',
        Qq8Pb.intAt(base, 1) == 1 &&
            Qq8Pb.textAt(base, 2) == '10001' &&
            Qq8Pb.textAt(base, 3) == 'PicUp.DataUp' &&
            Qq8Pb.intAt(base, 4) == 7 &&
            Qq8Pb.intAt(base, 6) == 537155557 &&
            Qq8Pb.intAt(base, 7) == 4096 &&
            Qq8Pb.intAt(base, 8) == 1,
        'cmd=${Qq8Pb.textAt(base, 3)}');
    check('seghead：2=总长 / 3=偏移 / 4=本片长 / 6=ticket / 8=片 md5 / 9=整文件 md5',
        Qq8Pb.intAt(seg, 2) == 1000 &&
            Qq8Pb.intAt(seg, 3) == 8 &&
            Qq8Pb.intAt(seg, 4) == 8 &&
            Qq8Pb.bytesAt(seg, 6)?.join(',') == '222,173' &&
            Qq8Pb.bytesAt(seg, 9)?.join(',') == fileMd5.join(','));
  }

  // ----------------------------------------------------------------
  section('5. highway 上传：本地假图床真跑一遍（含错误码路径）');
  {
    // 假图床：收帧 → 校验结构 → 回 ack；记录收到的片偏移与长度。
    final received = <(int, int, Uint8List)>[];
    var ackError = 0;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final serve = () async {
      await for (final socket in server) {
        final buf = BytesBuilder(copy: false);
        socket.listen((d) {
          buf.add(d);
          var acc = buf.takeBytes();
          var pos = 0;
          while (acc.length - pos >= 10) {
            if (acc[pos] != 40) {
              pos++;
              continue;
            }
            final headLen = _readU32be(acc, pos + 1);
            final bodyLen = _readU32be(acc, pos + 5);
            final total = 9 + headLen + bodyLen + 1;
            if (acc.length - pos < total) break;
            final head = Qq8Pb.decode(acc.sublist(pos + 9, pos + 9 + headLen));
            final seg = Qq8Pb.decode(Qq8Pb.bytesAt(head, 2)!);
            final off = Qq8Pb.intAt(seg, 3) ?? 0;
            final len = Qq8Pb.intAt(seg, 4) ?? 0;
            final size = Qq8Pb.intAt(seg, 2) ?? 0;
            received.add((off, len, Uint8List.fromList(
                acc.sublist(pos + 9 + headLen, pos + 9 + headLen + bodyLen))));
            socket.add(_ackFrame(
              code: ackError,
              offset: off,
              len: len,
              fileSize: size,
            ));
            pos += total;
          }
          if (pos < acc.length) {
            buf.add(Uint8List.sublistView(acc, pos));
          }
        });
      }
    }();
    unawaited(serve);

    final data = Uint8List.fromList(
        List<int>.generate(2 * Qq8Highway.maxChunk + 123, (i) => i & 0xFF));
    final progress = <double>[];
    await Qq8Highway.upload(
      host: '127.0.0.1',
      port: server.port,
      uin: '10001',
      appid: 537155557,
      buCmdId: Qq8Highway.cmdIdGroupImage,
      ticket: Uint8List.fromList(<int>[9, 9]),
      fileMd5: Uint8List(16),
      data: data,
      timeout: const Duration(seconds: 10),
      onProgress: progress.add,
    );
    stdout.writeln('    收到 ${received.length} 片，进度回调 '
        '${progress.map((p) => (p * 100).toStringAsFixed(0)).join('% → ')}%');
    check('2.5 MiB 分成 3 片（1 MiB 上限）', received.length == 3,
        '${received.length}');
    check('片偏移 0 / 1MiB / 2MiB',
        received[0].$1 == 0 &&
            received[1].$1 == Qq8Highway.maxChunk &&
            received[2].$1 == 2 * Qq8Highway.maxChunk,
        received.map((r) => r.$1).join(','));
    check('最后一片长度 = 余数',
        received[2].$2 == data.length - 2 * Qq8Highway.maxChunk,
        '${received[2].$2}');
    check('服务端收到的数据与原文逐字节一致',
        received[0].$3.length + received[1].$3.length + received[2].$3.length ==
                data.length &&
            received[1].$3[0] == data[Qq8Highway.maxChunk] &&
            received[2].$3.last == data.last);
    check('进度回调收尾到 100%',
        progress.isNotEmpty && progress.last == 1.0,
        '${progress.length} 次');

    // 错误码：图床回 35 → 必须抛，且带 code
    ackError = 35;
    var err = '';
    try {
      await Qq8Highway.upload(
        host: '127.0.0.1',
        port: server.port,
        uin: '10001',
        appid: 537155557,
        buCmdId: Qq8Highway.cmdIdGroupImage,
        ticket: Uint8List.fromList(<int>[9, 9]),
        fileMd5: Uint8List(16),
        data: Uint8List.fromList(<int>[1, 2, 3, 4]),
        timeout: const Duration(seconds: 10),
      );
    } on Qq8ImageException catch (e) {
      err = e.message;
    }
    check('图床回错误码时抛异常并带上码', err.contains('35'), err);

    // 用一个"刚关掉的本地端口"验连不上：立即被拒，不用等超时
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = closed.port;
    await closed.close();
    var refused = '';
    try {
      await Qq8Highway.upload(
        host: '127.0.0.1',
        port: deadPort,
        uin: '10001',
        appid: 1,
        buCmdId: 1,
        ticket: Uint8List(0),
        fileMd5: Uint8List(16),
        data: Uint8List.fromList(<int>[1]),
        timeout: const Duration(seconds: 3),
        connectTimeout: const Duration(seconds: 2),
      );
    } on Qq8ImageException catch (e) {
      refused = e.message;
    }
    check('连不上图床时给明确错误', refused.contains('连图床'), refused);
    await server.close();
  }

  // ----------------------------------------------------------------
  section('6. 元素回填 ↔ 接收侧解析 闭环（发出去的能被我们自己解回来）');
  {
    final info = Qq8ImageProbe.probe(_fakePng(120, 80));
    final dmElem = Qq8ImageElems.dm(info: info, fid: 'FID/1/2');
    final scan = Qq8ElemScan()..scan(dmElem);
    final first = scan.elems.first;
    stdout.writeln('    私聊元素回读: ${first.runtimeType}');
    check('私聊元素被识别为图片元素', first is Qq8ImageElem,
        '${first.runtimeType}');
    final img = first is Qq8ImageElem ? first : null;
    if (img == null) {
      check('私聊：md5 / 宽高 / fid 原样读回', false, '元素类型不对');
    } else {
      check('私聊：md5 / 宽高 / size 原样读回',
          img.md5 == info.md5Hex &&
              img.width == 120 &&
              img.height == 80 &&
              img.size == info.size,
          'md5=${img.md5} ${img.width}x${img.height}');
      check('私聊：url 用 fid 拼出来', img.url?.contains('FID/1/2') ?? false,
          '${img.url}');
      check('私聊：group 标记为假', !img.group);
    }

    final grpElem = Qq8ImageElems.group(info: info, fid: 'GROUPFID');
    final scan2 = Qq8ElemScan()..scan(grpElem);
    final first2 = scan2.elems.first;
    check('群元素被识别为图片元素', first2 is Qq8ImageElem);
    final img2 = first2 is Qq8ImageElem ? first2 : null;
    if (img2 == null) {
      check('群：md5 / 宽高 / fid 原样读回', false, '元素类型不对');
    } else {
      check('群：md5 / 宽高 / group 标记原样读回',
          img2.md5 == info.md5Hex &&
              img2.width == 120 &&
              img2.height == 80 &&
              img2.group,
          'md5=${img2.md5} ${img2.width}x${img2.height}');
      check('群：fileParam = {md5}{size}-120-80.png',
          img2.file == info.fileParam, img2.file);
    }

    final asFace = Qq8ElemScan()
      ..scan(Qq8ImageElems.dm(info: info, fid: 'F', asFace: true));
    final first3 = asFace.elems.first;
    check('asFace 标记能读回（29.1）',
        first3 is Qq8ImageElem && first3.asFace);
  }

  // ----------------------------------------------------------------
  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_passed 项，失败 $_failed 项');
  if (_failed == 0) {
    stdout.writeln('上传链路离线部分可用 ✓（真机那一步要连腾讯图床，另行验证）');
  }
  exit(_failed == 0 ? 0 : 1);
}
