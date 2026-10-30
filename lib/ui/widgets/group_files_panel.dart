/// 群文件面板（哑视图）。
///
/// 只负责**呈现与交互回调**：列目录、下载、上传、删除都由调用方注入
/// （见 `Qq8LoginService.fetchGroupFiles / groupFileDownloadUrl /
/// uploadGroupFile / deleteGroupFile`）。面板本身不认识协议，也不读 provider，
/// 这样在 widget 测试里可以直接塞假数据。
library;

import 'package:flutter/material.dart';
import 'package:qqclient/kernel/wlogin8/qq8_gfs.dart';
import 'package:qqclient/ui/theme/telegram_theme.dart';
import 'package:qqclient/ui/widgets/telegram_list_item.dart';

class GroupFilesPanel extends StatefulWidget {
  const GroupFilesPanel({
    super.key,
    required this.title,
    required this.loader,
    this.onDownload,
    this.onUpload,
    this.onDelete,
    this.onCreateDir,
    this.onRename,
  });

  /// 群名（显示在标题栏）。
  final String title;

  /// 拉某个目录（`pid == Qq8Gfs.rootPid` 是根）下的条目。
  final Future<List<Qq8GfsEntry>> Function(String pid) loader;

  /// 下载一个文件，成功后返回落盘路径（面板只负责提示）。
  final Future<String> Function(Qq8GfsEntry file)? onDownload;

  /// 上传：由调用方弹自己的选择对话框，完成后面板会重列一次。
  final Future<void> Function()? onUpload;

  /// 删除一个文件或目录（删目录会连带删掉里面的文件，调用方可自行加确认）。
  final Future<void> Function(Qq8GfsEntry file)? onDelete;

  /// 新建文件夹（官方只允许建在根目录，所以只在根目录显示按钮）。
  final Future<void> Function(String name)? onCreateDir;

  /// 给文件或目录改名。
  final Future<void> Function(Qq8GfsEntry entry, String name)? onRename;

  static Future<void> show(
    BuildContext context, {
    required String title,
    required Future<List<Qq8GfsEntry>> Function(String pid) loader,
    Future<String> Function(Qq8GfsEntry file)? onDownload,
    Future<void> Function()? onUpload,
    Future<void> Function(Qq8GfsEntry file)? onDelete,
    Future<void> Function(String name)? onCreateDir,
    Future<void> Function(Qq8GfsEntry entry, String name)? onRename,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: TelegramColors.bgSidebar,
      isScrollControlled: true,
      builder: (_) => GroupFilesPanel(
        title: title,
        loader: loader,
        onDownload: onDownload,
        onUpload: onUpload,
        onDelete: onDelete,
        onCreateDir: onCreateDir,
        onRename: onRename,
      ),
    );
  }

  @override
  State<GroupFilesPanel> createState() => _GroupFilesPanelState();
}

