/// 拉群列表（OIDB 0xfe5_2，对齐 acidify `FetchGroups.kt` + `Oidb.0xfe5_2.kt`）。
///
/// 请求 `FetchGroupsReq{1:config{1:config1(全true) 2:config2(全true) 3:config3{5,6=true}}}`
/// 响应 `FetchGroupsResp{2:groups[{3:groupUin,4:info{...},5:customInfo{3:remark}}]}`
library;

import 'dart:typed_data';

import 'pc_oidb.dart';
import 'pc_proto.dart';

class PcGroup {
  const PcGroup({
    required this.uin,
    required this.name,
    this.memberCount = 0,
    this.capacity = 0,
    this.remark = '',
    this.createdAt = 0,
    this.description = '',
    this.question = '',
    this.announcement = '',
  });
  final int uin;
  final String name;
  final int memberCount;
  final int capacity;
  final String remark;
  final int createdAt;
  final String description;
  final String question;
  final String announcement;
}

abstract final class PcGroupService {
  static const int command = 0xfe5;
  static const int service = 2;
  static String get cmd => PcOidb.cmdOf(command, service);

  // config1 全部置 true 的字段（acidify FetchGroups.kt）
  static const List<int> _c1 = [
    1, 2, 3, 4, 5, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, //
    22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 5001, 5002, 5003,
  ];
  static const List<int> _c2 = [1, 2, 3, 4, 5, 6, 7, 8];

  static Uint8List buildFetchGroupsReq() {
    final c1 = PbWriter();
    for (final f in _c1) {
      c1.writeInt(f, 1);
    }
    final c2 = PbWriter();
    for (final f in _c2) {
      c2.writeInt(f, 1);
    }
    final c3 = PbWriter()
      ..writeInt(5, 1)
      ..writeInt(6, 1);
    final config = (PbWriter()
          ..writeBytes(1, c1.toBytes())
          ..writeBytes(2, c2.toBytes())
          ..writeBytes(3, c3.toBytes()))
        .toBytes();
    return (PbWriter()..writeBytes(1, config)).toBytes();
  }

  static List<PcGroup> parseFetchGroupsResp(Uint8List body) {
    final r = PbReader(body);
    final out = <PcGroup>[];
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 2) {
        out.add(_parseGroup(r.readBytes()));
      } else {
        r.skip(w);
      }
    }
    return out;
  }

  static PcGroup _parseGroup(Uint8List b) {
    final r = PbReader(b);
    var uin = 0;
    var name = '';
    var memberCount = 0;
    var capacity = 0;
    var remark = '';
    var createdAt = 0;
    var description = '';
    var question = '';
    var announcement = '';
    while (!r.atEnd) {
      final (f, w) = r.readTag();
      if (f == 3) {
        uin = r.readVarint();
      } else if (f == 4) {
        // info
        final i = PbReader(r.readBytes());
        while (!i.atEnd) {
          final (inf, inw) = i.readTag();
          if (inf == 2) {
            createdAt = i.readVarint();
          } else if (inf == 3) {
            capacity = i.readVarint();
          } else if (inf == 4) {
            memberCount = i.readVarint();
          } else if (inf == 5) {
            name = i.readString();
          } else if (inf == 19) {
            question = i.readString();
          } else if (inf == 21) {
            description = i.readString();
          } else if (inf == 30) {
            announcement = i.readString();
          } else {
            i.skip(inw);
          }
        }
      } else if (f == 5) {
        // customInfo{3:remark}
        final c = PbReader(r.readBytes());
        while (!c.atEnd) {
          final (cf, cw) = c.readTag();
          if (cf == 3) {
            remark = c.readString();
          } else {
            c.skip(cw);
          }
        }
      } else {
        r.skip(w);
      }
    }
    return PcGroup(
      uin: uin,
      name: name,
      memberCount: memberCount,
      capacity: capacity,
      remark: remark,
      createdAt: createdAt,
      description: description,
      question: question,
      announcement: announcement,
    );
  }
}
