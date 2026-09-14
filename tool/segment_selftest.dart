/// 消息段模型 + L3 数据对象 的离线自测
///
/// 纯 Dart，不需要 Flutter 引擎、不需要后端、不需要 QQ 账号。
///
/// 覆盖：
///   1. 各段类型的解析与序列化往返
///   2. OneBot array 格式（主格式）
///   3. CQ 码 string 格式（兼容老实现），含转义还原
///   4. 纯文本摘要派生（会话预览 / 全文检索字段）
///   5. @我 / @全体 判定
///   6. 未知段保留原始数据不丢信息
///   7. Chat 复合 ID 与反解
///   8. ChatMessage 的撤回 / 揭示语义
///
/// 运行：
/// ```bash
/// & "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe" run tool/segment_selftest.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:qqclient/client_api/objects.dart';
import 'package:qqclient/client_api/segment.dart';

// ---------------------------------------------------------------------------
// 断言
// ---------------------------------------------------------------------------

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  \u2713 $name');
  } else {
    _failed++;
    stdout.writeln('  \u2717 $name${detail == null ? '' : '  → $detail'}');
  }
}

void checkEq(String name, Object? actual, Object? expected) {
  final ok = jsonEncode(actual) == jsonEncode(expected);
  check(name, ok, ok ? null : '期望 ${jsonEncode(expected)}，实际 ${jsonEncode(actual)}');
}

void section(String t) => stdout.writeln('\n$t');

// ---------------------------------------------------------------------------

void testArrayFormat() {
  section('1. array 格式解析（主格式）');

  final raw = [
    {'type': 'text', 'data': {'text': '你好 '}},
    {'type': 'at', 'data': {'qq': '10001', 'name': '小明'}},
    {'type': 'face', 'data': {'id': '178'}},
    {
      'type': 'image',
      'data': {'file': 'a.jpg', 'url': 'http://x/a.jpg', 'summary': '[图片]'},
    },
    {'type': 'reply', 'data': {'id': '42', 'text': '上一条'}},
    {'type': 'record', 'data': {'file': 'v.amr'}},
    {'type': 'file', 'data': {'file': 'f.zip', 'file_id': 'fid1', 'name': 'f.zip', 'size': 1024}},
    {'type': 'forward', 'data': {'id': 'resid-1'}},
    {'type': 'json', 'data': {'data': '{"app":"x"}'}},
    {'type': 'xml', 'data': {'data': '<msg/>'}},
  ];

  final segs = Segment.parseList(raw);
  check('段数量解析正确', segs.length == 10, 'len=${segs.length}');

  check('text', segs[0] is TextSegment && (segs[0] as TextSegment).text == '你好 ');
  check('at', segs[1] is AtSegment && (segs[1] as AtSegment).qq == '10001');
  check('at 带显示名', (segs[1] as AtSegment).name == '小明');
  check('face', segs[2] is FaceSegment && (segs[2] as FaceSegment).id == '178');
  check('image', segs[3] is ImageSegment && (segs[3] as ImageSegment).url == 'http://x/a.jpg');
  check('reply', segs[4] is ReplySegment && (segs[4] as ReplySegment).messageId == '42');
  check('record', segs[5] is RecordSegment);
  check('file', segs[6] is FileSegment && (segs[6] as FileSegment).size == 1024);
  check('forward', segs[7] is ForwardSegment && (segs[7] as ForwardSegment).id == 'resid-1');
  check('json', segs[8] is JsonSegment);
  check('xml', segs[9] is XmlSegment);

  // 行内 / 块级分类（决定 UI 排版）
  check('text 为行内', segs[0].isInline);
  check('at 为行内', segs[1].isInline);
  check('face 为行内', segs[2].isInline);
  check('image 为块级', !segs[3].isInline);
  check('image 标记含媒体', segs[3].hasMedia);
  check('text 不标记媒体', !segs[0].hasMedia);
}

