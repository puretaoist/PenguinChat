/// L3 客户端 API 层：消息段模型
///
/// ## 为什么需要这一层
///
/// 现状 `ChatMessage` 只有一个 `text` 字段，撑不住日用的消息体。参考两个
/// 对标项目的做法后选定**类型化段数组**：
///
/// | 项目 | 表示法 | 评价 |
/// |---|---|---|
/// | Icalingua++ | `content: string` + `files[]` + `file.order`（UTF-16 偏移） | ❌ 偏移会算错表情，老消息无此字段 |
/// | Stapxs | `MsgItemElem = {type: string, [k: string]: any}` | ❌ 无类型，判类型靠 `item.type == '…'` 链 |
/// | **本项目** | `sealed class Segment` + 各子类 | ✅ 编译期穷尽检查，UI 层 switch 不漏分支 |
///
/// OneBot 11 的消息体原生就是段数组（`[{type, data}]`），所以这一层几乎是
/// 一对一映射，不需要 Icalingua 那种偏移重建的复杂度。
///
/// ## 双格式
///
/// OneBot 允许后端把消息发成两种格式（`messagePostFormat` 配置）：
///   - **array**：`[{"type":"text","data":{"text":"hi"}}]` ← 默认，本层主格式
///   - **string**：`[CQ:image,file=a.jpg]` ← CQ 码，老实现仍在用
///
/// [Segment.parseList] 两种都能吃，[toArrayData] 只产出 array 格式。
///
/// 本文件**不依赖 Flutter**，可在纯 Dart 自测里跑。
library;

/// 消息段基类。
///
/// 新增段类型时：加子类 → 实现 [toData] 与 [preview] → 编译器会提示所有
/// 需要补分支的 switch。这是选 sealed 而不是 `Map<String,dynamic>` 的全部理由。
sealed class Segment {
  const Segment();

  /// OneBot array 格式里的 `type` 字段。
  String get type;

  /// 序列化回 `data` 字段（发送时用）。
  Map<String, dynamic> toData();

  /// 单段的人类可读预览，用于通知、会话列表摘要、降级显示。
  String get preview;

  /// 是否与文本行内排布。
  ///
  /// 行内：文本 / 表情 / @  —— 可以和文字连在一行
  /// 块级：图片 / 语音 / 文件 / 转发 —— 单独占一行
  bool get isInline => false;

  /// 是否带媒体资源（用于判断是否需要走 BlobStore 缓存）。
  bool get hasMedia => false;

  /// 解析一条 OneBot 段。
  factory Segment.parse(Object? raw) {
    if (raw is String) {
      return TextSegment(raw);
    }
    if (raw is! Map) {
      return UnknownSegment('invalid', {'raw': raw});
    }
    final map = raw.cast<String, dynamic>();
    final type = (map['type'] as String?) ?? '';
    final data = (map['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return switch (type) {
      'text' => TextSegment.fromData(data),
      'face' => FaceSegment.fromData(data),
      'image' => ImageSegment.fromData(data),
      'record' => RecordSegment.fromData(data),
      'video' => VideoSegment.fromData(data),
      'at' => AtSegment.fromData(data),
      'reply' => ReplySegment.fromData(data),
      'file' => FileSegment.fromData(data),
      'forward' => ForwardSegment.fromData(data),
      'json' => JsonSegment.fromData(data),
      'xml' => XmlSegment.fromData(data),
      'poke' => PokeSegment.fromData(data),
      'rps' => PokeSegment.fromData(data),
      'dice' => PokeSegment.fromData(data),
      _ => UnknownSegment(type, data),
    };
  }

  /// 解析整个消息体：兼容 array 格式与 CQ 码字符串格式。
  static List<Segment> parseList(Object? message) {
    if (message == null) return const [];
    if (message is List) {
      // 畸形实现可能在数组里塞 null 或非对象条目；直接丢弃，
      // 而不是为每条造一个无效段污染 UI。
      return message
          .where((e) => e is String || e is Map)
          .map(Segment.parse)
          .toList(growable: false);
    }
    if (message is String) {
      return parseCqCodes(message);
    }
    if (message is Map) {
      // 少数实现会把单段直接作为对象返回
      return [Segment.parse(message)];
    }
    return const [];
  }

  /// 序列化成 OneBot array 格式（发送用）。
  static List<Map<String, dynamic>> toArrayData(List<Segment> segments) =>
      segments.map((s) => {'type': s.type, 'data': s.toData()}).toList();

  /// 拼接出可搜索 / 可复制的纯文本摘要。
  ///
  /// 这条同时解决了两个问题：会话列表的 `lastMessage` 预览，
  /// 以及存储层的全文检索字段（对应 Icalingua++ 独立 FTS5 库里存的内容）。
  static String plainText(List<Segment> segments, {bool skipReply = true}) {
    final buf = StringBuffer();
    for (final s in segments) {
      if (skipReply && s is ReplySegment) continue;
      if (s is TextSegment) {
        buf.write(s.text);
      } else {
        buf.write(s.preview);
      }
    }
    return buf.toString().trim();
  }

  /// 是否包含 @ 我或 @ 全体。
  static bool mentions(List<Segment> segments, {required String selfId}) {
    for (final s in segments) {
      if (s is AtSegment && (s.qq == 'all' || s.qq == selfId)) return true;
    }
    return false;
  }
}

// ---------------------------------------------------------------------------
// 行内段
// ---------------------------------------------------------------------------

/// 纯文本。
class TextSegment extends Segment {
  final String text;
  const TextSegment(this.text);

