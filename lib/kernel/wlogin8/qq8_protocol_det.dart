/// 官方 `com.tencent.loginsecsdk.ProtocolDet` 的等价实现。
///
/// ## 它是什么
///
/// 官方在密码登录的 `0x525` 里塞一个内嵌 `0x536` TLV，body 来自
/// `ProtocolDet.getLoginExtraData(context)`。这块数据是**历史登录出口 IP 缓存**：
/// 每次登录成功后，官方把「本次登录用的 uin + 出口 IP + 时间 + subAppId」
/// 追加进 `files/pd2.dat`，下次登录时把最近至多 3 条打包带上。
///
/// 服务端据此判断「这个账号是不是在常用出口 IP 上」——是一个**风控证据块**，
/// 不是加密块、不是签名块。取不到数据时官方发 `01 00`（2 字节，条数 0）。
///
/// ## 为什么必须实现
///
/// 我方此前恒发 `[0x01, 0x00]`（等价于「我一条历史都没有」）。对照官方真机日志：
///
/// | 日志 | `0x536` 长度 | 结果 |
/// |---|---|---|
/// | `wtlogin_20260919.txt:73` | 2（`0100`） | `subCmd=0x9 type:2`（要验证） |
/// | `wtlogin_20260919-b.txt:2931` | 65 | `type=2`（同日已有风控） |
/// | `qq8211/wtlogin_20260930.txt:375` | 65 | **`subCmd=0x9 type:0 ret:0` 成功** |
///
/// 成功样本是 65 字节。恒发 2 字节等于每次都告诉服务端「我是全新环境」，
/// 与「这是老账号在老地方登录」的事实相悖。
///
/// ## 格式（`ProtocolDet.java` 逐行核对）
///
/// 磁盘文件 `pd2.dat` 是**裸条目串联**，无头：
/// ```text
/// 条目 = writeLong(mUin) ‖ writeByte(mlen) ‖ write(mIp) ‖ writeInt(mTime) ‖ writeInt(mVersion)
/// ```
/// `mlen` 只能是 4（IPv4，共 21 字节）或 16（IPv6，共 33 字节），否则整条丢弃
/// （`getExtraDataFromBuffer` 打 `"error: IP Length fault "` 返回 null）。
///
/// 上线时的 body 是 `packExtraData` 现加的 2 字节头：
/// ```text
/// body = writeByte(1) ‖ writeByte(条目数) ‖ 条目...
/// ```
/// 所有整数都是**大端**（`DataOutputStream` 语义）。
///
/// 官方常量（`ProtocolDet.java:9-15`）：
/// - `DET_CACHE_FILE_NAME = "pd2.dat"`
/// - `EXTRA_IPV4_DATA_ITEM_SIZE = 21`
/// - `EXTRA_IPV6_DATA_ITEM_SIZE = 33`
/// - `IPV4_LEN = 4` / `IPV6_LEN = 16`
/// - `MAX_CACHED_FILE_SIZE = 4096`
/// - `MAX_CACHED_ITEM_COUNT = 3`
library;

import 'dart:typed_data';

import '../../infra/coder.dart';

/// 一条登录出口 IP 记录（官方 `ProtocolDet.LoginExtraData`）。
class Qq8ProtocolDetEntry {
  /// 这条记录属于哪个 uin。
  ///
  /// ⚠️ **不一定等于当前登录账号**：官方真机 `pd2.dat` 里同时存着
  /// `2089495846` 与 `3499239040` 两个号，登录 `2089495846` 时也把
  /// `3499239040` 的旧记录一起带上了（同一个 `pd2.dat` 文件多号共用）。
  final int uin;

  /// IP 字节。4 字节（IPv4）或 16 字节（IPv6）。
  final Uint8List ip;

  /// 记录时间（Unix 秒）。
  final int time;

  /// 写入时的 `subAppId`（8.2.11 = 537064117）。
  final int version;

  const Qq8ProtocolDetEntry({
    required this.uin,
    required this.ip,
    required this.time,
    required this.version,
  });

  /// 该条目编码后的字节数（21 / 33）。
  int get encodedSize => 8 + 1 + ip.length + 4 + 4;

  /// IP 的点分十进制展示（仅 IPv4 有意义）。
  String get ipText => ip.length == 4
      ? ip.join('.')
      : ip.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Map<String, Object?> toJson() => <String, Object?>{
        'uin': uin,
        'ip': ipText,
        'time': time,
        'version': version,
      };

