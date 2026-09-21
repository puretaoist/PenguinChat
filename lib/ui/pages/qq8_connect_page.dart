/// L4 协议线登录页：口令 / 手机号短信 / 二维码 / 票据四种方式，一步一页。
///
/// ## 与 OneBot 连接页的分工
///
/// `connect_page.dart` 连的是**本机/远端进程**（OneBot 后端），
/// 本页连的是**腾讯服务器**（协议线）——后者每一步都要过 `SafetyGate`（在
/// `Qq8LoginService` 里把关），所以本页不做任何风险判断，只做两件事：
///
/// 1. 按 [Qq8ConnectStatus.stage] 渲染"这一步要人做什么"；
/// 2. 把输入交给 [Qq8ConnectController] 的动作。
///
/// ## 交互设计（对齐 Telegram/Nagram 的 LoginActivity）
///
/// * 顶部一个**方式切换**（口令 / 二维码 / 短信 / 票据），默认口令；
/// * 一次只显示**当前要做的这一件事**，配一个明确的「继续 / 登录」主按钮
///   ——不再四个按钮平铺（旧版被吐槽"看不出怎么登录"）；
/// * 滑块验证在**应用内**的 WebView 里完成
///   （[Qq8VerifyPage]）：验证页所在环境要与登录包里的设备身份对得上，
///   而且只有应用内才拿得到页面回传的验证码——它会被自动识别并直接提交；
/// * 文案全部人话化，不出现"票据 / ticket / 协议线"等术语。
///
/// ## 拆成两层是为了能测
///
/// [Qq8ConnectView] 是**哑视图**（状态 + 回调，纯 UI），
/// [Qq8ConnectPage] 只是把它接到 provider 上。这样 widget 测试能直接喂各种
/// 状态，把"每个阶段该出现什么、回调有没有被调"全测到，而不需要真登录。
///
/// 本文件是 Flutter 层（L4）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../client_api/qq8_login_service.dart';
import '../../client_api/qq8_providers.dart';
import '../../client_api/session_providers.dart' show dataDirProvider;
import '../../infra/log/log_file.dart';
import '../../kernel/wlogin8/qq8_profiles.dart';
import '../theme/telegram_theme.dart';
import '../widgets/real_server_panel.dart';
import 'home_page.dart';
import 'qq8_verify_page.dart';

/// 协议线登录页（把 [Qq8ConnectView] 接到 provider 上）。
class Qq8ConnectPage extends ConsumerWidget {
  const Qq8ConnectPage({super.key});

  /// 打开**应用内**验证页（[Qq8VerifyPage]），拿回验证码就直接提交。
  ///
  /// 与旧做法的区别：不再把地址丢给系统浏览器再让用户抄验证码回来。
  /// 抄回来的那条路在服务端看是"另一个环境"，而且人肉搬运必然超时；
  /// 应用内验证页会把识别到的验证码直接交回来（见该页头部说明）。
  ///
  /// 用户取消（返回 null）时什么都不做——**不猜、不重试**。
  Future<void> _openVerifyPage(
      BuildContext context, WidgetRef ref, String url) async {
    final controller = ref.read(qq8ConnectControllerProvider.notifier);
    final ticket = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => Qq8VerifyPage(url: url)),
    );
    if (ticket == null || ticket.isEmpty) return;
    await controller.submitSliderTicket(ticket);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(qq8ConnectControllerProvider);
    final c = ref.read(qq8ConnectControllerProvider.notifier);
    // 日志目录：应用私有目录下。main.dart 注入的 dataDir 即 "…/logs" 的父目录。
    final dataDir = ref.read(dataDirProvider);
    final logDir = Directory(
        '${dataDir.path}${Platform.pathSeparator}logs');
    return Scaffold(
      appBar: AppBar(title: const Text('QQ 账号登录')),
      body: Qq8ConnectView(
        key: const ValueKey('qq8-connect-view'),
        status: status,
        // 风险确认入口：没开真实服务器模式时登录必被拦，用户必须在**本页**
        // 就能开（旧版提示"去风险确认里开"却没有入口，真机上卡死）。
        // 默认折叠成一行提示，点击展开检测 + 逐条确认，不撑满首屏。
        header: const RealServerPanel(),
        onPasswordLogin: c.loginWithPassword,
        onTokenLogin: c.loginWithToken,
        onPhoneLogin: c.loginWithPhone,
        onSubmitTicket: c.submitSliderTicket,
        onRequestSms: c.requestSmsCode,
        onSubmitSms: c.submitSmsCode,
        onRefreshSmsLoginCode: c.refreshSmsLoginCode,
        onSubmitSmsLoginCode: c.submitSmsLoginCode,
        onUnlock: c.unlockDevice,
        onFetchQrcode: c.fetchQrcode,
        onPollQrcode: c.pollQrcode,
        onOpenBrowser: (url) => _openVerifyPage(context, ref, url),
        // 客户端档案可切换（研究线需要按档对照服务端裁决，见 qq8ProfileProvider）。
        profileKey: qq8ProfileKeyOf(ref.watch(qq8ProfileProvider)),
        profileKeys: qq8ClientProfiles.keys.toList(),
        onProfileChanged: (key) {
          final p = qq8ClientProfiles[key];
          if (p != null) ref.read(qq8ProfileProvider.notifier).state = p;
        },
        // 导出日志：生成报告 → 写临时文件 → 系统分享面板。
        onExportLog: () async {
          final report = LogExporter.buildReport(
            logDirectory: logDir,
            metadata: <String, Object?>{
              'app': 'PenguinChat QQ 客户端',
              'time': DateTime.now().toIso8601String(),
            },
          );
          final tmp =
              '${Directory.systemTemp.path}${Platform.pathSeparator}'
              '${LogExporter.fileNameFor(DateTime.now())}';
          File(tmp).writeAsStringSync(report);
          await Share.shareXFiles(
            <XFile>[XFile(tmp, mimeType: 'text/plain')],
            subject: 'QQ 客户端日志',
          );
        },
        onEnterApp: () => Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const HomePage()),
        ),
      ),
    );
  }
}

