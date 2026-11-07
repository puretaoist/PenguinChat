import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/ui/chat/chat_draft_controller.dart';

void main() {
  testWidgets('防抖只保存最新输入，程序恢复不产生写入', (tester) async {
    final writes = <String>[];
    final c = ChatDraftController();
    c.bind(
      owner: Object(),
      chatId: 'a',
      text: '原草稿',
      write: (id, text) async {
        writes.add('$id:$text');
      },
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(writes, isEmpty);
    c.input.text = '一';
    await tester.pump(const Duration(milliseconds: 400));
    c.input.text = '二';
    await tester.pump(const Duration(milliseconds: 599));
    expect(writes, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(writes, ['a:二']);
    c.dispose();
  });
  testWidgets('同会话ID换store先保存旧归属再恢复新草稿', (tester) async {
    final oldWrites = <String>[];
    final newWrites = <String>[];
    final c = ChatDraftController();
    c.bind(
      owner: Object(),
      chatId: 'same',
      text: '旧',
      write: (id, text) async {
        oldWrites.add(text);
      },
    );
    await tester.pump();
    c.input.text = '旧账号输入';
    c.bind(
      owner: Object(),
      chatId: 'same',
      text: '新账号草稿',
      write: (id, text) async {
        newWrites.add(text);
      },
    );
    expect(oldWrites, ['旧账号输入']);
    await tester.pump();
    expect(c.input.text, '新账号草稿');
    c.input.text = '新账号输入';
    c.dispose();
    expect(newWrites, ['新账号输入']);
  });
  testWidgets('同帧快速切换仅最新回调生效，销毁不写尚未恢复的内容', (tester) async {
    final writes = <String>[];
    final c = ChatDraftController();
    final owner = Object();
    Future<void> write(String id, String text) async {
      writes.add('$id:$text');
    }

    c.bind(owner: owner, chatId: 'a', text: 'A', write: write);
    c.bind(owner: owner, chatId: 'b', text: 'B', write: write);
    await tester.pump();
    expect(c.input.text, 'B');
    expect(writes, isEmpty);
    c.bind(owner: owner, chatId: 'c', text: 'C', write: write);
    c.dispose();
    await tester.pump();
    expect(writes, isEmpty);
  });
}
