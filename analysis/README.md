# 协议分析产物

逆向官方 QQ / TIM APK 得到的协议参数、对照结论与可复现脚本。

**这份目录存在的理由**：协议实现里的每个魔法数字都应当能追到出处。
`lib/kernel/wlogin8/` 里的注释大量引用"某文件某行"，
对应的就是这里的东西。**改协议代码前先在这里找到依据，不要凭印象调参。**

---

## 目录

```
analysis/
├── README.md                          ← 本文件
├── QQ-8.2.11-参数提取报告.md           8.2.11 的全套参数与出处
├── QQ-官方三版本登录流程对照.md        8.2.11 / 8.9.50 / 9.3.60 / TIM 四客户端对照
├── scripts/                           全部提取与核对脚本（可重跑）
├── lib/                               从 APK 里抽出的原生库（体积小，入库）
├── _decompiled/                       ⛔ 不进 git：反编译与提取产物（645 MB）
└── _device-dump/                      ⛔ 不进 git：真机取证（含账号信息）
```

`_decompiled/` 与 `_device-dump/` 已在 `.gitignore` 里排除。
它们**不是必须的**——都能按下面「如何重新生成」重建，
但重建耗时，所以留在本地供查阅。

> ⚠️ `_device-dump/` 里含**真机 TIM 的账号信息与昵称**。
> 不要把它加进 git，也不要把内容贴到公开场合。

---

## 两份文档

### `QQ-8.2.11-参数提取报告.md`

8.2.11（Play 版，versionCode 1380）的全部协议参数与逐项出处：
版本串、`qua`、`subAppId`、三个 sigmap、APK 签名证书 MD5、ECDH 公钥等。

`lib/kernel/wlogin8/qq8_config.dart` 里的常量都来自这里。

### `QQ-官方三版本登录流程对照.md`

四客户端（QQ 8.2.11 / 8.9.50 / 9.3.60 / TIM 4.1.0）的逐项对照，是 `qq8_profiles.dart`
里那张档案表的依据。关键结论：

| 主题 | 结论 |
|---|---|
| 登录 TLV 顺序表 | 8.2.11 ≡ 8.9.50（37 项）；9.3.60 ≡ TIM（38 项 = 37 + `0x553`） |
| `_SSoVer` | 7 / 19 / 22 / 22 |
| `APPKEY_DENGTA` | 8.2.11 / 8.9.50 / TIM 三者相同；但**只属于旧 Beacon** |
| QIMEI appkey | 8.9.50 起换新 SDK，appkey 是**每 app 一套**的 `0AND0*`，TIM 的不能给 QQ 用 |
| `sign`（TLV 0x142） | 三个 QQ 版本共用同一张证书；TIM 用另一张 |
| `0x544` 降级形态 | 8.2.11 = `00 00 00 00`；8.9.50+ = 空 body |
| 响应解析 | 对照官方 9.3.60 反编译逐行核实（`oicq_request.d()` / `c()`） |

文档里也记录了**三次被推翻的推断**（原文保留，没有抹掉）：
最早用"字符串池相邻关系"提取 appkey 得出错误结论，
后来正确解析 AXML 属性结构才发现三者其实一致。
**保留错误过程是有意的**——它说明"看起来对"和"验证过"是两回事。

---

## scripts/ 里有什么

按用途分三类。都是独立可跑的 Python / Node 脚本，多数需要 `pip install` 无——
只用标准库。

**提取参数**

| 脚本 | 作用 |
|---|---|
| `axml_meta.py` | 解析 `AndroidManifest.xml` 的 AXML 属性结构，取 `meta-data`（appkey、`AppSetting_params`） |
| `arsc_labels.py` | 解析 `resources.arsc` 字符串池，取资源标签 |
| `extract_versions.py` | 抽 `qua` / `fullVersion` / sdkVersion |
| `extract_sign.py` | 解析 `META-INF/*.RSA` 的 PKCS#7，算签名证书 DER 的 MD5 |
| `extract_appsetting_params.py` | 取 `AppSetting_params`（`subAppId` 的真正来源） |

