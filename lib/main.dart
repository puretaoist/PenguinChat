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

import 'client_api/qq8_providers.dart';
import 'client_api/qq8_token_store.dart';
import 'client_api/session_providers.dart';
import 'infra/device/device_info.dart';
import 'infra/lifecycle/keep_alive.dart';
import 'infra/log/log_file.dart';
import 'infra/log/logger.dart';
import 'kernel/onebot/backend_profile.dart';
import 'kernel/safety/safety_gate.dart';
import 'ui/lifecycle/keep_alive_scope.dart';
import 'ui/lifecycle/message_notify_scope.dart';
import 'ui/pages/app_bootstrap.dart';
import 'ui/prefs/ui_prefs.dart';
import 'ui/platform/android_device_info.dart';
import 'ui/platform/foreground_keep_alive.dart';
import 'ui/theme/telegram_theme.dart';
import 'ui/theme/theme_mode.dart';

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

  // 设备信息采集（只在 Android 有实现）。
  final deviceInfo =
      Platform.isAndroid ? AndroidDeviceInfo() : const NoopDeviceInfo();

  // 先把「这一版 APK 到底带了什么」写进日志。有一次真机日志里整段新代码的
  // 痕迹都看不到，最后靠解包 APK 翻 dex 才确认装的是旧包 —— 那次排查本可省掉。
  final deviceTag = await deviceInfo.buildTag();
  Log.get('Main').i(
    '设备采集: 构建=${deviceTag ?? "无原生实现（非 Android 或通道缺失）"}',
  );

  // 设备身份必须在这里定下来，不能交给异步 provider —— 理由见
  // `resolveQq8DeviceIdentity` 的文档：androidId 进 guid 派生
  // （`guid = MD5(androidId ‖ mac)`），异步就会在一次启动里先后出现两台设备。
  final deviceIdentity = await resolveQq8DeviceIdentity(
    dataDir: dataDir,
    deviceInfo: deviceInfo,
  );
  Log.get('Main').i(
    '设备身份已确定: ${deviceIdentity == null ? "无（将退回合成派生）" : "有（本机采集或人工注入）"}',
  );

  runApp(
    ProviderScope(
      overrides: [
        dataDirProvider.overrideWithValue(dataDir),
        backendRegistryProvider.overrideWithValue(registry),
        safetyGateProvider.overrideWithValue(gate),
        // 协议线的票据存储：需要可写目录（不注入会在首次 watch 时抛错 → 白屏）
        qq8TokenStoreProvider.overrideWithValue(
          FileQq8TokenStore(Directory('${dataDir.path}${Platform.pathSeparator}qq8')),
        ),
        // 设备身份：null 表示"采不到 → 让上层退回合成派生"，这是合法状态，
        // 所以必须 override（不 override 的话 provider 会自己去读 identity.json，
        // 绕过这里的优先级判断）。
        qq8DeviceIdentityProvider.overrideWithValue(deviceIdentity),
        deviceInfoProvider.overrideWithValue(deviceInfo),
        // 后台保活：只有 Android 有前台服务这个概念。
        // 桌面端注入 Noop 而不是直接留默认值——留默认值也一样，但显式写出来
        // 能让"这条能力只在 Android 生效"这件事在代码里可见。
        keepAliveProvider.overrideWithValue(
          Platform.isAndroid ? ForegroundKeepAlive() : const NoopKeepAlive(),
        ),
      ],
      // KeepAliveScope 必须在 MaterialApp 外面：它不需要 context、不参与布局，
      // 而前台服务是进程级资源，整个应用只能有一个观察者。
      // MessageNotifyScope 同理（订阅 ChatStore + 应用生命周期 → 系统通知）。
      child: const KeepAliveScope(
        child: MessageNotifyScope(child: QQClientApp()),
      ),
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

class QQClientApp extends ConsumerWidget {
  const QQClientApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 调色板是全局单例：根组件每次 build 先把"当前生效的那套"设好，
    // 之后这一帧里所有 `TelegramColors.xxx` 读到的就是它。
    // 其它页面自己也调了一次（applyThemePalette），避免谁先重建谁读到旧值。
    final dark = applyThemePalette(ref);
    // 字号倍率作用在根 MediaQuery 上：整个应用（含后续 push 的页面）一起变，
    // 不需要每个 Text 各自算一遍。
    final fontScale = ref.watch(uiPrefsProvider).fontScale;
    return MaterialApp(
      title: 'QQ Client',
      debugShowCheckedModeBanner: false,
      theme: buildTelegramTheme(dark: dark),
      builder: (BuildContext context, Widget? child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(fontScale)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      // 冷启动先放品牌页，等账号恢复有结论（或超时）再淡入主界面。
      // 这段"其实正在登录"的时间以前是一片空态，用户会以为连不上。
      home: const AppBootstrap(),
    );
  }
}