  factory TextSegment.fromData(Map<String, dynamic> data) =>
      TextSegment((data['text'] as String?) ?? '');

  @override
  String get type => 'text';

  @override
  Map<String, dynamic> toData() => {'text': text};

  @override
  String get preview => text;

  @override
  bool get isInline => true; // text

  @override
  String toString() => 'TextSegment(${text.length} chars)';
}

/// QQ 表情。
class FaceSegment extends Segment {
  /// 表情 ID（字符串，对应 QQ 表情表）。
  final String id;

  /// 是否大表情。
  final bool isBig;

  const FaceSegment(this.id, {this.isBig = false});

  factory FaceSegment.fromData(Map<String, dynamic> data) => FaceSegment(
        (data['id'] as String?) ?? '',
        isBig: data['is_big'] == true || data['is_big'] == 1,
      );

  @override
  String get type => 'face';

  @override
  Map<String, dynamic> toData() => {
        'id': id,
        if (isBig) 'is_big': true,
      };

  @override
  String get preview => '[表情]';

  @override
  bool get isInline => true;

  @override
  String toString() => 'FaceSegment($id)';
}

/// @某人。`qq == 'all'` 表示 @全体成员。
class AtSegment extends Segment {
  final String qq;

  /// 显示名（部分后端会带）。
  final String? name;

  const AtSegment(this.qq, {this.name});

  factory AtSegment.fromData(Map<String, dynamic> data) => AtSegment(
        (data['qq'] ?? '').toString(),
        name: data['name'] as String?,
      );

  bool get isAll => qq == 'all';

  @override
  String get type => 'at';

  @override
  Map<String, dynamic> toData() => {'qq': qq, if (name != null) 'name': name};

  @override
  String get preview => isAll ? '@全体成员' : '@${name ?? qq}';

  @override
  bool get isInline => true;

  @override
  String toString() => 'AtSegment($qq)';
}

// ---------------------------------------------------------------------------
// 块级段
// ---------------------------------------------------------------------------

/// 图片。
class ImageSegment extends Segment {
  /// 文件名或 URL 或 base64:// 前缀。
  ///
  /// 协议线收到的是 QQ 的图片文件名（`{md5}{大小}-{宽}-{高}.{扩展名}`）；
  /// OneBot 后端给的是路径或 base64。
  final String file;

  /// 后端给的直链（接收侧才有）。
  final String? url;

  /// 图片摘要文本（QQ 的"图片"占位）。
  final String? summary;

  /// 闪照。
  final bool flash;

  /// 原始宽高（像素）。协议线会给（QQ 图片元素里有），OneBot 后端多半没有——
  /// UI 拿它算占位框的宽高比，拿不到就退回方形占位。
  final int? width;
  final int? height;

  const ImageSegment(
    this.file, {
    this.url,
    this.summary,
    this.flash = false,
    this.width,
    this.height,
  });

  factory ImageSegment.fromData(Map<String, dynamic> data) => ImageSegment(
        (data['file'] as String?) ?? '',
        url: data['url'] as String?,
        summary: data['summary'] as String?,
        flash: data['type'] == 'flash',
        width: _intOf(data['width']),
        height: _intOf(data['height']),
      );

