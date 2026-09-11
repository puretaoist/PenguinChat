/// L1 基础设施：日志落盘与导出
///
/// 与 `logger.dart` 分开，是为了让**日志门面不依赖 `dart:io`**——
/// 门面能在纯逻辑自测里跑，落盘与导出才需要文件系统。
///
/// ## 体积控制
///
/// Telegram 式客户端对存储占用敏感，日志不能无限涨。三条闸门：
///
/// 1. **单文件上限** [maxFileBytes]，超了就轮转到 `.1` `.2` …；
/// 2. **目录总量上限** [maxTotalBytes]，超了先删最旧的；
/// 3. **保留天数** [maxAgeDays]，超期的直接删。
///
/// 默认总预算 **4 MiB**，相对 512MB 的整体存储预算可以忽略。
///
/// 本文件依赖 `dart:io`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'logger.dart';

/// 日志文件的命名前缀。
const String logFilePrefix = 'qqclient-';

/// 日志子目录名（放在应用私有目录下）。
const String logDirName = 'logs';

/// 落盘出口。
///
/// **写入是同步追加、异步 flush**：崩溃前的最后几条也要能留下来，
/// 所以不缓冲整块。但每条都 fsync 太慢，故按时间片 flush。
class FileLogSink extends LogSink {
  FileLogSink(
    this.directory, {
    this.minLevel = LogLevel.debug,
    this.maxFileBytes = 1024 * 1024,
    this.maxTotalBytes = 4 * 1024 * 1024,
    this.maxAgeDays = 14,
    this.flushInterval = const Duration(seconds: 2),
  });

  /// 日志目录。不存在会自动创建。
  final Directory directory;

  final LogLevel minLevel;

  /// 单个文件的上限，超过就轮转。
  final int maxFileBytes;

  /// 目录内所有日志文件的总上限。
  final int maxTotalBytes;

  /// 保留天数。
  final int maxAgeDays;

  /// flush 间隔。
  final Duration flushInterval;

  RandomAccessFile? _raf;
  File? _current;
  int _written = 0;
  DateTime? _lastFlush;
  bool _enabled = true;

  /// 最近一次出错的原因（初始化失败时不抛异常，只记下来，日志本身不该拖垮应用）。
  Object? lastError;

  @override
  bool accepts(LogLevel level) => _enabled && level.severity >= minLevel.severity;

  /// 打开（或复用）当前日志文件。
  Future<void> _ensureOpen() async {
    if (_raf != null) return;
    try {
      if (!directory.existsSync()) {
        directory.createSync(recursive: true);
      }
      final f = _fileFor(DateTime.now());
      _current = f;
      _raf = f.openSync(mode: FileMode.append);
      _written = f.existsSync() ? f.lengthSync() : 0;
    } on Object catch (e) {
      // 落盘失败不能让应用崩，也不能让日志把异常吞到看不见。
      lastError = e;
      _enabled = false;
    }
  }

  File _fileFor(DateTime t) => File(
        '${directory.path}${Platform.pathSeparator}'
        '$logFilePrefix${_two(t.year, 4)}-${_two(t.month)}-${_two(t.day)}.log',
      );

  static String _two(int v, [int w = 2]) => v.toString().padLeft(w, '0');

  /// 写入一条。
  ///
  /// ## 为什么用 [RandomAccessFile] 而不是 `IOSink`
  ///
  /// `IOSink.flush()` 在**上一次 flush 尚未完成**时会**同步抛**
  /// `StateError: StreamSink is bound to a stream`。日志出口的写入频率不可控
  /// （协议日志可能瞬间几百条），一旦踩到，异常会落进 [write] 的 catch，
  /// 把整个出口打成 disabled——日志静默失效，而且很难察觉。
  ///
  /// `RandomAccessFile` 没有这层异步状态机：写就是写，刷就是刷，
  /// 不会因为并发调用进入未定义状态。
  @override
  void write(LogRecord record) {
    if (!_enabled) return;
    final line = record.format();
    try {
      if (_raf == null) {
        if (!directory.existsSync()) directory.createSync(recursive: true);
        _current = _fileFor(record.time);
        _raf = _current!.openSync(mode: FileMode.append);
        _written = _current!.existsSync() ? _current!.lengthSync() : 0;
      }
      _raf!.writeStringSync('$line\n');
      _written += line.length + 1;
      _maybeFlush(record.time);
      if (_written >= maxFileBytes) {
        _rotateSync(record.time);
      }
    } on Object catch (e) {
      lastError = e;
      _enabled = false;
      _closeQuietly();
    }
  }

  void _maybeFlush(DateTime now) {
    final last = _lastFlush;
    if (last != null && now.difference(last) < flushInterval) return;
    final r = _raf;
    if (r == null) return;
    _lastFlush = now;
    try {
      r.flushSync();
    } on Object catch (e) {
      lastError = e;
    }
  }

  void _closeQuietly() {
    try {
      _raf?.closeSync();
    } on Object catch (e) {
      lastError ??= e;
    }
    _raf = null;
  }

  /// 超限时把当前文件改名，并开新文件。
  void _rotateSync(DateTime now) {
    try {
      final c = _current;
      _closeQuietly();
      if (c != null && c.existsSync()) {
        final rotated =
            File('${c.path}.${now.millisecondsSinceEpoch}');
        c.renameSync(rotated.path);
        _prune(AgeAnchor(now));
      }
      _written = 0;
      _lastFlush = null;
    } on Object catch (e) {
      lastError = e;
    }
  }

  @override
  Future<void> flush() async {
    await _ensureOpen();
    try {
      _raf?.flushSync();
    } on Object catch (e) {
      lastError = e;
    }
  }

