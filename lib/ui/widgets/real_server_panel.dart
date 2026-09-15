/// L4 组件：真实服务器模式开关面板（风险确认 UI）
///
/// ## 为什么需要它
///
/// `SafetyGate` 在每次联网前校验「真实服务器模式 + 有效知情同意」，
/// 没开时协议线登录会返回一句话：
///
/// > 要连接真实 QQ 服务器，需要先在「风险确认」里开启真实服务器模式：…
///
/// 而那个「风险确认」界面原先只长在 OneBot 连接页（`connect_page.dart`）里，
/// **QQ8 登录页自己没有入口** —— 用户被提示去开，却无处可开（真机上实际卡住）。
/// 本组件把这段流程抽成可复用面板，QQ8 登录页直接放一个即可。
///
/// ## 流程（与 connect_page 的同款两道关，判定一律交给 SafetyGate）
///
/// 1. **环境检测**：`EnvironmentProbe().probe()`；高危环境由闸门直接拒绝。
/// 2. **逐条确认**：[kRiskPoints] 全部 5 项独立勾选（不接受一键同意）。
/// 3. 交 [SafetyGate.enableRealServer] 判定，拒绝原因**原文**显示。
///
/// 开启后收起为一行状态（可一键关闭——模式开着本身就是风险）。
///
/// 本文件是 Flutter 层（L4）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/session_providers.dart' show safetyGateProvider;
import '../../kernel/safety/environment_probe.dart';
import '../../kernel/safety/safety_gate.dart';
import '../theme/telegram_theme.dart';

/// 警告色 / 错误底色（与 connect_page 同款，日志导出页对齐视觉）。
const Color _warnColor = Color(0xFFE8A33D);
const Color _errorBg = Color(0x33E05252);
const Color _errorBorder = Color(0x66E05252);

/// 真实服务器模式开关面板。
///
/// 未开启：显示警示横幅，点击展开完整流程（环境检测 → 逐条确认 → 开启）。
/// 已开启：收起为一行状态，点击可关闭（回到离线）。
class RealServerPanel extends ConsumerStatefulWidget {
  const RealServerPanel({super.key, this.expandedByDefault = false});

  /// 初次渲染就展开（登录页希望用户一眼看到该做什么时置 true）。
  final bool expandedByDefault;

  @override
  ConsumerState<RealServerPanel> createState() => _RealServerPanelState();
}

class _RealServerPanelState extends ConsumerState<RealServerPanel> {
  /// 逐条确认的勾选状态。刻意做成 5 个独立勾选，不接受一键同意。
  final List<bool> _acked = List<bool>.filled(kRiskPoints.length, false);

  late bool _expanded = widget.expandedByDefault;

  EnvironmentReport? _report;
  bool _probing = false;
  String? _probeError;
  String? _gateError;

  bool get _allAcked => _acked.every((v) => v);

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
    final rejected = await gate.enableRealServer(
      acknowledged,
      environment: _report,
    );
    if (!mounted) return;
    setState(() {
      _gateError = rejected;
      if (rejected == null) _expanded = false;
    });
  }

  Future<void> _turnOff() async {
    await ref.read(safetyGateProvider).killSwitch();
    if (!mounted) return;
    setState(() {
      _gateError = null;
      for (var i = 0; i < _acked.length; i++) {
        _acked[i] = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final gate = ref.watch(safetyGateProvider);
    if (gate.isRealServer) {
      // 已开启：一行状态 + 可关闭。
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _errorBg.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _errorBorder),
        ),
        child: Row(
          children: <Widget>[
            const Icon(
              Icons.warning_amber_rounded,
              color: _warnColor,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '真实服务器模式已开启 —— 正在操作真实账号',
                style: TextStyle(
                  color: TelegramColors.textPrimary,
                  fontSize: 12.5,
                ),
              ),
            ),
            TextButton(
              key: const ValueKey('real-server-off'),
              onPressed: _turnOff,
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    }

    // 未开启：横幅（可展开）。
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: TelegramColors.bgInput,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _warnColor.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            key: const ValueKey('real-server-banner'),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.lock_outline, color: _warnColor, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '连腾讯服务器前，需要先开启「真实服务器模式」',
                      style: TextStyle(
                        color: TelegramColors.textPrimary,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: TelegramColors.textSecondary,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            // Material(transparency)：CheckboxListTile 的墨水效果必须画在
            // Material 上，直接放在有背景色的 Container 里会触发断言
            //（"ListTile background color or ink splashes may be invisible"）。
            Material(
              type: MaterialType.transparency,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '开启需要过两道关：先做环境检测（高危环境直接拒绝），'
                      '再逐条确认下面 ${kRiskPoints.length} 项。',
                      style: TextStyle(
                        color: TelegramColors.textSecondary,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: OutlinedButton(
                            key: const ValueKey('real-server-probe'),
                            onPressed: _probing ? null : _probeEnvironment,
                            child: Text(
                              _probing
                                  ? '检测中…'
                                  : (_report == null ? '环境检测' : '重新检测'),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        if (_report != null)
                          Text(
                            '等级：${_report!.level.label}',
                            style: TextStyle(
                              color: _report!.blocksRealServer
                                  ? _warnColor
                                  : TelegramColors.online,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                    if (_probeError != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        '环境检测失败：$_probeError',
                        style: TextStyle(color: _warnColor, fontSize: 12),
                      ),
                    ],
                    if (_report != null) ...[
                      const SizedBox(height: 10),
                      ..._report!.sortedFindings.map(
                        (f) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '· [${f.severity.label}] ${f.label}：${f.detail}',
                            style: TextStyle(
                              color: TelegramColors.textSecondary,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
                      if (_report!.findings.isEmpty)
                        Text(
                          '未发现常见风险信号。',
                          style: TextStyle(
                            color: TelegramColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      if (_report!.undetectable.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          '探测不到的部分（诚实说明局限）：',
                          style: TextStyle(
                            color: TelegramColors.textMuted,
                            fontSize: 11,
                          ),
                        ),
                        ..._report!.undetectable.map(
                          (u) => Text(
                            '· $u',
                            style: TextStyle(
                              color: TelegramColors.textMuted,
                              fontSize: 11,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ],
                    Divider(color: TelegramColors.divider, height: 24),
                    for (var i = 0; i < kRiskPoints.length; i++)
                      CheckboxListTile(
                        key: ValueKey('real-server-ack-$i'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _acked[i],
                        activeColor: TelegramColors.accent,
                        onChanged: (v) =>
                            setState(() => _acked[i] = v ?? false),
                        title: Text(
                          kRiskPoints[i],
                          style: TextStyle(
                            color: TelegramColors.textPrimary,
                            fontSize: 12.5,
                            height: 1.4,
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        key: const ValueKey('real-server-enable'),
                        // 全勾选才可点；环境报告的校验交给闸门（它会给原文原因）
                        onPressed: _allAcked ? _enableRealServer : null,
                        child: const Text('开启真实服务器模式'),
                      ),
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
                          style: TextStyle(
                            color: TelegramColors.textPrimary,
                            fontSize: 12.5,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
