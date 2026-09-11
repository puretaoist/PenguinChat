# 已踩过的坑

> 每条都是**真踩过**的，不是预防性建议。格式：
> **现象 → 根因 → 处理**。
>
> 读一遍能省你几小时。有些坑的现象离根因很远（比如"尾部校验失败"
> 其实是分组链模式写错了），不知道的话基本查不出来。

---

## A. 测试与时序

### A1. 连用两次 `stream.first` 会漏事件

**现象**：本地连跑 15 次挂 1 次；CI 上第一次就挂。断言是"第二个事件为 null"。

**根因**：

```dart
final a = await waitFor(stream.where((e) => 条件A), 2s);  // 内部是 .first
final b = await waitFor(stream.where((e) => 条件B), 2s);
```

`waitFor` 是**先订阅、再等下一个匹配事件**。两条事件背靠背到达时，
第二次订阅错过已经过去的那个。

**处理**：先订阅收集，再等条件。

```dart
final got = <T>[];
final sub = stream.listen(got.add);
try {
  ...推事件...
  await waitUntil(() => got.any(条件A) && got.any(条件B));
} finally {
  await sub.cancel();
}
```

`waitUntil` 的实现见 `tool/onebot_selftest.dart`。

**教训**：本机大概率不复现的竞态，在 CI 上近乎必然。不要用"本地跑十次都过"
来判断测试是否稳定。

### A2. 固定 `sleep` 后断言"某事已经发生"

**现象**：`await sleep(600); check('已重连', connectCount > before)` 在 CI 上挂。

**根因**：CI 机器比本机慢，600ms 里重连未必来得及完成。

**处理**：改成等条件。

```dart
final ok = await waitUntil(() => server.connectCount > before,
    timeout: const Duration(seconds: 5));
```

⚠️ 但**断言"某事没有发生"时**（如"关闭码 1000 不触发重连"），
固定 sleep 是无法避免的——只能靠拉长窗口增加置信度，并接受它天然较弱。

### A3. `exitCode = N` 不会让进程退出

**现象**：自测跑完打印了结果，然后**一直挂着**，CI 卡到超时。

**根因**：脚本里 bind 了 `ServerSocket`。只要还有句柄没关，
Dart 事件循环就不会结束，`exitCode` 只是设了个值。

**处理**：用 `exit(failed == 0 ? 0 : 1)`。它会立刻终止进程。

### A4. 「未处理的异步错误」会打挂进程

**现象**：自测莫名退出，没有失败的断言，只有一个 `Unhandled exception`。

**根因**：

```dart
final pending = client.call('never');   // 之后会以错误完成
...
await dropAll();                        // ← 在这之前 pending 就已拒绝
try { await pending; } on X catch (e) {} // ← 订阅挂晚了
```

Future 以错误完成而当时没有监听者时，Dart 会把错误抛到根 zone。

**处理**：拿到 Future 就**立刻**挂上错误处理，哪怕只是转发。

```dart
final guarded = pending.then<Object?>((v) => v).catchError((Object e) => e);
...
final result = await guarded;
```

---

## B. Dart / I/O

### B1. `IOSink.flush()` 在并发下同步抛 `StateError`

**现象**：日志出口只写了一行就再也不写了，而且**没有任何报错**。

**根因**：`IOSink.flush()` 在上一次 flush 未完成时会**同步抛**
`StateError: StreamSink is bound to a stream`。日志写入频率不可控，
一旦踩到这个异常落进 `write` 的 catch，整个出口就被打成 disabled——
**日志静默失效**。

**处理**：日志落盘改用 `RandomAccessFile`（`writeStringSync` / `flushSync`），
没有异步状态机，并发调用不会进入未定义状态。见 `lib/infra/log/log_file.dart`。

### B2. PowerShell 5.1 按 GBK 读 UTF-8 脚本

**现象**：`powershell -File xx.ps1` 报一堆
`The string is missing the terminator` / `Missing closing '}'`，
但语法检查能过。

**根因**：Windows PowerShell 5.1 默认按系统 ANSI 码页读 `.ps1`，
文件里的中文被拆坏，引号配对随之失效。

**处理**：写 BOM，或用 `pwsh`（PowerShell 7，默认 UTF-8）执行。

```powershell
$c = Get-Content -Raw -Encoding UTF8 $p
[System.IO.File]::WriteAllText($p, $c, (New-Object System.Text.UTF8Encoding $true))
```

