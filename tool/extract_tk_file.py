#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从真机 tk_file 里抠出 QQ 票据，生成 qq8_live_smoke.dart 的 --token-file。

## tk_file 是什么

`/data/data/<pkg>/databases/tk_file` 是 **SQLite 数据库**（不是裸文件），
由 `oicq/wlogin_sdk/request/b.java`（一个空的 `SQLiteOpenHelper`）打开。

官方读法（`oicq/wlogin_sdk/request/c.java:927-985` `a(Context, String)`）：

    query(str, new String[]{str}, "ID=0", null, null, null, null)
    cursor.getBlob(0)

即：**单表单列，表名 = 列名 = `tk_file`，只取 `ID=0` 那一行**，BLOB 是整块密文。

官方解法（同文件 `:535-591` `loadTKTreeMap`）：

    byte[] b = a(context, "tk_file");
    byte[] plain = cryptor.decrypt(b, 0, b.length, oicq.wlogin_sdk.request.t.B);
    Object obj = new ObjectInputStream(new ByteArrayInputStream(plain)).readObject();
    // obj 是 TreeMap<Long, WloginAllSigInfo>

**TEA key = `t.B`，也就是 guid**（`t.B = guid.clone()`）。

反序列化出来的结构（`oicq/wlogin_sdk/request/WloginAllSigInfo.java`）：

    mainSigMap : int
    _useInfo   : WloginSimpleInfo
    _tk_map    : TreeMap<Long, WloginSigInfo>    ← 我们只要这个
    _uin       : long

`WloginSigInfo` 里 `qq8_live_smoke.dart --token-file` 需要的字段：

    _D2         -> "d2"
    _D2Key      -> "d2key"
    _TGT        -> "tgt"
    _sKey       -> "sig_key"        （官方字段名是 _sKey）
    _wtST       / _st  -> "ticket_key"
    _srmToken   -> "srm_token"

## 为什么要这个脚本

路线 C 的目标是「不猜口令、直接用官方已经登录成功的票据跑
`wtlogin.exchange_emp`（子命令 11）」——**这条链路不经过密码校验，
是唯一能干净验证我们全部协议代码（ECDH/SSO/TEA/TLV）对错的路径**。
而票据就在这台机器的 tk_file 里，官方自己也在用它。

## 用法

    # 1) 拉下来（务必用 exec-out，shell 的 pty 会把 \\n 改成 \\r\\n 破坏二进制）
    adb exec-out "su -c 'cat /data/data/com.tencent.mobileqq/databases/tk_file'" > tk_file

    # 2) 提取（guid 从官方 wtlogin 日志的 `get current guid` 行抄，或从 identity json 取）
    python extract_tk_file.py tk_file --guid 7d9cf98da15d5c95f87507273280cbbf \\
        --uin 2089495846 --out token.json

    # 3) 用它续期
    dart run tool/qq8_live_smoke.dart --send --token-login --token-file=token.json

## 注意

- **guid 必须是写这个 tk_file 的那个客户端实例的 guid**。QQ 与 TIM 在同一台机上
  的 guid 不同（android_id 按应用签名分域），用错了解密直接失败（尾部校验不过）。
