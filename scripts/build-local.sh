#!/usr/bin/env bash
# ============================================================
#  本机构建脚本（国内网络环境）
# ------------------------------------------------------------
#  相比裸跑 flutter build apk，这里做了几件事：
#    1. 把 Maven 源切成阿里云优先（国内直连快，海外源常超时）
#    2. 检查并补齐 android/local.properties
#    3. 构建前清理可能残留的 Gradle 文件锁
#    4. 关闭 Gradle daemon，避免残留进程占锁（沙箱下杀不掉）
#
#  用法：
#     bash scripts/build-local.sh [debug|release]
# ============================================================
set -uo pipefail

MODE="${1:-debug}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "==> 项目: $PROJECT_ROOT"
echo "==> 模式: $MODE"
echo

# ---------- 1. 清理残留 Gradle 进程与文件锁 ----------
echo "==> 检查残留 Gradle/Java 进程..."
JAVA_PIDS="$(tasklist 2>/dev/null | grep -iE '^java\.exe' | awk '{print $2}')"
if [[ -n "$JAVA_PIDS" ]]; then
  echo "    发现: $(echo "$JAVA_PIDS" | tr '\n' ' ')"
  for pid in $JAVA_PIDS; do
    taskkill /F /PID "$pid" >/dev/null 2>&1 && echo "    已终止 PID $pid" || echo "    终止失败 PID $pid"
  done
else
  echo "    无残留进程"
fi

LOCK_DIR="android/.gradle"
if [[ -d "$LOCK_DIR" ]]; then
  echo "==> 清理 $LOCK_DIR"
  rm -rf "$LOCK_DIR" && echo "    已清理" || echo "    清理失败（可能仍被占用）"
fi
echo

# ---------- 2. 检查 local.properties ----------
if [[ ! -f android/local.properties ]] || ! grep -q '^flutter.sdk' android/local.properties; then
  echo "==> 生成 android/local.properties"
  FLUTTER_ROOT="$(dirname "$(dirname "$(which flutter)")")"
  ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/AppData/Local/Android/sdk}}"
  {
    echo "flutter.sdk=$FLUTTER_ROOT"
    echo "sdk.dir=$ANDROID_SDK"
  } > android/local.properties
fi
echo "==> android/local.properties:"
sed 's/^/    /' android/local.properties
echo

# ---------- 3. 切换 Maven 源为阿里云优先 ----------
# 备份原文件，构建结束后恢复
SETTINGS="android/settings.gradle.kts"
BUILDGRADLE="android/build.gradle.kts"
cp "$SETTINGS" "$SETTINGS.bak"
cp "$BUILDGRADLE" "$BUILDGRADLE.bak"

restore() {
  mv "$SETTINGS.bak" "$SETTINGS" 2>/dev/null || true
  mv "$BUILDGRADLE.bak" "$BUILDGRADLE" 2>/dev/null || true
  echo
  echo "==> 已恢复原始 Gradle 配置"
}
trap restore EXIT

echo "==> 切换为阿里云镜像优先"
python - "$SETTINGS" "$BUILDGRADLE" <<'PY'
import re, sys
for path in sys.argv[1:]:
    with open(path, encoding='utf-8') as f:
        src = f.read()
    # 把 google() / mavenCentral() / gradlePluginPortal() 行移到 aliyun 之后
    lines = src.splitlines()
    aliyun, others = [], []
    for ln in lines:
        s = ln.strip()
        if 'maven.aliyun.com' in s:
            aliyun.append(ln)
        elif s in ('google()', 'mavenCentral()', 'gradlePluginPortal()'):
            others.append(ln)
    if not aliyun:
        continue
    # 重新组装 repositories 块
    indent = ' ' * (len(aliyun[0]) - len(aliyun[0].lstrip()) or 8)
    block = [indent + '// 国内镜像优先（本地构建）'] + aliyun + others
    start = end = None
    for i, ln in enumerate(lines):
        if 'repositories {' in ln:
            start = i
        elif start is not None and ln.strip() == '}':
            end = i
            break
    if start is None or end is None:
        continue
    new = lines[:start + 1] + block + lines[end:]
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(new) + '\n')
    print(f'    已改写 {path}')
PY
echo

# ---------- 4. 构建 ----------
case "$MODE" in
  release)
    echo "==> flutter build apk --release --split-per-abi"
    flutter build apk --release --split-per-abi
    ;;
  *)
    echo "==> flutter build apk --debug"
    flutter build apk --debug
    ;;
esac
STATUS=$?

echo
echo "==> 退出码: $STATUS"
if [[ $STATUS -eq 0 ]]; then
  ls -la build/app/outputs/flutter-apk/*.apk 2>/dev/null
fi
exit $STATUS
