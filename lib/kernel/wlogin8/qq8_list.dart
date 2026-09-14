/// L2 协议内核：好友列表与群列表（JCE 通道）
///
/// | 命令字 | JCE 包装 | 用途 |
/// |---|---|---|
/// | `friendlist.getFriendGroupList` | `mqq.IMService.FriendListServiceServantObj.GetFriendListReq` | 好友 + 好友分组（分页） |
/// | `friendlist.GetTroopListReqV2` | `...FriendListServiceServantObj.GetTroopListReqV2Simplify` | 群列表 |
///
/// ## 字段号出处：**官方 8.9.50 的 JCE 类**（`friendlist/` 包，74 个类）
///
/// 这是本项目里证据最硬的一块——官方 APK 自带 JCE 生成类，`writeTo` 里的
/// 字段序号就是权威定义，与参考实现逐项吻合：
///
/// ```text
/// friendlist.GetFriendListReq（请求；19 个字段）
///   0 reqtype=3  1 ifReflush=1  2 uin  3 startIndex  4 getfriendCount
///   5 groupid=0  6 ifGetGroupInfo=1  7 groupstartIndex=0  8 getgroupCount=0
///   9 ifGetMSFGroup=0  10 ifShowTermType=1  11 version=31
///   12 uinList=null  13 eAppType=0  14 ifGetDOVId=0  15 ifGetBothFlag=0
///   16 vec0xd50Req(byte[])  17 vec0xd6bReq=null  18 vecSnsTypelist
/// friendlist.GetFriendListResp
///   5 totoal_friend_count  7 vecFriendInfo  14 vecGroupInfo(好友分组)  15 result
/// friendlist.FriendInfo（好友条目）
///   0 friendUin  1 groupId(分组)  3 remark  14 nick  31 cSex(1男/2女)
/// friendlist.GroupInfo（分组条目）  0 groupId  1 groupName
/// friendlist.GetTroopListReqV2Simplify（请求；9 个字段）
///   0 uin  1 bGetMSFMsgFlag=0  2 vecCookies  3 vecGroupInfo([])  4 bGroupFlagExt=1
///   5 shVersion=8  6 dwCompanyId=0  7 versionNum=1  8 bGetLongGroupName=1
/// friendlist.GetTroopListRespV2
///   1 troopcount  2 result  5 vecTroopList
/// friendlist.stTroopNum（群条目）
///   1 GroupCode  4 群名  9 dwShutupTimestamp(全员禁言)  10 dwMyShutupTimestamp
///   11 dwCmdUinUinFlag(管理员位)  19 dwMemberNum  23 群主  27 加入时间
///   29 dwMaxGroupMemberNum
/// ```
///
/// `vec0xd50Req` 是"0xd50 扩展请求"的 protobuf 常量（参考实现取值：
/// `{1:10002, 91001:1, 101001:1, 151001:1, 181001:1, 251001:1}`）——
/// 官方字段名与类型可以核，**内容语义核不到**（在 native/业务层），照抄参考值。
///
/// ⚠️ 没有真机样本 ⇒ 无黄金向量，自测用手搓 JCE 往返。
///
/// 本文件是纯 Dart。
library;

import 'dart:typed_data';

import 'qq8_jce.dart';
import 'qq8_msg.dart';
import 'qq8_pb.dart';

/// 一个好友。
class Qq8Friend {
  /// 好友 uin。
  final int uin;

  /// 昵称（`FriendInfo.nick`）。
  final String nick;

  /// 备注（`FriendInfo.remark`，空串表示没备注）。
  final String remark;

  /// 好友分组 id（`FriendInfo.groupId`）。
  final int groupId;

  /// 性别：1 = 男、2 = 女、其它 = 未知（`FriendInfo.cSex`）。
  final int sex;

  const Qq8Friend({
    required this.uin,
    required this.nick,
    required this.remark,
    required this.groupId,
    required this.sex,
  });

