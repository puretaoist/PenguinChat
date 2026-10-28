set -e
# 实验包（带 TIM 官方 so/dex）：包名 com.example.qqclient.test，可与纯净包共存。
#
# 为什么这里用 gradlew 而不是 flutter build apk：
#   flutter build apk 不会把 ORG_GRADLE_PROJECT_withTimLibs 传进 Gradle 子进程
#   （实测：即使 export 了，build.gradle.kts 里 withTimLibs 仍是 false，包名不变、
#   87MB 的 so 也不进包）。而 gradlew 显式 -PwithTimLibs=true 一定生效。
#   gradlew :app:assembleDebug 本身就包含 Flutter 的 Dart 编译任务，产物与
#   flutter build apk 同路径（build/app/outputs/flutter-apk/app-debug.apk）。
cd /c/Users/Administrator/penguis/qqclient/android
export PATH="$USERPROFILE/scoop/apps/flutter/bin:$PATH"
./gradlew :app:assembleDebug -PwithTimLibs=true --console=plain 2>&1 | grep -E "qqclient\]|BUILD|error:" | tail -5
APK=/c/Users/Administrator/penguis/qqclient/build/app/outputs/flutter-apk/app-debug.apk
ls -l "$APK"
cd /c/Users/Administrator/penguis/repack
python repack4.py
BT=/c/Users/Administrator/AppData/Local/Android/Sdk/build-tools/36.0.0
rm -f app-tim-aligned.apk app-tim-signed.apk
"$BT/zipalign.exe" -f -p 4 app-tim.apk app-tim-aligned.apk
"$BT/apksigner.bat" sign --ks /c/Users/Administrator/penguis/qqclient/android/app/qqclient.p12 --ks-pass pass:qqclient123 --key-pass pass:qqclient123 --ks-key-alias qqclient --out app-tim-signed.apk app-tim-aligned.apk
"$BT/aapt2.exe" dump packagename app-tim-signed.apk
"C:/Users/Administrator/AppData/Local/Android/Sdk/platform-tools/adb.exe" install -r -d app-tim-signed.apk 2>&1 | tail -2