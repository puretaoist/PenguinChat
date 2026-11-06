/// L4 主题：动效常量（时长 + 曲线）。
///
/// 为什么集中：以前 150/200/250ms 和 easeOutCubic 散落在 home_page、
/// chat_input_bar、message_action_popup 各处，改一处手感其他几处不跟着变，
/// 于是"整体动效"永远对不齐。数值都来自 TG：
/// * 150ms = `ChatActivityEnterView` 的 send/mic 切换；
/// * 200ms = `ActionBarPopupWindow` 的 setAnimationStyle；
/// * 250ms = `ChatListItemAnimator` 的 duration；
/// * DecelerateInterpolator = `1-(1-t)^1.5`，是 TG 列表/气泡入场的主力曲线。
library;

import 'package:flutter/animation.dart';

/// 动效时长与曲线（只放常量，不放状态）。
class Motion {
  const Motion._();

  /// 快速反馈：按钮形态切换、回复条展开。
  static const Duration fast = Duration(milliseconds: 150);

  /// 弹层：popup / action sheet 进出。
  static const Duration normal = Duration(milliseconds: 200);

  /// 列表入场：TG ChatListItemAnimator。
  static const Duration slow = Duration(milliseconds: 250);

  /// 进场曲线（TG 的 DecelerateInterpolator 同族）。
  static const Curve enter = Curves.easeOutCubic;

  /// 退场曲线。
  static const Curve exit = Curves.easeInCubic;

  /// TG 的 AccelerateDecelerateInterpolator。
  static const Curve standard = Curves.easeInOutCubic;
}
