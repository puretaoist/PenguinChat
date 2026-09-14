/// 好友 / 群列表（`qq8_list.dart`）离线自测
///
/// ⚠️ 没有真机样本 ⇒ 无黄金向量。但**字段号有官方 JCE 类背书**
/// （`friendlist/` 包的 `writeTo` 顺序，见 `qq8_list.dart` 头注），
/// 所以这里做的是：手搓"服务端会发的结构" → 断言组包/解析的每个字段。
///
/// 运行：
/// ```bash
/// dart run tool/qq8_list_selftest.dart
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:qqclient/kernel/wlogin8/qq8_jce.dart';
import 'package:qqclient/kernel/wlogin8/qq8_list.dart';
import 'package:qqclient/kernel/wlogin8/qq8_msg.dart';
import 'package:qqclient/kernel/wlogin8/qq8_pb.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✓ $name${detail == null ? '' : '   ($detail)'}');
  } else {
    _fail++;
    stdout.writeln('  ✗ $name${detail == null ? '' : '  ($detail)'}');
  }
}

void section(String t) => stdout.writeln('\n$t');

/// 一个 JCE 结构体（列表元素用）。
Qq8JceNested _struct(Map<int, Object?> fields) =>
    Qq8JceNested(Qq8Jce.encode(fields));

/// 服务端响应包装：`{7: {0: {方法名: 结构体字节}}}`（与 `decodeWrapper` 对应）。
Uint8List _resp(String method, Map<int, Object?> fields) =>
    Qq8Jce.encode(<int, Object?>{
      7: Qq8Jce.encode(<int, Object?>{
        0: <Object?, Object?>{method: Qq8Jce.encodeStruct(fields)},
      }),
    });

/// 取请求体里真正发给服务的 JCE 字段（解包装 → sBuffer → 属性表 → 结构体）。
Map<int, Object?> _reqFields(Uint8List body) {
  final wrapper = Qq8Jce.decode(body);
  final attrs = Qq8Jce.decode(wrapper[7] as Uint8List)[0] as Map<Object?, Object?>;
  final nested = Qq8Jce.decode(attrs.values.first as Uint8List);
  return nested[0] as Map<int, Object?>;
}

String _svcOf(Uint8List body) => Qq8Jce.decode(body)[5] as String;
String _methodOf(Uint8List body) => Qq8Jce.decode(body)[6] as String;

