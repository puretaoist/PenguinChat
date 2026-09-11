import zipfile, re

APK = r"C:\Users\Administrator\penguis\tim_4.1.0.4050.apk"
z = zipfile.ZipFile(APK)

libs = sorted(n for n in z.namelist() if n.startswith("lib/arm64"))
print("total arm64 libs:", len(libs))
print("--- entries 50+ ---")
for n in libs[50:]:
    base = n.split("/")[-1]
    print("  %-42s %9.1f KB" % (base, z.getinfo(n).file_size / 1024))

print()
print("--- interesting lib patterns ---")
for pat in ["poxy", "qsec", "fekit", "qimei", "beacon", "bypass", "kernel", "mars", "msf"]:
    hit = [n.split("/")[-1] for n in libs if pat.lower() in n.lower()]
    print("  %-8s %s" % (pat, hit))

print()
mani = z.read("AndroidManifest.xml")
print("manifest size:", len(mani), "magic:", mani[:4].hex())

def find_u16(s):
    return mani.find(s.encode("utf-16-le"))

for k in ["APPKEY_DENGTA", "com.tencent.tim", "com.tencent.mobileqq", "QQProtect", "beacon"]:
    print("  utf16 %-22r -> %d" % (k, find_u16(k)))

i = find_u16("APPKEY_DENGTA")
if i != -1:
    seg = mani[i:i + 200]
    vals = re.findall(rb"(?:[\x20-\x7e]\x00){4,}", seg)
    print("  nearby utf16 strings:", [v.decode("utf-16-le") for v in vals])
