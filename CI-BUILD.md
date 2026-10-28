# 云端构建（GitHub Actions）

> 思路参考 PiliPlus 等第三方客户端项目：**本地只负责写代码，编译交给云端**。
> 好处是彻底绕开本机的 JDK / Android SDK / Gradle / 网络代理环境问题，
> 而且每次构建环境一致、可复现。

**仓库地址**：https://github.com/puretaoist/PenguinChat
**当前状态**：代码已推送（48 文件），CI 已就绪，推送到 main 即自动构建。

---

## 为什么走这条路

本机构建踩到的坑（诊断记录，供后续参考）：

| 问题 | 根因 | 处理 |
|---|---|---|
| 依赖下载极慢（25 分钟 15 MB） | 宿主设了 `HTTP_PROXY/HTTPS_PROXY=127.0.0.1:59518`，**Gradle daemon 会继承这些变量**，Maven 流量全走慢代理 | `~/.gradle/gradle.properties` 里把 `systemProp.http.proxyHost=` 置空 + `nonProxyHosts=*` |
| `fileHashes.lock 拒绝访问` | 旧 Gradle daemon 残留进程占文件锁 | `taskkill /F /PID <pid>` + 删 `android/.gradle` |
| `PKIX path building failed` | gradle-wrapper HTTPS 下载证书链校验失败 | wrapper 指向本地已缓存分发版本 |
| **构建卡死 10 分钟无输出** | Flutter Gradle 插件调 `forceNdkDownload()` → `sdkmanager --install ndk;28.2.13676358` 从 `dl.google.com` 拉 ~1GB | 见下方「NDK 问题」 |
| `dl.google.com` 直连 **Connection reset** | 网络对 Google 域直连做了重置 | NDK/Google 系必须走代理，**不能一刀切去代理** |
| 阿里云镜像直连 | 实测 **12.8–13.5 MB/s** | Maven 依赖走阿里云，绕过代理 |

### NDK 问题（最隐蔽的一个）

项目**没有任何 C/C++ 源码**，但仍需要 NDK：

```
Flutter 自带的空 CMakeLists.txt 原文注释：
# Empty file to trick the Android Gradle Plugin to download the NDK. This is because
# AGP requires the NDK in order to strip debug symbols from native libraries, ...
```

即：AGP 需要 NDK 来 **strip Flutter 引擎自带 .so 的调试符号**，不是用来编译。
Flutter 的 `FlutterPluginUtils.forceNdkDownload()` 检测到 NDK 缺失就现场用 `sdkmanager` 下载，
而这一步走 `dl.google.com`，在国内网络下必然卡死。

**在 CI 上这不是问题**——GitHub runner 预装了 NDK，工作流里还有一步显式确保版本存在。

---

## 一、仓库

已创建：`https://github.com/puretaoist/PenguinChat`（**私有仓库**）

## 二、推送代码

代码已在仓库里。后续改动：

```bash
cd C:/Users/Administrator/penguis/qqclient
git add -A
git commit -m "feat: xxx"
git push origin main
```

> 首次推送可用 `bash scripts/push-to-github.sh <用户名> <仓库名>` 一键完成初始化。
>
> **认证**：HTTPS 推送需要 Personal Access Token（Settings → Developer settings →
> Personal access tokens，勾选 `repo` + `workflow`）。
>
> ⚠️ PAT 属凭据，**不要写进任何提交的文件里**。

## 三、触发构建

两种触发方式（已在 `.github/workflows/build.yml` 配置）：

| 方式 | 说明 |
|---|---|
| **push 到 main/master** | 自动构建 **debug** APK |
| **手动触发** | Actions 页面 → `build` → `Run workflow`，可选 `debug` / `release` |

> 打 tag **不再**触发构建，也不会发布 GitHub Release（2026-09-11 决定，
> 产物只走 Actions artifact，见下节）。

## 四、取回 APK

构建完成后（约 5–10 分钟）：

1. 打开 `https://github.com/<用户名>/<仓库名>/actions`
2. 点进最新的 run
3. 页面底部 **Artifacts** 区域下载 `apk-<commit hash>.zip`
4. 解压得到 `app-debug.apk`，传到手机安装即可

要体积小的 release 包，用**手动触发选 `release`**（实测 17.8MB；
debug 是 44.7MB，差距在 debug 引擎 + JIT）。

所有产物由**统一签名**（`android/app/qqclient.p12`，见
`android/app/build.gradle.kts` 的 `signingConfigs.unified`）——
debug / release、本机 / CI，任意两次构建都能互相覆盖安装。
这是刻意的：CI 每次跑在新 runner 上，不统一的话签名每次都不一样，
手机升级安装会报"签名不一致"。

