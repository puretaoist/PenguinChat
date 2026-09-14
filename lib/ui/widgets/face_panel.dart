/// QQ 表情选择面板（输入框旁的表情按钮打开）
///
/// ## 为什么是一格一格的中文名，而不是表情图
///
/// 官方客户端的表情是**随包资源**（drawable / 表情包 APK），不在网络上；参考实现
/// `oicq-src` 里也只有 id↔名字的表，没有任何表情图 URL。所以这一版老老实实显示
/// 名字，点一下把 `/名字` 插进输入框——发送时由协议层（`Qq8FaceNames` +
/// `faceElem`）翻成真正的表情元素。
///
/// 要真出图，正确做法是从官方包里取资源自建表情包（就像 Nagram 用 TG 的
/// emoji pack 那样），那是另一件事，别在代码里硬编一个来路不明的 CDN。
library;

import 'package:flutter/material.dart';

import '../../kernel/wlogin8/qq8_elem.dart';
import '../theme/telegram_theme.dart';

/// 弹出表情面板。选中一个就把它的 `/名字` 交给 [onPick]。
Future<void> showFacePicker(
  BuildContext context, {
  required void Function(String token) onPick,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: TelegramColors.bgSidebar,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
    ),
    builder: (ctx) => _FacePanel(onPick: onPick),
  );
}

class _FacePanel extends StatelessWidget {
  final void Function(String token) onPick;

  const _FacePanel({required this.onPick});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Row(
              children: [
                Text(
                  'QQ 表情',
                  style: TextStyle(
                    color: TelegramColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '点一下插入 /名字，发送时变成表情',
                  style: TextStyle(
                    color: TelegramColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: GridView.count(
              key: const ValueKey('face-grid'),
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              crossAxisCount: 6,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              childAspectRatio: 1.25,
              shrinkWrap: true,
              children: [
                for (final id in Qq8FaceNames.common)
                  _FaceTile(
                    // 面板里摆的都是小表情（id ≤ 0xFF），名字表查不到就跳过
                    name: Qq8FaceNames.nameOf('$id') ?? '',
                    onTap: () {
                      final name = Qq8FaceNames.nameOf('$id');
                      if (name == null) return;
                      onPick('/$name');
                      Navigator.of(context).pop();
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FaceTile extends StatelessWidget {
  final String name;
  final VoidCallback onTap;

  const _FaceTile({required this.name, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey('face-$name'),
      borderRadius: BorderRadius.circular(8),
      onTap: name.isEmpty ? null : onTap,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: TelegramColors.bgHover,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: TelegramColors.textPrimary,
            fontSize: 12.5,
          ),
        ),
      ),
    );
  }
}
