"""补完三件事：versionCode、sdkver、以及 WLogin SDK 版本常量。

versionCode 从二进制 AndroidManifest 里直接解析（AXML 格式），
不依赖 jadx 的资源解码。
"""
import zipfile
import re
import struct

APK = r'C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk'


# ---------------------------------------------------------------------------
# 最小 AXML 解析：只为取 manifest 元素的 versionCode 属性
# ---------------------------------------------------------------------------

def parse_axml_string_pool(buf, off):
    """返回字符串池与池结束偏移。"""
    type_, hdr_size, size = struct.unpack_from('<HHI', buf, off)
    assert type_ == 0x0001, f'不是字符串池: 0x{type_:04x}'
    string_count, style_count, flags, strings_start, styles_start = struct.unpack_from(
        '<IIIII', buf, off + 8)
    is_utf8 = bool(flags & (1 << 8))
    offsets = struct.unpack_from(f'<{string_count}I', buf, off + 28)
    strings = []
    for o in offsets:
        p = off + strings_start + o
        if is_utf8:
            # u16 len, u8 utf16len, bytes, 0x00
            n = buf[p]
            if n & 0x80:
                n = ((n & 0x7F) << 8) | buf[p + 1]
                p += 2
            else:
                p += 1
            u16n = buf[p]
            if u16n & 0x80:
                u16n = ((u16n & 0x7F) << 8) | buf[p + 1]
                p += 2
            else:
                p += 1
            strings.append(buf[p:p + n].decode('utf-8', 'replace'))
        else:
            n = struct.unpack_from('<H', buf, p)[0]
            p += 2
            if n & 0x8000:
                n = ((n & 0x7FFF) << 16) | struct.unpack_from('<H', buf, p)[0]
                p += 2
            strings.append(buf[p:p + n * 2].decode('utf-16-le', 'replace'))
    return strings, off + size


def dump_manifest(path):
    buf = path
    off = 8  # 跳过文件头
    strings = None
    ns = {}
    while off < len(buf):
        type_, hdr_size, size = struct.unpack_from('<HHI', buf, off)
        if size == 0:
            break
        if type_ == 0x0001:
            strings, _ = parse_axml_string_pool(buf, off)
        elif type_ == 0x0100:  # START_ELEMENT
            name_idx, attr_start, attr_size, attr_count = struct.unpack_from(
                '<IIHH', buf, off + 16)
            elem = strings[name_idx] if strings else '?'
            attrs = {}
            for i in range(attr_count):
                aoff = off + 16 + attr_start + i * 20
                ans, ani, araw, atype, adata = struct.unpack_from('<IIIiI', buf, aoff)
                aname = strings[ani] if strings else '?'
                if atype == 0x10:      # int
                    val = adata
                elif atype == 0x12:    # bool
                    val = bool(adata)
                elif atype == 0x03:    # string
                    val = strings[adata] if strings and adata < len(strings) else f'#{adata}'
                else:
                    val = f'type=0x{atype:x} data={adata}'
                attrs[aname] = val
            if elem == 'manifest' or elem == 'application':
                print(f'--- <{elem}> ---')
                for k, v in attrs.items():
                    if elem == 'manifest' or k in ('name', 'versionName', 'versionCode'):
                        print(f'    {k} = {v!r}')
        off += size


def main():
    z = zipfile.ZipFile(APK)

    print('=' * 62)
    print('【1】AndroidManifest（自解析 AXML）')
    print('=' * 62)
    try:
        dump_manifest(z.read('AndroidManifest.xml'))
    except Exception as e:
        print(f'  自解析失败: {e}')

    print()
    print('=' * 62)
    print('【2】sdkver / WLogin SDK 版本常量')
    print('=' * 62)
    dexes = sorted(n for n in z.namelist() if n.endswith('.dex'))
    pats = [rb'6\.0\.0\.\d{3,5}', rb'\d\.\d\.\d\.\d{4}']
    hits = {}
    for n in dexes:
        data = z.read(n)
        for p in pats:
            for m in re.finditer(p, data):
                s = m.group(0).decode('ascii', 'replace')
                hits.setdefault(s, set()).add(n)
    for s in sorted(hits, key=lambda x: (len(x), x)):
        if len(s) >= 8:
            print(f'  {s:<18} {sorted(hits[s])}')

    print()
    print('=' * 62)
    print('【3】versionCode 相关的其它线索')
    print('=' * 62)
    for pat in [b'versionCode', b'1380', b'V1_AND_SQ_8.2.11']:
        for n in dexes:
            c = z.read(n).count(pat)
            if c:
                print(f'  {pat!r} 在 {n} 出现 {c} 次')


if __name__ == '__main__':
    main()