---
## 两种包：纯净包 与 实验包（带官方库）2026-10-28 起，本工程能出**两个可共存的包**：| | 纯净包（默认） | 实验包（B 路线） || --- | --- | --- || 包名 | `com.example.qqclient` | `com.example.qqclient.test` || 构建命令 | `flutter build apk --debug --target-platform android-arm64` | `cd android && ./gradlew :app:assembleDebug -PwithTimLibs=true`，再 `python ../repack/repack4.py` + `zipalign` + `apksigner`（即 `bash repack/build_tim.sh`） || 官方 .so | 无 | 127 个（`android/app/jniLibs-tim/arm64-v8a/`，87MB 原始） || dex 数 | 12（纯 Flutter） | 36（12 + TIM 24，由 repack4.py 追加） || 产物 | `build/app/outputs/flutter-apk/app-debug.apk` | `repack/app-tim-signed.apk` |为什么要分开：TIM 那 117 个 .so / 24 个 dex 只服务「官方栈能否在非腾讯宿主里跑」这条实验路线（见 `docs/PITFALLS.md` C49/C52），**纯 Dart 的登录链路一个都不需要**。把 87MB 打进用户装的包里没有任何收益，还会让「这个 App 到底用了多少腾讯代码」说不清楚。⚠️ **`flutter build apk` 不会把 `ORG_GRADLE_PROJECT_withTimLibs` 传进 Gradle 子进程**（实测：`export` 之后 `withTimLibs` 仍是 false，包名不变、so 也不进包）。所以实验包必须走 `./gradlew ... -PwithTimLibs=true`，不要去给 `flutter build` 加环境变量。构建日志里会打一行 `[qqclient] withTimLibs=... -> <包名>`，装错包时先看这一行。实验包与纯净包签名相同但包名不同，所以**可以同时装在一台手机上**——这一点很关键：卸载会连带清掉 `/data/data/<pkg>` 下的登录票据与日志，测一次卸一次等于每次都要重新取证。---
## 工作流做了什么

`.github/workflows/build.yml` 的步骤：

1. `actions/checkout` 拉代码
2. `actions/setup-java` 装 JDK 17
3. `subosito/flutter-action` 装 Flutter stable 并开启缓存
4. `flutter doctor -v` 打印环境
5. `flutter pub get` 拉 Dart 依赖
6. `flutter analyze` 静态检查（失败不阻断）
7. 全部纯 Dart 自检（`tool/*_selftest.dart` 通配遍历 + `tea_compat_check` / `selftest`）
8. `flutter test` 标准单测（失败不阻断）
9. 登录组包 dry-run（`qq8_live_smoke.dart`，不联网）
10. **动态生成 `android/local.properties`** ← 关键，见下
11. **确保 NDK 存在**（避免构建中途触发下载）
12. `gradle/actions/setup-gradle` 开启 Gradle 缓存
13. `flutter build apk --debug --target-platform android-arm64` 打包
    （**只出 arm64-v8a**，artifact 实测 44.7MB；此前 3-ABI fat 包 68.8MB。
    手动触发选 release 时走 `--release`，实测 17.8MB）
14. `actions/upload-artifact` 上传产物（不发布 Release）

### 关键工程点：`local.properties`

Flutter 的 Gradle 插件从 `android/local.properties` 读取 `flutter.sdk` 路径：

```kotlin
// android/settings.gradle.kts
file("local.properties").inputStream().use { properties.load(it) }
val flutterSdkPath = properties.getProperty("flutter.sdk")
require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
```

这个文件里是**本机绝对路径**，不能提交到仓库（不同机器路径不同，且 `android/.gitignore`
默认就忽略它）。所以在 CI 上必须动态生成：

```bash
FLUTTER_ROOT="$(dirname "$(dirname "$(which flutter)")")"
echo "flutter.sdk=$FLUTTER_ROOT" > android/local.properties
echo "sdk.dir=$ANDROID_SDK_ROOT" >> android/local.properties
```

## Maven 仓库顺序

`android/settings.gradle.kts` 与 `android/build.gradle.kts` 里的源顺序是**按运行环境**排的：

- **CI（海外机器）**：`google()` / `mavenCentral()` 在前，阿里云兜底
- **本机（国内）**：把三行 `maven.aliyun.com` 提到 `google()` 之前

两边都留着，切换时只需要调换行序。

---

## 后续里程碑在 CI 上的表现

| 里程碑 | 内容 | CI 影响 |
|---|---|---|
| M1 ✅ | 骨架 + TLV + TEA | 当前，可打包 |
| M2 | 逆向 `WtloginHelper`，实现登录 TLV 序列 | 无需改 CI |
| M3 | MSF 长连接 + 心跳 | 无需改 CI |
| M4 | 会话列表 + 消息收发 | 无需改 CI |
| M5 | Rust 内核（`flutter_rust_bridge`） | **需加 `rustup` + `cargo-ndk` 步骤**，并在 `build.gradle.kts` 里挂 cargo 任务 |
| M6 | 报告 + 演示 | 无需改 CI |
