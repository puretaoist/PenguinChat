"""在 8.2.11 APK 的 dex 里找 oicq apk.name 对应的串。

oicq 表里 8.4.1 的 name 是 "A8.4.1.2703aac4"，
格式形如 A<版本>.<构建><4位十六进制>。
"""
import zipfile
import re

APK = r'C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk'
z = zipfile.ZipFile(APK)
dexes = sorted(n for n in z.namelist() if n.endswith('.dex'))

seen = set()
for n in dexes:
    data = z.read(n)
    for m in re.finditer(rb'A[0-9]\.[0-9][0-9A-Za-z._\-]{2,24}', data):
        s = m.group(0).decode('ascii', 'replace')
        seen.add(s)

print('=== 形如 A<major>.<...> 的串 ===')
for s in sorted(seen):
    print(f'  {s}')

print()
print('=== 含 0153f87a（构建哈希）的串 ===')
for n in dexes:
    data = z.read(n)
    for m in re.finditer(rb'[\x20-\x7e]{0,40}0153f87a[\x20-\x7e]{0,40}', data):
        print(f'  {m.group(0).decode("ascii", "replace")}')

print()
print('=== 含 4530 的 A 开头串 ===')
for n in dexes:
    data = z.read(n)
    for m in re.finditer(rb'A[\x20-\x7e]{0,30}4530[\x20-\x7e]{0,16}', data):
        print(f'  {m.group(0).decode("ascii", "replace")}')