- 解密失败会打印明文的**前若干字节特征**帮助判断（是否 `AC ED 00 05` 序列化魔数）。
- 二次回退：官方在 TEA 失败后还会试 `Cipher("DESede")`，本脚本暂不实现。
"""

import argparse
import json
import sqlite3
import struct
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")


# ---------------------------------------------------------------------------
# QQ-TEA 解密（与 lib/kernel/crypto/tea.dart 同一套变体分组链）
# ---------------------------------------------------------------------------
DELTA = 0x9E3779B9
SUM_INIT_DECRYPT = 0xE3779B90


def _tea_decrypt_block(block8: bytes, key: bytes) -> bytes:
    """8 字节一块的 QQ-TEA 单块解密（16 轮，sum 从 0xE3779B90 起）。"""
    k = struct.unpack(">4I", key)
    v0, v1 = struct.unpack(">2I", block8)
    s = SUM_INIT_DECRYPT & 0xFFFFFFFF
    for _ in range(16):
        v1 = (v1 - ((((v0 << 4) + k[2]) ^ (v0 + s) ^ ((v0 >> 5) + k[3])) & 0xFFFFFFFF)) & 0xFFFFFFFF
        v0 = (v0 - ((((v1 << 4) + k[0]) ^ (v1 + s) ^ ((v1 >> 5) + k[1])) & 0xFFFFFFFF)) & 0xFFFFFFFF
        s = (s - DELTA) & 0xFFFFFFFF
    return struct.pack(">2I", v0, v1)


def qq_tea_decrypt(data: bytes, key: bytes) -> bytes:
    """QQ-TEA 解密（变体分组链）。

    明文布局：[0] = (rand & 0xF8) | pad，[1] = (rand & 0xF8) | pad，
    [2] = (rand & 0xF8) | pad，尾部 7 字节 0，最后 1 字节 pad。

    分组链（与标准 CBC 不同，这是早期版本踩过的坑）：
        B_i = P_i XOR C_{i-1}
        C_i = E(B_i) XOR B_{i-1}
    """
    if len(data) % 8 != 0 or len(data) < 16:
        raise ValueError(f"密文长度 {len(data)} 不是 8 的倍数或太短")
    n = len(data) // 8
    c = [data[i * 8:(i + 1) * 8] for i in range(n)]

    # 逐块反推：已知 C_i，求 B_i = D(C_i XOR B_{i-1})，P_i = B_i XOR C_{i-1}
    prev_b = bytes(8)  # B_{-1} = 0
    blocks = []
    for i in range(n):
        d = bytes(a ^ b for a, b in zip(c[i], prev_b))
        b = _tea_decrypt_block(d, key)
        blocks.append(b)
        prev_b = b

    plain = bytearray()
    for i in range(n):
        prev_c = c[i - 1] if i > 0 else bytes(8)
        plain += bytes(a ^ b for a, b in zip(blocks[i], prev_c))

    pad = plain[0] & 7
    data_len = len(plain) - pad - 10
    if data_len < 0:
        raise ValueError(f"填充长度非法（pad={pad}, total={len(plain)}）")
    body = bytes(plain[pad + 3:pad + 3 + data_len])
    tail = plain[pad + 3 + data_len:]
    if any(tail):
        raise ValueError(f"尾部 {len(tail)} 字节校验失败（key 不对？）")
    return body


# ---------------------------------------------------------------------------
# Java Object Serialization 最小解析器
# ---------------------------------------------------------------------------
TC_NULL = 0x70
TC_REFERENCE = 0x71
TC_CLASSDESC = 0x72
TC_OBJECT = 0x73
TC_STRING = 0x74
TC_ARRAY = 0x75
TC_CLASS = 0x76
TC_BLOCKDATA = 0x77
TC_ENDBLOCKDATA = 0x78
TC_RESET = 0x79
TC_BLOCKDATALONG = 0x7A
TC_LONGSTRING = 0x7C


class JObj:
    """反序列化出来的对象：类名 + 字段字典（字段名来自 CLASSDESC）。"""

    __slots__ = ("cls", "fields")

    def __init__(self, cls):
        self.cls = cls
        self.fields = {}

    def __repr__(self):
        return f"<{self.cls} {sorted(self.fields)}>"


class JavaDeserializer:
    """够用就好的 Java 序列化解析器：目标只有 TreeMap<Long, WloginAllSigInfo>。"""

    def __init__(self, data):
        self.d = data
        self.p = 0
        self.handles = []   # 句柄表：下标 = handle 号 - 0x7E0000

    # ---- 基础读取 ----
    def u1(self):
        v = self.d[self.p]
        self.p += 1
        return v

    def i2(self):
        v = struct.unpack_from(">h", self.d, self.p)[0]
        self.p += 2
        return v

    def u2(self):
        v = struct.unpack_from(">H", self.d, self.p)[0]
        self.p += 2
        return v

    def i4(self):
        v = struct.unpack_from(">i", self.d, self.p)[0]
        self.p += 4
        return v

    def i8(self):
        v = struct.unpack_from(">q", self.d, self.p)[0]
        self.p += 8
        return v

    def f4(self):
        v = struct.unpack_from(">f", self.d, self.p)[0]
        self.p += 4
        return v

    def f8(self):
        v = struct.unpack_from(">d", self.d, self.p)[0]
        self.p += 8
        return v

    def utf(self):
        """modified UTF-8 字符串（长度前缀 u2）。"""
        n = self.u2()
        raw = self.d[self.p:self.p + n]
        self.p += n
        # modified UTF-8：0xC0 0x80 表示 U+0000；其余与标准 UTF-8 兼容
        return raw.replace(b"\xc0\x80", b"\x00").decode("utf-8", errors="replace")

    def add_handle(self, obj):
        self.handles.append(obj)
        return obj

    def new_handle(self):
        return 0x7E0000 + len(self.handles) - 1

    # ---- 主循环 ----
    def read_object(self):
        tc = self.u1()
        if tc == TC_NULL:
            return None
        if tc == TC_REFERENCE:
            h = self.i4()
            idx = h - 0x7E0000
            if 0 <= idx < len(self.handles):
                return self.handles[idx]
            return f"<ref {h:#x}>"
        if tc == TC_STRING:
            return self.add_handle(self.utf())
        if tc == TC_LONGSTRING:
            n = self.i8()
            raw = self.d[self.p:self.p + n]
            self.p += n
            return self.add_handle(raw.decode("utf-8", errors="replace"))
        if tc == TC_OBJECT:
            return self.read_object_body()
        if tc == TC_CLASSDESC:
            # 只在 superClassDesc 位置出现（classAnnotation 里的也可能）
            return self.read_classdesc()
        if tc == TC_ARRAY:
            return self.read_array()
        if tc == TC_CLASS:
            self.read_classdesc()
            return "<class>"
        if tc == TC_BLOCKDATA:
            n = self.u1()
            raw = self.d[self.p:self.p + n]
            self.p += n
            return raw
        if tc == TC_BLOCKDATALONG:
            n = self.i4()
            raw = self.d[self.p:self.p + n]
            self.p += n
            return raw
        if tc == TC_ENDBLOCKDATA:
            return "<end>"
        if tc == TC_RESET:
            self.handles.clear()
            return self.read_object()
        raise ValueError(f"未知 type code {tc:#x} @ {self.p - 1}")

    def read_classdesc_or_ref(self):
        """读「类描述」：TC_CLASSDESC 首见 / TC_REFERENCE 复用已读过的描述符。"""
        tc = self.d[self.p]
        if tc == TC_CLASSDESC:
            self.p += 1
            return self.read_classdesc()
        if tc == TC_REFERENCE:
            self.p += 1
            h = self.i4()
            idx = h - 0x7E0000
            if 0 <= idx < len(self.handles):
                d = self.handles[idx]
                if isinstance(d, list) and len(d) == 4 and d[1] is not None:
                    return d
            raise ValueError(f"类描述引用无效 {h:#x}")
        raise ValueError(f"期望类描述，实际 {tc:#x} @ {self.p}")

    def read_classdesc(self):
        """读 CLASSDESC 体（调用方已消费 TC_CLASSDESC 0x72）。

        规范顺序：类名 UTF → **此处分配句柄** → serialVersionUID(8) →
        flags(1) → 字段数(2) → 字段… → classAnnotation → superClassDesc。
        句柄必须紧跟类名分配：后面字段的类型串（如 `Ljava/util/TreeMap;`）
        会带 TC_STRING/TC_REFERENCE，句柄号错一位就全乱。
        """
        cls = self.utf()
        # 句柄号在 serialVersionUID 之前分配（规范如此）。存完整描述符，
        # 这样同一类的第二、三次出现可以走 TC_REFERENCE 复用。
        desc = [cls, None, None, None]
        self.add_handle(desc)                 # 后文原地填字段，句柄表里同一个 list
        self.i8()                             # serialVersionUID
        flags = self.u1()
        nfields = self.u2()
        fields = []
        for _ in range(nfields):
            typecode = chr(self.u1())
            name = self.utf()
            if typecode in ("L", "["):   # 只有对象/数组字段带类名
                self.read_object()       # TC_STRING 或 TC_REFERENCE
            fields.append((name, typecode))
        # classAnnotation
        while True:
            tc = self.d[self.p]
            if tc == TC_ENDBLOCKDATA:
                self.p += 1
                break
            self.read_object()
        # superClassDesc
        super_cls = self.read_object()
        desc[1] = fields
        desc[2] = super_cls
        desc[3] = flags
        return desc

    def read_object_body(self):
        # TC_OBJECT 之后是「类描述」：首见为 TC_CLASSDESC，复用为 TC_REFERENCE
        desc = self.read_classdesc_or_ref()
        cls, fields, super_desc, _flags = desc
        obj = self.add_handle(JObj(cls))
        # 类层次：自身 + 所有父类的字段（父类在前！Java 规范是先写父类字段）
        chain = [(cls, fields)]
        s = super_desc
        while isinstance(s, list) and len(s) == 4:
            chain.append((s[0], s[1]))
            s = s[2]
        for cname, flds in reversed(chain):
            for name, tc in flds:
                if tc == "B":
                    v = struct.unpack_from(">b", self.d, self.p)[0]
                    self.p += 1
                elif tc == "C":
                    v = chr(self.u2())
                elif tc == "D":
                    v = self.i8()
                elif tc == "F":
                    v = struct.unpack_from(">f", self.d, self.p)[0]
                    self.p += 4
                elif tc == "I":
                    v = self.i4()
                elif tc == "J":
                    v = self.i8()
                elif tc == "S":
                    v = self.i2()
                elif tc == "Z":
                    v = self.u1() != 0
                elif tc in ("L", "["):
                    v = self.read_object()
                else:
                    raise ValueError(f"未知字段类型 {tc}")
                obj.fields[name] = v

        # java.util.TreeMap / HashMap 等自定义 writeObject：
        #   defaultWriteObject 之后写 TC_BLOCKDATA(int size)，再逐对写
        #   writeObject(key) / writeObject(value)。不读这段，键值对对象
        #   就永远不会进句柄表（官方 TreeMap<Long, WloginAllSigInfo> 同理）。
        if "TreeMap" in cls:
            tc = self.d[self.p]
            if tc == TC_BLOCKDATA:
                self.p += 1
                n = self.u1()
                size = int.from_bytes(self.d[self.p:self.p + n], "big", signed=True)
                self.p += n
            elif tc == TC_BLOCKDATALONG:
                self.p += 1
                n = self.i4()
                size = int.from_bytes(self.d[self.p:self.p + n], "big", signed=True)
                self.p += n
            else:
                size = 0
            pairs = []
            for _ in range(size):
                k = self.read_object()
                v = self.read_object()
                pairs.append((k, v))
            obj.fields["#entries"] = pairs
            # TreeMap.writeObject 的自定义块以 TC_ENDBLOCKDATA 收尾。
            # 不消费这个 0x78，调用方读下一个字段时会把它当成对象的
            # type code（read_object 里 TC_ENDBLOCKDATA 返回 "<end>"），
            # 于是后续所有对象整体错位——真机 tk_file 里两个账号时，
            # 第二个账号的 key 就被错当成外层的 value 读走（见 C21）。
            if self.d[self.p] == TC_ENDBLOCKDATA:
                self.p += 1
        return obj

    def read_array(self):
        # TC_ARRAY 之后同样是「类描述」：首见 CLASSDESC，复用 REFERENCE
        desc = self.read_classdesc_or_ref()
        cls, fields, _super, _flags = desc
        n = self.i4()
        elem_type = cls[1:] if cls.startswith("[") else "?"
        arr = self.add_handle([])
        for _ in range(n):
            if elem_type in "BCDFIJSZ":
                size = {"B": 1, "C": 2, "D": 8, "F": 4, "I": 4,
                        "J": 8, "S": 2, "Z": 1}[elem_type]
                raw = self.d[self.p:self.p + size]
                self.p += size
                arr.append(raw)
            else:
                arr.append(self.read_object())
        return arr

    def parse(self):
        magic = self.d[:4]
        if magic != b"\xac\xed\x00\x05":
            raise ValueError(
                f"不是 Java 序列化流（前 4 字节 {magic.hex()}，期望 aced0005）"
                "——TEA key（guid）可能不对")
        self.p = 4
        return self.read_object()


# ---------------------------------------------------------------------------
# 从反序列化结果里抽票据
# ---------------------------------------------------------------------------
def _iter_pairs(pairs):
    """把 TreeMap 的 `#entries` 规整成 [(key_value, obj), ...]。

    键是 `java.lang.Long` 包装对象，其字段 `value` 才是数值；真机上还观察到
    键/值错位的形态（键位置出现 None、值位置出现 Long），所以这里做双向容错：
    哪一边是 Long 就把它当键，另一边当值。
    """
    out = []
    for a, b in pairs:
        av = a.fields.get("value") if isinstance(a, JObj) else a
        bv = b.fields.get("value") if isinstance(b, JObj) else b
        if isinstance(a, JObj) and "WloginSigInfo" in a.cls:
            out.append((bv, a))
        elif isinstance(b, JObj) and "WloginSigInfo" in b.cls:
            out.append((av, b))
        else:
            out.append((av if av is not None else bv, b if av is not None else a))
    return out


def _as_bytes(v):
    """把解析结果统一成 bytes。

    `byte[]` 字段被 `read_array` 解成「1 字节 bytes 的 list」，不是 bytes 本身；
    `_pick` / `_hex` 都必须先过这一层，否则恒判为空。
    """
    if isinstance(v, (bytes, bytearray)):
        return bytes(v)
    if isinstance(v, list) and v and all(isinstance(x, (bytes, bytearray)) for x in v):
        return b"".join(v)
    return b""


def _hex(v):
    return _as_bytes(v).hex()


def _pick(fields, *names):
    """按候选字段名取第一个非空的 byte[]。"""
    for n in names:
        b = _as_bytes(fields.get(n))
        if b:
            return b
    return b""


def extract(token_map, uin=None):
    """（保留占位）实际的抽取逻辑在 main() 里就地实现。

    之所以不抽成函数：需要同时访问 `jd.handles`（句柄表）与对象的
    `#entries`（TreeMap 键值对），跨对象引用不便拆分。
    """
    raise NotImplementedError("见 main()")


def main():
    ap = argparse.ArgumentParser(description="从真机 tk_file 提取 QQ 票据")
    ap.add_argument("tk_file", help="从设备拉下来的 tk_file（SQLite）")
    ap.add_argument("--guid", required=True,
                    help="写这个 tk_file 的客户端 guid（32 hex）。"
                         "从官方 wtlogin 日志 `get current guid` 抄")
    ap.add_argument("--uin", type=int, default=None,
                    help="目标 uin；不给则列出文件里所有 uin")
    ap.add_argument("--out", default=None, help="输出 token json 路径")
    ap.add_argument("--pkgs", default="com.tencent.mobileqq",
                    help="包名（仅用于提示路径）")
    args = ap.parse_args()

    guid = bytes.fromhex(args.guid.strip())
    if len(guid) != 16:
        sys.exit(f"✗ --guid 必须 32 个 hex 字符（16 字节），当前 {len(guid)}")

    # ---- 1) SQLite 取 BLOB ----
    con = sqlite3.connect(f"file:{args.tk_file}?mode=ro", uri=True)
    try:
        tables = [r[0] for r in con.execute(
            "select name from sqlite_master where type='table'")]
        print(f"表: {tables}")
        if "tk_file" not in tables:
            sys.exit("✗ 没有 tk_file 表——这不是 QQ/TIM 的票据库？")
        row = con.execute("select tk_file from tk_file where ID=0").fetchone()
        if row is None:
            sys.exit("✗ tk_file 表里没有 ID=0 这一行")
        blob = bytes(row[0])
    finally:
        con.close()
    print(f"BLOB: {len(blob)} 字节（密文）")

    # ---- 2) TEA 解密 ----
    try:
        plain = qq_tea_decrypt(blob, guid)
    except Exception as e:
        sys.exit(f"✗ TEA 解密失败: {e}\n"
                 f"  guid 用错是最常见原因（QQ 与 TIM 在同一台机上 guid 不同）。\n"
                 f"  官方在 TEA 失败后还会回退 DESede，本脚本未实现。")
    magic_ok = plain[:4] == b"\xac\xed\x00\x05"
    print(f"明文: {len(plain)} 字节，前 4 字节 {plain[:4].hex()}"
          f"{'  ✓ Java 序列化魔数' if magic_ok else '  ✗ 不是序列化魔数'}")

    # ---- 3) 反序列化 ----
    jd = JavaDeserializer(plain)
    try:
        root = jd.parse()
    except Exception as e:
        sys.exit(f"✗ 反序列化失败: {e}\n  已解析到偏移 {jd.p}/{len(plain)}")
    print(f"根对象: {root!r}  剩余 {len(plain) - jd.p} 字节")

    # root 是 TreeMap<Long, WloginAllSigInfo>
    # 我们的解析器把 TreeMap 的 defaultWriteObject 字段读进 root.fields，
    # 而 size 与键值对在 root 之后的对象流里。为稳妥，直接扫 handles 里的
    # 所有 WloginAllSigInfo 对象。
    # 真机 tk_file 的根对象是 **TreeMap<Long, WloginAllSigInfo>**（外层 key 才是
    # uin），里面每个 WloginAllSigInfo 的 `_uin` 字段是 0（官方不填它），真正的
    # uin 在外层 key 和 `_useInfo._uin` 里。所以优先按外层 key 归属。
    root_entries = []
    if isinstance(root, JObj) and root.cls.endswith("TreeMap"):
        root_entries = root.fields.get("#entries") or []

    all_sig = [h for h in jd.handles
               if isinstance(h, JObj) and "WloginAllSigInfo" in h.cls]
    if not all_sig:
        print("\n句柄表里的对象类型（帮助定位）:")
        for i, h in enumerate(jd.handles):
            if isinstance(h, JObj):
                print(f"  #{i} {h.cls}")
        sys.exit("✗ 没找到 WloginAllSigInfo 对象")
    print(f"WloginAllSigInfo: {len(all_sig)} 个")

    # 外层 key -> AllSig 的映射（真机形态）
    uin_of = {}
    for k, v in root_entries:
        kv = k.fields.get("value") if isinstance(k, JObj) else k
        if isinstance(kv, int) and isinstance(v, JObj) and "WloginAllSigInfo" in v.cls:
            uin_of[id(v)] = kv

    found = []
    for a in all_sig:
        # uin 三个来源按可信度排：外层 key > _useInfo._uin > _uin
        uin = uin_of.get(id(a))
        if uin is None:
            ui = a.fields.get("_useInfo")
            if isinstance(ui, JObj):
                uin = ui.fields.get("_uin")
        if not uin:
            uin = a.fields.get("_uin", 0)
        # _tk_map 是 TreeMap<Long, WloginSigInfo>，键值对挂在 `#entries` 上
        tk = a.fields.get("_tk_map")
        pairs = []
        if isinstance(tk, JObj):
            pairs = tk.fields.get("#entries") or []
        sigs = [(kslot, v) for (kslot, v) in _iter_pairs(pairs)
                if isinstance(v, JObj) and "WloginSigInfo" in v.cls]
        if not sigs:
            # 兜底：TreeMap 没解出键值对时，退回扫句柄表
            sigs = [(None, h) for h in jd.handles
                    if isinstance(h, JObj) and "WloginSigInfo" in h.cls]
        found.append((uin, a, sigs))
        print(f"  uin={uin} mainSigMap={a.fields.get('mainSigMap')} "
              f"_tk_map 条目×{len(pairs)} WloginSigInfo×{len(sigs)}")
        for kslot, v in sigs:
            print(f"    入口 key={kslot} -> {v.cls}")

    if args.uin is not None:
        sel = [f for f in found if f[0] == args.uin]
        if not sel:
            sys.exit(f"✗ 没有 uin={args.uin}；文件里有 {[f[0] for f in found]}")
    else:
        if len(found) != 1:
            sys.exit(f"文件里有多个 uin {[f[0] for f in found]}，请用 --uin 指定")
        sel = found
    uin, allsig, sigs = sel[0]
    if not sigs:
        sys.exit("✗ 没有 WloginSigInfo")

    # 一个 WloginAllSigInfo 下有多个 WloginSigInfo（按 appid 区分）：
    #   16           = QQ 主 app（我们要的）
    #   1600000226   = 协议内部的次要 appid
    # 优先取 16，退其次取第一个有 d2 的。
    chosen = None
    for kslot, v in sigs:
        if kslot == 16 and _pick(v.fields, "_D2"):
            chosen = (kslot, v)
            break
    if chosen is None:
        for kslot, v in sigs:
            if _pick(v.fields, "_D2"):
                chosen = (kslot, v)
                break
    if chosen is None:
        sys.exit("✗ 所有 WloginSigInfo 都没有 _D2")
    kslot, sig = chosen
    print(f"\n选用入口 appid={kslot}（其余 {len(sigs) - 1} 个跳过）")
    f = sig.fields
    out = {
        "uin": uin,
        "saved_at": "extracted-from-tk_file",
        "tgt": _hex(_pick(f, "_TGT")),
        "d2": _hex(_pick(f, "_D2")),
        "d2key": _hex(_pick(f, "_D2Key")),
        "sig_key": _hex(_pick(f, "_sKey")),
        "ticket_key": _hex(_pick(f, "_wtST", "_st", "_stKey")),
        "srm_token": _hex(_pick(f, "_srmToken")),
    }
    print("\n--- 提取结果 ---")
    hex_keys = ("tgt", "d2", "d2key", "sig_key", "ticket_key", "srm_token")
    for k, v in out.items():
        if k in hex_keys:
            if v:
                print(f"  {k:11s} {len(bytes.fromhex(v)):3d} 字节  {v[:32]}…")
            else:
                print(f"  {k:11s}   -（空）")
        else:
            print(f"  {k:11s} {v!r}")
    if not out["d2"] or not out["d2key"]:
        sys.exit("✗ d2/d2key 为空 —— 这条记录不是完整登录态，无法 token 续期")

    if args.out:
        with open(args.out, "w", encoding="utf-8") as fp:
            json.dump(out, fp, ensure_ascii=False, indent=2)
        print(f"\n✓ 已写 {args.out}")
        print(f"  下一步: dart run tool/qq8_live_smoke.dart --send "
              f"--token-login --token-file={args.out}")
    else:
        print("\n（未给 --out，只打印不落盘）")


if __name__ == "__main__":
    main()
