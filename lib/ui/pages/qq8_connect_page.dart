/// L4 协议线登录页：口令 / 票据 / 扫码三种入口 + 多步验证的表单
///
/// ## 与 OneBot 连接页的分工
///
/// `connect_page.dart` 连的是**本机/远端进程**（OneBot 后端），
/// 本页连的是**腾讯服务器**（协议线）——后者每一步都要过 `SafetyGate`（在
/// `Qq8LoginService` 里把关），所以本页不做任何风险判断，只做两件事：
///
/// 1. 按 [Qq8ConnectStatus.stage] 渲染"现在要人做什么"（滑块 / 短信 / 设备锁 / 扫码）；
/// 2. 把输入交给 [Qq8ConnectController] 的动作。
///
/// ## 拆成两层是为了能测
///
/// [Qq8ConnectView] 是**哑视图**（状态 + 回调，纯 UI），
/// [Qq8ConnectPage] 只是把它接到 provider 上。这样 widget 测试能直接喂各种
/// 状态，把"每个阶段该出现什么、回调有没有被调"全测到，而不需要真登录。
///
/// ## 二维码怎么显示
///
/// `0x17` 里就是**PNG 图片字节**（参考实现 `logQrcode` 直接 `PNG.sync.read`），
/// 所以 `Image.memory` 就能渲染——不需要二维码编码依赖。
///
/// 本文件是 Flutter 层（L4）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/qq8_login_service.dart';
import '../../client_api/qq8_providers.dart';
import 'home_page.dart';

/// 协议线登录页（把 [Qq8ConnectView] 接到 provider 上）。
class Qq8ConnectPage extends ConsumerWidget {
  const Qq8ConnectPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(qq8ConnectControllerProvider);
    final c = ref.read(qq8ConnectControllerProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('协议线登录（QQ）')),
      body: Qq8ConnectView(
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
        onEnterApp: () => Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const HomePage()),
        ),
      ),
    );
  }
}

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
    this.onEnterApp,
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
  final VoidCallback? onEnterApp;

  @override
  State<Qq8ConnectView> createState() => _Qq8ConnectViewState();
}

class _Qq8ConnectViewState extends State<Qq8ConnectView> {
  final _uin = TextEditingController();
  final _password = TextEditingController();
  final _phone = TextEditingController();
  final _ticket = TextEditingController();
  final _sms = TextEditingController();

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

  @override
  Widget build(BuildContext context) {
    final s = widget.status;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        _card(<Widget>[
          Text('登录 QQ 账号（协议线）',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
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
            decoration: const InputDecoration(labelText: '口令（只在本机内存里转 MD5）'),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('qq8-phone'),
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: '手机号（短信登录用；服务器会给这个号发验证码）',
            ),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: <Widget>[
            FilledButton(
              key: const ValueKey('qq8-login-password'),
              onPressed: _busy || widget.onPasswordLogin == null
                  ? null
                  : () {
                      final uin = _parsedUin;
                      if (uin == null) return;
                      widget.onPasswordLogin!(uin, _password.text);
                    },
              child: const Text('口令登录'),
            ),
            OutlinedButton(
              key: const ValueKey('qq8-login-phone'),
              onPressed: _busy || widget.onPhoneLogin == null
                  ? null
                  : () {
                      final phone = _phone.text.trim();
                      if (phone.isEmpty) return;
                      widget.onPhoneLogin!(phone);
                    },
              child: const Text('手机号短信登录'),
            ),
            OutlinedButton(
              key: const ValueKey('qq8-login-token'),
              onPressed: _busy || widget.onTokenLogin == null
                  ? null
                  : () {
                      final uin = _parsedUin;
                      if (uin == null) return;
                      widget.onTokenLogin!(uin);
                    },
              child: const Text('用已保存票据登录'),
            ),
            OutlinedButton(
              key: const ValueKey('qq8-fetch-qrcode'),
              onPressed: _busy || widget.onFetchQrcode == null
                  ? null
                  : widget.onFetchQrcode,
              child: const Text('扫码登录'),
            ),
          ]),
        ]),
        const SizedBox(height: 12),
        _card(<Widget>[
          Row(children: <Widget>[
            Icon(_busy ? Icons.sync : Icons.info_outline, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(s.stateLabel)),
            if (s.uin != null) Text('uin=${s.uin}'),
          ]),
          if (_busy) const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(),
          ),
          ..._stageWidgets(context, s),
        ]),
      ],
    );
  }

  /// 按阶段渲染"要人做什么"。
  List<Widget> _stageWidgets(BuildContext context, Qq8ConnectStatus s) {
    switch (s.stage) {
      case Qq8LoginStage.needsSlider:
        return <Widget>[
          const SizedBox(height: 12),
          const Text('在浏览器里打开下面的地址完成验证，把拿到的 ticket 粘贴回来：'),
          SelectableText(s.sliderUrl ?? '(地址为空)',
              key: const ValueKey('qq8-slider-url')),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('qq8-ticket'),
            controller: _ticket,
            decoration: const InputDecoration(labelText: 'ticket'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: const ValueKey('qq8-submit-ticket'),
            onPressed: _busy || widget.onSubmitTicket == null
                ? null
                : () => widget.onSubmitTicket!(_ticket.text.trim()),
            child: const Text('提交 ticket'),
          ),
        ];
      case Qq8LoginStage.needsSmsCode:
        // 两条短信线的按钮不一样：手机号登录用 19（下发）/18（提交），
        // 密码登录后补短信用 8/7。UI 只认 smsFlow 这个标记，不认内部子命令。
        final smsFlow = s.smsFlow;
        final requestNext = smsFlow
            ? widget.onRefreshSmsLoginCode
            : widget.onRequestSms;
        final submitCode = smsFlow ? widget.onSubmitSmsLoginCode : widget.onSubmitSms;
        return <Widget>[
          const SizedBox(height: 12),
          Text(s.smsAutoSent
              ? '服务端已向 ${s.phone ?? '绑定手机'} 下发验证码'
              : '需要短信验证码（手机号 ${s.phone ?? '未知'}）'),
          if (smsFlow) const Text('（手机号短信登录：验证码通过后会自动完成登录）'),
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
              child: Text(smsFlow ? '下发/重发验证码' : '重新下发'),
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
        return <Widget>[
          const SizedBox(height: 12),
          Text(s.qrMessage ?? '请用手机 QQ 扫码'),
          const SizedBox(height: 8),
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
          const SizedBox(height: 8),
          OutlinedButton(
            key: const ValueKey('qq8-poll-qrcode'),
            onPressed: _busy || widget.onPollQrcode == null
                ? null
                : widget.onPollQrcode,
            child: const Text('刷新扫码状态'),
          ),
        ];
      case Qq8LoginStage.online:
        return <Widget>[
          const SizedBox(height: 12),
          const Text('已上线，可以进入聊天界面'),
          const SizedBox(height: 8),
          FilledButton(
            key: const ValueKey('qq8-enter'),
            onPressed: widget.onEnterApp,
            child: const Text('进入'),
          ),
        ];
      case Qq8LoginStage.failed:
      case Qq8LoginStage.disconnected:
        return <Widget>[
          const SizedBox(height: 12),
          Text(s.error ?? '已断开',
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
