/// 群设置面板（哑视图）：群名 / 群公告 / 全员禁言。
///
/// 与 [GroupFilesPanel] 一样只做呈现与回调，**不认识协议**：
/// 三个动作都由调用方注入（见 `Qq8LoginService.setGroupName /
/// setGroupAnnounce / setGroupWholeMute`）。
///
/// 为什么全员禁言用两个按钮而不是开关：我们**没有拉群详情**的接口
/// （`0x88d_0` 那套还没接），拿不到当前是开还是关。与其画一个可能反了的
/// 开关，不如让用户明确点「开」或「解除」。
library;

import 'package:flutter/material.dart';
import 'package:qqclient/ui/theme/telegram_theme.dart';

class GroupSettingsPanel extends StatefulWidget {
  const GroupSettingsPanel({
    super.key,
    required this.title,
    required this.initialName,
    this.onRename,
    this.onAnnounce,
    this.onWholeMute,
  });

  final String title;
  final String initialName;

  /// 成功返回 true（面板据此提示）；抛异常则在面板里显示原因。
  final Future<bool> Function(String name)? onRename;
  final Future<bool> Function(String content)? onAnnounce;
  final Future<bool> Function(bool enable)? onWholeMute;

  static Future<void> show(
    BuildContext context, {
    required String title,
    required String initialName,
    Future<bool> Function(String name)? onRename,
    Future<bool> Function(String content)? onAnnounce,
    Future<bool> Function(bool enable)? onWholeMute,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: TelegramColors.bgSidebar,
      isScrollControlled: true,
      builder: (_) => GroupSettingsPanel(
        title: title,
        initialName: initialName,
        onRename: onRename,
        onAnnounce: onAnnounce,
        onWholeMute: onWholeMute,
      ),
    );
  }

  @override
  State<GroupSettingsPanel> createState() => _GroupSettingsPanelState();
}

class _GroupSettingsPanelState extends State<GroupSettingsPanel> {
  late final TextEditingController _nameCtl =
      TextEditingController(text: widget.initialName);
  final TextEditingController _annCtl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _nameCtl.dispose();
    _annCtl.dispose();
    super.dispose();
  }

  Future<void> _run(Future<bool> Function() action, String okText) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await action();
      if (!mounted) return;
      _toast(ok ? okText : '服务端没有确认成功（看日志里的结果码）');
    } on Object catch (e) {
      if (mounted) _toast('失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.72,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('群设置',
                          key: const ValueKey('gset-title'),
                          style: TextStyle(
                              color: TelegramColors.textPrimary,
                              fontSize: TelegramMetrics.fontTitle,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: TelegramColors.textSecondary,
                              fontSize: 12.5)),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close,
                      size: 20, color: TelegramColors.textSecondary),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: TelegramColors.divider),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
              children: <Widget>[
                _label('群名'),
                TextField(
                  key: const ValueKey('gset-name'),
                  controller: _nameCtl,
                  decoration: const InputDecoration(hintText: '新的群名'),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: const ValueKey('gset-name-ok'),
                    onPressed: widget.onRename == null || _busy
                        ? null
                        : () => _run(
                            () => widget.onRename!(_nameCtl.text.trim()),
                            '群名已改'),
                    child: const Text('保存群名'),
                  ),
                ),
                const SizedBox(height: 12),
                _label('群公告（简易版，纯文本）'),
                TextField(
                  key: const ValueKey('gset-announce'),
                  controller: _annCtl,
                  maxLines: 4,
                  decoration: const InputDecoration(hintText: '要告诉全群的话'),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: const ValueKey('gset-announce-ok'),
                    onPressed: widget.onAnnounce == null || _busy
                        ? null
                        : () => _run(
                            () => widget.onAnnounce!(_annCtl.text.trim()),
                            '公告已发'),
                    child: const Text('发布公告'),
                  ),
                ),
                const SizedBox(height: 16),
                _label('全员禁言'),
                Text(
                  '拿不到当前状态（群详情接口还没接），所以给两个明确按钮。',
                  style:
                      TextStyle(color: TelegramColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    OutlinedButton(
                      key: const ValueKey('gset-mute-all-on'),
                      onPressed: widget.onWholeMute == null || _busy
                          ? null
                          : () => _run(
                              () => widget.onWholeMute!(true), '已开启全员禁言'),
                      child: const Text('开启'),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      key: const ValueKey('gset-mute-all-off'),
                      onPressed: widget.onWholeMute == null || _busy
                          ? null
                          : () => _run(
                              () => widget.onWholeMute!(false), '已解除全员禁言'),
                      child: const Text('解除'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: TextStyle(
                color: TelegramColors.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w600)),
      );
}
