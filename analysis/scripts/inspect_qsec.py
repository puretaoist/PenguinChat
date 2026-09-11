import zipfile, os, struct

APK = r"C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk"
SO = "lib/arm64-v8a/libQSec.so"
OUT = r"C:\Users\Administrator\.dsh\workspace\apk-analysis\lib"
os.makedirs(OUT, exist_ok=True)
dst = os.path.join(OUT, "libQSec.so")
if not os.path.exists(dst):
    with zipfile.ZipFile(APK) as z, z.open(SO) as f, open(dst, "wb") as g:
        g.write(f.read())

data = open(dst, "rb").read()
print(f"libQSec.so  {len(data)/1024:.1f} KB")

# --- minimal ELF64 parse ---
assert data[:4] == b"\x7fELF", "not ELF"
is64 = data[4] == 2
e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
e_shstrndx = struct.unpack_from("<H", data, 0x3E)[0]

sections = []
for i in range(e_shnum):
    off = e_shoff + i * e_shentsize
    name, typ, flags, addr, offset, size, link, info, align, entsize = struct.unpack_from("<IIQQQQIIQQ", data, off)
    sections.append(dict(name=name, type=typ, addr=addr, off=offset, size=size, link=link, entsize=entsize))

shstr = sections[e_shstrndx]
def secname(n):
    s = shstr["off"] + n
    e = data.index(b"\0", s)
    return data[s:e].decode("utf-8", "replace")

dynsym = dynstr = None
for s in sections:
    nm = secname(s["name"])
    s["sname"] = nm
    if nm == ".dynsym": dynsym = s
    if nm == ".dynstr": dynstr = s

def str_at(base, off):
    s = base + off
    e = data.index(b"\0", s)
    return data[s:e].decode("utf-8", "replace")

exports = []
if dynsym:
    n = dynsym["size"] // 24
    for i in range(n):
        o = dynsym["off"] + i * 24
        st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", data, o)
        if st_name == 0: continue
        nm = str_at(dynstr["off"], st_name)
        bind = st_info >> 4
        typ = st_info & 0xF
        exports.append((nm, bind, typ, st_value, st_size))

print(f"dynsym entries: {len(exports)}")

jni = [e for e in exports if e[0].startswith("Java_")]
print("\n--- JNI exports ---")
for nm, bind, typ, val, sz in sorted(jni):
    print(f"  {nm}")

print("\n--- other defined exports (top 60) ---")
defined = [e for e in exports if e[3] != 0 and not e[0].startswith("Java_")]
for nm, bind, typ, val, sz in sorted(defined)[:60]:
    print(f"  {nm}  size={sz}")

# NEEDED libs
dynamic = next((s for s in sections if s["sname"] == ".dynamic"), None)
if dynamic:
    needed = []
    off = dynamic["off"]
    end = off + dynamic["size"]
    while off < end:
        d_tag, d_val = struct.unpack_from("<qQ", data, off)
        off += 16
        if d_tag == 0: break
        if d_tag == 1:
            needed.append(str_at(dynstr["off"], d_val))
    print("\n--- DT_NEEDED ---")
    for n in needed: print("  " + n)
