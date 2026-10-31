/// 免密恢复：失效范围（scoped invalidation）与材料门槛的离线自测。
///
/// 覆盖 lib/client_api/qq8_token_store.dart 的 invalidatedMaterial /
/// materialKnownInvalid / markInvalidated / evaluateValidity，以及
/// lib/client_api/recovery_planner.dart 的 fromToken 过滤与 verified 门槛。
/// 纯离线：不联网、不需要账号、不建连接。
///
/// 运行：dart run tool/qq8_recovery_scope_selftest.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/client_api/qq8_token_store.dart';
import 'package:qqclient/client_api/recovery_planner.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  OK  $name${detail == null ? '' : '   ($detail)'}');
  } else {
    _fail++;
    stdout.writeln('  NG  $name${detail == null ? '' : '  ($detail)'}');
  }
}

Uint8List _b(int n, [int fill = 0x11]) =>
    Uint8List.fromList(List<int>.filled(n, fill));

Qq8TokenData _base({bool a1 = false, bool noPicSig = false}) => Qq8TokenData(
      uin: 10001,
      savedAt: '2026-10-31T00:00:00.000',
      tgt: _b(72),
      d2: _b(64),
      d2key: _b(16),
      sigKey: _b(16, 0x22),
      ticketKey: _b(16, 0x33),
      srmToken: _b(16, 0x44),
      a1: a1 ? _b(152) : Uint8List(0),
      noPicSig: noPicSig ? _b(80) : null,
    );

Qq8RecoveryAvailability _avail(Qq8TokenData t) =>
    Qq8RecoveryAvailability.fromToken(t);

