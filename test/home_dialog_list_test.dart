import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/client_api/objects.dart';
import 'package:penguinchat/ui/chat/home_dialog_list.dart';

void main() {
  const a = Chat(id: 'a', title: 'A');
  const b = Chat(id: 'b', title: 'B', archived: true);
  const c = Chat(id: 'c', title: 'C', pinned: true);

  test('投影保留业务顺序，归档合成一行且索引可逆', () {
    final rows = HomeDialogList([a, b, c]);
    expect(rows.visible, [a, c]);
    expect(rows.archived, [b]);
    expect(rows.length, 3);
    expect(rows.isArchive(0), isTrue);
    expect(rows.isArchive(1), isFalse);
    expect(rows.chatAt(1), same(a));
    expect(rows.chatAt(2), same(c));
    expect(rows.indexOf('a'), 1);
    expect(rows.indexOf('c'), 2);
    expect(rows.indexOf('b'), isNull);
    expect(rows.indexOf('missing'), isNull);
  });

  test('无归档时直接从零索引，列表快照不随输入变化', () {
    final input = [a, c];
    final rows = HomeDialogList(input);
    input.clear();
    expect(rows.length, 2);
    expect(rows.hasArchive, isFalse);
    expect(rows.isArchive(0), isFalse);
    expect(rows.chatAt(0), same(a));
    expect(rows.indexOf('a'), 0);
    expect(() => rows.visible.add(b), throwsUnsupportedError);
    expect(() => rows.archived.add(b), throwsUnsupportedError);
  });

  test('显式归档选择保留，缺失选择回退未归档首项', () {
    expect(HomeDialogList.resolveSelected([b, a, c], 'b'), 'b');
    expect(HomeDialogList.resolveSelected([b, a, c], 'c'), 'c');
    expect(HomeDialogList.resolveSelected([b, a, c], 'missing'), 'a');
    expect(HomeDialogList.resolveSelected([b, a, c], null), 'a');
  });

  test('全归档仍有入口和默认选择，空列表清空选择', () {
    final rows = HomeDialogList([b]);
    expect(rows.length, 1);
    expect(rows.isArchive(0), isTrue);
    expect(HomeDialogList.resolveSelected([b], null), 'b');
    expect(HomeDialogList.resolveSelected([], 'a'), isNull);
    expect(HomeDialogList([]).length, 0);
  });
}
