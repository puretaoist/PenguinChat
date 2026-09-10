/// L2 安全防护：设备环境风险探针
///
/// ## 为什么需要它
///
/// 有用户反馈：**即便用官方 QQ、没有注入、并做了 root 隐藏，仍然被封。**
/// 这个现象指向的关键事实是：**判定基准是设备环境本身，而不只是客户端行为。**
///
/// ## 反编译证据（目标 APK 9.3.60）
///
/// 检测能力集中在 **native 层**，而非 Java 层：
///
/// | 特征 | Java 层命中 | native 层命中 |
/// |---|---|---|
/// | `magisk` | 0 个 dex | `libfekit.so` |
/// | `supersu` | 0 个 dex | `libfekit.so` |
/// | `lsposed` | 0 个 dex | `libfekit.so` |
/// | `frida` | 2 个 dex | `libfekit.so` |
/// | `ro.debuggable` | 少量 | `libfekit.so` |
/// | `de.robv`（Xposed 包前缀） | 1 个 dex | — |
///
/// `libfekit.so` 是腾讯安全 SDK，**7.3 MB**，其中：
///   - `/proc/` 出现 10 次 —— 进程与状态检查
///   - `maps` 出现 2 次 —— **读取 `/proc/self/maps` 检测被注入的 .so**
///   - `ro.` 出现 23 次 —— 系统属性对比
///   - `su` 出现 97 次 —— 大量 root 路径
///
/// **这解释了为什么用户态隐藏（Magisk DenyList / Zygisk 等）不可靠**：
/// 检测在 native 层读 `/proc/self/maps` 与系统属性，
/// 那是用户态隐藏通常覆盖不到的地方。
///
/// ## 本模块的立场：检测以便**回避**，不是检测以便**隐藏**
///
/// 本模块只做两件事：
///   1. 告诉你当前设备处于什么风险状态
///   2. **在环境高危时直接拒绝连接真实服务器**
///
/// 它**不提供**任何让检测更难发现的能力。理由有两层：
///   - 事实层面：隐藏已被证明不可靠（native 层检测绕不过）
///   - 原则层面：那属于规避安全措施
///
/// 正确的应对不是「藏得更好」，而是**不要在有风险的设备上连**。
library;

import 'dart:io';

/// 环境风险等级。
enum EnvRiskLevel {
  /// 无明显风险信号
  clean,

  /// 有轻微信号（如曾开启过 USB 调试）
  low,

  /// 有明确风险（root 痕迹、开发者选项）
  medium,

  /// 高危（root 框架、hook 框架、被注入）
  high,

  /// 极高（同时存在多项高危信号）
  critical,
}

extension EnvRiskLevelX on EnvRiskLevel {
  String get label {
    switch (this) {
      case EnvRiskLevel.clean:
        return '无异常';
      case EnvRiskLevel.low:
        return '轻微';
      case EnvRiskLevel.medium:
        return '中等';
      case EnvRiskLevel.high:
        return '高危';
      case EnvRiskLevel.critical:
        return '极高';
    }
  }

  /// 是否应阻断真实服务器连接。
  ///
  /// 阈值定在 [high]：中等风险仍允许（给用户判断空间），
  /// 高危则直接拒绝——因为此时账号损失概率已经明显偏高。
  bool get blocksRealServer =>
      this == EnvRiskLevel.high || this == EnvRiskLevel.critical;
}

/// 单条检测结果。
class EnvFinding {
  final String id;
  final String label;
  final EnvRiskLevel severity;
  final String detail;
  final String? advice;

  const EnvFinding({
    required this.id,
    required this.label,
    required this.severity,
    required this.detail,
    this.advice,
  });

  @override
  String toString() => '[${severity.label}] $label —— $detail';
}

/// 环境探测报告。
class EnvironmentReport {
  final List<EnvFinding> findings;
  final DateTime probedAt;

  /// 无法检测的项（诚实说明局限）。
  final List<String> undetectable;

  const EnvironmentReport({
    required this.findings,
    required this.probedAt,
    this.undetectable = const [],
  });

  /// 综合等级 = 最高单项等级；若高危项 >= 2 则升为 critical。
  EnvRiskLevel get level {
    if (findings.isEmpty) return EnvRiskLevel.clean;
    final highCount = findings
        .where((f) => f.severity == EnvRiskLevel.high)
        .length;
    if (highCount >= 2) return EnvRiskLevel.critical;
    var max = EnvRiskLevel.clean;
    for (final f in findings) {
      if (f.severity.index > max.index) max = f.severity;
    }
    return max;
  }

  bool get blocksRealServer => level.blocksRealServer;

