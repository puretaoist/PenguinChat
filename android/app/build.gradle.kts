plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

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
