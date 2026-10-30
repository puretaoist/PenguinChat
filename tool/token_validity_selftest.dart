/// 票据有效期元数据 + 可用性判据离线自测（`lib/client_api/qq8_token_store.dart`）
///
/// 只测**纯函数与文件往返**，不联网、不需要账号：
/// * 新字段的 JSON 往返 / 旧文件（缺键）向后兼容；
/// * `evaluateValidity` 的五个分支（invalidated / expired / expiringSoon / valid / unknown）；
/// * `copyWith` 传 null 保持原值（这是"标记失效"能用的前提）；
/// * `FileQq8TokenStore` 落盘→读回后新字段仍在。
///
/// 运行：
/// ```bash
/// dart run tool/token_validity_selftest.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/client_api/qq8_token_store.dart';
import 'package:qqclient/kernel/wlogin8/qq8_login.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✓ $name${detail == null ? '' : '   ($detail)'}');
  } else {
    _fail++;
    stdout.writeln('  ✗ $name${detail == null ? '' : '   ($detail)'}');
  }
}

Uint8List _b(int n, [int fill = 0x11]) => Uint8List.fromList(List<int>.filled(n, fill));

Qq8TokenData _base() => Qq8TokenData(
      uin: 10001,
      savedAt: '2026-10-30T00:00:00.000',
      tgt: _b(72),
      d2: _b(64),
      d2key: _b(16),
      sigKey: _b(16, 0x22),
      ticketKey: _b(16, 0x33),
      srmToken: _b(16, 0x44),
    );