void testRoundTrip() {
  section('2. 序列化往返');

  const segs = <Segment>[
    TextSegment('hi'),
    AtSegment('all'),
    FaceSegment('178'),
    ImageSegment('a.jpg', url: 'http://x/a.jpg'),
    ReplySegment('42', text: '上一条'),
    FileSegment('f.zip', fileId: 'fid1', name: 'f.zip'),
    PokeSegment('poke', id: '1'),
  ];

  final data = Segment.toArrayData(segs);
  checkEq('序列化出 7 段', data.length, 7);
  checkEq('text 段结构', data[0], {
    'type': 'text',
    'data': {'text': 'hi'},
  });
  checkEq('at 段结构', data[1]['type'], 'at');
  checkEq('image 段保留 url', (data[3]['data'] as Map)['url'], 'http://x/a.jpg');

  final back = Segment.parseList(data);
  check('往返段数一致', back.length == segs.length);
  check('往返 text 一致', (back[0] as TextSegment).text == 'hi');
  check('往返 at 一致', (back[1] as AtSegment).qq == 'all');
  check('往返 image url 一致', (back[3] as ImageSegment).url == 'http://x/a.jpg');
  check('往返 reply 一致', (back[4] as ReplySegment).messageId == '42');
  check('往返 file 一致', (back[5] as FileSegment).fileId == 'fid1');

  // 图片的宽高：协议线收到的是原始尺寸，UI 拿它算占位框比例，
  // 落盘再读回不能丢（丢了就只能退回方形占位）
  final withSize = ImageSegment('b.jpg',
      url: 'https://gchat.qpic.cn/x',
      summary: '[动画表情]',
      width: 320,
      height: 240);
  final sizeBack =
      Segment.parseList(Segment.toArrayData(<Segment>[withSize])).first
          as ImageSegment;
  check(
      '往返图片宽高与摘要一致',
      sizeBack.width == 320 &&
          sizeBack.height == 240 &&
          sizeBack.summary == '[动画表情]' &&
          sizeBack.aspectRatio == 320 / 240,
      '${sizeBack.width}x${sizeBack.height} ${sizeBack.summary}');
  check('没有宽高时比例返回 null（不瞎猜成 1）',
      const ImageSegment('c.jpg').aspectRatio == null);
}

void testCqCode() {
  section('3. CQ 码格式（string）兼容');

  final segs = Segment.parseList('你好[CQ:at,qq=10001][CQ:image,file=a.jpg]世界');
  check('CQ 码拆出 4 段', segs.length == 4, 'len=${segs.length}');
  check('前段文本', (segs[0] as TextSegment).text == '你好');
  check('at 段', (segs[1] as AtSegment).qq == '10001');
  check('image 段', (segs[2] as ImageSegment).file == 'a.jpg');
  check('后段文本', (segs[3] as TextSegment).text == '世界');

  // 转义还原：CQ 码内部用实体表示特殊字符
  final escaped = Segment.parseList('[CQ:image,file=a&#91;1&#93;.jpg]');
  check('实体转义被还原', (escaped[0] as ImageSegment).file == 'a[1].jpg');

  // 未闭合的 [CQ: 当成普通文本
  final broken = Segment.parseList('abc[CQ:image,file=x');
  check('未闭合 CQ 码不丢内容', broken.length == 1 && (broken[0] as TextSegment).text.contains('abc'));

  // 序列化回 CQ 码
  const out = <Segment>[
    TextSegment('看看这个'),
    ImageSegment('a.jpg'),
    AtSegment('10001'),
  ];
  final cq = toCqCodes(out);
  check('CQ 码序列化包含 image', cq.contains('[CQ:image,file=a.jpg]'), cq);
  check('CQ 码序列化包含 at', cq.contains('[CQ:at,qq=10001]'), cq);

  // 文本里的特殊字符被转义，避免被误解析
  final tricky = toCqCodes(const [TextSegment('a[1],b')]);
  check('文本中的 [] 与逗号被转义', !tricky.contains('[CQ:'), tricky);
  final reparsed = Segment.parseList(tricky);
  check('转义后可无损还原', (reparsed[0] as TextSegment).text == 'a[1],b',
      (reparsed[0] as TextSegment).text);
}

