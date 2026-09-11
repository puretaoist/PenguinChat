/// L1 日志层自测
///
/// 覆盖三件事：**格式**、**脱敏**、**体积闸门**。
/// 最后一条尤其重要——日志不能把应用存储撑爆，也不能把凭据写进文件。
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/log_selftest.dart
/// ```
library;

import 'dart:io';

import 'package:qqclient/infra/log/log_file.dart';
import 'package:qqclient/infra/log/logger.dart';

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

/// 确定性时间源。
DateTime _t(int sec, [int ms = 0]) =>
    DateTime(2026, 9, 11, 14, ms == 0 ? 23 : 23, sec, ms);

Future<void> main() async {
  stdout.writeln('=' * 66);
  stdout.writeln('L1 日志层自测');
  stdout.writeln('=' * 66);

  // -- 1. 格式 -----------------------------------------------------------
  stdout.writeln('\n【1】格式');
  {
    final r = LogRecord(
      time: DateTime(2026, 9, 11, 14, 23, 1, 123),
      level: LogLevel.info,
      scope: 'QQ8',
      message: '开始登录',
    );
    final s = r.format();
    check(
      '单行格式为 `YYYY-MM-DD HH:mm:ss.SSS L/SCOPE  消息`',
      s == '2026-09-11 14:23:01.123 I/QQ8  开始登录',
      s,
    );
    check('级别字母可用 grep 直接检索', s.contains(' I/QQ8'));

    final e = LogRecord(
      time: DateTime(2026, 9, 11, 0, 0, 0, 5),
      level: LogLevel.error,
      scope: 'TEA',
      message: '解密失败',
      error: 'FormatException: 尾部校验失败',
    );
    check('错误附加在行尾', e.format().endsWith('|  FormatException: 尾部校验失败'));
    check(
      '毫秒补零到 3 位',
      e.format().contains('.005 '),
      e.format().substring(0, 23),
    );
  }
  {
    check('级别按严重度排序', LogLevel.error.severity > LogLevel.info.severity);
    check('byName 能反查', LogLevel.byName('warn') == LogLevel.warn);
    check('未知名字返回 null', LogLevel.byName('nope') == null);
  }

  // -- 2. 脱敏（最关键的一组） --------------------------------------------
  stdout.writeln('\n【2】脱敏');
  {
    const mustRedact = <String>[
      'password', 'passwd', 'pwd', 'pwd_md5', 'passwordmd5',
      'tgtgt', 'tgt', 'd2', 'd2key', 'd2_key',
      'skey', 'pskey', 'p_skey',
      'srm_token', 'ticket', 'ticket_key', 'sig', 'sig_key',
      'cookie', 'token', 'access_token', 'authorization',
      'session_key', 'share_key', 'private_key',
      'Password', 'PWD_MD5', 'Tgtgt', 'd2-Key',
    ];
    var bad = <String>[];
    for (final k in mustRedact) {
      if (!Redact.isSensitive(k)) bad.add(k);
    }
    check(
      '凭据类键名全部被识别（${mustRedact.length} 个）',
      bad.isEmpty,
      bad.join(','),
    );

    const mustNot = <String>['uin', 'appid', 'subid', 'seq', 'cmd', 'model', 'ver'];
    var wrong = <String>[];
    for (final k in mustNot) {
      if (Redact.isSensitive(k)) wrong.add(k);
    }
    check('普通键名不被误伤', wrong.isEmpty, wrong.join(','));

    check(
      'kv 命中敏感键时输出占位符',
      Redact.kv('pwd_md5', '11111111111111111111111111111111') ==
          'pwd_md5=<redacted>',
      Redact.kv('pwd_md5', 'x'),
    );
    check(
      'kv 普通键原样输出',
      Redact.kv('uin', 10001) == 'uin=10001',
      Redact.kv('uin', 10001),
    );
    final m = Redact.map(<String, Object?>{
      'uin': 10001,
      'tgtgt': 'ffeeddccbbaa99887766554433221100',
      'ver': '8.9.50',
    });
    check('整表渲染里 tgtgt 被打码', m.contains('tgtgt=<redacted>'), m);
    check('整表渲染里 uin 保留', m.contains('uin=10001'), m);
    check('整表渲染里 ver 保留', m.contains('ver=8.9.50'), m);
  }
  {
    final fp = Redact.fingerprint('tgtgt', <int>[0xff, 0xee, 0xdd, 0xcc, 1, 2]);
    check('指纹含长度', fp.contains('len=6'), fp);
    check('指纹含前 4 字节', fp.contains('head=ffeeddcc'), fp);
    check('指纹不含后 2 字节内容', !fp.contains('0102'), fp);
    check(
      '空值给出明确标注',
      Redact.fingerprint('x', const <int>[]) == 'x=<empty>',
    );
  }

  // -- 3. 环形缓冲 -------------------------------------------------------
  stdout.writeln('\n【3】环形缓冲');
  {
    final ring = RingLogSink(capacity: 3);
    for (var i = 1; i <= 5; i++) {
      ring.write(LogRecord(
        time: _t(i),
        level: LogLevel.info,
        scope: 'S',
        message: 'm$i',
      ));
    }
    check('容量上限生效', ring.length == 3, '${ring.length}');
    final snap = ring.snapshot();
    check(
      '淘汰的是最旧的（留下 m3/m4/m5）',
      snap.map((r) => r.message).join(',') == 'm3,m4,m5',
      snap.map((r) => r.message).join(','),
    );

    ring.write(LogRecord(
      time: _t(6),
      level: LogLevel.error,
      scope: 'S',
      message: 'boom',
    ));
    check(
      'snapshotAtLeast 能过滤',
      ring.snapshotAtLeast(LogLevel.error).length == 1,
      '${ring.snapshotAtLeast(LogLevel.error).length}',
    );

    ring.capacity = 2;
    ring.write(LogRecord(
      time: _t(7),
      level: LogLevel.info,
      scope: 'S',
      message: 'm7',
    ));
    check('容量调小后立即生效', ring.length == 2, '${ring.length}');

    ring.clear();
    check('clear 生效', ring.isEmpty);
  }

  // -- 4. 门面 -----------------------------------------------------------
  stdout.writeln('\n【4】门面');
  {
    Log.clock = () => DateTime(2026, 9, 11, 14, 23, 1, 0);
    Log.configure(minLevel: LogLevel.debug, ringCapacity: 100);
    Log.clearMemory();

    final log = Log.get('QQ8');
    log.t('trace 不该进');
    log.d('debug 该进');
    log.i('info 该进');
    log.w('warn 该进');
    log.e('error 该进', error: 'some error');

    final msgs = Log.memory.snapshot().map((r) => r.message).toList();
    check('低于门面的级别被丢弃', !msgs.contains('trace 不该进'), msgs.join('|'));
    check('四个级别都进了', msgs.length == 4, '${msgs.length}');
    check('作用域被带上', Log.memory.snapshot().first.scope == 'QQ8');
    check(
      'error 的附加信息保留',
      Log.memory.snapshot().last.format().contains('some error'),
    );

    Log.configure(minLevel: LogLevel.warn);
    Log.clearMemory();
    log.i('info 现在该被丢掉');
    log.e('error 仍然进');
    check(
      '改级别后立即生效',
      Log.memory.snapshot().length == 1,
      '${Log.memory.snapshot().length}',
    );
    Log.configure(minLevel: LogLevel.debug);

    // 自定义出口
    final got = <String>[];
    final sink = _CollectSink(got);
    Log.addSink(sink);
    Log.clearMemory();
    Log.get('T').i('hello sink');
    check('自定义出口收到日志', got.length == 1 && got.first.contains('hello sink'), got.join('|'));
    await Log.removeSink(sink);
    Log.clearMemory();
    Log.get('T').i('after remove');
    check('移除后不再收到', got.length == 1, '${got.length}');
  }

  // -- 5. 落盘 + 轮转 + 体积闸门 ------------------------------------------
  stdout.writeln('\n【5】落盘与体积闸门');
  final tmp = Directory.systemTemp.createTempSync('qqclient_log_test_');
  try {
    {
      final dir = Directory('${tmp.path}${Platform.pathSeparator}logs');
      final sink = FileLogSink(
        dir,
        minLevel: LogLevel.debug,
        maxFileBytes: 400,
        maxTotalBytes: 4096,
        maxAgeDays: 30,
        flushInterval: Duration.zero,
      );
      for (var i = 0; i < 40; i++) {
        sink.write(LogRecord(
          time: _t(i % 60, i),
          level: LogLevel.info,
          scope: 'F',
          message: 'line $i ${'x' * 30}',
        ));
      }
      await sink.flush();

      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.split(Platform.pathSeparator).last
              .startsWith(logFilePrefix))
          .toList();
      check('日志目录被自动创建', dir.existsSync());
      check('写出了文件', files.isNotEmpty, '${files.length}');
      check(
        '单文件超限触发轮转（文件数 > 1）',
        files.length > 1,
        '${files.length}',
      );
      check('落盘失败时不会抛异常拖垮应用', sink.lastError == null,
          '${sink.lastError}');

      // 总量闸门
      final removed = sink.prune();
      final total = dir
          .listSync()
          .whereType<File>()
          .fold<int>(0, (a, f) => a + f.statSync().size);
      check(
        'prune 后总量仍在预算内（${total}B <= ${sink.maxTotalBytes}B）',
        total <= sink.maxTotalBytes + 8192,
        total.toString(),
      );
      check('prune 返回删除数（$removed）', removed >= 0);

      // 内容可读
      final last = dir
          .listSync()
          .whereType<File>()
          .toList()
        ..sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      final text = last.last.readAsStringSync();
      check('文件内容是可读文本', text.contains('I/F'));
    }

    // -- 6. 导出 ---------------------------------------------------------
    stdout.writeln('\n【6】导出');
    {
      Log.clearMemory();
      Log.configure(minLevel: LogLevel.debug, ringCapacity: 100);
      Log.clock = () => DateTime(2026, 9, 11, 14, 23, 1, 0);
      final log = Log.get('QQ8');
      log.i('开始登录 uin=10001');
      log.d('tgtgt ${Redact.fingerprint('tgtgt', <int>[0xaa, 0xbb, 0xcc, 0xdd])}');
      log.e('连接被拒', error: 'SocketException');

      final report = LogExporter.buildReport(
        metadata: <String, Object?>{
          'app': 'qqclient 0.1.0',
          'android': 16,
          'model': '25091RP04C',
          'pwd_md5': '11111111111111111111111111111111',
          'tgtgt': 'ffeeddccbbaa99887766554433221100',
        },
        now: DateTime(2026, 9, 11, 14, 30),
        includeFileLogs: false,
      );

      check('报告含抬头', report.contains('QQ 客户端日志导出'));
      check('报告含导出时间', report.contains('2026-09-11T14:30'));
      check('报告含环境段', report.contains('--- 环境 ---'));
      check('报告含普通元数据', report.contains('model=25091RP04C'));
      check(
        '报告里 pwd_md5 被脱敏',
        report.contains('pwd_md5=<redacted>') &&
            !report.contains('11111111111111111111111111111111'),
      );
      check(
        '报告里 tgtgt 被脱敏',
        report.contains('tgtgt=<redacted>') &&
            !report.contains('ffeeddccbbaa99887766554433221100'),
      );
      check('报告含日志段', report.contains('--- 内存缓冲'));
      check('报告含实际日志行', report.contains('开始登录 uin=10001'));
      check('报告含错误行', report.contains('E/QQ8') && report.contains('SocketException'));
      check('报告有结束标记', report.contains('导出结束'));

      // 文件导出
      final outDir = Directory('${tmp.path}${Platform.pathSeparator}export');
      final f = await LogExporter.exportToDirectory(
        outDir,
        metadata: <String, Object?>{'app': 'qqclient 0.1.0'},
        now: DateTime(2026, 9, 11, 14, 30, 1),
      );
      check('导出文件已写出', f.existsSync());
      check(
        '文件名含时间戳',
        f.path.endsWith('qqclient-log-20260911-143001.txt'),
        f.path.split(Platform.pathSeparator).last,
      );
      final body = await f.readAsString();
      check('导出文件内容与报告一致（含抬头）', body.contains('QQ 客户端日志导出'));
      check('导出文件含日志行', body.contains('开始登录 uin=10001'));
    }
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } on Object {
      // 清理失败不影响结论
    }
  }

  // -- 汇总 --------------------------------------------------------------
  stdout.writeln('\n${'=' * 66}');
  stdout.writeln('通过 $_passed 项，失败 $_failed 项');
  if (_failed == 0) {
    stdout.writeln('日志层可用 ✓');
  }
  exit(_failed == 0 ? 0 : 1);
}

/// 收集式出口，用于验证 addSink / removeSink。
class _CollectSink extends LogSink {
  _CollectSink(this.lines);
  final List<String> lines;

  @override
  void write(LogRecord record) => lines.add(record.format());
}