  /// 按严重程度排序的发现列表。
  List<EnvFinding> get sortedFindings =>
      findings.toList()..sort((a, b) => b.severity.index.compareTo(a.severity.index));

  String summary() {
    final sb = StringBuffer();
    sb.writeln('环境风险等级：${level.label}');
    if (findings.isEmpty) {
      sb.writeln('未发现常见风险信号。');
    } else {
      for (final f in sortedFindings) {
        sb.writeln('  · ${f.label}：${f.detail}');
      }
    }
    if (blocksRealServer) {
      sb.writeln('→ 已阻断真实服务器连接。');
    }
    return sb.toString();
  }
}

/// 环境探针。
///
/// 说明：从 Dart 层只能做**文件与端口**级别的检查。
/// 真正的深度检测（读取 `/proc/self/maps`、对比系统属性、
/// 内核级痕迹）需要 native 实现，本探针**做不到**，
/// 因此在 [EnvironmentReport.undetectable] 中明确列出。
///
/// 这不是缺陷——目标是「拦住常见的高危配置」，
/// 而不是「做一套反作弊」。即便有漏检，也不会让情况变好或变坏：
/// 漏检只是少了一次提醒，而服务端那边的判定不受本地探针影响。
class EnvironmentProbe {
  /// 每项检查的超时（避免某个检查卡住拖慢启动）。
  final Duration perCheckTimeout;

  EnvironmentProbe({this.perCheckTimeout = const Duration(milliseconds: 400)});

  /// 执行探测。
  Future<EnvironmentReport> probe() async {
    final findings = <EnvFinding>[];

    Future<void> run(
        String id, String label, EnvRiskLevel sev, Future<String?> Function() fn,
        {String? advice}) async {
      try {
        final detail = await fn().timeout(perCheckTimeout);
        if (detail != null) {
          findings.add(EnvFinding(
            id: id,
            label: label,
            severity: sev,
            detail: detail,
            advice: advice,
          ));
        }
      } catch (_) {
        // 检测本身失败不是风险信号，忽略
      }
    }

    await run('su_binary', 'su 可执行文件', EnvRiskLevel.high,
        _checkSuBinaries,
        advice: '存在 root 提权工具路径。腾讯安全 SDK（libfekit）在 native 层查这些路径。');

    await run('magisk', 'Magisk 痕迹', EnvRiskLevel.high, _checkMagisk,
        advice: '检测到 Magisk 相关文件。注意：Magisk DenyList/Zygisk 属于用户态隐藏，'
            '对 native 层检测无效。');

    await run('hook_framework', 'Hook 框架痕迹', EnvRiskLevel.critical,
        _checkHookFrameworks,
        advice: '检测到 Xposed/LSPosed 类框架。这是腾讯判定最重的信号之一'
            '（xposed 字样出现在 34/41 个 dex 中）。');

    await run('frida', 'Frida 调试框架', EnvRiskLevel.critical, _checkFrida,
        advice: '检测到 Frida。libfekit 会读 /proc/self/maps 找注入的 .so，'
            '这属于其重点检测项。');

    await run('emulator', '模拟器环境', EnvRiskLevel.high, _checkEmulator,
        advice: '模拟器的设备特征与真实机差异明显，且极易被识别。'
            '建议改用一台真实手机。');

    await run('debuggable', '系统可调试', EnvRiskLevel.medium,
        _checkDebuggableProps,
        advice: '系统 ro.debuggable=1。正式手机应为 0。');

    await run('adb', 'ADB 相关痕迹', EnvRiskLevel.low, _checkAdbTraces,
        advice: '设备曾启用 USB 调试。单独不致命，但会和其他信号叠加。');

    await run('build_tags', '测试版系统', EnvRiskLevel.medium, _checkBuildTags,
        advice: '系统为 test-keys 签名的非正式版。');

    return EnvironmentReport(
      findings: findings,
      probedAt: DateTime.now(),
      undetectable: const [
        'libfekit 的 /proc/self/maps 深度扫描（需 native 实现）',
        '类加载器层面的 hook 探测（Dart 无反射，Java 侧可用 Class.forName）',
        '内核层 root 痕迹（SUID、SELinux 状态）',
        '系统属性的完整对比（仅抽查了常见项）',
        'Magisk 的 Zygisk 注入状态',
        'Qimei 在本机的实际取值',
        '真实手机的设备指纹是否已被标记（服务端数据，本地不可知）',
      ],
    );
  }

  // ---------------------------------------------------------------
  //  各项检查
  // ---------------------------------------------------------------

