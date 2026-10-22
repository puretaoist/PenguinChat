/// L3 客户端 API 层：协议线登录服务的 Riverpod 接线（**前端从这里接**）
///
/// 与 `session_providers.dart` 同一套约定：
/// * 只用 `package:riverpod`（不拉 Flutter，AGENTS §1.1）；
/// * 平台相关（数据目录、未来的加密存储）由 `main.dart` 通过
///   `ProviderScope.overrides` 注入，本层不碰 `path_provider`。
///
/// ## 前端怎么用
///
/// ```dart
/// // 读状态（驱动界面）
/// final snap = ref.watch(qq8LoginStateProvider).valueOrNull;
/// switch (snap?.stage) {
///   case Qq8LoginStage.needsSlider:  // 打开 snap.sliderUrl 给人解
///   case Qq8LoginStage.needsSmsCode: // 显示 snap.phone，收码后调 controller
///   case Qq8LoginStage.online:       // 进主界面
///   case Qq8LoginStage.failed:       // 显示 snap.error
///   ...
/// }
///
/// // 调动作
/// ref.read(qq8LoginServiceProvider).loginWithPassword(uin: ..., password: ...);
/// ref.read(qq8LoginServiceProvider).submitSliderTicket(ticket);
/// ```
///
/// 推送：原始帧 `ref.watch(qq8PushesProvider)`（在线后才有）；
/// 结构化事件 `ref.watch(qq8PushEventsProvider)`（收消息/被踢/新消息通知）。
///
/// ## 把协议线当成 UI 的后端（切后端时这么接）
///
/// ```dart
/// final adapter = Qq8SessionAdapter(
///   service: ref.read(qq8LoginServiceProvider), uin: uin);
/// await adapter.connect();   // 用本地票据上线
/// // 之后交给 chat_store / UI：adapter 就是 Session
/// ```
///
/// 口令/滑块/扫码登录仍走 [Qq8LoginService] 的动作（适配器的 `connect()` 只做
/// token 登录），认证完成后套上适配器即可。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:riverpod/riverpod.dart';

import '../infra/device/device_info.dart';
import '../infra/log/logger.dart';
import '../infra/net/media_fetcher.dart';
import '../kernel/wlogin8/qq8_device.dart';
import '../kernel/wlogin8/qq8_profiles.dart';
import '../kernel/wlogin8/qq8_protocol_det.dart';
import '../kernel/wlogin8/qq8_push.dart';
import '../kernel/wlogin8/qq8_qimei.dart';
import '../kernel/wlogin8/qq8_recv.dart';
import '../kernel/wlogin8/qq8_tran.dart';
import 'chat_store.dart';
import 'qq8_device_store.dart';
import 'qq8_login_service.dart';
import 'qq8_session_adapter.dart';
import 'session.dart';
import 'session_providers.dart'
    show
        activeQq8BackendProvider,
        dataDirProvider,
        mediaFetcherProvider,
        safetyGateProvider;

/// 票据存储——**必须由 `main.dart` override 注入**（需要一个可写目录）。
///
/// 例：`qq8TokenStoreProvider.overrideWithValue(FileQq8TokenStore(dir))`
final qq8TokenStoreProvider = Provider<Qq8TokenStore>(
  (ref) => throw UnimplementedError(
      'qq8TokenStoreProvider 必须被 override（见 main.dart：注入数据目录）'),
);

/// 使用的客户端档案（默认见 [qq8DefaultProfile]，**可在登录页直接切换**）。
///
/// 为什么做成可写的：服务端的裁决与"我们自称哪个版本/ssoVer"强相关
/// （8.2.11 → `type=1`，8.9.50/9.3.60 → `type=45`，见 `docs/PITFALLS.md` C8），
/// 而每试一档都要真机跑一次。做成可切换后一次安装就能把档案矩阵跑完，
/// 不必为每个变体各发一版包。
///
/// 切换会重建 [qq8LoginServiceProvider]（档案是服务的构造参数），
/// 所以切换后必须重新发起登录——**不能**在登录流程中途换。
final qq8ProfileProvider = StateProvider<Qq8ClientProfile>(
  (ref) => qq8DefaultProfile,
);

/// 传输层构造器——测试可 override 成脚本传输；生产就是真实 TCP。
final qq8TransportBuilderProvider = Provider<Qq8Transport Function()>(
  (ref) => () => Qq8TcpTransport(),
);

