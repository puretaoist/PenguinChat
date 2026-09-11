import zipfile, re, struct, os, glob

QQ8_ORDER = [24, 1, 262, 278, 256, 263, 264, 260, 322, 274, 324, 325, 327,
             358, 362, 340, 321, 8, 1297, 370, 389, 1024, 391, 392, 404, 401,
             513, 514, 375, 1302, 1313, 1317, 1321, 792, 1348, 1349, 1352]


def scan(data, prefix=(24, 1, 262)):
    pat = b"".join(struct.pack("<i", v) for v in prefix)
    out = []
    start = 0
    while True:
        i = data.find(pat, start)
        if i == -1:
            break
        vals = []
        for k in range(48):
            if i + 4 * k + 4 > len(data):
                break
            vals.append(struct.unpack_from("<i", data, i + 4 * k)[0])
        out.append((i, vals))
        start = i + 1
    return out


def dump(label, path, sub=None):
    print("=" * 74)
    print(label)
    if path.endswith(".apk"):
        z = zipfile.ZipFile(path)
        items = [(n, z.read(n)) for n in sorted(z.namelist())
                 if re.fullmatch(r"classes\d*\.dex", n)]
    else:
        items = [(os.path.basename(p), open(p, "rb").read())
                 for p in sorted(glob.glob(os.path.join(path, "*.dex")))]
    for name, data in items:
        hits = scan(data)
        for off, vals in hits:
            # trim to a plausible TLV list: positive, ends before junk
            tlvs = []
            for v in vals:
                if v <= 0 or v > 4000:
                    break
                tlvs.append(v)
            if len(tlvs) < 5:
                continue
            # only care if the first 3 match our known head
            mark = "== QQ8.2.11 一致" if tlvs[:len(QQ8_ORDER)] == QQ8_ORDER else "** 不同 **"
            print(f"  {name:<16} @0x{off:08x}  n={len(tlvs):<3} {mark}")
            print(f"      {tlvs}")
            extra = [v for v in tlvs[len(QQ8_ORDER):]] if tlvs[:len(QQ8_ORDER)] == QQ8_ORDER else None
            if extra:
                print(f"      额外: {extra}")


dump("QQ 8.2.11", r"C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk")
dump("QQ 8.9.50", r"C:\Users\Administrator\penguis\8.9.50.apk")
dump("QQ 9.3.60", r"C:\Users\Administrator\penguis\9.3.60_23e3f34e30110797.apk")
dump("TIM 4.1.0.4050", r"C:\Users\Administrator\penguis\tim_4.1.0.4050.apk")