**协议结构**

| 脚本 | 作用 |
|---|---|
| `find_tlv_order.py` / `find_tlv_order2.py` | 从 DEX 的 `fill-array-data` payload **头**读出登录 TLV 数组的真实长度 |
| `tim_survey.py` / `tim_survey2.py` | TIM APK 结构体检（dex / 原生库） |
| `tim_qimei_locate.py` | 定位新 QIMEI SDK（TIM 用 `com.tencent.qimei`，旧 Beacon 已移除） |
| `appkey_compare.py` | 四个 APK 的 appkey 与安全库对照 |

**原生库**

| 脚本 | 作用 |
|---|---|
| `inspect_qsec.py` | 解析 `libQSec.so` 的 ELF 段表与符号（结论：28.5 KB 无代码段的存壳） |
| `inspect_poxy.py` | 解析 `libpoxy.so` 并跨三版本对照（结论：50 KB 下载器，导入表里没有加密原语） |

---

## 如何重新生成 `_decompiled/`

需要：Java 21、[jadx 1.5.6](https://github.com/skylot/jadx)、四个 APK。

```powershell
# 1) 解出全部 dex
$apk = "QQ-com.tencent.mobileqq-play-8.2.11.apk"
python -c "import zipfile,os; z=zipfile.ZipFile(r'$apk'); os.makedirs('_decompiled/all-dex',exist_ok=True); [open(os.path.join('_decompiled/all-dex',n),'wb').write(z.read(n)) for n in z.namelist() if n.endswith('.dex')]"

# 2) jadx 反编译（按需挑 dex，全量很慢）
$jar  = "jadx-gui-1.5.6-all.jar"
$java = "java"
& $java -Xmx6g -cp $jar jadx.cli.JadxCLI `
    -d _decompiled/jadx-main --no-res -j 8 _decompiled/all-dex/classes.dex
```

各版本对应关系：

| APK | dex | 关注点 |
|---|---|---|
| 8.2.11 | `classes.dex`（登录）、`classes3.dex`（secprotocol + beacon） | `oicq/wlogin_sdk/request/k.java` |
| 8.9.50 | `classes26.dex`（登录）、`classes25.dex`（AppSetting） | `request/j.java` |
| 9.3.60 | `classes11.dex`（登录）、`classes5.dex`（响应处理） | `request/l.java`、`oicq_request` |
| TIM 4.1.0 | `classes19.dex`（登录）、`classes2.dex`（QimeiSDK） | `request/j.java` |

**为什么脚本里到处是"从 DEX payload 头读长度"这种做法**：
`fill-array-data` 载荷在数据前有 8 字节头
（`ushort ident=0x0300 | ushort width=4 | uint size`），
直接读字节就能拿到数组**真实长度**，不用靠反编译猜——
反编译输出的数组字面量经常被 jadx 拆行或截断。

---

## 已确认的坑（别重复踩）

| 现象 | 根因 |
|---|---|
| `python -c` / `node -e` 里带 `<` `>` `[` 报语法错 | PowerShell 先解析了一遍，把 `>` 当重定向。**写成文件再跑** |
| `.py` 中文输出乱码 | 控制台码页问题，输出到文件再读，或用 `unicode_escape` |
| 用 jsDelivr 读刚推的内容读到旧的 | CDN 缓存。验证远端内容**用 git**（`git show origin/main:path`） |
| `node fetch('https://github.com/...')` 报 `fetch failed` | 本机环境下 Node 的 TLS 走不通；**`curl.exe` 和 `git` 都正常** |
| 把顺序表长度当成"实际发送 TLV 数" | 官方是「超集清单 + `switch` 条件分派」，未命中的项根本不产生 |