Future<void> main() async {
  stdout.writeln('== 恢复材料失效范围自测 ==');

  stdout.writeln('');
  stdout.writeln('[1] materialKnownInvalid：没有失效记录时一律 false');
  {
    final t = _base();
    check('未失效 -> d2Key 不算失效', !t.materialKnownInvalid(Qq8TokenData.materialD2Key));
    check('未失效 -> a1NoPicSig 不算失效',
        !t.materialKnownInvalid(Qq8TokenData.materialA1NoPicSig));
  }

  stdout.writeln('');
  stdout.writeln('[2] legacy 整票语义：有失效时刻但没有材料字段');
  {
    final t = _base().markInvalidated(atMs: 1761800000000, type: 16);
    check('legacy -> d2Key 失效', t.materialKnownInvalid(Qq8TokenData.materialD2Key));
    check('legacy -> a2Key 失效', t.materialKnownInvalid(Qq8TokenData.materialA2Key));
    check('legacy -> a1NoPicSig 失效',
        t.materialKnownInvalid(Qq8TokenData.materialA1NoPicSig));
    check('legacy -> a2Only 失效', t.materialKnownInvalid(Qq8TokenData.materialA2Only));
    check('legacy -> evaluateValidity = invalidated',
        t.evaluateValidity(DateTime(2026, 10, 31)) == Qq8TokenValidity.invalidated);
  }

  stdout.writeln('');
  stdout.writeln('[3] scoped 语义：只否掉那一条材料');
  {
    final t = _base(a1: true, noPicSig: true).markInvalidated(
        atMs: 1761800000000, type: 16, material: Qq8TokenData.materialD2Key);
    check('scoped d2Key -> d2Key 失效', t.materialKnownInvalid(Qq8TokenData.materialD2Key));
    check('scoped d2Key -> a1NoPicSig 仍可用',
        !t.materialKnownInvalid(Qq8TokenData.materialA1NoPicSig));
    check('scoped d2Key -> evaluateValidity 不再一刀切 invalidated',
        t.evaluateValidity(DateTime(2026, 10, 31)) != Qq8TokenValidity.invalidated);
    check('scoped d2Key -> recoveryUsable 仍为 true（材料还在）', t.recoveryUsable);
  }

  stdout.writeln('');
  stdout.writeln('[4] markInvalidated 精确覆盖（copyWith 做不到）');
  {
    final once = _base().markInvalidated(
        atMs: 1000, type: 16, material: Qq8TokenData.materialA2Key);
    final twice = once.markInvalidated(
        atMs: 2000, type: 155, material: Qq8TokenData.materialD2Key);
    check('第二次写入了新的失效时刻', twice.invalidatedAtMs == 2000);
    check('第二次写入了新的返回码', twice.invalidatedType == 155);
    check('第二次把材料范围改成 d2Key',
        twice.invalidatedMaterial == Qq8TokenData.materialD2Key);
    check('旧材料的失效结论已被替换（a2Key 不再算失效）',
        !twice.materialKnownInvalid(Qq8TokenData.materialA2Key));
    final cleared = twice.markInvalidated(atMs: 3000, type: 16);
    check('markInvalidated 不带 material -> 回到 legacy 整票',
        cleared.invalidatedMaterial == null &&
            cleared.materialKnownInvalid(Qq8TokenData.materialA1NoPicSig));
  }

  stdout.writeln('');
  stdout.writeln('[5] fromToken 按失效范围过滤可用材料');
  {
    final t = _base(a1: true, noPicSig: true).markInvalidated(
        atMs: 1761800000000, type: 16, material: Qq8TokenData.materialD2Key);
    final a = _avail(t);
    check('d2Key 被否掉', !a.has(Qq8RecoveryMaterial.d2Key));
    check('a1NoPicSig 仍可用', a.has(Qq8RecoveryMaterial.a1NoPicSig));
    check('hasA2 仍在（tgt 没丢）', a.hasA2);
    final d = planNext(
        a: a,
        tried: const <Qq8RecoveryMaterial>{},
        networkError: false,
        challengeActive: false);
    check('默认模式：只剩未验证的 a1NoPicSig -> Stop(unverified)',
        d is Qq8RecoveryStop && d.code == 'unverified');
    final d2 = planNext(
        a: a,
        tried: const <Qq8RecoveryMaterial>{},
        networkError: false,
        challengeActive: false,
        allowUnverifiedMaterials: true);
    check('显式允许后改选 a1NoPicSig（不再因 d2Key 失效而整体放弃）',
        d2 is Qq8RecoveryAttempt &&
            d2.material == Qq8RecoveryMaterial.a1NoPicSig);
  }

  stdout.writeln('');
  stdout.writeln('[6] JSON 往返：invalidated_material 保留');
  {
    final t = _base().markInvalidated(
        atMs: 1761800000000, type: 16, material: Qq8TokenData.materialA1NoPicSig);
    final j = t.toJson();
    check('toJson 含 invalidated_material',
        j['invalidated_material'] == Qq8TokenData.materialA1NoPicSig);
    final back = Qq8TokenData.fromJson(
        jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
    check('往返后材料范围一致',
        back.invalidatedMaterial == Qq8TokenData.materialA1NoPicSig);
    check('往返后失效时刻/返回码一致',
        back.invalidatedAtMs == 1761800000000 && back.invalidatedType == 16);
    final legacyJson = <String, dynamic>{
      'uin': 1,
      'saved_at': 'x',
      'tgt': 'aa',
      'd2': 'bb',
      'd2key': 'cc',
      'sig_key': 'dd',
      'ticket_key': 'ee',
      'srm_token': 'ff',
      'invalidated_at_ms': 5,
    };
    final legacy = Qq8TokenData.fromJson(legacyJson);
    check('旧文件缺 invalidated_material -> null（legacy 整票）',
        legacy.invalidatedMaterial == null &&
            legacy.materialKnownInvalid(Qq8TokenData.materialD2Key));
  }

  stdout.writeln('');
  stdout.writeln('[7] 原子落盘：save 后能读回，且不留 .tmp');
  {
    final dir = await Directory.systemTemp.createTemp('qq8_scope_');
    try {
      final store = FileQq8TokenStore(dir);
      final t = _base().markInvalidated(
          atMs: 1761800000000, type: 155, material: Qq8TokenData.materialD2Key);
      await store.save(t);
      final back = await store.load(10001);
      check('读回票据非空', back != null);
      check('读回失效范围一致',
          back!.invalidatedMaterial == Qq8TokenData.materialD2Key);
      check('读回失效返回码一致', back.invalidatedType == 155);
      final left = dir
          .listSync()
          .where((e) => e.path.endsWith('.tmp'))
          .toList();
      check('目录里没有残留 .tmp 文件', left.isEmpty, 'left=${left.length}');
      await store.save(t.copyWith());
      final again = await store.load(10001);
      check('二次保存覆盖后仍可读（rename 覆盖生效）', again != null);
    } finally {
      await dir.delete(recursive: true);
    }
  }

  stdout.writeln('');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  if (_fail > 0) exitCode = 1;
}