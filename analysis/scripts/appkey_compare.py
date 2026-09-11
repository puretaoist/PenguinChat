import zipfile, re, os

APKS = {
    "QQ 8.2.11": r"C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk",
    "QQ 8.9.50": r"C:\Users\Administrator\penguis\8.9.50.apk",
    "QQ 9.3.60": r"C:\Users\Administrator\penguis\9.3.60_23e3f34e30110797.apk",
    "TIM 4.1.0.4050": r"C:\Users\Administrator\penguis\tim_4.1.0.4050.apk",
}

for label, path in APKS.items():
    print("=" * 72)
    print(label, " ", round(os.path.getsize(path) / 1024 / 1024, 1), "MB")
    z = zipfile.ZipFile(path)
    try:
        mani = z.read("AndroidManifest.xml")
    except KeyError:
        print("  no AndroidManifest.xml")
        continue
    i = mani.find("APPKEY_DENGTA".encode("utf-16-le"))
    if i == -1:
        print("  APPKEY_DENGTA: NOT FOUND")
    else:
        seg = mani[i:i + 300]
        vals = re.findall(rb"(?:[\x20-\x7e]\x00){4,}", seg)
        vals = [v.decode("utf-16-le") for v in vals]
        print("  APPKEY_DENGTA =", vals[1] if len(vals) > 1 else vals)

    libs = [n.split("/")[-1] for n in z.namelist() if n.startswith("lib/arm64")]
    want = ["libpoxy.so", "libQSec.so", "libQimei.so", "libqimei.so", "libfekit.so",
            "libBeaconDT.so", "libbypass.so", "libkernel.so", "libMSFKernel.so"]
    present = [w for w in want if w in libs]
    print("  key libs:", present)
    miss = [w for w in want if w not in libs]
    print("  absent  :", miss)