/// 真机身份材料——**优先级三级**，取到第一个可用的就停。
///
/// ```text
///   ① identity.json（人工导出，含官方客户端用过的 guid/QIMEI）
///         ↓ 不存在
///   ② 本机自采：DeviceInfo 快照 + <dataDir>/qq8/device.json 里持久的三项
///         ↓ 采不到
///   ③ null → 上层退回 Qq8Device.generate(uin) 合成派生
/// ```
///
/// ## 为什么要 ②（这是 2026-10-22 的改动）
///
/// ① 要求用户 adb push 一个文件，App 内根本没有导入界面（`grep -rn identity
/// lib/ui/` 零命中）——等于这条路只有我们能走，用户走不了。
///
/// 而 ③ 的合成设备有两个硬伤：**在现实里不存在**（`brand=OICQX`、
/// `model=Konata 2020` 不是任何厂商的机型）与**自相矛盾**（自称 Android 10
/// 却跑在 Android 16 上）。服务端一比对机型库就知道是假的。
///
/// ② 用官方 `util` 同一套系统 API 读真值（见 `DeviceProbe.kt`），
/// 机型、指纹、boot_id、/proc/version、基带全部真实。
///
/// ## ⚠️ 不要指望 ② 能等于官方
///
/// Android 8+ 的 `ANDROID_ID` 按「应用签名 + 用户 + 设备」隔离，官方 QQ 与 TIM
/// 装在同一台机器上都读到不同的值（`25cf6881290b58f7` vs `f23dd554a9f43c9a`）。
/// 换签名就是第三个值——**这个目标本身不成立**。② 的意义是"整台设备是真的"，
/// 不是"冒充官方那一个 android_id"。
///
/// ## 三个必须持久化的值
///
/// 见 [Qq8DeviceState]：`androidId`（读不到时官方生成 15 位随机数字）、
/// `ksid`（服务端 `0x108` 下发）、`qimei`（灯塔签发）。任何一个每次现算，
/// 都会让设备标识在两次启动之间漂移。
final qq8DeviceIdentityProvider = Provider<Qq8DeviceIdentity?>((ref) {
  final log = Log.get('QQ8');
  final dir = ref.watch(dataDirProvider);
  final f = File(
      '${dir.path}${Platform.pathSeparator}qq8${Platform.pathSeparator}identity.json');
  if (!f.existsSync()) return null;
  try {
    final decoded = jsonDecode(f.readAsStringSync());
    if (decoded is! Map) {
      log.w('identity.json 不是 JSON 对象，忽略（保持合成派生）');
      return null;
    }
    final id = Qq8DeviceIdentity.fromJson(Map<String, Object?>.from(decoded));
    if (id == null) {
      log.w('identity.json 缺必需项 android_id / mac，忽略（保持合成派生）');
      return null;
    }
    log.i('已加载真机身份: $id');
    return id;
  } catch (e) {
    log.w('identity.json 解析失败，忽略（保持合成派生）', error: e);
    return null;
  }
});

/// 设备状态存储（`<dataDir>/qq8/device.json`）。
final qq8DeviceStoreProvider = Provider<Qq8DeviceStore>((ref) {
  final dir = ref.watch(dataDirProvider);
  return FileQq8DeviceStore(
      Directory('${dir.path}${Platform.pathSeparator}qq8'));
});

