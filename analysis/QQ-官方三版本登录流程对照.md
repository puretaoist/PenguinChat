# QQ 官方客户端三版本登录流程对照

对照对象（全部为反编译产物，`apk-analysis/`）：

| 代号 | 版本 | APK | jadx 输出 | 登录构建器 |
|---|---|---|---|---|
| V8211 | 8.2.11 (versionCode 1380) | `QQ-com.tencent.mobileqq-play-8.2.11.apk` | `jadx-main/` | `oicq/wlogin_sdk/request/k.java` |
| V8950 | 8.9.50 | `8.9.50.apk` | `jadx8950/`（classes26.dex） | `oicq/wlogin_sdk/request/j.java` |
| V9360 | 9.3.60 | `9.3.60_23e3f34e30110797.apk` | `jadx9360/`（classes11.dex） | `oicq/wlogin_sdk/request/l.java` |

目的：确认本仓库 `lib/kernel/wlogin8/` 的 8.2.11 协议实现是否与**官方**对齐，
以及参考实现 oicq 与官方分歧时该信谁。

---

## 1. 登录 TLV 顺序数组：8.2.11 与 8.9.50 逐字节相同

三版本各有一份 `int[]` 顺序表，官方按它循环组装登录请求。

### V8211 `k.java:56`

源码用 `NotificationUtil.Constants.NOTIFY_ID_*` 与 `HttpStatus.*` 常量当 TLV
编号（腾讯把通知 ID 常量池复用成了 TLV 常量池）。逐个解出后：

```
24, 1, 262, 278, 256, 263, 264, 260, 322, 274,
324, 325, 327, 358, 362, 340, 321, 8, 1297, 370,
389, 1024, 391, 392, 404, 401, 513, 514, 375, 1302,
1313, 1317, 1321, 792, 1348, 1349, 1352
```

常量解析来源：

| 常量 | 值 | 位置 |
|---|---|---|
| `NOTIFY_ID_UPGRADE_TABLE` | 262 | `NotificationUtil.java` |
| `NOTIFY_ID_UNIFORM_DOWNLOAD_BEGIN` | 278 | 同上 |
| `NOTIFY_ID_IPADONLINE_MSG` | 263 | 同上 |
| `NOTIFY_ID_PCONLINE_MSG` | 264 | 同上 |
| `NOTIFY_ID_STORY_UNREAD_CAPTURE_TOGETHER` | 260 | 同上 |
| `NOTIFY_ID_UNREAD_SEC_MSG` | 274 | 同上 |
| `HttpStatus.SC_NOT_FOUND` | 404 | `highway/utils/HttpStatus.java` |
| `msf.core.net.a.f.s` | 514 | `msf/core/net/a/f.java` |

### V8950 `j.java:75`

```java
int[] iArr2 = {24, 1, 262, tlv_t116.CMD_116, 256, 263, 264, tlv_t104.CMD_104,
  tlv_t142.CMD_142, 274, 324, tlv_t145.CMD_145, 327, 358, 362, 340, 321, 8,
  1297, 370, 389, 1024, 391, 392, 404, 401, 513, 514, 375, 1302,
  tlv_t521.CMD_521, 1317, 1321, 792, 1348, 1349, 1352};
```

已解析常量：`CMD_104=260`、`CMD_116=278`、`CMD_142=322`、`CMD_145=325`、
`CMD_521=1313`。

**结果：与 V8211 的 37 项完全相同（含顺序）。**

### V9360 `l.java:76`

同上 37 项，**末尾追加** `tlv_t553.CMD_553 = 1363`，共 **38 项**。

> 结论：`lib/kernel/wlogin8/qq8_tlv.dart` 里的 `qq8OfficialLoginTlvOrder`
> （37 项）与 8.2.11 / 8.9.50 **完全一致**，无需改动。
> 0x553 只出现在 9.3.60，不是 8.2.11 的组成部分，**不必补**。

---

## 2. 顺序表 ≠ 实际发送：官方自己也会跳项

V8950 `j.java` 对顺序表做 `switch` 分派（`j.java:120`），但只有 **31 个 `case`**。
顺序表里的 6 项没有对应 `case`：

```
278 (0x116)   260 (0x104)   322 (0x142)   325 (0x145)   1313 (0x521)   1321 (0x529)
```

进一步统计该文件里 `get_tlv_*` 的调用点，可知：

- `0x104 / 0x116 / 0x142 / 0x145` **确实被构建**（在 `switch` 外/默认分支调用，
  见 `j.java:168 / 265 / 289 / 317`），只是不参与条件分派；
- `0x521 (1313)` 与 `0x529 (1321)` 在这个文件里**既没有 `case` 也没有
  `get_tlv_521 / get_tlv_529` 调用** —— 即列在顺序表里但 8.9.50 的登录构建器
  **根本不产生这两个 TLV**。（其它流程构建器另算。）

> 教训：把顺序表长度当成"实际发送 TLV 数"是错的。
> 官方是「超集清单 + 条件分派」，未命中的项直接跳过。

### 条件项举例

| TLV | 条件 | 位置 |
|---|---|---|
| `0x201 (513)` | 仅当 `w` 非空 | `j.java:551-567` |
| `0x202 (514)` | 仅当 `u.R` 非空 | `j.java:575-591` |
| `0x318 (792)` | 仅当 `tgtQR` 非空；且用泛型 `tlv_t(792).set_data(tgtQR)` 直接包，**无专用类** | `j.java:599-631` |
| `0x400 (1024)` | 需已有 `WloginSigInfo`（`_G` / `_dpwd` / `_randseed`）→ **仅重登/续期**，首次登录不发 | `j.java:633-` |

**0x318 是 `tgtQR`，属二维码登录路径；密码登录下 `tgtQR` 为空，永不发送。**

