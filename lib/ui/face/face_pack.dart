/// QQ 表情资源包（`assets/faces/faces.pqf`，PQFC v1）。
///
/// ## 为什么打成单个二进制包，而不是几百个 png 文件
///
/// 1. **asset 清单不能太大**：Flutter 的 `AssetManifest` 会在每个 asset 上留一条
///    记录，333 张图就是 333 条；打包后只有 1 条。
/// 2. **首帧不用等几百次 IO**：一次 `rootBundle.load` 拿到全部字节，解析只是读
///    一张索引表，没有 per-file 的 open/stat。
/// 3. **压缩比可控**：源站给的是 PNG（全套 7.8MB）和 APNG（44.8MB），打包时统一
///    转成 96×96 WebP，静态 q88、动态按帧数抽稀到 12~24 帧 q75，最终 10.68MB
///    同时覆盖**静态与动态**——比只带 APNG 小 4 倍。
///
/// 这不是 Telegram 的 `EPK3`（那是它自己的调色板 + 差分编码格式，为 64×64 的
/// emoji 表优化的）。我方只有 333 条、每条已经是 WebP，再做差分编码收益有限，
/// 所以用最简单的「头 + JSON 索引 + 连续 payload」。
///
/// ## 格式（全部小端）
///
/// ```
/// Header 32 字节
///   0  char[4] 'PQFC'
///   4  u16     version = 2
///   6  u16     reserved
///   8  u32     entryCount
///   12 u32     metaOffset
///   16 u32     metaLength
///   20 u32     dataOffset
///   24 u32     fileSize
///   28 u32     reserved
/// Meta：UTF-8 JSON 数组，每项
///   {id, name, type, kind, w, h, off, len, frames}
///   kind 是 'lottie'（payload 为 gzip 的 Lottie json）或 'webp'
///   off 相对 dataOffset
/// Data：连续 payload
///
/// v1（已废弃）把动态表情存成 animated WebP，265 条共 35.6 MB；v2 换成矢量
/// Lottie（110 条 gzip 共 2.8 MB）+ 静态 WebP（155 条 0.65 MB），包体 3.48 MB
/// 且矢量在 160px 预览下仍然锐利。解析时两个版本都认。
/// ```
///
/// ## 生命周期
///
/// 在 `main()` 里 `await FacePack.ensureLoaded()`，之后 [instance] 同步可用。
/// 测试里不加载也照常跑——所有取用点都对 null 做了回退（显示 `[名字]` 文本），
/// 所以既有断言不受影响。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../kernel/wlogin8/qq8_elem.dart';

/// payload 的编码方式。
enum FaceKind {
  /// gzip 压缩的 Lottie json（矢量，可任意缩放）。
  lottie,

  /// WebP（静态；v1 包里也可能是 animated WebP）。
  webp,
}

/// 包里的一条表情。
@immutable
class FaceEntry {
  const FaceEntry({
    required this.id,
    required this.name,
    required this.type,
    required this.kind,
    required this.width,
    required this.height,
    required this.offset,
    required this.length,
    required this.frames,
    this.bbox = const Rect.fromLTRB(0, 0, 1, 1),
  });

  /// QQ 表情 id。数字 id 是经典表情，非数字（`☀`/`🍉` 这类）是 Unicode 原生 emoji。
  final String id;

  /// 展示名（取自 QFace 的 `describe`，去掉了前导 `/`）。
  final String name;

  /// QFace 的 `emojiType`：0 静态 / 1 动态 / 2 多段 lottie / 3 动态 / 4 Unicode / 5 互动。
  final int type;

  /// payload 类型：[FaceKind.lottie]（gzip 的 Lottie json）或 [FaceKind.webp]。
  final FaceKind kind;

  final int width;
  final int height;

  /// payload 在数据区里的偏移与长度。
  final int offset;
  final int length;

  /// 帧数（静态为 1）。
  final int frames;

