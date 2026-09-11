import zipfile, os, re, struct

APK = r"C:\Users\Administrator\penguis\tim_4.1.0.4050.apk"
print("=" * 70)
print(os.path.basename(APK), round(os.path.getsize(APK)/1024/1024, 1), "MB")

z = zipfile.ZipFile(APK)
names = z.namelist()

dexes = sorted(n for n in names if re.fullmatch(r"classes\d*\.dex", n))
libs = sorted(n for n in names if n.startswith("lib/"))
print(f"\ndex: {dexes}")
print(f"lib/ entries: {len(libs)}")

# --- manifest ---
mani = z.read("AndroidManifest.xml")
print("\n--- manifest strings of interest ---")
for k in [b"APPKEY_DENGTA", b"com.tencent.tim", b"com.tencent.mobileqq"]:
    i = mani.find(k)
    print(f"  {k.decode():<26} found at {i}")
# dump the utf16/utf8 value after APPKEY_DENGTA
i = mani.find(b"APPKEY_DENGTA")
if i != -1:
    seg = mani[i:i+160]
    m = re.search(rb'APPKEY_DENGTA[^\x00]{0,8}([\x20-\x7e]{6,32})', seg)
    print("  APPKEY_DENGTA context:", seg[:120])

# --- which dex has wtlogin / secprotocol / beacon ---
print("\n--- dex forensics ---")
markers = {
    b"oicq/wlogin_sdk/request/": "wtlogin-req",
    b"oicq/wlogin_sdk/tlv_type/": "wtlogin-tlv",
    b"com/tencent/secprotocol": "secprotocol",
    b"com/tencent/beacon/qimei": "beacon-qimei",
    b"QIMEI_DENGTA": "QIMEI_DENGTA",
    b"tgtQR": "tgtQR",
    b"libpoxy": "libpoxy",
    b"libQSec": "libQSec",
    b"libfekit": "libfekit",
    b"oicq/wlogin_sdk/tools/util": "wlogin-util",
}
for d in dexes:
    data = z.read(d)
    hits = [(v, data.count(k)) for k, v in markers.items() if data.count(k)]
    print(f"  {d:<16} {len(data)/1024/1024:6.2f} MB  {hits if hits else '-'}")

# --- native libs ---
print("\n--- arm64 libs ---")
for n in libs:
    if "arm64" not in n:
        continue
    print(f"  {n.split('/')[-1]:<42} {z.getinfo(n).file_size/1024:9.1f} KB")

# --- split apks / extra ---
others = [n for n in names if n.endswith(".apk")]
if others:
    print("\n--- nested apk ---", others)
