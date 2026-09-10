# M2 报告：登录协议逆向与内核修正

> 目标 APK：`com.tencent.mobileqq` 9.3.60（versionCode 16070）
> 分析范围：`oicq.wlogin_sdk`（368 个类）+ `EcdhService` 登录命令族
>
> **本轮的实质产出不是「新增了什么」，而是「修正了之前错的两处」。**
> M1 的字节序与加密模式都建立在未经验证的假设上，M2 用反编译证据推翻了它们。

---

## 一、得出结论的方法（先解决「反编译跑不动」）

### 问题

APK 有 41 个 dex、约 400MB 字节码。直接对 APK 跑 jadx：

- 默认配置 → **OOM**（`Native memory allocation (mmap) failed to map 931135488 bytes`）
- 限制堆内存后 → 单个 dex 有 2677 个类，按实测速率要 **约 3.7 小时**
  （进度 117/2677 时已耗时约 10 分钟）

### 解法：先定位类，再单类反编译

`--single-class` 只需 **26 秒**。所以关键变成「怎么快速知道目标类在哪个 dex」。

写了 `dex_class_finder.py`：

- 解析 dex 的 `class_defs` 表，而不是搜字符串
- 必要性：同一个类描述符会出现在多个 dex 的**字符串常量池**里（跨 dex 引用），
  grep 命中 ≠ 定义在此。只有 `class_defs` 里出现才是定义位置
- 实测：`WtloginHelper` 的字符串在 8 个 dex 里都有，但**定义**只在 `classes2.dex`

配套 `decompile.sh` 批量单类反编译。**3.7 小时 → 26 秒/类。**

---

## 二、修正一：字节序是**大端**，不是小端

### 证据

`oicq.wlogin_sdk.tools.util`：

```java
public static int buf_to_int16(byte[] b, int i) {
    return ((b[i] << 8) & 65280) + ((b[i + 1] << 0) & 255);   // 首字节是高位
}
public static void int16_to_buf(byte[] b, int i, int v) {
    b[i + 1] = (byte) (v >> 0);
    b[i + 0] = (byte) (v >> 8);                                // 高字节写到低位偏移
}
```

`int32_to_buf` / `int64_to_buf` 同样高字节在前，且 util 里**没有**小端变体。

### 影响

| | 修正前（错） | 修正后（对） |
|---|---|---|
| TLV 0x0104（body 4 字节）编码 | `04 01 04 00 …` | `01 04 00 04 …` |
| TEA 密钥字解析 | 小端 | 大端 |
| TEA 分组输入/输出 | 小端 | 大端 |

**这是会直接导致协议对接失败的 bug**，而且不会报错——只会收到服务端拒绝或解析出垃圾。

### 处理

`coder.dart` 改为**默认大端**，同时显式提供 `u16le` / `u32le` / `readUint16Le` 等小端方法。
理由：QQ 协议各层字节序可能不一致（WLogin 已证实大端，native MSF 层未知），
不应依赖「默认值恰好对」——**每一层按各自证据显式选择**。

同时修正了 `tlv.dart` 与两个测试文件里的错误断言。

---

## 三、修正二：加密不是裸 ECB TEA，是「填充 + CBC」

### 证据

`oicq.wlogin_sdk.tools.a`（`cryptor` 调用的轮函数）：

```java
// 加密
j2 = (j2 + 2654435769L) & 0xFFFFFFFF;                    // delta = 0x9E3779B9
jB  = (jB + ((((jB2<<4)+k0) ^ (jB2+j2)) ^ ((jB2>>>5)+k1))) & 0xFFFFFFFF;
jB2 = (jB2 + ((((jB<<4)+k2) ^ (jB+j2) ^ ((jB>>>5)+k3))) & 0xFFFFFFFF;

// 解密：sum 初值 3816266640 == 0xE3779B90
j2 = (j2 - 2654435769L) & 0xFFFFFFFF;
```

`oicq.wlogin_sdk.tools.cryptor.decrypt` 的解密路径：