  /// 内容包围盒（归一化 0..1，相对资源自身的画布）。
  ///
  /// 两种资源的内容留白差别很大：Lottie 画布 512×512 但内容可能只占 27%，
  /// 静态 WebP 是从官方 PNG 重编码的、内容占 92%~95%。渲染时按这个框裁掉留白，
  /// 两类表情看起来才会一样大（用户 2026-11-07 报的就是这个）。
  ///
  /// 数据由 `tmp_qface/bbox_all.py` 算出：WebP 用自身 alpha 包围盒，Lottie 用
  /// 同一个表情的 APNG 全帧 alpha 并集（比解析 lottie 几何可靠——嵌套 precomp
  /// 的变换很容易漏）。
  final Rect bbox;

  /// 是否是经典小表情（可以塞进一行文字里）。
  ///
  /// 官方把 id ≤ 340 的数字表情叫「经典表情」，其余（超级表情、互动表情）在面板里
  /// 单列。判据用 id 是否为纯数字且 ≤ 340，与 `Qq8FaceNames` 的分段一致。
  bool get isClassic {
    final n = int.tryParse(id);
    return n != null && n <= 340;
  }

  /// 发送时用的文本形式（`/名字`）。
  ///
  /// 展示名以 QFace 为准，但发送侧认的是 `Qq8FaceNames` 的名字表。两者有 62
  /// 条不一致（例如 109 这里叫「左亲亲」，协议表里是「亲亲」），直接用展示名
  /// 会打出 `/左亲亲` 而发送侧解析不出来。所以这里优先用**能被协议层解析**
  /// 的名字，解析不了才退回展示名。
  String get token {
    // 名字能反查回自己就用名字（最常见）。
    if (Qq8FaceNames.idOf(name) == int.tryParse(id) &&
        int.tryParse(id) != null) {
      return '/$name';
    }
    final protocolName = Qq8FaceNames.nameOf(id);
    if (protocolName != null &&
        Qq8FaceNames.idOf(protocolName) == int.tryParse(id)) {
      return '/$protocolName';
    }
    // 名字被别人占用（例如 353 与常量表里的 200 都叫「拜托」）时，名字这条路
    // 表达不出这个 id，退回带 id 后缀的写法：`/拜托#353`。
    final n = int.tryParse(id);
    if (n == null) return '/$name';
    return '/$name#$n';
  }
}

/// 已解析的表情包。
class FacePack {
  FacePack._(this._raw, this._entries, this._byId, this._byName);

  final Uint8List _raw;
  final List<FaceEntry> _entries;
  final Map<String, FaceEntry> _byId;
  final Map<String, FaceEntry> _byName;

  /// 全局单例。`main()` 里加载后才有值；测试里可以是 null。
  static FacePack? instance;

  /// 全部条目，顺序与包内一致（按 id 长度、再按 id 字典序）。
  List<FaceEntry> get all => _entries;

  /// 经典小表情（id ≤ 340 的数字表情）。
  List<FaceEntry> get classic =>
      _entries.where((e) => e.isClassic).toList(growable: false);

  /// 非经典（超级表情 / 互动表情 / Unicode 原生）。
  List<FaceEntry> get others =>
      _entries.where((e) => !e.isClassic).toList(growable: false);

  FaceEntry? byId(String id) => _byId[id];

  FaceEntry? byName(String name) => _byName[name];

  /// 取某条的 WebP 字节（零拷贝视图）。
  Uint8List bytesOf(FaceEntry e) =>
      Uint8List.sublistView(_raw, e.offset, e.offset + e.length);

  /// 包体字节数（诊断用）。
  int get byteLength => _raw.length;

  /// 把包里的名字注册成协议层别名，让 `/名字` 能解析出 id。
  ///
  /// 数字 id 才有意义（Unicode 原生 emoji 的 id 不是协议里的表情 id）。常量表
  /// 里已有的写法不会被覆盖，所以「亲亲」仍然是「亲亲」，不会变成「左亲亲」。
  void registerProtocolAliases() {
    final aliases = <String, int>{};
    for (final e in _entries) {
      final n = int.tryParse(e.id);
      if (n == null) continue;
      aliases[e.name] = n;
      // 展示名与协议名不同时，两个都能解析（点面板用展示名，手打常用协议名）。
      final protocolName = Qq8FaceNames.nameOf(e.id);
      if (protocolName != null) aliases[protocolName] = n;
    }
    Qq8FaceNames.registerAliases(aliases);
  }

