/// L2 内核：`im_msg_body.Elem` 的解析（收消息的"多元素"入口）
///
/// ## 字段号出处（**两处互相印证**，都来自参考实现 `_ref/oicq-src`）
///
/// 接收侧：`lib/message/parser.ts` 的 `parseElems` / `parsePartialElem` /
/// `parseImgElem`。它按 `Elem` 的字段号分派：
///   1 = 文本  2 = 小表情  4 = 私聊图（NotOnlineImage）  8 = 群图（CustomFace）
///   12 = xml  45 = src_msg（引用）  51 = json  53 = common_elem
///
/// 发送侧：`lib/message/image.ts` 的 `setProto` 与 `lib/message/converter.ts`
/// 的 `face()`。因为构造时字段是**写进去**的，比解析更能说明语义：
///
/// 私聊图（NotOnlineImage，Elem 4）        群图（CustomFace，Elem 8）
///   1  = md5（hex 字符串）                  2  = "{md5}.gif"
///   2  = 文件大小                           7  = fid
///   5  = 图片类型（1000=jpg 1001=png…）      13 = md5（字节）
///   7  = md5（字节）                        16 = URL 片段（服务端给的）
///   8  = **高**                             20 = 图片类型
///   9  = **宽**                             22 = **宽**
///   10 = fid（文件标识，拼直链用）           23 = **高**
///   13 = 原图标记                           25 = 文件大小
///   16 = 类型为 4（face）时填 5              34 = {1: 动画表情标记}
///   29 = {1: 动画表情标记, 30: URL 片段}
///
/// 注意 8/9 是"高在前、宽在后"，与直觉相反——这是 `setProto`（写 8: height、
/// 9: width）与 `parseImgElem`（`buildImageFileParam(md5, size, proto[9],
/// proto[8], type)`，即第 3 个参数 width=proto[9]）两处对上才敢这么写。
///
/// ## 直链怎么来的
///
/// 服务端在元素里给的是**片段**，客户端自己拼域名（参考实现同款）：
///   私聊：`https://c2cpicdw.qpic.cn` + (29.30 | 15 | "/offpic_new/0/{fid}/0")
///   群聊：`https://gchat.qpic.cn` + 16，没有 16 就用 md5 拼
///         `https://gchat.qpic.cn/gchatpic_new/0/0-0-{MD5大写}/0`
///
/// ⚠️ 真机没验证过：我们还没跑通过端到端（见 project-live-login-status）。
/// 直链失效时先看这里，别怀疑 UI——`ImageSegment.url` 拿不到就只显示占位。
///
/// 本文件是纯 Dart（只用 `dart:io` 的 zlib 解卡片消息，不依赖 Flutter）。
library;

import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'qq8_pb.dart';

// ---------------------------------------------------------------------------
// 元素模型（协议层：只描述"线上有什么"，不掺 OneBot/UI 的语义）
// ---------------------------------------------------------------------------

/// 一个 `im_msg_body.Elem`。
sealed class Qq8Elem {
  const Qq8Elem();
}

/// 文本（`Elem.text`）。
class Qq8TextElem extends Qq8Elem {
  final String text;
  const Qq8TextElem(this.text);
}

/// @某人（`Elem.text.attr_6_buf`）。`target == 'all'` 表示 @全体成员。
class Qq8AtElem extends Qq8Elem {
  /// 被 @ 的 uin（十进制字符串）或 `all`。
  final String target;

  /// 线上元素自带的显示名（通常是 `@阿花`，已去掉开头的 `@`）。
  final String? name;

  const Qq8AtElem(this.target, {this.name});

  bool get isAll => target == 'all';
}

/// QQ 表情（`Elem.face`，或 `Elem.common_elem` serviceType=33 的大表情）。
class Qq8FaceElem extends Qq8Elem {
  /// 表情 ID（Qq8FaceNames 里有常用表）。
  final String id;

  /// 大表情（id > 255，走 common_elem 那条路）。
  final bool isBig;

  const Qq8FaceElem(this.id, {this.isBig = false});
}

/// 图片（`Elem` 4 = 私聊图 / 8 = 群图 / common_elem 里的闪照）。
class Qq8ImageElem extends Qq8Elem {
  /// QQ 图片文件名：`{md5}{size}-{宽}-{高}.{扩展名}`（参考实现
  /// `buildImageFileParam`）。转发/重发时原样带回服务端。
  final String file;

  /// 直链（服务端片段 + 域名拼出来的）。拿不到就为 null。
  final String? url;

  /// md5（32 位小写 hex）。
  final String? md5;

  final int? size;
  final int? width;
  final int? height;

  /// 闪照（`common_elem` serviceType=3）。
  final bool flash;

  /// 服务端标的"动画表情"（发出来当成表情包）。
  final bool asFace;

  /// 群图（`Elem.custom_face`）还是私聊图（`Elem.not_online_image`）。
  final bool group;

  const Qq8ImageElem({
    required this.file,
    this.url,
    this.md5,
    this.size,
    this.width,
    this.height,
    this.flash = false,
    this.asFace = false,
    this.group = false,
  });

  /// 给人看的摘要（会话列表、通知、占位框都用它）。
  String get summary => flash
      ? '[闪照]'
      : asFace
          ? '[动画表情]'
          : '[图片]';

  @override
  String toString() =>
      'Qq8ImageElem(${group ? 'group' : 'c2c'} ${flash ? 'flash ' : ''}$file)';
}

/// 语音（`Elem.ptt`，字段 0）。
///
/// 字段号出处：参考实现 `parser.ts` 的 `parseExclusiveElem` 分支 `case 0`——
/// `4 = md5（字节）6 = 大小 19 = 秒数 20 = 直链后缀`（不以 http 开头时前面要补
/// `https://grouptalk.c2c.qq.com`）。
class Qq8VoiceElem extends Qq8Elem {
  final String? md5;
  final int? size;
  final int? seconds;
  final String? url;

  const Qq8VoiceElem({this.md5, this.size, this.seconds, this.url});

  @override
  String toString() => 'Qq8VoiceElem(${seconds}s ${size ?? '?'}B)';
}