/// 四种登录方式（顶部切换）。用 String 而非 enum，避免引入过度类型。
enum _LoginMode { password, qrcode, phone, token }

/// 哑视图：只认状态与回调（可单独测）。
class Qq8ConnectView extends StatefulWidget {
  const Qq8ConnectView({
    super.key,
    required this.status,
    this.header,
    this.onPasswordLogin,
    this.onTokenLogin,
    this.onPhoneLogin,
    this.onSubmitTicket,
    this.onRequestSms,
    this.onSubmitSms,
    this.onRefreshSmsLoginCode,
    this.onSubmitSmsLoginCode,
    this.onUnlock,
    this.onFetchQrcode,
    this.onPollQrcode,
    this.onOpenBrowser,
    this.profileKey,
    this.profileKeys = const <String>[],
    this.onProfileChanged,
    this.onEnterApp,
    this.onExportLog,
  });

  final Qq8ConnectStatus status;

  /// 表单上方的附加区块（如 [RealServerPanel] 风险确认）。
  /// 哑视图不关心它是什么，只负责摆在顶部——测试可传 null。
  final Widget? header;

  final void Function(int uin, String password)? onPasswordLogin;
  final void Function(int uin)? onTokenLogin;
  final void Function(String phone)? onPhoneLogin;
  final void Function(String ticket)? onSubmitTicket;
  final VoidCallback? onRequestSms;
  final void Function(String code)? onSubmitSms;
  final VoidCallback? onRefreshSmsLoginCode;
  final void Function(String code)? onSubmitSmsLoginCode;
  final VoidCallback? onUnlock;
  final VoidCallback? onFetchQrcode;
  final VoidCallback? onPollQrcode;

  /// 打开系统浏览器（滑块验证页）。null 表示不可用（比如测试环境）。
  final void Function(String url)? onOpenBrowser;

  /// 当前客户端档案的注册键（[qq8ClientProfiles] 的 key；null = 不显示这一行）。
  ///
  /// 研究线要按档对照服务端裁决（8.2.11 → `type=1`，8.9.50/9.3.60 → `type=45`），
  /// 所以把"自称哪个客户端"摆到台面上，别靠改常量重发版。
  final String? profileKey;

  /// 可选档案键列表（空 = 不显示）。哑视图只认字符串，不认档案对象。
  final List<String> profileKeys;

  final void Function(String key)? onProfileChanged;

  final VoidCallback? onEnterApp;

  /// 导出日志（生成报告 → 系统分享面板）。
  final VoidCallback? onExportLog;

  @override
  State<Qq8ConnectView> createState() => _Qq8ConnectViewState();
}

class _Qq8ConnectViewState extends State<Qq8ConnectView> {
  final _uin = TextEditingController();
  final _password = TextEditingController();
  final _phone = TextEditingController();
  final _ticket = TextEditingController();
  final _sms = TextEditingController();

  /// 当前选中的登录方式（默认口令）。
  _LoginMode _mode = _LoginMode.password;

  /// 等扫码阶段的自动轮询计时器（见 [_syncQrPoll]）。
  Timer? _qrPoll;