---

## 3. 待补的 10 个 TLV：8 个可直接从 8.2.11 自身移植

`qq8LoginTlvMissing` 现有 10 项。逐个核对官方是否存在可移植的 `tlv_type` 类：

| TLV | 十进制 | 8.2.11 `jadx-main` | 8.9.50 | 9.3.60 | 判定 |
|---|---|---|---|---|---|
| `0x112` | 274 | ✅ `tlv_t112` | ✅ | ✅ | 可移植 |
| `0x166` | 358 | ✅ `tlv_t166` | ✅ | ✅ | 可移植 |
| `0x172` | 370 | ✅ `tlv_t172` | ✅ | ✅ | 可移植 |
| `0x185` | 389 | ✅ `tlv_t185` | ✅ | ❌ | 可移植（8.9.50 兜底） |
| `0x201` | 513 | ✅ `tlv_t201` | ✅ | ✅ | 可移植（**条件项**） |
| `0x544` | 1348 | ✅ `tlv_t544` | ✅ | ✅ | 可移植 |
| `0x545` | 1349 | ✅ `tlv_t545` | ✅ | ✅ | 可移植 |
| `0x548` | 1352 | ✅ `tlv_t548` | ✅ | ❌ | 可移植（8.9.50 兜底） |
| `0x529` | 1321 | ❌ | ❌ | ❌ | **无类、无构建点** → 8.2.11 不该发 |
| `0x318` | 792 | ❌ | ❌ | ❌ | **无专用类**，是 `tgtQR` 泛型包装 → 仅二维码登录 |

**8.2.11 自身就有全部 8 个可移植类的实现，且是目标版本本身 —— 移植供体用
`jadx-main`，无需跨版本借用，避免版本漂移。**

`jadx-main/sources/oicq/wlogin_sdk/tlv_type/` 共 **111** 个类，命名未被混淆。

---

## 4. TLV 0x106：三版本算法一致，密钥派生以官方为准

三版本 `get_tlv_106` 主体逐行对照，除 `_SSoVer` 常量外**完全一致**：

| 版本 | `_SSoVer` |
|---|---|
| 8.2.11 | **7** |
| 8.9.50 | **19** |
| 9.3.60 | **22** |

TEA 密钥派生：`MD5(guid(16) ‖ u64(uin 或 msalt)(8))`。

调用点直接印证（V8950 `j.java:185`）：

```java
tlv_t106Var.get_tlv_106(j2, j3, i2, j4, bArr2, bArr, 1, bArr3,
                        async_contextVar3._msalt, jVar.m.e.getBytes(), ...);
                                    ^^^^^^^^^^^^^^^^^^^^^ 第 9 参数 = msalt
```

即：**有 msalt 用 msalt，否则用 uin**，与三版本代码一致。

oicq 的 `lib/wtlogin/login-password.js` 用的密钥公式与三者**都不同**。

> 本仓库已按官方修正 `qq8_tlv.dart`（`Qq8TlvContext` 增加 `msalt`），
> `tool/qq8_tlv_selftest.dart` 新增断言并 **58/58 通过**。

---

## 5. TEA 填充头：官方确认 `(rand & 0xF8) | pad`

`jadx-main/sources/oicq/wlogin_sdk/tools/a.java:130`：

```java
this.a[0] = (byte) ((b() & NOTIFY_ID_STORY_UNREAD_AT_FRIEND) | this.f);
//                    ^ b() & 248 == & 0xF8      ^ this.f == pad
```

`NOTIFY_ID_STORY_UNREAD_AT_FRIEND = 248 = 0xF8`。
与 `lib/kernel/crypto/tea.dart` 的 `(rand & 0xF8) | pad` 一致
（oicq 写的是 `pad | 0xF8`，因为接收端只读 `& 7`，两者等价）。

**填充是随机的 → TEA 密文不可字节复现**，测试必须比明文与密钥，不能比密文。

---

## 5.5 逐项核对：10 个"缺失 TLV"的真实性质

`lib/kernel/wlogin8/qq8_tlv.dart` 的 `qq8LoginTlvMissing` 逐项核到官方代码后，
**结论与"补 10 个 TLV"完全不同** —— 其中多数在首登时官方自己也不发。

### 8.2.11 的 case 分派与条件（`oicq/wlogin_sdk/request/k.java`）

`this.x` 的类型是 `oicq.wlogin_sdk.request.t`（同一类既装静态配置又装请求上下文），
故 `x.g` = `t.g`（`String`，默认 `""`）、`x.r` = `t.r`（`byte[]`，默认空）、
`x.i` = `t.i`（`int`，默认 0）。静态量：`t.A/B/C/... = new byte[0]`、
`t.x = 1`、`t.D = 0`、`t.an = new byte[0]`。

| TLV | 官方条件（行号） | Body 构造 | 首登实际情况 |
|---|---|---|---|
| `0x112` | `x.g != null && !check_uin_account(x.g)`（`k.java:131`） | `g.getBytes()` 原文 | **uin 登录 → 不发**；仅手机号/邮箱登录发 |
| `0x166` | `(i4 & 128) != 0`（`k.java:176`） | `i8(t.x)` = `[0x01]`（`t.x` 默认 1） | 取决于登录标志位 |
| `0x172` | `x.r != null && x.r.length != 0`（`k.java:196`） | `r` 原文 | **`t.r` 由服务端回显赋值**（`oicq_request.java:1341` / `aa.java:274`）→ 首登为空，**不发** |
| `0x185` | `i3 == 3`（`k.java:211`） | `[0x01, i8(1)]` = `01 01` | 取决于登录类型参数 |
| `0x201` | `L != null && L.length != 0`（`k.java:253`） | `u16len‖L ‖ u16len‖M ‖ u16len‖"qq" ‖ u16len‖N` | 依赖 `k.L/M/N`（服务端下发）→ 首登多为空，**不发** |
| `0x544` | **无条件**（`k.java:376`） | **`com.tencent.secprotocol.ByteData.getCode()` 产出** | **❌ 无法在纯 Dart 复现** |
| `0x545` | `t.T`（QIMEI）非空（`k.java:383-393`） | `T` 原文 | `t.T = util.get_qimei(context)`，需 `libQimei.so`；取不到 → **官方也跳过** |
| `0x548` | `t.an != null && t.an.length > 0`（`k.java:394`） | `an` 原文 | 默认空 → **不发** |

