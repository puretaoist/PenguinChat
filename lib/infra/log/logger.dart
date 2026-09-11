/// L1 基础设施：日志
///
/// ## 为什么单独写一套，不用 `print` / `logging` 包
///
/// QQ 客户端的日志有几个**硬约束**，通用日志库都不满足：
///
/// 1. **绝不能泄漏凭据**。登录流程手里握着口令 MD5、`tgtgt`、票据、`d2key`、
///    会话密钥——这些只要进了日志文件，就等于把账号交出去了。所以脱敏必须是
///    **默认行为**，而不是"记得别打"。
/// 2. **必须能在应用内看、能导出**。真机排障时没有人连 adb，用户要能把日志
///    导出发出来。
/// 3. **必须限体积**。Telegram 式客户端对存储占用敏感，日志不能无限涨。
///
/// ## 分层
///
/// ```text
///   Log（门面，纯 Dart，无 Flutter、无 dart:io）
///     └── LogSink  ← 可插拔
///           ├── RingLogSink   内存环形缓冲（应用内查看 / 导出用）
///           ├── FileLogSink   落盘 + 轮转（见 log_file.dart）
///           └── ConsoleLogSink 开发期
/// ```
///
/// 门面本身不碰文件系统，落盘路径由调用方注入——这样 L1 不依赖 Flutter，
/// 也就能在纯 Dart 自测里跑（见 `tool/log_selftest.dart`）。
///
/// 本文件是纯 Dart。
library;

import 'dart:collection';

/// 日志级别。数值越大越严重。
enum LogLevel {
  trace(0, 'T'),
  debug(1, 'D'),
  info(2, 'I'),
  warn(3, 'W'),
  error(4, 'E');

  const LogLevel(this.severity, this.letter);

  final int severity;
  final String letter;

  static LogLevel? byName(String name) {
    for (final v in LogLevel.values) {
      if (v.name == name) return v;
    }
    return null;
  }
}

/// 一条日志。
class LogRecord {
  final DateTime time;
  final LogLevel level;

  /// 作用域，如 `QQ8` / `OneBot` / `UI`。
  final String scope;

  final String message;
  final Object? error;
  final StackTrace? stack;

  const LogRecord({
    required this.time,
    required this.level,
    required this.scope,
    required this.message,
    this.error,
    this.stack,
  });

  /// 单行格式：`2026-09-11 14:23:01.123 I/QQ8  消息`
  ///
  /// 刻意用**单行 + 固定宽度级别字母**，这样 `grep ' E/'` 就能直接捞出错误，
  /// 不需要正则。
  String format() {
    final b = StringBuffer()
      ..write(_two(time.year, 4))
      ..write('-')
      ..write(_two(time.month))
      ..write('-')
      ..write(_two(time.day))
      ..write(' ')
      ..write(_two(time.hour))
      ..write(':')
      ..write(_two(time.minute))
      ..write(':')
      ..write(_two(time.second))
      ..write('.')
      ..write(_two(time.millisecond, 3))
      ..write(' ')
      ..write(level.letter)
      ..write('/')
      ..write(scope)
      ..write('  ')
      ..write(message);
    if (error != null) b.write('  |  $error');
    return b.toString();
  }

  static String _two(int v, [int width = 2]) =>
      v.toString().padLeft(width, '0');
}

/// 日志出口。
abstract class LogSink {
  void write(LogRecord record);

  /// 落盘类出口的收尾。内存出口可为空实现。
  Future<void> flush() async {}

  /// 该出口是否记录了 [record]。返回 false 的出口会被门面跳过（省开销）。
  bool accepts(LogLevel level) => true;
}

/// 内存环形缓冲。
///
/// 只保留最近 [capacity] 条——导出时优先用它，因为它是**崩溃前最后时刻**
/// 唯一还在的东西（文件可能还没来得及 flush）。
class RingLogSink extends LogSink {
  RingLogSink({this.capacity = 2000, this.minLevel = LogLevel.trace});

  /// 最多保留多少条。运行期可调（调小会立即淘汰旧记录）。
  int capacity;

  /// 该出口记录的最低级别。
  final LogLevel minLevel;

  final ListQueue<LogRecord> _buffer = ListQueue<LogRecord>();

  @override
  bool accepts(LogLevel level) => level.severity >= minLevel.severity;

  @override
  void write(LogRecord record) {
    _buffer.addLast(record);
    _trim();
  }

  void _trim() {
    while (_buffer.length > capacity) {
      _buffer.removeFirst();
    }
  }

  int get length => _buffer.length;

  bool get isEmpty => _buffer.isEmpty;

  /// 按时间顺序快照。
  List<LogRecord> snapshot() => _buffer.toList(growable: false);

  /// 只取某级别及以上的。
  List<LogRecord> snapshotAtLeast(LogLevel level) => _buffer
      .where((r) => r.level.severity >= level.severity)
      .toList(growable: false);

  void clear() => _buffer.clear();
}

/// 控制台出口（开发期用）。
class ConsoleLogSink extends LogSink {
  ConsoleLogSink({
    this.minLevel = LogLevel.debug,
    void Function(String line)? printer,
  }) : _print = printer ?? _defaultPrint;

  final LogLevel minLevel;
  final void Function(String line) _print;

  static void _defaultPrint(String line) {
    // ignore: avoid_print
    print(line);
  }

  @override
  bool accepts(LogLevel level) => level.severity >= minLevel.severity;

  @override
  void write(LogRecord record) => _print(record.format());
}

