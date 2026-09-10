# 云端构建（GitHub Actions）

> 思路参考 PiliPlus 等第三方客户端项目：**本地只负责写代码，编译交给云端**。
> 好处是彻底绕开本机的 JDK / Android SDK / Gradle / 网络代理环境问题，
> 而且每次构建环境一致、可复现。

---

## 为什么走这条路

本机构建踩到的问题（已解决，但值得记录）：

| 问题 | 根因 | 处理 |
|---|---|---|
| 依赖下载极慢（25 分钟 15 MB） | Gradle 是独立 JVM 进程，**不继承 shell 的 `http_proxy` 环境变量** | 改用阿里云 Maven 镜像直连（实测 12.8 MB/s） |
| `fileHashes.lock 拒绝访问` | 旧 Gradle daemon 残留进程占着文件锁，沙箱下杀不掉 | 用 `taskkill /F` 强杀 + 删除 `android/.gradle` |
| `PKIX path building failed` | gradle-wrapper 走 HTTPS 下载时证书链校验失败 | wrapper 指向本地已缓存的分发版本 |
| 构建耗时 73 分钟仍失败 | 上述问题叠加 | — |

云端构建没有这些问题：环境干净、直连官方源、无残留进程。

---

## 一、准备仓库

在 GitHub 网页上创建一个**空仓库**（不要勾选 "Add a README" / ".gitignore" / "license"），
假设用户名为 `puretaoist`，仓库名为 `qqclient`。

## 二、推送代码

```bash
cd C:/Users/Administrator/penguis/qqclient
bash scripts/push-to-github.sh puretaoist qqclient
```

脚本会自动完成：`git init` → 确认 `local.properties` 被忽略 → 提交 → 添加 remote → 推送。

> **关于认证**：HTTPS 推送需要 Personal Access Token（GitHub → Settings → Developer settings
> → Personal access tokens → 勾选 `repo` + `workflow` 权限）。
> 也可以用 SSH key，把 remote 换成 `git@github.com:...` 即可。
>
> ⚠️ PAT 属于凭据，请自己保管，**不要写进任何提交的文件里**。

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

`.github/workflows/build.yml` 的步骤：

1. `actions/checkout` 拉代码
2. `actions/setup-java` 装 JDK 17
3. `subosito/flutter-action` 装 Flutter stable 并开启缓存
4. `flutter pub get` 拉 Dart 依赖
5. `flutter analyze` 静态检查（失败不阻断）
6. `dart run tool/selftest.dart` **协议自检**（TLV / TEA 编解码，19 项）
7. `flutter test` 标准单测（失败不阻断）
8. **动态生成 `android/local.properties`** ← 关键步骤，见下
9. `gradle/actions/setup-gradle` 开启 Gradle 缓存
10. `flutter build apk` 打包
11. `actions/upload-artifact` 上传产物

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