### 0x544 是硬阻断

`tlv_t544.java`（8.2.11）：

```java
com.tencent.secprotocol.ByteData.getInstance().init(context);
byte[] code = com.tencent.secprotocol.ByteData.getInstance()
        .getCode(0L, j, i3, 0L, "", str, strBuf_to_string, bArr3);
fill_body(code, code.length);          // ← 真正的 TLV body 由这个 SDK 生成
```

* `com.tencent.secprotocol.*` 在 `jadx-main/sources/` 里**只有 `tlv_t544` 一处引用**
  —— 实现类在我们没反编译的其它 `classesN.dex` 里（APK 是多 dex）。
* APK 原生库里有 **`libQSec.so`**（腾讯安全 SDK），就是它的后端。
* 8.9.50 的 `tlv_t544` 签名已变成 3 参数 `(String, String, byte[])`，
  8.2.11 是 7 参数 `(Context, long, int, byte[], int, String, int)` → 版本间有漂移。

> **含义：纯 Dart 实现永远发不出与官方一致的 0x544。**
> 这不是"还没实现"，而是**架构上不可达** —— 除非打包腾讯的 native 库并调用它。
> 因此自实现协议客户端在服务端眼里**必然**是 oicq / Lagrange 同一档的信任级别，
> 拿不到官方客户端的设备指纹。这一点直接决定账号风险等级。

### 重新分类

| 类别 | TLV | 处理 |
|---|---|---|
| 结构简单、首登可能真发 | `0x166`、`0x185` | 可补（各 1–2 字节常量） |
| 条件明确、首登为空 | `0x112`、`0x172`、`0x201`、`0x548` | 可补构造器，但首登不构建 |
| 依赖 native | `0x545`（`libQimei.so`） | 取不到就跳过，**与官方同构** |
| **不可复现** | `0x544`（`libQSec.so`） | 只能跳过；0x544 缺失是本实现与官方的**永久差异** |

---

## 5.6 深挖 0x544：能不能把腾讯的 native 库打包进来调用？

结论先说：**技术上可行，但拿不到你想要的东西；而且不需要 —— 官方自己有一条
"SDK 不可用"的降级路径，输出正好是 4 个零字节。**

### 真正的后端是 `libpoxy.so`，不是 `libQSec.so`

`com.tencent.secprotocol.ByteData`（在 `classes3.dex`，此前没反编译到）里：

```java
private native byte[] getByte(Context ctx, long a, long b, long c, long d,
                              Object o1, Object o2, Object o3, Object o4);

private void initLoadlibrary() {
    if (!loadUpgradedLibrary()) {
        System.loadLibrary("poxy");            // ← 后端是 poxy
    }
    this.mPoxyNativeLoaded = true;
    this.mPoxyInit = true;
}

private boolean loadUpgradedLibrary() {
    String str = QPDirUtils.getQQProtectQSecLibsDir(getContext())
                 + File.separator + "libpoxy.so";      // ← 优先加载"升级后"的那份
    File file = new File(str);
    if (file.exists() && VerifyFileUtil.verifySoFile(file, null)) {   // ← 要腾讯签名
        System.load(str);
        return true;
    }
    return false;
}
```

注意两点：**优先加载运行时下载到 `QQProtectQSecLibs/` 的那份**，并且必须通过
`VerifyFileUtil.verifySoFile` —— 即"APK 里自带的那份"本身就是设计上的兜底路径。

### 三个 .so 的真实成分（8.2.11 / 8.9.50 / 9.3.60 对照）

| .so | 8.2.11 | 8.9.50 | 9.3.60 | 实情 |
|---|---|---|---|---|
| `libpoxy.so` | **50.0 KB** | 无 | 无 | 有 `JNI_OnLoad`，**无静态 `Java_*` 导出**（动态 `RegisterNatives`） |
| `libQSec.so` | 28.5 KB | 28.5 KB（同文件） | 28.5 KB（同文件） | **只有 `.dynamic` / `.dynstr` / `.shstrtab`，没有任何代码段** → 加密壳存根 |
| `libQimei.so` | 33.6 KB | 无 | 无 | 1 个 JNI 导出 `Java_com_tencent_beacon_core_BeaconIdJNI_c` |

**`libpoxy.so` 的导入表是决定性的：**

```
socket  connect  getaddrinfo  freeaddrinfo  setsockopt      ← 联网
dlopen  dlsym  dladdr  dlclose                              ← 运行时再加载
fopen  fgets  fclose  chmod  stat                           ← 落盘并置可执行
```

**没有任何加密原语导入**（无 openssl / libcrypto）。50KB + 这段导入表的含义
很明确：**它是个下载器/加载器**，真身靠联网取回、`chmod` 落地、再 `dlopen`。
APK 里根本没有真正的设备指纹算法。

而 8.9.50 / 9.3.60 **连 `libpoxy.so` 和 `libQimei.so` 都不带**了，只剩同一个
28.5KB 的 `libQSec.so` 存根，另配 `libfekit.so`（9.7MB）—— 模块早已换代，
可打包的是 2020 年那条死路径。

