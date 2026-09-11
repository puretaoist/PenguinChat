"""扫描 APK 内 dex，定位关键类所在的 dex 文件。

避免对 101MB dex 做全量反编译——先知道目标在哪个 dex，再定点处理。
"""
import zipfile
import sys

APK = r'C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk'

KEYS = [
    b'CKeyFacade',
    b'com/tencent/httpproxy',
    b'oicq/wlogin_sdk',
    b'GenCKey',
    b'getsign',
    b'EcdhCrypt',
    b'RSACrypt',
    b'oicq/wlogin_sdk/tools',
    b'oicq/wlogin_sdk/request',
    b'wlogin_sdk/register',
    b'CkeyMoudleInit',
    b'taskEncrypt',
]

def main():
    z = zipfile.ZipFile(APK)
    names = sorted(n for n in z.namelist() if n.endswith('.dex'))
    print(f'dex 文件数: {len(names)}\n')

    summary = {}
    for n in names:
        data = z.read(n)
        hits = {}
        for k in KEYS:
            c = data.count(k)
            if c:
                hits[k.decode()] = c
        if hits:
            summary[n] = hits

    for n in names:
        hits = summary.get(n, {})
        if hits:
            print(f'--- {n} ---')
            for k, v in hits.items():
                print(f'    {k:<28} x{v}')
        else:
            print(f'--- {n} ---  (无命中)')

if __name__ == '__main__':
    main()
