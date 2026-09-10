# 逆向工具链说明（含 MCP / Skills 的适用性判断）

> 结论先行：**本项目的逆向分析不需要任何 MCP 或 Skills。** 全部依赖本机命令行工具。

---

## 一、已部署的本机工具链

| 工具 | 版本 | 位置 | 用途 |
|---|---|---|---|
| jadx | 1.5.6 | `WorkBuddy/.../penguis-analysis/tools/bin/jadx` | dex → Java 反编译 |
| apktool | 3.0.3 | `penguis-analysis/tools/apktool_3.0.3.jar` | 资源解码 / smali |
| Ghidra | 12.1.3 | `penguis-analysis/tools/ghidra_12.1.3_PUBLIC/` | native `.so` 逆向 |
| adb | 1.0.41 | `penguis-analysis/tools/platform-tools/adb.exe` | 设备调试 |
| frida-tools | 17.18.0 | venv `envs/default/Scripts/frida.exe` | 运行时 hook |
| 自研脚本 | — | `penguis-analysis/*.py` | AXML 解析、dex 扫描、接口导出 |

**全部为绿色免安装版本，无需 MCP 即可直接调用。**

---

## 二、为什么不需要 MCP / Skills

### 概念区分（重要）

| | MCP / Skills | 本项目 |
|---|---|---|
| 定位 | AI 助手的**能力插件** | 独立交付的**软件产品** |
| 运行位置 | 开发机（助手侧的扩展） | 用户手机（APK 内） |
| 是否在交付物中 | ❌ 不在 | ✅ 就是交付物 |

### 逐环节判断

| 逆向环节 | 本机方案是否足够 | 需要 MCP/Skills |
|---|---|---|
| 静态分析（dex / so / 资源） | ✅ jadx + Ghidra + 自研脚本 | ❌ |
| 动态调试（hook / 断点） | ✅ frida + adb | ❌ |
| 抓包分析 | ✅ adb + 代理工具 | ❌ |
| 签名 / 证书验证 | ✅ openssl | ❌ |
| 协议字段查证 | ✅ 内置 WebSearch | ❌ |
| 批量目标并行分析 | ⚠️ 用 Agent 子代理更合适 | ❌ |
| 查询在线样本库（VT/Shodan 等） | ❌ 本机无此能力 | ✅ 需专用 MCP |
| 报告发布为在线网页 | ✅ 内置发布能力 | ❌ |

### 唯一有潜在价值的场景

如果作业需要**查询在线威胁情报库**（如 VirusTotal 哈希查询、MalwareBazaar 样本检索），
则需要接入对应的 MCP 服务。**但本作业（协议逆向 + 客户端实现）不涉及此需求。**

---

## 三、当前环境注意事项（踩坑记录）

| 问题 | 现象 | 解决方案 |
|---|---|---|
| `flutter test` 不可用 | `flutter_tester` WebSocket 连接失败 | 改用 `dart run tool/selftest.dart` |
| Gradle 下载被证书链拦截 | `PKIX path building failed` | wrapper 指向本地已缓存版本 |
| Gradle 不走系统代理 | `Could not resolve kotlin-build-tools-impl` | 见下方第 3 条 |
| 大文件下载被截断 | curl 返回不完整 zip | 一律后台下载 + `unzip -t` 校验 |
| `fileHashes.lock 拒绝访问` | 旧 daemon 占文件锁 | `taskkill /F /PID <pid>` + 删 `android/.gradle` |

> **第 3 条是关键经验**：curl 能访问不代表 Gradle 能访问。
> Gradle 是独立 JVM 进程，**不继承 shell 的 `http_proxy`/`https_proxy` 环境变量**，
> 必须通过 `systemProp.*` 显式配置。

---

## 四、最终采用的依赖获取方案：国内镜像直连

代理方案（`systemProp.*.proxyHost` 指向 `127.0.0.1`）虽然能通，但**实测极慢**
（25 分钟只下 15 MB），且代理端口随会话变化、不可复现。

**改为直接使用阿里云 Maven 镜像直连**，实测：
```bash
$ curl -sL -o tj.jar -w "size=%{size_download} time=%{time_total}s speed=%{speed_download}\n" \
    "https://maven.aliyun.com/repository/google/com/android/tools/build/gradle/8.7.3/gradle-8.7.3.jar"
size=12429787 time=0.971334s speed=12796614
```
→ **12.8 MB/s**，不需要任何代理。

`~/.gradle/gradle.properties` 已精简为：
```properties
# 走阿里云镜像直连，不配置代理（代理转发是之前的性能瓶颈）
org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=1G
org.gradle.daemon=true
org.gradle.parallel=true
org.gradle.caching=true
```

镜像地址写在项目里（`android/settings.gradle.kts`、`android/build.gradle.kts`），
不依赖全局配置，换机器也能用。

---

## 五、构建方式：交给云端

本机 Gradle 环境（JDK / SDK / 网络 / 进程锁）问题太多，最终采用
**GitHub Actions 云端构建**，本地只管写代码。详见 [`CI-BUILD.md`](CI-BUILD.md)。

这是 PiliPlus 等成熟第三方客户端项目的通行做法。