class _GroupFilesPanelState extends State<GroupFilesPanel> {
  List<Qq8GfsEntry>? _entries;
  String? _error;
  bool _loading = true;
  String _pid = Qq8Gfs.rootPid;
  String? _busyFid;

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
      final list = await widget.loader(_pid);
      if (!mounted) return;
      setState(() {
        _entries = list;
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

  void _enter(Qq8GfsEntry dir) {
    setState(() {
      _pid = dir.fid;
      _entries = null;
      _error = null;
      _loading = true;
    });
    _load();
  }

  void _up() {
    setState(() {
      _pid = Qq8Gfs.rootPid;
      _entries = null;
      _error = null;
      _loading = true;
    });
    _load();
  }

  Future<void> _download(Qq8GfsEntry f) async {
    final cb = widget.onDownload;
    if (cb == null || _busyFid != null) return;
    setState(() => _busyFid = f.fid);
    try {
      final path = await cb(f);
      if (mounted) _toast('已保存到 $path');
    } on Object catch (e) {
      if (mounted) _toast('下载失败：$e');
    } finally {
      if (mounted) setState(() => _busyFid = null);
    }
  }

  Future<void> _upload() async {
    final cb = widget.onUpload;
    if (cb == null) return;
    try {
      await cb();
    } on Object catch (e) {
      if (mounted) _toast('上传失败：$e');
      return;
    }
    if (mounted) await _load();
  }

  Future<void> _delete(Qq8GfsEntry f) async {
    final cb = widget.onDelete;
    if (cb == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('gf-delete-dialog'),
        backgroundColor: TelegramColors.bgSidebar,
        title: Text('删除「${f.name}」？',
            style: TextStyle(color: TelegramColors.textPrimary)),
        content: Text('群里的其他成员也会看不到这个文件。',
            style: TextStyle(color: TelegramColors.textSecondary, fontSize: 13)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('gf-delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除', style: TextStyle(color: TelegramColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await cb(f);
    } on Object catch (e) {
      if (mounted) _toast('删除失败：$e');
      return;
    }
    if (mounted) {
      _toast('已删除');
      await _load();
    }
  }

  Future<void> _newDir() async {
    final cb = widget.onCreateDir;
    if (cb == null) return;
    final name = await _askName(
      dialogKey: 'gf-newdir-dialog',
      fieldKey: 'gf-newdir-name',
      okKey: 'gf-newdir-ok',
      title: '新建文件夹',
      hint: '文件夹名字',
      okText: '创建',
    );
    if (name == null || name.isEmpty) return;
    try {
      await cb(name);
    } on Object catch (e) {
      if (mounted) _toast('建文件夹失败：$e');
      return;
    }
    if (mounted) {
      _toast('已创建');
      await _load();
    }
  }

  Future<void> _rename(Qq8GfsEntry f) async {
    final cb = widget.onRename;
    if (cb == null) return;
    final name = await _askName(
      dialogKey: 'gf-rename-dialog',
      fieldKey: 'gf-rename-name',
      okKey: 'gf-rename-ok',
      title: '重命名「${f.name}」',
      hint: '新名字',
      okText: '保存',
      initial: f.name,
    );
    if (name == null || name.isEmpty || name == f.name) return;
    try {
      await cb(f, name);
    } on Object catch (e) {
      if (mounted) _toast('改名失败：$e');
      return;
    }
    if (mounted) {
      _toast('已改名');
      await _load();
    }
  }

  /// 一个名字输入框（新建/改名共用）。取消或留空都返回 null。
  Future<String?> _askName({
    required String dialogKey,
    required String fieldKey,
    required String okKey,
    required String title,
    required String hint,
    required String okText,
    String initial = '',
  }) async {
    // 用 TextFormField + onChanged 而不是 TextEditingController：
    // controller 在对话框退场动画播完前就 dispose 会抛
    // 「A TextEditingController was used after being disposed」。
    var text = initial;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: ValueKey(dialogKey),
        backgroundColor: TelegramColors.bgSidebar,
        title: Text(title, style: TextStyle(color: TelegramColors.textPrimary)),
        content: TextFormField(
          key: ValueKey(fieldKey),
          initialValue: initial,
          autofocus: true,
          onChanged: (v) => text = v,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: ValueKey(okKey),
            onPressed: () => Navigator.of(ctx).pop(text.trim()),
            child: Text(okText),
          ),
        ],
      ),
    );
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return FractionallySizedBox(
      heightFactor: 0.72,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
            child: Row(
              children: <Widget>[
                Expanded(child: _header(entries)),
                if (_pid != Qq8Gfs.rootPid)
                  IconButton(
                    key: const ValueKey('gf-up'),
                    onPressed: _loading ? null : _up,
                    icon: Icon(Icons.arrow_upward,
                        size: 20, color: TelegramColors.textSecondary),
                    tooltip: '上一级',
                  ),
                if (widget.onCreateDir != null && _pid == Qq8Gfs.rootPid)
                  IconButton(
                    key: const ValueKey('gf-newdir'),
                    onPressed: _loading ? null : _newDir,
                    icon: Icon(Icons.create_new_folder_outlined,
                        size: 20, color: TelegramColors.textSecondary),
                    tooltip: '新建文件夹',
                  ),
                if (widget.onUpload != null)
                  IconButton(
                    key: const ValueKey('gf-upload'),
                    onPressed: _loading ? null : _upload,
                    icon: Icon(Icons.upload_file_outlined,
                        size: 20, color: TelegramColors.textSecondary),
                    tooltip: '上传文件',
                  ),
                IconButton(
                  key: const ValueKey('gf-refresh'),
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
          Expanded(child: _body(entries)),
        ],
      ),
    );
  }

  Widget _header(List<Qq8GfsEntry>? entries) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(widget.title,
              key: const ValueKey('gf-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: TelegramColors.textPrimary,
                  fontSize: TelegramMetrics.fontTitle,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            entries == null ? '加载中…' : '${entries.length} 个文件',
            key: const ValueKey('gf-count'),
            style:
                TextStyle(color: TelegramColors.textSecondary, fontSize: 12.5),
          ),
        ],
      );

  Widget _body(List<Qq8GfsEntry>? entries) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              key: const ValueKey('gf-error'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: TelegramColors.textSecondary, fontSize: 13)),
        ),
      );
    }
    if (entries == null) {
      return const Center(
        child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (entries.isEmpty) {
      return Center(
        child: Text('这个目录还是空的',
            key: const ValueKey('gf-empty'),
            style: TextStyle(color: TelegramColors.textMuted, fontSize: 13)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: entries.length,
      itemBuilder: (_, i) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _row(entries[i]),
          // SharedDocumentCell 的 needDivider：从 72 画到右缘
          if (i != entries.length - 1)
            Container(
              height: 1,
              margin: const EdgeInsets.only(left: 72),
              color: TelegramColors.divider,
            ),
        ],
      ),
    );
  }

  Widget _row(Qq8GfsEntry f) {
    final subtitle = StringBuffer();
    if (f.isDir) {
      subtitle.write('文件夹 · ${f.fileCount} 项');
    } else {
      subtitle.write(f.sizeText);
      final date = _dateText(f.createTime);
      if (date.isNotEmpty) subtitle.write(' · $date');
    }
    if (f.uploaderUin > 0) subtitle.write(' · ${f.uploaderUin}');
    return TgFileRow(
      key: ValueKey('gf-entry-${f.fid}'),
      icon: f.isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
      highlight: f.isDir,
      title: f.name,
      subtitle: subtitle.toString(),
      onTap: f.isDir ? () => _enter(f) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (f.isDir && widget.onRename != null)
            IconButton(
              key: ValueKey('gf-rename-${f.fid}'),
              onPressed: () => _rename(f),
              icon: Icon(Icons.drive_file_rename_outline,
                  size: 20, color: TelegramColors.textSecondary),
              tooltip: '重命名',
            ),
          if (f.isDir && widget.onDelete != null)
            IconButton(
              key: ValueKey('gf-delete-${f.fid}'),
              onPressed: _busyFid == null ? () => _delete(f) : null,
              icon: Icon(Icons.delete_outline,
                  size: 20, color: TelegramColors.danger),
              tooltip: '删除文件夹',
            ),
          if (!f.isDir && widget.onRename != null)
            IconButton(
              key: ValueKey('gf-rename-${f.fid}'),
              onPressed: () => _rename(f),
              icon: Icon(Icons.drive_file_rename_outline,
                  size: 20, color: TelegramColors.textSecondary),
              tooltip: '重命名',
            ),
          if (!f.isDir && widget.onDownload != null)
            IconButton(
              key: ValueKey('gf-download-${f.fid}'),
              onPressed: _busyFid == null ? () => _download(f) : null,
              icon: _busyFid == f.fid
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(Icons.download_outlined,
                      size: 20, color: TelegramColors.textSecondary),
              tooltip: '下载',
            ),
          if (!f.isDir && widget.onDelete != null)
            IconButton(
              key: ValueKey('gf-delete-${f.fid}'),
              onPressed: _busyFid == null ? () => _delete(f) : null,
              icon: Icon(Icons.delete_outline,
                  size: 20, color: TelegramColors.danger),
              tooltip: '删除',
            ),
          if (f.isDir)
            Icon(Icons.chevron_right,
                color: TelegramColors.textMuted, size: 20),
        ],
      ),
    );
  }

  /// 秒级时间戳 → `2026-10-28`（拿不到就留空，不猜）。
  static String _dateText(int seconds) {
    if (seconds <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    final mm = t.month.toString().padLeft(2, '0');
    final dd = t.day.toString().padLeft(2, '0');
    return '${t.year}-$mm-$dd';
  }
}