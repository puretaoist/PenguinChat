/// QQ 登录 TCP 传输层离线自测
///
/// **不需要网络、不需要 QQ 账号、不碰真实服务器**。
/// 用一个真实的本地 `ServerSocket` 当 mock 服务端，走完整的
/// 「加分帧 → 过 TCP → 收字节 → 解帧」链路。
///
/// 覆盖三类容易写错的地方：
/// * **半包** —— 一次 data 事件只到一部分；
/// * **粘包** —— 一次 data 事件含多个包；
/// * **非法长度** —— 流错位时必须报错，而不是静默卡死。
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/qq8_tran_selftest.dart
/// ```
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/wlogin8/qq8_tran.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  ✓ $name');
  } else {
    _failed++;
    stdout.writeln('  ✗ $name${detail == null ? '' : '  ($detail)'}');
  }
}

Uint8List _bytes(List<int> v) => Uint8List.fromList(v);

String _hex(Uint8List b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join(' ');

/// 一个 mock 登录服务器：解帧、按脚本回包。
class MockServer {
  final ServerSocket _server;
  final List<Uint8List> _script;
  final List<Uint8List> received = <Uint8List>[];

  /// 已接受的连接，[stop] 时要一并销毁 —— 只关 ServerSocket 的话，
  /// 已建立的 socket 仍会让 Dart 事件循环活着，进程不会退出。
  final List<Socket> _clients = <Socket>[];

  /// 每次都把响应拆成 [chunkSize] 字节分批发送，用来制造半包。
  final int? chunkSize;

  /// 把多个响应合并成一次 write 发出，用来制造粘包。
  final bool coalesce;

  MockServer._(this._server, this._script, {this.chunkSize, this.coalesce = false});

  int get port => _server.port;

  static Future<MockServer> start(
    List<Uint8List> script, {
    int? chunkSize,
    bool coalesce = false,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final mock = MockServer._(server, script,
        chunkSize: chunkSize, coalesce: coalesce);
    mock._accept();
    return mock;
  }

  void _accept() {
    _server.listen((socket) {
      _clients.add(socket);
      final decoder = Qq8FrameDecoder();
      var cursor = 0;

      socket.listen(
        (chunk) {
          List<Uint8List> frames;
          try {
            frames = decoder.add(chunk);
          } on Qq8TransportException {
            socket.destroy();
            return;
          }
          received.addAll(frames);

          if (coalesce) {
            // 一次把剩下的响应全发出去 → 客户端会收到粘包
            final buf = <int>[];
            while (cursor < _script.length) {
              buf.addAll(framePacket(_script[cursor++]));
            }
            socket.add(buf);
            return;
          }

          for (var i = 0; i < frames.length; i++) {
            if (cursor >= _script.length) break;
            final framed = framePacket(_script[cursor++]);
            if (chunkSize == null) {
              socket.add(framed);
            } else {
              for (var o = 0; o < framed.length; o += chunkSize!) {
                final end = (o + chunkSize!) > framed.length
                    ? framed.length
                    : o + chunkSize!;
                socket.add(framed.sublist(o, end));
              }
            }
          }
        },
        onError: (_) {},
        onDone: () => socket.destroy(),
      );
    });
  }

  Future<void> stop() async {
    for (final c in _clients) {
      c.destroy();
    }
    _clients.clear();
    await _server.close();
  }
}

Future<void> main() async {
  stdout.writeln('=' * 66);
  stdout.writeln('QQ 登录 TCP 传输层自测');
  stdout.writeln('=' * 66);

  // -- 1. 分帧编码 -------------------------------------------------------
  stdout.writeln('\n【1】加分帧');
  {
    final f = framePacket(_bytes([0xaa, 0xbb]));
    check(
      'framePacket 总长 = 4 + payload',
      f.length == 6,
      '${f.length}',
    );
    check(
      '长度字段是大端且含自身（6）',
      f[0] == 0 && f[1] == 0 && f[2] == 0 && f[3] == 6,
      _hex(f),
    );
    check('payload 原样跟在后面', f[4] == 0xaa && f[5] == 0xbb, _hex(f));

    final big = framePacket(Uint8List(300));
    check(
      '长度能表达 304',
      big[0] == 0 && big[1] == 0 && big[2] == 0x01 && big[3] == 0x30,
      '${big[0]} ${big[1]} ${big[2]} ${big[3]}',
    );
  }

  // -- 2. 解帧器：单包 / 半包 / 粘包 ---------------------------------------
  stdout.writeln('\n【2】解帧器');
  {
    final d = Qq8FrameDecoder();
    final out = d.add(framePacket(_bytes([1, 2, 3])));
    check('单包 → 1 帧', out.length == 1, '${out.length}');
    check('内容正确', out.first.join(',') == '1,2,3', _hex(out.first));
    check('缓冲已清空', d.bufferedBytes == 0, '${d.bufferedBytes}');
  }
  {
    final d = Qq8FrameDecoder();
    final framed = framePacket(_bytes([9, 9, 9, 9]));
    final first = d.add(framed.sublist(0, 3));
    check('半包 → 0 帧', first.isEmpty, '${first.length}');
    check('半包被缓存', d.bufferedBytes == 3, '${d.bufferedBytes}');
    final second = d.add(framed.sublist(3));
    check('补齐 → 1 帧', second.length == 1, '${second.length}');
    check('内容正确', second.first.join(',') == '9,9,9,9', _hex(second.first));
    check('缓冲已清空', d.bufferedBytes == 0, '${d.bufferedBytes}');
  }
  {
    final d = Qq8FrameDecoder();
    final both = <int>[
      ...framePacket(_bytes([1])),
      ...framePacket(_bytes([2, 2])),
      ...framePacket(_bytes([3, 3, 3])),
    ];
    final out = d.add(both);
    check('粘包 → 3 帧', out.length == 3, '${out.length}');
    check(
      '三帧内容依次正确',
      out[0].join(',') == '1' && out[1].join(',') == '2,2' && out[2].join(',') == '3,3,3',
    );
    check('缓冲已清空', d.bufferedBytes == 0, '${d.bufferedBytes}');
  }
  {
    final d = Qq8FrameDecoder();
    var threw = false;
    try {
      d.add(_bytes([0, 0, 0, 3, 0xff])); // 长度 3 < 头长 4
    } on Qq8TransportException {
      threw = true;
    }
    check('长度 < 4 时报错而不是卡死', threw);
    check('报错后缓冲被清空（避免重复报同一个错）', d.bufferedBytes == 0);
  }
  {
    final d = Qq8FrameDecoder();
    var threw = false;
    try {
      d.add(_bytes([0xff, 0xff, 0xff, 0xff]));
    } on Qq8TransportException {
      threw = true;
    }
    check('长度超上限时报错', threw);
  }

  // -- 3. mock TCP 服务器：完整往返 ----------------------------------------
  stdout.writeln('\n【3】真实 TCP 往返（本地 mock 服务器）');
  {
    final resp = _bytes([0x02, 0x00, 0x00, 0x10, 0xde, 0xad]);
    final srv = await MockServer.start(<Uint8List>[resp]);
    final tran = Qq8TcpTransport(
      host: InternetAddress.loopbackIPv4.address,
      port: srv.port,
    );
    try {
      await tran.connect();
      check('已连上', tran.isConnected);
      final got = await tran.send(_bytes([0x11, 0x22]));
      check('响应字节完全一致', got.join(',') == resp.join(','), _hex(got));
      check('服务器收到 1 个请求', srv.received.length == 1, '${srv.received.length}');
      check(
        '服务器收到的 payload 正确（帧头已被剥掉）',
        srv.received.first.join(',') == '17,34',
        _hex(srv.received.first),
      );
    } finally {
      await tran.close();
      await srv.stop();
    }
    check('关闭后状态正确', !tran.isConnected);
  }

  // -- 4. 半包：服务器每 1 字节发一次 ---------------------------------------
  stdout.writeln('\n【4】半包（服务器逐字节发送）');
  {
    final resp = _bytes(List<int>.generate(40, (i) => i));
    final srv = await MockServer.start(<Uint8List>[resp], chunkSize: 1);
    final tran = Qq8TcpTransport(
      host: InternetAddress.loopbackIPv4.address,
      port: srv.port,
    );
    try {
      final got = await tran.send(_bytes([0x01]));
      check('逐字节发送仍能拼出完整响应', got.join(',') == resp.join(','));
      check('长度正确', got.length == 40, '${got.length}');
    } finally {
      await tran.close();
      await srv.stop();
    }
  }

  // -- 5. 粘包：服务器一次发多个包 -----------------------------------------
  stdout.writeln('\n【5】粘包（服务器合并发送）');
  {
    final r1 = _bytes([0xa1, 0xa2]);
    final r2 = _bytes([0xb1, 0xb2, 0xb3]);
    final srv = await MockServer.start(<Uint8List>[r1, r2], coalesce: true);
    final tran = Qq8TcpTransport(
      host: InternetAddress.loopbackIPv4.address,
      port: srv.port,
    );
    try {
      final got = await tran.send(_bytes([0x01]));
      check(
        '只取第一个包，多余的不串味',
        got.join(',') == r1.join(','),
        _hex(got),
      );
    } finally {
      await tran.close();
      await srv.stop();
    }
  }

  // -- 6. 超时 ------------------------------------------------------------
  stdout.writeln('\n【6】超时与错误路径');
  {
    // 服务器不回任何东西
    final srv = await MockServer.start(<Uint8List>[]);
    final tran = Qq8TcpTransport(
      host: InternetAddress.loopbackIPv4.address,
      port: srv.port,
    );
    var threw = false;
    try {
      await tran.send(
        _bytes([0x01]),
        timeout: const Duration(milliseconds: 300),
      );
    } on Qq8TransportException catch (e) {
      threw = e.message.contains('超时');
    } finally {
      await tran.close();
      await srv.stop();
    }
    check('无响应时按超时报错', threw);
  }
  {
    // 连不上的端口
    var threw = false;
    // 先占一个端口再关掉，保证它没人监听
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = probe.port;
    await probe.close();
    final tran = Qq8TcpTransport(
      host: InternetAddress.loopbackIPv4.address,
      port: deadPort,
      connectTimeout: const Duration(milliseconds: 800),
    );
    try {
      await tran.connect();
    } on Qq8TransportException {
      threw = true;
    }
    check('连不上时报错', threw);
  }
  {
    // 并发请求应当被拒绝
    final srv = await MockServer.start(<Uint8List>[_bytes([1])]);
    final tran = Qq8TcpTransport(
      host: InternetAddress.loopbackIPv4.address,
      port: srv.port,
    );
    var threw = false;
    try {
      final f1 = tran.send(_bytes([0x01]), timeout: const Duration(seconds: 2));
      try {
        await tran.send(_bytes([0x02]), timeout: const Duration(seconds: 2));
      } on Qq8TransportException catch (e) {
        threw = e.message.contains('并发');
      }
      await f1;
    } on Object {
      // 忽略
    } finally {
      await tran.close();
      await srv.stop();
    }
    check('并发请求被显式拒绝（本协议不支持）', threw);
  }

  // -- 7. 脚本传输 --------------------------------------------------------
  stdout.writeln('\n【7】脚本传输（登录流程自测用的那一版）');
  {
    final s = Qq8ScriptedTransport(<Uint8List>[
      _bytes([1, 1]),
      _bytes([2, 2]),
    ]);
    final a = await s.send(_bytes([0xaa]));
    final b = await s.send(_bytes([0xbb]));
    check('按顺序回放', a.join(',') == '1,1' && b.join(',') == '2,2');
    check('记录了 2 个请求', s.sent.length == 2, '${s.sent.length}');
    check('请求内容被记录', s.sent[0].join(',') == '170' && s.sent[1].join(',') == '187');
    var threw = false;
    try {
      await s.send(_bytes([0xcc]));
    } on Qq8TransportException catch (e) {
      threw = e.message.contains('用尽');
    }
    check('脚本用尽时报错', threw);
  }
  {
    final s = Qq8ScriptedTransport(
      <Uint8List>[_bytes([7, 7, 7])],
      splitResponses: true,
    );
    final r = await s.send(_bytes([0x01]));
    check('splitResponses 走了一遍真实半包路径', r.join(',') == '7,7,7');
  }

  // -- 汇总 --------------------------------------------------------------
  stdout.writeln('\n${'=' * 66}');
  stdout.writeln('通过 $_passed 项，失败 $_failed 项');
  if (_failed == 0) {
    stdout.writeln('传输层可用 ✓');
  }
  // 必须用 exit() 而不是 exitCode = —— 本文件会 bind ServerSocket，
  // 只要有句柄没关干净，事件循环就不会结束，进程会一直挂着。
  exit(_failed == 0 ? 0 : 1);
}