  /// 界面上显示的名字：有备注用备注，否则昵称。
  String get displayName => remark.isNotEmpty ? remark : nick;
}

/// 好友分组。
class Qq8FriendClass {
  final int id;
  final String name;

  const Qq8FriendClass({required this.id, required this.name});
}

/// 好友列表一页。
class Qq8FriendListPage {
  final int result;

  /// 好友总数（`totoal_friend_count`，官方就这么拼的）——分页游标的依据。
  final int total;

  final List<Qq8Friend> friends;
  final List<Qq8FriendClass> classes;

  const Qq8FriendListPage({
    required this.result,
    required this.total,
    this.friends = const <Qq8Friend>[],
    this.classes = const <Qq8FriendClass>[],
  });

  bool get ok => result == 0;
}

/// 一个群。
class Qq8Group {
  final int gid;
  final String name;
  final int memberCount;
  final int maxMemberCount;

  /// 群主 uin。
  final int ownerUin;

  /// 我是不是管理员（`dwCmdUinUinFlag` 非 0）。
  final bool admin;

  /// 全员禁言。
  final bool shutupWhole;

  /// 我被禁言到什么时候（秒；0 = 没被禁言）。
  final int shutupMeUntil;

  /// 我的入群时间（秒）。
  final int joinTime;

  const Qq8Group({
    required this.gid,
    required this.name,
    required this.memberCount,
    required this.maxMemberCount,
    required this.ownerUin,
    required this.admin,
    required this.shutupWhole,
    required this.shutupMeUntil,
    required this.joinTime,
  });
}

/// 群列表。
class Qq8GroupListPage {
  final int result;
  final int total;
  final List<Qq8Group> groups;

  const Qq8GroupListPage({
    required this.result,
    required this.total,
    this.groups = const <Qq8Group>[],
  });

  bool get ok => result == 0;
}

/// 好友 / 群列表的组包与解析。
abstract final class Qq8List {
  static const String cmdFriendList = 'friendlist.getFriendGroupList';
  static const String cmdGroupList = 'friendlist.GetTroopListReqV2';

  static const String _service = 'mqq.IMService.FriendListServiceServantObj';

  /// 好友列表"0xd50 扩展请求"（`GetFriendListReq.vec0xd50Req`）。
  static final Uint8List _d50 = Qq8Pb.encode(<int, Object?>{
    1: 10002,
    91001: 1,
    101001: 1,
    151001: 1,
    181001: 1,
    251001: 1,
  });

  /// 好友列表请求体（`GetFriendListReq`，19 个字段照官方 `writeTo` 顺序）。
  ///
  /// [count] 单页条数（参考实现用 150）；[startIndex] 分页游标。
  static Uint8List buildFriendListBody({
    required int uin,
    int startIndex = 0,
    int count = 150,
  }) =>
      Qq8Jce.encodeWrapper(
        service: _service,
        method: 'GetFriendListReq',
        attributes: <String, Uint8List>{
          'FL': Qq8Jce.encodeStruct(<int, Object?>{
            0: 3, // reqtype
            1: 1, // ifReflush
            2: uin,
            3: startIndex,
            4: count,
            5: 0, // groupid（只要 0 号分组？官方语义如此，照参考实现）
            6: 1, // ifGetGroupInfo（要分组）
            7: 0, // groupstartIndex
            8: 0, // getgroupCount
            9: 0, // ifGetMSFGroup
            10: 1, // ifShowTermType
            11: 31, // version
            13: 0, // eAppType
            14: 0, // ifGetDOVId
            15: 0, // ifGetBothFlag
            16: _d50, // vec0xd50Req
            18: <int>[13580, 13581, 13582], // vecSnsTypelist
          }),
        },
      );