/// 短视频（`Elem.video_file`，字段 19）。
///
/// 字段号出处：参考实现同分支 `case 19`——`1 = fid 2 = md5（字节）3 = 文件名
/// 5 = 秒数 6 = 大小`。
class Qq8VideoElem extends Qq8Elem {
  final String? fileId;
  final String? md5;
  final String? name;
  final int? seconds;
  final int? size;

  const Qq8VideoElem({
    this.fileId,
    this.md5,
    this.name,
    this.seconds,
    this.size,
  });

  @override
  String toString() => 'Qq8VideoElem(${name ?? fileId} ${seconds ?? '?'}s)';
}

/// 文件（`Elem.trans_elem`，字段 5；群文件走这条）。
///
/// 字段号出处：参考实现同分支 `case 5`——里面套了三层：
/// `5.2` 的**前 3 字节是头**、跳过之后解出 `7.2` 才是文件信息，
/// 文件信息里 `2 = fid（带 / 前缀）3 = 大小 4 = 文件名 5 = 时长 8 = md5`。
class Qq8FileElem extends Qq8Elem {
  final String? fileId;
  final String? name;
  final int? size;
  final int? seconds;
  final String? md5;

  const Qq8FileElem({
    this.fileId,
    this.name,
    this.size,
    this.seconds,
    this.md5,
  });

  @override
  String toString() => 'Qq8FileElem(${name ?? fileId} ${size ?? '?'}B)';
}

/// 卡片消息（`Elem.rich_msg` 字段 12 / `Elem.light_app` 字段 51）。
///
/// 线上是一段 **XML 或 JSON**，并且可能被 zlib 压过：参考实现
/// `parseExclusiveElem` 的 `case 12/51` 先看第一个字节，`> 0` 就把剩下的
/// inflate，否则原样当文本。我们照做，并顺手从属性里抠一句摘要
/// （`summary=` / `brief=` / `desc=` / `title=`，取到哪个算哪个）——
/// 完整解析卡片结构不是这一层的事。
class Qq8CardElem extends Qq8Elem {
  /// `xml` 或 `json`。
  final String kind;

  /// 解压后的原文（可能很长）。
  final String raw;

  /// 从属性里抠出来的摘要（抠不到为空串）。
  final String summary;

  const Qq8CardElem({
    required this.kind,
    required this.raw,
    this.summary = '',
  });

  /// 从卡片原文里抠一句摘要：`summary=` / `brief=` / `desc=` / `title=` /
  /// `"prompt"`（JSON 卡片）。抠不到就空串（UI 退回 `[卡片消息]` 这类通用文案）。
  ///
  /// 只抠属性、不解析结构：QQ 的卡片 XML/JSON 结构几十种，完整解析属于"卡片渲染"
  /// 那一层的事，这里只要一句给人看的摘要。
  static String extractSummary(String raw) {
    for (final key in const <String>['summary', 'brief', 'desc', 'title']) {
      final m = RegExp('$key\\s*=\\s*"([^"]{1,60})"').firstMatch(raw);
      if (m != null) return m.group(1)!;
    }
    final j = RegExp('"(?:prompt|summary|title)"\\s*:\\s*"([^"]{1,60})"')
        .firstMatch(raw);
    return j?.group(1) ?? '';
  }

  /// 给人看的占位。
  String get preview => summary.isNotEmpty
      ? '[${kind == 'xml' ? '卡片' : '轻应用'}] $summary'
      : (kind == 'xml' ? '[卡片消息]' : '[轻应用消息]');

  @override
  String toString() => 'Qq8CardElem($kind, ${raw.length} 字符)';
}

/// 引用（`Elem.src_msg`，字段 45）。
///
/// 我们**发**出去时用的就是这套字段（见 `qq8_msg.dart` 的 `srcMsgElem`）：
/// `1 = orig_seqs  2 = sender_uin  3 = time  4 = flag  5 = elems（被引用消息的元素）
/// 6 = type`。收到时我们从 5 里的第一个文本元素抠出引用原文给 UI 画引用条。
///
/// 为什么不顺手拼出"被引用消息的 ID"：消息 ID 要 `seq + rand + time`，而 src_msg
/// 里只有 seq/time/发送者，**没有 rand**——拼不出来就不拼，别造一个假 ID 去骗
/// 撤回/跳转那些依赖 ID 的功能。
class Qq8ReplyElem extends Qq8Elem {
  /// 被引用消息的序号。
  final int? seq;

  /// 被引用消息的发送者 uin。
  final int? senderUin;

  /// 被引用消息的时间（秒）。
  final int? time;

  /// 引用原文（从被引用消息的元素里抠的，可能是空串）。
  final String preview;

  const Qq8ReplyElem({
    this.seq,
    this.senderUin,
    this.time,
    this.preview = '',
  });

  @override
  String toString() => 'Qq8ReplyElem(seq=$seq "$preview")';
}

/// 戳一戳（`Elem.common_elem` serviceType=2）。
class Qq8PokeElem extends Qq8Elem {
  /// 动作 id（拿不到就是 null；文案统一用官方的 `[戳一戳]`）。
  final int? id;

  const Qq8PokeElem({this.id});

  @override
  String toString() => 'Qq8PokeElem(${id ?? '?'})';
}

/// **没认出来**的元素。
///
/// 留这个类型是为了两件事：① 气泡里给一句官方文案（`[不支持显示的消息]`），
/// 而不是渲染成空气泡；② 把字段号带出来，真机上遇到新类型时日志里能直接看到。
class Qq8UnsupportedElem extends Qq8Elem {
  /// 元素字段号。
  final int field;

  /// 字段名（`elemName(field)`）。
  final String name;

  const Qq8UnsupportedElem({required this.field, required this.name});

  /// 官方预览文案（`manifest/resources/.../strings.xml` 里就有这一条）。
  static const String preview = '[不支持显示的消息]';

  @override
  String toString() => 'Qq8UnsupportedElem($name/$field)';
}

// ---------------------------------------------------------------------------
// 元素扫描：一条消息的全部元素 → 模型列表 + 纯文本 + @ 目标
// ---------------------------------------------------------------------------