  static int? _intOf(Object? v) =>
      v is int ? v : (v == null ? null : int.tryParse('$v'));

  /// 传输层优先用直链，没有则回落到 file（可能是本地路径或 base64）。
  String get bestSource => (url != null && url!.isNotEmpty) ? url! : file;

  /// 宽高比（宽/高）。拿不到宽高返回 null。
  double? get aspectRatio {
    final w = width, h = height;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return w / h;
  }

  @override
  String get type => 'image';

  @override
  Map<String, dynamic> toData() => {
        'file': file,
        if (url != null) 'url': url,
        if (summary != null) 'summary': summary,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        if (flash) 'type': 'flash',
      };

  @override
  String get preview => summary?.isNotEmpty == true ? summary! : '[图片]';

  @override
  bool get hasMedia => true;

  @override
  String toString() => 'ImageSegment(${flash ? 'flash ' : ''}$file)';
}

/// 语音。
class RecordSegment extends Segment {
  final String file;
  final String? url;
  final String? text;

  /// 变声。
  final bool magic;

  /// 时长（秒）与体积（字节）。协议线会给（QQ 的语音元素里有），OneBot 多半没有。
  final int? seconds;
  final int? size;

  const RecordSegment(
    this.file, {
    this.url,
    this.text,
    this.magic = false,
    this.seconds,
    this.size,
  });

  factory RecordSegment.fromData(Map<String, dynamic> data) => RecordSegment(
        (data['file'] as String?) ?? '',
        url: data['url'] as String?,
        text: data['text'] as String?,
        magic: data['magic'] == true || data['magic'] == 1,
        seconds: _asInt(data['seconds'] ?? data['duration']),
        size: _asInt(data['size']),
      );

  String get bestSource => (url != null && url!.isNotEmpty) ? url! : file;

  @override
  String get type => 'record';

  @override
  Map<String, dynamic> toData() => {
        'file': file,
        if (url != null) 'url': url,
        if (seconds != null) 'seconds': seconds,
        if (size != null) 'size': size,
        if (magic) 'magic': '1',
      };

  @override
  String get preview => '[语音]';

  @override
  bool get hasMedia => true;

  @override
  String toString() => 'RecordSegment($file)';
}

/// 短视频。
class VideoSegment extends Segment {
  final String file;
  final String? url;

  /// 文件名、时长（秒）、体积（字节）——协议线会给，OneBot 多半没有。
  final String? name;
  final int? seconds;
  final int? size;

  const VideoSegment(this.file, {this.url, this.name, this.seconds, this.size});

  factory VideoSegment.fromData(Map<String, dynamic> data) => VideoSegment(
        (data['file'] as String?) ?? '',
        url: data['url'] as String?,
        name: data['name'] as String?,
        seconds: _asInt(data['seconds'] ?? data['duration']),
        size: _asInt(data['size']),
      );

  String get bestSource => (url != null && url!.isNotEmpty) ? url! : file;

  @override
  String get type => 'video';

  @override
  Map<String, dynamic> toData() => {
        'file': file,
        if (url != null) 'url': url,
        if (name != null) 'name': name,
        if (seconds != null) 'seconds': seconds,
        if (size != null) 'size': size,
      };

  @override
  String get preview => '[视频]';

  @override
  bool get hasMedia => true;

  @override
  String toString() => 'VideoSegment($file)';
}

/// 文件。
class FileSegment extends Segment {
  final String file;

  /// 后端文件 ID（群文件下载要用）。
  final String? fileId;

  final String? name;
  final int? size;

  const FileSegment(this.file, {this.fileId, this.name, this.size});

  factory FileSegment.fromData(Map<String, dynamic> data) => FileSegment(
        (data['file'] as String?) ?? '',
        fileId: (data['file_id'] ?? data['id'])?.toString(),
        name: data['name'] as String?,
        size: _asInt(data['size']),
      );

  @override
  String get type => 'file';

  @override
  Map<String, dynamic> toData() => {
        'file': file,
        if (name != null) 'name': name,
        if (fileId != null) 'file_id': fileId,
      };

  @override
  String get preview => name?.isNotEmpty == true ? '[文件] $name' : '[文件]';

  @override
  bool get hasMedia => true;

