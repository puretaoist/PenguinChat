import zipfile, re, struct, os

ORDER = [24, 1, 262, 278, 256, 263, 264, 260, 322, 274, 324, 325, 327, 358,
         362, 340, 321, 8, 1297, 370, 389, 1024, 391, 392, 404, 401, 513, 514,
         375, 1302, 1313, 1317, 1321, 792, 1348, 1349, 1352]

APKS = {
    "QQ 8.2.11": r"C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk",
    "QQ 8.9.50": r"C:\Users\Administrator\penguis\8.9.50.apk",
    "QQ 9.3.60": r"C:\Users\Administrator\penguis\9.3.60_23e3f34e30110797.apk",
    "TIM 4.1.0.4050": r"C:\Users\Administrator\penguis\tim_4.1.0.4050.apk",
}

pat = b"".join(struct.pack("<i", v) for v in (24, 1, 262))

for label, path in APKS.items():
    print("=" * 74)
    print(label)
    z = zipfile.ZipFile(path)
    for name in sorted(n for n in z.namelist() if re.fullmatch(r"classes\d*\.dex", n)):
        data = z.read(name)
        start = 0
        while True:
            i = data.find(pat, start)
            if i == -1:
                break
            start = i + 1
            # DEX fill-array-data payload header sits right before the values:
            #   ushort ident(0x0300) | ushort element_width | uint size
            hdr = data[i - 8:i]
            ident, width, size = struct.unpack("<HHI", hdr)
            if ident != 0x0300 or width != 4:
                print(f"  {name:<16} @0x{i:08x}  (no payload header: {hdr.hex()})")
                continue
            vals = list(struct.unpack_from("<%di" % size, data, i))
            extra = vals[len(ORDER):] if vals[:len(ORDER)] == ORDER else None
            tag = "与 8.2.11 前 37 项一致" if extra is not None else "** 前缀不同 **"
            print(f"  {name:<16} @0x{i:08x}  size={size:<3} {tag}")
            if extra is not None:
                print(f"      前 37 = 基准；额外 {len(extra)} 项: {extra}")
                print(f"      额外项 hex: {[hex(v) for v in extra]}")
            else:
                print(f"      完整: {vals}")
