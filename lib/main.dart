/// QQ Client — 应用入口
///
/// 架构（对标 Telegram TDLib 的分层）：
///   L4 ui/          表现层（Flutter）
///   L3 client_api/  客户端 API 层（对标 td_api）
///   L2 kernel/      协议内核（wlogin TLV / trpc / msf / crypto）
///   L1 infra/       基础设施（字节读写器）
///
/// ## 入口只做三件「必须早于 UI」的事
///
///   1. **定位应用私有目录**——ChatStore 与日志都落在这里。Android 上
///      只能靠 `path_provider` 拿（`Directory.systemTemp` 会被系统清理，
///      用户数据丢了就是丢消息）。
///   2. **把平台能力注入 provider**——L3 是纯 Dart，不允许 import Flutter，
///      所以「目录从哪来」「asset 怎么读」只能由 L4 在这里提供。
///   3. **加载后端适配表**——表是 asset JSON，L2 也不允许 import Flutter，
///      因此必须在 UI 层读出来再注入。
///
/// 这三件事都是「谁来提供平台能力」的问题，答完就 `runApp`，不在这里做业务。
library;

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'client_api/session_providers.dart';
import 'infra/log/log_file.dart';
import 'infra/log/logger.dart';
import 'kernel/onebot/backend_profile.dart';
import 'kernel/safety/safety_gate.dart';
import 'ui/pages/home_page.dart';
import 'ui/theme/telegram_theme.dart';

/// 后端适配表 asset 清单。
///
/// 刻意写死而不是运行时枚举 asset：`AssetManifest` 在 release 构建里
/// 可以被裁剪掉，而这份清单必须稳定——少一张表就等于少一种后端的适配。
const List<String> _backendAssetPaths = [
  'assets/backends/napcat.json',
  'assets/backends/lagrange.json',
  'assets/backends/llonebot.json',
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dataDir = await _resolveDataDir();
  final gate = SafetyGate(
    persistFile: File('${dataDir.path}${Platform.pathSeparator}safety.json'),
  );
  // 必须 await：模式与同意记录没读回来之前就允许连接，等于绕过闸门。
  await gate.load();

  _installLogging(dataDir);
  final registry = await _loadBackendRegistry();

  runApp(
    ProviderScope(
      overrides: [
        dataDirProvider.overrideWithValue(dataDir),
        backendRegistryProvider.overrideWithValue(registry),
        safetyGateProvider.overrideWithValue(gate),
      ],
      child: const QQClientApp(),
    ),
  );
}

/// 应用私有目录。取不到就退回临时目录——可用性优先，
/// 但会在日志里留一条 warn，免得"消息老是丢"查无实据。
Future<Directory> _resolveDataDir() async {
  try {
    return await getApplicationSupportDirectory();
  } catch (e) {
    final fallback = Directory('${Directory.systemTemp.path}/qqclient');
    await fallback.create(recursive: true);
    Log.get('Main').w('取应用私有目录失败，退化到临时目录（数据可能被系统清理）',
        error: e);
    return fallback;
  }
}

void _installLogging(Directory dataDir) {
  Log.configure(
    minLevel: LogLevel.debug,
    ringCapacity: 2000,
    sinks: [
      FileLogSink(
        Directory('${dataDir.path}${Platform.pathSeparator}logs'),
        minLevel: LogLevel.debug,
      ),
    ],
  );
  Log.get('Main').i('日志已启动，数据目录=${dataDir.path}');
}

/// 从 asset 读适配表。
///
/// 读失败不拦启动：注册表本身有 `resolveOrDefault` 兜底（NapCat 表），
/// 少几张表最多是换后端时字段对不上，不该让应用起不来。
Future<BackendProfileRegistry> _loadBackendRegistry() async {
  final sources = <String>[];
  for (final path in _backendAssetPaths) {
    try {
      sources.add(await rootBundle.loadString(path));
    } catch (e) {
      Log.get('Main').w('后端适配表读取失败：$path', error: e);
    }
  }
  try {
    return BackendProfileRegistry.fromJsonStrings(sources);
  } catch (e) {
    // 这里返回的是**空**注册表——它里面连 NapCat 表都没有，所以这句日志
    // 不能写成"回落到兜底表"。真正的最后防线在
    // `BackendProfileRegistry.resolveOrDefault`，它会在注册表为空时退到
    // `BackendProfile.builtinFallback`（无字段映射，但保证客户端起得来）。
    Log.get('Main').e('适配表解析失败，将退到内置兜底表（字段映射不可用）', error: e);
    return BackendProfileRegistry(const []);
  }
}

class QQClientApp extends StatelessWidget {
  const QQClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QQ Client',
      debugShowCheckedModeBanner: false,
      theme: buildTelegramTheme(),
      // 直接进主界面：未连接时主界面自己会引导去连接页，
      // 不让用户每开一次应用都先看一遍连接设置。
      home: const HomePage(),
    );
  }
}
