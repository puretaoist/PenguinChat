# WorkBuddy 实施任务书：账号隔离与日常免密登录

日期：2026-10-30
状态：策划完成；尚未派发、未改业务代码、未运行本任务测试。
执行模型：用户指定 WorkBuddy / DeepSeek v4.1 Flash。策划与审查由当前会话负责，不得擅自替换执行模型。

## 0. 目标与红线

交付四项能力：
1. 聊天、消息、媒体及索引按账号隔离，切号不串数据。
2. 正确区分会话失效、网络故障、验证要求、服务端拒绝，提供可用的重新登录入口。
3. 按各类票据的真实有效期及用途管理，支持静默续期和安全持久化。
4. 将有证据、有材料的免密恢复分支接入产品；材料不可用或要求验证时明确交还用户。

不承诺永久免登录，也不承诺所有账号通过服务端验证。

执行限制：
- 项目根：C:/Users/Administrator/penguis/qqclient；先完整阅读项目 AGENTS.md。
- 本轮仅离线开发、假传输与测试。不得连接 QQ 登录端点、运行 live/smoke 登录工具、请求短信、操作真实账号或使用旧票据试登录。
- 不走 OneBot、hook/Xposed、第三方签名服务；官方凭据导入不是产品前提。
- 不读取/输出真实口令、票据或私有模型凭据；日志与测试报告不得含完整密钥及敏感载荷。
- 不修改 .dsh、模型配置、依赖版本、Gradle；不删除或重命名已有目录。
- 保留已有未提交变更及 tmp/ 研究产物；禁止 git add .、git reset --hard、全局 checkout、自动提交推送。
- L1/L2/L3 保持纯 Dart；UI 才可依赖 Flutter；遵守项目分层。
- 每阶段提交 diff、测试结果、局限和下一阶段范围，策划方审查后再进入下一阶段。

## 1. 已核实的问题与源码入口

下列行号为策划时定位，修改后以符号名为准：
- lib/client_api/qq8_providers.dart:853-869：_attachInner() 将全局 dataDir 交给 ChatStore；bootstrap 异步返回后无账号世代检查。
- 同文件:810-849：仅 online 且 _adapter==null 时 attach；_attaching 只挡并发，不解决切号与过期任务发布。
- 同文件:872-878：_teardown() 先等待 dispose 再清引用，需审查旧后端继续暴露的窗口。
- lib/client_api/chat_store.dart：chats/、media/、chats.json、media_index.json 是需隔离的集合；继续检索 UI/provider 的内存与下载缓存。
- lib/client_api/qq8_login_service.dart:583-592：loginWithToken() 只按 token.usable 放行 D2 路径。
- 同文件:3472-3489：把16/155泛称账号准入拒绝，并输出未经证实的风控因果解释。
- 同文件:3794-3856：reconnect() 多次尝试，需在验证、重验、拒绝、取消、切号时确定停止。
- lib/client_api/qq8_token_store.dart:55-135：保存票据及 savedAt，无完整逐票据到期信息；usable 只检查 D2/D2Key 非空。
- lib/kernel/wlogin8/qq8_login.dart:1288-1348：Qq8SigBundle 暴露全部 TLV，但未结构化解析有效期；现有 A1 仅直接保存 t106。
- 同文件:558 buildToken() 已有 sub11；:579 buildA1Exchange() 已有 sub15，不能把新调通组包误报为新实现。
- lib/ui/pages/qq8_connect_page.dart：登录页与控制器接线；同时检查主页的离线提示、返回路径及账号预填。

## 2. 总体结构

拆分三类职责，不把更多逻辑堆进单个大服务：
- AccountDataScope：账号目录、身份键、后端生命周期和取消世代。
- TicketMetadata / CredentialSet：凭据、配套密钥、生命周期、来源、关联档案与身份。
- RecoveryPlanner + RecoveryCoordinator：纯决策与有界异步执行分离。

名称可遵循现有风格调整。尽可能复用已有存储、加密、登录包和测试夹具。

## 3. P1：账号隔离（优先实施）

目录规范：现有应用私有 dataDir 下新增 accounts/<十进制uin>/，向 ChatStore 传入该账号根。账号参数严格校验，禁止路径注入。

隔离范围：消息文件、会话列表、媒体文件、媒体引用索引、草稿、未读、分页/搜索结果及内存 provider。不能只隔离 chats.json。设备身份与票据沿用已有稳定持久化，先做账号绑定审计，不盲目搬迁。