  static const String assetPath = 'assets/faces/faces.pqf';

  /// 从 asset 加载并解析。重复调用直接返回已有实例。
  static Future<FacePack> ensureLoaded() async {
    final existing = instance;
    if (existing != null) return existing;

    final ByteData data = await rootBundle.load(assetPath);
    final raw = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final pack = FacePack._parse(raw);
    instance = pack;
    return pack;
  }

  /// 解析一段字节（测试与诊断用；正式路径走 [ensureLoaded]）。
  @visibleForTesting
  static FacePack parseForTest(Uint8List raw) => _parse(raw);

  /// 读元数据里的 bbox；缺失或格式不对时按满幅。
  static Rect _rect(Object? raw) {
    if (raw is List && raw.length == 4) {
      final v = raw.map((e) => (e as num).toDouble()).toList(growable: false);
      return Rect.fromLTRB(v[0], v[1], v[2], v[3]);
    }
    return const Rect.fromLTRB(0, 0, 1, 1);
  }

  static FacePack _parse(Uint8List raw) {
    if (raw.length < 32) {
      throw const FormatException('faces.pqf 太短，读不出头部');
    }
    final bd = ByteData.sublistView(raw);
    final magic = String.fromCharCodes(raw.sublist(0, 4));
    if (magic != 'PQFC') {
      throw FormatException('faces.pqf 魔数不对：$magic');
    }
    final version = bd.getUint16(4, Endian.little);
    if (version != 1 && version != 2) {
      throw FormatException('faces.pqf 版本不支持：$version');
    }
    final count = bd.getUint32(8, Endian.little);
    final metaOffset = bd.getUint32(12, Endian.little);
    final metaLength = bd.getUint32(16, Endian.little);
    final dataOffset = bd.getUint32(20, Endian.little);
    final fileSize = bd.getUint32(24, Endian.little);
    if (fileSize != raw.length) {
      throw FormatException('faces.pqf 长度不符：头写 $fileSize，实际 ${raw.length}');
    }

    final metaText = utf8.decode(
      Uint8List.sublistView(raw, metaOffset, metaOffset + metaLength),
    );
    final list = (jsonDecode(metaText) as List<dynamic>)
        .cast<Map<String, dynamic>>();
    if (list.length != count) {
      throw FormatException('faces.pqf 条目数不符：头写 $count，索引 ${list.length}');
    }

    final entries = <FaceEntry>[];
    final byId = <String, FaceEntry>{};
    final byName = <String, FaceEntry>{};
    for (final m in list) {
      final e = FaceEntry(
        id: m['id'] as String,
        name: m['name'] as String,
        type: (m['type'] as num?)?.toInt() ?? 0,
        kind: (m['kind'] as String?) == 'lottie'
            ? FaceKind.lottie
            : FaceKind.webp,
        width: (m['w'] as num).toInt(),
        height: (m['h'] as num).toInt(),
        offset: dataOffset + (m['off'] as num).toInt(),
        length: (m['len'] as num).toInt(),
        frames: (m['frames'] as num?)?.toInt() ?? 1,
        bbox: _rect(m['bbox']),
      );
      if (e.offset + e.length > raw.length) {
        throw FormatException('faces.pqf 条目 ${e.id} 越界');
      }
      entries.add(e);
      byId[e.id] = e;
      // 重名时经典表情优先（例：452 是超级表情「微笑」，14 才是经典的
      // 那个；按名字反查应该拿到 14，否则面板点出来的 token 会指向超级表情）。
      final prev = byName[e.name];
      if (prev == null || (e.isClassic && !prev.isClassic)) {
        byName[e.name] = e;
      }
    }

    return FacePack._(raw, entries, byId, byName);
  }
}
