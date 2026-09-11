/// 接线层（session_providers）离线自测
///
/// **不联网**：只覆盖「连接之前」的那些判定——地址分类、闸门拒绝、
/// 配置持久化。这些是本次改动里最要紧的一行：如果 `_passGate` 把远端地址
/// 误判成本机，用户会在没有任何风险确认的情况下连上真实服务器。
///
/// 真正握手成功之后的流程由 `tool/chat_store_selftest.dart`（数据层）与
/// `tool/onebot_selftest.dart`（协议层）覆盖，这里不重复。
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/session_providers_selftest.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:qqclient/client_api/session_providers.dart';
import 'package:qqclient/kernel/onebot/backend_profile.dart';
import 'package:qqclient/kernel/safety/safety_gate.dart';
import 'package:riverpod/riverpod.dart';

// ---------------------------------------------------------------------------
// 断言工具（与 tool/chat_store_selftest.dart 同款）
// ---------------------------------------------------------------------------

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  ✓ $name');
  } else {
    _failed++;
    stdout.writeln('  ✗ $name${detail == null ? '' : '  → $detail'}');
  }
}

void checkEq(String name, Object? actual, Object? expected) {
  final ok = jsonEncode(actual) == jsonEncode(expected);
  check(name, ok, ok ? null : '期望 ${jsonEncode(expected)}，实际 ${jsonEncode(actual)}');
}

void section(String t) => stdout.writeln('\n$t');

// ---------------------------------------------------------------------------
// 环境
// ---------------------------------------------------------------------------

late Directory _tmp;

/// `StateNotifier.state` 是 protected，测试里靠子类把它读出来。
///
/// 不把它改成公开 getter（那会污染生产接口），也不经 provider 读
/// （provider 内部的文件路径固定，测不了「指定文件」的落盘行为）。
class _ReadableConfig extends ConnectionConfigNotifier {
  _ReadableConfig(super.file);

  ConnectionConfig get value => state;
}

SafetyGate _newGate() => SafetyGate(
      persistFile: File('${_tmp.path}${Platform.pathSeparator}safety.json'),
    );

ProviderContainer _newContainer({SafetyGate? gate}) {
  final container = ProviderContainer(
    overrides: [
      dataDirProvider.overrideWithValue(_tmp),
      backendRegistryProvider.overrideWithValue(BackendProfileRegistry(const [])),
      safetyGateProvider.overrideWithValue(gate ?? _newGate()),
    ],
  );
  return container;
}

Future<int> main() async {
  _tmp = Directory.systemTemp.createTempSync('session_providers_');
  try {
    await _testAddressClassification();
    await _testBadAddressRejected();
    await _testRemoteAddressNeedsConsent();
    await _testConfigPersistence();
    await _testConfigRoundTrip();
  } finally {
    try {
      _tmp.deleteSync(recursive: true);
    } catch (_) {}
  }

  stdout.writeln('\n${_failed == 0 ? '全部通过' : '有失败'}：'
      '通过 $_passed 项，失败 $_failed 项');
  exit(_failed == 0 ? 0 : 1);
}

// ---------------------------------------------------------------------------
// 用例
// ---------------------------------------------------------------------------

Future<void> _testAddressClassification() async {
  section('1. 地址分类：只有真·本机才算回环');

  check('ws://127.0.0.1:3001 是本机', isLoopbackAddress('ws://127.0.0.1:3001'));
  check('ws://localhost:3001 是本机', isLoopbackAddress('ws://localhost:3001'));
  check('ws://[::1]:3001 是本机', isLoopbackAddress('ws://[::1]:3001'));
  check('前后空格不影响判定', isLoopbackAddress('  ws://127.0.0.1:3001  '));

  // 下面这些全是"看起来像本机"的坑：任何一个被判成本机，
  // 都等于绕过了风险确认。
  check('ws://192.168.1.10:3001 不是本机', !isLoopbackAddress('ws://192.168.1.10:3001'));
  check('ws://10.0.0.5:3001 不是本机', !isLoopbackAddress('ws://10.0.0.5:3001'));
  check('ws://example.com:3001 不是本机', !isLoopbackAddress('ws://example.com:3001'));
  check('ws://127.0.0.1.evil.com 不是本机', !isLoopbackAddress('ws://127.0.0.1.evil.com'));
  check('ws://notlocalhost:3001 不是本机', !isLoopbackAddress('ws://notlocalhost:3001'));
  check('空串不是本机', !isLoopbackAddress(''));
  check('乱码不是本机', !isLoopbackAddress('不是地址'));
}

Future<void> _testBadAddressRejected() async {
  section('2. 地址格式：连之前就被拦下');

  final container = _newContainer();
  final controller = container.read(connectionControllerProvider.notifier);

  await controller.connect(const ConnectionConfig(address: 'http://127.0.0.1:3001'));
  var status = container.read(connectionControllerProvider);
  check('http:// 被拒', status.error != null && status.error!.contains('ws://'),
      status.error);
  check('拒绝后不是忙碌态', !status.busy);
  check('拒绝后没有建立会话', controller.session == null);

  await controller.connect(const ConnectionConfig(address: '随便写的'));
  status = container.read(connectionControllerProvider);
  check('非 URL 被拒', status.error != null && status.error!.contains('地址格式'),
      status.error);
  check('拒绝后仍无会话', controller.session == null);

  await controller.shutdown();
  container.dispose();
}

