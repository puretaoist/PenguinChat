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
                              // 与 settings_page 页头一致：20dp（ActionBar.java:654）
                              fontSize: 20,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: TelegramColors.textSecondary,
                              fontSize: 13)),
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
              padding: EdgeInsets.zero,
              children: <Widget>[
                // 分组标题走 TG GraySectionCell 的版式：
                // ui/Cells/GraySectionCell.java:40 layerHeight=32、:57 字 14、
                // :54 key_graySection 底色、:61 左右各 padding(默认 16)。
                _section('群名'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: TextField(
                    key: const ValueKey('gset-name'),
                    controller: _nameCtl,
                    style: TextStyle(
                        fontSize: 16, color: TelegramColors.textPrimary),
                    decoration: _fieldDecoration('新的群名'),
                  ),
                ),
                _actionRow(
                  key: 'gset-name-ok',
                  label: '保存群名',
                  onTap: widget.onRename == null || _busy
                      ? null
                      : () => _run(
                          () => widget.onRename!(_nameCtl.text.trim()), '群名已改'),
                ),
                _section('群公告（简易版，纯文本）'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: TextField(
                    key: const ValueKey('gset-announce'),
                    controller: _annCtl,
                    maxLines: 4,
                    style: TextStyle(
                        fontSize: 16, color: TelegramColors.textPrimary),
                    decoration: _fieldDecoration('要告诉全群的话'),
                  ),
                ),
                _actionRow(
                  key: 'gset-announce-ok',
                  label: '发布公告',
                  onTap: widget.onAnnounce == null || _busy
                      ? null
                      : () => _run(() => widget.onAnnounce!(_annCtl.text.trim()),
                          '公告已发'),
                ),
                _section('全员禁言'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                  child: Text(
                    '拿不到当前状态（群详情接口还没接），所以给两个明确按钮。',
                    style: TextStyle(
                        color: TelegramColors.textMuted, fontSize: 13),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Row(
                    children: <Widget>[
                      OutlinedButton(
                        key: const ValueKey('gset-mute-all-on'),
                        onPressed: widget.onWholeMute == null || _busy
                            ? null
                            : () => _run(() => widget.onWholeMute!(true),
                                '已开启全员禁言'),
                        child: const Text('开启'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        key: const ValueKey('gset-mute-all-off'),
                        onPressed: widget.onWholeMute == null || _busy
                            ? null
                            : () => _run(() => widget.onWholeMute!(false),
                                '已解除全员禁言'),
                        child: const Text('解除'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// TG `GraySectionCell` 版式的分组标题（32 高、14 w700、灰底、左右 16）。
  Widget _section(String text) => Container(
        height: 32,
        width: double.infinity,
        margin: const EdgeInsets.only(top: 8),
        color: TelegramColors.bgHover,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.centerLeft,
        child: Text(text,
            style: TextStyle(
                color: TelegramColors.textMuted,
                fontSize: 14,
                fontWeight: FontWeight.w700)),
      );

  /// 输入框：TG 设置页那种"灰底无边框"胶囊（暗色 bgHover / 圆角 10）。
  InputDecoration _fieldDecoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: TelegramColors.textMuted, fontSize: 16),
        filled: true,
        fillColor: TelegramColors.bgHover,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: TelegramColors.accent, width: 1.5),
        ),
      );

  /// 右对齐的动作按钮（TG 设置页的"保存"就是这个位置/颜色）。
  Widget _actionRow(
      {required String key, required String label, VoidCallback? onTap}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          key: ValueKey(key),
          onPressed: onTap,
          child: Text(label,
              style: TextStyle(
                  color: onTap == null
                      ? TelegramColors.textMuted
                      : TelegramColors.accent,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}
