import zipfile, re, os

APKS = {
    "QQ 8.2.11": r"C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk",
    "QQ 8.9.50": r"C:\Users\Administrator\penguis\8.9.50.apk",
    "QQ 9.3.60": r"C:\Users\Administrator\penguis\9.3.60_23e3f34e30110797.apk",
    "TIM 4.1.0.4050": r"C:\Users\Administrator\penguis\tim_4.1.0.4050.apk",
}

# <version>.<build>.<date>.<revision>.<channel>
FULL = re.compile(rb"[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,3}\.[0-9]{2,5}\.[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9a-fA-F]{6,10}\.[A-Za-z0-9_]+")
QUA = re.compile(rb"V1_AND_SQ_[0-9A-Za-z_.]+")
SDKV = re.compile(rb"6\.0\.0\.[0-9]{3,5}")
BETA = re.compile(rb"beta\.\d+\.\d+\.\d+\.[0-9a-zA-Z./:% -]{10,60}")

for label, path in APKS.items():
    print("=" * 74)
    print(label)
    z = zipfile.ZipFile(path)
    fulls, quas, sdkvs, betas = set(), set(), set(), set()
    for n in sorted(n for n in z.namelist() if re.fullmatch(r"classes\d*\.dex", n)):
        d = z.read(n)
        for m in FULL.finditer(d):
            fulls.add(m.group().decode())
        for m in QUA.finditer(d):
            quas.add(m.group().decode())
        for m in SDKV.finditer(d):
            sdkvs.add(m.group().decode())
        for m in BETA.finditer(d):
            betas.add(m.group().decode().strip())
    print("  fullVersion 候选:")
    for s in sorted(fulls):
        print("     ", s)
    print("  qua:", sorted(quas))
    print("  sdkVersion 候选:", sorted(sdkvs)[:8])
    if betas:
        print("  beta 串:", sorted(betas)[:5])