### 所以"打包 native 库调用"会得到什么

1. 要打包：`libpoxy.so` + `libQSec.so` + `ByteData` / `ByteCodeCrashProtector` /
   `QPDirUtils` / `QPMiscUtils` / `VerifyFileUtil` 五个 Java 类（都已可反编译）。
2. 还要 Flutter → Android 平台通道，因为 `getByte` 要真实 `Context`。
3. 跑起来后，`libpoxy.so` 会 **联网**去取真身 —— 于是你的自建客户端会主动
   发出一段腾讯设备指纹的取件流量。**这比发零字节更像在伪造官方客户端**，
   风控上是更差的信号，不是更好的。
4. 散发 APK 里含腾讯专有 `.so`，是直接的知识产权问题。

### 关键：官方有降级路径，输出就是 `00 00 00 00`

```java
private byte[] status = new byte[]{0, 0, 0, 0};

public synchronized byte[] getCode(final long j, final long j2, final long j3,
                                   final long j4, Object obj, Object obj2,
                                   Object obj3, Object obj4) {
    byte[] bArr;
    if (this.status[1] != 0 || checkObject(obj4)
            || !this.mPoxyNativeLoaded || !this.mPoxyInit) {
        bArr = this.status;                 // ← 00 00 00 00
    } else {
        ... getByte(...) ...
    }
    return bArr;
}
```

* `status[1]` 在 `UnsatisfiedLinkError` 时置 **1**，在 `HandlerThread` 起不来时置 **2**。
* `getByte` 内部崩了则 `ByteCodeCrashProtector.onCrashDetected()` 返回
  `new byte[4]` 且 `[3] = 1`。
* `checkObject(obj4)` 只在 obj4 不是非空 `byte[]` 时为真；`tlv_t544` 传的
  `bArr3` 恒为非空，故这条不触发。

**即：安全 SDK 没加载成功时，官方客户端往 TLV 0x544 里放的就是恰好
4 个零字节。**

> 所以正确做法不是打包 native 库，而是 **发 `0x544 = 00 00 00 00`**。
> 这是官方自己的代码路径，不是伪造：拿到与官方降级客户端**完全一致的报文
> 格式**，不携带任何腾讯二进制，不产生指纹取件流量，也没有版权问题。

---

## 5.7 官方设备指纹的完整栈与逐层难度

登录报文里的"设备身份"不是一个值，是三层，难度递增。

| 层 | 值 | 所在 TLV | 生成方式 | 能否自造 |
|---|---|---|---|---|
| L1 | `guid`（16B） | `0x106` | `MD5(android_id ‖ mac)`，**本地纯计算** | ✅ 完全可造 |
| L1 | `android_id` / `mac` | `0x106` | `Settings.Secure` / 网卡；取不到时随机 15 位数字并落盘 | ✅ |
| L2 | **QIMEI** | `0x545` | **Beacon 灯塔 SDK 联网注册，腾讯服务器签发** | ❌ |
| L3 | **设备码** | `0x544` | **`libpoxy.so` native + 联网** | ❌ |

### L1 —— 不难，因为它本来就是本地算的

`oicq/wlogin_sdk/tools/util.java:402`：

```java
public static byte[] generateGuid(Context context) {
    if (t.ak != null && t.ak.length != 0) return t.ak;   // 允许外部直接指定
    String androidId = getAndroidId(context);
    String macAddr   = getMacAddr(context);
    return MD5.toMD5Byte((androidId + macAddr).getBytes());
}
```

配套还有：

* `getRandomAndroidId`（`util.java:415`）—— android_id 取不到时**随机造 15 位数字**，
  存进 `WLOGIN_DEVICE_INFO/random_AndroidId`；
* `needChangeGuid`（`util.java:432`）—— GUID 按 `GUID_DELAY_HOUR` 随机小时数轮换。

也就是说：guid 从设计上就是"客户端自己算 + 自己存"的，**我们算出来的和官方没有区别**。

### L2 —— QIMEI：格式极简，签发很硬

**先破除误解：0x545 的 body 就是 `MD5(一个字符串)`。**

`oicq/wlogin_sdk/tools/util.java:343`：

```java
public static byte[] get_qimei(Context context) {
    SharedPreferences sp = context.getSharedPreferences("DENGTA_META", 0);
    String s = sp.getString("QIMEI_DENGTA", "");
    if (!TextUtils.isEmpty(s)) {
        return MD5.toMD5Byte(s.getBytes());      // ← 0x545 body
    }
    return new byte[0];                          // ← 取不到就空，官方自己也不发该 TLV
}
```

连存储都能完整读到：

* SP：`DENGTA_META` / 键 `QIMEI_DENGTA`；
* SD 卡备份：`tencent/beacon/meta_0S200MNJT807V3GE.dat`
  （`APPKEY_DENGTA = 0S200MNJT807V3GE`，来自 `AndroidManifest.xml`）；
* 该文件用 `i.b(data, 3, key)` 加密，key 由 `com.tencent.beacon.qimei.d.a()` 产出 ——
  那段代码把同一个 XOR 跑了两遍（`d.java:171-176`），**互相抵消**，
  净结果就是字面量 `@&(*#HNKJg12!@)`。

**难的是这个字符串从哪来。** `com.tencent.beacon.qimei.c.a()` 是请求构造：

```java
qimeiPackage.imei = ...;  qimeiPackage.imsi = ...;
qimeiPackage.mac = ...;   qimeiPackage.androidId = ...;
qimeiPackage.qimei = ...; qimeiPackage.model = ...;
qimeiPackage.brand = ...; qimeiPackage.osVersion = ...;
qimeiPackage.broot = false;   // 硬编码 false
qimeiPackage.qq = ...;    qimeiPackage.cid = ...;
this.h = a(this.a, bVarA, byteArray, 2, 3, this.f);   // ← 发给灯塔
```

