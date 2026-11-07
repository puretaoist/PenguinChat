# QQClient 滚动定位审计交接

## 当前任务与状态
- 用户 m65843：使用体验不佳，进入聊天卡住、记忆位置仍错误，要求认真分析实现方法。已完成只读源码审计，已给方案；未改代码、未操作真机、未发起登录。最新产品代码 HEAD=629f17c，之前790fa14/629f17c的滚动补丁未达到用户要求，不可标成已解决。
- 仓库 C:/Users/Administrator/penguis/qqclient；工作目录 C:/Users/Administrator/.dsh/workspace。保留脏文件 AGENTS.md、tmp/shot2.png、tmp/shot3.png、tmp/tk.txt.url；不提交凭据或抓包，不用git add .。语音按m54108冻结；不重开登录或协议实验。

## 已证实的结构问题（HEAD629f17c）
1. lib/ui/pages/home_page.dart:426-439 的 Future<void> _ensureOpened(String chatId) 在 await store.openChat(chatId) 后只检查mounted；:692-696 void _restoreScroll() 消费全局_pendingRestore，绑定当前_scrollOwnerChatId。A慢完成可恢复B/消费B目标。:703-705旧回调还会无条件清除新恢复的_restoringChatId。应携带chatId+generation+不可变target并逐层校验。
2. lib/ui/pages/home_page.dart:749-784 void _startBottomPin()/void _pinTick()/void _stopBottomPin() 每帧主动scheduleFrame最多90帧，没有内容稳定条件或任务代次。:759当次读取owner、:773同步与其比较不能挡旧链；stop只改bool，旧回调可在新start后复活。:396-409切会话、:971-975返回均不取消。90帧不是固定1.5秒，120Hz仅约0.75秒。实际卡顿占比未经profile，不能断言唯一原因。
3. lib/ui/pages/home_page.dart:748注释宣称NotificationListener取消，实际无任何NotificationListener/ScrollStartNotification。:297仅离底40px才stop，开始拖动与前40px仍可能被:772 jumpTo打断；发送:654-655同时animateTo和pin相冲突。应基于用户输入通知与滚动来源区分。
4. lib/ui/pages/home_page.dart:98全局共享ScrollController；:938-963 AnimatedSwitcher保留旧树220ms，快速返回重进可能新旧聊天列表同时绑定它。:291/:679/:716/:770仅hasClients就读.position（需要恰好一个position）。:1866-1867列表无会话key，owner先改、旧列表尚未换帧时存在归属错位。应独立keyed视口和controller。
5. lib/ui/pages/home_page.dart:329-339 _loadMore只await；:306-307程序滚动也会触发历史请求；全局_loadingMore会跨会话互挡。lib/client_api/chat_store.dart:360-370拉before，:1202-1206插入排序、:1217-1231时间正序、:1234-1251合并，前插历史时不补可视锚点，原pixels对应消息必然变位。
6. lib/ui/pages/home_page.dart:707-714重试最多20个postFrame却不主动推进帧，不代表有确定时间窗口；:719在:729-732等待max>0前提前清恢复守卫；:734只要max>0就clamp一次。应等待特定视口/内容版本ready，不盲靠帧数。
7. lib/ui/pages/home_page.dart:132/:304/:677-679纯像素记忆无法跨前插、字体/宽度/行高变化；:861-866宽屏自动ensureOpened不设置owner（只有:402设置），首次自动会话不记忆位置。
8. lib/client_api/chat_store.dart:1354-1410 _ensureDiskLoaded同步readAsLinesSync、逐行jsonDecode、list.any逐条去重（累计可能O(n²)）、排序后遍历全历史预取媒体。:1234-1251 _mergePage逐条_insertMessage后重写消息文件。明确存在UI isolate同步重活，实际耗时需profile。
9. 纠正旧归因：lib/ui/widgets/message_content.dart:548-561图片本来已有固定SizedBox(width240,height=(240/aspectRatio).clamp(90,320))；不能声称图片解码必然撑高，旧文档C122/六节的确定性说法需订正。lib/client_api/session_providers.dart:508-523消息StreamProvider.autoDispose含媒体落盘事件重新发全消息列表；lib/ui/widgets/message_list_builder.dart:75-113按正序生成日期、分组、未读分隔。

## 建议实现方案（尚未实施）
- 独立ChatMessageViewport，按账号+会话key隔离controller与状态。
- 明确FollowingLatest与ReadingHistory(anchorMessageId,anchorOffsetInViewport,neighborIds)，不用double.infinity混像素模型。
- 优先原型验证reverse列表，以最新端offset0为几何原点，避免从头猜max；同时调整日期/分组/可访问性顺序。reverse本身不能替代历史锚点。
- 历史恢复要支持离屏索引/锚点定位，先对比成熟索引列表组件与自有anchored sliver；普通GlobalKey.ensureVisible无法定位尚未构建的远端消息。
- 所有异步open/分页/布局校正绑定generation；明确用户拖动即让位，程序校正不写阅读缓存、不触发分页。加载、恢复、跟随、浏览状态分开。
- 本地消息先显示，远端请求不阻塞首屏定位；按页读、Set查重、批量排序，媒体只暖可见区及邻近。

## 必须验收
- 混合高度、最新离开后新增、历史离开后前插仍同消息同屏偏移、A慢B快拒迟到、<220ms重进无多position、恢复期间拖动不抢、空/慢消息、键盘/字体/宽度变化、大历史profile首帧与UI/raster帧耗时。现有278测试和相似截图不能证明修复。
- 最近审计子代理58838027-488d-4ffa-b5c3-8235de87e661已完成且无修改，结果在m65862/m65869/m65871/m65872/m65873。

## 上下文压缩故障
- 本轮compress已失败且工具明确非瞬态，不能立即重试。错误：no visible context，session约662.6MiB+其他sessions105.9MiB超过resident pool512MiB；建议关闭其他会话或由用户提高sessions.residentMaxBytes/env BILI_SESSION_RESIDENT_MAX_BYTES到超过约768.4MiB并重启bili。未修改任何DSH配置，也未关闭其它用户会话。

Open objectives: 可靠聊天定位与进入性能（m65843）；TG剩余UI(m54108)；语音冻结(m54108)；通知回复终验(m48940)；原生日常登录(m16818,m33765)；E多号/F自然过期(m43286)；四点恢复链离线复审(m42895/m42997)，真机需另授权。