  @override
  String toString() => 'FileSegment($name)';
}

/// 回复引用。
///
/// 只保留回复**所需的最小信息**（被引用消息的 ID + 摘要），不嵌套完整
/// `ChatMessage`——Icalingua++ 的 `replyMessage?: Message` 会造成递归嵌套，
/// 解码时容易失控。
class ReplySegment extends Segment {
  final String messageId;
  final String? text;
  final String? qq;
  final DateTime? time;

  const ReplySegment(this.messageId, {this.text, this.qq, this.time});

  factory ReplySegment.fromData(Map<String, dynamic> data) => ReplySegment(
        (data['id'] ?? data['message_id'] ?? '').toString(),
        text: data['text'] as String?,
        qq: data['qq']?.toString(),
        time: _asDateTime(data['time']),
      );

  @override
  String get type => 'reply';

  @override
  Map<String, dynamic> toData() => {
        'id': messageId,
        if (text != null) 'text': text,
      };

  @override
  String get preview => text?.isNotEmpty == true ? '[回复]$text' : '[回复]';

  @override
  String toString() => 'ReplySegment($messageId)';
}

/// 合并转发。
class ForwardSegment extends Segment {
  /// 转发资源 ID（拿它去调 `get_forward_msg` 拉内容）。
  final String id;

  /// 已展开的节点（后端直接内联返回时才有）。
  final List<ForwardNode>? content;

  const ForwardSegment(this.id, {this.content});

  factory ForwardSegment.fromData(Map<String, dynamic> data) => ForwardSegment(
        (data['id'] ?? '') .toString(),
        content: (data['content'] as List?)
            ?.whereType<Map>()
            .map((e) => ForwardNode.fromMap(e.cast<String, dynamic>()))
            .toList(),
      );

  @override
  String get type => 'forward';

  @override
  Map<String, dynamic> toData() => {'id': id};

  @override
  String get preview => '[聊天记录]';

  @override
  String toString() => 'ForwardSegment($id, nodes=${content?.length})';
}

/// 合并转发里的一个节点。
class ForwardNode {
  final String senderName;
  final int? senderId;
  final DateTime? time;
  final List<Segment> content;

  const ForwardNode({
    required this.senderName,
    this.senderId,
    this.time,
    this.content = const [],
  });

