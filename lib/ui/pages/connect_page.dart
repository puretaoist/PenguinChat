/// L4 连接页：全应用唯一允许发起连接的地方
///
/// ## 为什么单独做一页，而不是主界面塞个弹窗
///
/// 连接是整个客户端里唯一**可能造成不可逆后果**的操作：连到非本机地址
/// 意味着真实账号进入真实服务器的风控视野。做成独立页面，是为了让
/// 「地址 → 环境检测 → 逐条确认 → 连接」这条链路可见、可中断，
/// 而不是藏在一个按钮后面。
///
/// ## 判定一律交给 SafetyGate，本页不自己发明规则
///
/// 本页只做两件事：
///   1. 把「地址是不是本机」这个**事实**告诉用户（[isLoopbackAddress]）
///   2. 把 [SafetyGate.enableRealServer] 的拒绝原因**原文**显示出来
///
/// 「先放行再补救」是错的写法——闸门的意义就在于拦在连接之前。
/// 同理，连接失败时显示错误原文而不是「连接失败」：OneBot 的排障全靠这句。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/session.dart';
import '../../client_api/session_providers.dart';
import '../../kernel/safety/environment_probe.dart';
import '../../kernel/safety/safety_gate.dart';
import '../theme/telegram_theme.dart';
import 'home_page.dart';

class ConnectPage extends ConsumerStatefulWidget {
  const ConnectPage({super.key});

  @override
  ConsumerState<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends ConsumerState<ConnectPage> {
  late final TextEditingController _addressCtrl;
  late final TextEditingController _tokenCtrl;
  bool _tokenInHeader = false;

  /// 逐条确认的勾选状态。刻意做成 5 个独立勾选，不接受一键同意。
  final List<bool> _acked = List<bool>.filled(kRiskPoints.length, false);

  EnvironmentReport? _report;
  bool _probing = false;
  String? _probeError;
  String? _gateError;

  @override
  void initState() {
    super.initState();
    // 只读一次：之后再改地址不应被 provider 回写覆盖用户正在输入的内容。
    final cfg = ref.read(connectionConfigProvider);
    _addressCtrl = TextEditingController(text: cfg.address);
    _tokenCtrl = TextEditingController(text: cfg.accessToken);
    _tokenInHeader = cfg.tokenInHeader;
    // 地址决定「本机 / 非本机」，直接影响是否展示风险确认区，必须实时跟随输入。
    _addressCtrl.addListener(_onAddressChanged);
  }

  void _onAddressChanged() => setState(() {});

  @override
  void dispose() {
    _addressCtrl.removeListener(_onAddressChanged);
    _addressCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  bool get _isLoopback => isLoopbackAddress(_addressCtrl.text);

  bool get _allAcked => _acked.every((v) => v);

  // ---------------------------------------------------------------
  //  动作
  // ---------------------------------------------------------------

  Future<void> _probeEnvironment() async {
    setState(() {
      _probing = true;
      _probeError = null;
    });
    try {
      final report = await EnvironmentProbe().probe();
      if (mounted) setState(() => _report = report);
    } catch (e) {
      // 探测本身失败不是风险信号，但也不能装作没发生——显示原文。
      if (mounted) setState(() => _probeError = '$e');
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _enableRealServer() async {
    final gate = ref.read(safetyGateProvider);
    final acknowledged = [
      for (var i = 0; i < kRiskPoints.length; i++)
        if (_acked[i]) kRiskPoints[i],
    ];
    final rejected = await gate.enableRealServer(acknowledged, environment: _report);
    if (!mounted) return;
    setState(() => _gateError = rejected);
  }

  Future<void> _connect() async {
    final configNotifier = ref.read(connectionConfigProvider.notifier);
    await configNotifier.update(
      address: _addressCtrl.text.trim(),
      accessToken: _tokenCtrl.text,
      tokenInHeader: _tokenInHeader,
    );

    final controller = ref.read(connectionControllerProvider.notifier);
    await controller.connect(ref.read(connectionConfigProvider));
    if (!mounted) return;

    if (ref.read(connectionControllerProvider).isConnected) _leave();
  }

  Future<void> _disconnect() async {
    await ref.read(connectionControllerProvider.notifier).disconnect();
    if (mounted) setState(() {});
  }

  /// 立即切断：先断链路，再让闸门回到离线。顺序不能反——
  /// 先降级闸门的话，切断过程中若发生自动重连就没人拦了。
  Future<void> _killSwitch() async {
    await ref.read(connectionControllerProvider.notifier).disconnect();
    await ref.read(safetyGateProvider).killSwitch();
    if (mounted) setState(() {});
  }

  Future<void> _revokeConsent() async {
    await ref.read(connectionControllerProvider.notifier).disconnect();
    await ref.read(safetyGateProvider).revokeConsent();
    if (mounted) {
      setState(() {
        for (var i = 0; i < _acked.length; i++) {
          _acked[i] = false;
        }
        _gateError = null;
      });
    }
  }

  void _leave() {
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
    } else {
      // 连接页作为首屏时退无可退，直接换成主界面
      nav.pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const HomePage()),
      );
    }
  }

  // ---------------------------------------------------------------
  //  构建
  // ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(connectionControllerProvider);
    final gate = ref.watch(safetyGateProvider);
    final account = ref.watch(accountProvider);

    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      appBar: AppBar(
        backgroundColor: TelegramColors.bgHeader,
        foregroundColor: TelegramColors.textPrimary,
        elevation: 0,
        title: const Text('连接设置',
            style: TextStyle(fontSize: TelegramMetrics.fontTitle)),
        actions: [
          if (status.isConnected)
            TextButton(
              onPressed: _leave,
              child: const Text('进入主界面',
                  style: TextStyle(color: TelegramColors.accent)),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _addressSection(),
          const SizedBox(height: 16),
          _statusSection(status, account),
          const SizedBox(height: 16),
          if (!_isLoopback) ...[
            _dangerHint(),
            const SizedBox(height: 16),
            _riskSection(gate),
            const SizedBox(height: 16),
          ],
          _modeFooter(gate),
        ],
      ),
    );
  }