/// 解析最终生效的设备身份（**启动路径调用一次**，结果注入
/// [qq8DeviceIdentityProvider] 的 override）。
///
/// 为什么放在启动路径而不是做成 `FutureProvider`：`androidId` 必须在第一帧
/// UI 之前确定。放进异步 provider 就意味着它会有 `loading` 态，而下游
/// `deviceBuilder` 是同步的——只能在"还没采到"和"采到了"之间来回切换，
/// 那期间建出来的设备 guid 是不同的（`guid = MD5(androidId ‖ mac)`），
/// 等于一次启动里出现了两台设备。
///
/// 一次 `MethodChannel` 往返 + 一次几百字节的文件读，代价可以忽略。
///
/// ## 参数
/// * [dataDir] — 应用私有目录（`device.json` 放在它的 `qq8/` 子目录）。
/// * [deviceInfo] — 平台采集实现；桌面/测试传 [NoopDeviceInfo] 即可。
/// * [log] — 可选日志器（默认 `Log.get('QQ8')`）。
Future<Qq8DeviceIdentity?> resolveQq8DeviceIdentity({
  required Directory dataDir,
  required DeviceInfo deviceInfo,
  Logger? log,
}) async {
  final l = log ?? Log.get('QQ8');
  final store = FileQq8DeviceStore(
      Directory('${dataDir.path}${Platform.pathSeparator}qq8'));

  // ---- ① identity.json（人工注入，含官方用过的 guid/qimei）----
  final idFile = File(
      '${dataDir.path}${Platform.pathSeparator}qq8${Platform.pathSeparator}identity.json');
  if (idFile.existsSync()) {
    try {
      final decoded = jsonDecode(idFile.readAsStringSync());
      if (decoded is Map) {
        final id =
            Qq8DeviceIdentity.fromJson(Map<String, Object?>.from(decoded));
        if (id != null) {
          l.i('设备身份来源: identity.json（人工注入）→ $id');
          return id;
        }
        l.w('identity.json 缺必需项 android_id / mac，继续走本机采集');
      } else {
        l.w('identity.json 不是 JSON 对象，继续走本机采集');
      }
    } catch (e) {
      l.w('identity.json 解析失败，继续走本机采集', error: e);
    }
  }

  // ---- ② 本机自采 + 持久状态 ----
  final state = store.loadSync();
  DeviceSnapshot? snap;
  try {
    snap = await deviceInfo.snapshot();
  } catch (e) {
    // snapshot 自己保证不抛，这里只是双保险：采集失败不该阻断启动。
    l.w('设备信息采集异常，按无快照处理', error: e);
  }

  if (snap == null) {
    // 采集不到（桌面 / 通道缺失）。但历史上可能已经存过 androidId ——
    // 那时仍然能构造出"稳定的部分身份"吗？不行：没有机型/指纹，
    // 造出来的只会是半真半假的设备，比全合成更可疑。所以直接返回 null。
    l.i('设备身份来源: 无（采集不到本机信息）→ 退回合成派生');
    return null;
  }

  // androidId 缺失时照官方 `getRandomAndroidId` 生成 15 位数字并**立刻落盘**。
  var androidId = state.androidId;
  if ((snap.androidId == null || snap.androidId!.isEmpty) &&
      (androidId == null || androidId.isEmpty)) {
    androidId = qq8RandomAndroidId();
    store.saveSync(Qq8DeviceState(androidId: androidId));
    l.i('系统 ANDROID_ID 读不到，按官方风格生成 15 位随机数并持久化');
  }

  final id = Qq8DeviceIdentity.fromSnapshot(
    snap,
    androidIdFallback: androidId,
    ksid: state.ksid,
    qimei: state.qimei,
  );
  if (id == null) {
    l.w('快照里没有可用的 androidId，退回合成派生');
    return null;
  }
  l.i('设备身份来源: 本机采集 → $id');
  return id;
}


/// 历史登录出口 IP 缓存（官方 `ProtocolDet` / `files/pd2.dat`）的读取接缝。
///
/// 官方每次登录成功后往 `pd2.dat` 追加一条「uin + 出口 IP + 时间 + subAppId」，
/// 下次登录把最近至多 3 条塞进 `0x525` 内嵌的 `0x536`。官方真机的密码登录
/// **成功**样本里这块是 65 字节（3 条）；本方此前恒发 `01 00`（0 条），
/// 等于每次都对服务端自称「全新环境」。
///
/// ## 文件位置
///
/// App 自己的 `pd2.dat` 放在 `<dataDir>/qq8/pd2.dat`。它可以是：
/// * **从官方客户端抄来的**（最优——直接复用服务端已认的出口历史）；
/// * 本方自己累积的（每次登录成功后追加，需要 [protocolDetRecorder]）。
///
/// 文件不存在 / 读失败 → 返回 null → TLV 层退回官方空形态 `01 00`。
/// **不会阻断登录**（官方 ProtocolDet 自己也把异常吞成 `01 00`）。
final qq8ProtocolDetProvider = Provider<Uint8List?>((ref) {
  final log = Log.get('QQ8');
  final dir = ref.watch(dataDirProvider);
  final f = File('${dir.path}${Platform.pathSeparator}qq8'
      '${Platform.pathSeparator}${Qq8ProtocolDet.cacheFileName}');
  if (!f.existsSync()) return null;
  try {
    final raw = f.readAsBytesSync();
    final entries = Qq8ProtocolDet.decodeFile(raw);
    if (entries.isEmpty) {
      log.w('pd2.dat 存在但解不出条目（${raw.length} 字节），按无历史处理');
      return null;
    }
    log.i('pd2.dat: ${entries.length} 条历史出口 '
        '(${entries.map((e) => e.ipText).join(', ')})');
    return Qq8ProtocolDet.encode(entries);
  } catch (e) {
    log.w('pd2.dat 读取失败，按无历史处理', error: e);
    return null;
  }
});

