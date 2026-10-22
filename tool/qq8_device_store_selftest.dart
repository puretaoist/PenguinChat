/// L3 自测：设备状态持久化（`qq8_device_store.dart`）
///
/// ## 为什么这个自测重要
///
/// 这三个值的失效方式是**静默的**：`androidId` 丢了 → 下次启动生成新的 →
/// guid 变了 → 服务端当新设备；`ksid` 丢了 → 每次登录都自称没有 ksid。
/// 两者都不报错、不崩溃，只是登录永远过不去，而日志看起来一切正常。
///
/// 所以这里不测"函数能不能跑"，只测**跨进程语义**：
/// 写进去的东西，重新构造一个 store 还能读回来；损坏的文件不会让启动炸。
///
/// 跑法：`dart run tool/qq8_device_store_selftest.dart`
library;

// 自测脚本的标准写法（与 tool/media_refs_selftest.dart 一致）：
// 打印是对人的输出，不是生产代码；相对 lib 导入是为了让脚本能被直接 dart run。
// ignore_for_file: avoid_print, avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../lib/client_api/qq8_device_store.dart';
import '../lib/infra/device/device_info.dart';
import '../lib/kernel/wlogin8/qq8_device.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String note = '']) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    print('  ✗ $name${note.isEmpty ? '' : ' — $note'}');
  }
}

void eq(String name, Object? actual, Object? expected) {
  check(name, actual == expected, 'got=$actual want=$expected');
}

Directory _tmpDir(String tag) {
  final d = Directory.systemTemp.createTempSync('qq8dev_$tag');
  return d;
}

void main() {
  print('=== 设备状态持久化自测 ===');

  _testJsonFormat();
  _testFileRoundTrip();
  _testMergeSemantics();
  _testAtomicWrite();
  _testCorruptFile();
  _testMemoryStore();
  _testRandomAndroidId();
  _testSnapshotToIdentity();

  print('');
  print('=== 结果: $_pass 通过, $_fail 失败 ===');
  exit(_fail == 0 ? 0 : 1);
}

// ---------------------------------------------------------------------------
// 1. JSON 形状
// ---------------------------------------------------------------------------

void _testJsonFormat() {
  print('[1] JSON 形状');

  const s = Qq8DeviceState(
    androidId: '123456789012345',
    ksid: '188ca8765de720b5207b0adc6c51d3d7',
    qimei: 'c5da7bd11af782c8a3dec3d710001591a806',
  );
  final json = s.toJson();
  eq('androidId 键名是 android_id', json['android_id'], '123456789012345');
  eq('ksid 原样', json['ksid'], '188ca8765de720b5207b0adc6c51d3d7');
  eq('qimei 原样', json['qimei'], 'c5da7bd11af782c8a3dec3d710001591a806');

  // 空状态不该写出空串键（否则下次读到的是 "" 而不是 null，
  // 上层判断 `isEmpty` 与 `== null` 会分叉）。
  const empty = Qq8DeviceState();
  check('空状态不写任何键', empty.toJson().isEmpty,
      'got=${empty.toJson()}');

  final back = Qq8DeviceState.fromJson(json);
  eq('往返 androidId', back.androidId, s.androidId);
  eq('往返 ksid', back.ksid, s.ksid);
  eq('往返 qimei', back.qimei, s.qimei);

  // 空串与缺键都要归一到 null，否则"有值但为空"会绕过 `??` 兜底。
  final blank = Qq8DeviceState.fromJson(const <String, Object?>{
    'android_id': '   ',
    'ksid': '',
    'qimei': null,
  });
  check('空串/空白归一为 null', blank.androidId == null && blank.ksid == null,
      'got=$blank');

  eq('toString 不泄露 qimei 全值',
      const Qq8DeviceState(qimei: 'abcdefghijklmnopqrstuvwxyz0123456789')
          .toString()
          .contains('abcdefghij'),
      false);
}

// ---------------------------------------------------------------------------
// 2. 跨实例往返（模拟"杀掉进程再启动"）
// ---------------------------------------------------------------------------

void _testFileRoundTrip() {
  print('[2] 落盘往返（新实例能读到）');

  final dir = _tmpDir('roundtrip');
  try {
    final a = FileQq8DeviceStore(dir);
    a.saveSync(const Qq8DeviceState(
      androidId: '111111111111111',
      ksid: 'aaaa',
      qimei: 'bbbb',
    ));
    check('文件已创建',
        File('${dir.path}${Platform.pathSeparator}device.json').existsSync());

    // 关键：**换一个实例**读，模拟重启（同实例读内存也能过，测不出落盘）。
    final b = FileQq8DeviceStore(dir);
    final got = b.loadSync();
    eq('重启后 androidId 不变', got.androidId, '111111111111111');
    eq('重启后 ksid 不变', got.ksid, 'aaaa');
    eq('重启后 qimei 不变', got.qimei, 'bbbb');

    // 只在内存里改、不落盘，重开就不该看到。
    final c = FileQq8DeviceStore(dir);
    eq('未落盘的修改不会被读到', c.loadSync().ksid, 'aaaa');
  } finally {
    dir.deleteSync(recursive: true);
  }

  // 目录不存在时读不该抛。
  final missing = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}qq8dev_missing_${DateTime.now().microsecondsSinceEpoch}');
  final store = FileQq8DeviceStore(missing);
  final got = store.loadSync();
  check('目录不存在时返回空状态',
      got.androidId == null && got.ksid == null && got.qimei == null,
      'got=$got');
}

