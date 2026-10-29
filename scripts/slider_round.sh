#!/usr/bin/env bash
# slider_round.sh —— 真机一轮「首发 → 出验证码 → WebView 打开 → CDP 读题/修图/点选 → 取票 → **同连接**提交」
#
# 用法：
#   bash scripts/slider_round.sh --uin 3880159487 --md5 <口令MD5大写> \
#        [--identity ../analysis/_ref/official-logs/tim/identity-tim.json] \
#        [--wait 420] [--nx 0.176 --ny 0.3125] [--form picture|websig]
#
#   给了 --nx/--ny 就自动点选该归一化坐标（0..1，相对 .tc-imgarea）；
#   tile 位置要人看图决定 ⇒ 先不带 --nx 跑一次，看 tmp_capimg.bin，再带坐标重跑。
#
# 依赖：adb（ANDROID_SDK 下 platform-tools）、dart、node 22。
set -u
ADB="${ADB:-C:/Users/Administrator/AppData/Local/Android/Sdk/platform-tools/adb.exe}"
DART="${DART:-$USERPROFILE/scoop/apps/flutter/bin/cache/dart-sdk/bin/dart.exe}"
cd "$(dirname "$0")/.." || exit 1

UIN=""; MD5=""; IDENT=""; WAIT=420; NX=""; NY=""; FORM="picture"
while [ $# -gt 0 ]; do
  case "$1" in
    --uin) UIN="$2"; shift 2;;
    --md5) MD5="$2"; shift 2;;
    --identity) IDENT="$2"; shift 2;;
    --wait) WAIT="$2"; shift 2;;
    --nx) NX="$2"; shift 2;;
    --ny) NY="$2"; shift 2;;
    --form) FORM="$2"; shift 2;;
    *) echo "未知参数 $1"; exit 2;;
  esac
done
[ -n "$UIN" ] && [ -n "$MD5" ] || { echo "必须给 --uin 和 --md5"; exit 2; }

rm -f tmp_tk.txt tmp_tk.txt.url tmp_login.log tmp_jsmsgs.txt

echo "== 1/5 首发（拿 type=2 后保持连接等票，最长 ${WAIT}s）"
QQ_LIVE_CONFIRM=I_UNDERSTAND_THE_RISK "$DART" tool/qq8_live_smoke.dart --send \
  --uin="$UIN" --pwd="$MD5" ${IDENT:+--identity="$IDENT"} \
  --slider-form="$FORM" --slider-wait=tmp_tk.txt --slider-wait-secs="$WAIT" \
  > tmp_login.log 2>&1 &
LOGIN_PID=$!

for i in $(seq 1 90); do
  [ -s tmp_tk.txt.url ] && break
  sleep 1
  kill -0 $LOGIN_PID 2>/dev/null || break
done
if [ ! -s tmp_tk.txt.url ]; then
  echo "!! 没拿到验证地址，登录日志："; tail -30 tmp_login.log; exit 1
fi
cp tmp_tk.txt.url tmp_url.txt
echo "   验证地址 $(wc -c < tmp_url.txt) 字节 -> tmp_url.txt"

echo "== 2/5 用探针 WebView 打开验证页"
export MSYS_NO_PATHCONV=1
"$ADB" shell am force-stop com.example.qqclient.test
"$ADB" logcat -c
"$ADB" shell "run-as com.example.qqclient.test rm -f files/js_msgs.txt"
"$ADB" push tmp_url.txt /data/local/tmp/web_url.txt >/dev/null 2>&1
"$ADB" shell "run-as com.example.qqclient.test cp /data/local/tmp/web_url.txt files/web-url.txt"
"$ADB" shell am start -n com.example.qqclient.test/com.example.qqclient.TimCoreProbeActivity --es only web --ei nosubmit 1 >/dev/null
sleep 6
PID=$("$ADB" shell pidof com.example.qqclient.test | tr -d '\r')
"$ADB" forward --remove-all >/dev/null 2>&1
"$ADB" forward tcp:9222 localabstract:webview_devtools_remote_$PID >/dev/null
echo "   devtools pid=$PID"

echo "== 3/5 读题（图存 tmp_capimg.bin）"
node tool/cdp_captcha.mjs get | head -c 400; echo

if [ -n "$NX" ] && [ -n "$NY" ]; then
  echo "== 4/5 修图 + 点选 ($NX,$NY)"
  node tool/cdp_captcha.mjs fix
  node tool/cdp_captcha.mjs click "$NX" "$NY"
else
  echo "== 4/5 已跳过点选（没给 --nx/--ny）；看图后重跑带坐标"
fi

echo "== 5/5 等票"
for i in $(seq 1 60); do
  "$ADB" shell run-as com.example.qqclient.test cat files/js_msgs.txt 2>/dev/null > tmp_jsmsgs.txt
  if node tool/cdp_captcha.mjs ticket tmp_jsmsgs.txt 2>/dev/null; then break; fi
  sleep 2
done
if [ ! -s tmp_tk.txt ]; then echo "!! 60 次轮询没拿到票"; tail -20 tmp_jsmsgs.txt 2>/dev/null; fi

echo "== 同连接提交结果（登录日志尾部）"
for i in $(seq 1 60); do
  kill -0 $LOGIN_PID 2>/dev/null || break
  sleep 2
done
tail -25 tmp_login.log