/// 把服务端下发的 `ksid` / 灯塔签发的 `qimei` 落进 `<dataDir>/qq8/device.json`。
///
/// ## 为什么这一步不能省
///
/// 这两个值都是「拿到一次、之后永久复用」的：
/// * `ksid` — 服务端 `0x108` 下发，官方 `util.set_ksid` 只在 SP 为空时写；
/// * `qimei` — 灯塔按设备属性签发，官方缓存在 `DENGTA_META` / `QimeiSDK`。
///
/// 丢掉它们的后果不对称：`ksid` 尤其糟糕，因为它**要登录成功才下发**，
/// 一旦丢了就形成死循环——失败 → 没有 ksid → 更像新设备 → 失败。
///
/// 写盘失败只记日志，绝不影响登录（与 `pd2.dat` 同一原则）。
void _recordDeviceState(
  Ref ref, {
  String? ksid,
  String? qimei,
}) {
  if (ksid == null && qimei == null) return;
  final log = Log.get('QQ8');
  try {
    final store = ref.read(qq8DeviceStoreProvider);
    final current = store.loadSync();
    store.saveSync(current.copyWith(ksid: ksid, qimei: qimei));
  } catch (e) {
    log.w('设备状态落盘失败（不影响登录）', error: e);
  }
}

/// 登录成功后把服务端下发的 `0x537` 并进 `<dataDir>/qq8/pd2.dat`。
///
/// 照官方 `ProtocolDet.updateCachedExtraDataFile`：不满 3 条就追加，
/// 满了就**替换 mTime 最小的那条**（不是 FIFO 轮转）。
///
/// 写盘失败只记日志，绝不影响登录（官方也把异常吞掉）。
void _recordProtocolDetEntry(Ref ref, Qq8ProtocolDetEntry entry) {
  final log = Log.get('QQ8');
  final dir = ref.read(dataDirProvider);
  final f = File('${dir.path}${Platform.pathSeparator}qq8'
      '${Platform.pathSeparator}${Qq8ProtocolDet.cacheFileName}');
  try {
    final existing = f.existsSync()
        ? Qq8ProtocolDet.decodeFile(f.readAsBytesSync())
        : const <Qq8ProtocolDetEntry>[];
    final merged = Qq8ProtocolDet.merge(existing, entry);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(Qq8ProtocolDet.encodeFile(merged));
    // 让下次登录的 protocolDetBuilder 立刻看到新内容。
    ref.invalidate(qq8ProtocolDetProvider);
    log.i('pd2.dat 已更新: ${existing.length} → ${merged.length} 条');
  } catch (e) {
    log.w('pd2.dat 写盘失败（不影响登录）', error: e);
  }
}