生命周期要求：
- 登录目标变化、主动退出、shutdown 时增加 generation；捕获确定的 uin 和 generation，不能在 await 后重新读可变 _snap.uin。
- 切号立刻撤销旧后端对 UI 的发布，再有序关闭旧订阅、store、adapter。
- bootstrap 完成必须检查 mounted、generation、目标账号及服务会话；过时结果只能释放，不得发布。
- 失败、取消与关闭也必须清理新建资源；旧 finally 不得改写新一代 attaching 状态。
- 同账号断线可保留账号限定的离线数据视图，但不得继续用失效会话发送；换号不得看见旧号内容。
- 通知、后台下载、缓存回调、异步落盘都携带账号上下文；跨账号缓存不能只以 chatId 为键。

旧全局数据：默认保留原样、标为待归属，不按最近登录账号/票据时间自动认领。新账号根不默读旧目录。若本轮实现迁移，必须由用户明确选择归属账号后进行非破坏复制，带校验、完成标记及中断恢复；原件不删、不移动。归属不明时宁可暂停迁移，不串号。

验收：A/B 同 chatId 不混；A bootstrap 未完成时切 B，最终仅 B 发布；退出/销毁期间 bootstrap 返回不会复活；旧消息流/下载晚到不污染 B；媒体与草稿同样隔离；旧全局原件保留。用可控 Completer/假调度器，不用固定 sleep 掩盖竞态。

补充静态审查发现（2026-10-30）：
- lib/ui/pages/home_page.dart:169-175：_syncDraft() 仅以 chatId 判断是否切换；:498-499 先把 _draftStore 更新成当前 store。若A/B有相同 chatId，可能保留A输入；若ID不同，切换时的 _flushDraft() 又可能拿B store写A草稿。P1必须将草稿上下文绑定 (账号/世代, store, chatId)，在更换引用前向原store收尾或取消，防抖及post-frame回调也验证世代。
- lib/client_api/session_providers.dart:464-474：sessionProvider/chatStoreProvider 优先取旧 ConnectionController，再取 activeQq8BackendProvider。审查原生账号撤销后是否意外露出其他后端的数据；不增加OneBot路线、不破坏旧离线DI测试。
- 同文件:482-512：chatsProvider/messagesProvider 会先yield新store数据再订阅，但Flutter异步provider重建期间可能保留旧value。不能仅凭已watch store就认定不串；P1需要widget测试证明切号首帧/加载中没有A内容，必要时以账号世代作为缓存键或显式重置显示状态。

## 4. P2：会话过期与重新登录入口

采用有上下文的状态/原因（可新增 reauthRequired，不要求机械照搬名称）：
- networkUnavailable：网络问题，保留凭据，允许有界重连。
- recovering：正在免密恢复，不显示封禁或风控。
- needsVerification：人工验证，保留同一挑战上下文，停止后台重试。
- reauthRequired：免密材料不可用或有证据判定失效，需要用户重新认证。
- rejected：如实展示服务端拒绝及原始 type；不推断账号一定封禁或风险必然升级。

分类必须考虑请求路径与结果：token/exchange 返回16应进入恢复决策，不能直接当账号风控；155不能在所有密码/验证场景一律等同票据过期。保留 resultType、flow 和原始服务端说明。无法证明的结果按未知失败处理。会话失效的 SSO retcode 也进入同一有界决策，不递归重连。

UI：主页与登录页均能到达“重新登录”；预填当前账号，清理旧 challenge、验证码与口令输入，要求用户手动认证，不自动发密码请求。按钮本身只导航/准备流程；若要发送请求必须有明确动作。票据无效不删除聊天记录、不自动换号。文案示例：“登录状态已失效，请重新登录；聊天记录仍保留。”

验收：16不显示账号风控；155按路径区分；网络错误不清票；挑战态不重试；入口保留账号且不自动发包；所有 enum switch、状态映射、日志与主页提示同步修正。

## 5. P3：逐票据生命周期

先交“证据表”再改解析器：列 ticket名、TLV来源、密钥配对、时间单位、时长/绝对值、缺省语义、官方消费点、四版本差异。

