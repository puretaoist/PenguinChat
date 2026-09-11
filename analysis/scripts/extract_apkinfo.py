"""从 QQ 8.2.11 play APK 提取 oicq 需要的 apk 参数表。

对应 oicq `lib/device.js` 里的结构：
    { name, version, ver, sign, buildtime, appid, subid, bitmap, sigmap, sdkver }

本脚本提取：
  1. AndroidManifest 里的 versionName / versionCode / package
  2. APK 签名证书（META-INF/*.RSA）及其多种哈希候选
  3. 全部 dex 里出现过的版本号字符串（找 "8.2.11" / "A8.x" 之类）
  4. dex 里是否出现 oicq 已知的 8.4.1 常量（用于确认字段存在）
"""
import zipfile
import re
import hashlib
import struct

APK = r'C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk'

# oicq lib/device.js 里 8.4.1 (android phone) 的已知值，用来确认字段确实存在于 dex
KNOWN_841_SIGN = bytes([166, 183, 69, 191, 36, 162, 194, 119, 82, 119, 22, 246, 243, 110, 182, 141])


def find_ascii_utf16(data, needle: str):
    """在二进制里找 ASCII 与 UTF-16LE 两种编码的出现位置。"""
    hits = []
    b_ascii = needle.encode('ascii')
    b_utf16 = needle.encode('utf-16-le')
    for pat, tag in ((b_ascii, 'ascii'), (b_utf16, 'utf16')):
        start = 0
        while True:
            i = data.find(pat, start)
            if i < 0:
                break
            hits.append((tag, i))
            start = i + 1
    return hits


def main():
    z = zipfile.ZipFile(APK)

    print('=' * 66)
    print('【1】AndroidManifest 里的版本信息')
    print('=' * 66)
    mf = z.read('AndroidManifest.xml')
    for key in ['8.2.11', '8.2.11.4', 'com.tencent.mobileqq', 'versionName']:
        hits = find_ascii_utf16(mf, key)
        print(f'  "{key}"  命中 {len(hits)} 处  {hits[:4]}')

    # UTF-16 字符串池里把所有像版本号的串捞出来
    u16 = mf.decode('utf-16-le', errors='ignore')
    vers = sorted({m for m in re.findall(r'\b\d+\.\d+\.\d+(?:\.\d+)?\b', u16)})
    print(f'  manifest 中形似版本号的串: {vers[:40]}')

    print()
    print('=' * 66)
    print('【2】签名文件与证书哈希')
    print('=' * 66)
    sig_files = [n for n in z.namelist() if n.upper().startswith('META-INF/')
                 and n.upper().endswith(('.RSA', '.DSA', '.EC'))]
    print(f'  v1 签名文件: {sig_files}')
    for n in sig_files:
        blob = z.read(n)
        print(f'  --- {n}  ({len(blob)} 字节) ---')
        print(f'      md5(整个文件)   = {hashlib.md5(blob).hexdigest()}')
        print(f'      sha1(整个文件)  = {hashlib.sha1(blob).hexdigest()}')
        print(f'      sha256(整个文件)= {hashlib.sha256(blob).hexdigest()}')
        # 证书 DER 一般是 PKCS#7 里第一段 SEQUENCE，粗略取一遍所有长度合理的
        # 偏移处做候选哈希，方便后面人工比对
        cands = set()
        for off in range(0, min(len(blob), 4096)):
            if blob[off] == 0x30 and off + 2 < len(blob):
                ln = blob[off + 1]
                if ln & 0x80:
                    nb = ln & 0x7F
                    if nb > 3 or off + 2 + nb > len(blob):
                        continue
                    ln = int.from_bytes(blob[off + 2:off + 2 + nb], 'big')
                    hdr = 2 + nb
                else:
                    hdr = 2
                if 400 < ln < 4000 and off + hdr + ln <= len(blob):
                    der = blob[off:off + hdr + ln]
                    cands.add((off, ln, hashlib.md5(der).hexdigest()))
        print(f'      候选证书 DER（offset, len, md5）共 {len(cands)} 条：')
        for off, ln, h in sorted(cands)[:12]:
            print(f'        off=0x{off:04x} len={ln} md5={h}')

    print()
    print('=' * 66)
    print('【3】dex 中的版本号字符串')
    print('=' * 66)
    dexes = sorted(n for n in z.namelist() if n.endswith('.dex'))
    allvers = {}
    for n in dexes:
        data = z.read(n)
        # 字符串池是 MUTF-8；直接找 ASCII 片段
        for m in re.finditer(rb'A8\.\d+\.\d+(?:\.\d+)?[0-9a-zA-Z]{0,12}', data):
            s = m.group(0).decode('ascii', 'replace')
            allvers.setdefault(s, []).append(n)
        for m in re.finditer(rb'\b8\.\d+\.\d+\.\d{3,6}\b', data):
            s = m.group(0).decode('ascii', 'replace')
            allvers.setdefault(s, []).append(n)

    for s in sorted(allvers):
        locs = allvers[s]
        print(f'  {s:<28} 出现 {len(locs)} 次  {sorted(set(locs))[:3]}')

    print()
    print('=' * 66)
    print('【4】dex 中是否出现 oicq 已知的 8.4.1 常量')
    print('=' * 66)
    for n in dexes:
        data = z.read(n)
        if KNOWN_841_SIGN in data:
            print(f'  {n}: 找到 8.4.1 的 sign 字节序列')
    # appid / subid / bitmap / sigmap 的字节序表示
    for label, val in [('subid 537064989', 537064989), ('bitmap 184024956', 184024956),
                       ('sigmap 34869472', 34869472), ('appid 16', 16)]:
        be = struct.pack('>I', val)
        le = struct.pack('<I', val)
        hits_be = sum(1 for n in dexes if be in z.read(n))
        hits_le = sum(1 for n in dexes if le in z.read(n))
        print(f'  {label:<22} 大端命中 {hits_be} 个 dex，小端命中 {hits_le} 个 dex')
    print('  （命中数仅供参考：常量通常以 DEX 的整数常量内联，未必是裸字节）')


if __name__ == '__main__':
    main()