  Widget _addressSection() {
    final status = ref.watch(connectionControllerProvider);
    return _Card(
      title: '后端地址',
      children: [
        TextField(
          controller: _addressCtrl,
          style: const TextStyle(color: TelegramColors.textPrimary, fontSize: 14),
          decoration: _inputDecoration('ws://127.0.0.1:3001'),
        ),
        const SizedBox(height: 6),
        Text(
          _isLoopback
              ? '本机地址 —— 后端进程跑在这台机器上，不需要风险确认'
              : '非本机地址 —— 账号将由远端进程驱动，需要先完成风险确认',
          style: TextStyle(
            color: _isLoopback ? TelegramColors.textSecondary : _warnColor,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _tokenCtrl,
          obscureText: true,
          style: const TextStyle(color: TelegramColors.textPrimary, fontSize: 14),
          decoration: _inputDecoration('访问令牌（后端未开鉴权就留空）'),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: _tokenInHeader,
          activeThumbColor: TelegramColors.accent,
          onChanged: (v) => setState(() => _tokenInHeader = v),
          title: const Text('令牌放在 Authorization 头',
              style: TextStyle(color: TelegramColors.textPrimary, fontSize: 13)),
          subtitle: const Text(
            '默认走 ?access_token= 查询参数；NapCat 两种都支持，按你的配置选',
            style: TextStyle(color: TelegramColors.textSecondary, fontSize: 11),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _PrimaryButton(
                label: status.busy ? '连接中…' : '连接',
                onPressed: status.busy ? null : _connect,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _OutlinedButton(
                label: '断开',
                onPressed: status.busy ? null : _disconnect,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _statusSection(ConnectionStatus status, AccountInfo? account) {
    return _Card(
      title: '连接状态',
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: status.isConnected
                    ? TelegramColors.online
                    : TelegramColors.textMuted,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              status.stateLabel,
              style: const TextStyle(
                color: TelegramColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (status.busy) ...[
              const SizedBox(width: 12),
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ],
        ),
        if (account != null) ...[
          const SizedBox(height: 12),
          _kv('账号', account.uin),
          _kv('昵称', account.nickname.isEmpty ? '（后端未提供）' : account.nickname),
          _kv('后端', account.backendName ?? '（未上报）'),
          _kv('后端版本', account.backendVersion ?? '（未上报）'),
          _kv('协议版本', account.protocolVersion ?? '（未上报）'),
        ],
        if (status.error != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _errorBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _errorBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('错误原文',
                    style: TextStyle(
                        color: _warnColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                // 排障靠这句：原文照抄，不做归纳，可选中复制
                SelectableText(
                  status.error!,
                  style: const TextStyle(
                      color: TelegramColors.textPrimary,
                      fontSize: 12.5,
                      height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _dangerHint() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _errorBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _errorBorder),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: _warnColor, size: 18),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '你正在配置一个非本机地址。这意味着有另一个进程（很可能是别人或别的设备）'
              '在驱动这个账号——用非官方客户端连接真实服务器违反《QQ 用户协议》，'
              '账号可能被限制登录或永久封禁。',
              style: TextStyle(
                  color: TelegramColors.textPrimary, fontSize: 12.5, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _riskSection(SafetyGate gate) {
    final report = _report;
    return _Card(
      title: '风险确认',
      children: [
        Text(
          '开启真实服务器模式需要过两道关：先做环境检测（高危环境直接拒绝），'
          '再逐条确认下面 ${kRiskPoints.length} 项。',
          style: const TextStyle(
              color: TelegramColors.textSecondary, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _OutlinedButton(
                label: _probing ? '检测中…' : (_report == null ? '环境检测' : '重新检测'),
                onPressed: _probing ? null : _probeEnvironment,
              ),
            ),
            const SizedBox(width: 10),
            if (report != null)
              Text(
                '等级：${report.level.label}',
                style: TextStyle(
                  color: report.blocksRealServer ? _warnColor : TelegramColors.online,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
        if (_probeError != null) ...[
          const SizedBox(height: 8),
          Text('环境检测失败：$_probeError',
              style: const TextStyle(color: _warnColor, fontSize: 12)),
        ],
        if (report != null) ...[
          const SizedBox(height: 10),
          ...report.sortedFindings.map(
            (f) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '· [${f.severity.label}] ${f.label}：${f.detail}',
                style: const TextStyle(
                    color: TelegramColors.textSecondary, fontSize: 12, height: 1.4),
              ),
            ),
          ),
          if (report.findings.isEmpty)
            const Text('未发现常见风险信号。',
                style: TextStyle(color: TelegramColors.textSecondary, fontSize: 12)),
          if (report.undetectable.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Text(
              '探测不到的部分（诚实说明局限）：',
              style: TextStyle(color: TelegramColors.textMuted, fontSize: 11),
            ),
            ...report.undetectable.map(
              (u) => Text('· $u',
                  style: const TextStyle(
                      color: TelegramColors.textMuted, fontSize: 11, height: 1.35)),
            ),
          ],
        ],
        const Divider(color: TelegramColors.divider, height: 24),
        for (var i = 0; i < kRiskPoints.length; i++)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _acked[i],
            activeColor: TelegramColors.accent,
            onChanged: (v) => setState(() => _acked[i] = v ?? false),
            title: Text(
              kRiskPoints[i],
              style: const TextStyle(
                  color: TelegramColors.textPrimary, fontSize: 12.5, height: 1.4),
            ),
          ),
        const SizedBox(height: 8),
        _PrimaryButton(
          label: '开启真实服务器模式',
          // 全勾选才可点；环境报告的校验交给闸门（它会给原文原因）
          onPressed: _allAcked ? _enableRealServer : null,
        ),
        if (_gateError != null) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _errorBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _errorBorder),
            ),
            child: Text(
              _gateError!,
              style: const TextStyle(
                  color: TelegramColors.textPrimary, fontSize: 12.5, height: 1.45),
            ),
          ),
        ],
        if (gate.isRealServer) ...[
          const SizedBox(height: 12),
          const Text(
            '真实服务器模式已开启。不用了请尽早关闭——模式开着本身就是风险。',
            style: TextStyle(color: _warnColor, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _modeFooter(SafetyGate gate) {
    return _Card(
      title: '安全模式',
      children: [
        Text(
          gate.describe(),
          style: const TextStyle(
              color: TelegramColors.textPrimary, fontSize: 13, height: 1.4),
        ),
        if (gate.consent != null) ...[
          const SizedBox(height: 6),
          Text(
            '同意时间：${gate.consent!.at.toLocal()}　声明版本：${gate.consent!.statementVersion}',
            style: const TextStyle(color: TelegramColors.textSecondary, fontSize: 11),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _OutlinedButton(
                label: '立即切断',
                danger: true,
                onPressed: _killSwitch,
              ),
            ),
            if (gate.consent != null) ...[
              const SizedBox(width: 10),
              Expanded(
                child: _OutlinedButton(
                  label: '撤销同意',
                  danger: true,
                  onPressed: _revokeConsent,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 68,
              child: Text(k,
                  style: const TextStyle(
                      color: TelegramColors.textSecondary, fontSize: 12)),
            ),
            Expanded(
              child: SelectableText(v,
                  style: const TextStyle(
                      color: TelegramColors.textPrimary, fontSize: 12.5)),
            ),
          ],
        ),
      );

  InputDecoration _inputDecoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: TelegramColors.textMuted, fontSize: 13),
        isDense: true,
        filled: true,
        fillColor: TelegramColors.bgHover,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      );
}

// ---------------------------------------------------------------------------
//  小组件（本页自用，避免动到已调好的主界面组件）
// ---------------------------------------------------------------------------

const Color _warnColor = Color(0xFFE8A33D);
const Color _errorBg = Color(0x33E05252);
const Color _errorBorder = Color(0x66E05252);

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: TelegramColors.bgSidebar,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: TelegramColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: TelegramColors.accent,
          disabledBackgroundColor: TelegramColors.bgHover,
          foregroundColor: Colors.white,
          disabledForegroundColor: TelegramColors.textMuted,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(label, style: const TextStyle(fontSize: 14)),
      ),
    );
  }
}

class _OutlinedButton extends StatelessWidget {
  const _OutlinedButton({
    required this.label,
    required this.onPressed,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final color = danger ? _warnColor : TelegramColors.textPrimary;
    return SizedBox(
      height: 42,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          disabledForegroundColor: TelegramColors.textMuted,
          side: BorderSide(
            color: enabled ? color.withValues(alpha: 0.5) : TelegramColors.divider,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(label, style: const TextStyle(fontSize: 14)),
      ),
    );
  }
}