已核实的官方 8.2.11 入口（项目根的相邻 analysis/）：
- ../analysis/_decompiled/jadx-main/sources/oicq/wlogin_sdk/tlv_type/tlv_t138.java:13-20：u32 count，之后每项10字节；读取逻辑不能把整个条目直接当 epoch。
- 同文件:24-84：0x10a、0x120、0x143 等对应 chg_time。
- ../analysis/_decompiled/jadx-main/sources/oicq/wlogin_sdk/request/oicq_request.java:1689-1723：使用上述时长并有该版本缺省值；须继续追踪存储消费者确定到期语义，不能把缺省值推广到四版本。
- ../analysis/_decompiled/jadx-main/sources/oicq/wlogin_sdk/tlv_type/tlv_t130.java:10-21：服务端时间字段位置及最低长度；解析还须核对实际调用链。
- ../analysis/_decompiled/jadx-main/sources/oicq/wlogin_sdk/request/WtloginHelper.java:854-926：按 ticket._expire_time 取票及 GetStWithoutPasswd 续取，不支持“一条永生票据”的假设。
- 对照现存8.9.50、9.3.60、TIM反编译树以及 oicq；找不到的语义明确标为未知，不编造。

持久化模型：schemaVersion、uin、profile/身份关联、每类票据 issuedAt/expiresAt/refreshAfter（允许未知）、时间基准/来源；不要以 savedAt 或文件 mtime 推导所有 TTL。敏感字段沿用受保护存储。

要求：
- 区分 missing/unknown/valid/due/expired/invalid；未知不是无限期，也不是立刻判死。旧 JSON 可读，元信息未知时仅作有界的恢复候选。
- 凭据与配套密钥成组更新，例如 D2/D2Key；不能把新票和旧密钥拼接。响应未携带的独立有效材料不应无条件清空；明确失效的组不能被 merge 复活。
- 临时文件写入、校验、原子替换或等效事务；更新失败保留旧记录并准确报告失败，不泄露票据。
- 无效/截断/恶意 count、整数溢出、时钟回拨/前跳、服务端偏移异常可处理；注入 clock。
- 短期业务票到期只影响对应业务，不一概踢掉完整登录。
- 启动/恢复前与实际使用时检查；在有可靠生命周期时可提前刷新。Android 暂停期间不依赖 Timer 保证准点，回到前台重新评估。

验收：逐票独立过期、临界时间、未知兼容、异常 TLV、时钟变化、部分更新、成组一致性、落盘失败/中断。不得用任意固定小时数代替协议证据。

## 6. P4：完整且有界的免密恢复

“完整”指分支、停止条件与产品接线完整，不意味着缺少原料也能绕过认证。由 RecoveryPlanner 根据当前材料与已尝试路径产生下一步，每条路径一轮最多一次，网络重试另设有界预算。所有入口共享 single-flight，并允许用户取消/切号使结果失效。

官方参考：../analysis/_decompiled/jadx-main/sources/oicq/wlogin_sdk/request/WtloginHelper.java:607-755。须还原调用者、字段来源、信封密钥与命令选择，不能把该函数 if/else 结构直接当服务器推荐的重试顺序。

候选能力：
1. A2(TGT)+D2+D2Key：现有 sub11；确认所有必要材料、有效性与配套关系，不只判断两字段非空。
2. A2+A2Key：官方有明确分支，但当前未保存完整 A2Key；核实其 TLV来源并补持久化、组包与解密，不能把 d2key/sigKey 当 A2Key。
3. A1+noPicSig：接现有 sub15。必须追清 0x106、0x10c、官方 _en_A1 的包装/解包与 tgtgt 材料；现有 a1=t106 不等于已经证明适配所有官方路径。
4. A2-only：审计官方后备的额外上下文和密钥。证据与必要材料齐全才启用，否则报告 unavailable 及原因，不发送伪造/空料请求。

明确分支材料不足时，要么补齐可从自己成功登录取得的字段，要么停在重验入口；不得把“跳过所有分支”报成完整免密恢复已验证。为每条分支列 implemented / offlineVerified / liveVerified / unavailable 状态。

