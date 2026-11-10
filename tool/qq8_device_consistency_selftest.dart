// 设备一致性位（0x128 的 Y）与快照持久化自测。纯离线。
import 'dart:io';

import 'package:penguinchat/client_api/qq8_device_store.dart';

int _p = 0, _f = 0;
void ck(String n, bool ok, [String d = '']) {
  if (ok) {
    _p++;
    stdout.writeln('  OK  $n');
  } else {
    _f++;
    stdout.writeln('  NG  $n  ($d)');
  }
}

void main() {
  stdout.writeln('== 设备一致性位 qq8DeviceConsistencyBits ==');
  const m = 'aaa', a = 'bbb', g = 'ccc';

  ck('首登(无 prev) → 0',
      qq8DeviceConsistencyBits(curMacMd5: m, curAndroidIdMd5: a, curGuidMd5: g) == 0);
  ck('全不变 → 0',
      qq8DeviceConsistencyBits(prevMacMd5: m, prevAndroidIdMd5: a, prevGuidMd5: g,
              curMacMd5: m, curAndroidIdMd5: a, curGuidMd5: g) ==
          0);
  ck('mac 变 → bit1',
      qq8DeviceConsistencyBits(prevMacMd5: m, prevAndroidIdMd5: a, prevGuidMd5: g,
              curMacMd5: 'x', curAndroidIdMd5: a, curGuidMd5: g) ==
          1);
  ck('androidId 变 → bit2',
      qq8DeviceConsistencyBits(prevMacMd5: m, prevAndroidIdMd5: a, prevGuidMd5: g,
              curMacMd5: m, curAndroidIdMd5: 'x', curGuidMd5: g) ==
          2);
  ck('guid 变 → bit4',
      qq8DeviceConsistencyBits(prevMacMd5: m, prevAndroidIdMd5: a, prevGuidMd5: g,
              curMacMd5: m, curAndroidIdMd5: a, curGuidMd5: 'x') ==
          4);
  ck('全变 → 7',
      qq8DeviceConsistencyBits(prevMacMd5: m, prevAndroidIdMd5: a, prevGuidMd5: g,
              curMacMd5: 'x', curAndroidIdMd5: 'y', curGuidMd5: 'z') ==
          7);
  ck('prev 空串视为无(不置位)',
      qq8DeviceConsistencyBits(prevMacMd5: '', prevAndroidIdMd5: '', prevGuidMd5: '',
              curMacMd5: m, curAndroidIdMd5: a, curGuidMd5: g) ==
          0);

  stdout.writeln('== 快照持久化 roundtrip ==');
  final st = const Qq8DeviceState(
    androidId: '123', ksid: 'k', qimei: 'q',
    lastMacMd5: 'mm', lastAndroidIdMd5: 'aa', lastGuidMd5: 'gg',
  );
  final back = Qq8DeviceState.fromJson(st.toJson());
  ck('last_mac_md5 往返', back.lastMacMd5 == 'mm');
  ck('last_android_id_md5 往返', back.lastAndroidIdMd5 == 'aa');
  ck('last_guid_md5 往返', back.lastGuidMd5 == 'gg');
  ck('旧 JSON(无 last_*) → null',
      Qq8DeviceState.fromJson(<String, Object?>{'android_id': '1'}).lastGuidMd5 == null);

  stdout.writeln('\n通过 $_p 项，失败 $_f 项');
  exit(_f == 0 ? 0 : 1);
}