```java
int i3 = bArrA[0] & 7;                    // pad = 首字节低 3 位
int i4 = (i2 - i3) - 10;                  // 正文长度 = 总长 - pad - 10
...
aVar.c[i8] = (byte)(bArr5[(aVar.e+0)+i9] ^ aVar.b[i9]);   // P_i = D(C_i) XOR C_{i-1}
```

即 **标准 CBC（零 IV）**。

### 完整的 QQ TEA 规约

```
填充：pad = (8 - (len + 10) % 8) % 8
输出长度 = pad + len + 10

加密前列布局：
  [ (rand & 0xF8) | pad ]     1 字节   低 3 位存填充长度
  [ 随机 ]                    pad 字节
  [ 随机 ]                    2 字节
  [ 正文 ]                    len 字节
  [ 0x00 × 7 ]                7 字节   完整性校验位

然后按 8 字节分组做 CBC 加密（TEA 轮函数，大端字）
```

### 影响

M1 的实现（裸 ECB）**无法对接真实协议**。已新增：

- `teaEncryptBlock` / `teaDecryptBlock` — 裸分组原语（单测可直测轮函数）
- `qqTeaEncrypt` / `qqTeaDecrypt` — 真实模式（填充 + CBC）
- `qqTeaPadLength` — 填充公式

支持注入填充字节以便测试断言；生产路径用 `Random.secure()`
（QQ 本身用 `java.util.Random`，属线性同余、可预测；填充字节不参与协议语义，
换安全源严格更优）。

### 诚实边界

- 轮函数与解密路径的**反编译产物是清晰可信的**
- 但 `a()` 这个「加密单块」方法的 jadx 输出**控制流被重排**（出现不可达分支），
  因此加密路径的结论来自：轮函数（可信）+ 解密路径（可信）+ CBC 标准结构 三者推导
- **未做**：与官方客户端的密文逐字节比对。这需要能运行官方实现生成黄金向量，
  本轮未完成。当前仅有「往返一致 + 跨语言一致」级别的验证

---

## 四、TLV 布局确认（M1 的这条是对的）

`oicq.wlogin_sdk.tlv_type.tlv_t`（基类）：

```java
this._head_len = 4;
public void fill_head(int cmd) {
    util.int16_to_buf(_buf, _pos, cmd);       // offset 0
    util.int16_to_buf(_buf, _pos + 2, 0);     // offset 2，len 占位
}
public void set_length() {
    util.int16_to_buf(_buf, 2, _pos - _head_len);   // len 只计 body
}
```

```
+--------+--------+------------------+
| cmd    | len    | body             |
| u16 BE | u16 BE | len 字节          |
+--------+--------+------------------+
```

另有两条附带确认：

```java
public int search_tlv(...) {
    i = util.buf_to_int16(bArr, i4) + 2 + i4;   // 下一字段 = 当前 + 4 + len
}
```
→ TLV 链式遍历方式确认，与实现一致。

```java
public class tlv_t104 extends tlv_t {
    public static final int CMD_104 = 260;      // 260 == 0x0104
}
```
→ **「类名后缀即编号」的映射规律得到直接证实**（`tlv_t104` → `0x0104`）。
    这条规律是 `tlv_types.dart` 里 113 条编号的依据。

---

## 五、登录链路：现代 QQNT 走的是命名式 SSO，不是老的 0x0825

全 dex 扫描 `api_sso_commands.csv`（401 条）中，`EcdhService.SsoNTLogin*` 一族构成现代登录链路：

| 命令字 | 语义 |
|---|---|
| `EcdhService.SsoKeyExchange` | ECDH 密钥交换 |
| `EcdhService.SsoNTLoginGetSaltList` | 拉取口令加盐列表 |
| `EcdhService.SsoNTLoginPasswordLogin` | 口令登录 |
| `EcdhService.SsoNTLoginGetSms` / `CheckSms` | 短信验证码 |
| `EcdhService.SsoNTLoginCheckGateWayCode` | 网关验证码 |
| `EcdhService.SsoNTLoginCheckThirdCode` | 第三方验证码 |
| `EcdhService.SsoNTLoginCheckA1List` | 检查本地 A1 票据 |
| `EcdhService.SsoNTLoginAuthNewDevice` | 新设备鉴权 |
| `EcdhService.SsoNTLoginEasyLogin` / `RapidLogin` / `OptimusLogin` | 免密/快速登录 |
| `EcdhService.SsoNTLoginRefreshA2` / `RefreshTicket` | 票据刷新 |

