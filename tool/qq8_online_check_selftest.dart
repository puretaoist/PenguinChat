import 'dart:typed_data';

import 'package:qqclient/kernel/wlogin8/qq8_jce.dart';
import 'package:qqclient/kernel/wlogin8/qq8_online_check.dart';

/// 校验 [Qq8OnlineCheck] 里那两个「抓包回放」请求体没有抄错。
///
/// 判据不是「长度对」，而是**用我们自己的 JCE 解码器解出抓包时得到的字段**：
/// ```
/// PhSigLcId : {1: ['be910af39a26a4a992c6fd01a143ed19'], 2: 537064117, 3: [3499239040], 4: 0}
/// GrayUinPro: {1: 537064117, 2: '3499239040', 3: '', 4: '627864465254787270'}
/// ```
/// 手抄 138 字节十六进制出错的风险极高，且错一个半字节服务端就判「签名不符」，
/// 而失败现象会跟「字段算错」完全一样——所以必须由机器验，不能靠眼睛。
int _failures = 0;
int _passes = 0;

void _check(String name, bool ok, [String extra = '']) {
  if (ok) {
    _passes++;
    print('  [OK] $name');
  } else {
    _failures++;
    print('  [FAIL] $name ${extra.isEmpty ? '' : '→ $extra'}');
  }
}

String _hex(Uint8List b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  print('== 在线检查请求体：抓包回放的自洽性 ==');

  final sig = Qq8OnlineCheck.phSigLcIdPayload(3499239040);
  final gray = Qq8OnlineCheck.grayUinProPayload(3499239040);

  // 1) 长度必须与抓包一致（138 / 116）
  _check('PhSigLcId 长度 138', sig.length == 138, '实际 ${sig.length}');
  _check('GrayUinPro 长度 116', gray.length == 116, '实际 ${gray.length}');

  // 2) 用 JCE 解码器解出抓包时看到的字段
  final sigMap = Qq8Jce.decodeWrapper(sig);
  _check('PhSigLcId 解出四个字段', sigMap.length == 4, '${sigMap.keys.toList()}');
  _check(
    'PhSigLcId[1] 是那个 32 位十六进制串',
    sigMap[1] is List<Object?> && (sigMap[1] as List<Object?>).length == 1 &&
        '${(sigMap[1] as List<Object?>).first}' == 'be910af39a26a4a992c6fd01a143ed19',
    '${sigMap[1]}',
  );
  _check('PhSigLcId[2] = subAppId 537064117', sigMap[2] == 537064117, '${sigMap[2]}');
  _check(
    'PhSigLcId[3] = [uin]',
    sigMap[3] is List<Object?> &&
        '${(sigMap[3] as List<Object?>).first}' == '3499239040',
    '${sigMap[3]}',
  );
  _check('PhSigLcId[4] = 0', sigMap[4] == 0, '${sigMap[4]}');

  final grayMap = Qq8Jce.decodeWrapper(gray);
  _check('GrayUinPro 解出四个字段', grayMap.length == 4, '${grayMap.keys.toList()}');
  _check('GrayUinPro[1] = subAppId 537064117', grayMap[1] == 537064117, '${grayMap[1]}');
  _check('GrayUinPro[2] = uin 字符串', '${grayMap[2]}' == '3499239040', '${grayMap[2]}');
  _check('GrayUinPro[3] = 空串', '${grayMap[3]}' == '', '${grayMap[3]}');
  _check(
    'GrayUinPro[4] = 那个尾串',
    '${grayMap[4]}' == '627864465254787270',
    '${grayMap[4]}',
  );

  // 3) uin 替换只动 ASCII 数字，不碰摘要字节
  final other = Qq8OnlineCheck.phSigLcIdPayload(1234567890);
  _check('不同 uin 长度一致（10 位）', other.length == sig.length);
  final diff = <int>[];
  for (var i = 0; i < sig.length; i++) {
    if (sig[i] != other[i]) diff.add(i);
  }
  // 两个 10 位 uin 可能有个别位数字相同（`3499239040` 与 `1234567890` 末位都是
  // 0），所以是「不超过 10 个字节，且恰好等于两串数字不同的位数」。
  const a = '3499239040', b = '1234567890';
  var digitsDiffer = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) digitsDiffer++;
  }
  _check(
    '替换字节数 = 两串 uin 不同的位数（$digitsDiffer）',
    diff.length == digitsDiffer,
    '改了 ${diff.length} 字节',
  );
  // 摘要串是**以 ASCII 存下来的 32 位十六进制**，所以判据是「解出来的字段 1 没变」，
  // 而不是「十六进制里能找到那段字符」（那段字符在 hex 里是 6265 3931 … 的样子）。
  final otherMap = Qq8Jce.decodeWrapper(other);
  _check(
    '替换后字段 1 摘要串未变',
    '${(otherMap[1] as List<Object?>).first}' ==
        'be910af39a26a4a992c6fd01a143ed19',
    '${otherMap[1]}',
  );
  _check(
    '替换后字段 3 已换成新 uin',
    '${(otherMap[3] as List<Object?>).first}' == '1234567890',
    '${otherMap[3]}',
  );

  // 4) 位数不同的 uin 不做替换（会让 JCE 长度前缀自相矛盾）
  final oddUin = Qq8OnlineCheck.phSigLcIdPayload(123456789);
  _check('9 位 uin 原样返回', _hex(oddUin) == _hex(sig));

  print('');
  print('== 结果: $_passes 通过, $_failures 失败 ==');
}
