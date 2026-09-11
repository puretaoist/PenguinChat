"""最小 AndroidManifest.xml (AXML) 解析器。

只做一件事：把 <meta-data> 的 android:name / android:value 读出来，
以及 <manifest> 的 versionCode / versionName。
用来提取 AppSetting_params / APPKEY_DENGTA，避免猜字符串池的相邻关系。
"""
import zipfile
import struct
import sys

APKS = {
    "QQ 8.2.11": r"C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk",
    "QQ 8.9.50": r"C:\Users\Administrator\penguis\8.9.50.apk",
    "QQ 9.3.60": r"C:\Users\Administrator\penguis\9.3.60_23e3f34e30110797.apk",
    "TIM 4.1.0.4050": r"C:\Users\Administrator\penguis\tim_4.1.0.4050.apk",
}

RES_STRING_POOL = 0x0001
RES_XML_START_ELEMENT = 0x0102
RES_XML_END_ELEMENT = 0x0103
UTF8_FLAG = 0x00000100

ANDROID_NS = "http://schemas.android.com/apk/res/android"


def parse_string_pool(d, off):
    chunk_type, header_size, chunk_size = struct.unpack_from("<HHI", d, off)
    assert chunk_type == RES_STRING_POOL, hex(chunk_type)
    string_count, style_count, flags, strings_start, styles_start = struct.unpack_from(
        "<IIIII", d, off + 8)
    utf8 = bool(flags & UTF8_FLAG)
    offsets = struct.unpack_from("<%dI" % string_count, d, off + 28)
    base = off + strings_start
    out = []
    for o in offsets:
        p = base + o
        if utf8:
            n = d[p]
            p += 1
            if n & 0x80:
                n = ((n & 0x7F) << 8) | d[p]
                p += 1
            n2 = d[p]
            p += 1
            if n2 & 0x80:
                n2 = ((n2 & 0x7F) << 8) | d[p]
                p += 1
            out.append(d[p:p + n2].decode("utf-8", "replace"))
        else:
            n = struct.unpack_from("<H", d, p)[0]
            p += 2
            if n & 0x8000:
                n = ((n & 0x7FFF) << 16) | struct.unpack_from("<H", d, p)[0]
                p += 2
            out.append(d[p:p + n * 2].decode("utf-16-le", "replace"))
    return out, utf8, chunk_size


def walk(d):
    """yield (element_name, {attr_name: raw_string_value})"""
    magic, size = struct.unpack_from("<II", d, 0)
    assert magic == 0x00080003, hex(magic)
    off = 8
    strings = []
    while off < size:
        chunk_type, header_size, chunk_size = struct.unpack_from("<HHI", d, off)
        if chunk_type == RES_STRING_POOL:
            strings, utf8, chunk_size = parse_string_pool(d, off)
            off += chunk_size
            continue
        if chunk_type == RES_XML_START_ELEMENT:
            # ResXMLTree_attrExt: ns(4) name(4) attributeStart(2) attributeSize(2)
            #                     attributeCount(2) idIndex(2) classIndex(2) styleIndex(2)
            ns_idx, name_idx = struct.unpack_from("<II", d, off + 16)
            attr_start = struct.unpack_from("<H", d, off + 24)[0]
            attr_count = struct.unpack_from("<H", d, off + 28)[0]
            ap = off + 16 + attr_start
            attrs = {}
            for i in range(attr_count):
                a_ns, a_name, a_raw = struct.unpack_from("<III", d, ap + i * 20)
                data_type = d[ap + i * 20 + 15]
                data = struct.unpack_from("<I", d, ap + i * 20 + 16)[0]
                key = strings[a_name] if a_name < len(strings) else "?"
                if a_raw != 0xFFFFFFFF and a_raw < len(strings):
                    val = strings[a_raw]
                elif data_type == 0x03 and data < len(strings):
                    val = strings[data]
                else:
                    val = str(data)
                attrs[key] = val
                attrs["{" + (strings[a_ns] if a_ns < len(strings) else "") + "}" + key] = val
            yield strings[name_idx] if name_idx < len(strings) else "?", attrs
        off += chunk_size


for label, path in APKS.items():
    print("=" * 74)
    print(label)
    z = zipfile.ZipFile(path)
    d = z.read("AndroidManifest.xml")
    want = {"AppSetting_params", "APPKEY_DENGTA", "AppSetting_params_pad"}
    for name, attrs in walk(d):
        if name == "manifest":
            print("  versionName =", attrs.get("versionName"))
            print("  versionCode =", attrs.get("versionCode"))
        if name == "meta-data":
            n = attrs.get("name") or attrs.get(ANDROID_NS + "}name") or ""
            if n in want or (n and "APPKEY" in n) or (n and "AppSetting" in n):
                v = attrs.get("value") or attrs.get(ANDROID_NS + "}value")
                print(f"  meta-data {n} = {v}")
