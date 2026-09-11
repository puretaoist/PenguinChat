"""提取 8.2.11 APK 的版本标识与 qua，并定位 AppInfo 常量区。

已确认：
  version = 8.2.11.4530
  sign    = a6b745bf24a2c277527716f6f36eb68d（= APK 证书 DER 的 MD5，与 8.4.1 相同）
本脚本继续提取 qua 与 appid/subid/bitmap/sigmap 的线索。
"""
import zipfile
import re

APK = r'C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk'


def strings_of(data, minlen=4):
    return [m.group(0).decode('ascii') for m in re.finditer(rb'[\x20-\x7e]{%d,}' % minlen, data)]


def main():
    z = zipfile.ZipFile(APK)
    dexes = sorted(n for n in z.namelist() if n.endswith('.dex'))

    print('=' * 66)
    print('【1】V1_AND_SQ / qua 字符串')
    print('=' * 66)
    seen = set()
    for n in dexes:
        for s in strings_of(z.read(n), 6):
            if 'V1_AND' in s or 'V1_AND_SQ' in s:
                # 可能和其他字符串粘在一起，按 V1_ 切
                for part in re.findall(r'V1_AND[\w_]*', s):
                    if part not in seen:
                        seen.add(part)
                        print(f'  {part}')
    if not seen:
        print('  未找到')

    print()
    print('=' * 66)
    print('【2】含 GoogleMarket / 完整版本号的串')
    print('=' * 66)
    seen2 = set()
    for n in dexes:
        for s in strings_of(z.read(n), 8):
            for m in re.finditer(r'[\w.]*8\.2\.11[\w.\-]*', s):
                t = m.group(0)
                if len(t) >= 7 and t not in seen2:
                    seen2.add(t)
                    print(f'  {t}')
    for s in sorted(seen2)[:60]:
        pass
    print(f'  （共 {len(seen2)} 条唯一串）')

    print()
    print('=' * 66)
    print('【3】sigmap / appid / subid 附近的可读上下文')
    print('=' * 66)
    for key in [b'sigmap', b'SubAppId', b'subid', b'55033']:
        for n in dexes:
            data = z.read(n)
            i = data.find(key)
            if i >= 0:
                seg = data[max(0, i - 150):i + 250]
                seg = re.sub(rb'[^\x20-\x7e]', b'.', seg).decode('ascii')
                print(f'  --- {key.decode()} @ {n} 0x{i:x} ---')
                print(f'    {seg}')
                break

    print()
    print('=' * 66)
    print('【4】常见 QQ appid/subid 常量在 dex 中的存在性')
    print('=' * 66)
    import struct
    cands = {
        'appid 16': 16,
        'subid 537064989 (oicq 8.4.1)': 537064989,
        'subid 537065549 (oicq aPad)': 537065549,
        'bitmap 184024956 (oicq 8.4.1)': 184024956,
        'sigmap 34869472 (oicq 8.4.1)': 34869472,
        'sigmap 1970400 (oicq aPad)': 1970400,
    }
    for label, v in cands.items():
        be, le = struct.pack('>I', v), struct.pack('<I', v)
        hb = [n for n in dexes if be in z.read(n)]
        hl = [n for n in dexes if le in z.read(n)]
        print(f'  {label:<32} BE={hb}  LE={hl}')


if __name__ == '__main__':
    main()