  /// 群列表请求体（`GetTroopListReqV2Simplify`，9 个字段）。
  static Uint8List buildGroupListBody({required int uin}) => Qq8Jce.encodeWrapper(
        service: _service,
        method: 'GetTroopListReqV2Simplify',
        attributes: <String, Uint8List>{
          'GetTroopListReqV2Simplify': Qq8Jce.encodeStruct(<int, Object?>{
            0: uin,
            1: 0, // bGetMSFMsgFlag
            3: <Object?>[], // vecGroupInfo（空 = 全量）
            4: 1, // bGroupFlagExt
            5: 8, // shVersion
            6: 0, // dwCompanyId
            7: 1, // versionNum
            8: 1, // bGetLongGroupName（要长群名）
          }),
        },
      );

  /// 解析好友列表响应。
  static Qq8FriendListPage parseFriendList(Uint8List payload) {
    final f = Qq8Jce.decodeWrapper(payload);
    final classes = <Qq8FriendClass>[];
    for (final v in _structs(f[14])) {
      classes.add(Qq8FriendClass(
        id: _int(v[0]),
        name: _str(v[1]),
      ));
    }
    final friends = <Qq8Friend>[];
    for (final v in _structs(f[7])) {
      friends.add(Qq8Friend(
        uin: _int(v[0]),
        groupId: _int(v[1]),
        remark: _str(v[3]),
        nick: _str(v[14]),
        sex: _int(v[31]),
      ));
    }
    return Qq8FriendListPage(
      result: _int(f[15]),
      total: _int(f[5]),
      friends: friends,
      classes: classes,
    );
  }

  /// 解析群列表响应。
  static Qq8GroupListPage parseGroupList(Uint8List payload) {
    final f = Qq8Jce.decodeWrapper(payload);
    final groups = <Qq8Group>[];
    for (final v in _structs(f[5])) {
      final shutupWholeTs = _int(v[9]);
      final myShutupTs = _int(v[10]);
      groups.add(Qq8Group(
        gid: _int(v[1]),
        name: _str(v[4]),
        memberCount: _int(v[19]),
        maxMemberCount: _int(v[29]),
        ownerUin: _int(v[23]),
        admin: _int(v[11]) != 0,
        shutupWhole: shutupWholeTs != 0,
        shutupMeUntil: myShutupTs,
        joinTime: _int(v[27]),
      ));
    }
    return Qq8GroupListPage(
      result: _int(f[2]),
      total: _int(f[1]),
      groups: groups,
    );
  }

  /// 把 JCE 解出来的"列表"规整成"结构体列表"（元素不是 Map 的直接跳过）。
  static List<Map<int, Object?>> _structs(Object? v) {
    final out = <Map<int, Object?>>[];
    if (v is! List) return out;
    for (final e in v) {
      if (e is Map) {
        out.add(<int, Object?>{
          for (final kv in e.entries)
            if (kv.key is int) kv.key as int: kv.value,
        });
      }
    }
    return out;
  }

  static int _int(Object? v) => v is int ? v : 0;

  static String _str(Object? v) => v is String ? v : '';

  // -------------------------------------------------------------------------
  // 群成员（`friendlist.GetTroopMemberListReq`，JCE 同通道）
  // -------------------------------------------------------------------------

  /// 群成员列表命令字。
  static const String cmdGroupMemberList = 'friendlist.GetTroopMemberListReq';

  /// 群成员列表请求体。
  ///
  /// 官方 `GetTroopMemberListReq` 8 个字段（`writeTo` 顺序）：
  /// `0 uin / 1 GroupCode / 2 NextUin / 3 GroupUin / 4 Version / 5 ReqType /
  /// 6 GetListAppointTime / 7 cRichCardNameVer`。
  /// 取值照参考实现：`GroupUin = code2uin(gid)`、`Version = 2`、其余 0；
  /// 翻页靠 [nextUin]。
  static Uint8List buildGroupMemberListBody({
    required int uin,
    required int gid,
    int nextUin = 0,
  }) =>
      Qq8Jce.encodeWrapper(
        service: _service,
        method: 'GetTroopMemberListReq',
        attributes: <String, Uint8List>{
          'GTML': Qq8Jce.encodeStruct(<int, Object?>{
            0: uin,
            1: gid,
            2: nextUin,
            3: Qq8Msg.code2uin(gid),
            4: 2, // Version
            5: 0, // ReqType
            6: 0, // GetListAppointTime
            7: 0, // cRichCardNameVer
          }),
        },
      );

