/// L3 客户端 API 层：服务端「已删除」幽灵占位的判定（纯函数）
///
/// ## 为什么单独一个文件
///
/// 同一条判据要被两个地方使用：
///
/// * 适配器入口（[Qq8SessionAdapter.isDeletedPlaceholder]）——拦住**新到**的推送/历史；
/// * 本地消息库读取（`ChatStore._ensureDiskLoaded`）——拦住**已经落盘**的历史脏数据。
///
/// 真机 2026-10-31 现场：过滤器只装在适配器入口，磁盘里 13 条幽灵记录照样
/// 渲染成 1970-01-01 的气泡。两处各写一份判断迟早会漂移（改一处忘一处），
/// 因此把条件和文案常量都收在这里。
///
/// ## 判定为什么是三个条件
///
/// `time=0 / sender=0 / 正文「[已删除]」` 必须**同时成立**。只按中文文案删会
/// 误伤真人发的同一句话；文案是服务端给的，将来也可能换措辞（换了就不会被
/// 过滤，但至少不会误删用户内容——这个方向的错误是可接受的）。
library;

/// 服务端删除占位用的正文文案。
const String kDeletedPlaceholderText = '[已删除]';

/// 是否服务端「已删除」占位。
///
/// [timeMs] 允许是秒或毫秒：两种单位下这个占位都是 0，判据是 `<= 0`。
bool isServerDeletedPlaceholder({
  required int timeMs,
  required int senderUin,
  required String text,
}) =>
    timeMs <= 0 && senderUin == 0 && text == kDeletedPlaceholderText;
