// 票据存储迁移自测：旧明文 → 密文迁移、密钥不可用时保留明文、损坏密文、
// listUins 合并、clear 清理。纯离线，不联网、不需要账号。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:penguinchat/client_api/qq8_token_store.dart';

int _pass = 0, _fail = 0;
void ok(String n) {
  _pass++;
  stdout.writeln('  OK  $n');
}

void ng(String n, String d) {
  _fail++;
  stdout.writeln('  NG  $n  ($d)');
}

void ck(String n, bool c, [String d = '']) => c ? ok(n) : ng(n, d);

Uint8List _b(int n, [int f = 0x11]) =>
    Uint8List.fromList(List<int>.filled(n, f));

Qq8TokenData _data(int uin) => Qq8TokenData(
      uin: uin,
      savedAt: '2026-11-09T00:00:00.000',
      tgt: _b(72),
      d2: _b(64),
      d2key: _b(16, 0x22),
      sigKey: _b(16, 0x33),
      ticketKey: _b(16, 0x44),
      srmToken: _b(16, 0x55),
      a1: _b(152, 0x66),
    );

Future<List<int>> _fixedKey() async => List<int>.generate(32, (i) => i);

File _legacy(Directory d, int uin) =>
    File('${d.path}${Platform.pathSeparator}qq8-token-$uin.json');
File _enc(Directory d, int uin) =>
    File('${d.path}${Platform.pathSeparator}qq8-token-$uin.json.enc');

Future<void> _writeLegacy(Directory d, int uin, Qq8TokenData data) async {
  await _legacy(d, uin).writeAsString(jsonEncode(data.toJson()));
}

Future<void> main() async {
  stdout.writeln('== 票据存储迁移自测 ==');
  final root = Directory.systemTemp.createTempSync('qq8tok_');
  try {
    stdout.writeln('[1] 旧明文 → 首次 load 自动迁移');
    {
      final d = Directory('${root.path}/a')..createSync(recursive: true);
      await _writeLegacy(d, 10001, _data(10001));
      final store = EncryptedFileQq8TokenStore(d, keyProvider: _fixedKey);
      final t = await store.load(10001);
      ck('返回票据', t != null);
      ck('uin 正确', t?.uin == 10001);
      ck('密文文件已生成', await _enc(d, 10001).exists());
      ck('旧明文已删除', !await _legacy(d, 10001).exists());
      final again = await store.load(10001);
      ck('二次 load 读密文', again?.uin == 10001);
      final fresh = EncryptedFileQq8TokenStore(d, keyProvider: _fixedKey);
      ck('新实例读同一密钥', (await fresh.load(10001))?.uin == 10001);
    }

    stdout.writeln('[2] 密钥不可用时保留明文并继续可用');
    {
      final d = Directory('${root.path}/b')..createSync(recursive: true);
      await _writeLegacy(d, 10002, _data(10002));
      Future<List<int>> badKey() async =>
          throw const Qq8TokenStoreKeyUnavailable('simulated');
      final store = EncryptedFileQq8TokenStore(d, keyProvider: badKey);
      final t = await store.load(10002);
      ck('返回明文票据', t?.uin == 10002);
      ck('明文仍在', await _legacy(d, 10002).exists());
      ck('未生成密文', !await _enc(d, 10002).exists());
    }

    stdout.writeln('[3] 密文损坏时不退回明文');
    {
      final d = Directory('${root.path}/c')..createSync(recursive: true);
      await _enc(d, 10003).writeAsString(
          '{"v":1,"nonce":"AA==","ct":"AA==","mac":"AA=="}');
      await _writeLegacy(d, 10003, _data(10003));
      final store = EncryptedFileQq8TokenStore(d, keyProvider: _fixedKey);
      ck('损坏密文返回 null', await store.load(10003) == null);
      ck('明文未被用来顶替', await _legacy(d, 10003).exists());
    }

    stdout.writeln('[4] listUins 合并明文与密文，clear 清理两者');
    {
      final d = Directory('${root.path}/d')..createSync(recursive: true);
      await _writeLegacy(d, 10004, _data(10004));
      final store = EncryptedFileQq8TokenStore(d, keyProvider: _fixedKey);
      await store.save(_data(10005));
      final uins = await store.listUins();
      ck('包含 10004 与 10005',
          uins.contains(10004) && uins.contains(10005));
      await store.clear(10004);
      ck('10004 明文已删', !await _legacy(d, 10004).exists());
      await store.clear(10005);
      ck('10005 密文已删', !await _enc(d, 10005).exists());
    }
  } finally {
    try {
      root.deleteSync(recursive: true);
    } on Object {
      // 临时目录清理失败不影响测试结论
    }
  }
  stdout.writeln('\n通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}