/// 扫描累加器。
///
/// 一次扫完产出三样东西，缺一不可：
/// * [elems]：有序的元素列表，给 UI 渲染（图片/表情/@ 都在里面）；
/// * [text]：**线上原样的纯文本**（含 `@名字` 与 `[图片]` 这类占位），
///   给通知、会话列表摘要、全文检索用；
/// * [atTargets]/[atAll]：@ 判定（比从文本里找 `@` 可靠）。
class Qq8ElemScan {
  final List<Qq8Elem> elems = <Qq8Elem>[];
  final List<String> kinds = <String>[];
  final List<int> atTargets = <int>[];
  final StringBuffer text = StringBuffer();
  bool atAll = false;

  /// 合并相邻文本元素（否则一条消息会被切成一堆 TextSegment）。
  ///
  /// 只处理**真正的文本**；图片/表情那种 `[图片]` 占位只写进 [text]（给摘要和
  /// 通知看），不进 [elems]——不然 UI 会既画占位文字、又画图片块，重复一遍。
  void addText(String s) {
    if (s.isEmpty) return;
    final last = elems.isEmpty ? null : elems.last;
    if (last is Qq8TextElem) {
      elems[elems.length - 1] = Qq8TextElem(last.text + s);
    } else {
      elems.add(Qq8TextElem(s));
    }
  }

  /// `rich_text.elems`（repeated）→ 逐个扫。
  void scanAll(Iterable<Object?> elemBytesList) {
    for (final e in elemBytesList) {
      if (e is Uint8List) scan(e);
    }
  }

  /// 扫一个 `Elem`。
  void scan(Uint8List elem) {
    final m = Qq8Pb.decode(elem);
    if (m.isEmpty) {
      // 空元素（理论上不该出现）：给占位，别让气泡空着
      kinds.add('empty');
      text.write(Qq8UnsupportedElem.preview);
      elems.add(const Qq8UnsupportedElem(field: 0, name: 'empty'));
      return;
    }
    final field = m.keys.first;

    final textBytes = Qq8Pb.bytesAt(m, 1);
    if (textBytes != null) {
      _scanText(textBytes);
      return;
    }

    // 小表情：Face{1 = index}
    final faceBytes = Qq8Pb.bytesAt(m, 2);
    if (faceBytes != null) {
      final id = Qq8Pb.intAt(Qq8Pb.decode(faceBytes), 1);
      kinds.add('face');
      text.write('[表情]');
      if (id != null) elems.add(Qq8FaceElem('$id'));
      return;
    }

    // 私聊图
    final c2cImg = Qq8Pb.bytesAt(m, 4);
    if (c2cImg != null) {
      final img = _parseImage(c2cImg, group: false);
      kinds.add('image');
      text.write(img.summary);
      elems.add(img);
      return;
    }

    // 群图
    final grpImg = Qq8Pb.bytesAt(m, 8);
    if (grpImg != null) {
      final img = _parseImage(grpImg, group: true);
      kinds.add('image');
      text.write(img.summary);
      elems.add(img);
      return;
    }

    // 群文件（transElem，字段 5）
    final trans = Qq8Pb.bytesAt(m, 5);
    if (trans != null) {
      final file = _parseTransElem(trans);
      if (file != null) {
        kinds.add('file');
        text.write('[文件]');
        elems.add(file);
        return;
      }
    }

    // 卡片：xml（12）/ json（51）
    for (final card in const <({int field, String kind})>[
      (field: 12, kind: 'xml'),
      (field: 51, kind: 'json'),
    ]) {
      final cardBytes = Qq8Pb.bytesAt(m, card.field);
      if (cardBytes != null) {
        final c = _parseCard(cardBytes, card.kind);
        kinds.add(card.kind);
        text.write(c.preview);
        elems.add(c);
        return;
      }
    }

    // 短视频（19）
    final video = Qq8Pb.bytesAt(m, 19);
    if (video != null) {
      final v = _parseVideo(video);
      kinds.add('video');
      text.write('[视频]');
      elems.add(v);
      return;
    }

    // common_elem：大表情（33）、闪照（3）、戳一戳（2）走这里；其余只记类型名。
    final common = Qq8Pb.bytesAt(m, 53);
    if (common != null) {
      _scanCommon(common);
      return;
    }

    // 引用：不进正文（UI 用引用条显示），但要解出来给上层
    final replyBytes = Qq8Pb.bytesAt(m, 45);
    if (replyBytes != null) {
      kinds.add('reply');
      elems.add(_parseReply(replyBytes));
      return;
    }

    // 其它结构性元素：不产生内容，也**不能**给"不支持"占位
    // （37 是每条消息都带的保留元素，给了占位就成了"每条消息都多一句话"）
    if (_structuralFields.contains(field)) {
      kinds.add(elemName(field));
      return;
    }

    // 认不出的：记类型 + 给官方文案占位，**不渲染成空气泡**
    final name = elemName(field);
    kinds.add(name);
    text.write(Qq8UnsupportedElem.preview);
    elems.add(Qq8UnsupportedElem(field: field, name: name));
  }

  /// 引用（`Elem.src_msg` = 45 → `im_msg_body.SourceMsg`）。
  Qq8ReplyElem _parseReply(Uint8List srcMsg) {
    final s = Qq8Pb.decode(srcMsg);
    return Qq8ReplyElem(
      seq: Qq8Pb.intAt(s, 1),
      senderUin: Qq8Pb.intAt(s, 2),
      time: Qq8Pb.intAt(s, 3),
      preview: _firstTextOf(s, 5),
    );
  }

  /// 从"一串元素"里抠出第一个文本元素的内容（引用条只需要一句话）。
  static String _firstTextOf(Map<int, List<Object>> m, int tag) {
    final elem = Qq8Pb.bytesAt(m, tag);
    if (elem == null) return '';
    final e = Qq8Pb.decode(elem);
    final textMsg = Qq8Pb.bytesAt(e, 1);
    if (textMsg == null) return '';
    final str = Qq8Pb.bytesAt(Qq8Pb.decode(textMsg), 1);
    return str == null ? '' : utf8.decode(str, allowMalformed: true);
  }

  /// 只做结构、没有内容的元素字段号：
  /// `16 = extra_info  21 = anon_group_msg  37 = general_flags（保留元素）`。
  /// （45 引用在上面单独处理了，它虽然也不进正文，但有内容要带给 UI。）
  static const Set<int> _structuralFields = <int>{16, 21, 37};

