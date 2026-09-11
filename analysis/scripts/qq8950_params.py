import zipfile, re

z = zipfile.ZipFile(r"C:\Users\Administrator\penguis\8.9.50.apk")

for dex in ["classes25.dex", "classes20.dex"]:
    d = z.read(dex)
    print("=" * 72)
    print(dex, len(d) / 1024 / 1024, "MB")
    found = set()
    for m in re.finditer(rb"[\x20-\x7e]{6,120}", d):
        s = m.group().decode("ascii")
        if re.search(r"(V1_AND_SQ|8\.9\.50|\d+\.\d+\.\d+\.\d{3,}|GoogleMarket|GM_D)", s):
            found.add(s)
    for s in sorted(found):
        print("   ", s)