void testPlainText() {
  section('4. 纯文本摘要（预览 / 检索字段）');

  final segs = Segment.parseList([
    {'type': 'reply', 'data': {'id': '1', 'text': '被引用的'}},
    {'type': 'text', 'data': {'text': '你好 '}},
    {'type': 'at', 'data': {'qq': 'all'}},
    {'type': 'image', 'data': {'file': 'a.jpg'}},
    {'type': 'face', 'data': {'id': '1'}},
  ]);

  checkEq('默认跳过回复段', Segment.plainText(segs), '你好 @全体成员[图片][表情]');
  check('包含回复时保留', Segment.plainText(segs, skipReply: false).startsWith('[回复]'));

  // 每种段都有预览，不会出现空串
  const all = <Segment>[
    FaceSegment('1'),
    ImageSegment('a'),
    RecordSegment('r'),
    VideoSegment('v'),
    FileSegment('f', name: 'g.zip'),
    ForwardSegment('id'),
    JsonSegment('{}'),
    XmlSegment('<x/>'),
    PokeSegment('dice'),
  ];
  final missing = all.where((s) => s.preview.isEmpty).toList();
  check('所有段类型都有非空预览', missing.isEmpty, '缺失=${missing.map((e) => e.type)}');
  check('文件预览带文件名',
      const FileSegment('f', name: 'g.zip').preview.contains('g.zip'));
}

void testMentions() {
  section('5. @ 判定');

  const me = '10001';
  check('@我 命中',
      Segment.mentions(const [AtSegment('10001')], selfId: me));
  check('@别人 不命中',
      !Segment.mentions(const [AtSegment('10002')], selfId: me));
  check('@全体 命中',
      Segment.mentions(const [AtSegment('all')], selfId: me));
  check('无 at 段不命中',
      !Segment.mentions(const [TextSegment('hi')], selfId: me));
}

void testUnknownSegment() {
  section('6. 未知段不丢信息');

  const raw = {
    'type': 'brand_new_thing',
    'data': {'foo': 1, 'bar': 'x'},
  };
  final seg = Segment.parse(raw);
  check('落到 UnknownSegment', seg is UnknownSegment);
  check('保留原始类型名', (seg as UnknownSegment).rawType == 'brand_new_thing');
  check('保留原始数据', seg.data['foo'] == 1 && seg.data['bar'] == 'x');
  check('预览可见', seg.preview == '[brand_new_thing]');
  checkEq('可原样转发', seg.toData(), {'foo': 1, 'bar': 'x'});

  // 非法输入不崩：null 无法解释为任何有效段，落 Unknown 以保留信息
  check('null 落 UnknownSegment（不丢信息）', Segment.parse(null) is UnknownSegment);
  check('非 Map 非 String 落到 Unknown', Segment.parse(42) is UnknownSegment);
  checkEq('null 消息体返回空表', Segment.parseList(null), <Object?>[]);

  // 数组里的畸形条目被丢弃，而不是变成无效段
  final dirty = Segment.parseList([
    {'type': 'text', 'data': {'text': 'ok'}},
    null,
    42,
    {'type': 'text', 'data': {'text': 'tail'}},
  ]);
  check('畸形条目被过滤', dirty.length == 2, 'len=${dirty.length}');
  check('过滤后内容正确',
      (dirty[0] as TextSegment).text == 'ok' && (dirty[1] as TextSegment).text == 'tail');
}

void testChatKey() {
  section('7. Chat 复合 ID');

  checkEq('群 ID 生成', Chat.keyOf(ChatType.group, 123), 'group_123');
  checkEq('私聊 ID 生成', Chat.keyOf(ChatType.private, 456), 'private_456');

  final g = Chat.parseKey('group_123');
  check('群 ID 反解类型', g?.type == ChatType.group);
  check('群 ID 反解数字', g?.id == 123);

  final p = Chat.parseKey('private_456');
  check('私聊 ID 反解', p?.type == ChatType.private && p?.id == 456);

  check('非法 ID 返回 null', Chat.parseKey('garbage') == null);
  check('未知前缀返回 null', Chat.parseKey('unknown_1') == null);

  // 同名 ID 在私聊与群里不冲突——这就是用复合 ID 的理由
  check('私聊与群不撞号',
      Chat.keyOf(ChatType.private, 100) != Chat.keyOf(ChatType.group, 100));

  const chat = Chat(id: 'group_1', title: '测试群', memberCount: 42, type: ChatType.group);
  check('isGroup 正确', chat.isGroup);
  check('copyWith 保留未改字段', chat.copyWith(unreadCount: 5).title == '测试群');
  check('copyWith 改优先级', chat.copyWith(priority: 1).priority == 1);
}