/// 脱敏。
///
/// ## 规则
///
/// 不是"看到像密钥就替换"——那样会把有用的诊断信息也删掉。而是：
///
/// 1. **按名**：键名命中 [sensitiveKeys] 时，值一律替换为 `<redacted>`；
/// 2. **按值**：调用方明确用 [Log.secret] 报一个敏感值，则**永不输出原值**，
///    只输出长度与一个短指纹（便于比对"两次是不是同一个"，但不泄漏内容）。
abstract final class Redact {
  /// 命中这些键名的值一律脱敏。大小写不敏感，允许 `-` / `_` 分隔。
  static const Set<String> sensitiveKeys = <String>{
    'password', 'passwd', 'pwd', 'pwd_md5', 'passwordmd5', 'passwdmd5',
    'tgtgt', 'tgt', 'tgtgt_key',
    'd2', 'd2key', 'd2_key',
    'skey', 'p_skey', 'pskey', 's_key',
    'srm_token', 'srmtoken', 'ticket', 'ticket_key', 'ticketkey',
    'sig', 'sig_key', 'sigkey',
    'cookie', 'cookies', 'authorization', 'auth',
    'token', 'access_token', 'refresh_token',
    'session_key', 'sessionkey', 'share_key', 'sharekey',
    'private_key', 'privatekey', 'license', 'license_blob',
  };

  static const String placeholder = '<redacted>';

  static String _norm(String key) =>
      key.toLowerCase().replaceAll('-', '').replaceAll('_', '');

  static bool isSensitive(String key) {
    final n = _norm(key);
    for (final k in sensitiveKeys) {
      if (_norm(k) == n) return true;
    }
    return false;
  }

  /// 键值对渲染：命中敏感键就脱敏。
  static String kv(String key, Object? value) =>
      '$key=${isSensitive(key) ? placeholder : value}';

  /// 整表渲染。
  static String map(Map<String, Object?> m) {
    final parts = <String>[];
    m.forEach((k, v) => parts.add(kv(k, v)));
    return '{${parts.join(', ')}}';
  }

  /// 敏感值的**可安全输出**的摘要。
  ///
  /// 给出长度 + 前 4 字节的十六进制 + 内容 MD5 的前 8 位。
  /// 足够判断"两次是不是同一个值"，但不泄漏内容本身。
  static String fingerprint(String label, List<int> value) {
    if (value.isEmpty) return '$label=<empty>';
    final head = value
        .take(4)
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    return '$label=<len=${value.length} head=$head…>';
  }
}

/// 日志门面。
///
/// 用法：
/// ```dart
/// final log = Log.get('QQ8');
/// log.i('开始登录，uin=${Redact.kv('uin', uin)}');
/// log.d('tgtgt ${Redact.fingerprint('tgtgt', tgtgt)}');
/// log.e('解密失败', error: e, stack: st);
/// ```
abstract final class Log {
  static final List<LogSink> _sinks = <LogSink>[];

  /// 全局最低级别。
  static LogLevel _minLevel = LogLevel.debug;

  /// 内存缓冲。**始终存在**，导出功能依赖它。
  static final RingLogSink ring = RingLogSink();

  /// 时间源，可注入以便自测产出确定性输出。
  static DateTime Function() clock = DateTime.now;

  static bool _installed = false;

  /// 初始化。幂等，重复调用只更新配置。
  ///
  /// [ringCapacity] 决定内存里保留多少条；[minLevel] 是全局下限。
  static void configure({
    LogLevel minLevel = LogLevel.debug,
    int ringCapacity = 2000,
    List<LogSink>? sinks,
  }) {
    _minLevel = minLevel;
    ring.capacity = ringCapacity;
    if (!_installed) {
      _sinks.add(ring);
      _installed = true;
    }
    if (sinks != null) {
      for (final s in sinks) {
        if (!_sinks.contains(s)) _sinks.add(s);
      }
    }
  }

  /// 当前生效的内存缓冲。
  static RingLogSink get memory => ring;

  /// 注册一个出口。
  static void addSink(LogSink sink) {
    if (!_sinks.contains(sink)) _sinks.add(sink);
  }

  /// 移除一个出口（并 flush）。
  static Future<void> removeSink(LogSink sink) async {
    if (_sinks.remove(sink)) await sink.flush();
  }

  /// flush 所有出口。
  static Future<void> flush() async {
    for (final s in _sinks) {
      await s.flush();
    }
  }

  /// 清空内存缓冲（不影响文件）。
  static void clearMemory() => ring.clear();

  /// 记一条。
  static void log(
    LogLevel level,
    String scope,
    String message, {
    Object? error,
    StackTrace? stack,
  }) {
    if (level.severity < _minLevel.severity) return;
    final record = LogRecord(
      time: clock(),
      level: level,
      scope: scope,
      message: message,
      error: error,
      stack: stack,
    );
    for (final s in _sinks) {
      if (!s.accepts(level)) continue;
      s.write(record);
    }
  }

  /// 取一个带作用域的记录器。
  static Logger get(String scope) => Logger._(scope);
}

/// 带作用域的记录器。
class Logger {
  Logger._(this.scope);

  final String scope;

  void t(String message, {Object? error, StackTrace? stack}) =>
      Log.log(LogLevel.trace, scope, message, error: error, stack: stack);

  void d(String message, {Object? error, StackTrace? stack}) =>
      Log.log(LogLevel.debug, scope, message, error: error, stack: stack);

  void i(String message, {Object? error, StackTrace? stack}) =>
      Log.log(LogLevel.info, scope, message, error: error, stack: stack);

  void w(String message, {Object? error, StackTrace? stack}) =>
      Log.log(LogLevel.warn, scope, message, error: error, stack: stack);

  void e(String message, {Object? error, StackTrace? stack}) =>
      Log.log(LogLevel.error, scope, message, error: error, stack: stack);
}
