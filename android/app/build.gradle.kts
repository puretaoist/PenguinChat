import java.text.SimpleDateFormat
import java.util.Properties
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

// ---- 官方库（B 路线实验）开关（2026-10-28）--------------------------------
// 为什么要这个开关：
//   为了验证「TIM 官方 dex+native 能否在非腾讯宿主里跑起来」，我们往工程里放了
//   117 个 TIM 的 .so（87MB）。这些东西只服务那条实验路线，纯 Dart 的登录链路
//   一个都不需要 —— 但它们在模块目录里时**每次 flutter build 都会被打进包**
//   （181MB，装到用户手机上毫无必要）。
// 所以：
//   * 默认（不带属性）= **纯净包**：包名 com.puretaoist31.penguinchat，不含任何腾讯 so，
//     jniLibs 目录整个不参与打包；
//   * -PwithTimLibs=true（或环境变量 ORG_GRADLE_PROJECT_withTimLibs=true）= **实验包**：
//     包名加 .test 后缀（com.puretaoist31.penguinchat.test，可与纯净包共存），带上 jniLibs-tim。
// 为什么不走 product flavor：本仓库已有 scripts/build-local.sh 与 CI 文档里的
//   flutter build apk（不带 --flavor）。一旦定义 flavor，所有不带 --flavor 的
//   构建都会直接报错，等于把现有构建链全部打断。属性开关对现有命令零影响。
val withTimLibs: Boolean =
    (project.findProperty("withTimLibs") as String?)?.toBoolean() == true

// 把结果打进构建日志：装错包（纯净包当实验包用）时第一眼就能在 flutter build
// 的输出里看到这一行，不用去解包数 so。
logger.lifecycle("[penguinchat] withTimLibs=$withTimLibs" + if (withTimLibs) " -> com.puretaoist31.penguinchat.test" else " -> com.puretaoist31.penguinchat")

android {
    namespace = "com.puretaoist31.penguinchat"
    compileSdk = flutter.compileSdkVersion
    // NDK 用途说明（重要，别删）：
    //   本项目业务代码是纯 Dart，但 **有 C 原生代码**：SILK v3 编解码底座
    //   （vendor/silk，详见 android/app/src/main/cpp/CMakeLists.txt）会被编成
    //   libsilkcodec.so，Dart 侧用 FFI 直接调用。其余 native 需求仅来自 AGP
    //   对 Flutter 引擎自带 .so 的 strip。
    //   GitHub Actions 的 runner 预装了 NDK，这里能正常解析；
    //   本地若报 sdkmanager 下载失败，用代理装一次即可：
    //     sdkmanager --install "ndk;28.2.13676358"
    ndkVersion = flutter.ndkVersion

    // SILK 编解码底座（vendor/silk -> libsilkcodec.so）。单一 CMakeLists 同时
    // 服务列表里的每个 ABI；ABI 由 NDK toolchain 决定。
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

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
        applicationId = "com.puretaoist31.penguinchat"
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

        // 这里**不要**写 ndk { abiFilters += ... }：本工程用 apk splits（见
        // splits.abi），AGP 不允许 splits 的 abiFilters 与 defaultConfig 的
        // ndk.abiFilters 同时存在，会直接报 "Conflicting configuration ...
        // cannot be present when splits abi filters are set"。ABI 集合由
        // splits 唯一决定，CMake 会为每个 split ABI 各编一份 libsilkcodec.so。

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

        // 让日志/排障一眼看出这个包装的是哪条线（纯净包=false / 实验包=true）。
        // 注意：Kotlin 侧**不要**用 BuildConfig 去决定 loadLibrary —— 纯净包里根本没有
        // 那些 .so，多加判断只是多一条路径。这里只是标记位。
        buildConfigField("boolean", "TIM_LIBS", "$withTimLibs")
        if (withTimLibs) {
            // 实验包与纯净包必须能同时装在一台机器上：否则测一次就要卸载一次，
            // 而卸载会连带清掉 /data/data 下的票据与日志，取证很麻烦。
            applicationIdSuffix = ".test"
            versionNameSuffix = "-tim"
        }
    }

    sourceSets.getByName("main") {
        // 87MB 的腾讯 so 只在实验包里参与打包。默认构建的输出里不会出现
        // libfekit.so 等任何一个 —— 纯净包就该是纯 Flutter + 纯 Dart。
        if (withTimLibs) {
            jniLibs.srcDir("jniLibs-tim")
        }
    }

    // 统一签名（2026-09-11）：debug 与 release 共用同一把钥匙 qqclient.p12，
    // 保证任何来源（本机 / CI 任意一次构建）的 APK 都能覆盖安装上一版。
    // 背景：CI 每次跑在新 runner 上，AGP 自动生成的 debug 钥匙每次都不一样，
    // 不统一就会出现"签名不一致，无法升级安装"。
    //
    // 2026-11-01：口令**不再写死在本文件**（本文件是公开仓库内容）。取值顺序：
    //   1) android/key.properties（本机手写 / CI 由 Secrets 生成，已 gitignore）
    //   2) 环境变量 ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_PASSWORD /
    //      ANDROID_KEY_ALIAS / ANDROID_KEYSTORE_FILE
    //   3) 都没有 => 打警告并退回 AGP 默认 debug 签名（能装，但签名可能随机器变化）
    val signingProps = Properties().apply {
        val f = rootProject.file("key.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }

    fun signingValue(key: String, env: String): String? =
        (signingProps.getProperty(key) ?: System.getenv(env))?.takeIf { it.isNotBlank() }

    val storePasswordValue = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
    val keyPasswordValue = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")
    val keyAliasValue = signingValue("keyAlias", "ANDROID_KEY_ALIAS") ?: "qqclient"
    val storeFileValue = signingValue("storeFile", "ANDROID_KEYSTORE_FILE") ?: "qqclient.p12"
    val hasSigning = storePasswordValue != null && keyPasswordValue != null

    if (!hasSigning) {
        logger.warn(
            "[penguinchat] 未找到签名口令（android/key.properties 或 ANDROID_KEYSTORE_PASSWORD / " +
                "ANDROID_KEY_PASSWORD），本次构建使用 AGP 默认 debug 签名；" +
                "产物可能与上一版签名不一致，覆盖安装会失败。",
        )
    }

    signingConfigs {
        if (hasSigning) {
            create("unified") {
                storeFile = file(storeFileValue)
                storePassword = storePasswordValue
                keyAlias = keyAliasValue
                keyPassword = keyPasswordValue
            }
        }
    }

    buildTypes {
        debug {
            signingConfig =
                if (hasSigning) signingConfigs.getByName("unified") else signingConfigs.getByName("debug")
        }
        release {
            signingConfig =
                if (hasSigning) signingConfigs.getByName("unified") else signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // B 路线实验专用：只为编译期提供 oicq.wlogin_sdk 的**类签名**（不打包进 APK，
    // 真正的实现由 TIM 的 classes*.dex 提供）。缺了它 TimDataSenderBridge 无法
    // 声明与 TIM 反射查找完全一致的参数类型。
    compileOnly(files("libs/tim-stubs.jar"))
}

flutter {
    source = "../.."
}