/// 登录/会话服务实例（随 provider 生命周期创建与关闭）。
///
/// 注入与 OneBot 线**同一个** [safetyGateProvider]：协议线的联网前置校验
/// （真实服务器模式 + 有效同意）由它把关，见 [Qq8LoginService.gate]。
final qq8LoginServiceProvider = Provider<Qq8LoginService>((ref) {
  final identity = ref.watch(qq8DeviceIdentityProvider);
  final profile = ref.watch(qq8ProfileProvider);
  // 档案必须进日志：服务端的裁决与"我们自称哪个版本"直接相关
  //（2026-09-21 的 type=45 版本门就是这么看出来的），但日志里原先没有这一行。
  // ⚠️ 用 [Qq8ClientProfile.describe]：该类**没有**重写 toString()，
  // 第一版写成 `$profile` 只印出 `Instance of 'Qq8ClientProfile'`（等于没记）。
  Log.get('QQ8').i('客户端档案: ${profile.describe()}');
  final svc = Qq8LoginService(
    profile: profile,
    tokenStore: ref.watch(qq8TokenStoreProvider),
    transportBuilder: ref.watch(qq8TransportBuilderProvider),
    gate: ref.watch(safetyGateProvider),
    // 有真机身份就用它，否则沿用默认的 uin 派生
    deviceBuilder:
        identity == null ? null : (int uin) => Qq8Device.fromIdentity(identity),
    qimei: identity?.qimei,
    // 身份文件没带 QIMEI 时自动向灯塔取号（纯 HTTPS，无需 root/hook，
    // 见 `lib/kernel/wlogin8/qq8_qimei.dart`）。取号只提交设备属性，
    // 不含 uin/口令/票据；失败就整条 0x545 不发，不阻断登录。
    // 设备由服务层传进来（用的是它自己那台，保证 guid 与登录包一致）。
    qimeiFetcher: identity?.qimei != null
        ? null
        : (Qq8Device device) => Qq8Qimei.fetch(
              device: device,
              apk: profile.apk,
              beaconAppKey: profile.beaconAppKey,
              onLog: (line) => Log.get('QQ8').d('QIMEI 取号: $line'),
            ).then((r) => r.q16),
    // 0x525 内嵌 0x536：历史登录出口 IP（官方 ProtocolDet）。
    // 没有 pd2.dat 时返回 null → TLV 层退回官方空形态 `01 00`。
    protocolDetBuilder: () => ref.read(qq8ProtocolDetProvider),
    // 登录成功后把服务端下发的 0x537 并进 pd2.dat（官方同位置行为）。
    protocolDetRecorder: (entry) => _recordProtocolDetEntry(ref, entry),
    // 设备状态回写：ksid（服务端 0x108 下发）与 QIMEI（灯塔签发）都必须落盘，
    // 否则每次启动都是一台"新设备"。官方同位置行为见 `util.set_ksid`
    // （只在 SP 为空时写）与 QIMEI 的 SP 缓存。
    deviceStateRecorder: ({String? ksid, String? qimei}) =>
        _recordDeviceState(ref, ksid: ksid, qimei: qimei),
  );
  ref.onDispose(() => svc.close());
  return svc;
});

/// 当前状态快照流（UI 直接 watch；首个事件前的 loading 用 `.valueOrNull` 兜）。
final qq8LoginStateProvider = StreamProvider<Qq8LoginSnapshot>(
  (ref) => ref.watch(qq8LoginServiceProvider).states,
);

/// 服务端推送（只在 [Qq8LoginStage.online] 阶段有内容）。
///
/// 刻意依赖状态：未上线时给空流，上线后才接上会话层的广播流——
/// 这样 UI 不必关心"什么时候才有推送"。
final qq8PushesProvider = StreamProvider<Qq8SsoResponse>((ref) {
  final stage = ref.watch(qq8LoginStateProvider).valueOrNull?.stage;
  if (stage != Qq8LoginStage.online) {
    return const Stream<Qq8SsoResponse>.empty();
  }
  return ref.watch(qq8LoginServiceProvider).pushes;
});

/// 推送解析后的事件流：收到消息 / 被踢下线 / 新消息通知（UI 用这条）。
///
/// 与 [qq8PushesProvider] 的分工：那条是原始帧（排障），这条是结构化事件。
/// 服务层始终在解析（"被踢下线"要改状态），所以这里不按阶段过滤。
final qq8PushEventsProvider = StreamProvider<Qq8PushEvent>((ref) {
  return ref.watch(qq8LoginServiceProvider).events;
});

// ---------------------------------------------------------------------------
// 协议线后端：连接控制器（UI 用这个驱动登录，不必自己拼动作）
// ---------------------------------------------------------------------------

/// 协议线连接状态（UI 直接渲染这个）。
class Qq8ConnectStatus {
  /// 登录状态机的当前阶段。
  final Qq8LoginStage stage;

  /// 当前账号（发起登录后才有值）。
  final int? uin;

  /// 滑动验证地址（[Qq8LoginStage.needsSlider] 时）。
  final String? sliderUrl;

  /// 短信验证的手机号，以及"服务端已自动下发"标记。
  final String? phone;
  final bool smsAutoSent;

  /// 这次短信验证是"手机号短信登录"（true）还是"密码登录后补短信"（false）。
  final bool smsFlow;

  /// 设备锁提示语（[Qq8LoginStage.needsDeviceLock] 时）。
  final String? deviceLockHint;

  /// 二维码内容与扫码状态一句话（[Qq8LoginStage.waitingQrScan] 时）。
  final Uint8List? qrToken;
  final String? qrMessage;

  /// 失败原因（已转成给人看的话）。
  final String? error;