  /// 按总量与保留期清理旧文件。返回删除的文件数。
  int prune() => _prune(AgeAnchor.fromNow());

  int _prune(AgeAnchor anchor) {
    var removed = 0;
    try {
      final files = directory
          .listSync()
          .whereType<File>()
          .where((f) => f.path.split(Platform.pathSeparator).last
              .startsWith(logFilePrefix))
          .toList();

      // 1. 按保留期删
      for (final f in files) {
        final age = anchor.now.difference(f.statSync().modified);
        if (age.inDays >= maxAgeDays) {
          f.deleteSync();
          removed++;
        }
      }

      // 2. 按总量删（最旧的先删，但当前正在写的那个不动）
      final rest = directory
          .listSync()
          .whereType<File>()
          .where((f) => f.path.split(Platform.pathSeparator).last
              .startsWith(logFilePrefix))
          .where((f) => _current == null || f.path != _current!.path)
          .toList()
        ..sort((a, b) =>
            a.statSync().modified.compareTo(b.statSync().modified));

      var total = 0;
      for (final f in rest) {
        total += f.statSync().size;
      }
      total += _written;
      for (final f in rest) {
        if (total <= maxTotalBytes) break;
        final sz = f.statSync().size;
        f.deleteSync();
        total -= sz;
        removed++;
      }
    } on Object catch (e) {
      lastError = e;
    }
    return removed;
  }

  @override
  String toString() =>
      'FileLogSink(${directory.path}, enabled=$_enabled, written=$_written)';
}

/// 只是给 `_prune` 传"现在"的载体，便于自测注入时间。
class AgeAnchor {
  AgeAnchor(this.now);
  factory AgeAnchor.fromNow() => AgeAnchor(DateTime.now());
  final DateTime now;
}

/// 日志导出。
///
/// 真机排障时没有人连 adb，用户要能把日志发出来。导出格式刻意做成
/// **纯文本、自包含、可直接粘贴**——不要 JSON，因为要发给人的是能读的东西。
abstract final class LogExporter {
  /// 导出文件的命名：`qqclient-log-20260911-142301.txt`
  static String fileNameFor(DateTime t) =>
      '${logFilePrefix}log-${t.year}${_p(t.month)}${_p(t.day)}'
      '-${_p(t.hour)}${_p(t.minute)}${_p(t.second)}.txt';

  static String _p(int v) => v.toString().padLeft(2, '0');

  /// 组装导出文本。
  ///
  /// [metadata] 是键值对头（app 版本、设备、协议档案等）。
  /// **调用方有责任不在其中放敏感值**；这里只做一次兜底脱敏。
  static String buildReport({
    Map<String, Object?> metadata = const <String, Object?>{},
    LogLevel minLevel = LogLevel.trace,
    bool includeFileLogs = true,
    Directory? logDirectory,
    int fileTailLines = 2000,
    DateTime? now,
  }) {
    final t = now ?? DateTime.now();
    final b = StringBuffer();

    b.writeln('=' * 68);
    b.writeln('QQ 客户端日志导出');
    b.writeln('导出时间: ${t.toIso8601String()}');
    b.writeln('=' * 68);
    b.writeln('');

    if (metadata.isNotEmpty) {
      b.writeln('--- 环境 ---');
      metadata.forEach((k, v) {
        b.writeln('  ${Redact.kv(k, v)}');
      });
      b.writeln('');
    }

    b.writeln('--- 内存缓冲（最近 ${Log.memory.length} 条，'
        '级别 >= ${minLevel.name}）---');
    final mem = Log.memory.snapshotAtLeast(minLevel);
    if (mem.isEmpty) {
      b.writeln('  (空)');
    } else {
      for (final r in mem) {
        b.writeln(r.format());
        if (r.stack != null) {
          for (final line in r.stack!.toString().trim().split('\n').take(12)) {
            b.writeln('      $line');
          }
        }
      }
    }
    b.writeln('');

    if (includeFileLogs && logDirectory != null && logDirectory.existsSync()) {
      b.writeln('--- 落盘日志 ---');
      final files = logDirectory
          .listSync()
          .whereType<File>()
          .where((f) =>
              f.path.split(Platform.pathSeparator).last.startsWith(logFilePrefix))
          .toList()
        ..sort((a, b) =>
            a.statSync().modified.compareTo(b.statSync().modified));
      if (files.isEmpty) {
        b.writeln('  (无)');
      } else {
        // 只取最后一个文件的尾部，避免导出文本过大。
        final last = files.last;
        b.writeln('  文件: ${last.path}');
        try {
          final lines = last.readAsLinesSync();
          final start = lines.length > fileTailLines
              ? lines.length - fileTailLines
              : 0;
          if (start > 0) b.writeln('  (省略前 $start 行)');
          for (final l in lines.sublist(start)) {
            b.writeln(l);
          }
        } on Object catch (e) {
          b.writeln('  <读取失败: $e>');
        }
      }
      b.writeln('');
    }

    b.writeln('=' * 68);
    b.writeln('导出结束');
    return b.toString();
  }

  /// 把报告写到 [target] 目录，返回写出的文件。
  static Future<File> exportToDirectory(
    Directory target, {
    Map<String, Object?> metadata = const <String, Object?>{},
    LogLevel minLevel = LogLevel.trace,
    Directory? logDirectory,
    DateTime? now,
  }) async {
    final t = now ?? DateTime.now();
    if (!target.existsSync()) target.createSync(recursive: true);
    final f = File(
      '${target.path}${Platform.pathSeparator}${fileNameFor(t)}',
    );
    final report = buildReport(
      metadata: metadata,
      minLevel: minLevel,
      logDirectory: logDirectory,
      now: t,
    );
    await f.writeAsString(report, encoding: utf8, flush: true);
    return f;
  }
}
