/// L4 组件：群成员面板（点群聊标题打开）
///
/// 对齐 TG"群资料页"里最实用的一半：成员列表——头像、显示名（群名片优先）、
/// 身份（群主/管理员）与专属头衔。
///
/// 设计成"哑视图 + 注入加载器"：
/// * 加载器由调用方给（[loader]）——协议线用 `Qq8LoginService.fetchGroupMembers`，
///   别的后端还没这个能力（抛错，界面显示原文，不假装成功）；
/// * **群主判定拿 [ownerUin] 比**：成员条目本身没有群主标志位。
///
/// L4 直接用 L2 的 `Qq8GroupMember`：L3 的 `Session` 契约还没有成员 API，
/// 为 UI 再造一层一模一样的模型是重复劳动（依赖方向 L4 → L3 → L2 是允许的）。
library;

import 'package:flutter/material.dart';

import '../../kernel/wlogin8/qq8_list.dart';
import '../theme/telegram_theme.dart';
import 'telegram_avatar.dart';

class GroupMembersPanel extends StatefulWidget {
  /// 群名（标题栏）。
  final String title;

  /// 群主 uin（用来标"群主"；0/未知时只标管理员）。
  final int ownerUin;

  /// 拉成员（协议线传 `service.fetchGroupMembers` 包一层）。
  final Future<List<Qq8GroupMember>> Function() loader;

  const GroupMembersPanel({
    super.key,
    required this.title,
    required this.loader,
    this.ownerUin = 0,
  });

  /// 弹出面板（加载中就有 loading 态）。
  static Future<void> show(
    BuildContext context, {
    required String title,
    required Future<List<Qq8GroupMember>> Function() loader,
    int ownerUin = 0,
  }) =>
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: TelegramColors.bgSidebar,
        isScrollControlled: true,
        builder: (_) => GroupMembersPanel(
          title: title,
          loader: loader,
          ownerUin: ownerUin,
        ),
      );

  @override
  State<GroupMembersPanel> createState() => _GroupMembersPanelState();
}

class _GroupMembersPanelState extends State<GroupMembersPanel> {
  List<Qq8GroupMember>? _members;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.loader();
      if (!mounted) return;
      setState(() {
        _members = list;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final members = _members;
    return FractionallySizedBox(
      heightFactor: 0.72,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
            child: Row(
              children: <Widget>[
                Expanded(child: _header(members)),
                IconButton(
                  key: const ValueKey('members-refresh'),
                  onPressed: _loading ? null : _load,
                  icon: Icon(Icons.refresh,
                      size: 20, color: TelegramColors.textSecondary),
                  tooltip: '刷新',
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
          Expanded(child: _body(members)),
        ],
      ),
    );
  }

  Widget _header(List<Qq8GroupMember>? members) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(widget.title,
              key: const ValueKey('members-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: TelegramColors.textPrimary,
                  fontSize: TelegramMetrics.fontTitle,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            members == null ? '加载中…' : '${members.length} 位成员',
            key: const ValueKey('members-count'),
            style: TextStyle(
                color: TelegramColors.textSecondary, fontSize: 12.5),
          ),
        ],
      );

  Widget _body(List<Qq8GroupMember>? members) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              key: const ValueKey('members-error'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: TelegramColors.textSecondary, fontSize: 13)),
        ),
      );
    }
    if (members == null) {
      return const Center(
        child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (members.isEmpty) {
      return Center(
        child: Text('没有成员数据',
            style: TextStyle(color: TelegramColors.textMuted, fontSize: 13)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: members.length,
      itemBuilder: (_, i) => _row(members[i]),
    );
  }

  Widget _row(Qq8GroupMember m) {
    final isOwner = widget.ownerUin != 0 && m.uin == widget.ownerUin;
    final subtitle = StringBuffer('${m.uin} · ${m.genderLabel}');
    if (m.title.isNotEmpty) subtitle.write(' · ${m.title}');
    return ListTile(
      key: ValueKey('member-${m.uin}'),
      leading: TelegramAvatar(name: m.displayName, size: 40),
      title: Text(m.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              TextStyle(color: TelegramColors.textPrimary, fontSize: 14)),
      subtitle: Text(subtitle.toString(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              TextStyle(color: TelegramColors.textMuted, fontSize: 12)),
      trailing: isOwner
          ? _chip('群主', TelegramColors.accent)
          : m.admin
              ? _chip('管理员', TelegramColors.textSecondary)
              : null,
    );
  }

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label, style: TextStyle(color: color, fontSize: 11)),
      );
}