  /// 语音：**不在 `elems` 里**，是 `RichText.ptt`（字段 4）。
  ///
  /// 这一点由参考实现的两处对上：接收侧构造里 `if (rich[4]) parseExclusiveElem(0, rich[4])`，
  /// 发送侧 `record()` 里 `this.rich[4] = buf`。所以扫完 elems 之后要单独调它。
  ///
  /// 字段号（ptt 本身）：`4 = md5（字节）6 = 大小 19 = 秒数 20 = 直链后缀`
  /// ——后缀不以 `http` 开头时前面补 `https://grouptalk.c2c.qq.com`。
  void scanPtt(Uint8List ptt) {
    final p = Qq8Pb.decode(ptt);
    final suffix = Qq8Pb.textAt(p, 20);
    kinds.add('voice');
    text.write('[语音]');
    elems.add(Qq8VoiceElem(
      md5: _hex(Qq8Pb.bytesAt(p, 4)),
      size: Qq8Pb.intAt(p, 6),
      seconds: Qq8Pb.intAt(p, 19),
      url: suffix == null
          ? null
          : (suffix.startsWith('http')
              ? suffix
              : 'https://grouptalk.c2c.qq.com$suffix'),
    ));
  }

  /// 短视频（`Elem.video_file`，字段 19）。
  Qq8VideoElem _parseVideo(Uint8List bytes) {
    final v = Qq8Pb.decode(bytes);
    return Qq8VideoElem(
      fileId: Qq8Pb.textAt(v, 1),
      // 参考实现这里存的是 base64；我们统一成 md5 十六进制串，和图片那边一致
      md5: _hex(Qq8Pb.bytesAt(v, 2)),
      name: Qq8Pb.textAt(v, 3),
      seconds: Qq8Pb.intAt(v, 5),
      size: Qq8Pb.intAt(v, 6),
    );
  }

  /// 文件（`Elem.trans_elem`，字段 5）：三层嵌套 + 3 字节头，见 [Qq8FileElem]。
  ///
  /// 解不出来就返回 null（让消息继续按"不支持"渲染），**不让它把整条消息带崩**——
  /// 这段是嵌套解析，畸形数据只影响这一个元素。
  Qq8FileElem? _parseTransElem(Uint8List trans) {
    try {
      final body = Qq8Pb.bytesAt(Qq8Pb.decode(trans), 2);
      if (body == null || body.length <= 3) return null;
      final inner = Qq8Pb.decode(body.sublist(3)); // 前 3 字节是头
      final f7 = Qq8Pb.bytesAt(inner, 7);
      if (f7 == null) return null;
      final file = Qq8Pb.bytesAt(Qq8Pb.decode(f7), 2);
      if (file == null) return null;
      final fi = Qq8Pb.decode(file);
      return Qq8FileElem(
        fileId: Qq8Pb.textAt(fi, 2)?.replaceAll('/', ''),
        size: Qq8Pb.intAt(fi, 3),
        name: Qq8Pb.textAt(fi, 4),
        seconds: Qq8Pb.intAt(fi, 5),
        md5: Qq8Pb.textAt(fi, 8),
      );
    } catch (_) {
      return null;
    }
  }

  /// 卡片（`Elem.rich_msg` = 12 / `Elem.light_app` = 51）。
  ///
  /// 解压规则照参考实现：首字节是标志，`> 0` 表示后面这段是 zlib 压缩的，
  /// 否则后面这段本身就是文本。zlib 解不开就按原文读（不抛，卡片内容不值得
  /// 让整条消息失败）。
  Qq8CardElem _parseCard(Uint8List richMsgBytes, String kind) {
    // 少解一层就会把 richMsg 自己的编码头当成"压缩标志"（这个坑自测抓到了）：
    // `Elem.rich_msg` / `Elem.light_app` 本身是个 message，真正的卡片字节在它的
    // 1 号字段里——参考实现也是 `proto[1].toBuffer()` 之后才看首字节。
    final payload = Qq8Pb.bytesAt(Qq8Pb.decode(richMsgBytes), 1) ?? Uint8List(0);
    final body = payload.length > 1 ? payload.sublist(1) : Uint8List(0);
    String raw;
    if (payload.isNotEmpty && payload[0] > 0) {
      try {
        raw = utf8.decode(zlib.decode(body), allowMalformed: true);
      } catch (_) {
        raw = utf8.decode(body, allowMalformed: true);
      }
    } else {
      raw = utf8.decode(body, allowMalformed: true);
    }
    return Qq8CardElem(
        kind: kind, raw: raw, summary: Qq8CardElem.extractSummary(raw));
  }

  /// `Elem.text`：解两层才是 `1 = str`、`3 = @信息`。
  void _scanText(Uint8List textBytes) {
    final t = Qq8Pb.decode(textBytes);
    final strBytes = Qq8Pb.bytesAt(t, 1);
    final s = strBytes == null ? '' : utf8.decode(strBytes, allowMalformed: true);

    final atBuf = Qq8Pb.bytesAt(t, 3);
    if (atBuf != null && atBuf.length >= 7 && atBuf[1] == 1) {
      kinds.add('at');
      // 线上元素自带 `@名字`；没有就退回 `@uin`（参考实现同款）。
      final name = s.startsWith('@') ? s.substring(1) : s;
      if (atBuf[6] == 1) {
        atAll = true;
        if (s.isEmpty) {
          text.write('@全体成员');
          elems.add(const Qq8AtElem('all'));
        } else {
          text.write(s);
          elems.add(Qq8AtElem('all', name: name));
        }
      } else if (atBuf.length >= 11) {
        final target = (atBuf[7] << 24) |
            (atBuf[8] << 16) |
            (atBuf[9] << 8) |
            atBuf[10];
        atTargets.add(target);
        if (s.isEmpty) {
          text.write('@$target');
          elems.add(Qq8AtElem('$target'));
        } else {
          text.write(s);
          elems.add(Qq8AtElem('$target', name: name));
        }
      } else {
        // 长度不够，解不出目标：当普通文本，别丢字。
        kinds.add('text');
        text.write(s);
        addText(s);
      }
      return;
    }

    kinds.add('text');
    text.write(s);
    addText(s);
  }

