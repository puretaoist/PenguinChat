import zipfile, os, struct, re

APKS = {
    "8.2.11": r"C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk",
}
import glob
for p in glob.glob(r"C:\Users\Administrator\penguis\*.apk"):
    b = os.path.basename(p)
    if "8.9.50" in b: APKS["8.9.50"] = p
    if "9.3.60" in b: APKS["9.3.60"] = p

OUT = r"C:\Users\Administrator\.dsh\workspace\apk-analysis\lib"
os.makedirs(OUT, exist_ok=True)

TARGETS = ("libpoxy.so", "libQSec.so", "libQimei.so")

def elfinfo(data):
    if data[:4] != b"\x7fELF": return "not ELF"
    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
    e_shstrndx = struct.unpack_from("<H", data, 0x3E)[0]
    secs = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        secs.append(struct.unpack_from("<IIQQQQIIQQ", data, o))
    if not secs: return "no sections"
    so = secs[e_shstrndx][4]
    def nm(n):
        s = so + n; e = data.index(b"\0", s); return data[s:e].decode("utf-8", "replace")
    names = {nm(s[0]): s for s in secs}
    line = "sections=" + ",".join(sorted(k for k in names if k))
    # count dynsym
    if ".dynsym" in names:
        d = names[".dynsym"]
        n = d[5] // 24
        strtab = secs[d[6]]
        base = strtab[4]
        def sa(off):
            s = base + off; e = data.index(b"\0", s); return data[s:e].decode("utf-8", "replace")
        java = []
        total = 0
        for i in range(n):
            o = d[4] + i * 24
            st_name, st_info, _, _, st_value, _ = struct.unpack_from("<IBBHQQ", data, o)
            if st_name == 0: continue
            total += 1
            s = sa(st_name)
            if s.startswith("Java_"): java.append(s)
        line += f"\n      dynsym={total}  JNI={len(java)}"
        for j in java[:25]: line += "\n        " + j
    return line

for ver, apk in APKS.items():
    print("=" * 70)
    print(ver, os.path.basename(apk))
    with zipfile.ZipFile(apk) as z:
        for t in TARGETS:
            ent = "lib/arm64-v8a/" + t
            try:
                info = z.getinfo(ent)
            except KeyError:
                print(f"  {t:<14} ABSENT")
                continue
            data = z.read(ent)
            dst = os.path.join(OUT, f"{ver}-{t}")
            if not os.path.exists(dst):
                open(dst, "wb").write(data)
            print(f"  {t:<14} {len(data)/1024:9.1f} KB   {elfinfo(data)[:400]}")
