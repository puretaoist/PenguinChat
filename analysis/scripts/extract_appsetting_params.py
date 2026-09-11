import zipfile, re, os

APKS = {
    "QQ 8.2.11": r"C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk",
    "QQ 8.9.50": r"C:\Users\Administrator\penguis\8.9.50.apk",
    "QQ 9.3.60": r"C:\Users\Administrator\penguis\9.3.60_23e3f34e30110797.apk",
    "TIM 4.1.0.4050": r"C:\Users\Administrator\penguis\tim_4.1.0.4050.apk",
}

U16 = re.compile(rb"(?:[\x20-\x7e]\x00){3,400}")


def strings16(seg):
    return [m.group().decode("utf-16-le") for m in U16.finditer(seg)]


for label, path in APKS.items():
    print("=" * 74)
    print(label)
    z = zipfile.ZipFile(path)
    mani = z.read("AndroidManifest.xml")

    for key in ["AppSetting_params", "APPKEY_DENGTA"]:
        i = mani.find(key.encode("utf-16-le"))
        if i == -1:
            print(f"  {key}: NOT FOUND")
            continue
        seg = mani[i:i + 900]
        vals = strings16(seg)
        # vals[0] is the key itself; the value is the next distinct string
        cand = [v for v in vals[1:] if v != key][:3]
        print(f"  {key:<20} -> {cand}")

    # versionCode / versionName are android: attributes; scan pool for plausible ones
    print("  (qua 已在上一轮提取)")
