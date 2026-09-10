/// L2 协议内核：WLogin 登录命令字与流程模型
///
/// ## 数据来源
///
/// 本文件的命令字常量来自对目标 APK（com.tencent.mobileqq 9.3.60，41 个 dex）
/// 的**全量字符串扫描**，导出见 `api_sso_commands.csv`（401 条 SSO 命令字）。
/// 其中 `EcdhService.SsoNTLogin*` 一族构成现代 QQNT 登录链路。
///
/// ## 与老版 WLogin 的区别
///
/// 旧版 QQ 走 `0x0825 / 0x0810 / 0x0819` 这几个 cmd 字（TLV 为主）。
/// QQNT 改为 **trpc/SSO 命名式接口 + protobuf 载荷**，命令字形如
/// `EcdhService.SsoNTLoginPasswordLogin`，这正是本文件建模的对象。
/// 目标 APK 中两者并存（`oicq.wlogin_sdk` 仍在，但 QQNT 内核走新的 EcdhService）。
///
/// ## 流程建模的置信度
///
/// 命令字的**存在与名称**是扫描得到的确定事实（[LoginSsoCommand] 全部常量）。
/// 它们之间的**调用顺序**是基于名称语义与公开资料的推断（[LoginStage]），
/// 待 `WtloginHelper` 反编译完成后校正。
library;

/// 登录链路中出现的 SSO 命令字（事实数据，取自 APK 扫描）。
///
/// 命名规律：`<服务名>.<方法名>`，方法是 `Sso` + PascalCase 动作。
class LoginSsoCommand {
  LoginSsoCommand._();

  /// ECDH 密钥交换——建立会话共享密钥（登录前必走）。
  ///
  /// 对应 native 侧的 `EcdhAccess.SsoEstablishShareKey`。
  static const keyExchange = 'EcdhService.SsoKeyExchange';

  /// 拉取口令加盐列表。说明口令并非直接 MD5，而是加盐派生。
  static const getSaltList = 'EcdhService.SsoNTLoginGetSaltList';

  /// 账号口令登录（提交加盐后的口令材料）。
  static const passwordLogin = 'EcdhService.SsoNTLoginPasswordLogin';

  /// 请求下发短信验证码。
  static const getSms = 'EcdhService.SsoNTLoginGetSms';

  /// 校验短信验证码。
  static const checkSms = 'EcdhService.SsoNTLoginCheckSms';

  /// 校验网关验证码（图形验证码 / 风控挑战）。
  static const checkGateWayCode = 'EcdhService.SsoNTLoginCheckGateWayCode';

  /// 校验第三方验证码（如微信/QQ 安全中心下发的 code）。
  static const checkThirdCode = 'EcdhService.SsoNTLoginCheckThirdCode';

  /// 检查本地 A1 票据列表（决定能否免密登录）。
  static const checkA1List = 'EcdhService.SsoNTLoginCheckA1List';

  /// 新设备登录鉴权（首次在此设备登录时的额外校验）。
  static const authNewDevice = 'EcdhService.SsoNTLoginAuthNewDevice';

  /// 免密登录（基于已缓存的票据）。
  static const easyLogin = 'EcdhService.SsoNTLoginEasyLogin';

  /// 快速登录（缓存的 A1 + 轻量校验）。
  static const rapidLogin = 'EcdhService.SsoNTLoginRapidLogin';

  /// Optimus 登录（腾讯内部代号，基于长期票据的一键登录）。
  static const optimusLogin = 'EcdhService.SsoNTLoginOptimusLogin';

  /// 刷新 A2 票据（登录后维持会话）。
  static const refreshA2 = 'EcdhService.SsoNTLoginRefreshA2';

  /// 刷新票据（通用刷新入口）。
  static const refreshTicket = 'EcdhService.SsoNTLoginRefreshTicket';

  /// 全部登录相关命令字，便于遍历与测试覆盖。
  static const all = <String>[
    keyExchange,
    getSaltList,
    passwordLogin,
    getSms,
    checkSms,
    checkGateWayCode,
    checkThirdCode,
    checkA1List,
    authNewDevice,
    easyLogin,
    rapidLogin,
    optimusLogin,
    refreshA2,
    refreshTicket,
  ];

  /// 登录入口类命令（用于「选择哪种登录方式」）。
  static const entryPoints = <String>[
    passwordLogin,
    easyLogin,
    rapidLogin,
    optimusLogin,
  ];
}

/// 登录流程的阶段划分。
///
/// 这是**推断的**状态机骨架（依据命令字命名语义），
/// 不是从字节码还原出来的确定控制流。反编译校正前不应作为实现依据。
enum LoginStage {
  /// 空闲，未开始
  idle,

  /// 建立 ECDH 共享密钥
  keyExchange,

  /// 拉取加盐列表
  fetchSalt,

  /// 提交口令，等待服务端裁决
  submitPassword,

  /// 服务端要求短信验证
  awaitingSms,

  /// 服务端要求图形/网关验证码
  awaitingGatewayCode,

  /// 服务端要求第三方验证码
  awaitingThirdCode,

  /// 新设备额外鉴权
  awaitingNewDeviceAuth,

  /// 登录成功，持有 A1/A2 票据
  success,

  /// 失败终态
  failed,
}

/// 服务端在口令登录响应中可能要求的下一步动作。
///
/// 各分支对应上面 [LoginStage] 的等待态。QWLogin 用响应 TLV（0x0108 等）
/// 或新版 protobuf 字段表达「需要什么验证」。
enum LoginChallenge {
  none,

  /// 需要短信验证码
  sms,

  /// 需要图形/网关验证码
  gatewayCode,

  /// 需要第三方验证码
  thirdCode,

  /// 新设备需额外鉴权
  newDevice,

  /// 账号被风控拦截
  riskControl,
}

/// 登录请求/响应的结果码。
///
/// 取值来自公开的 QQ 协议研究；[unknown] 保留给未识别返回值。
/// 反编译校正前，这里只用于日志与调试分类，不驱动关键分支。
class LoginResultCode {
  LoginResultCode._();

  static const success = 0;

  /// 需要图形验证码
  static const needCaptcha = 1;

  /// 需要短信验证码
  static const needSms = 2;

  /// 口令错误
  static const wrongPassword = 3;

  /// 账号被冻结 / 限制登录
  static const accountBlocked = 40;

  /// 设备被锁定（需安全中心解锁）
  static const deviceLocked = 43;

  /// 票据过期
  static const ticketExpired = 52;

  static const unknown = -1;

  /// 把服务端返回值归类为人类可读描述（用于日志）。
  static String describe(int code) {
    switch (code) {
      case success:
        return '成功';
      case needCaptcha:
        return '需要图形验证码';
      case needSms:
        return '需要短信验证码';
      case wrongPassword:
        return '口令错误';
      case accountBlocked:
        return '账号被限制登录';
      case deviceLocked:
        return '设备已锁定';
      case ticketExpired:
        return '票据已过期';
      default:
        return '未知返回码 0x${code.toRadixString(16)}';
    }
  }
}