  @override
  void initState() {
    super.initState();
    _syncQrPoll();
  }

  @override
  void dispose() {
    _qrPoll?.cancel();
    _uin.dispose();
    _password.dispose();
    _phone.dispose();
    _ticket.dispose();
    _sms.dispose();
    super.dispose();
  }

  /// 进入"等待扫码"就自动轮询（2 秒一次）。
  ///
  /// 官方客户端也是自动轮询：确认动作发生在**手机上**，手动点「刷新扫码状态」
  /// 很容易在确认之后才想起去点，白等一轮；而轮询本身开销极小。
  /// 服务层刻意不带定时器（节奏归 UI），所以计时器长在这里。
  void _syncQrPoll() {
    final shouldPoll = widget.status.stage == Qq8LoginStage.waitingQrScan &&
        widget.onPollQrcode != null;
    if (shouldPoll && _qrPoll == null) {
      _qrPoll = Timer.periodic(const Duration(seconds: 2), (_) {
        if (widget.status.busy) return; // 上一次还没回来就跳过这一拍
        widget.onPollQrcode?.call();
      });
    } else if (!shouldPoll && _qrPoll != null) {
      _qrPoll?.cancel();
      _qrPoll = null;
    }
  }

  /// 账号输入框里的 uin（解析失败返回 null）。
  int? get _parsedUin => int.tryParse(_uin.text.trim());

  bool get _busy => widget.status.busy;

  /// 用 `onOpenBrowser` 打开验证页（回调由页面注入：应用内 WebView）。
  void _openSliderBrowser() {
    final url = widget.status.sliderUrl;
    final open = widget.onOpenBrowser;
    if (url == null || url.isEmpty || open == null) return;
    open(url);
  }

  @override
  void didUpdateWidget(Qq8ConnectView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 收到"等待扫码"阶段时自动切到二维码表单——用户点了扫码才进这个状态，
    // 不该停留在口令页（旧实现把二维码内容塞在各阶段里，无需切换）。
    if (widget.status.stage == Qq8LoginStage.waitingQrScan &&
        _mode != _LoginMode.qrcode) {
      _mode = _LoginMode.qrcode;
    }
    _syncQrPoll();
  }

