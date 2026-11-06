/// L4 宽屏正文限宽工具：让设置等"表单型"页面在平板上不再把每一行
/// 拉到整屏宽（1280dp 上一行文字从左甩到右，眼睛读不完第一句就丢了）。
///
/// 两种用法：
/// - [CappedContent]：包一个自绘的中部内容块（少量页面用）；
/// - [contentHorizontalInset]：给 **ListView 的 padding** 用——列表滚动条
///   仍贴着真实屏边，内容居中，比包 ConstrainedBox 更省一层布局。
///
/// 阈值只从 [AppBreakpoints] 取，别在页面里写魔法数字。
library;

import 'package:flutter/widgets.dart';

import '../platform/app_breakpoints.dart';

/// 宽屏下正文两侧该留多少水平内边距（窄屏恒为 0）。
///
/// 注意只算"超出 [AppBreakpoints.contentMaxWidth] 的那部分的一半"，
/// 所以 700dp 宽的窗口仍是满宽（0），不会出现小屏反而被塞窄的情况。
double contentHorizontalInset(BuildContext context) {
  final double width = MediaQuery.sizeOf(context).width;
  final double extra = (width - AppBreakpoints.contentMaxWidth) / 2;
  return extra > 0 ? extra : 0;
}

/// 宽度上限为 [AppBreakpoints.contentMaxWidth]、水平居中的容器。
class CappedContent extends StatelessWidget {
  const CappedContent({super.key, required this.child, this.maxWidth});

  final Widget child;

  /// 默认 [AppBreakpoints.contentMaxWidth]（720dp）。
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth ?? AppBreakpoints.contentMaxWidth,
        ),
        child: child,
      ),
    );
  }
}
