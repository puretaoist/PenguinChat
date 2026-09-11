"""解析 resources.arsc 的全局字符串池，导出资源标签。

用途：确认 KernelSU / ReSukiSU 里那几个开关的**准确界面文字**，
避免凭记忆给用户指错地方。
"""
import zipfile
import struct
import re
import sys

RES_STRING_POOL = 0x0001
UTF8_FLAG = 0x00000100


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
        try:
            if utf8:
                n = d[p]; p += 1
                if n & 0x80:
                    n = ((n & 0x7F) << 8) | d[p]; p += 1
                n2 = d[p]; p += 1
                if n2 & 0x80:
                    n2 = ((n2 & 0x7F) << 8) | d[p]; p += 1
                out.append(d[p:p + n2].decode("utf-8", "replace"))
            else:
                n = struct.unpack_from("<H", d, p)[0]; p += 2
                if n & 0x8000:
                    n = ((n & 0x7FFF) << 16) | struct.unpack_from("<H", d, p)[0]
                    p += 2
                out.append(d[p:p + n * 2].decode("utf-16-le", "replace"))
        except Exception:
            out.append("")
    return out


def find_string_pool(d):
    """arsc 顶层是 ResTable_header，全局字符串池是它的第一个子 chunk。"""
    chunk_type, header_size, chunk_size = struct.unpack_from("<HHI", d, 0)
    assert chunk_type == 0x0002, hex(chunk_type)  # RES_TABLE_TYPE
    off = header_size
    while off < chunk_size:
        t, hs, cs = struct.unpack_from("<HHI", d, off)
        if t == RES_STRING_POOL:
            return off
        off += cs
    raise RuntimeError("找不到字符串池")


def dump(apk, keys):
    z = zipfile.ZipFile(apk)
    r = z.read("resources.arsc")
    pool = parse_string_pool(r, find_string_pool(r))
    print("=" * 70)
    print(apk, " 字符串池条目:", len(pool))
    # 建索引：值 -> 位置
    idx = {}
    for i, s in enumerate(pool):
        idx.setdefault(s, i)
    for k in keys:
        i = idx.get(k)
        if i is None:
            print(f"  {k:<32} (池里没有)")
            continue
        nxt = [pool[j] for j in range(i + 1, min(i + 4, len(pool)))]
        print(f"  {k}")
        print(f"      紧随其后的条目: {nxt}")


if __name__ == "__main__":
    keys = [
        "settings_sucompat",
        "settings_sucompat_summary",
        "settings_adb_root",
        "settings_adb_root_summary",
        "settings_sulog",
        "settings_kernel_umount",
    ]
    for apk in [
        r"C:\Users\Administrator\.dsh\workspace\kernelsu.apk",
        r"C:\Users\Administrator\.dsh\workspace\resukisu.apk",
    ]:
        dump(apk, keys)
