set -e
# 纯净包：普通 flutter build，包名 com.example.qqclient，不含任何腾讯 so/dex。
# 与 build_tim.sh 的区别只有一个 —— 不设 ORG_GRADLE_PROJECT_withTimLibs，
# 所以 jniLibs-tim 整个目录不参与打包（省 87MB），repack 也不追加 TIM dex。
cd /c/Users/Administrator/penguis/qqclient
export PATH="$USERPROFILE/scoop/apps/flutter/bin:$PATH"
flutter build apk --debug --target-platform android-arm64 2>&1 | tail -3
"C:/Users/Administrator/AppData/Local/Android/Sdk/platform-tools/adb.exe" install -r -d build/app/outputs/flutter-apk/app-debug.apk 2>&1 | tail -2