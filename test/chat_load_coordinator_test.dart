import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/ui/chat/chat_load_coordinator.dart';

void main() {
  test('请求中复用Future，完成后不重复加载', () async {
    final c = ChatLoadCoordinator()..bind(Object());
    final gate = Completer<void>();
    var calls = 0;
    Future<void> load() {
      calls++;
      return gate.future;
    }

    final a = c.run('a', load);
    final b = c.run('a', load);
    expect(identical(a, b), isTrue);
    expect(calls, 1);
    gate.complete();
    await a;
    await c.run('a', load);
    expect(calls, 1);
    c.dispose();
  });
  test('旧store慢完成不得清掉新store同ID请求', () async {
    final c = ChatLoadCoordinator()..bind(Object());
    final old = Completer<void>();
    final a = c.run('same', () => old.future);
    final rev = c.revision;
    c.bind(Object());
    final fresh = Completer<void>();
    final b = c.run('same', () => fresh.future);
    old.complete();
    await a;
    expect(c.isCurrent(rev), isFalse);
    expect(identical(b, c.run('same', () async => fail('不得重复'))), isTrue);
    fresh.complete();
    await b;
    c.dispose();
  });
  test('失败允许重试，主动重试不复制正在进行的请求', () async {
    final c = ChatLoadCoordinator()..bind(Object());
    await expectLater(
      c.run('a', () async => throw StateError('offline')),
      throwsStateError,
    );
    expect(c.contains('a'), isFalse);
    final gate = Completer<void>();
    final a = c.run('a', () => gate.future);
    c.retry('a');
    expect(identical(a, c.run('a', () async => fail('重复'))), isTrue);
    gate.complete();
    await a;
    final rev = c.revision;
    c.dispose();
    expect(c.isCurrent(rev), isFalse);
  });
}