**重要含义**：口令不是直接 MD5，而是**加盐派生**（有 `GetSaltList` 这一步）。
新版接口用 trpc 命名 + protobuf 载荷，与旧版 TLV 报文是两套东西——目标 APK 里两者并存。

`oicq.wlogin_sdk` 包 368 个类的模块划分：

| 子包 | 内容 |
|---|---|
| `request` | `WtloginHelper`（884KB 源码）+ 25 个 `HelperThread`、`Ticket`、`WUserSigInfo` |
| `tlv_type` | **114 个** TLV 类 |
| `tools` | `cryptor`(TEA) / `EcdhCrypt` / `RSACrypt` / `MD5` / `util` |
| `devicelock` | `DevlockBase` / `DevlockInfo` / `TLV_QuerySig` / `TLV_SppKey` |
| `contextpersist` | `PersistContext` / `SmsVerifyContext` / `DeviceSmsContext` |
| `pb` | `ThirdPartLogin$*`（微信/手机/Apple/Facebook/Google 登录 protobuf） |
| `code2d` | `fetch_code` — 扫码登录 |

加密栈确认：**TEA(cryptor) + ECDH(EcdhCrypt) + RSA(RSACrypt) + MD5**。

---

## 六、代码改动清单

| 文件 | 改动 |
|---|---|
| `lib/infra/coder.dart` | **字节序默认改大端**；显式新增小端变体；补反编译证据注释 |
| `lib/kernel/crypto/tea.dart` | **重写**：修字节序、补 `qqTeaEncrypt/Decrypt`、补分组原语、XXTEA 归因标注 |
| `lib/kernel/wlogin/tlv.dart` | 文档更正为「大端 + 4 字节头」，附三条反编译证据 |
| `lib/kernel/wlogin/tlv_types.dart` | **新增**（自动生成）：113 个已确认 TLV 编号 |
| `lib/kernel/wlogin/login_commands.dart` | **新增**：14 条登录命令字 + 登录阶段/结果码模型 |
| `lib/kernel/transport/transport.dart` | **新增**：长连接抽象 + `LoopbackTransport` + 帧编解码契约 |
| `test/protocol_test.dart` | 断言改大端；新增 QQ TEA 测试组（7 例） |
| `tool/selftest.dart` | 断言改大端；新增 M2 三组测试 |
| `penguis-analysis/dex_class_finder.py` | **新增**：dex 类定位（解决 grep 误判） |
| `penguis-analysis/decompile.sh` | **新增**：批量单类反编译 |
| `penguis-analysis/gen_tlv_registry.py` | **新增**：从扫描结果生成 Dart 注册表 |

验证结果：`flutter analyze` → No issues found；`dart run tool/selftest.dart` → **57/57 通过**。

---

## 七、未完成 / 待确认

1. **密文黄金向量**：无官方实现的可运行对照，`qqTeaEncrypt` 未做逐字节验证。
   下一步可尝试把 dex 转成 class 后直接调用原 `cryptor` 生成向量。
2. **`oicq_request` 报文封装**：已定位在 `classes5.dex`，尚未反编译。
   MSF 帧格式（head 标记、长度字段语义、seq 生成规则）仍未知，
   `MsfFrameCodec` 因此**故意留空**，不填猜测值。
3. **`WtloginHelper` 控制流**：884KB 源码已产出，尚未细读。
   登录阶段的状态机（`LoginStage`）目前是**基于命令字名称的推断**，不是还原结果。
4. **端到端连通性**：客户端是否需要连真实腾讯服务器，老师是否提供测试服务端——**仍未确认**。
   这决定 M3 之后是「真实对接」还是「针对测试端实现」。