上报端点（`com/tencent/beacon/**` 里的字面量）：

```
http://oth.eve.mdt.qq.com
http://oth.str.mdt.qq.com
http://strategy.beacon.qq.com/analytics/upload
http://183.36.108.226                      ← 硬编码 IP 兜底
```

响应码 **102** 才算拿到 QIMEI（`c.java:94`），随后 `QimeiSDK` 写回 SP + SD 卡。

> 所以 QIMEI = **腾讯服务器按你上报的设备属性签发的一个 ID**。
> 自己编一个 → 服务端不认识；要去要一个 → 就得把一套设备属性发给腾讯灯塔。
> 它还是设备绑定的：频繁换 QIMEI、或同一 QIMEI 配不同设备画像，本身就是风控特征。

### L3 —— 0x544：见 5.6，native + 联网

### 为什么这条路的困难是结构性的

1. **完整性校验**：`VerifyFileUtil.verifySoFile(file, null)` —— 运行时下载的 `.so`
   必须过腾讯签名；每次 native 调用还包着 `ByteCodeCrashProtector`。
2. **权限面**：manifest 声明 49 项权限，含 `READ_PHONE_STATE`、`ACCESS_WIFI_STATE`、
   `GET_ACCOUNTS`、`ACCESS_FINE_LOCATION`、`WRITE_EXTERNAL_STORAGE`、`READ_CONTACTS`；
   指纹的输入就取自这些真实设备属性。
3. **多 SDK 各自注册**：灯塔（QIMEI）、QSec/poxy（设备码）、turing（风控，
   `classes3.dex` 里 71 处引用）、`libfekit.so`（9.3.60 才有的 9.7MB 新模块）
   是**互相独立**的模块，各自联网、各自缓存。
4. **服务端看的是整体一致性**，不是单点值：一套设备画像 + 登录历史 + IP + 行为。

### 实际结论

自实现协议客户端能到达的上限是：

> **L1 与官方完全一致，L2 / L3 走官方自己的降级路径。**

这不会让服务端把你当官方客户端，但**也不会因为伪造痕迹额外扣分** ——
`0x544 = 00 00 00 00` 是官方表示"安全 SDK 没加载"，塞一个编造的设备码反而会被
识别为伪造。**降级比伪造安全。**

### 如果确实想要一个真 QIMEI：两条路，各有代价

| 路线 | 做法 | 代价 |
|---|---|---|
| 读取官方客户端的缓存 | 读 `/data/data/com.tencent.mobileqq/shared_prefs/DENGTA_META.xml` 的 `QIMEI_DENGTA`，或 SD 卡 `tencent/beacon/meta_0S200MNJT807V3GE.dat`（key = `@&(*#HNKJg12!@`） | 需要 **root**；Android 11+ 下普通应用读不到别的应用 `shared_prefs` |
| 自己集成 Beacon SDK | 引入 `com.tencent.beacon`，用 QQ 的 `APPKEY_DENGTA = 0S200MNJT807V3GE` 走 `oth.eve.mdt.qq.com` 注册 | 属于**用 QQ 的 appkey 冒充官方 app 向腾讯灯塔注册**；拿到的 QIMEI 会与你的包名/签名/设备画像绑到一起 |

两条路都解决"值从哪来"，但都解决不了最根本的问题：**服务端比对的是
「QIMEI + 设备画像 + 登录历史 + IP + 行为」的一致性**，而不是单个值。
一个来源可疑、画像对不上的 QIMEI，比诚实降级更像异常。

---

## 5.8 TIM 4.1.0.4050 并入对照（四个客户端）

新增对照对象：`tim_4.1.0.4050.apk`（147.2 MB，24 个 dex，包内 119 个 arm64 原生库）。

### (1) 登录 TLV 顺序表：用 DEX payload 头读出确切长度

DEX 的 `fill-array-data` 载荷在数据前有 8 字节头
（`ushort ident=0x0300` | `ushort element_width=4` | `uint size`），
因此可以直接从字节读到**数组真实长度**，不必靠反编译猜：

| 客户端 | dex | 偏移 | 大小 | 相对 8.2.11 |
|---|---|---|---|---|
| QQ 8.2.11 | `classes.dex` | `0x00793718` | **37** | 基准 |
| QQ 8.9.50 | `classes26.dex` | `0x003a06d0` | **37** | 完全一致 |
| QQ 9.3.60 | `classes11.dex` | `0x0080bf2c` | **38** | + `0x553` |
| **TIM 4.1.0.4050** | `classes19.dex` | `0x0047ec3c` | **38** | **+ `0x553`** |

TIM 的完整表（`oicq/wlogin_sdk/request/j.java:127`）：

```java
int[] iArr = {24, 1, 262, tlv_t116.CMD_116, 256, 263, 264, tlv_t104.CMD_104,
  322, 274, 324, tlv_t145.CMD_145, 327, 358, 362, 340, 321, 8, 1297, 370,
  389, 1024, 391, 392, 404, 401, WnsNetworkConst.CONNECT_TIME_OUT,
  WnsNetworkConst.WRITE_TIME_OUT, 375, 1302, tlv_t521.CMD_521, 1317, 1321,
  792, 1348, 1349, 1352, tlv_t553.CMD_553};
```

`WnsNetworkConst.CONNECT_TIME_OUT = 513`、`WRITE_TIME_OUT = 514`
—— 又是拿别的常量池顶替 TLV 编号，与 8.2.11 同一套路。

**所以：QQ 8.9.50 ≡ 8.2.11（37 项）；TIM ≡ 9.3.60（38 项）。**

