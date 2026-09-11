"""在三个官方 APK 里定位 oicq/wlogin_sdk 的 TLV 相关类，供横向对比。

目的：确认 TLV 0x106 的 TEA 密钥派生方式是否随版本变化，
以及 oicq 的实现究竟对应哪一代。
"""
import zipfile
import re
import os

APKS = [
    ('8.2.11', r'C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk'),
    ('8.9.50', r'C:\Users\Administrator\penguis\8.9.50.apk'),
    ('9.3.60', r'C:\Users\Administrator\penguis\9.3.60_23e3f34e30110797.apk'),
]

KEYS = [
    b'get_tlv_106',
    b'L o i c q'.replace(b' ', b'') if False else b'oicq/wlogin_sdk/tlv_type/tlv_t106',
    b'oicq/wlogin_sdk/request/k;',
    b'wlogin_sdk/tlv_type/tlv_t',
    b'_msalt',
]

def main():
    for label, path in APKS:
        if not os.path.exists(path):
            print(f'=== {label}: 文件不存在 ===')
            continue
        print(f'=== {label}  ({os.path.getsize(path)//1024//1024} MB) ===')
        z = zipfile.ZipFile(path)
        dexes = sorted(n for n in z.namelist() if n.endswith('.dex'))
        print(f'  dex 数: {len(dexes)}')
        for n in dexes:
            data = z.read(n)
            hits = {k.decode(): data.count(k) for k in KEYS if data.count(k)}
            if hits:
                short = ', '.join(f'{k}×{v}' for k, v in hits.items())
                print(f'    {n}: {short}')
        # 顺带看是否有 libfekit.so（签名库分代标志）
        sos = [n for n in z.namelist()
               if n.startswith('lib/') and n.endswith('.so')
               and ('fekit' in n or 'ckey' in n or 'wtecdh' in n or 'wlogin' in n)]
        print(f'  相关 native: {sorted(set(os.path.basename(s) for s in sos))}')
        print()
        z.close()

if __name__ == '__main__':
    main()
