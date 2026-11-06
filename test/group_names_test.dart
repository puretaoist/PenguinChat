/// 群成员名缓存的两条约束（真机 m05841 的后端一半）：
///
/// 1. 消息体里带的昵称能补进缓存——成员名单拉不到时也显示得出名字；
/// 2. 已有名字（群名片）不被消息里的昵称覆盖——名片才是群内身份。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/client_api/qq8_login_service.dart';

void main() {
  test('消息里的昵称能补进成员名缓存', () {
    final svc = Qq8LoginService();
    svc.rememberGroupMemberNameFromMessage(123, 1001, '张三');
    expect(svc.groupMemberNameOf(123, 1001), '张三');
  });

  test('已有名字不被消息昵称覆盖', () {
    final svc = Qq8LoginService();
    svc.rememberGroupMemberNameFromMessage(123, 1001, '群名片');
    svc.rememberGroupMemberNameFromMessage(123, 1001, '别的昵称');
    expect(svc.groupMemberNameOf(123, 1001), '群名片');
  });

  test('空昵称与非法 gid/uin 都不写入', () {
    final svc = Qq8LoginService();
    svc.rememberGroupMemberNameFromMessage(123, 1002, null);
    svc.rememberGroupMemberNameFromMessage(123, 1002, '   ');
    svc.rememberGroupMemberNameFromMessage(0, 1002, '张三');
    svc.rememberGroupMemberNameFromMessage(123, 0, '张三');
    expect(svc.groupMemberNameOf(123, 1002), isNull);
  });
}
