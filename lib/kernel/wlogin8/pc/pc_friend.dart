/// 拉好友列表（OIDB 0xfd4_1，对齐 acidify `FetchFriends.kt` + `IncPull.kt`）。
///
/// 请求 `IncPull`（只填需要的字段）：2:reqCount 5:cookie{1:nextUin} 6:flag 10001:requestBiz[]
/// 响应 `IncPullResp`：101:friendList[{1:uid,2:categoryId,3:uin,10001:subBizMap}] 102:category[]
library;

import 'dart:typed_data';

import 'pc_oidb.dart';
import 'pc_proto.dart';

class PcFriend {
  const PcFriend({
    required this.uin,
    required this.uid,
    this.nickname = '',
    this.remark = '',
    this.bio = '',
    this.qid = '',
    this.age = 0,
    this.gender = 0,
    this.categoryId = 0,
  });
  final int uin;
  final String uid;
  final String nickname;
  final String remark;
  final String bio;
  final String qid;
  final int age;
  final int gender;
  final int categoryId;
}

abstract final class PcFriendService {
  static const int command = 0xfd4;
  static const int service = 1;
  static String get cmd => PcOidb.cmdOf(command, service);

  // UserInfoKey（acidify `UserInfoKey.kt`）
  static const int _bio = 102;
  static const int _remark = 103;
  static const int _nickname = 20002;
  static const int _qid = 27394;
  static const int _age = 20037;
  static const int _gender = 20009;

  static Uint8List buildIncPull({int reqCount = 300, int? nextUin}) {
    final biz1 = (PbWriter()
          ..writeInt(1, 1) // bizType=1
          ..writeBytes(
              2, PcOidb.packedVarints([_bio, _remark, _nickname, _qid, _age, _gender])))
        .toBytes();
    final biz4 = (PbWriter()
          ..writeInt(1, 4) // bizType=4
          ..writeBytes(2, PcOidb.packedVarints([100, 101, 102])))
        .toBytes();
    final w = PbWriter()..writeInt(2, reqCount);
    if (nextUin != null) {
      w.writeBytes(5, (PbWriter()..writeInt(1, nextUin)).toBytes()); // cookie
    }
    w
      ..writeInt(6, 1) // flag
      ..writeBytes(10001, biz1)
      ..writeBytes(10001, biz4);
    return w.toBytes();
  }

  /// 解析 OIDB body → 好友列表。
  static List<PcFriend> parseIncPullResp(Uint8List body) {
    final r = PbReader(body);
    final out = <PcFriend>[];
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 101) {
        out.add(_parseFriend(r.readBytes()));
      } else {
        r.skip(w);
      }
    }
    return out;
  }

  static PcFriend _parseFriend(Uint8List b) {
    final r = PbReader(b);
    var uin = 0;
    var uid = '';
    var cat = 0;
    final number = <int, int>{};
    final string = <int, String>{};
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 1) {
        uid = r.readString();
      } else if (f == 2) {
        cat = r.readVarint();
      } else if (f == 3) {
        uin = r.readVarint();
      } else if (f == 10001) {
        // SubBizEntry{1:key, 2:value(SubBiz{1:numberProps,2:stringProps})}
        final e = PbReader(r.readBytes());
        var key = 0;
        Uint8List? val;
        while (!e.atEnd) {
          final (ef, ew) = e.readTag();
          if (ef == 1) {
            key = e.readVarint();
          } else if (ef == 2) {
            val = e.readBytes();
          } else {
            e.skip(ew);
          }
        }
        if (key == 1 && val != null) _parseSubBiz(val, number, string);
      } else {
        r.skip(w);
      }
    }
    return PcFriend(
      uin: uin,
      uid: uid,
      nickname: string[_nickname] ?? '',
      remark: string[_remark] ?? '',
      bio: string[_bio] ?? '',
      qid: string[_qid] ?? '',
      age: number[_age] ?? 0,
      gender: number[_gender] ?? 0,
      categoryId: cat,
    );
  }

  static void _parseSubBiz(
      Uint8List b, Map<int, int> number, Map<int, String> string) {
    final r = PbReader(b);
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 1) {
        // numberProps: map<int,int> = repeated Entry{1:key,2:value}
        final m = PbReader(r.readBytes());
        var k = 0;
        var v = 0;
        while (!m.atEnd) {
          final (mf, mw) = m.readTag();
          if (mf == 1) {
            k = m.readVarint();
          } else if (mf == 2) {
            v = m.readVarint();
          } else {
            m.skip(mw);
          }
        }
        number[k] = v;
      } else if (f == 2) {
        // stringProps: map<int,string>
        final m = PbReader(r.readBytes());
        var k = 0;
        var v = '';
        while (!m.atEnd) {
          final (mf, mw) = m.readTag();
          if (mf == 1) {
            k = m.readVarint();
          } else if (mf == 2) {
            v = m.readString();
          } else {
            m.skip(mw);
          }
        }
        string[k] = v;
      } else {
        r.skip(w);
      }
    }
  }
}
