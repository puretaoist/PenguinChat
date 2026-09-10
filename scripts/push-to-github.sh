#!/usr/bin/env bash
# ============================================================
#  一键把 qqclient 推送到 GitHub，交给 Actions 云端构建 APK
# ------------------------------------------------------------
#  用法：
#     bash scripts/push-to-github.sh <你的GitHub用户名> [仓库名]
#  例：
#     bash scripts/push-to-github.sh puretaoist qqclient
#
#  前置：
#     1) 已在 GitHub 网页上创建好空仓库（不要勾选 README / .gitignore）
#     2) git 已登录（HTTPS 需要 PAT，或用 SSH key）
# ============================================================
set -euo pipefail

GH_USER="${1:-}"
REPO_NAME="${2:-qqclient}"

if [[ -z "$GH_USER" ]]; then
  echo "用法: bash scripts/push-to-github.sh <GitHub用户名> [仓库名]"
  exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "==> 项目目录: $PROJECT_ROOT"
echo "==> 目标仓库: https://github.com/${GH_USER}/${REPO_NAME}.git"
echo

# ---------- 1. 初始化 git ----------
if [[ ! -d .git ]]; then
  echo "==> 初始化 git 仓库"
  git init -b main
else
  echo "==> 已存在 .git，跳过初始化"
fi

# ---------- 2. 确认忽略规则生效 ----------
# local.properties 含本机绝对路径，绝不能入库
if [[ -f android/local.properties ]]; then
  if git check-ignore -q android/local.properties; then
    echo "==> OK: android/local.properties 已被忽略"
  else
    echo "!! 警告: android/local.properties 未被忽略，已自动追加规则"
    echo "/android/local.properties" >> .gitignore
  fi
fi

# ---------- 3. 提交 ----------
git add -A
if git diff --cached --quiet; then
  echo "==> 无新改动，跳过提交"
else
  git commit -m "feat: QQ 协议客户端骨架（Flutter + Telegram 风格 UI）

- infra: 小端字节读写器 (coder.dart)
- kernel/wlogin: TLV 编解码 + 26 个已知字段常量
- kernel/crypto: TEA / XXTEA（16 轮，delta=0x9E3779B9）
- client_api: Chat / ChatMessage 不可变对象
- ui: Telegram 风格主题、头像、消息气泡、三栏自适应首页
- tool/selftest.dart: 纯 Dart 协议自检（19 项）
- CI: GitHub Actions 自动构建 APK"
fi

# ---------- 4. 推送 ----------
git remote remove origin 2>/dev/null || true
git remote add origin "https://github.com/${GH_USER}/${REPO_NAME}.git"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "==> 推送到 origin/$CURRENT_BRANCH ..."
git push -u origin "$CURRENT_BRANCH"

echo
echo "============================================================"
echo " 推送完成！接下来："
echo
echo " 1. 打开 Actions 页面查看构建进度："
echo "    https://github.com/${GH_USER}/${REPO_NAME}/actions"
echo
echo " 2. 构建约需 5-10 分钟（首次会下载 Flutter SDK + Gradle 依赖）"
echo
echo " 3. 构建成功后，在对应 run 的页面底部 Artifacts 区域"
echo "    下载 apk-xxxx.zip，解压即得 app-debug.apk"
echo
echo " 4. （可选）打 tag 会自动创建 Release 并附上 APK："
echo "    git tag v0.1.0 && git push origin v0.1.0"
echo "============================================================"