### (2) `_SSoVer`：TIM 与 9.3.60 同为 22

| 客户端 | `tlv_t106._SSoVer` |
|---|---|
| QQ 8.2.11 | 7 |
| QQ 8.9.50 | 19 |
| QQ 9.3.60 | 22 |
| **TIM 4.1.0.4050** | **22** |

### (3) `0x553` 是另一个 fekit 门控的证明块

TIM `request/j.java:860`：

```java
case tlv_t553.CMD_553 /* 1363 */:
    bArr17 = new tlv_t553().get_tlv_t553(
        QSec.getInstance().getFeKitAttach(this.a, String.valueOf(j4), "0x810", "0x9"));
```

`"0x810"` = 2064、`"0x9"` = 9，正是登录命令的 `t` / `u`。
而 `tlv_t553` 本身只是原始字节透传（`get_tlv_t553(byte[])`）——
**值完全由 `QSec.getFeKitAttach` 生成，和 `0x544` 是同一类东西。**

> 含义：9.3.60 / TIM 比 8.9.50 **多一个不可复现的门控块**。
> 补 `0x553` 不是"加 15 行代码"，而是再加一个 fekit 依赖。

### (4) TIM 的 `0x544` 与 8.9.50 同形

```java
public byte[] get_tlv_544(String str, String str2, byte[] bArr) {
    byte[] liteSign = new byte[0];
    try {
        if (e.b().e()) {                       // 门控（8.9.50 里是 fe.c.c().f()）
            liteSign = QSec.getInstance().getLiteSign(str2, bArr);
        }
        return makeByte(liteSign, liteSign.length);   // 不可用 → 空 body
    } catch (Exception e) {
        return errInfo((byte) 1);                     // → [0,0,1,0]
    }
}
```

TIM 的 `SDK_VERSION` 字符串是 `"6.0.0.2563"`（8.9.50 用 `util.SDK_VERSION`）。

### (5) `APPKEY_DENGTA`：三个客户端**完全相同**（更正）

> ⚠️ **本节此前有过一个错误结论，已更正。**
> 早先用"AXML 字符串池相邻关系"提取，得出 8.9.50/TIM 的 appkey 与 8.2.11 不同的
> 结论。那是把**相邻的另一个 meta-data 值**当成了目标值。
> 正确做法是解析 AXML 属性结构（脚本 `axml_meta.py`），结果是三者一致。

| 客户端 | `APPKEY_DENGTA` |
|---|---|
| QQ 8.2.11 | `0S200MNJT807V3GE` |
| QQ 8.9.50 | `0S200MNJT807V3GE` |
| **TIM 4.1.0.4050** | **`0S200MNJT807V3GE`** |
| QQ 9.3.60 | manifest 中无，运行时下发 |

QIMEI 按 appkey 签发 ⇒ **TIM 的 QIMEI 对 8.2.11 和 8.9.50 都有效**。
"appkey 对不上" **不构成换版本的理由**。

### (5b) `AppSetting_params`：subAppId 的真正来源

`AppSetting.m1650a()`（8.2.11）从 manifest 的 `AppSetting_params` 解析：

```java
String[] p = str.split("#");
f = Integer.parseInt(p[0]);   // ← subAppId
f2554d = p[1];
h = p[2];
i = p[3];                     // ← 渠道名
```

于是四个客户端的 subAppId 可直接读出：

| 客户端 | `AppSetting_params` |
|---|---|
| QQ 8.2.11 | `537064117#DF164B0A8344DA4E#2001#GoogleMarket#fff…` |
| QQ 8.9.50 | `537155557#4C6F23140CE449B9#2008#ALYY#fff…` |
| QQ 9.3.60 | `537389183#1BD2FCF3B7A70889#2017#GuanWang#fff…` |
| TIM 4.1.0 | `537298353#84856344DE59E952#2017#GuanWang#fff…` |

### (6) 安全栈对照

| 客户端 | `libpoxy` | `libQSec` | `libqimei` | `libBeaconDT` | `libfekit` | `libkernel` | 反 hook |
|---|---|---|---|---|---|---|---|
| QQ 8.2.11 | **50 KB** | 28.5 KB | 33.6 KB(`libQimei`) | — | — | — | — |
| QQ 8.9.50 | — | 28.5 KB | 527 KB | ✅ | **9.7 MB** | — | — |
| QQ 9.3.60 | — | 28.5 KB | — | ✅ | ✅ | 27 MB | — |
| TIM 4.1.0 | — | 28.5 KB | 527 KB | ✅ | 7.4 MB | 27 MB | **`libmatrix-*` 全套** |

TIM 额外带 `libmatrix-hookcommon` / `libmatrix-memoryhook` /
`libmatrix-pthreadhook` / `libmatrix-traffic` / `libshadowhook` / `libbypass`
—— **腾讯自家内存与流量 hook 检测**。⇒ TIM 不适合作为 LSPosed hook 宿主。

### (7) 版本选择结论

| 候选 | TLV 表 | 额外门控块 | fekit | 判定 |
|---|---|---|---|---|
| 8.2.11 | 37 | 无 | 无 | 链路最简，但 2020 年版本可能被服务端判旧 |
| **8.9.50** | **37（与已实现逐项相同）** | **无** | 9.7MB | **✅ 默认** |
| 9.3.60 | 38 | **+`0x553`（fekit）** | ✅ | 多一个不可复现块 |
| TIM 4.1.0 | 38 | **+`0x553`（fekit）** | ✅ | 同上 |

