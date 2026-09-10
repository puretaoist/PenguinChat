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

三种触发方式（已在 `.github/workflows/build.yml` 配置）：

| 方式 | 说明 |
|---|---|
| **push 到 main/master** | 自动构建 **debug** APK |
| **手动触发** | Actions 页面 → `build` → `Run workflow`，可选 `debug` / `release` |
| **打 tag** | `git tag v0.1.0 && git push origin v0.1.0` → 构建 release 并自动创建 Release 附件 |

## 四、取回 APK

构建完成后（约 5–10 分钟）：

1. 打开 `https://github.com/<用户名>/<仓库名>/actions`
2. 点进最新的 run
3. 页面底部 **Artifacts** 区域下载 `apk-<commit hash>.zip`
4. 解压得到 `app-debug.apk`，传到手机安装即可

如果用 tag 触发，APK 会直接挂在 **Releases** 页面，下载更方便。

---

## 工作流做了什么

`.github/workflows/build.yml` 的步骤（共 15 步）：

1. `actions/checkout` 拉代码
2. `actions/setup-java` 装 JDK 17
3. `subosito/flutter-action` 装 Flutter stable 并开启缓存
4. `flutter doctor -v` 打印环境
5. `flutter pub get` 拉 Dart 依赖
6. `flutter analyze` 静态检查（失败不阻断）
7. `dart run tool/selftest.dart` **协议自检**（TLV / TEA，19 项）
8. `flutter test` 标准单测（失败不阻断）
9. **动态生成 `android/local.properties`** ← 关键，见下
10. **确保 NDK 存在**（避免构建中途触发下载）
11. `gradle/actions/setup-gradle` 开启 Gradle 缓存
12. `flutter build apk --debug` 打包
13. `actions/upload-artifact` 上传产物
14. `softprops/action-gh-release`（仅打 tag 时附到 Release）

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
