"""提取 libckeygenerator.so 的字符串并分类汇总。

目的：判断 GenCKey / getsign 是纯本地算法还是需要联网。
导入表里已经确认存在 socket/connect/gethostbyname，需要进一步看它连的是什么。
"""
import re
import os

SO = r'C:\Users\Administrator\.dsh\workspace\apk-analysis\lib\arm64-v8a\libckeygenerator.so'
OUT = r'C:\Users\Administrator\.dsh\workspace\apk-analysis\ckey_strings.txt'

def main():
    data = open(SO, 'rb').read()
    runs = re.findall(rb'[\x20-\x7e]{6,}', data)
    strs = [r.decode('latin1') for r in runs]

    with open(OUT, 'w', encoding='utf-8') as f:
        f.write('\n'.join(strs))

    print(f'总字符串数: {len(strs)}  -> {OUT}\n')

    def show(title, pat, limit=40):
        hits = sorted({s for s in strs if re.search(pat, s, re.I)})
        print(f'=== {title} （{len(hits)} 条）===')
        for s in hits[:limit]:
            print('   ', s[:150])
        if len(hits) > limit:
            print(f'    ... 还有 {len(hits)-limit} 条')
        print()

    show('URL / 域名 / IP', r'https?://|\.com/|\.qq\.com|\.tencent\.|^https?$')
    show('签名相关', r'\bsign|ckey|ticket|encrypt|decrypt|cipher|aes|tea|rsa|md5|sha')
    show('注册/初始化', r'regist|init|module|moudle|facade')
    show('文件路径 / 加载', r'\.so$|/data/|/system/|\.cfg$|\.dat$|\.json$')
    show('错误信息', r'^error|failed|null|invalid|fail ', limit=30)

if __name__ == '__main__':
    main()