Future<void> main() async {
  stdout.writeln('== 票据有效期自测 ==');

  // ---------------------------------------------------------------
  stdout.writeln('\n[1] 默认值：没有元数据时是 unknown，且仍 usable');
  {
    final t = _base();
    check('旧票（无时长元数据）→ evaluateValidity = unknown',
        t.evaluateValidity(DateTime(2026, 10, 30)) == Qq8TokenValidity.unknown);
    check('usable 仍按 d2/d2key 非空判断（不受元数据影响）', t.usable);
    check('invalidated 默认 false', !t.invalidated);
    check('新字段默认全 null',
        t.issuedAtMs == null &&
            t.renewedAtMs == null &&
            t.expireAtMs == null &&
            t.serverTimeMs == null &&
            t.lifetimeTlvHex == null &&
            t.invalidatedAtMs == null &&
            t.invalidatedType == null);
  }

  // ---------------------------------------------------------------
  stdout.writeln('\n[2] evaluateValidity 五分支');
  {
    const now = 1761800000000; // 固定时刻，别用 DateTime.now()
    final n = DateTime.fromMillisecondsSinceEpoch(now);

    final expiring = _base().copyWith(expireAtMs: now + 10 * 60 * 1000);
    check('10 分钟后到期 → expiringSoon',
        expiring.evaluateValidity(n) == Qq8TokenValidity.expiringSoon);

    final fresh = _base().copyWith(expireAtMs: now + 5 * 60 * 60 * 1000);
    check('5 小时后到期 → valid',
        fresh.evaluateValidity(n) == Qq8TokenValidity.valid);

    final dead = _base().copyWith(expireAtMs: now - 1);
    check('已过到期时间 → expired',
        dead.evaluateValidity(n) == Qq8TokenValidity.expired);

    final bad = _base().copyWith(invalidatedAtMs: now - 1000, invalidatedType: 16);
    check('服务端判过失效 → invalidated（优先于 valid）',
        bad.evaluateValidity(n) == Qq8TokenValidity.invalidated);
    check('invalidated getter 与元数据一致', bad.invalidated);

    final both = _base()
        .copyWith(expireAtMs: now + 60 * 60 * 1000, invalidatedAtMs: now);
    check('同时有到期时间与失效标记 → 仍报 invalidated',
        both.evaluateValidity(n) == Qq8TokenValidity.invalidated);
  }

  // ---------------------------------------------------------------
  stdout.writeln('\n[3] copyWith：传 null 保持原值（标记失效的前提）');
  {
    final t = _base().copyWith(issuedAtMs: 111, renewedAtMs: 222, lifetimeTlvHex: 'aabb');
    final marked = t.copyWith(invalidatedAtMs: 333, invalidatedType: 155);
    check('标记失效不会清掉原有时间戳',
        marked.issuedAtMs == 111 && marked.renewedAtMs == 222);
    check('标记失效不会清掉诊断 hex', marked.lifetimeTlvHex == 'aabb');
    check('invalidatedType 正确写入', marked.invalidatedType == 155);
    check('再次 copyWith 不传该字段时保留失效标记',
        marked.copyWith(renewedAtMs: 444).invalidatedAtMs == 333);
    check('copyWith 保持 uin 与二进制字段',
        marked.uin == 10001 && marked.d2key.length == 16);
  }

  // ---------------------------------------------------------------
  stdout.writeln('\n[4] JSON 往返：新字段在，旧字段不变');
  {
    final t = _base().copyWith(
      issuedAtMs: 111,
      renewedAtMs: 222,
      expireAtMs: 333,
      serverTimeMs: 444,
      lifetimeTlvHex: 'deadbeef',
      invalidatedAtMs: 555,
      invalidatedType: 16,
    );
    final back = Qq8TokenData.fromJson(
        jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>);
    check('issuedAtMs 往返', back.issuedAtMs == 111);
    check('renewedAtMs 往返', back.renewedAtMs == 222);
    check('expireAtMs 往返', back.expireAtMs == 333);
    check('serverTimeMs 往返', back.serverTimeMs == 444);
    check('lifetimeTlvHex 往返', back.lifetimeTlvHex == 'deadbeef');
    check('invalidatedAtMs / invalidatedType 往返',
        back.invalidatedAtMs == 555 && back.invalidatedType == 16);
    check('uin/d2key 等旧字段仍在', back.uin == 10001 && back.d2key.length == 16);
  }

  // ---------------------------------------------------------------
  stdout.writeln('\n[5] 向后兼容：旧票据文件（没有新键）仍能读');
  {
    final legacy = <String, dynamic>{
      'uin': 10002,
      'saved_at': '2026-10-24T00:00:00.000',
      'tgt': 'aa' * 4,
      'd2': 'bb' * 4,
      'd2key': 'cc' * 4,
      'sig_key': 'dd' * 4,
      'ticket_key': 'ee' * 4,
      'srm_token': 'ff' * 4,
      'a1': '',
    };
    final t = Qq8TokenData.fromJson(legacy);
    check('旧文件读成 uin/票据正常', t.uin == 10002 && t.d2.length == 4);
    check('旧文件新字段全 null（不报错）',
        t.issuedAtMs == null && t.invalidatedAtMs == null && t.expireAtMs == null);
    check('旧文件判 unknown（照常尝试）',
        t.evaluateValidity(DateTime(2026, 10, 30)) == Qq8TokenValidity.unknown);
    // 脏值也要扛住（人工改坏的文件不该让启动崩）
    final dirty = Map<String, dynamic>.from(legacy)
      ..['expire_at_ms'] = 'not-a-number'
      ..['lifetime_tlv'] = 42;
    final d = Qq8TokenData.fromJson(dirty);
    check('脏值（类型不对）读成 null，不抛异常',
        d.expireAtMs == null && d.lifetimeTlvHex == null);
  }

  // ---------------------------------------------------------------
  stdout.writeln('\n[6] fromSigBundle：新参数可选，旧调用点行为不变');
  {
    final bundle = Qq8SigBundle(
      all: <int, Uint8List>{},
      tgt: _b(72),
      d2: _b(64),
      d2key: _b(16),
      sigKey: _b(16),
      ticketKey: _b(16),
      srmToken: _b(16),
      t106: _b(152),
    );
    final plain = Qq8TokenData.fromSigBundle(10003, bundle);
    check('不传元数据 → 时间戳 null', plain.issuedAtMs == null && plain.serverTimeMs == null);
    check('a1 仍从 t106 取', plain.a1.length == 152);
    final withMeta = Qq8TokenData.fromSigBundle(10003, bundle,
        issuedAtMs: 777, serverTimeMs: 888, lifetimeTlvHex: 'cafe');
    check('传了就写进去',
        withMeta.issuedAtMs == 777 &&
            withMeta.serverTimeMs == 888 &&
            withMeta.lifetimeTlvHex == 'cafe');
  }

  // ---------------------------------------------------------------
  stdout.writeln('\n[7] FileQq8TokenStore：落盘→读回，新字段不丢');
  {
    final dir = Directory.systemTemp.createTempSync('qq8tok_');
    try {
      final store = FileQq8TokenStore(dir);
      final t = _base().copyWith(
          issuedAtMs: 111, expireAtMs: 999, invalidatedAtMs: 555, invalidatedType: 155);
      await store.save(t);
      final back = await store.load(10001);
      check('文件存在', File('${dir.path}/qq8-token-10001.json').existsSync());
      check('读回 issuedAtMs', back?.issuedAtMs == 111);
      check('读回 expireAtMs', back?.expireAtMs == 999);
      check('读回失效标记', back?.invalidated == true && back?.invalidatedType == 155);
      check('读回后仍判 invalidated',
          back!.evaluateValidity(DateTime(2026, 10, 30)) ==
              Qq8TokenValidity.invalidated);
      check('listUins 能列出', (await store.listUins()).contains(10001));
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  stdout.writeln('\n==============================================================');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