### B3. PowerShell 会吃掉 `<` `>` `[` 和嵌套引号

**现象**：`node -e "..."` / `python -c "..."` 里带 `=>`、`[..]`、多层引号时，
报 `Missing type name after '['`、`The module 'xxx' could not be loaded`。

**根因**：PowerShell 先解析一遍，把 `>` 当成重定向、`[` 当成类型字面量起点。

**处理**：**把脚本写成文件再执行**，不要用 `-e` / `-c` 塞大段代码。
短命令用单引号包裹（PowerShell 单引号内不做展开）。

### B4. 多层引号穿过 `adb shell` → `su` 会被吃掉

**现象**：`adb shell "su -c 'ls /data/...'"` 执行结果莫名其妙，
或者 `$p` 变成空字符串。

**处理**：把要在设备上跑的东西**写成 `.sh` 推上去执行**：

```powershell
& $adb push script.sh /data/local/tmp/script.sh
& $adb shell "su -c 'sh /data/local/tmp/script.sh'"
```

---

## C. 协议实现（最贵的几个）

### C1. TEA 的分组链不是标准 CBC

**现象**：TEA 自测往返通过，但**任何一个真实的 oicq 密文都解不开**，
报错是 `FormatException: 尾部校验失败`。

**根因**：QQ 的 TEA 用**变体分组链**，不是标准 CBC：

```
标准 CBC:  C_i = E(P_i ⊕ C_{i-1})
QQ 变体:   B_i = P_i ⊕ C_{i-1}
           C_i = E(B_i) ⊕ B_{i-1}      ← 多异或一个 B_{i-1}
```

**处理**：见 `lib/kernel/crypto/tea.dart` 文件头注释。
**往返测试抓不到这个**——自己加密自己解密，两种模式都能过。
只有对参考实现的真实密文才能暴露它。

**教训**：对称算法的往返测试**证明不了互操作性**。

### C2. 长度前缀有的是"含自身"，有的是"裸长度"

**现象**：服务端返回一个含糊的登录失败码，无论怎么调 TLV 都不对。

**根因**：本协议里 `tgt` / `cmd` / `session_id` / `imei` / `d2` / `uin`
用的是**长度含自身 4 字节**的写法（`writeU32(len + 4)`），
而 `ByteWriter.bytes32` 写的是**裸长度**。混用不会报错，只是登不上。

**处理**：`lib/kernel/wlogin8/qq8_sso.dart` 里的 `_withLength()` helper 是
**唯一**的写入点，不要绕过它手写。

### C3. 别"顺手优化"看不懂的字段

**现象**：删掉一个看起来没用的常量字段后，登录开始静默失败。

**根因**：协议里存在大量"含义不明但服务端会校验"的字段。例如
`qq8BufUnknown`（12 字节常量），改了大概率登不上，**而且报错信息不会指向这里**。

**处理**：`lib/kernel/wlogin8/qq8_sso.dart` 里已经写了警告注释。
新增字段时同样：不知道含义就照抄，并注明"含义未明，不要动"。

### C4. 同一个字段号在不同版本含义不同

**现象**：8.2.11 的代码拿去按 8.9.50 的参数发，参数看着都对但登不上。

**根因**：`0x545`（QIMEI）在 8.2.11 是 `MD5(qimei字符串)`（16 字节），
8.9.50 起变成**原文**。`_SSoVer` 也从 7 → 19 → 22。

**处理**：`lib/kernel/wlogin8/qq8_profiles.dart` 把版本差异**全部数据化**。
不要写 `if (版本 == xxx)` 分支，加/改档案里的字段。

### C5. 「body 为空」不等于「不发这个 TLV」

**现象**：按"空 body 就跳过"的规则过滤 TLV，结果 8.9.50 登不上。

**根因**：`0x544` 在 8.9.50 上**合法的 body 就是空的**
（安全 SDK 不可用时 `liteSign` 初值是 `new byte[0]`）。
用"空就跳过"会把它误删。

**处理**：`Qq8LoginConditions.applies(tag)` 显式建模每个 TLV 的准入条件，
逐条对应官方 `k.java` / `j.java` 的 guard。

### C6. 首登时某些 TLV 官方是整条跳过的

**现象**：多发了一个 TLV 导致失败，但少发那个又不对。