  /// 有动作在跑（UI 该禁用按钮）。
  final bool busy;

  const Qq8ConnectStatus({
    required this.stage,
    this.uin,
    this.sliderUrl,
    this.phone,
    this.smsAutoSent = false,
    this.smsFlow = false,
    this.deviceLockHint,
    this.qrToken,
    this.qrMessage,
    this.error,
    this.busy = false,
  });

  static const idle = Qq8ConnectStatus(stage: Qq8LoginStage.idle);

  bool get isOnline => stage == Qq8LoginStage.online;

  /// 需要人做点什么（UI 据此弹对应的表单）。
  bool get needsHumanAction =>
      stage == Qq8LoginStage.needsSlider ||
      stage == Qq8LoginStage.needsSmsCode ||
      stage == Qq8LoginStage.needsDeviceLock ||
      stage == Qq8LoginStage.waitingQrScan;

  String get stateLabel => switch (stage) {
        Qq8LoginStage.idle => '未连接',
        Qq8LoginStage.connecting => '连接中…',
        Qq8LoginStage.needsSlider => '需要完成滑动验证',
        Qq8LoginStage.needsSmsCode => '需要短信验证码',
        Qq8LoginStage.needsDeviceLock => '需要设备锁验证',
        Qq8LoginStage.waitingQrScan => '等待扫码确认',
        Qq8LoginStage.online => '已上线',
        Qq8LoginStage.disconnected => '已断开',
        Qq8LoginStage.failed => '登录失败',
      };
}

/// 协议线的连接控制器：把 [Qq8LoginService] 的多步认证搬给 UI。
///
/// 与 OneBot 那条（`ConnectionController`）的区别：协议线登录是**多步交互**
/// （口令 → 滑块/短信/设备锁，或扫码），所以这里把每一步都开成独立动作，
/// UI 按 [Qq8ConnectStatus.stage] 渲染对应表单。
///
/// 上线成功后自动套 [Qq8SessionAdapter] 并建 [ChatStore]——此后与 OneBot 那条
/// **完全同构**：`sessionProvider` / `chatStoreProvider` 都会切过来。
class Qq8ConnectController extends StateNotifier<Qq8ConnectStatus> {
  Qq8ConnectController({
    required this.service,
    required this.dataDir,
    this.log,
    this.onBackendChanged,
    this.mediaFetcher,
  }) : super(Qq8ConnectStatus.idle) {
    _sub = service.states.listen(_onSnapshot);
    _onSnapshot(service.snapshot);
  }

  /// 被桥接的登录服务（需要更细的控制时可直接用它）。
  final Qq8LoginService service;

  /// ChatStore 的落盘位置。
  final Directory dataDir;

  /// 媒体下载器；null = 只读已有缓存不联网。
  final MediaFetcher? mediaFetcher;

  /// 日志回调。
  final void Function(String level, String message, [Object? detail])? log;

  /// 上线/断开时把"当前后端"报出去（UI 侧的 sessionProvider 靠它切换）。
  final void Function(Qq8SessionAdapter? session, ChatStore? store)?
      onBackendChanged;

  StreamSubscription<Qq8LoginSnapshot>? _sub;
  Qq8LoginSnapshot _snap = const Qq8LoginSnapshot(stage: Qq8LoginStage.idle);
  bool _busy = false;
  Qq8SessionAdapter? _adapter;
  ChatStore? _store;

  /// 当前状态（`StateNotifier.state` 是 protected，这里开个公开读口，
  /// 给"直接持有控制器"的调用方与测试用；provider 消费方 watch 即可）。
  Qq8ConnectStatus get status => state;

  /// 上线后的 Session（未上线为 null）。
  Session? get session => _adapter;

  /// 上线后的数据层（未上线为 null）。
  ChatStore? get store => _store;

  /// 口令登录（口令只在本进程内转 MD5，不落盘）。
  Future<void> loginWithPassword(int uin, String password) =>
      _run(() => service.loginWithPassword(uin: uin, password: password));

  /// 用本地票据登录（不需要口令）。
  Future<void> loginWithToken(int uin) =>
      _run(() => service.loginWithToken(uin: uin));

  /// 提交滑动验证票据（人工在浏览器解出来之后填回来）。
  Future<void> submitSliderTicket(String ticket) =>
      _run(() => service.submitSliderTicket(ticket));

