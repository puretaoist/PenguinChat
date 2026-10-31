#!/bin/bash
# 跑完 tool/*_selftest.dart 全量自测，只汇总 pass/fail（原先散在 tmp/st_loop.sh，tmp 清理后落库）
cd "$(dirname "$0")/.." || exit 1
D="C:/Users/Administrator/scoop/apps/flutter/bin/cache/dart-sdk/bin/dart.exe"
pass=0; fail=0
for f in tool/*_selftest.dart; do
  if out=$("$D" run "$f" 2>&1); then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL $f"; echo "$out" | tail -8
  fi
done
echo "SELFTESTS pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
