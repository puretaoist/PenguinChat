/// 「无真签禁止口令登录」闸门。
///
/// 背景（见 docs/RESEARCH-code45.md）：
/// 服务端把「没有有效设备签名（0x544 / 0x553 官方 native 签名）的口令登录」
/// 当成 BOT 嫌疑。同一账号被这样登过若干次之后，会被打上 code 45
/// （界面文案是「你当前使用的QQ版本过低」），此后**任何客户端**都可能被拦，
/// 甚至被要求用最新官方客户端做人工复核。2026-10-29 小号
/// 3499239040 就是这样被升级处置的。
///
/// 因此产品侧默认**不允许**在没有真签能力时发口令链；
/// 只有明确知道后果的调试场景才把它置 true（如 tool 里的 --allow-unattested）。
///
/// 注意：票据续期（A2/D2/key）不走口令链，不受本闸门限制。
class Qq8LoginPolicy {
  Qq8LoginPolicy._();

  /// 是否允许在「没有官方 native 真签」的情况下发起口令登录。默认 false。
  ///
  /// 只应由调试工具在显式开关下置 true；App 内不要改。
  static bool allowUnattestedPasswordLogin = false;

  /// 当前口令链是否**真的带了签**（由登录服务在组包前如实上报）。
  ///
  /// 2026-10-29 实测：纯 Dart 的 oicq 布局真签（`Qq8T544Mode.oicq`，39 字节）
  /// 首包直接过闸 → `type=2`（正常要滑块）；同一账号把 0x544 换成官方降级体
  /// （4 个零字节）→ `type=45`。所以「有签」不再等于「必须有 native」，
  /// 闸门按这个事实放行，而退回降级体时仍然拦。
  static bool deviceSignatureAvailable = false;

  /// 口令链是否被本闸门拦下。
  static bool get passwordLoginBlocked =>
      !(allowUnattestedPasswordLogin || deviceSignatureAvailable);

  /// 被拦时给用户的文案（不要含账号/口令等敏感信息）。
  static const String blockedMessage =
      '已阻止「无设备签名」的口令登录：连续这样登录会让账号被判定为 BOT 并触发'
      '「版本过低」(code 45) 风控，之后连官方客户端也可能被要求人工复核。'
      '请改用票据续期登录，或使用官方客户端登录。';

  /// 仅供自测：恢复到默认值。
  static void resetForTest() {
    allowUnattestedPasswordLogin = false;
    deviceSignatureAvailable = false;
  }
}