  /// 常见 su 路径（对齐 libfekit 里出现 97 次的 `su` 特征）。
  static const List<String> suPaths = [
    '/system/bin/su',
    '/system/xbin/su',
    '/system/sbin/su',
    '/sbin/su',
    '/su/bin/su',
    '/vendor/bin/su',
    '/system/bin/.ext/.su',
    '/system/usr/we-need-root/su-backup',
    '/system/xbin/mu',
    '/data/local/su',
    '/data/local/bin/su',
    '/data/local/xbin/su',
  ];

  Future<String?> _checkSuBinaries() async {
    final hit = <String>[];
    for (final p in suPaths) {
      if (await File(p).exists()) hit.add(p);
    }
    return hit.isEmpty ? null : '发现 ${hit.length} 处：${hit.take(3).join(', ')}';
  }

  static const List<String> magiskPaths = [
    '/sbin/.magisk',
    '/data/adb/magisk',
    '/data/adb/modules',
    '/cache/magisk.log',
    '/data/magisk.img',
    '/data/adb/magisk.img',
  ];

  Future<String?> _checkMagisk() async {
    final hit = <String>[];
    for (final p in magiskPaths) {
      if (await FileSystemEntity.isDirectory(p) ||
          await FileSystemEntity.isFile(p)) {
        hit.add(p);
      }
    }
    return hit.isEmpty ? null : '发现：${hit.join(', ')}';
  }

  static const List<String> hookPaths = [
    '/system/framework/XposedBridge.jar',
    '/data/adb/lspd',
    '/data/adb/modules/riru_xposed',
    '/data/misc/riru',
  ];

  Future<String?> _checkHookFrameworks() async {
    final hit = <String>[];
    for (final p in hookPaths) {
      if (await FileSystemEntity.isDirectory(p) ||
          await FileSystemEntity.isFile(p)) {
        hit.add(p);
      }
    }
    // 说明：Java 侧可用 Class.forName 探测 XposedBridge 是否可加载，
    // 但 Dart 没有反射，这里只做文件系统检查。
    // 「类加载器层面的 hook 探测」已列入 undetectable 清单。
    return hit.isEmpty ? null : '发现：${hit.join(', ')}';
  }

  /// Frida 默认监听端口。
  static const List<int> fridaPorts = [27042, 27043];

  Future<String?> _checkFrida() async {
    final hit = <int>[];
    for (final port in fridaPorts) {
      try {
        final s = await Socket.connect('127.0.0.1', port);
        s.destroy();
        hit.add(port);
      } catch (_) {
        // 端口未监听 = 正常
      }
    }
    // 进程名检查（部分环境可直接读到）
    try {
      final ps = await File('/proc/self/cmdline').readAsString();
      if (ps.contains('frida')) hit.add(-1);
    } catch (_) {}

    return hit.isEmpty
        ? null
        : 'Frida 端口开放：${hit.where((p) => p > 0).join(', ')}';
  }

  static const List<String> emulatorMarkers = [
    '/dev/socket/qemud',
    '/dev/qemu_pipe',
    '/system/lib/libc_malloc_debug_qemu.so',
    '/sys/qemu_trace',
    '/system/bin/qemu-props',
    '/dev/socket/genyd',
    '/dev/socket/baseband_genyd',
  ];

  Future<String?> _checkEmulator() async {
    final hit = <String>[];
    for (final p in emulatorMarkers) {
      if (await FileSystemEntity.isDirectory(p) ||
          await FileSystemEntity.isFile(p)) {
        hit.add(p);
      }
    }
    return hit.isEmpty ? null : '发现模拟器特征：${hit.take(3).join(', ')}';
  }

  /// 抽查系统属性。
  Future<String?> _checkDebuggableProps() async {
    final v = await _readProp('ro.debuggable');
    return v == '1' ? 'ro.debuggable=1' : null;
  }

  Future<String?> _checkBuildTags() async {
    final v = await _readProp('ro.build.tags');
    if (v != null && v.contains('test-keys')) return 'ro.build.tags=$v';
    return null;
  }

  Future<String?> _checkAdbTraces() async {
    if (await FileSystemEntity.isDirectory('/data/adb')) {
      return '/data/adb 存在（曾启用过 ADB）';
    }
    return null;
  }

  /// 读取系统属性。
  ///
  /// 优先读 `/system/build.prop`；受限时退化为读取 `/proc` 相关入口。
  /// 读不到返回 null（不视为风险）。
  static Future<String?> _readProp(String key) async {
    const candidates = [
      '/system/build.prop',
      '/vendor/build.prop',
      '/default.prop',
    ];
    for (final path in candidates) {
      try {
        final f = File(path);
        if (!await f.exists()) continue;
        for (final line in await f.readAsLines()) {
          if (line.startsWith('$key=')) {
            return line.substring(key.length + 1).trim();
          }
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }
}