  /// 手机号短信登录第一步：检查手机号（子命令 17，不需要 uin）。
  Future<void> loginWithPhone(String phone) =>
      _run(() => service.loginWithPhone(phone: phone));

  /// 手机号短信登录：请求下发验证码（子命令 19）。
  Future<void> refreshSmsLoginCode() =>
      _run(() => service.refreshSmsLoginCode());

  /// 手机号短信登录：提交验证码（子命令 18，通过后服务自动续一次口令登录）。
  Future<void> submitSmsLoginCode(String code) =>
      _run(() => service.submitSmsLoginCode(code));

  /// 请求下发短信验证码（密码登录那条线的子命令 8）。
  Future<void> requestSmsCode() => _run(() => service.requestSmsCode());

  /// 提交短信验证码。
  Future<void> submitSmsCode(String code) =>
      _run(() => service.submitSmsCode(code));

  /// 设备锁解锁。
  Future<void> unlockDevice() => _run(() => service.unlockDevice());

  /// 取登录二维码（扫码登录第一步）。
  Future<void> fetchQrcode() => _run(() => service.fetchQrcode());

  /// 轮询扫码状态（UI 按秒级节奏调）。
  Future<void> pollQrcode() => _run(() => service.pollQrcode());

  /// 断开并回到未连接（票据保留，下次可 [loginWithToken]）。
  Future<void> disconnect() async {
    await _teardown();
    await service.close();
    _snap = const Qq8LoginSnapshot(stage: Qq8LoginStage.idle);
    _emit();
  }

  /// provider 释放时调用（不抛异常）。
  Future<void> shutdown() async {
    try {
      await _sub?.cancel();
      await _teardown();
    } catch (e) {
      log?.call('warn', '释放协议线资源时出错', e);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    _emit();
    try {
      await action();
    } on Object catch (e) {
      // 服务自己会把失败写进快照（stage=failed + error），这里只兜底日志
      log?.call('warn', '协议线动作失败', e);
    } finally {
      _busy = false;
      _onSnapshot(service.snapshot);
    }
  }

  void _onSnapshot(Qq8LoginSnapshot s) {
    _snap = s;
    if (s.stage == Qq8LoginStage.online && _adapter == null) {
      unawaited(_attach());
    }
    _emit();
  }

  /// 上线后：套适配器 + 建数据层（幂等）。
  Future<void> _attach() async {
    if (!mounted || _adapter != null) return;
    final adapter = Qq8SessionAdapter(
      service: service,
      uin: _snap.uin,
      onLog: (level, message, [detail]) => log?.call(level, message, detail),
    );
    final store = ChatStore(
      session: adapter,
      dataDir: dataDir,
      mediaFetcher: mediaFetcher,
    );
    await store.bootstrap();
    _adapter = adapter;
    _store = store;
    onBackendChanged?.call(adapter, store);
    log?.call('info', '协议线已上线 uin=${_snap.uin}，会话数=${store.chats.length}');
    _emit();
  }

  Future<void> _teardown() async {
    await _store?.dispose();
    await _adapter?.dispose();
    _store = null;
    _adapter = null;
    onBackendChanged?.call(null, null);
  }

  void _emit() {
    if (!mounted) return;
    state = Qq8ConnectStatus(
      stage: _snap.stage,
      uin: _snap.uin,
      sliderUrl: _snap.sliderUrl,
      phone: _snap.phone,
      smsAutoSent: _snap.smsAutoSent,
      smsFlow: _snap.smsFlow,
      deviceLockHint: _snap.deviceLockHint,
      qrToken: _snap.qrToken,
      qrMessage: _snap.qrMessage,
      error: _snap.error,
      busy: _busy,
    );
  }
}

/// 协议线的连接控制器（生命周期随 provider）。
final qq8ConnectControllerProvider =
    StateNotifierProvider<Qq8ConnectController, Qq8ConnectStatus>((ref) {
  final controller = Qq8ConnectController(
    service: ref.watch(qq8LoginServiceProvider),
    dataDir: ref.watch(dataDirProvider),
    mediaFetcher: ref.read(mediaFetcherProvider),
    log: (level, message, [detail]) => Log.get('Qq8Connect')
        .i('[$level] $message${detail == null ? '' : ' · $detail'}'),
    onBackendChanged: (session, store) {
      ref.read(activeQq8BackendProvider.notifier).state =
          session == null || store == null
              ? null
              : (session: session, store: store);
    },
  );
  ref.onDispose(controller.shutdown);
  return controller;
});