> **目标版本取 QQ 8.9.50；指纹源取本机 TIM 4.1.0 的 `DENGTA_META/QIMEI_DENGTA`。**
>
> 8.9.50 的 TLV 表与我们已实现的 8.2.11 **逐项相同**，
> 差异只剩 `ssoVer`（7 → 19）与 `0x544` 降级形态（`00000000` → 空 body）。
> 二者都已做成 `Qq8ApkInfo` 的字段，换版本 = 换一个 profile 常量。
>
> 若服务端以"版本过旧"拒绝，回退 8.2.11 同样只需换常量。

### (9) QIMEI：TIM 4.1.0 换了一套实现，且 TLV 语义变了

设备上**找不到 `DENGTA_META.xml`** 是正常的——原因如下。

#### 9.1 TIM 4.1.0 不用 Beacon QIMEI 了

标记在 dex 里的出现次数：

| 标记 | QQ 8.2.11 | TIM 4.1.0 |
|---|---|---|
| `Lcom/tencent/beacon/qimei`（旧实现） | **9** | **0** |
| `Lcom/tencent/qimei`（新独立 SDK） | 0 | **473** |
| `QIMEI_DENGTA`（旧 SP 键） | **2** | **0** |
| `q36`（QIMEI 新格式） | 1 | 6 |

TIM 4.1.0 换成 `com.tencent.qimei`（`classes15.dex` 235 处 / `classes4.dex` 135 处 /
`classes2.dex` 64 处），旧的 `com.tencent.beacon.qimei` 包**完全不存在**。
所以 `DENGTA_META` 里不会有 `QIMEI_DENGTA` 这个键。

**新 SDK 的存储目录**（`com/tencent/qimei/u/a.java:75`）：

```java
public static synchronized String b() {
    File file = new File(contextE.getFilesDir(), "qm");
    ...
}
// → /data/data/com.tencent.tim/files/qm/
```

#### 9.2 8.9.50 起 `0x545` 的语义变了（真实协议差异）

```java
// 8.2.11  util.java:343
String s = sp.getString("QIMEI_DENGTA", "");
if (!TextUtils.isEmpty(s)) return MD5.toMD5Byte(s.getBytes());   // ← 16 字节哈希
return new byte[0];

// 8.9.50  util.java:1493
QimeiListener l = qimeiListener;
if (l == null) return new byte[0];
String qimei = l.getQimei(context);
if (TextUtils.isEmpty(qimei)) return new byte[0];
return qimei.getBytes();                                          // ← 原文，不哈希
```

两点变化：

1. **不再 MD5**，body 是 QIMEI 字符串原文的 UTF-8 字节；
2. QIMEI 由**注入的监听器**提供 ——
   `WtloginHelper.setQimeiListener(QimeiListener)`，
   接口就是 `String getQimei(Context)`（`oicq/wlogin_sdk/listener/QimeiListener.java`），
   QQ app 自己实现，底层接的是新 QIMEI SDK。

**两者长度不同**（8.2.11 恒 16 字节，8.9.50 是 36 字符左右），
所以这是协议可见差异，已做成档案里的 `Qq8QimeiMode`：

| 档案 | `qimeiMode` |
|---|---|
| 8.2.11 | `md5OfSource` |
| 8.9.50 / 9.3.60 / TIM | `rawSource` |

拿不到 QIMEI 时**四个档案都发空 body** —— 这正是官方的行为
（`listener == null` → `return new byte[0]`）。

#### 9.3 设备上该找什么

```bash
# 新 SDK 的存储目录
su -c 'ls -laR /data/data/com.tencent.tim/files/qm/'

# 兜底：全盘找 qimei 相关文件
su -c 'find /data/data/com.tencent.tim -iname "*qimei*" -o -iname "*.qm" -o -path "*qm*" 2>/dev/null | head -40'

# 确认这个包名对吗（TIM 的包名也可能不是 com.tencent.tim）
su -c 'pm list packages | grep -i -E "tencent"'
```

### (11) `sign`（TLV 0x142）已从 APK 实测，不用猜

脚本 `extract_sign.py` 解析 `META-INF/*.RSA`（PKCS#7 SignedData）
取出第一张证书的 DER 再算 MD5：

| APK | v1 签名块 | 证书 DER | MD5 |
|---|---|---|---|
| QQ 8.2.11 | `ANDROIDR.RSA` | 599 B | `a6b745bf24a2c277527716f6f36eb68d` |
| QQ 8.9.50 | `ANDROIDR.RSA` | 599 B | `a6b745bf24a2c277527716f6f36eb68d` |
| QQ 9.3.60 | `ANDROIDR.RSA` | 599 B | `a6b745bf24a2c277527716f6f36eb68d` |
| **TIM 4.1.0** | `TIM_QQ_C.RSA` | **873 B** | **`775e696d09856872fdd8ab4f3f06b1e0`** |

* 三个 QQ 版本共用**同一张** 1024-bit 证书 ⇒ `sign` **跨 QQ 版本稳定**，
  一次提取到处可用（与 oicq 记录的 8.4.1 值也一致）。
* TIM 用的是另一张 2048-bit 证书 ⇒ 若做 TIM 档案必须换 `sign`。
  档案里已按实测值填好，测试断言覆盖。

### (13) 实机取证：小米平板 8 Pro + KernelSU 上的 TIM 4.1.0

拿到了设备 root（KernelSU v3.2.5，需在设置里开
「总是给 shell 授予 root 权限」= `settings_adb_root`，
以及「传统 su 命令支持」= `settings_sucompat`），
对真机上的 TIM 4.1.0（versionCode 4050，与手上的 APK 完全一致）做了采样。

#### 13.1 新 QIMEI SDK 的存储位置全部找到

