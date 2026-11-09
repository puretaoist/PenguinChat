/// L4 PC NTLogin 扫码登录页：显示二维码、状态，登录成功后进入主界面。
///
/// 与现有 Android 协议登录页并行，不改变原有登录方式；仅新增一条「PC 扫码」入口。
/// 说明：本页只负责登录；登录后的消息收发仍在后续 PC 收发层实现前不可用。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../client_api/pc_login_providers.dart';
import '../../client_api/pc_login_service.dart';
import 'home_page.dart';

class PcScanPage extends ConsumerStatefulWidget {
  const PcScanPage({super.key});

  @override
  ConsumerState<PcScanPage> createState() => _PcScanPageState();
}

class _PcScanPageState extends ConsumerState<PcScanPage> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() async {
      final svc = ref.read(pcLoginServiceProvider);
      // 优先复用持久化 session（免重复扫码）；失败再走扫码
      final resumed = await svc.tryResumeOnline();
      if (!resumed) svc.startQrLogin();
    });
  }

  String _stageText(PcLoginStage s) => switch (s) {
        PcLoginStage.idle => '准备中…',
        PcLoginStage.connecting => '连接服务器…',
        PcLoginStage.qrReady => '请用手机 QQ 扫码',
        PcLoginStage.waitingConfirm => '已扫描，请在手机上点「确认登录」',
        PcLoginStage.loggingIn => '正在登录…',
        PcLoginStage.online => '登录成功',
        PcLoginStage.failed => '登录失败',
      };

  @override
  Widget build(BuildContext context) {
    final svc = ref.read(pcLoginServiceProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('PC 扫码登录')),
      body: StreamBuilder<PcLoginSnapshot>(
        stream: svc.states,
        initialData: svc.last,
        builder: (context, snap) {
          final s = snap.data ?? PcLoginSnapshot.idle;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Text(_stageText(s.stage),
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              if (s.qrImage != null)
                Center(
                  child: Image.memory(s.qrImage!,
                      width: 240, height: 240, gaplessPlayback: true),
                ),
              if (s.qrUrl != null) ...<Widget>[
                const SizedBox(height: 8),
                SelectableText(s.qrUrl!,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
              const SizedBox(height: 16),
              if (s.stage == PcLoginStage.online)
                FilledButton(
                  onPressed: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute<void>(builder: (_) => const HomePage()),
                  ),
                  child: Text('进入（${s.uin}）'),
                ),
              if (s.stage == PcLoginStage.failed) ...<Widget>[
                Text(s.error ?? '未知错误',
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => svc.startQrLogin(),
                  child: const Text('重试'),
                ),
              ],
              const SizedBox(height: 24),
              Text('签名服务：${ref.watch(pcSignServerProvider)}',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          );
        },
      ),
    );
  }
}
