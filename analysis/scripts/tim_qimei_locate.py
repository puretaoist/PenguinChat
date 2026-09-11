"""TIM 4.1.0 里 QIMEI / Beacon 到底在哪。

QQ 8.2.11 的 QIMEI 走 `com.tencent.beacon.qimei.d`，存 SP `DENGTA_META`
的 `QIMEI_DENGTA` 键。TIM 4.1.0 带的是新版 `libqimei.so`(527KB)，
存储位置很可能不同——本脚本把候选标记在所有 dex 里定位出来。
"""
import zipfile
import re
import os

APKS = {
    "TIM 4.1.0.4050": r"C:\Users\Administrator\penguis\tim_4.1.0.4050.apk",
    "QQ 8.2.11": r"C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk",
}

MARKERS = [
    b"Lcom/tencent/beacon/qimei",
    b"Lcom/tencent/qimei",
    b"com.tencent.qimei",
    b"QimeiSDK",
    b"QIMEI_DENGTA",
    b"DENGTA_META",
    b"APPKEY_DENGTA",
    b"qimei",
    b"QIMEI",
    b"q16",
    b"q36",
    b"BeaconIdJNI",
    b"QimeiAudit",
    b"Lcom/tencent/beacon/",
]

for label, path in APKS.items():
    print("=" * 74)
    print(label)
    z = zipfile.ZipFile(path)
    dexes = sorted(n for n in z.namelist() if re.fullmatch(r"classes\d*\.dex", n))
    totals = {m: 0 for m in MARKERS}
    per_dex = {}
    for n in dexes:
        d = z.read(n)
        hits = {}
        for m in MARKERS:
            c = d.count(m)
            if c:
                hits[m.decode()] = c
                totals[m] += c
        if hits:
            per_dex[n] = hits
    for n, hits in per_dex.items():
        print(f"  {n:<16} {hits}")
    print("  --- 汇总 ---")
    for m in MARKERS:
        print(f"    {m.decode():<34} {totals[m]}")