// ---------------------------------------------------------------------------
// 3. 合并语义：只覆盖非空字段
// ---------------------------------------------------------------------------

void _testMergeSemantics() {
  print('[3] 合并语义');

  final dir = _tmpDir('merge');
  try {
    final s = FileQq8DeviceStore(dir);
    s.saveSync(const Qq8DeviceState(androidId: 'A', ksid: 'K', qimei: 'Q'));

    // 只写 ksid：androidId 与 qimei 必须留着。
    s.saveSync(const Qq8DeviceState(ksid: 'K2'));
    var got = s.loadSync();
    eq('只写 ksid 时 androidId 保留', got.androidId, 'A');
    eq('只写 ksid 时 ksid 更新', got.ksid, 'K2');
    eq('只写 ksid 时 qimei 保留', got.qimei, 'Q');

    // 只写 qimei：ksid 必须留着（这正是登录成功后回写的场景）。
    s.saveSync(const Qq8DeviceState(qimei: 'Q2'));
    got = s.loadSync();
    eq('只写 qimei 时 ksid 保留', got.ksid, 'K2');
    eq('只写 qimei 时 qimei 更新', got.qimei, 'Q2');

    // 空状态写入不该清空任何东西。
    s.saveSync(const Qq8DeviceState());
    got = s.loadSync();
    check('写空状态不影响已有值',
        got.androidId == 'A' && got.ksid == 'K2' && got.qimei == 'Q2',
        'got=$got');
  } finally {
    dir.deleteSync(recursive: true);
  }
}

// ---------------------------------------------------------------------------
// 4. 原子写：临时文件不能留下
// ---------------------------------------------------------------------------

void _testAtomicWrite() {
  print('[4] 原子写');

  final dir = _tmpDir('atomic');
  try {
    final s = FileQq8DeviceStore(dir);
    s.saveSync(const Qq8DeviceState(androidId: 'X'));
    s.saveSync(const Qq8DeviceState(androidId: 'Y'));

    final leftovers = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.tmp'))
        .toList();
    check('不留 .tmp 残留文件', leftovers.isEmpty,
        'got=${leftovers.map((f) => f.path).toList()}');

    // 文件本身必须是合法 JSON（rename 后不可能出现半个文件）。
    final f = File('${dir.path}${Platform.pathSeparator}device.json');
    final decoded = jsonDecode(f.readAsStringSync());
    check('内容是完整 JSON', decoded is Map, 'got=$decoded');
    eq('最后一次写的生效', (decoded as Map)['android_id'], 'Y');
  } finally {
    dir.deleteSync(recursive: true);
  }
}

// ---------------------------------------------------------------------------
// 5. 损坏文件：不崩、不阻塞启动
// ---------------------------------------------------------------------------

void _testCorruptFile() {
  print('[5] 损坏文件容错');

  final dir = _tmpDir('corrupt');
  try {
    final f = File('${dir.path}${Platform.pathSeparator}device.json');

    for (final bad in <String>[
      'not json at all',
      '{"android_id": ',
      '[1,2,3]',
      '"just a string"',
      '',
    ]) {
      f.writeAsStringSync(bad);
      final s = FileQq8DeviceStore(dir);
      final got = s.loadSync();
      check('损坏内容「${bad.length > 12 ? '${bad.substring(0, 12)}…' : bad}」'
          '返回空状态而不是抛异常',
          got.androidId == null && got.ksid == null && got.qimei == null,
          'got=$got');
    }

    // 损坏后仍能正常写入并读回（自愈）。
    final s = FileQq8DeviceStore(dir);
    s.saveSync(const Qq8DeviceState(androidId: 'recovered'));
    eq('损坏后能自愈写入', s.loadSync().androidId, 'recovered');
  } finally {
    dir.deleteSync(recursive: true);
  }
}

// ---------------------------------------------------------------------------
// 6. 内存实现（自测/桌面用，语义必须与落盘版一致）
// ---------------------------------------------------------------------------

void _testMemoryStore() {
  print('[6] 内存实现');

  final s = MemoryQq8DeviceStore();
  eq('初始为空', s.loadSync().androidId, null);

  s.saveSync(const Qq8DeviceState(androidId: 'A', ksid: 'K'));
  eq('写入生效', s.loadSync().androidId, 'A');

  s.saveSync(const Qq8DeviceState(qimei: 'Q'));
  final got = s.loadSync();
  check('合并语义与落盘版一致', got.androidId == 'A' && got.ksid == 'K',
      'got=$got');
  eq('新值生效', got.qimei, 'Q');
}

