/// L3 客户端 API 层：**后端发布协调器**（纯 Dart，无 Flutter）。
///
/// ## 它解决什么
///
/// 协议线上线后要异步建 `ChatStore`（`bootstrap()` 里含好友/群列表请求，
/// 耗时上百毫秒到数秒）。这期间会不断有新的登录快照进来（心跳、QueryHB、
/// 任何 `_emit` 都会发状态流），也可能发生：
///
/// * 用户切号 → 目标账号变了；
/// * 同号重连 → 服务新建了一个 `Qq8Session`，旧会话的结论作废；
/// * 控制器被 dispose → 一切结论都不许再发布。
///
/// 只用一个 `bool _attaching` 有两个必然的错：
///
/// 1. **新目标被旧请求挡住**：上一轮 bootstrap 还没回来，切号后新一轮根本
///    发不起来，用户看到"已上线"却永远没有数据。
/// 2. **旧结论被当成新结论发布**：await 回来时不再检查"这一轮还算不算数"，
///    旧号的会话列表就挂到了新号下面。
///
/// 所以把「想要什么 / 正在跑哪一轮 / 已发布了什么」收在一处，规则只有三条：
///
/// * **目标变化（账号或在线会话代）一律作废旧轮次**（世代 +1），并把已发布的
///   旧资源**交还调用方去释放**——不是只改一个字段就了事，否则旧 `ChatStore`
///   会继续挂在旧数据根上，还可能与新一代抢同一个索引文件；
/// * **同一代同一目标只允许一轮**（重复的在线快照不会重复建 store）；
/// * **关闭是永久的**：`close()` 之后不再产生任何计划，也不会把已发布的资源
///   留在表里。
///
/// ## 泛型 `R`
///
/// 协调器只管"谁拥有资源"，不关心资源是什么。真实接线里 `R` 是
/// `({Qq8SessionAdapter session, ChatStore store})`；自测里是一个记录
/// `dispose` 次数的假资源——**测试断言的是真实释放次数**，不是世代整数。
///
/// ## 离线语义（为什么要有 `epoch == null`）
///
/// 临时断线（心跳连续失败、`failed`）**不等于**换号：用户应该还能看到该账号
/// 的离线记录。所以「账号还在、只是不在线」时**保留已发布资源**，但取消任何
/// 在跑的轮次（它建出来的东西已经过时）。换号则相反：**哪怕新号还没在线**，
/// 也要立刻收回旧号的展示。
library;

/// 一次 attach 的目标：哪个账号、哪一代在线会话。
typedef AttachTarget = ({int uin, int epoch});

/// 一轮待执行的 attach。
class AttachPlan {
  const AttachPlan({
    required this.uin,
    required this.epoch,
    required this.gen,
  });

  final int uin;

  /// 发起时的在线会话代（见 `Qq8ConnectController._onlineEpoch`）。
  final int epoch;

  /// 发起时的世代号。发布/失败时必须拿它和 [AttachCoordinator.generation]
  /// 比：不等就说明期间已经切号、重连或关闭，这一轮只能释放、不能发布。
  final int gen;

  AttachTarget get target => (uin: uin, epoch: epoch);

  @override
  String toString() => 'AttachPlan(uin=$uin, epoch=$epoch, gen=$gen)';
}

/// 每账号清理屏障：保证**同账号的旧资源释放完成**先于**新资源开始写盘**。
///
/// ## 为什么需要
///
/// 切号/重连时旧 `ChatStore` 的 `dispose()` 会 flush `chats.json` 与
/// `media_index.json`（见 `chat_store.dart` 的 dispose）。如果新 `ChatStore`
/// 已经 `bootstrap()`（读同一个索引文件）而旧的那个还没写完，两者就会在
/// 同一个账号根上互相覆盖——这正是 P1 要杜绝的串写。
///
/// 所以 `dispose` 排进该账号的链尾，新建之前先 `await waitFor(uin)`。
/// 链本身吞掉异常（一次释放失败不该永久卡住该账号），调用方自行记录日志。
class AccountCleanupBarrier {
  final Map<int, Future<void>> _tails = <int, Future<void>>{};

  /// 该账号所有已排队的释放都完成后再返回（无排队则立即完成）。
  Future<void> waitFor(int uin) => _tails[uin] ?? Future<void>.value();

  /// 把一次释放排到该账号的链尾，返回**本次**释放的 Future（可能失败）。
  Future<void> run(int uin, Future<void> Function() cleanup) {
    final prev = _tails[uin] ?? Future<void>.value();
    final next = prev.then((_) => cleanup());
    // 链尾只记「已完成（无论成败）」，这样一次失败不会让后续永远等不到。
    _tails[uin] = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }
}


/// [AttachCoordinator.update] 的返回：可能要启动一轮，也可能要交还旧资源。
typedef AttachUpdate<R> = ({AttachPlan? plan, R? retired});

