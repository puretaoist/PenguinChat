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
/// * 滑块验证用 `url_launcher` 打开系统浏览器，解完把验证码粘回来
///   （手机上无 F12，不能像 PC 那样抓 ticket）；
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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../client_api/qq8_login_service.dart';
import '../../client_api/qq8_providers.dart';
import '../../client_api/session_providers.dart' show dataDirProvider;
import '../../infra/log/log_file.dart';
import 'home_page.dart';

/// 协议线登录页（把 [Qq8ConnectView] 接到 provider 上）。
class Qq8ConnectPage extends ConsumerWidget {
  const Qq8ConnectPage({super.key});

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
        onOpenBrowser: (url) => launchUrl(Uri.parse(url),
            mode: LaunchMode.externalApplication),
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
    this.onEnterApp,
    this.onExportLog,
  });

  final Qq8ConnectStatus status;
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

  @override
  void dispose() {
    _uin.dispose();
    _password.dispose();
    _phone.dispose();
    _ticket.dispose();
    _sms.dispose();
    super.dispose();
  }

  /// 账号输入框里的 uin（解析失败返回 null）。
  int? get _parsedUin => int.tryParse(_uin.text.trim());

  bool get _busy => widget.status.busy;

  /// 用 `onOpenBrowser` 打开滑块页（回调由页面注入 launchUrl）。
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
          const Text('需要完成滑动验证。点下面打开浏览器，滑完后把验证码复制回来：'),
          const SizedBox(height: 8),
          if (s.sliderUrl != null && s.sliderUrl!.isNotEmpty)
            SelectableText(s.sliderUrl!,
                key: const ValueKey('qq8-slider-url')),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('qq8-open-browser'),
            onPressed: widget.onOpenBrowser == null ? null : _openSliderBrowser,
            icon: const Icon(Icons.open_in_browser, size: 18),
            label: const Text('在浏览器打开滑块页'),
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