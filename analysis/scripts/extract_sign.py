"""从 APK 的 v1 签名块算出 `sign` 字段。

QQ 的 `sign`（TLV 0x142）是 **APK 签名证书 DER 的 MD5**。
v1 签名时证书在 `META-INF/*.RSA`（PKCS#7 SignedData）里；
纯 v2/v3 签名的 APK 没有这个文件，需要另一条路。

本脚本做两件事：
  1. 列出 APK 的签名方案（v1 / v2 / v3）
  2. 有 v1 就解析 PKCS#7 取出第一张证书 DER 并算 MD5
"""
import zipfile
import hashlib
import struct
import os
import sys

APKS = {
    "QQ 8.2.11": r"C:\Users\Administrator\penguis\QQ-com.tencent.mobileqq-play-8.2.11.apk",
    "QQ 8.9.50": r"C:\Users\Administrator\penguis\8.9.50.apk",
    "QQ 9.3.60": r"C:\Users\Administrator\penguis\9.3.60_23e3f34e30110797.apk",
    "TIM 4.1.0.4050": r"C:\Users\Administrator\penguis\tim_4.1.0.4050.apk",
}


def der_len(d, i):
    """读 DER 长度，返回 (长度, 新偏移)。"""
    n = d[i]
    i += 1
    if n < 0x80:
        return n, i
    k = n & 0x7F
    ln = int.from_bytes(d[i:i + k], "big")
    return ln, i + k


def walk(d, i=0, depth=0, out=None):
    """收集所有 DER 节点的 (tag, start, headerlen, contentlen)。"""
    if out is None:
        out = []
    while i < len(d):
        start = i
        tag = d[i]
        i += 1
        if i >= len(d):
            break
        ln, i = der_len(d, i)
        out.append((tag, start, i - start, ln, depth))
        if tag & 0x20:  # constructed
            walk(d, i, depth + 1, out)
        i += ln
    return out


def tlv(d, i):
    """读一个 TLV，返回 (tag, node_start, content_start, content_len, end)。"""
    start = i
    tag = d[i]
    i += 1
    ln, i = der_len(d, i)
    return tag, start, i, ln, i + ln


def children(d, cstart, clen):
    """遍历一个 constructed 节点的直接子节点。"""
    i = cstart
    end = cstart + clen
    out = []
    guard = 0
    while i < end and guard < 256:
        guard += 1
        tag, start, cs, ln, e = tlv(d, i)
        if e > end or e <= i:
            break
        out.append((tag, start, cs, ln, e))
        i = e
    return out


def find_certificate(p7):
    """在 PKCS#7 SignedData 里取第一张 X.509 证书的完整 DER。

    结构：ContentInfo{ OID, [0] SignedData{ INTEGER, SET, SEQUENCE, [0] certs } }
    返回 (证书 DER 字节, 诊断信息)。
    """
    tag, _, cs, ln, _ = tlv(p7, 0)
    if tag != 0x30:
        return None, "最外层不是 SEQUENCE"
    ci = children(p7, cs, ln)
    oids = [c for c in ci if c[0] == 0x06]
    sd_holder = next((c for c in ci if c[0] == 0xA0), None)
    if not sd_holder:
        return None, f"ContentInfo 里没有 [0]；子节点 tag={[hex(c[0]) for c in ci]}"

    tag, _, cs2, ln2, _ = tlv(p7, sd_holder[2])
    if tag != 0x30:
        return None, "SignedData 不是 SEQUENCE"

    kids = children(p7, cs2, ln2)
    certs = next((c for c in kids if c[0] == 0xA0), None)
    if not certs:
        return None, f"SignedData 里没有 certificates [0]；tag={[hex(c[0]) for c in kids]}"

    cl = children(p7, certs[2], certs[3])
    if not cl:
        return None, "certificates 是空的"
    tag, start, cs3, ln3, end3 = cl[0]
    if tag != 0x30:
        return None, f"第一张证书不是 SEQUENCE（{hex(tag)}）"
    return p7[start:end3], f"证书共 {len(cl)} 张，取第一张"


for label, path in APKS.items():
    print("=" * 74)
    print(label)
    if not os.path.exists(path):
        print("  (文件不存在)")
        continue
    z = zipfile.ZipFile(path)
    names = z.namelist()

    v1 = [n for n in names if n.upper().startswith("META-INF/")
          and n.upper().endswith((".RSA", ".DSA", ".EC"))]
    print(f"  v1 签名块: {v1 if v1 else '无'}")

    # v2/v3：APK Signing Block 在 Central Directory 之前
    has_v2 = b"APK Sig Block 42" in z.read(names[0]) if names else False
    data_tail = None
    with open(path, "rb") as f:
        f.seek(max(0, os.path.getsize(path) - 4096))
        data_tail = f.read()
    marker = b"APK Sig Block 42"
    print(f"  v2/v3 签名块: {'有' if marker in data_tail else '未见（在文件末尾 4KB 内查找）'}")

    if v1:
        blob = z.read(v1[0])
        print(f"  {v1[0]} 大小 {len(blob)}")
        cert, why = find_certificate(blob)
        if cert:
            print(f"  {why}")
            print(f"  证书 DER 长度: {len(cert)}")
            print(f"  证书 DER MD5 : {hashlib.md5(cert).hexdigest()}")
            print(f"  SHA-256      : {hashlib.sha256(cert).hexdigest()}")
        else:
            print(f"  没解析出证书：{why}")
    else:
        print("  没有 v1 签名块 → sign 需要从 v2/v3 块里取证书（待做）")
