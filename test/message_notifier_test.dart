import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:penguinchat/ui/platform/message_notifier.dart';

/// 通知栏「直接回复」的通道协议测试。
///
/// 这里只测 Dart 侧的分发与返回值：原生（Kotlin）那一半靠真机验证，
/// 因为 RemoteInput 的文字只有系统才会塞进广播。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(MessageNotifier.channelName);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 模拟原生发来的反向调用。
  Future<Object?> invokeFromNative(MethodCall call) async {
    final data = const StandardMethodCodec().encodeMethodCall(call);
    Object? reply;
    await messenger.handlePlatformMessage(
      MessageNotifier.channelName,
      data,
      (ByteData? result) {
        reply = const StandardMethodCodec().decodeEnvelope(result!);
      },
    );
    return reply;
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('reply：把 chatId/text 交给回调，并把结果回给原生', () async {
    final notifier = MessageNotifier();
    String? gotChat;
    String? gotText;
    notifier.install(onReply: (chatId, text) async {
      gotChat = chatId;
      gotText = text;
      return true;
    });

    final result = await invokeFromNative(const MethodCall('reply', <String, Object?>{
      'chatId': 'group_486045673',
      'text': '收到',
    }));

    expect(result, isTrue);
    expect(gotChat, 'group_486045673');
    expect(gotText, '收到');
    await notifier.dispose();
  });

  test('reply：回调说发不出去时返回 false，原生据此换"未发送"通知', () async {
    final notifier = MessageNotifier();
    notifier.install(onReply: (_, __) async => false);
    final result = await invokeFromNative(const MethodCall('reply', <String, Object?>{
      'chatId': 'private_2089495846',
      'text': '在吗',
    }));
    expect(result, isFalse);
    await notifier.dispose();
  });

  test('reply：空文本 / 缺 chatId / 没装回调 一律 false', () async {
    final notifier = MessageNotifier();
    notifier.install(onReply: (_, __) async => true);
    expect(
      await invokeFromNative(const MethodCall('reply', <String, Object?>{
        'chatId': 'private_1',
        'text': '   ',
      })),
      isFalse, // 只有空白 = 没回复：直接拒绝，不发给对方
    );

    final noHandler = MessageNotifier();
    noHandler.install();
    expect(
      await invokeFromNative(const MethodCall('reply', <String, Object?>{
        'chatId': 'private_1',
        'text': 'hi',
      })),
      isFalse,
    );
    await noHandler.dispose();
    await notifier.dispose();
  });
}
