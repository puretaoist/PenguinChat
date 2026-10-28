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

class GroupFilesPanel extends StatefulWidget {
  const GroupFilesPanel({
    super.key,
    required this.title,
    required this.loader,
    this.onDownload,
    this.onUpload,
    this.onDelete,
  });

  /// 群名（显示在标题栏）。
  final String title;

  /// 拉某个目录（`pid == Qq8Gfs.rootPid` 是根）下的条目。
  final Future<List<Qq8GfsEntry>> Function(String pid) loader;

  /// 下载一个文件，成功后返回落盘路径（面板只负责提示）。
  final Future<String> Function(Qq8GfsEntry file)? onDownload;

  /// 上传：由调用方弹自己的选择对话框，完成后面板会重列一次。
  final Future<void> Function()? onUpload;

  /// 删除一个文件（目录不给删，交给调用方拒）。
  final Future<void> Function(Qq8GfsEntry file)? onDelete;

  static Future<void> show(
    BuildContext context, {
    required String title,
    required Future<List<Qq8GfsEntry>> Function(String pid) loader,
    Future<String> Function(Qq8GfsEntry file)? onDownload,
    Future<void> Function()? onUpload,
    Future<void> Function(Qq8GfsEntry file)? onDelete,
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
      itemBuilder: (_, i) => _row(entries[i]),
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
    return ListTile(
      key: ValueKey('gf-entry-${f.fid}'),
      leading: Icon(
        f.isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
        color: f.isDir ? TelegramColors.accent : TelegramColors.textSecondary,
        size: 26,
      ),
      title: Text(f.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: TelegramColors.textPrimary, fontSize: 14)),
      subtitle: Text(subtitle.toString(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: TelegramColors.textMuted, fontSize: 12)),
      onTap: f.isDir ? () => _enter(f) : null,
      trailing: f.isDir
          ? Icon(Icons.chevron_right, color: TelegramColors.textMuted, size: 20)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (widget.onDownload != null)
                  IconButton(
                    key: ValueKey('gf-download-${f.fid}'),
                    onPressed: _busyFid == null ? () => _download(f) : null,
                    icon: _busyFid == f.fid
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.download_outlined,
                            size: 20,
                            color: TelegramColors.textSecondary),
                    tooltip: '下载',
                  ),
                if (widget.onDelete != null)
                  IconButton(
                    key: ValueKey('gf-delete-${f.fid}'),
                    onPressed: _busyFid == null ? () => _delete(f) : null,
                    icon: Icon(Icons.delete_outline,
                        size: 20, color: TelegramColors.danger),
                    tooltip: '删除',
                  ),
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