/// 目标 → 计划的同步状态机（规则见文件头）。
class AttachCoordinator<R extends Object> {
  int _generation = 0;
  int? _desiredUin;
  int? _desiredEpoch;
  int? _pendingGen;
  AttachTarget? _pendingTarget;
  R? _published;
  AttachTarget? _publishedTarget;
  bool _closed = false;

  /// 当前世代。只有等于某一轮 `plan.gen` 的那一轮才有发布资格。
  int get generation => _generation;

  /// 已发布资源对应的目标（null = 没有发布，或已关闭）。
  AttachTarget? get publishedTarget => _publishedTarget;

  /// 是否已有一轮在跑（且属于当前世代）。
  bool get hasPending => _pendingGen != null && _pendingGen == _generation;

  /// 已关闭？关闭后 [update] 永远返回空，也不会再持有已发布资源。
  bool get isClosed => _closed;

  /// 喂一个"当前想要的状态"，同步得出「要释放谁 / 要启动什么」。
  ///
  /// 参数表达的是**意图**，不是快照原文：
  /// * `uin == null` —— 什么都不想要（idle / 退出登录）；
  /// * `uin != null && epoch == null` —— 这个账号还"在"，但当前不在线
  ///   （断线 / 登录失败）；保留同账号的已发布资源；
  /// * `uin != null && epoch != null` —— 这个账号的这一代会话在线。
  AttachUpdate<R> update({required int? uin, required int? epoch}) {
    if (_closed) return (plan: null, retired: null);

    // ---- 1. 完全不想要：收回一切 ----
    if (uin == null) {
      final retired = _published;
      final hadAnything =
          _published != null || _pendingGen != null || _desiredUin != null;
      _desiredUin = null;
      _desiredEpoch = null;
      _pendingGen = null;
      _pendingTarget = null;
      _published = null;
      _publishedTarget = null;
      if (hadAnything) _generation++;
      return (plan: null, retired: retired);
    }

    R? retired;
    var targetChanged = false;

    // ---- 2. 换号：哪怕新号还没在线，也立刻收回旧号的展示 ----
    if (_publishedTarget != null && _publishedTarget!.uin != uin) {
      retired = _published;
      _published = null;
      _publishedTarget = null;
      targetChanged = true;
    }

    // ---- 3. 取消在跑的轮次（目标不同 / 不在线 / 同号新会话代）----
    final pendingStale = _pendingTarget != null &&
        (_pendingTarget!.uin != uin ||
            epoch == null ||
            _pendingTarget!.epoch != epoch);
    if (pendingStale) {
      _pendingGen = null;
      _pendingTarget = null;
      targetChanged = true;
    }

    // ---- 4. 记录意图 ----
    if (_desiredUin != uin || _desiredEpoch != epoch) {
      _desiredUin = uin;
      _desiredEpoch = epoch;
      if (epoch != null) targetChanged = true;
    }

    // ---- 5. 不在线：保留同号已发布资源，不做新计划 ----
    if (epoch == null) {
      if (targetChanged) _generation++;
      return (plan: null, retired: retired);
    }

    final target = (uin: uin, epoch: epoch);

    // ---- 6. 已发布的就是它：去重（重复的在线快照到此为止）----
    if (_publishedTarget == target) {
      if (retired != null || targetChanged) _generation++;
      return (plan: null, retired: retired);
    }

    // ---- 7. 同号新会话代：旧 store 也要收回（两个 ChatStore 不能共用一个根）----
    if (_publishedTarget != null) {
      retired = _published;
      _published = null;
      _publishedTarget = null;
      targetChanged = true;
    }

    if (targetChanged) _generation++;
    if (_pendingGen == _generation) return (plan: null, retired: retired);

    _pendingGen = _generation;
    _pendingTarget = target;
    return (
      plan: AttachPlan(uin: uin, epoch: epoch, gen: _generation),
      retired: retired,
    );
  }

  /// 这一轮还算数吗（世代未变且未关闭）。
  bool isCurrent(int gen) => !_closed && gen == _generation;

  /// 发布成功。返回 true = 这一轮仍然有效、资源已被登记；
  /// false = 过时，调用方必须自己释放资源（协调器不接管）。
  bool complete(AttachPlan plan, R resource) {
    if (!isCurrent(plan.gen)) return false;
    if (_published != null) return false; // 已经有别的在用了
    _published = resource;
    _publishedTarget = plan.target;
    if (_pendingGen == plan.gen) {
      _pendingGen = null;
      _pendingTarget = null;
    }
    return true;
  }

  /// 这一轮结束但没发布（失败 / 取消）。只清**自己那一代**的标记。
  void fail(AttachPlan plan) {
    if (_pendingGen == plan.gen) {
      _pendingGen = null;
      _pendingTarget = null;
    }
  }

  /// 永久关闭：交还已发布资源，之后 [update] 一律返回空。
  R? close() {
    final retired = _published;
    _closed = true;
    _generation++;
    _desiredUin = null;
    _desiredEpoch = null;
    _pendingGen = null;
    _pendingTarget = null;
    _published = null;
    _publishedTarget = null;
    return retired;
  }
}
