import zipfile, os, sys

APK = r"C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk"
OUT = r"C:\Users\Administrator\.dsh\workspace\apk-analysis\all-dex"
os.makedirs(OUT, exist_ok=True)

with zipfile.ZipFile(APK) as z:
    names = [n for n in z.namelist() if n.startswith("classes") and n.endswith(".dex")]
    names.sort()
    print("dex count:", len(names))
    for n in names:
        p = os.path.join(OUT, os.path.basename(n))
        if not os.path.exists(p):
            with z.open(n) as f, open(p, "wb") as g:
                g.write(f.read())
        sz = os.path.getsize(p)
        data = open(p, "rb").read()
        hits = []
        for needle in (b"Lcom/tencent/secprotocol/ByteData;",
                       b"secprotocol",
                       b"Lcom/tencent/qimei/",
                       b"QSec",
                       b"qsec"):
            hits.append((needle.decode(), data.count(needle)))
        nonz = [h for h in hits if h[1]]
        print(f"  {os.path.basename(n):<16} {sz/1024/1024:6.2f} MB  {nonz}")