  @override
  String toString() =>
      'Qq8ProtocolDetEntry(uin: $uin, ip: $ipText, time: $time, ver: $version)';

  @override
  bool operator ==(Object other) =>
      other is Qq8ProtocolDetEntry &&
      other.uin == uin &&
      other.time == time &&
      other.version == version &&
      other.ip.length == ip.length &&
      _bytesEqual(other.ip, ip);

  @override
  int get hashCode => Object.hash(uin, time, version, ip.length);
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 官方 `ProtocolDet` 的纯 Dart 等价物。
abstract final class Qq8ProtocolDet {
  /// 缓存文件名（官方 `DET_CACHE_FILE_NAME`）。
  static const String cacheFileName = 'pd2.dat';

  /// IPv4 条目字节数（官方 `EXTRA_IPV4_DATA_ITEM_SIZE`）。
  static const int ipv4ItemSize = 21;

  /// IPv6 条目字节数（官方 `EXTRA_IPV6_DATA_ITEM_SIZE`）。
  static const int ipv6ItemSize = 33;

  /// 磁盘文件大小上限（官方 `MAX_CACHED_FILE_SIZE`）。
  static const int maxFileSize = 4096;

  /// 至多保留/发送几条（官方 `MAX_CACHED_ITEM_COUNT`）。
  static const int maxItemCount = 3;

  /// `packExtraData(null)` 的产物：协议版本 1、条目数 0。
  ///
  /// 官方 `packExtraData` 里 `bArr == null` 时 `cNum = 0`，写出 `01 00`。
  static Uint8List get emptyBody => Uint8List.fromList(const <int>[0x01, 0x00]);

  /// 把条目列表打成 `0x536` 的 body（`packExtraData(convertExtraDataListToBuffer(list))`）。
  ///
  /// [entries] 为空时返回 [emptyBody]（与官方完全一致，不返回空数组）。
  /// 超过 [maxItemCount] 条时**只取前 3 条**（官方 `loadExtraDataFromFile(context, 3)`
  /// 在读取阶段就限了 3，这里在编码阶段再兜一次）。
  ///
  /// 单条 `ip` 长度不是 4/16 时**跳过该条**——官方 `convertExtraDataListToBuffer`
  /// 遇到坏条目是 `break`（连同其后的条目一起丢弃），这里保持同样的
  /// 「遇到坏条目就停」语义而不是静默跳过继续。
  static Uint8List encode(List<Qq8ProtocolDetEntry> entries) {
    if (entries.isEmpty) return emptyBody;

    final items = <Qq8ProtocolDetEntry>[];
    for (final e in entries.take(maxItemCount)) {
      if (e.ip.length != 4 && e.ip.length != 16) break; // 官方 break
      items.add(e);
    }
    if (items.isEmpty) return emptyBody;

    final w = ByteWriter()
      ..u8(1) // 协议版本
      ..u8(items.length); // 条目数
    for (final e in items) {
      w
        ..u64(e.uin)
        ..u8(e.ip.length)
        ..raw(e.ip)
        ..u32(e.time)
        ..u32(e.version);
    }
    return w.build();
  }

  /// 解析磁盘上的 `pd2.dat` 内容（裸条目串联，**无 2 字节头**）。
  ///
  /// 与官方 `loadExtraDataFromFile` 同样的容错：
  /// * 文件超过 [maxFileSize] 时直接返回空（官方 `loadFileContent` 拒绝）；
  /// * 遇到 `mlen` 不是 4/16 的条目时**停止解析**并返回已解出的部分
  ///   （官方 `loadExtraDataFromFileUnchecked` 是 `break` 出循环，不是抛异常）；
  /// * 尾部不足一条完整记录时忽略残余字节。
  ///
  /// 至多返回 [maxItemCount] 条。
  static List<Qq8ProtocolDetEntry> decodeFile(Uint8List raw) {
    if (raw.isEmpty || raw.length > maxFileSize) {
      return const <Qq8ProtocolDetEntry>[];
    }

    final out = <Qq8ProtocolDetEntry>[];
    var off = 0;
    while (out.length < maxItemCount) {
      // 最短一条 IPv4 = 21 字节；连 mlen 都读不到就停。
      if (raw.length - off < 9) break;

      final uin = _readU64(raw, off);
      final mlen = raw[off + 8];
      if (mlen != 4 && mlen != 16) break; // 官方 "error: IP Length fault "

      final need = off + 9 + mlen + 8;
      if (raw.length < need) break; // 残余不足一条

      final ip = Uint8List.sublistView(raw, off + 9, off + 9 + mlen);
      final time = _readU32(raw, off + 9 + mlen);
      final version = _readU32(raw, off + 13 + mlen);
      out.add(Qq8ProtocolDetEntry(
        uin: uin,
        ip: Uint8List.fromList(ip),
        time: time,
        version: version,
      ));
      off = need;
    }
    return out;
  }

