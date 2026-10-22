/// L4 平台能力：Android 前台服务保活（`MethodChannel` 实现）
///
/// 这一层是 [KeepAlive] 的真实现。放在 L4 而不是 L1，原因是它必须
/// `import 'package:flutter/services.dart'`——而 L1/L2 要能在纯 Dart 里跑自测。
/// 注入方式与 `path_provider` 一致：`main.dart` 里 override provider。
///
/// ## 通道协议（与 `MainActivity.kt` / `KeepAliveService.kt` 一一对应）
///
/// ```text
///   start          → null（幂等；已在跑时直接返回）
///   stop           → null（幂等）
///   isRunning      → bool
///   ensurePermission → bool（Android 13+ 会弹一次系统对话框）
/// ```
///
/// 所有方法都带 `title` / `text` 参数（`start` 需要），因为通知文案属于
/// 表现层——内核不该知道"保持连接"这几个字怎么写。
library;

import 'package:flutter/services.dart';

import '../../infra/lifecycle/keep_alive.dart';

class ForegroundKeepAlive implements KeepAlive {
  ForegroundKeepAlive({
    this.title = '保持连接',
    this.text = '正在后台保持消息连接',
  });

  /// 常驻通知标题。
  final String title;

  /// 常驻通知正文。
  final String text;

  static const MethodChannel _channel = MethodChannel('qqclient/keepalive');

  @override
  Future<void> start() => _channel.invokeMethod<void>('start', <String, Object?>{
        'title': title,
        'text': text,
      });

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stop');

  @override
  Future<bool> isRunning() async {
    final running = await _channel.invokeMethod<bool>('isRunning');
    return running ?? false;
  }

  @override
  Future<bool> ensurePermission() async {
    final granted = await _channel.invokeMethod<bool>('ensurePermission');
    return granted ?? true;
  }
}
