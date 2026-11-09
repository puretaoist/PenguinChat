/// `/表情名` 文本 → 表情段的切分。
///
/// 这套切分决定两件事：**发出去的是什么**（协议层要 face 元素）与**本地回显
/// 长什么样**（气泡里要出表情图而不是斜杠加中文）。所以用例两边都钉。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/client_api/chat_store.dart';
import 'package:penguinchat/client_api/face_tokens.dart';
import 'package:penguinchat/client_api/segment.dart';

void main() {
  test('切分：纯文本原样返回一个片段', () {
    expect(splitFaceTokens('你好'), <Object>['你好']);
  });

  test('切分：名字后面紧跟标点也认', () {
    expect(splitFaceTokens('/微笑，你好'), <Object>[14, '，你好']);
    expect(splitFaceTokens('你好/微笑'), <Object>['你好', 14]);
    expect(splitFaceTokens('/微笑/撇嘴'), <Object>[14, 1]);
  });

  test('切分：名字表里没有的斜杠命令原样保留', () {
    expect(splitFaceTokens('/notaface'), <Object>['/notaface']);
    expect(splitFaceTokens('/notaface 你好'), <Object>['/notaface 你好']);
  });

  test('切分：支持 /名字#id 后缀（名字重复时靠它定位）', () {
    // 353 与 200 都叫「拜托」，后缀才是权威。
    expect(splitFaceTokens('/拜托#353'), <Object>[353]);
    // 后缀必须紧贴到名字结束：`#353好` 里的「好」让后缀不再是纯数字，
    // 于是退回按名字查（「拜托」=200），后缀原样留在文本里。
    expect(splitFaceTokens('/拜托#353好'), <Object>[200, '#353好']);
  });

  group('expandFaceTokens', () {
    test('文本里的 /名字 展开成 FaceSegment，顺序不变', () {
      final out = ChatStore.expandFaceTokens(const <Segment>[
        TextSegment('笑一个'),
        TextSegment('/微笑'),
        TextSegment('吧'),
      ]);

      expect(out.length, 3);
      expect((out[0] as TextSegment).text, '笑一个');
      expect((out[1] as FaceSegment).id, '14');
      expect((out[2] as TextSegment).text, '吧');
    });

    test('同一段文本里文本与表情交替也要拆开', () {
      final out = ChatStore.expandFaceTokens(const <Segment>[
        TextSegment('前面/微笑后面'),
      ]);

      expect(out.length, 3);
      expect((out[0] as TextSegment).text, '前面');
      expect((out[1] as FaceSegment).id, '14');
      expect((out[2] as TextSegment).text, '后面');
    });

    test('没有表情时返回同一个列表对象（不白分配）', () {
      const input = <Segment>[TextSegment('纯文本')];
      expect(identical(ChatStore.expandFaceTokens(input), input), isTrue);
    });

    test('非文本段原样保留', () {
      final out = ChatStore.expandFaceTokens(const <Segment>[
        AtSegment('123', name: '小明'),
        TextSegment('/微笑'),
      ]);

      expect(out.length, 2);
      expect(out[0], isA<AtSegment>());
      expect((out[1] as FaceSegment).id, '14');
    });

    test('已经有 FaceSegment 的不动', () {
      final out = ChatStore.expandFaceTokens(const <Segment>[
        FaceSegment('14'),
        TextSegment('/微笑'),
      ]);

      expect(out.length, 2);
      expect((out[0] as FaceSegment).id, '14');
      expect((out[1] as FaceSegment).id, '14');
    });
  });
}