  /// 从原始 21/33 字节单条目解出记录（官方 `getExtraDataFromBuffer`）。
  ///
  /// 长度不是 21/33 或 `mlen` 不合法时返回 null。
  static Qq8ProtocolDetEntry? decodeSingle(Uint8List raw) {
    if (raw.length != ipv4ItemSize && raw.length != ipv6ItemSize) return null;
    final mlen = raw[8];
    if (mlen != 4 && mlen != 16) return null;
    if (raw.length != 9 + mlen + 8) return null;
    return Qq8ProtocolDetEntry(
      uin: _readU64(raw, 0),
      ip: Uint8List.sublistView(raw, 9, 9 + mlen),
      time: _readU32(raw, 9 + mlen),
      version: _readU32(raw, 13 + mlen),
    );
  }

  /// 把一条新记录并入已有列表，返回**应写盘**的完整列表。
  ///
  /// 逐行照官方 `updateCachedExtraDataFile`（`ProtocolDet.java:431-469`）：
  /// ```java
  /// List list = loadExtraDataFromFile(context, 0);
  /// if (list == null) list = new ArrayList();
  /// if (list.size() < 3) {
  ///     list.add(loginExtraData);
  /// } else {
  ///     int oldest = list.get(0).mTime;
  ///     int idx = 0;
  ///     for (int i = 1; i < list.size(); i++) {
  ///         if (oldest > list.get(i).mTime) { oldest = list.get(i).mTime; idx = i; }
  ///     }
  ///     list.set(idx, loginExtraData);
  /// }
  /// ```
  /// ⚠️ 注意官方这里是**替换 mTime 最小的那条**，不是整体轮转。
  /// 我第一版以为是 FIFO 轮转，读了这段才对上。
  ///
  /// [existing] 是磁盘上已有的条目（[decodeFile] 的结果）。
  /// 返回的列表长度 ≤ [maxItemCount]。
  static List<Qq8ProtocolDetEntry> merge(
    List<Qq8ProtocolDetEntry> existing,
    Qq8ProtocolDetEntry incoming,
  ) {
    final list = List<Qq8ProtocolDetEntry>.from(existing);
    if (list.length < maxItemCount) {
      list.add(incoming);
      return list;
    }
    // 找 mTime 最小者的下标（官方用 **有符号** int 比较 `oldest > list.get(i).mTime`）
    var oldest = list[0].time;
    var idx = 0;
    for (var i = 1; i < list.length; i++) {
      if (oldest > list[i].time) {
        oldest = list[i].time;
        idx = i;
      }
    }
    list[idx] = incoming;
    return list;
  }

  /// 把条目列表编码成**磁盘文件**形态（裸条目串联，无 2 字节头）。
  ///
  /// 与 [encode]（上线 body，带 `01 0N` 头）不同：`pd2.dat` 落盘的格式没有头。
  /// 官方 `updateFile(context, list)` 直接 `convertExtraDataListToBuffer(list)`
  /// 写盘，头只在上线时才由 `packExtraData` 现加。
  static Uint8List encodeFile(List<Qq8ProtocolDetEntry> entries) {
    final w = ByteWriter();
    for (final e in entries) {
      if (e.ip.length != 4 && e.ip.length != 16) continue;
      w
        ..u64(e.uin)
        ..u8(e.ip.length)
        ..raw(e.ip)
        ..u32(e.time)
        ..u32(e.version);
    }
    return w.build();
  }

  static int _readU64(Uint8List b, int off) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | b[off + i];
    }
    return v;
  }

  static int _readU32(Uint8List b, int off) =>
      (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];
}