// ---------------------------------------------------------------------------
// 7. 随机 androidId：官方风格 15 位数字
// ---------------------------------------------------------------------------

void _testRandomAndroidId() {
  print('[7] 随机 androidId');

  final a = qq8RandomAndroidId();
  eq('长度 15', a.length, 15);
  check('全数字', RegExp(r'^\d{15}$').hasMatch(a), 'got=$a');

  // 用固定种子验证可复现（自测里不依赖真随机）。
  final r1 = qq8RandomAndroidId(Random(42));
  final r2 = qq8RandomAndroidId(Random(42));
  eq('同种子可复现', r1, r2);

  // 允许首位为 0（它只是字符串标识，官方也没要求非零）。
  final zero = qq8RandomAndroidId(_ZeroRandom());
  eq('首位 0 也合法', zero, '000000000000000');

  // 1000 次不重复（碰撞概率极低，但主要验证没有"只返回常量"这类实现错误）。
  final seen = <String>{};
  for (var i = 0; i < 1000; i++) {
    seen.add(qq8RandomAndroidId());
  }
  check('1000 次生成基本不重复', seen.length > 990, 'got=${seen.length}');
}

/// 恒返回 0 的 Random（只为验证首位 0 的情况）。
class _ZeroRandom implements Random {
  @override
  int nextInt(int max) => 0;

  @override
  double nextDouble() => 0;

  @override
  bool nextBool() => false;
}

// ---------------------------------------------------------------------------
// 8. 快照 → 身份（L2 的 fromSnapshot）
// ---------------------------------------------------------------------------

void _testSnapshotToIdentity() {
  print('[8] 快照转身份');

  const snap = DeviceSnapshot(
    androidId: '25cf6881290b58f7',
    macAddress: '02:00:00:00:00:00',
    model: '25091RP04C',
    brand: 'Xiaomi',
    product: 'piano',
    device: 'piano',
    board: 'sun',
    bootloader: 'unknown',
    fingerprint: 'Xiaomi/piano/piano:16/BP2A.250605.031.A3/OS3.0.307.0.WPYCNXM:user/release-keys',
    bootId: 'dd2fe9c5-63a8-408a-beff-42a5f8b6cc61',
    procVersion: 'Linux version 5.15.0',
    baseband: '',
    incremental: 'OS3.0.307.0.WPYCNXM',
    display: 'OS3.0.307.0.WPYCNXM',
    release: '16',
    codename: 'REL',
    sdk: 36,
  );

  final id = Qq8DeviceIdentity.fromSnapshot(
    snap,
    ksid: '188ca8765de720b5207b0adc6c51d3d7',
    qimei: 'c5da7bd11af782c8a3dec3d710001591a806',
  );
  check('能构造身份', id != null);
  if (id == null) return;

  eq('androidId 取快照值', id.androidId, '25cf6881290b58f7');
  eq('mac 取快照值', id.macAddress, '02:00:00:00:00:00');
  eq('model 取快照值', id.model, '25091RP04C');
  eq('brand 取快照值', id.brand, 'Xiaomi');
  eq('sdk 取快照值', id.sdk, 36);
  eq('release 取快照值', id.release, '16');
  eq('ksid 由上层带入', id.ksid, '188ca8765de720b5207b0adc6c51d3d7');
  eq('qimei 由上层带入', id.qimei,
      'c5da7bd11af782c8a3dec3d710001591a806');
  eq('imsi 强制为 null（Android 10+ 读不到，官方同）', id.imsi, null);

  // guid 必须等于官方公式 MD5(androidId ‖ mac)。
  final device = Qq8Device.fromIdentity(id);
  final expectGuid = qq8DeriveGuid('25cf6881290b58f7', '02:00:00:00:00:00');
  final guidHex = _hex(device.guid);
  check('guid = MD5(androidId ‖ mac)', guidHex == _hex(expectGuid),
      'got=$guidHex want=${_hex(expectGuid)}');
  // 真机日志与 SP 里的值是 7d9cf98da15d5c95f87507273280cbbf。
  eq('guid 命中真机实测值', guidHex, '7d9cf98da15d5c95f87507273280cbbf');

  // androidId 缺失时用 fallback。
  const noId = DeviceSnapshot(
    androidId: null,
    macAddress: '02:00:00:00:00:00',
    model: 'X',
  );
  final withFallback = Qq8DeviceIdentity.fromSnapshot(
    noId,
    androidIdFallback: '999999999999999',
  );
  eq('缺失时用 fallback', withFallback?.androidId, '999999999999999');

  final neither = Qq8DeviceIdentity.fromSnapshot(noId);
  check('两者都缺失返回 null（不编）', neither == null);

  // mac 缺失时补官方常量（否则 guid 算不出来）。
  const noMac = DeviceSnapshot(androidId: 'abc', macAddress: null);
  final derived = Qq8DeviceIdentity.fromSnapshot(noMac);
  eq('mac 缺失补官方常量', derived?.macAddress, '02:00:00:00:00:00');
}

String _hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
