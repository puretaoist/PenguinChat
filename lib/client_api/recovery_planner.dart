/// L3 客户端 API 层：**免密恢复编排**——决定"下一次该用哪份材料去续期"。
///
/// ## 为什么是"决策"而不是"重试算法"
///
/// 官方的续期入口是 `WtloginHelper.java:607-755` 里的三条**并列分支**：
///
/// | 手上有什么 | 官方动作 | 该分支的 tgtgt |
/// |---|---|---|
/// | A2 + D2 + KEY | 子命令 11（普通续期） | `MD5(d2key)` |
/// | A2 + A2KEY | 子命令 11 | 显式 A2KEY（不派生） |
/// | A1 + noPicSig | 子命令 15（`request.z(u=15)`） | A1 换票 |
/// | 只有 A2 | 兜底 | 无 key |
///
/// 这不是一条"先做 A、失败再做 B"的强制顺序算法——官方是按手上材料**选**一条。
/// 所以本文件只做**纯选择**：给定"可用材料集合"与"已经试过的集合"，返回
/// 下一步该用哪个（或者该停下来）。
///
/// ## 纪律
///
/// - 纯函数：无 IO、无时间、无 Flutter、不 import kernel（只依赖 token_store 的数据类）；
/// - **永不返回"用密码"**：密码不是免密材料，恢复路径里静默退回密码是最坏的
///   产品行为（用户没点、也没授权，却把口令哈希又交出去一次）；
/// - `networkError` / `challengeActive` **不在这里重试**：前者是链路问题（上层重连），
///   后者是人的问题（验证码只能人来解）。
///
/// live 状态：**unavailable**——本文件只产出决策，不做任何网络动作。
library;

import 'dart:typed_data';

import 'qq8_token_store.dart';

/// 一份免密续期材料（对应官方的三条分支 + A2-only 兜底）。
enum Qq8RecoveryMaterial {
  /// A2 + D2 + KEY：tgtgt = MD5(d2key)。当前唯一已接线的分支。
  d2Key,

  /// A2 + A2KEY：tgtgt 用显式 key，不做 MD5 派生。
  a2Key,

  /// A1 + noPicSig：子命令 15，用长期凭据换一张新票。
  a1NoPicSig,

  /// 只有 A2：不派生 tgtgt 的兜底尝试。
  a2Only,
}

/// "手上到底有什么"——从票据里读出来的**纯快照**（不判有效期，那是
/// `Qq8TokenData.evaluateValidity` 的事，调用方自己先过闸门）。
class Qq8RecoveryAvailability {
  /// A2 非空。**A2 是 `_TGT`（0x119 里的 `0x10a`，即票据里的 `tgt`），
  /// 不是 `d2`**——`d2`（`0x143`）是另一份材料，见 [hasD2]。
  ///
  /// 依据 `WtloginHelper.java:607-690`：4 元组形态要 A2+D2+KEY 三样齐，
  /// 3 元组形态要 A2+A2KEY 两样齐；两种形态的第一个参数都是 A2（TGT）。
  /// 2026-11 修正：此前本字段读的是 `t.d2`，把 A2 与 D2 混成一物，
  /// 会让「只有 d2 没有 tgt」的票被误判成可以发 3 元组形态。
  final bool hasA2;

  /// D2（`d2`，`0x143`）非空。只有 4 元组形态（A2+D2+KEY，子命令 11 带
  /// `0x143`）需要它；3 元组形态（A2+A2KEY）不带 `0x143`，因此不要求它。
  final bool hasD2;

  /// D2KEY 非空。
  final bool hasD2Key;

  /// A2KEY（`a2_key`）非空。
  final bool hasA2Key;

  /// A1（0x106）非空。
  final bool hasA1;

  /// noPicSig 非空。
  final bool hasNoPicSig;

  const Qq8RecoveryAvailability({
    this.hasA2 = false,
    this.hasD2 = false,
    this.hasD2Key = false,
    this.hasA2Key = false,
    this.hasA1 = false,
    this.hasNoPicSig = false,
  });

  /// 从票据推出可用材料。**null 票据 → 全 false**（不抛）。
  factory Qq8RecoveryAvailability.fromToken(Qq8TokenData? t) {
    if (t == null) return const Qq8RecoveryAvailability();
    return Qq8RecoveryAvailability(
      // A2 = _TGT = 0x10a（`t.tgt`）；D2 = 0x143（`t.d2`）。两者是不同材料。
      hasA2: _nonEmpty(t.tgt),
      hasD2: _nonEmpty(t.d2),
      hasD2Key: _nonEmpty(t.d2key),
      hasA2Key: _nonEmpty(t.a2Key),
      hasA1: _nonEmpty(t.a1),
      hasNoPicSig: _nonEmpty(t.noPicSig),
    );
  }

  static bool _nonEmpty(Uint8List? b) => b != null && b.isNotEmpty;