void testChatMessageSemantics() {
  section('8. ChatMessage 语义（撤回 / 揭示 / @我）');

  final base = ChatMessage.fromSegments(
    id: 'm1',
    segments: Segment.parseList([
      {'type': 'reply', 'data': {'id': 'm0', 'text': '上一条'}},
      {'type': 'text', 'data': {'text': '你好'}},
      {'type': 'at', 'data': {'qq': '10001'}},
    ]),
    time: DateTime(2026, 9, 11, 10, 30),
    senderName: '小明',
    senderId: '20002',
    chatId: 'group_1',
    selfId: '10001',
  );

  check('text 摘要自动派生', base.text == '你好@10001', base.text);
  check('回复 ID 从段数组自动提取', base.replyToId == 'm0');
  check('回复摘要自动提取', base.replyPreview == '上一条');
  check('@我 自动判定', base.atMe);
  check('未撤回时 displayText == text', base.displayText == '你好@10001');
  check('!isRecalled', !base.isRecalled);

  // 撤回：不删除，只置标记（对齐 Icalingua++ 的 renewMessage 补丁语义）
  final recalled = base.recalled(recallInfo: '{"time":1,"operator_id":1}');
  check('撤回后 isRecalled', recalled.isRecalled);
  check('撤回后 displayText 变为提示', recalled.displayText == '[消息已撤回]');
  check('撤回后原始 text 仍在（可揭示）', recalled.text == '你好@10001');
  check('撤回记录 recallInfo', recalled.recallInfo != null);
  check('撤回后段数组保留', recalled.segments.length == 3);

  // 揭示
  final revealed = recalled.reveal();
  check('揭示后不再是 isRecalled', !revealed.isRecalled);
  check('揭示后恢复原文', revealed.displayText == '你好@10001');

  // 媒体标记
  final withImage = ChatMessage.fromSegments(
    id: 'm2',
    segments: Segment.parseList([
      {'type': 'image', 'data': {'file': 'a.jpg'}},
    ]),
    time: DateTime(2026, 9, 11),
  );
  check('含媒体被标记', withImage.hasMedia);
  check('纯文本不标记媒体', !base.hasMedia);

  // 自己发的消息不判 @我
  final mine = ChatMessage.fromSegments(
    id: 'm3',
    segments: Segment.parseList([
      {'type': 'at', 'data': {'qq': '10001'}},
    ]),
    time: DateTime(2026, 9, 11),
    outgoing: true,
    selfId: '',
  );
  check('未传 selfId 时不误判 @我', !mine.atMe);

  // 直接传 text 的兼容路径（历史数据 / 系统消息）
  final legacy = ChatMessage(id: 'old', text: '旧数据', time: DateTime(2026, 9, 11));
  check('直接构造仍可用', legacy.text == '旧数据' && legacy.segments.isEmpty);
  check('直接构造 displayText 正常', legacy.displayText == '旧数据');

  check('copyWith 保留未改字段', base.copyWith(outgoing: true).senderName == '小明');
  check('withDerivedText 重算摘要',
      base.copyWith(text: '错').withDerivedText().text == '你好@10001');
}

void testChatMember() {
  section('9. 群成员');

  const m = ChatMember(id: '1', nickname: '小明', card: '群昵称', role: 'admin');
  check('群名片优先于昵称', m.displayName == '群昵称');
  check('admin 判定', m.isAdmin);

  const m2 = ChatMember(id: '2', nickname: '小红');
  check('无群名片回落昵称', m2.displayName == '小红');
  check('普通成员非 admin', !m2.isAdmin);
}

// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('消息段模型 + L3 数据对象 离线自测');
  stdout.writeln('=' * 60);

  testArrayFormat();
  testRoundTrip();
  testCqCode();
  testPlainText();
  testMentions();
  testUnknownSegment();
  testChatKey();
  testChatMessageSemantics();
  testChatMember();

  stdout.writeln('\n${'=' * 60}');
  stdout.writeln('通过 $_passed 项，失败 $_failed 项');
  exit(_failed == 0 ? 0 : 1);
}
