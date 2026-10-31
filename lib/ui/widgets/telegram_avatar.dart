/// Telegram 风格组件：圆形头像（真头像直链，退回首字母色块）
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/telegram_theme.dart';

Color _colorFromName(String name) {
  if (name.isEmpty) return TelegramColors.accent;
  final hash = name.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0x7FFFFFFF);
  const palette = [
    Color(0xFFE17076),
    Color(0xFF7BC862),
    Color(0xFFE5CA77),
    Color(0xFF65AADD),
    Color(0xFFEE7AAE),
    Color(0xFFA695E7),
    Color(0xFF6EC9CB),
    Color(0xFFFAA774),
  ];
  return palette[hash % palette.length];
}

/// 注意：本组件按 [size] 正方形绘制。**调用方给它的可用宽度必须 >= size**，
/// 否则父级约束会把它压成非正方盒，`ClipOval` / `BoxShape.circle` 画出来就是椭圆
/// （2026-10-31 真机：气泡头像槽宽 44 减左右内边距 14 只剩 30 → 30x34 椭圆，C103）。
class TelegramAvatar extends StatelessWidget {
  final String name;
  final double size;

  /// 头像直链（可空）。拉得到就显示真头像；失败/为空退回首字母色块——
  /// 头像 CDN 在弱网下经常超时，绝不能让整行列表陪着白屏。
  final String? url;

  const TelegramAvatar({
    super.key,
    required this.name,
    this.size = TelegramMetrics.avatarSize,
    this.url,
  });

  @override
  Widget build(BuildContext context) {
    final letter = Container(
      width: size,
      height: size,
      decoration:
          BoxDecoration(color: _colorFromName(name), shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        name.isEmpty ? '?' : name.characters.first,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    if (url == null || url!.isEmpty) return letter;
    // key 绑 url：换头像（或同一会话换了账号）时状态重置，不会沿用旧的失败
    // 计数把新地址也判死。
    return _AvatarImage(
      key: ValueKey<String>(url!),
      url: url!,
      size: size,
      fallback: letter,
    );
  }
}

/// 头像真图：失败不再**永久**退回首字母。
///
/// 改前的问题：Image.network 的 errorBuilder 只在本次 widget 生命周期里生效，
/// 一次 CDN 超时就把这一行的真头像钉死成色块，直到整行被重建（滚动复用也未必
/// 换实例）。头像 CDN 弱网下失败率不低，表现就是某些人的头像永远是字母。
///
/// 这里做的是 TG ImageLoader 的最小等价物：有限次退避重试（2 次 / 2s），
/// 每次重试换掉 Image 的 key 以真正重新发起请求；两次都失败才落到色块。
/// 磁盘缓存留给 P4（docs/图片加载-官方对照与改造方案-20261031.md 第 6 节）。
class _AvatarImage extends StatefulWidget {
  final String url;
  final double size;
  final Widget fallback;

  const _AvatarImage({
    super.key,
    required this.url,
    required this.size,
    required this.fallback,
  });

  @override
  State<_AvatarImage> createState() => _AvatarImageState();
}

class _AvatarImageState extends State<_AvatarImage> {
  /// 重试次数上限。头像不是正文，不值得像消息图那样多试。
  static const int _maxRetries = 2;

  /// 退避间隔（固定 2s；指数退避对头像没意义，要么瞬时抖动要么长期不可达）。
  static const Duration _retryDelay = Duration(seconds: 2);

  int _failures = 0;
  int _attemptSeq = 0;
  bool _gaveUp = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onError() {
    if (!mounted) return;
    if (_failures >= _maxRetries) {
      setState(() => _gaveUp = true);
      return;
    }
    _failures++;
    _timer?.cancel();
    _timer = Timer(_retryDelay, () {
      if (!mounted) return;
      // 换 key ⇒ Image 重建 ⇒ 重新发请求（同一个 ImageProvider 会命中
      // Flutter 的失败图缓存，光 setState 不会重试）。
      setState(() => _attemptSeq++);
    });
    // 重试等待期显示色块，别留空白。
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // 始终保留 ClipOval：形状断言（正圆回归测试）与视觉一致都靠它；
    // 放弃重试时里面换成首字母块，而不是把 ClipOval 整个摘掉。
    return ClipOval(
      child: _gaveUp
          ? widget.fallback
          : Image.network(
              widget.url,
              key: ValueKey<int>(_attemptSeq),
              width: widget.size,
              height: widget.size,
              fit: BoxFit.cover,
              // CDN 慢是常态：加载中显示首字母色块而不是空白
              frameBuilder: (ctx, child, frame, _) =>
                  frame == null ? widget.fallback : child,
              errorBuilder: (_, _, _) {
                // errorBuilder 在构建期调用，不能直接 setState。
                WidgetsBinding.instance.addPostFrameCallback((_) => _onError());
                return widget.fallback;
              },
            ),
    );
  }
}