  /// 当前应展示的登录方式：密码 / 二维码 / 短信 / 免密。
  ///
  /// 阶段为 [Qq8LoginStage.waitingQrScan] 时强制展示二维码表单（用户点了扫码
  /// 才进这个状态），其余随时可手动切换。这里跟 `build` 同步派生，保证
  /// `initState` 与 `didUpdateWidget` 两条路都覆盖。
  _LoginMode get _effectiveMode {
    if (widget.status.stage == Qq8LoginStage.waitingQrScan) {
      return _LoginMode.qrcode;
    }
    return _mode;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.status;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        // 附加区块（风险确认等）——排在最前，因为它是登录的前置条件
        if (widget.header != null) ...<Widget>[
          widget.header!,
          const SizedBox(height: 16),
        ],
        // 客户端档案（研究线旋钮）：服务端裁决与"自称哪个客户端"强相关，
        // 摆出来才能真正做按档对照，而不是靠改常量重发版。
        ..._profileRow(context),
        // 顶部方式切换
        SegmentedButton<_LoginMode>(
          segments: const <ButtonSegment<_LoginMode>>[
            ButtonSegment<_LoginMode>(
                value: _LoginMode.password, label: Text('密码')),
            ButtonSegment<_LoginMode>(
                value: _LoginMode.qrcode, label: Text('二维码')),
            ButtonSegment<_LoginMode>(
                value: _LoginMode.phone, label: Text('短信')),
            ButtonSegment<_LoginMode>(
                value: _LoginMode.token, label: Text('免密')),
          ],
          selected: <_LoginMode>{_effectiveMode},
          onSelectionChanged: _busy
              ? null
              : (sel) => setState(() => _mode = sel.first),
        ),
        const SizedBox(height: 16),
        // 当前方式要做的这一件事
        ..._modeWidgets(context, s, _effectiveMode),
        const SizedBox(height: 12),
        // 状态行 / 错误（放在最下方，不打扰输入）
        _statusCard(context, s),
        const SizedBox(height: 8),
        // 日志导出（弱入口，排障用；也方便把日志发出来给人看）
        if (widget.onExportLog != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('qq8-export-log'),
              onPressed: widget.onExportLog,
              icon: const Icon(Icons.ios_share, size: 16),
              label: const Text('导出日志'),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
      ],
    );
  }

  /// 客户端档案一行（下拉 + 一句说明）。测试传空列表即整行不出现。
  List<Widget> _profileRow(BuildContext context) {
    if (widget.profileKeys.isEmpty) return const <Widget>[];
    final current = widget.profileKey != null &&
            widget.profileKeys.contains(widget.profileKey)
        ? widget.profileKey
        : null;
    return <Widget>[
      Row(
        children: <Widget>[
          Text(
            '客户端档案',
            style: TextStyle(
              color: TelegramColors.textSecondary,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(width: 10),
          DropdownButton<String>(
            key: const ValueKey('qq8-profile'),
            value: current,
            hint: const Text('选择档案'),
            isDense: true,
            underline: const SizedBox.shrink(),
            style: TextStyle(
              color: TelegramColors.textPrimary,
              fontSize: 13,
            ),
            items: <DropdownMenuItem<String>>[
              for (final k in widget.profileKeys)
                DropdownMenuItem<String>(value: k, child: Text(k)),
            ],
            onChanged: _busy || current == null
                ? null
                : (k) {
                    if (k != null) widget.onProfileChanged?.call(k);
                  },
          ),
        ],
      ),
      Text(
        '换档 = 换我们自称的客户端身份（版本/ssoVer/TLV 表）。切换会重建登录服务，'
        '必须重新发起登录；同一台设备只改这一个变量，才能对照服务端的裁决码。',
        style: TextStyle(
          color: TelegramColors.textMuted,
          fontSize: 11,
          height: 1.35,
        ),
      ),
      const SizedBox(height: 12),
    ];
  }

  /// 按当前选中的登录方式渲染提取表单。
  List<Widget> _modeWidgets(
      BuildContext context, Qq8ConnectStatus s, _LoginMode mode) {
    switch (mode) {
      case _LoginMode.password:
        return <Widget>[
          TextField(
            key: const ValueKey('qq8-uin'),
            controller: _uin,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'QQ 号'),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('qq8-password'),
            controller: _password,
            obscureText: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submitPassword(),
            decoration: const InputDecoration(labelText: '密码'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('qq8-login-password'),
            onPressed: _busy || widget.onPasswordLogin == null
                ? null
                : _submitPassword,
            child: const Text('登录'),
          ),
        ];
      case _LoginMode.qrcode:
        return <Widget>[
          const Text('用另一台设备上的 QQ 扫码确认。'),
          const SizedBox(height: 12),
          if (s.qrToken != null && s.qrToken!.isNotEmpty)
            Center(
              child: Image.memory(
                s.qrToken!,
                key: const ValueKey('qq8-qr-image'),
                width: 200,
                height: 200,
                errorBuilder: (context, error, stack) =>
                    const Text('二维码图片解析失败（内容不是 PNG？）'),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('qq8-fetch-qrcode'),
            onPressed: _busy || widget.onFetchQrcode == null
                ? null
                : widget.onFetchQrcode,
            child: Text(s.qrToken == null ? '获取二维码' : '刷新二维码'),
          ),
          if (s.qrToken != null && s.qrToken!.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            OutlinedButton(
              key: const ValueKey('qq8-poll-qrcode'),
              onPressed: _busy || widget.onPollQrcode == null
                  ? null
                  : widget.onPollQrcode,
              child: const Text('刷新扫码状态'),
            ),
          ],
        ];
      case _LoginMode.phone:
        return <Widget>[
          const Text('短信验证码登录（备用方式，服务器会给这个号发验证码）。'),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('qq8-phone'),
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: '手机号'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('qq8-login-phone'),
            onPressed: _busy || widget.onPhoneLogin == null
                ? null
                : () {
                    final phone = _phone.text.trim();
                    if (phone.isEmpty) return;
                    widget.onPhoneLogin!(phone);
                  },
            child: const Text('发送验证码'),
          ),
        ];
      case _LoginMode.token:
        return <Widget>[
          const Text('用这台设备上已保存的登录状态直接登录（不需要密码）。'),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('qq8-token-uin'),
            controller: _uin,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'QQ 号'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('qq8-login-token'),
            onPressed: _busy || widget.onTokenLogin == null
                ? null
                : () {
                    final uin = _parsedUin;
                    if (uin == null) return;
                    widget.onTokenLogin!(uin);
                  },
            child: const Text('免密登录'),
          ),
        ];
    }
  }

  /// 提交口令登录（按钮 onPressed 与回车共用）。
  void _submitPassword() {
    final uin = _parsedUin;
    if (uin == null || widget.onPasswordLogin == null) return;
    widget.onPasswordLogin!(uin, _password.text);
  }

  /// 状态卡：进行中 / 进行到哪一步 / 要人做什么 / 已上线。
  /// 关键：**滑块等验证阶段的表单始终显示**，不因切了方式切换而丢失。
  Widget _statusCard(BuildContext context, Qq8ConnectStatus s) {
    return _card(<Widget>[
      Row(children: <Widget>[
        Icon(_busy ? Icons.sync : Icons.info_outline, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(s.stateLabel)),
        if (s.uin != null) Text('账号=${s.uin}'),
      ]),
      if (_busy) const Padding(
        padding: EdgeInsets.only(top: 8),
        child: LinearProgressIndicator(),
      ),
      ..._stageWidgets(context, s),
    ]);
  }

  /// 按阶段渲染"要人做什么"。
  /// 阶段只补额外动作，不重复填表单；主机表单在上方 [_modeWidgets]。
  List<Widget> _stageWidgets(BuildContext context, Qq8ConnectStatus s) {
    switch (s.stage) {
      case Qq8LoginStage.needsSlider:
        return <Widget>[
          const SizedBox(height: 12),
          const Text('需要完成滑动验证。点下面在本应用内打开验证页，'
              '验证完成后会自动识别验证码：'),
          const SizedBox(height: 8),
          if (s.sliderUrl != null && s.sliderUrl!.isNotEmpty)
            SelectableText(s.sliderUrl!,
                key: const ValueKey('qq8-slider-url')),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('qq8-open-browser'),
            onPressed: widget.onOpenBrowser == null ? null : _openSliderBrowser,
            icon: const Icon(Icons.verified_outlined, size: 18),
            label: const Text('打开验证页'),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('qq8-ticket'),
            controller: _ticket,
            decoration: const InputDecoration(labelText: '验证码（ticket）'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: const ValueKey('qq8-submit-ticket'),
            onPressed: _busy || widget.onSubmitTicket == null
                ? null
                : () => widget.onSubmitTicket!(_ticket.text.trim()),
            child: const Text('提交验证码'),
          ),
        ];
      case Qq8LoginStage.needsSmsCode:
        // 两条短信线：手机号登录（smsFlow=true）与密码后补短信（false）。
        final smsFlow = s.smsFlow;
        final requestNext =
            smsFlow ? widget.onRefreshSmsLoginCode : widget.onRequestSms;
        final submitCode =
            smsFlow ? widget.onSubmitSmsLoginCode : widget.onSubmitSms;
        return <Widget>[
          const SizedBox(height: 12),
          Text(s.smsAutoSent
              ? '服务端已向 ${s.phone ?? '绑定手机'} 下发验证码'
              : '需要短信验证码（手机号 ${s.phone ?? '未知'}）'),
          if (smsFlow) const Text('（短信登录：验证码通过后会自动登录）'),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('qq8-sms-code'),
            controller: _sms,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '6 位验证码'),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: <Widget>[
            FilledButton(
              key: const ValueKey('qq8-submit-sms'),
              onPressed: _busy || submitCode == null
                  ? null
                  : () => submitCode(_sms.text.trim()),
              child: const Text('提交验证码'),
            ),
            OutlinedButton(
              key: const ValueKey('qq8-request-sms'),
              onPressed: _busy || requestNext == null ? null : requestNext,
              child: Text(smsFlow ? '重发验证码' : '重新下发'),
            ),
          ]),
        ];
      case Qq8LoginStage.needsDeviceLock:
        return <Widget>[
          const SizedBox(height: 12),
          Text(s.deviceLockHint ?? '账号开了设备锁，需要先解锁'),
          const SizedBox(height: 8),
          FilledButton(
            key: const ValueKey('qq8-unlock'),
            onPressed: _busy || widget.onUnlock == null ? null : widget.onUnlock,
            child: const Text('解锁'),
          ),
        ];
      case Qq8LoginStage.waitingQrScan:
        return const <Widget>[];
      case Qq8LoginStage.online:
        return <Widget>[
          const SizedBox(height: 12),
          const Text('已上线，可以进入聊天界面'),
          const SizedBox(height: 8),
          FilledButton(
            key: const ValueKey('qq8-enter'),
            onPressed: widget.onEnterApp,
            child: const Text('进入聊天'),
          ),
        ];
      case Qq8LoginStage.failed:
      case Qq8LoginStage.disconnected:
        return <Widget>[
          const SizedBox(height: 12),
          if (s.error != null)
            Text(s.error!,
                key: const ValueKey('qq8-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ];
      case Qq8LoginStage.idle:
      case Qq8LoginStage.connecting:
        return const <Widget>[];
    }
  }

  Widget _card(List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      );
}