  /// `Elem.common_elem{1 = service_type, 2 = pb_elem, 3 = business_type}`。
  void _scanCommon(Uint8List common) {
    final c = Qq8Pb.decode(common);
    final svc = Qq8Pb.intAt(c, 1);
    final pb = Qq8Pb.bytesAt(c, 2);

    // 33 = 大表情：pb_elem 是 Face{1 = id, 2/3 = 名称}
    if (svc == 33 && pb != null) {
      final id = Qq8Pb.intAt(Qq8Pb.decode(pb), 1);
      kinds.add('face');
      text.write('[表情]');
      if (id != null) elems.add(Qq8FaceElem('$id', isBig: true));
      return;
    }

    // 3 = 闪照：pb_elem 里 1 或 2 号字段是那张 NotOnlineImage
    if (svc == 3 && pb != null) {
      final f = Qq8Pb.decode(pb);
      final imgBytes = Qq8Pb.bytesAt(f, 1) ?? Qq8Pb.bytesAt(f, 2);
      if (imgBytes != null) {
        final img = _parseImage(imgBytes, group: false, flash: true);
        kinds.add('image');
        text.write(img.summary);
        elems.add(img);
        return;
      }
    }

    // 2 = 戳一戳：官方预览文案就是 `[戳一戳]`；动作 id 按参考实现那句
    // `proto[3] === 126 ? proto[2][4] : proto[3]` 取（parity 不明就留 null，
    // id 只影响以后做动画，不影响文案）。
    if (svc == 2 && pb != null) {
      final inner = Qq8Pb.decode(pb);
      final bz = Qq8Pb.intAt(c, 3);
      final id = bz == 126 ? Qq8Pb.intAt(inner, 4) : bz;
      kinds.add('poke');
      text.write('[戳一戳]');
      elems.add(Qq8PokeElem(id: id));
      return;
    }

    kinds.add('common(${svc ?? '?'})');
  }

  /// 图片元素 → 模型。字段号见文件头。
  Qq8ImageElem _parseImage(Uint8List bytes,
      {required bool group, bool flash = false}) {
    final i = Qq8Pb.decode(bytes);

    final String? md5;
    final int? size;
    final int? type;
    final int? width;
    final int? height;
    final String? fid;
    String? url;
    bool asFace = false;

    if (group) {
      // 群图（CustomFace）
      md5 = _hex(Qq8Pb.bytesAt(i, 13));
      size = Qq8Pb.intAt(i, 25);
      type = Qq8Pb.intAt(i, 20);
      width = Qq8Pb.intAt(i, 22);
      height = Qq8Pb.intAt(i, 23);
      fid = Qq8Pb.textAt(i, 7);
      final suffix = Qq8Pb.textAt(i, 16);
      url = suffix != null
          ? 'https://gchat.qpic.cn$suffix'
          : (md5 != null
              ? 'https://gchat.qpic.cn/gchatpic_new/0/0-0-'
                  '${md5.toUpperCase()}/0'
              : null);
      asFace = _flag1(i, 34);
    } else {
      // 私聊图（NotOnlineImage）：md5 有两种存法，hex 串优先，字节兜底。
      md5 = Qq8Pb.textAt(i, 1) ?? _hex(Qq8Pb.bytesAt(i, 7));
      size = Qq8Pb.intAt(i, 2);
      type = Qq8Pb.intAt(i, 5);
      width = Qq8Pb.intAt(i, 9);
      height = Qq8Pb.intAt(i, 8);
      fid = Qq8Pb.textAt(i, 10) ?? Qq8Pb.textAt(i, 3);
      final nested = _sub(i, 29);
      final su = nested == null ? null : Qq8Pb.textAt(nested, 30);
      final suffix = Qq8Pb.textAt(i, 15);
      url = su != null
          ? 'https://c2cpicdw.qpic.cn$su&spec=0&rf=naio'
          : suffix != null
              ? 'https://c2cpicdw.qpic.cn$suffix'
              : (fid != null
                  ? 'https://c2cpicdw.qpic.cn/offpic_new/0/$fid/0'
                  : null);
      // 29 号子消息里的 1 号字段就是"动画表情"标记（参考实现同款）
      asFace = nested != null && Qq8Pb.intAt(nested, 1) == 1;
    }

    return Qq8ImageElem(
      file: buildImageFileParam(
        md5: md5 ?? '',
        size: size,
        width: width,
        height: height,
        type: type,
      ),
      url: url,
      md5: md5,
      size: size,
      width: width,
      height: height,
      flash: flash,
      asFace: asFace,
      group: group,
    );
  }
}

/// `{md5}{size}-{宽}-{高}.{扩展名}`（参考实现 `buildImageFileParam`）。
String buildImageFileParam({
  required String md5,
  int? size,
  int? width,
  int? height,
  int? type,
}) =>
    '$md5${size ?? 0}-${width ?? 0}-${height ?? 0}.${imageExt(type)}';

/// 图片类型码 → 扩展名（参考实现 `image.ts` 的 `EXT` 表）。
String imageExt(int? type) => switch (type) {
      3 => 'png',
      4 => 'face',
      1000 => 'jpg',
      1001 => 'png',
      1002 => 'webp',
      1003 => 'jpg',
      1005 => 'bmp',
      2000 => 'gif',
      2001 => 'png',
      _ => 'jpg',
    };

/// 元素字段名 → 诊断用类型名（对不上的走 `unknown(n)`，别猜）。
String elemName(int n) => switch (n) {
      1 => 'text',
      2 => 'face',
      3 => 'online_image',
      4 => 'image',
      5 => 'trans',
      6 => 'bface',
      8 => 'group_image',
      12 => 'xml',
      16 => 'extra',
      19 => 'video',
      21 => 'anon',
      31 => 'mirai',
      34 => 'sface',
      37 => 'flags',
      45 => 'reply',
      51 => 'json',
      53 => 'common',
      _ => 'unknown($n)',
    };

