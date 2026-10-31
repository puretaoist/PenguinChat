/// L4 平台能力：把「有新消息」变成一条系统通知（`MethodChannel` 实现）。
///
/// 与 `foreground_keep_alive.dart` 同一套做法：L1/L2/L3 不能 import Flutter，
/// 所以真正的平台调用只能待在这一层，由 UI 侧（[MessageNotifyScope]）驱动。
///
/// ## 通道协议（与 `MainActivity.kt` / `MessageNotifier.kt` 一一对应）
///
/// ```text
///   ensurePermission → bool    Android 13+ 弹一次系统权限对话框；13 以下恒 true
///   notify           → null    {chatId, title, text, sender, isGroup, timeMs}
///   cancelAll        → null    撤掉本通道发过的全部通知（不碰保活那条常驻通知）
/// ```
///
/// 反向调用（原生 → Dart）：
///
/// ```text
///   opened → chatId  用户点了某条消息通知，要打开对应会话
/// ```
library;

import 'dart:async';

import 'package:flutter/services.dart';

class MessageNotifier {
  MessageNotifier({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// 通道名。写成常量是为了真机排障时能在 `dumpsys`/`logcat` 里搜到。
  static const String channelName = 'qqclient/notify';

  final MethodChannel _channel;

  final StreamController<String> _opened = StreamController<String>.broadcast();
  bool _handlerInstalled = false;

  /// 用户点了通知要打开的会话 ID。
  ///
  /// 广播流：作用域可能因为换会话/重建而重新订阅，单订阅流会抛
  /// "Stream has already been listened to"。
  Stream<String> get opened => _opened.stream;

  /// 安装原生回调。重复调用是幂等的。
  void install() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'opened') {
        final chatId = call.arguments;
        if (chatId is String && chatId.isNotEmpty && !_opened.isClosed) {
          _opened.add(chatId);
        }
      }
      return null;
    });
  }

  /// 申请通知权限（Android 13+ 的 QQBPOST_NOTIFICATIONS`）。
  ///
  /// 返回值只用于日志与引导文案：**不改变"照常尝试发通知"的行为**。
  /// 系统会自己丢弃没有权限的通知，Dart 侧没必要因此停掉整条链路。
  Future<bool> ensurePermission() async {
    try {
      final granted = await _channel.invokeMethod<bool>('ensurePermission');
      return granted ?? true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 发一条消息通知。同一个 [chatId] 会覆盖上一条（原生按 chatId 取通知 id）。
  Future<void> notify({
    required String chatId,
    required String title,
    required String text,
    String sender = '',
    bool isGroup = false,
    int timeMs = 0,
  }) async {
    try {
      await _channel.invokeMethod<void>('notify', <String, Object?>{
        'chatId': chatId,
        'title': title,
        'text': text,
        'sender': sender,
        'isGroup': isGroup,
        'timeMs': timeMs,
      });
    } on MissingPluginException {
      // 桌面端/测试环境没有实现：静默跳过。
    } on PlatformException {
      // 通知失败不该影响消息收发——吞掉。
    }
  }

  /// 取走「冷启动时点通知留下的会话 id」。
  ///
  /// 冷启动的顺序是：原生先收到 Intent（Activity.onCreate），Dart 才把通道建好。
  /// 原生若在那时主动 invoke，Dart 侧 handler 还没装上，消息会被丢弃；
  /// 所以改成原生只暂存，Dart 就绪后主动来取。
  Future<String?> takePendingChatId() async {
    try {
      final chatId = await _channel.invokeMethod<String>('takePendingChatId');
      return (chatId != null && chatId.isNotEmpty) ? chatId : null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 撤掉本通道发过的全部通知。
  Future<void> cancelAll() async {
    try {
      await _channel.invokeMethod<void>('cancelAll');
    } on MissingPluginException {
      // 同上。
    } on PlatformException {
      // 同上。
    }
  }

  Future<void> dispose() async {
    await _opened.close();
  }
}