**根因**：`0x104`（口令盐缓存）和 `0x400`（票据续期）在**首次登录时官方不产出**：

```java
// 8.9.50 j.java:157
case tlv_t104.CMD_104 /* 260 */:
    if (bArr8 == null || bArr8.length == 0) { /* 什么都不产出 */ }
    else bArr11 = new tlv_t104().get_tlv_104(bArr8);
```

**处理**：同上，用 `Qq8LoginConditions` 的字段控制（`t104: null` / `hasSig: false`）。

---

## D. 网络与环境

### D1. `github.com` / `api.github.com` 在 node 里 `fetch failed`，但 git 和 curl 正常

**现象**：`fetch('https://github.com/...')` 报 `fetch failed`，
但 `git ls-remote` 和 `curl.exe` 都能通。

**根因**：本机环境下 Node 的 TLS/SNI 走不通，不是网络被墙。

**处理**：
- 取 GitHub 数据用 `curl.exe`（PowerShell 里直接调）
- 取仓库**文件内容**可以用 jsDelivr CDN：
  `https://cdn.jsdelivr.net/gh/<owner>/<repo>@<branch>/<path>`

### D2. jsDelivr 有缓存，刚推的内容看不到

**现象**：明明 push 成功了，CDN 上读到的还是旧内容。

**根因**：jsDelivr 对 gh 资源缓存时间较长。

**处理**：验证远端内容用 **git**，不要用 CDN：

```bash
git fetch origin
git show origin/main:LICENSE | head
```

### D3. 本机 `dart.bat` / `flutter.bat` 会卡住

**现象**：调用 `dart run ...` 长时间无输出。

**根因**：包装脚本在 Flutter SDK bootstrap 阶段挂起。

**处理**：直接用真正的可执行文件。

```powershell
$dart = "$env:USERPROFILE\scoop\apps\flutter\bin\cache\dart-sdk\bin\dart.exe"
& $dart run tool/xxx_selftest.dart
```

### D4. Android 上 `adb shell su` 不存在（KernelSU）

**现象**：`su: inaccessible or not found`，但设备明明有 root。

**根因**：KernelSU 默认不把 `su` 暴露给 adb shell。
`/system/bin/su` 也不存在（`/data/adb` 是 0700，shell 进不去）。

**处理**：KernelSU 设置里打开两个开关：

| 中文界面 | 英文界面 | resource key |
|---|---|---|
| 总是给 shell 授予 root 权限 | `ADB Root` | `settings_adb_root` |
| 传统 su 命令支持 | `Classic SU` | `settings_sucompat` |

（开关名是从 manager APK 的 `resources.arsc` 里挖出来的，不是猜的。）

### D5. 生产构建的 `adb root` 不可用

`ro.debuggable=0` / `ro.build.type=user` 时 `adb root` 必然报
`adbd cannot run as root in production builds`。别在这上面浪费时间。

---

## E. 工程流程

### E1. 本地与远端「没有共同历史」

**现象**：`git push` 被拒 `non-fast-forward`，但
`git log HEAD..origin/main` 只显示一个 `Initial commit`，
且 `git merge-base` 输出为空。

**根因**：本地是单独 `git init` 的，远端那个 `Initial commit`
（建仓时自动生成，通常只有 LICENSE）与本地历史**无关**。

**处理**：`git merge origin/main --allow-unrelated-histories`，
**不要**直接 force push——那会丢掉远端已有的文件。

### E2. CI 失败但拿不到日志

**现象**：Actions 日志下载返回 `403 Must have admin rights to Repository`。

**处理**：工作流里 emit 的 `::error file=X::` 会进 **check-run annotations**，
而 annotations 是**公开可读**的，足够定位到失败的文件：

```powershell
curl.exe -s -H "User-Agent: dsh" `
  "https://api.github.com/repos/<owner>/<repo>/check-runs/<job_id>/annotations"
```

`job_id` 从 `/actions/runs/<run_id>/jobs` 拿。

**建议**：在 CI 里给每个可能失败的步骤都 emit 带文件名的 `::error`，
这样失败时不用下日志就能定位。

### E3. `.md` 改动不触发 CI

工作流里有 `paths-ignore: ["**.md", "docs/**"]`。
**只改文档不会触发构建**——这是刻意的（省 CI 时间），
但别因此以为"推了没反应是坏了"。