Future<void> _testRemoteAddressNeedsConsent() async {
  section('3. 远端地址：没开真实服务器模式就必须拒绝');

  final gate = _newGate();
  await gate.load();
  checkEq('默认是离线模式', gate.mode.name, 'offline');

  final container = _newContainer(gate: gate);
  final controller = container.read(connectionControllerProvider.notifier);

  await controller.connect(const ConnectionConfig(address: 'ws://192.168.1.10:3001'));
  final status = container.read(connectionControllerProvider);
  check('被闸门拒绝', status.error != null && status.error!.contains('风险确认'),
      status.error);
  check('拒绝理由提到环境检测', status.error!.contains('环境检测'), status.error);
  check('拒绝后没有建立会话', controller.session == null);
  checkEq('闸门模式没被偷偷改掉', gate.mode.name, 'offline');

  await controller.shutdown();
  container.dispose();
}

Future<void> _testConfigPersistence() async {
  section('4. 连接配置：能落盘、坏文件不拦启动');

  final file = File('${_tmp.path}${Platform.pathSeparator}conn.json');
  final notifier = _ReadableConfig(file);

  check('默认地址是 NapCat 端口', notifier.value.address == kDefaultOneBotAddress);
  check('默认不带令牌', !notifier.value.hasToken);

  await notifier.update(
    address: ' ws://127.0.0.1:3001 ',
    accessToken: 'secret-token',
    tokenInHeader: true,
  );
  check('地址被 trim', notifier.value.address == 'ws://127.0.0.1:3001');
  check('令牌被记住', notifier.value.hasToken);
  check('落盘文件存在', file.existsSync());

  final raw = file.readAsStringSync();
  check('落盘内容含地址', raw.contains('127.0.0.1:3001'));

  // 重开一个 notifier 读回
  final reopened = _ReadableConfig(file);
  await reopened.load();
  checkEq('读回的地址一致', reopened.value.address, 'ws://127.0.0.1:3001');
  checkEq('读回的令牌一致', reopened.value.accessToken, 'secret-token');
  checkEq('读回的令牌位置一致', reopened.value.tokenInHeader, true);

  // 坏文件：不能抛，只能退回默认值
  file.writeAsStringSync('{ 这不是 JSON');
  final broken = _ReadableConfig(file);
  var threw = false;
  try {
    await broken.load();
  } catch (_) {
    threw = true;
  }
  check('坏配置不抛异常', !threw);
  checkEq('坏配置退回默认地址', broken.value.address, kDefaultOneBotAddress);

  // 坏文件不该让配置永远改不回来：update 仍要能写、能再读回
  await broken.update(address: 'ws://127.0.0.1:3001', accessToken: '');
  final afterFix = _ReadableConfig(file);
  await afterFix.load();
  checkEq('坏文件修复后可读回', afterFix.value.address, 'ws://127.0.0.1:3001');

  // 写入失败也不能把异常抛给 UI：把「父目录」做成一个文件来逼出失败。
  final blocker = File('${_tmp.path}${Platform.pathSeparator}blocker');
  blocker.writeAsStringSync('x');
  final blocked = _ReadableConfig(
    File('${blocker.path}${Platform.pathSeparator}conn.json'),
  );
  var writeThrew = false;
  try {
    await blocked.update(address: 'ws://127.0.0.1:3001');
  } catch (_) {
    writeThrew = true;
  }
  check('写入失败不抛异常', !writeThrew);
  checkEq('写入失败后内存状态仍更新', blocked.value.address, 'ws://127.0.0.1:3001');
}

Future<void> _testConfigRoundTrip() async {
  section('5. 令牌去向：只进对的地方');

  const withToken = ConnectionConfig(
    address: 'ws://127.0.0.1:3001',
    accessToken: 'tok',
  );
  final query = withToken.toOneBotConfig();
  checkEq('默认走查询参数', query.tokenInHeader, false);
  checkEq('令牌原样带上', query.accessToken, 'tok');

  const header = ConnectionConfig(
    address: 'ws://127.0.0.1:3001',
    accessToken: 'tok',
    tokenInHeader: true,
  );
  checkEq('可选走 Authorization 头', header.toOneBotConfig().tokenInHeader, true);

  const noToken = ConnectionConfig(address: 'ws://127.0.0.1:3001');
  checkEq('空令牌传 null（不传空串）', noToken.toOneBotConfig().accessToken, null);

  final back = ConnectionConfig.fromJson(withToken.toJson());
  checkEq('JSON 往返：地址', back.address, withToken.address);
  checkEq('JSON 往返：令牌', back.accessToken, withToken.accessToken);
  checkEq('JSON 往返：无令牌时不写多余字段',
      const ConnectionConfig().toJson().containsKey('token'), false);
}
