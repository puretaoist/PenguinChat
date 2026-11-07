/// 宽屏（平板）主壳的 tab 状态：让 HomeShell（画胶囊）与 HomePage（画左栏内容）
/// 共享一个"当前 tab"，而不用把整棵树拆成两个 State。
///
/// 依据 Telegram Android 13.1.1：
/// - 平板上 MainTabsActivity 只占左栏（LaunchActivity.java:949-953），tab 切换
///   只换左栏的 fragment，右栏（rightActionBarLayout）仍是当前会话 —— 所以
///   tab 的"选中态"属于外壳，而"左栏内容"由 HomePage 按这个索引来选。
/// - 手机上 MainTabsActivity 占满整屏，tab 换的是整页，本 provider 不参与。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 宽屏当前 tab：0=聊天 1=联系人 2=设置 3=我的。
final StateProvider<int> wideTabProvider = StateProvider<int>((Ref _) => 0);

/// 请求把某个 tab 的列表滚回顶部：自增一次 = 一次请求。
///
/// 依据 MainTabsActivity.java:334-349 —— 点击**当前** tab 时调
/// TabFragmentDelegate.onParentScrollToTop()（列表回顶），不重新选中。
/// 官方对**四个** tab 都这么做，所以这里按 tab 索引分片，而不是只服务聊天列表。
final StateProviderFamily<int, int> tabScrollToTopProvider =
    StateProvider.family<int, int>((Ref _, int tab) => 0);