决策约束：
- 仅在凭据类失败且存在其他合法材料时推进下一候选；网络超时不直接作票据过期。
- 验证/短信/设备确认：立刻暂停，人工处理，不自动请求短信或轮询刷挑战。
- 明确服务端拒绝：停止，不换路径轮番撞库。
- 全部不可用：reauthRequired，保留账号及历史数据，绝不偷偷退化密码登录。
- 续期请求与业务在途请求协调，避免新旧会话/密钥交叉；不自动重放非幂等发消息。
- 成功后按组持久化，再安全替换会话/注册/心跳；写盘失败、register 失败应区分，不报完全成功。
- 退出账号停止调度与恢复；踢下线/显式撤销不得被后台循环顶号。具体 retcode 依据仓库及官方来源，不新增猜测码表。

## 7. 离线测试与质量门

优先新增独立纯 Dart 测试：账号目录/世代；票据元数据与解析；RecoveryPlanner 决策表。扩展现有服务 fake transport；Flutter widget test 检查提示与导航。

必须覆盖：
- 每条支持恢复分支的请求帧命令、subCmd、TLV集合、盐/密钥来源和成功响应解码；预期值不能全部由被测函数自身生成。
- D2失效但A1可用、A2Key可用、全失效、全缺失、未知TTL、挑战、拒绝、网络断开、并发三入口single-flight、恢复中切号/销毁、调度恢复及过期票不无限尝试。
- 同号重连不丢记录；跨号媒体/草稿/未读/缓存不串；无凭据时不发包；日志无敏感值。

最终命令使用当前机器真实 Dart/Flutter SDK，不改 PATH 或依赖。
- dart analyze lib tool 必须 No issues found。
- 跑全量 tool/*_selftest.dart（策划时45个，以执行时实际列表为准，新测试也纳入）。
- 跑 flutter test，并审查相关登录页/主页 widget tests；记录实际命令、退出码、数量与失败项。
- 只对新增/修改代码格式化，避免全仓无关 diff。测试不访问真实服务器。

真实长期在线/前后台/服务端票据更新/群消息与表情回归仍需未来获准真机验收，不得把离线绿灯写成长期登录已验证。

## 8. WorkBuddy 首轮可直接使用的指令

请确认你在 WorkBuddy 中选择的是 DeepSeek v4.1 Flash，工作目录为 C:/Users/Administrator/penguis/qqclient。先阅读 AGENTS.md 与本任务书。只实施 P1（账号隔离），其余阶段不改。先给出准备修改的文件和生命周期方案，再做源码及离线测试。禁止真实登录、禁止碰凭据/模型配置、禁止修改已有 tmp 产物、禁止自动提交推送。完成后交付：逐文件 diff 说明、测试命令/结果、竞态覆盖、旧数据策略、尚未解决事项，等待策划方审查后才进入 P2。

P1审查通过后依次派发P2、P3、P4；协议证据不足先提交缺口表，不用臆测凑实现。各阶段分别评审，可先补证据/测试，但不要让两个任务同时改同一核心文件。

### 8.1 指定模型与入口核验

用户已澄清：WorkBuddy 通过本机 Magpie 反代接入，不是桌面端。已只读核验 Magpie 进程监听 http://127.0.0.1:3425，GET /v1/models 明确列出 workbuddy/deepseek-v4.1-flash。后续请求必须使用该完整 ID，不使用 auto 或其他渠道的同名模型。已用此精确 ID 发出 P1 规划请求并收到响应；响应 model 为 deepseek-v4.1-flash，这证明请求路由与返回名称，不单独证明上游内部实现。未读取私有配置或凭据。

已查阅官方创建任务和模型配置文档：
- https://www.workbuddy.cn/docs/workbuddy/Create-Task
- https://www.workbuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Model

此前官网模型名称差异及桌面CLI查找已被本机 Magpie 精确模型发现取代；不再以官网旧名称阻断执行。可见 subagent 接口不支持显式模型选择，因此采用直接请求 Magpie 指定模型、由当前会话受控传递源码及执行其编辑指令的方式，保留调用记录；不把普通子智能体当作指定模型。

## 9. 最终交付清单

- 四阶段源码与离线回归结果。
- 账号目录规范及旧数据归属/非破坏迁移说明。
- 结果分类与重新登录交互说明。
- 逐票据证据、字段映射、生命周期表。
- 免密恢复能力矩阵及各分支离线/真机验证状态。
- 修正 docs/日常登录-真机验收清单.md 中未经证实的必然性说法：损坏TGT不保证返回16、合成身份不保证237、QIMEI/KSID和清数据后的变化不应写死；不把私有票据复制到共享存储。
- 明确保留的真机验收项及未解决限制。
