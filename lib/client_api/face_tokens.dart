/// 把文本里的 `/表情名` 切成「文本 / 表情 id」两类片段。
///
/// ## 为什么要放在这里（L3），而不是留在 qq8 适配器里
///
/// 最初这套切分只写在 `Qq8SessionAdapter._elemsOf` 里，作用是"发出去时把
/// `/微笑` 变成表情元素"。但它同时决定**本地回显长什么样**：用户点表情面板插进
/// 输入框的是 `/微笑` 这段文本，如果本地只存 `TextSegment('/微笑')`，气泡里就会
/// 出现一串斜杠加中文，而不是表情图——只有等服务器回推才可能变。
///
/// 所以切分必须发生在 `ChatStore.send` 插入本地消息之前。为了让 OneBot 线也能
/// 复用（它的 face 段 id 与 QQ 表情 id 是同一套），这里做成后端无关的纯函数，
/// 两个适配器与 store 都调它。
///
/// ## 规则（对齐官方客户端行为）
///
/// * 只有名字表（[Qq8FaceNames]）里查得到的才当表情——`/notaface` 原样当文本，
///   不能把用户打的斜杠命令吞掉。
/// * 名字后面紧跟标点也认：`/微笑，你好` → 表情 + `，你好`。做法是从长到短试
///   名字，而不是要求用空格隔开（QQ 用户不会专门为表情加空格）。
/// * 支持 `/名字#id` 后缀：表情名可能重复（两个表情都叫「拜托」），后缀才是
///   权威。表情包生成 token 时，名字反查不到自己就会加这个后缀
///   （见 `lib/ui/face/face_pack.dart` 的 `FaceEntry.token`）。
library;

import '../kernel/wlogin8/qq8_elem.dart';

/// 表情名候选的终止符（空白与常见标点）。
final RegExp _faceNameStop = RegExp(r'[\s\u3000，。！？、,.!?~～:：;；]');

/// 返回值里 `String` = 文本片段，`int` = 表情 id，顺序即消息顺序。
List<Object> splitFaceTokens(String text) {
  final out = <Object>[];
  final buf = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final slash = text.indexOf('/', i);
    if (slash < 0) {
      buf.write(text.substring(i));
      break;
    }
    // 候选名字：斜杠后面到空白/下一个斜杠为止
    var end = slash + 1;
    while (end < text.length &&
        text[end] != '/' &&
        !_faceNameStop.hasMatch(text[end])) {
      end++;
    }
    int? id;
    var nameEnd = end;
    // 带 id 后缀的写法（`/拜托#353`）：名字可能被别人占用，后缀才是权威。
    final hash = text.indexOf('#', slash + 1);
    if (hash > slash + 1 && hash < end) {
      final suffixed = int.tryParse(text.substring(hash + 1, end));
      if (suffixed != null) {
        id = suffixed;
        nameEnd = end;
      }
    }
    while (id == null && nameEnd > slash + 1) {
      id = Qq8FaceNames.idOf(text.substring(slash + 1, nameEnd));
      if (id != null) break;
      nameEnd--;
    }
    if (id == null) {
      buf.write(text.substring(i, slash + 1));
      i = slash + 1;
      continue;
    }
    if (slash > i) buf.write(text.substring(i, slash));
    if (buf.isNotEmpty) {
      out.add(buf.toString());
      buf.clear();
    }
    out.add(id);
    i = nameEnd;
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
}