  factory ForwardNode.fromMap(Map<String, dynamic> map) {
    final sender = (map['sender'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ForwardNode(
      senderName: (sender['nickname'] as String?) ?? '',
      senderId: _asInt(sender['user_id']),
      time: _asDateTime(map['time']),
      content: Segment.parseList(map['message'] ?? map['content']),
    );
  }

  String get preview => Segment.plainText(content);
}

/// JSON 卡片消息（小程序、分享等）。
class JsonSegment extends Segment {
  final String data;

  /// 从卡片里抠出来的一句摘要（协议线给的；抠不到为空）。
  final String summary;

  const JsonSegment(this.data, {this.summary = ''});

  factory JsonSegment.fromData(Map<String, dynamic> d) => JsonSegment(
        (d['data'] as String?) ?? '',
        summary: (d['summary'] as String?) ?? '',
      );

  @override
  String get type => 'json';

  @override
  Map<String, dynamic> toData() => {
        'data': data,
        if (summary.isNotEmpty) 'summary': summary,
      };

  @override
  String get preview => summary.isNotEmpty ? '[轻应用] $summary' : '[轻应用消息]';

  @override
  String toString() => 'JsonSegment(${data.length} chars)';
}

/// XML 消息（富媒体卡片、文件分享等）。
class XmlSegment extends Segment {
  final String data;

  /// 从卡片里抠出来的一句摘要（协议线给的；抠不到为空）。
  final String summary;

  const XmlSegment(this.data, {this.summary = ''});

  factory XmlSegment.fromData(Map<String, dynamic> d) => XmlSegment(
        (d['data'] as String?) ?? '',
        summary: (d['summary'] as String?) ?? '',
      );

  @override
  String get type => 'xml';

  @override
  Map<String, dynamic> toData() => {
        'data': data,
        if (summary.isNotEmpty) 'summary': summary,
      };

  @override
  String get preview => summary.isNotEmpty ? '[卡片] $summary' : '[卡片消息]';

  @override
  String toString() => 'XmlSegment(${data.length} chars)';
}

/// 戳一戳 / 骰子 / 猜拳这类交互段。
class PokeSegment extends Segment {
  final String kind;
  final String? id;

  const PokeSegment(this.kind, {this.id});

  factory PokeSegment.fromData(Map<String, dynamic> d) =>
      PokeSegment((d['type'] as String?) ?? 'poke', id: d['id']?.toString());

  @override
  String get type => 'poke';

  @override
  Map<String, dynamic> toData() => {
        if (id != null) 'id': id,
      };

  @override
  String get preview => switch (kind) {
        'dice' => '[骰子]',
        'rps' => '[猜拳]',
        _ => '[戳一戳]',
      };

  @override
  String toString() => 'PokeSegment($kind)';
}

/// 未知段类型。
///
/// **刻意保留原始数据**而不是丢弃：客户端版本更新前遇到后端新加的段类型时，
/// 至少还能转发、还能看到原始内容，而不是静默变成空白。
class UnknownSegment extends Segment {
  final String rawType;
  final Map<String, dynamic> data;

  const UnknownSegment(this.rawType, this.data);

  @override
  String get type => 'unknown';

  @override
  Map<String, dynamic> toData() => data;

  @override
  String get preview => rawType.isEmpty ? '[不支持的消息]' : '[$rawType]';

  @override
  String toString() => 'UnknownSegment($rawType)';
}

// ---------------------------------------------------------------------------
// CQ 码解析（string 格式兼容）
// ---------------------------------------------------------------------------

/// 解析 CQ 码字符串，例如 `你好[CQ:image,file=a.jpg]世界`。
///
/// 除标准转义外，部分实现还会把 `&#91;` 等实体写进 CQ 码内部，
/// 这里一并还原。
List<Segment> parseCqCodes(String raw) {
  if (raw.isEmpty) return const [];

  final segments = <Segment>[];
  var buf = StringBuffer();
  var i = 0;

  void flushText() {
    if (buf.isNotEmpty) {
      // string 格式里，文本部分的 `& [ ] ,` 是被转义的实体，必须还原，
      // 否则消息里会直接显示 `&#91;` 这种字符串。
      segments.add(TextSegment(_unescapeCq(buf.toString())));
      buf = StringBuffer();
    }
  }

  while (i < raw.length) {
    final start = raw.indexOf('[CQ:', i);
    if (start < 0) {
      buf.write(raw.substring(i));
      break;
    }
    buf.write(raw.substring(i, start));
    final end = raw.indexOf(']', start);
    if (end < 0) {
      // 没有闭合，当作普通文本
      buf.write(raw.substring(start));
      break;
    }

    final body = raw.substring(start + 4, end);
    final parts = body.split(',');
    final type = parts.first.trim();
    final data = <String, dynamic>{};
    for (final p in parts.skip(1)) {
      final eq = p.indexOf('=');
      if (eq <= 0) continue;
      data[p.substring(0, eq).trim()] = _unescapeCq(p.substring(eq + 1));
    }

    flushText();
    segments.add(Segment.parse({'type': type, 'data': data}));
    i = end + 1;
  }

  flushText();
  return segments;
}

String _unescapeCq(String s) => s
    .replaceAll('&#91;', '[')
    .replaceAll('&#93;', ']')
    .replaceAll('&#44;', ',')
    .replaceAll('&amp;', '&');

/// 转义文本，供 [toCqCodes] 使用。
String _escapeCq(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('[', '&#91;')
    .replaceAll(']', '&#93;')
    .replaceAll(',', '&#44;');

/// 序列化成 CQ 码字符串（个别后端只吃 string 格式时用）。
String toCqCodes(List<Segment> segments) {
  final buf = StringBuffer();
  for (final s in segments) {
    if (s is TextSegment) {
      buf.write(_escapeCq(s.text));
      continue;
    }
    if (s is UnknownSegment) {
      buf.write('[${s.rawType}]');
      continue;
    }
    final data = s.toData();
    final kv = data.entries
        .where((e) => e.value != null)
        .map((e) => '${e.key}=${_escapeCq(e.value.toString())}')
        .join(',');
    buf.write(kv.isEmpty ? '[CQ:${s.type}]' : '[CQ:${s.type},$kv]');
  }
  return buf.toString();
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

int? _asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

DateTime? _asDateTime(Object? v) {
  final n = _asInt(v);
  if (n == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(n * 1000);
}