```
/data/data/com.tencent.tim/files/qm/                      ← 新 SDK 工作目录
  b1d34ebe047a8208        1024 B  {"5":"","8":"…","9":"…","11":"10.150.199.203"}
  pl_dde95e0d4eb73df862efcb5c98a38f99                21 B  32072,com.tencent.tim
  spread_data                                        364 B  base64 密文
/data/data/com.tencent.tim/files/com.tencent.qimei.sdk.QimeiSDK   262 B  二进制
/data/data/com.tencent.tim/shared_prefs/QV1com.tencent.qimei.sdk.QimeiSDKf3e03c14699bc502.xml
/data/data/com.tencent.tim/shared_prefs/qm_global_sp.xml
```

`QV1…QimeiSDK….xml` 的 `tn` 键是一个 JSON，里面直接写着 appkey：

```json
{"crypt":"1","extra":"{\"appKey\":\"0AND063BSR94DSGA\",\"crypt\":\"1\"}",
 "key":"…","nonce":"…","params":"…","sign":"…","time":"…"}
```

真正的 QIMEI 在 `key`/`params` 里，**是加密的**，明文读不到。

#### 13.2 QIMEI 的 appkey 是「每 app 一套」——上一节的推断被推翻

| 客户端 | `0AND0*` appkey 个数 | 是否含 `0AND063BSR94DSGA` |
|---|---|---|
| QQ 8.9.50 | 16 | **否** |
| QQ 9.3.60 | 28 | **否** |
| TIM 4.1.0 | 19 | **是**（主实例） |

| 客户端 | `Lcom/tencent/qimei`（新 SDK） | `Lcom/tencent/beacon/qimei`（旧） |
|---|---|---|
| QQ 8.2.11 | 0 | 9 |
| QQ 8.9.50 | **187** | 0 |
| QQ 9.3.60 | **595** | 0 |
| TIM 4.1.0 | **473** | 0 |

> **结论：`APPKEY_DENGTA` 相同只说明旧 Beacon 层一致；
> 8.9.50 起 QIMEI 走新 SDK，appkey 换成每 app 一套的 `0AND0*`。
> TIM 的 QIMEI 不能用于 QQ 客户端。**

#### 13.3 guid 也不是 `MD5(android_id + mac)`

真机上：`/data/data/com.tencent.tim/files/wlogin_device.dat` = 恰好 16 字节：

```
e0 ae bb d3 a6 17 ab d2 de e8 08 57 6a 29 04 cf
```

用 `android_id`（`d82c8666bef2a88f` 与 prefs 里的 `88e13a819b9702c9`）
× `mac`（`76:7c:56:26:3b:cf` / 无冒号 / 大写 / 官方默认占位 `02:00:00:00:00:00`）
**共 8 种组合全部对不上**。

原因在 8.9.50 的 `generateGuid`（`oicq/wlogin_sdk/tools/util.java:660`）：

```java
public static byte[] generateGuid(Context context) {
    byte[] bArr = oicq.wlogin_sdk.request.u.i0;
    if (bArr != null && bArr.length != 0) {
        return oicq.wlogin_sdk.request.u.i0;      // ← 客户传入的 guid 优先
    }
    …
    return MD5.toMD5Byte((str + mac).getBytes()); // ← MD5 只是兜底
}
```

而 **`libqqdid.so`（322 KB）只出现在 8.9.50 / TIM，8.2.11 里没有** ——
它很可能就是那个"客户 guid"的来源。所以在这台设备上 MD5 公式根本没被用到。

**不过这不构成阻塞**：guid 是客户端自证身份，服务端只存不校验，
16 字节随机即可（oicq 一直这么干）。

---

### (12) 落地状态

代码已改为数据驱动的多版本档案：

* `lib/kernel/wlogin8/qq8_profiles.dart` —— `Qq8ClientProfile` + 四个档案 + `qq8DefaultProfile`
* `Qq8ApkInfo` 新增 `ssoVer` / `subSigMap` / `loginTlvOrder` /
  `tlv544DegradedBody` / `tlv553DegradedBody` / `qimeiMode`
* `qq8_tlv.dart` 新增 `case 0x544` / `case 0x545` / `case 0x553`
* `tool/qq8_profile_selftest.dart` —— **85 项**，逐版本验证差异真的落到字节上

QQ8 线测试合计 **265 项全过**，`dart analyze` 干净。

仍未从 APK 取到的字段（已在档案里用 `unverified` 显式标注，没有编造）：
`8.9.50` 的 `apkName` / `sign`，`9.3.60`/`TIM` 的 `buildtime` / `apkName` / `sign`。

---

## 6. 对实现的行动项

1. `qq8OfficialLoginTlvOrder` **不改**（37 项已与 8.2.11/8.9.50 逐项一致）。
2. **不要**按"补 10 个 TLV"的旧计划走。改为：
   * 补构造器但**保持官方条件**：`0x112`、`0x166`、`0x172`、`0x185`、`0x201`、`0x548`；
   * `0x545` 留接口，取不到 QIMEI 就跳过（官方行为）；
   * `0x544` 标为 `unavailable`，在代码里写清原因，不做假实现。
3. `0x529` / `0x318` 从 `qq8LoginTlvMissing` 移出 → 不属于 8.2.11 密码登录。
4. `_SSoVer` 保持 8.2.11 的 **7**，不要抄 8.9.50/9.3.60 的 19/22。
5. `0x400` 只在**已有票据续期**时构建，首登不构建。

## 7. 对项目路线的含义

* 8.2.11 自实现协议这条线，**上限是 oicq 级别**：能收发消息，但设备指纹与官方
  不一致，长期在线会持续承受 Tencent 的风控观察。
* 要"低风险 + 日用"，**唯一稳妥路径是 NapCat（跑官方客户端本体）**，
  本仓库的 OneBot 线就是为它准备的。
* QQ8 线的合理定位因此是：**协议研究 / 课程作业 / 离线学习**，
  而不是承载常用账号的生产客户端。

