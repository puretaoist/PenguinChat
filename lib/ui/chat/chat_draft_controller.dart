import 'dart:async';

import 'package:flutter/widgets.dart';

typedef DraftWriter = Future<void> Function(String chatId, String text);

/// 输入状态属于视图，持久化委托数据层（参考 TG ChatActivity.saveDraft）。
/// owner 与 chatId 一起标识归属，不能把旧输入写入新账号的 store。
class ChatDraftController {
  ChatDraftController({this.debounce = const Duration(milliseconds: 600)}) {
    input.addListener(_changed);
  }
  final TextEditingController input = TextEditingController();
  final Duration debounce;
  Object? _owner;
  String? _chatId;
  DraftWriter? _write;
  Timer? _timer;
  int _generation = 0;
  bool _applying = false;
  bool _pending = false;
  bool _dirty = false;
  bool _disposed = false;

  void bind({
    required Object? owner,
    required String? chatId,
    required String text,
    required DraftWriter? write,
  }) {
    if (identical(owner, _owner) && chatId == _chatId) return;
    flush();
    _owner = owner;
    _chatId = chatId;
    _write = write;
    _dirty = false;
    _pending = true;
    final generation = ++_generation;
    // build 中不修改 TextEditingController；旧帧回调不得覆盖新会话输入。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || generation != _generation) return;
      _applying = true;
      input.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      _applying = false;
      _pending = false;
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _changed() {
    if (_applying || _pending || _disposed) return;
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(debounce, flush);
  }

  void flush() {
    _timer?.cancel();
    _timer = null;
    final write = _write;
    final id = _chatId;
    if (!_dirty || _pending || write == null || id == null) return;
    _dirty = false;
    unawaited(write(id, input.text));
  }

  void dispose() {
    if (_disposed) return;
    flush();
    _disposed = true;
    _generation++;
    input.removeListener(_changed);
    input.dispose();
  }
}
