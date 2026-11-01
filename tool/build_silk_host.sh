#!/usr/bin/env bash
# ============================================================
#  用 mingw gcc 把 vendor/silk 编成 Windows 宿主 silkcodec.dll
#  仅用于离线自测（tool/silk_codec_selftest.dart），不参与 Android 打包。
#
#  产物：build/host/silkcodec.dll
#  用法：bash tool/build_silk_host.sh
#
#  可覆盖：CC / CFLAGS 环境变量
# ============================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

CC="${CC:-gcc}"
OUT_DIR="build/host"
mkdir -p "$OUT_DIR"

SILK_DIR="vendor/silk"
OUT_DLL="$OUT_DIR/silkcodec.dll"

echo "==> 编译器: $($CC --version | head -1)"
echo "==> 源码: $SILK_DIR/src/*.c + android/app/src/main/cpp/silk_alloc.c"
echo "==> 输出: $OUT_DLL"

# 注意：只编 .c，不编 *.S（ARM 汇编）。NO_ASM=1 强制纯 C 路径
# （否则 32 位 ARM 目标会被头文件按 __ARM_ARCH_7A__ 拉进 ARM 汇编宏）。
# --export-all-symbols 让 SKP_Silk_SDK_* / get_TOC / get_version 全部导出，
# 否则 mingw 默认不导出未标 __declspec(dllexport) 的函数。
"$CC" -O3 -shared -std=gnu99 -DNO_ASM=1 -DEMBEDDED_ARM=0 \
  -I"$SILK_DIR/interface" -I"$SILK_DIR/src" \
  -Wl,--export-all-symbols \
  -Wno-unused-variable -Wno-unused-but-set-variable -Wno-unused-function -Wno-sign-compare \
  ${CFLAGS:-} \
  "$SILK_DIR"/src/*.c android/app/src/main/cpp/silk_alloc.c \
  -o "$OUT_DLL"

echo "==> 完成:" 
ls -la "$OUT_DLL"
