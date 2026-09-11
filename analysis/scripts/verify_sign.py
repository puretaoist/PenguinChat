"""确认 sign 字段的来源，并在 dex 中搜索 AppInfo 相关常量。

已验证：sign = APK 签名证书 DER 的 MD5，
       8.2.11 play 与 oicq 记录的 8.4.1 值完全相同（a6b745bf24a2c277527716f6f36eb68d）。
本脚本进一步：
  1. 在 dex 里搜这个 16 字节序列，确认 QQ 自己也在用它
  2. 打印 8.2.11.4530 附近的可读字符串，定位 AppInfo 表位置
  3. 搜 WLogin 相关类名
"""
import zipfile
import re

APK = r'C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk'
SIGN_BYTES = bytes.fromhex('a6b745bf24a2c277527716f6f36eb68d')
FULLVER = b'8.2.11.4530'


def readable_around(data, pos, before=64, after=200):
    seg = data[max(0, pos - before):pos + after]
    return re.sub(rb'[^\x20-\x7e]', b'.', seg).decode('ascii')


def main():
    z = zipfile.ZipFile(APK)
    dexes = sorted(n for n in z.namelist() if n.endswith('.dex'))

    print('=' * 66)
    print('【1】dex 中是否出现 sign 字节序列 a6b745bf...')
    print('=' * 66)
    found = False
    for n in dexes:
        data = z.read(n)
        start = 0
        while True:
            i = data.find(SIGN_BYTES, start)
            if i < 0:
                break
            found = True
            print(f'  {n} @ 0x{i:x}')
            print(f'    上下文: {readable_around(data, i)}')
            start = i + 1
    if not found:
        print('  未找到（可能以 base64/十六进制字符串形式存放，或运行时从证书计算）')

    # 也搜字符串形式
    for pat in (b'a6b745bf', b'A6B745BF', b'a6b745bf24a2c277527716f6f36eb68d'):
        for n in dexes:
            if pat in z.read(n):
                print(f'  字符串形式 {pat!r} 命中 {n}')

    print()
    print('=' * 66)
    print('【2】8.2.11.4530 附近的可读上下文（定位 AppInfo 表）')
    print('=' * 66)
    shown = 0
    for n in dexes:
        data = z.read(n)
        start = 0
        while shown < 12:
            i = data.find(FULLVER, start)
            if i < 0:
                break
            print(f'  --- {n} @ 0x{i:x} ---')
            print(f'    {readable_around(data, i, 80, 180)}')
            start = i + 1
            shown += 1
    if shown == 0:
        print('  未找到')

    print()
    print('=' * 66)
    print('【3】WLogin / 协议相关类名')
    print('=' * 66)
    keys = [b'oicq/wlogin_sdk/request', b'oicq/wlogin_sdk/tools', b'AppInfo',
            b'wtlogin', b'WtLogin', b'sigmap', b'bitmap', b'qua']
    for k in keys:
        hits = [(n, z.read(n).count(k)) for n in dexes]
        hits = [(n, c) for n, c in hits if c]
        if hits:
            print(f'  {k.decode():<26} {hits}')


if __name__ == '__main__':
    main()