void main() {
  stdout.writeln('好友 / 群列表离线自测（字段号照官方 friendlist JCE 类）');
  stdout.writeln('=' * 62);

  // ----------------------------------------------------------------
  section('1. 好友列表请求（GetFriendListReq，19 字段）');
  {
    final body =
        Qq8List.buildFriendListBody(uin: 10001, startIndex: 300, count: 150);
    check('包装服务/方法名',
        _svcOf(body) == 'mqq.IMService.FriendListServiceServantObj' &&
            _methodOf(body) == 'GetFriendListReq',
        '${_svcOf(body)}.${_methodOf(body)}');
    final f = _reqFields(body);
    check('reqtype=3 / ifReflush=1', f[0] == 3 && f[1] == 1, '${f[0]} ${f[1]}');
    check('uin / startIndex / getfriendCount',
        f[2] == 10001 && f[3] == 300 && f[4] == 150, '${f[2]} ${f[3]} ${f[4]}');
    check('ifGetGroupInfo=1 / ifShowTermType=1 / version=31',
        f[6] == 1 && f[10] == 1 && f[11] == 31);
    check('vec0xd50Req（tag16）= 0xd50 扩展请求 pb 常量',
        _hex(f[16]) ==
            _hex(Qq8Pb.encode(<int, Object?>{
              1: 10002,
              91001: 1,
              101001: 1,
              151001: 1,
              181001: 1,
              251001: 1,
            })),
        _hex(f[16]).substring(0, 16));
    check('vecSnsTypelist（tag18）= [13580, 13581, 13582]',
        (f[18] as List).join(',') == '13580,13581,13582', '${f[18]}');
    check('空字段不写：uinList/vec0xd6bReq 都不在',
        !f.containsKey(12) && !f.containsKey(17));
  }

  // ----------------------------------------------------------------
  section('2. 好友列表响应：好友 + 分组 + 总数');
  {
    final payload = _resp('GetFriendListResp', <int, Object?>{
      5: 2, // totoal_friend_count
      7: <Object?>[
        _struct(<int, Object?>{
          0: 22222,
          1: 7,
          3: '小王',
          14: '阿王',
          31: 1,
        }),
        _struct(<int, Object?>{
          0: 33333,
          1: 0,
          14: '路人',
          31: 2,
        }),
      ],
      14: <Object?>[
        _struct(<int, Object?>{0: 0, 1: '我的好友'}),
        _struct(<int, Object?>{0: 7, 1: '同事'}),
      ],
      15: 0,
    });
    final page = Qq8List.parseFriendList(payload);
    check('result=0 / total=2', page.ok && page.total == 2,
        'result=${page.result} total=${page.total}');
    check('两个好友：uin/分组/备注/昵称/性别',
        page.friends.length == 2 &&
            page.friends[0].uin == 22222 &&
            page.friends[0].groupId == 7 &&
            page.friends[0].remark == '小王' &&
            page.friends[0].nick == '阿王' &&
            page.friends[0].sex == 1,
        page.friends.map((f) => '${f.uin}:${f.displayName}').join(' '));
    check('显示名优先备注（没备注才用昵称）',
        page.friends[0].displayName == '小王' &&
            page.friends[1].displayName == '路人',
        page.friends[1].displayName);
    check('分组解出（id + 名称）',
        page.classes.length == 2 &&
            page.classes[1].id == 7 &&
            page.classes[1].name == '同事',
        page.classes.map((c) => '${c.id}:${c.name}').join(' '));

    final fail = Qq8List.parseFriendList(
        _resp('GetFriendListResp', <int, Object?>{15: 3}));
    check('失败响应：result=3 → ok=false，列表为空',
        !fail.ok && fail.friends.isEmpty && fail.classes.isEmpty);
  }

  // ----------------------------------------------------------------
  section('3. 群列表请求（GetTroopListReqV2Simplify，9 字段）');
  {
    final body = Qq8List.buildGroupListBody(uin: 10001);
    check('包装方法名 = GetTroopListReqV2Simplify',
        _methodOf(body) == 'GetTroopListReqV2Simplify', _methodOf(body));
    final f = _reqFields(body);
    check('uin=10001 / bGetMSFMsgFlag=0',
        f[0] == 10001 && f[1] == 0, '${f[0]}');
    check('vecGroupInfo 是空列表（全量拉）',
        f[3] is List && (f[3] as List).isEmpty);
    check('bGroupFlagExt=1 / shVersion=8 / versionNum=1 / bGetLongGroupName=1',
        f[4] == 1 && f[5] == 8 && f[7] == 1 && f[8] == 1,
        '${f[4]} ${f[5]} ${f[7]} ${f[8]}');
  }

  // ----------------------------------------------------------------
  section('4. 群列表响应：群条目字段');
  {
    final payload = _resp('GetTroopListRespV2', <int, Object?>{
      1: 2, // troopcount
      2: 0, // result
      5: <Object?>[
        _struct(<int, Object?>{
          1: 987654321,
          4: '测试群',
          9: 0, // 全员禁言时间戳
          10: 1700009999, // 我被禁言到
          11: 1, // 管理员位
          19: 233, // 成员数
          23: 10002, // 群主
          27: 1650000000, // 入群时间
          29: 500, // 上限
        }),
        _struct(<int, Object?>{
          1: 111222333,
          4: '全员禁言的群',
          9: 1700001234,
          19: 5,
          29: 200,
        }),
      ],
    });
    final page = Qq8List.parseGroupList(payload);
    check('result=0 / total=2', page.ok && page.total == 2,
        'result=${page.result} total=${page.total}');
    final g = page.groups.first;
    check('群 1：号/名/成员数/上限/群主/管理员/禁言/入群时间',
        g.gid == 987654321 &&
            g.name == '测试群' &&
            g.memberCount == 233 &&
            g.maxMemberCount == 500 &&
            g.ownerUin == 10002 &&
            g.admin &&
            !g.shutupWhole &&
            g.shutupMeUntil == 1700009999 &&
            g.joinTime == 1650000000,
        '${g.gid} ${g.name} ${g.memberCount}/${g.maxMemberCount}');
    check('群 2：全员禁言 = true（时间戳非 0），没禁言我 = 0',
        page.groups[1].shutupWhole && page.groups[1].shutupMeUntil == 0);

    final empty = Qq8List.parseGroupList(
        _resp('GetTroopListRespV2', <int, Object?>{1: 0, 2: 0}));
    check('空群列表（没 tag5）→ 0 条，不炸',
        empty.ok && empty.total == 0 && empty.groups.isEmpty);
    final fail = Qq8List.parseGroupList(
        _resp('GetTroopListRespV2', <int, Object?>{1: 0, 2: 7}));
    check('失败响应：result=7 → ok=false', !fail.ok && fail.result == 7);
  }

  // ----------------------------------------------------------------
  section('5. 群成员列表（GetTroopMemberListReq，8 字段）');
  {
    final body = Qq8List.buildGroupMemberListBody(uin: 10001, gid: 987654321);
    check('包装方法名 = GetTroopMemberListReq',
        _methodOf(body) == 'GetTroopMemberListReq', _methodOf(body));
    final f = _reqFields(body);
    check('uin / GroupCode / NextUin=0',
        f[0] == 10001 && f[1] == 987654321 && f[2] == 0, '${f[0]} ${f[1]} ${f[2]}');
    check('GroupUin = code2uin(gid)（讨论组式变换，与参考实现一致）',
        f[3] == Qq8Msg.code2uin(987654321), '${f[3]}');
    check('Version=2 / ReqType=0 / AppointTime=0 / RichCardNameVer=0',
        f[4] == 2 && f[5] == 0 && f[6] == 0 && f[7] == 0, '${f[4]}');

    final nextPageReq =
        Qq8List.buildGroupMemberListBody(uin: 10001, gid: 987654321, nextUin: 20002);
    check('翻页：NextUin 带上', _reqFields(nextPageReq)[2] == 20002);

    final payload = _resp('GetTroopMemberListResp', <int, Object?>{
      3: <Object?>[
        _struct(<int, Object?>{
          0: 20002,
          2: 24,
          3: 0,
          4: '小明',
          8: '小明的名片',
          14: 7,
          15: 1650000000,
          16: 1700000900,
          18: 1, // 最低位 = 管理员
          23: '摸鱼王',
          24: 1700000999,
          30: 1700001234,
        }),
        _struct(<int, Object?>{
          0: 20003,
          3: -1,
          4: '路人',
          18: 0,
        }),
      ],
      4: 0, // NextUin = 0 → 没有更多
      5: 0,
    });
    final page = Qq8List.parseGroupMemberList(payload);
    check('result=0 / 没有下一页', page.ok && !page.hasMore && page.nextUin == 0);
    final m = page.members.first;
    check('成员 1：uin/昵称/名片/等级/权限/头衔/禁言/入群时间',
        m.uin == 20002 &&
            m.nick == '小明' &&
            m.card == '小明的名片' &&
            m.level == 7 &&
            m.admin &&
            m.title == '摸鱼王' &&
            m.shutupUntil == 1700001234 &&
            m.joinTime == 1650000000 &&
            m.lastSpeakTime == 1700000900,
        '${m.uin} ${m.displayName} lv=${m.level}');
    check('显示名优先群名片；性别文字按官方判法（0 男 / -1 未知）',
        m.displayName == '小明的名片' &&
            m.genderLabel == '男' &&
            page.members[1].genderLabel == '未知',
        '${m.genderLabel}/${page.members[1].genderLabel}');
    check('成员 2：没名片时用昵称、admin=false',
        page.members[1].displayName == '路人' && !page.members[1].admin);

    final paged = Qq8List.parseGroupMemberList(
        _resp('GetTroopMemberListResp', <int, Object?>{
      3: <Object?>[
        _struct(<int, Object?>{0: 20004, 4: '第一页最后一位'}),
      ],
      4: 20004,
      5: 0,
    }));
    check('有 NextUin → hasMore=true（服务层据此翻页）',
        paged.hasMore && paged.nextUin == 20004);

    final bad = Qq8List.parseGroupMemberList(
        _resp('GetTroopMemberListResp', <int, Object?>{3: <Object?>[], 4: 0, 5: 6}));
    check('失败响应：result=6 → ok=false', !bad.ok && bad.members.isEmpty);
  }

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  exit(_fail == 0 ? 0 : 1);
}

String _hex(Object? v) => v is Uint8List
    ? v.map((b) => b.toRadixString(16).padLeft(2, '0')).join()
    : '(${v.runtimeType})';