  /// 该材料是否"手上真有"。
  bool has(Qq8RecoveryMaterial m) => switch (m) {
        // 4 元组：A2+D2+KEY 三样齐（WtloginHelper.java:607-690），body 带 0x143。
        Qq8RecoveryMaterial.d2Key => hasA2 && hasD2 && hasD2Key,
        // 3 元组：A2+A2KEY 两样齐，body 不带 0x143（故不要求 hasD2）。
        Qq8RecoveryMaterial.a2Key => hasA2 && hasA2Key,
        Qq8RecoveryMaterial.a1NoPicSig => hasA1 && hasNoPicSig,
        Qq8RecoveryMaterial.a2Only => hasA2,
      };

  @override
  String toString() => 'Qq8RecoveryAvailability(a2=$hasA2, d2=$hasD2, '
      'd2key=$hasD2Key, a2key=$hasA2Key, a1=$hasA1, noPicSig=$hasNoPicSig)';
}

/// 规划结果：要么"再试一次（用某材料）"，要么"停"。
sealed class Qq8RecoveryDecision {
  const Qq8RecoveryDecision();
}

/// 下一步用 [material] 去续期。
class Qq8RecoveryAttempt extends Qq8RecoveryDecision {
  final Qq8RecoveryMaterial material;

  /// 第几次尝试（1-based）。
  final int attempt;

  /// 为什么选它（写日志/单测断言用）。
  final String why;

  const Qq8RecoveryAttempt({
    required this.material,
    required this.attempt,
    required this.why,
  });

  @override
  String toString() => 'Qq8RecoveryAttempt(#$attempt $material: $why)';
}

/// 停下，不再发包。
class Qq8RecoveryStop extends Qq8RecoveryDecision {
  /// `network` / `challenge` / `exhausted`。
  final String code;
  final String message;

  const Qq8RecoveryStop({required this.code, required this.message});

  @override
  String toString() => 'Qq8RecoveryStop($code: $message)';
}

/// 材料的**固定优先级**。单测直接断言这个列表，别在别处隐含顺序。
///
/// 顺序的理由：能派生出 tgtgt 的（d2Key）最稳；显式 key 次之；A1 换票会
/// 改写服务端侧的 A1 version，风险更高所以更靠后；A2-only 是没有 key 的
/// 最后手段。
const List<Qq8RecoveryMaterial> qq8RecoveryOrderedMaterials =
    <Qq8RecoveryMaterial>[
  Qq8RecoveryMaterial.d2Key,
  Qq8RecoveryMaterial.a2Key,
  Qq8RecoveryMaterial.a1NoPicSig,
  Qq8RecoveryMaterial.a2Only,
];

/// 固定顺序（同 [qq8RecoveryOrderedMaterials]，供实例/测试使用）。
List<Qq8RecoveryMaterial> get orderedMaterials =>
    qq8RecoveryOrderedMaterials;

/// 规划下一步。**纯函数**：同样的入参永远同样的出参。
///
/// 规则（顺序即优先级，必须能被单测穷举）：
/// 1. [networkError] → `Stop('network')`：链路问题，交给上层重连，这里不重试；
/// 2. [challengeActive] → `Stop('challenge')`：验证码只能人来解，绝不自动重试；
/// 3. 按 [qq8RecoveryOrderedMaterials] 取第一个「可用且不在 [tried]」的；
/// 4. 都不行 → `Stop('exhausted')`，提示重新登录一次。
///
/// **永远不会**返回"用密码"分支——密码不是免密材料。
Qq8RecoveryDecision planNext({
  required Qq8RecoveryAvailability a,
  required Set<Qq8RecoveryMaterial> tried,
  required bool networkError,
  required bool challengeActive,
}) {
  if (networkError) {
    return const Qq8RecoveryStop(
      code: 'network',
      message: '网络问题，等链路恢复后再续期（不在恢复编排里重试）',
    );
  }
  if (challengeActive) {
    return const Qq8RecoveryStop(
      code: 'challenge',
      message: '需要人工完成验证（滑块/短信/设备锁），不做自动重试',
    );
  }
  for (final m in qq8RecoveryOrderedMaterials) {
    if (tried.contains(m)) continue;
    if (!a.has(m)) continue;
    return Qq8RecoveryAttempt(
      material: m,
      attempt: tried.length + 1,
      why: _whyFor(m, a, tried.length),
    );
  }
  return const Qq8RecoveryStop(
    code: 'exhausted',
    message: '登录凭证不足，请重新登录一次',
  );
}

String _whyFor(
  Qq8RecoveryMaterial m,
  Qq8RecoveryAvailability a,
  int alreadyTried,
) {
  final head = alreadyTried == 0 ? '首次尝试' : '已试过 $alreadyTried 份材料';
  final body = switch (m) {
    Qq8RecoveryMaterial.d2Key => '有 A2+D2KEY，可派生 tgtgt=MD5(d2key)（官方普通续期分支）',
    Qq8RecoveryMaterial.a2Key => '有 A2+A2KEY，用显式 key 不派生（官方 A2KEY 分支）',
    Qq8RecoveryMaterial.a1NoPicSig =>
      '有 A1+noPicSig，走子命令 15 用长期凭据换票（官方 request.z(u=15) 分支）',
    Qq8RecoveryMaterial.a2Only => '只有 A2，无 key 兜底（官方 A2-only 分支）',
  };
  return '$head：$body';
}
