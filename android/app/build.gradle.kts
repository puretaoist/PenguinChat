import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---- 构建标识（2026-10-23）------------------------------------------------
// 为什么需要：曾经连续 4 个提交都没有改过设备采集的硬编码 `BUILD_TAG`，
// 结果真机日志里那一行长得一模一样，无法判断装的是哪一版 APK —— 只好解包
// APK 翻 dex 才确认是旧包，那次排查本可以省掉。
// 所以这里把 **git 提交** 和 **构建时刻** 一起注入 BuildConfig，
// 每个提交都会变，日志里一眼可辨。
//
// `--dirty` 很重要：工作区有未提交改动时，光看 commit 会以为装的是那一版
// 干净的代码，实际混了本地修改。宁可标注出来也不要误导。
// 拿不到 git（比如源码压缩包、CI 用浅克隆且没装 git）时退化成 unknown，
// 不能让构建失败 —— 构建标识是排障辅助，不是构建前提。
val gitCommit: String =
    runCatching {
            providers
                .exec {
                    workingDir = rootDir.parentFile
                    commandLine("git", "rev-parse", "--short=7", "--dirty=+dirty", "HEAD")
                }.standardOutput.asText.get().trim()
        }
        .getOrNull()
        ?.takeIf { it.isNotEmpty() }
        ?: "unknown"

val buildTime: String = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).format(Date())

android {
    namespace = "com.example.qqclient"
    compileSdk = flutter.compileSdkVersion
    // NDK 用途说明（重要，别删）：
    //   本项目是纯 Dart 实现，没有任何 C/C++ 源码，**不需要编译 native 代码**。
    //   但 Flutter Gradle 插件会调用 forceNdkDownload()，因为 AGP 需要 NDK
    //   来 strip 掉 Flutter 引擎自带 .so 的调试符号。
    //   所以 NDK 是必需的。
    //   GitHub Actions 的 runner 预装了 NDK，这里能正常解析；
    //   本地若报 sdkmanager 下载失败，用代理装一次即可：
    //     sdkmanager --install "ndk;28.2.13676358"
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // AGP 8 起 BuildConfig 默认关闭，必须显式打开，否则下面的字段无处可放。
    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.qqclient"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 三个字段都用 BuildConfigField 注入：Kotlin 侧读 `BuildConfig.XXX`，
        // 再经 MethodChannel 交给 Dart。**不写进 versionName**——那会让
        // 安装包版本号每次构建都不同，覆盖安装与版本比较都会乱。
        //
        // APP_VERSION 例外地**保持**是 pubspec 的 version：它就是用户装的那个
        // 「0.1.0+1」，报障时最容易对上。构建次数与提交号走下面两行。
        buildConfigField(
            "String",
            "APP_VERSION",
            "\"${flutter.versionName}+${flutter.versionCode}\"",
        )
        buildConfigField("String", "GIT_COMMIT", "\"$gitCommit\"")
        buildConfigField("String", "BUILD_TIME", "\"$buildTime\"")
        buildConfigField(
            "String",
            "API_HOST",
            "\"${project.findProperty("qq8ApiHost") ?: "msfwifi.3g.qq.com"}\"",
        )
        // dry-run 长驻主机的调试地址（一般留空）。给模拟器/抓包用。
        buildConfigField(
            "String",
            "API_HOST_OVERRIDE",
            "\"${project.findProperty("qq8ApiHostOverride") ?: ""}\"",
        )
    }

    // 统一签名（2026-09-11）：debug 与 release 共用同一把钥匙 qqclient.p12，
    // 保证任何来源（本机 / CI 任意一次构建）的 APK 都能覆盖安装上一版。
    // 背景：CI 每次跑在新 runner 上，AGP 自动生成的 debug 钥匙每次都不一样，
    // 不统一就会出现"签名不一致，无法升级安装"。
    // 注意：这把钥匙与口令是**故意公开**的（课程项目，不做商店分发）；
    // 真上架前必须换正式签名并改用密钥管理，不得沿用这里的口令。
    signingConfigs {
        create("unified") {
            storeFile = file("qqclient.p12")
            storePassword = "qqclient123"
            keyAlias = "qqclient"
            keyPassword = "qqclient123"
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("unified")
        }
        release {
            signingConfig = signingConfigs.getByName("unified")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
