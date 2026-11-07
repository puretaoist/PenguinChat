import 'dart:async';

/// 页面负责选择会话，协调器只负责“哪个数据源的哪一次加载”。
/// 请求中与已完成分开保存，返回原 Future 而不是把“已触发”当成“已完成”。
class ChatLoadCoordinator {
  Object? _owner;
  int _revision = 0;
  bool _disposed = false;
  final Map<String, Future<void>> _pending = {};
  final Set<String> _completed = {};

  bool bind(Object? owner) {
    if (identical(owner, _owner)) return false;
    _owner = owner;
    _revision++;
    _pending.clear();
    _completed.clear();
    return true;
  }

  bool contains(String key) =>
      _pending.containsKey(key) || _completed.contains(key);

  void retry(String key) => _completed.remove(key);

  Future<void> run(String key, Future<void> Function() load) {
    if (_disposed) return Future.value();
    final running = _pending[key];
    if (running != null) return running;
    if (_completed.contains(key)) return Future.value();
    final revision = _revision;
    final completer = Completer<void>();
    _pending[key] = completer.future;
    Future.sync(load).then(
      (_) {
        if (!_disposed && revision == _revision) {
          _pending.remove(key);
          _completed.add(key);
        }
        completer.complete();
      },
      onError: (Object error, StackTrace stack) {
        if (!_disposed && revision == _revision) _pending.remove(key);
        completer.completeError(error, stack);
      },
    );
    return completer.future;
  }

  /// 解绑/销毁只让完成回调失效，不能假称取消了数据层的网络请求。
  int get revision => _revision;
  bool isCurrent(int revision) => !_disposed && revision == _revision;
  void dispose() {
    _disposed = true;
    _revision++;
    _pending.clear();
    _completed.clear();
  }
}