String? _hex(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) return null;
  final b = StringBuffer();
  for (final x in bytes) {
    b.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// 嵌套一层子消息（拿不到返回 null）。
Map<int, List<Object>>? _sub(Map<int, List<Object>> m, int tag) {
  final b = Qq8Pb.bytesAt(m, tag);
  return b == null ? null : Qq8Pb.decode(b);
}

/// 标记子消息（`{tag: {1: 1}}`）是否被置 1。
bool _flag1(Map<int, List<Object>> m, int tag) {
  final sub = _sub(m, tag);
  return sub != null && Qq8Pb.intAt(sub, 1) == 1;
}

// ---------------------------------------------------------------------------
// 表情名表（发送侧 `/名字` → 表情，展示侧 id → 名字）
// ---------------------------------------------------------------------------

/// QQ 表情的 id ↔ 名字。
///
/// **整表照抄**参考实现 `face.ts` 的 `facemap`（267 条，id 0~340 有跳号）——
/// 名字既是展示文案，也是 `/名字` 发送时的输入形式，编错一个就等于发错表情，
/// 所以这张表不手动维护：改的时候从同一来源重新提取，别凭印象加条目。
///
/// 260 以上的"超级表情"在参考实现里的名字自带 `/`（如 `/吃瓜`），那是 QQ 的
/// 线上文本形式；[idOf] 对这类名字额外接受不带斜杠的写法（`吃瓜`）。
abstract final class Qq8FaceNames {
  static const Map<int, String> _byId = <int, String>{
    0: '惊讶',
    1: '撇嘴',
    2: '色',
    3: '发呆',
    4: '得意',
    5: '流泪',
    6: '害羞',
    7: '闭嘴',
    8: '睡',
    9: '大哭',
    10: '尴尬',
    11: '发怒',
    12: '调皮',
    13: '呲牙',
    14: '微笑',
    15: '难过',
    16: '酷',
    18: '抓狂',
    19: '吐',
    20: '偷笑',
    21: '可爱',
    22: '白眼',
    23: '傲慢',
    24: '饥饿',
    25: '困',
    26: '惊恐',
    27: '流汗',
    28: '憨笑',
    29: '悠闲',
    30: '奋斗',
    31: '咒骂',
    32: '疑问',
    33: '嘘',
    34: '晕',
    35: '折磨',
    36: '衰',
    37: '骷髅',
    38: '敲打',
    39: '再见',
    41: '发抖',
    42: '爱情',
    43: '跳跳',
    46: '猪头',
    49: '拥抱',
    53: '蛋糕',
    54: '闪电',
    55: '炸弹',
    56: '刀',
    57: '足球',
    59: '便便',
    60: '咖啡',
    61: '饭',
    63: '玫瑰',
    64: '凋谢',
    66: '爱心',
    67: '心碎',
    69: '礼物',
    74: '太阳',
    75: '月亮',
    76: '赞',
    77: '踩',
    78: '握手',
    79: '胜利',
    85: '飞吻',
    86: '怄火',
    89: '西瓜',
    96: '冷汗',
    97: '擦汗',
    98: '抠鼻',
    99: '鼓掌',
    100: '糗大了',
    101: '坏笑',
    102: '左哼哼',
    103: '右哼哼',
    104: '哈欠',
    105: '鄙视',
    106: '委屈',
    107: '快哭了',
    108: '阴险',
    109: '亲亲',
    110: '吓',
    111: '可怜',
    112: '菜刀',
    113: '啤酒',
    114: '篮球',
    115: '乒乓',
    116: '示爱',
    117: '瓢虫',
    118: '抱拳',
    119: '勾引',
    120: '拳头',
    121: '差劲',
    122: '爱你',
    123: '不',
    124: '好',
    125: '转圈',
    126: '磕头',
    127: '回头',
    128: '跳绳',
    129: '挥手',
    130: '激动',
    131: '街舞',
    132: '献吻',
    133: '左太极',
    134: '右太极',
    136: '双喜',
    137: '鞭炮',
    138: '灯笼',
    140: 'K歌',
    144: '喝彩',
    145: '祈祷',
    146: '爆筋',
    147: '棒棒糖',
    148: '喝奶',
    151: '飞机',
    158: '钞票',
    168: '药',
    169: '手枪',
    171: '茶',
    172: '眨眼睛',
    173: '泪奔',
    174: '无奈',
    175: '卖萌',
    176: '小纠结',
    177: '喷血',
    178: '斜眼笑',
    180: '惊喜',
    181: '骚扰',
    182: '笑哭',
    183: '我最美',
    184: '河蟹',
    185: '羊驼',
    187: '幽灵',
    188: '蛋',
    190: '菊花',
    192: '红包',
    193: '大笑',
    194: '不开心',
    197: '冷漠',
    198: '呃',
    199: '好棒',
    200: '拜托',
    201: '点赞',
    202: '无聊',
    203: '托脸',
    204: '吃',
    205: '送花',
    206: '害怕',
    207: '花痴',
    208: '小样儿',
    210: '飙泪',
    211: '我不看',
    212: '托腮',
    214: '啵啵',
    215: '糊脸',
    216: '拍头',
    217: '扯一扯',
    218: '舔一舔',
    219: '蹭一蹭',
    220: '拽炸天',
    221: '顶呱呱',
    222: '抱抱',
    223: '暴击',
    224: '开枪',
    225: '撩一撩',
    226: '拍桌',
    227: '拍手',
    228: '恭喜',
    229: '干杯',
    230: '嘲讽',
    231: '哼',
    232: '佛系',
    233: '掐一掐',
    234: '惊呆',
    235: '颤抖',
    236: '啃头',
    237: '偷看',
    238: '扇脸',
    239: '原谅',
    240: '喷脸',
    241: '生日快乐',
    242: '头撞击',
    243: '甩头',
    244: '扔狗',
    245: '加油必胜',
    246: '加油抱抱',
    247: '口罩护体',
    260: '/搬砖中',
    261: '/忙到飞起',
    262: '/脑阔疼',
    263: '/沧桑',
    264: '/捂脸',
    265: '/辣眼睛',
    266: '/哦哟',
    267: '/头秃',
    268: '/问号脸',
    269: '/暗中观察',
    270: '/emm',
    271: '/吃瓜',
    272: '/呵呵哒',
    273: '/我酸了',
    274: '/太南了',
    276: '/辣椒酱',
    277: '/汪汪',
    278: '/汗',
    279: '/打脸',
    280: '/击掌',
    281: '/无眼笑',
    282: '/敬礼',
    283: '/狂笑',
    284: '/面无表情',
    285: '/摸鱼',
    286: '/魔鬼笑',
    287: '/哦',
    288: '/请',
    289: '/睁眼',
    290: '/敲开心',
    291: '/震惊',
    292: '/让我康康',
    293: '/摸锦鲤',
    294: '/期待',
    295: '/拿到红包',
    296: '/真好',
    297: '/拜谢',
    298: '/元宝',
    299: '/牛啊',
    300: '/胖三斤',
    301: '/好闪',
    302: '/左拜年',
    303: '/右拜年',
    304: '/红包包',
    305: '/右亲亲',
    306: '/牛气冲天',
    307: '/喵喵',
    308: '/求红包',
    309: '/谢红包',
    310: '/新年烟花',
    311: '/打call',
    312: '/变形',
    313: '/嗑到了',
    314: '/仔细分析',
    315: '/加油',
    316: '/我没事',
    317: '/菜狗',
    318: '/崇拜',
    319: '/比心',
    320: '/庆祝',
    321: '/老色痞',
    322: '/拒绝',
    323: '/嫌弃',
    324: '/吃糖',
    325: '/惊吓',
    326: '/生气',
    327: '/加一',
    328: '/错号',
    329: '/对号',
    330: '/完成',
    331: '/明白',
    332: '/举牌牌',
    333: '/烟花',
    334: '/虎虎生威',
    335: '/绿马护体',
    336: '/豹富',
    337: '/花朵脸',
    338: '/我想开了',
    339: '/舔屏',
    340: '/热化了',
  };

  static const Map<String, int> _byName = <String, int>{
    '惊讶': 0,
    '撇嘴': 1,
    '色': 2,
    '发呆': 3,
    '得意': 4,
    '流泪': 5,
    '害羞': 6,
    '闭嘴': 7,
    '睡': 8,
    '大哭': 9,
    '尴尬': 10,
    '发怒': 11,
    '调皮': 12,
    '呲牙': 13,
    '微笑': 14,
    '难过': 15,
    '酷': 16,
    '抓狂': 18,
    '吐': 19,
    '偷笑': 20,
    '可爱': 21,
    '白眼': 22,
    '傲慢': 23,
    '饥饿': 24,
    '困': 25,
    '惊恐': 26,
    '流汗': 27,
    '憨笑': 28,
    '悠闲': 29,
    '奋斗': 30,
    '咒骂': 31,
    '疑问': 32,
    '嘘': 33,
    '晕': 34,
    '折磨': 35,
    '衰': 36,
    '骷髅': 37,
    '敲打': 38,
    '再见': 39,
    '发抖': 41,
    '爱情': 42,
    '跳跳': 43,
    '猪头': 46,
    '拥抱': 49,
    '蛋糕': 53,
    '闪电': 54,
    '炸弹': 55,
    '刀': 56,
    '足球': 57,
    '便便': 59,
    '咖啡': 60,
    '饭': 61,
    '玫瑰': 63,
    '凋谢': 64,
    '爱心': 66,
    '心碎': 67,
    '礼物': 69,
    '太阳': 74,
    '月亮': 75,
    '赞': 76,
    '踩': 77,
    '握手': 78,
    '胜利': 79,
    '飞吻': 85,
    '怄火': 86,
    '西瓜': 89,
    '冷汗': 96,
    '擦汗': 97,
    '抠鼻': 98,
    '鼓掌': 99,
    '糗大了': 100,
    '坏笑': 101,
    '左哼哼': 102,
    '右哼哼': 103,
    '哈欠': 104,
    '鄙视': 105,
    '委屈': 106,
    '快哭了': 107,
    '阴险': 108,
    '亲亲': 109,
    '吓': 110,
    '可怜': 111,
    '菜刀': 112,
    '啤酒': 113,
    '篮球': 114,
    '乒乓': 115,
    '示爱': 116,
    '瓢虫': 117,
    '抱拳': 118,
    '勾引': 119,
    '拳头': 120,
    '差劲': 121,
    '爱你': 122,
    '不': 123,
    '好': 124,
    '转圈': 125,
    '磕头': 126,
    '回头': 127,
    '跳绳': 128,
    '挥手': 129,
    '激动': 130,
    '街舞': 131,
    '献吻': 132,
    '左太极': 133,
    '右太极': 134,
    '双喜': 136,
    '鞭炮': 137,
    '灯笼': 138,
    'K歌': 140,
    '喝彩': 144,
    '祈祷': 145,
    '爆筋': 146,
    '棒棒糖': 147,
    '喝奶': 148,
    '飞机': 151,
    '钞票': 158,
    '药': 168,
    '手枪': 169,
    '茶': 171,
    '眨眼睛': 172,
    '泪奔': 173,
    '无奈': 174,
    '卖萌': 175,
    '小纠结': 176,
    '喷血': 177,
    '斜眼笑': 178,
    '惊喜': 180,
    '骚扰': 181,
    '笑哭': 182,
    '我最美': 183,
    '河蟹': 184,
    '羊驼': 185,
    '幽灵': 187,
    '蛋': 188,
    '菊花': 190,
    '红包': 192,
    '大笑': 193,
    '不开心': 194,
    '冷漠': 197,
    '呃': 198,
    '好棒': 199,
    '拜托': 200,
    '点赞': 201,
    '无聊': 202,
    '托脸': 203,
    '吃': 204,
    '送花': 205,
    '害怕': 206,
    '花痴': 207,
    '小样儿': 208,
    '飙泪': 210,
    '我不看': 211,
    '托腮': 212,
    '啵啵': 214,
    '糊脸': 215,
    '拍头': 216,
    '扯一扯': 217,
    '舔一舔': 218,
    '蹭一蹭': 219,
    '拽炸天': 220,
    '顶呱呱': 221,
    '抱抱': 222,
    '暴击': 223,
    '开枪': 224,
    '撩一撩': 225,
    '拍桌': 226,
    '拍手': 227,
    '恭喜': 228,
    '干杯': 229,
    '嘲讽': 230,
    '哼': 231,
    '佛系': 232,
    '掐一掐': 233,
    '惊呆': 234,
    '颤抖': 235,
    '啃头': 236,
    '偷看': 237,
    '扇脸': 238,
    '原谅': 239,
    '喷脸': 240,
    '生日快乐': 241,
    '头撞击': 242,
    '甩头': 243,
    '扔狗': 244,
    '加油必胜': 245,
    '加油抱抱': 246,
    '口罩护体': 247,
    '/搬砖中': 260,
    '/忙到飞起': 261,
    '/脑阔疼': 262,
    '/沧桑': 263,
    '/捂脸': 264,
    '/辣眼睛': 265,
    '/哦哟': 266,
    '/头秃': 267,
    '/问号脸': 268,
    '/暗中观察': 269,
    '/emm': 270,
    '/吃瓜': 271,
    '/呵呵哒': 272,
    '/我酸了': 273,
    '/太南了': 274,
    '/辣椒酱': 276,
    '/汪汪': 277,
    '/汗': 278,
    '/打脸': 279,
    '/击掌': 280,
    '/无眼笑': 281,
    '/敬礼': 282,
    '/狂笑': 283,
    '/面无表情': 284,
    '/摸鱼': 285,
    '/魔鬼笑': 286,
    '/哦': 287,
    '/请': 288,
    '/睁眼': 289,
    '/敲开心': 290,
    '/震惊': 291,
    '/让我康康': 292,
    '/摸锦鲤': 293,
    '/期待': 294,
    '/拿到红包': 295,
    '/真好': 296,
    '/拜谢': 297,
    '/元宝': 298,
    '/牛啊': 299,
    '/胖三斤': 300,
    '/好闪': 301,
    '/左拜年': 302,
    '/右拜年': 303,
    '/红包包': 304,
    '/右亲亲': 305,
    '/牛气冲天': 306,
    '/喵喵': 307,
    '/求红包': 308,
    '/谢红包': 309,
    '/新年烟花': 310,
    '/打call': 311,
    '/变形': 312,
    '/嗑到了': 313,
    '/仔细分析': 314,
    '/加油': 315,
    '/我没事': 316,
    '/菜狗': 317,
    '/崇拜': 318,
    '/比心': 319,
    '/庆祝': 320,
    '/老色痞': 321,
    '/拒绝': 322,
    '/嫌弃': 323,
    '/吃糖': 324,
    '/惊吓': 325,
    '/生气': 326,
    '/加一': 327,
    '/错号': 328,
    '/对号': 329,
    '/完成': 330,
    '/明白': 331,
    '/举牌牌': 332,
    '/烟花': 333,
    '/虎虎生威': 334,
    '/绿马护体': 335,
    '/豹富': 336,
    '/花朵脸': 337,
    '/我想开了': 338,
    '/舔屏': 339,
    '/热化了': 340,
    '搬砖中': 260,
    '忙到飞起': 261,
    '脑阔疼': 262,
    '沧桑': 263,
    '捂脸': 264,
    '辣眼睛': 265,
    '哦哟': 266,
    '头秃': 267,
    '问号脸': 268,
    '暗中观察': 269,
    'emm': 270,
    '吃瓜': 271,
    '呵呵哒': 272,
    '我酸了': 273,
    '太南了': 274,
    '辣椒酱': 276,
    '汪汪': 277,
    '汗': 278,
    '打脸': 279,
    '击掌': 280,
    '无眼笑': 281,
    '敬礼': 282,
    '狂笑': 283,
    '面无表情': 284,
    '摸鱼': 285,
    '魔鬼笑': 286,
    '哦': 287,
    '请': 288,
    '睁眼': 289,
    '敲开心': 290,
    '震惊': 291,
    '让我康康': 292,
    '摸锦鲤': 293,
    '期待': 294,
    '拿到红包': 295,
    '真好': 296,
    '拜谢': 297,
    '元宝': 298,
    '牛啊': 299,
    '胖三斤': 300,
    '好闪': 301,
    '左拜年': 302,
    '右拜年': 303,
    '红包包': 304,
    '右亲亲': 305,
    '牛气冲天': 306,
    '喵喵': 307,
    '求红包': 308,
    '谢红包': 309,
    '新年烟花': 310,
    '打call': 311,
    '变形': 312,
    '嗑到了': 313,
    '仔细分析': 314,
    '加油': 315,
    '我没事': 316,
    '菜狗': 317,
    '崇拜': 318,
    '比心': 319,
    '庆祝': 320,
    '老色痞': 321,
    '拒绝': 322,
    '嫌弃': 323,
    '吃糖': 324,
    '惊吓': 325,
    '生气': 326,
    '加一': 327,
    '错号': 328,
    '对号': 329,
    '完成': 330,
    '明白': 331,
    '举牌牌': 332,
    '烟花': 333,
    '虎虎生威': 334,
    '绿马护体': 335,
    '豹富': 336,
    '花朵脸': 337,
    '我想开了': 338,
    '舔屏': 339,
    '热化了': 340,
  };

  /// 表情名 → id（发送 `/名字` 用）。找不到返回 null。
  static int? idOf(String name) => _byName[name.trim()];

  /// id → 表情名（展示用）。找不到返回 null。
  static String? nameOf(String id) {
    final n = int.tryParse(id);
    return n == null ? null : _byId[n];
  }

  /// 面板里摆出来的表情：经典表情里 id ≤ 233 的那一段（超级表情是 `/名字`
  /// 文本形式，输入法里打，不摆面板）。id 顺序按"常用的靠前"排过，不是表序。
  static const List<int> common = <int>[
    14, 13, 20, 21, 12, 11,
    9, 5, 15, 27, 25, 26,
    4, 16, 0, 1, 2, 6,
    22, 23, 28, 29, 30, 31,
    32, 33, 36, 38, 39, 46,
    49, 53, 55, 63, 66, 69,
    74, 76, 78, 79, 85, 89,
    96, 97, 98, 99, 101, 104,
    105, 106, 107, 108, 112, 113,
    114, 115, 116, 117, 119, 120,
    121, 122, 123, 124, 132, 133,
    134, 136, 137, 138, 144, 146,
    147, 148, 151, 158, 168, 169,
    171, 172, 173, 174, 175, 176,
    177, 178, 180, 181, 182, 183,
    184, 185, 187, 188, 190, 192,
    193, 194, 197, 198, 199, 200,
    201, 202, 203, 204, 205, 206,
    207, 208, 210, 211, 212, 214,
    215, 216, 217, 218, 219, 220,
    221, 222, 223, 224, 225, 226,
    227, 228, 229, 230, 231, 232,
    233,
  ];
}
