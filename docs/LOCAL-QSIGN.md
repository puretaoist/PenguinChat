# 本地 qsign（Windows 原生跑，无需 docker / 无需第三方服务器）

> 2026-10-29 建立。目的：在本机产出**真 0x544/0x553**，替代「拿不到签名」这一瓶颈。

## 一、原料从哪来（这才是关键：不走 GitHub raw）

| 通道 | 速度实测 | 拿到什么 |
|---|---|---|
| **Docker Hub registry v2 API** | **15.1 MB/s** | `xzhouqd/qsign:core-1.1.9` 全量镜像层：`srv/qsign/qsign/{lib,txlib}` |
| **Maven Central** | **5.7 MB/s** | `top.mrxiaom:qsign:1.1.0-beta`（40MB fat jar，内含整套 unidbg + windows_64/dynarmic.dll + `moe/fuqiuluo/unidbg/vm/AndroidVM` + QSecJni） |
| raw.githubusercontent.com | 1.6 MB/min | ❌ 已放弃 |

### 拉镜像层（本机无 docker，直接走 registry API）
```bash
T=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:xzhouqd/qsign:pull" \
    | python -c "import sys,json;print(json.load(sys.stdin)['token'])")
# 1) 取 amd64 manifest（8.9.63 标签是多架构 index，要先解一层）
curl -s -H "Authorization: Bearer $T" -H "Accept: application/vnd.oci.image.index.v1+json" \
  "https://registry-1.docker.io/v2/xzhouqd/qsign/manifests/8.9.63"
# 2) 按 digest 拉层（**必须带 -L**，307 到 S3；digest 必须完整 64 位，截断会报 DIGEST_INVALID）
curl -sL -H "Authorization: Bearer $T" -o layer.tgz \
  "https://registry-1.docker.io/v2/xzhouqd/qsign/blobs/sha256:<full-digest>"
```
层分配（实测）：
- 49.5MB = ubuntu base（解压会因 symlink 报错，可忽略）
- **198MB = JRE**（14.7MB/s）
- **93MB = qsign 本体**：`srv/qsign/qsign/lib/*.jar`（含 `unidbg-fix.jar` 79.5MB、`unidbg-fetch-qsign-1.0.5.jar` 238KB）
- **3.3MB = txlib**：`srv/qsign/qsign/txlib/8.9.63/{libfekit.so 10,113,764B, libQSec.so 29,176B, .system_android_l2}`

## 二、启动（Windows + Zulu 21）
```bash
cd tmp/qsrv/srv/qsign/qsign
"/c/Program Files/Zulu/zulu-21/bin/java.exe" -cp "lib/*" MainKt \
  --port=8099 --count=1 --library=txlib/8.9.63 --android_id=<androidId 16hex> --debug=true
```
**坑**：`ArgsParser`（`moe/fuqiuluo/comm/ArgsParser.class`）只认 `--key=value`，且每个参数都必须带 `=`；写成 `--port 8099` 直接抛 `IllegalStateException: Not support the expr.`。

## 三、验证（已成功）
```bash
curl "http://127.0.0.1:8099/energy?version=6.0.0.2534&uin=<uin>&guid=<md5(androidId+mac)>&data=810_9"
# → {"code":0,"msg":"success","data":"0C091171...9A"}  41 字节（0x0C 0x09 头）
```
- `data` = 就是 **0x544 的 body**（41B），可直接喂 `tool/qq8_live_smoke.dart --t544=native --t544-sign=<hex>`。
- **salt 支持面由 libfekit 版本决定**：8.9.63 的 lib 支持 `810_9` / `810_a`，**不支持 `810_2`**（返回 code -3 "failed"）⇒ 想给 8.2.11 档案签名，必须再取 8.9.58 或更老的 txlib。
- 其它端点：`/sign?uin=&qua=&cmd=wtlogin.login&seq=&buffer=<hex>`（返回 token/extra/sign → **0x553**）、`/custom_energy?salt=&data=`。

## 四、首个真实验结论（2026-10-29 20:16）
- 小号 3499239040 + 8.9.50 档案 + **真 0x544（810_9，82 hex）** + 真机身份 identity-25091RP04C.json → 仍 **type=45**（0x146 133B + 0x508 34B，"禁止登录…下载最新版QQ"）。
- 说明：45 与「0x544 是假签」无关，是**该账号的准入结论**（与此前 4 次二分一致）。
- 待做：改用**新号**（能走到 type=2 的账号）跑一轮「真 0x544 → 交票」，看 237 是否变成 0。这才是 0x544 是否为目的闸门的唯一干净实验。

## 五、注意
- 这台机器**没有 docker**，但 registry API 完全够用；`kissnavel/qsign`、`woxigousade/qsign` 是同类镜像（后者自称支持到 9.0.8）。
- qsign 是「用官方 libfekit.so 在 unidbg 里算」，**本地运行、不联网到第三方签名服务**，与「用别人签名服务」是两件事。