  /// 解析群成员列表响应。
  ///
  /// 官方 `GetTroopMemberListResp`：`3 vecTroopMember`、`4 NextUin`、`5 result`；
  /// 成员条目 `stTroopMemberInfo`：`0 MemberUin / 2 Age / 3 Gender / 4 Nick /
  /// 8 群名片 / 14 等级 / 15 入群时间 / 16 最后发言 / 18 dwFlag（权限位）/
  /// 23 头衔 / 24 头衔到期 / 30 禁言到`——与参考实现逐位吻合。
  static Qq8GroupMemberPage parseGroupMemberList(Uint8List payload) {
    final f = Qq8Jce.decodeWrapper(payload);
    final members = <Qq8GroupMember>[];
    for (final v in _structs(f[3])) {
      final flag = _int(v[18]);
      members.add(Qq8GroupMember(
        uin: _int(v[0]),
        age: _int(v[2]),
        gender: _int(v[3]),
        nick: _str(v[4]),
        card: _str(v[8]),
        level: _int(v[14]),
        joinTime: _int(v[15]),
        lastSpeakTime: _int(v[16]),
        admin: (flag & 1) == 1,
        title: _str(v[23]),
        titleExpireTime: _int(v[24]) & 0xFFFFFFFF,
        shutupUntil: _int(v[30]),
      ));
    }
    return Qq8GroupMemberPage(
      result: _int(f[5]),
      nextUin: _int(f[4]),
      members: members,
    );
  }
}

/// 一个群成员。
class Qq8GroupMember {
  /// 成员 uin。
  final int uin;

  /// 昵称。
  final String nick;

  /// 群名片（为空表示没设置）。
  final String card;

  /// 性别：官方 `Gender` 字段（0 男 / -1 未知 / 其它女，参考实现同款判法）。
  final int gender;

  final int age;

  /// 群等级（`dwMemberLevel`）。
  final int level;

  /// 专属头衔与到期时间（秒）。
  final String title;
  final int titleExpireTime;

  /// 入群时间 / 最后发言时间（秒）。
  final int joinTime;
  final int lastSpeakTime;

  /// 禁言到什么时候（秒；0 = 没被禁言）。
  final int shutupUntil;

  /// 是不是管理员（`dwFlag` 最低位）。
  ///
  /// **群主要和 [Qq8Group.ownerUin] 比**——成员条目里没有"群主"标志位。
  final bool admin;

  const Qq8GroupMember({
    required this.uin,
    required this.nick,
    required this.card,
    required this.gender,
    required this.age,
    required this.level,
    required this.title,
    required this.titleExpireTime,
    required this.joinTime,
    required this.lastSpeakTime,
    required this.shutupUntil,
    required this.admin,
  });

  /// 界面上显示的名字：有群名片用名片，否则昵称。
  String get displayName => card.isNotEmpty ? card : nick;

  /// 性别文字。
  String get genderLabel => switch (gender) {
        0 => '男',
        -1 => '未知',
        _ => '女',
      };
}

/// 群成员列表一页。
class Qq8GroupMemberPage {
  final int result;

  /// 下一页的起始 uin（0 = 没有更多）。
  final int nextUin;

  final List<Qq8GroupMember> members;

  const Qq8GroupMemberPage({
    required this.result,
    required this.nextUin,
    this.members = const <Qq8GroupMember>[],
  });

  bool get ok => result == 0;
  bool get hasMore => nextUin != 0;
}
