package com.example.qqclient

import android.util.Log
import oicq.wlogin_sdk.request.WUserSigInfo
import oicq.wlogin_sdk.request.WtloginMsfListener
import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket

/**
 * B 路线（官方 TIM dex + native）的传输桥。
 *
 * 为什么需要它：TIM 的 WtloginMsfListener.SendData 在「非 :MSF 进程」里会反射调用
 * CLIENT_CLASSNAME 指向的类的静态 sendData(WUserSigInfo,String,String,byte[],int,boolean,WtloginMsfListener)
 * 返回值 > 0 时自己 semp.acquire() 等回包；回包必须由我们异步调用
 * cb.onReceiveData(serviceCmd, uin, data) 投递。
 *
 * 也就是说：TLV 组包 / 签名 / 加密全部由官方 dex + native 完成，我们只负责
 * 把它已经组装好的整包按 4 字节大端长度分帧发到 msfwifi，再把响应帧交回去。
 */
object TimDataSenderBridge {
    private const val TAG = "TIMBRIDGE"

    @JvmStatic
    var host: String = "msfwifi.3g.qq.com"

    @JvmStatic
    var port: Int = 8080

    /** 调试用：把最后一次请求/响应整包 hex 落到这个路径。 */
    @JvmStatic
    var dumpFile: String? = null
    var respDir: String? = null

    /** 0 = 原样发（TIM 交给我们的字节）；1 = 外面再套一层 Dart 侧「登录信封」。 */
    @JvmStatic
    var wrapMode: Int = 0

    /** 1 = 把响应里的登录信封剥掉再交给 TIM。 */
    @JvmStatic
    var stripOuter: Int = 0

    private fun u32(n: Int): ByteArray = byteArrayOf(
        ((n ushr 24) and 0xff).toByte(), ((n ushr 16) and 0xff).toByte(),
        ((n ushr 8) and 0xff).toByte(), (n and 0xff).toByte()
    )

    private fun withLen(b: ByteArray): ByteArray {
        val o = java.io.ByteArrayOutputStream()
        o.write(u32(b.size + 4)); o.write(b); return o.toByteArray()
    }

    /** Dart `Qq8Sso.buildLoginPacket` 的外层登录信封。 */
    private fun wrapLogin(payload: ByteArray, uin: String, type: Int): ByteArray {
        val o = java.io.ByteArrayOutputStream()
        o.write(u32(0x0A))
        o.write(type)
        o.write(withLen(ByteArray(0)))          // d2 空
        o.write(0)                               // u8 0
        o.write(withLen(uin.toByteArray(Charsets.UTF_8)))
        o.write(payload)
        return withLen(o.toByteArray())
    }

    /** 反向剥离外层登录信封，返回内层 SSO 段。 */
    private fun stripLogin(b: ByteArray): ByteArray {
        var i = 0
        fun rdU32(): Int {
            val v = ((b[i].toInt() and 0xff) shl 24) or ((b[i + 1].toInt() and 0xff) shl 16) or
                    ((b[i + 2].toInt() and 0xff) shl 8) or (b[i + 3].toInt() and 0xff)
            i += 4; return v
        }
        if (b.size < 8) return b
        val magic = rdU32()
        if (magic != 0x0A) { Log.w(TAG, "strip: magic=" + magic); return b }
        i += 1                                   // type
        rdU32(); i += rdU32() - 4                // d2
        i += 1                                   // u8 0
        rdU32(); i += rdU32() - 4                // uin
        if (i >= b.size) return b
        val out = b.copyOfRange(i, b.size)
        Log.i(TAG, "strip: inner len=" + out.size + " head=" + hex(out, 24))
        return out
    }

    private fun hex(b: ByteArray, n: Int): String {
        val sb = StringBuilder()
        for (i in 0 until minOf(n, b.size)) sb.append(String.format("%02x", b[i]))
        return sb.toString()
    }


    // ===================== QQ TEA（16 轮，CBC，QQ 填充） =====================
    private const val TEA_DELTA = -0x61C88647   // 0x9E3779B9 as signed int

    private fun keyInts(key: ByteArray): IntArray = IntArray(4) { i ->
        ((key[i * 4].toInt() and 0xff) shl 24) or ((key[i * 4 + 1].toInt() and 0xff) shl 16) or
                ((key[i * 4 + 2].toInt() and 0xff) shl 8) or (key[i * 4 + 3].toInt() and 0xff)
    }

    private fun teaEncrypt(plain: ByteArray, key: ByteArray): ByteArray {
        val k = keyInts(key)
        val len = plain.size
        val r0 = (len + 10) % 8
        val pad = if (r0 == 0) 0 else 8 - r0
        val total = pad + len + 10
        val buf = ByteArray(total)
        val rnd = ByteArray(pad + 3)
        java.security.SecureRandom().nextBytes(rnd)
        buf[0] = (((rnd[0].toInt() and 0xF8) or (pad and 0x07))).toByte()
        for (i in 1..pad) buf[i] = rnd[i]
        buf[pad + 1] = rnd[pad + 1]
        buf[pad + 2] = rnd[pad + 2]
        System.arraycopy(plain, 0, buf, pad + 3, len)
        val out = ByteArray(total)
        var bPrev = ByteArray(8)
        var cPrev = ByteArray(8)
        var off = 0
        while (off < total) {
            val b = ByteArray(8) { i -> (buf[off + i].toInt() xor cPrev[i].toInt()).toByte() }
            var v0 = 0
            var v1 = 0
            for (i in 0..3) {
                v0 = (v0 shl 8) or (b[i].toInt() and 0xff)
                v1 = (v1 shl 8) or (b[i + 4].toInt() and 0xff)
            }
            var sum = 0
            var a = v0
            var bb = v1
            repeat(16) {
                sum += TEA_DELTA
                a += ((((bb shl 4) + k[0]) xor (bb + sum)) xor ((bb ushr 5) + k[1]))
                bb += ((((a shl 4) + k[2]) xor (a + sum)) xor ((a ushr 5) + k[3]))
            }
            val e = byteArrayOf(
                (a ushr 24).toByte(), (a ushr 16).toByte(), (a ushr 8).toByte(), a.toByte(),
                (bb ushr 24).toByte(), (bb ushr 16).toByte(), (bb ushr 8).toByte(), bb.toByte()
            )
            val c = ByteArray(8) { i -> (e[i].toInt() xor bPrev[i].toInt()).toByte() }
            System.arraycopy(c, 0, out, off, 8)
            bPrev = b
            cPrev = c
            off += 8
        }
        return out
    }

    private fun teaDecrypt(cipher: ByteArray, key: ByteArray): ByteArray {
        val k = keyInts(key)
        val total = cipher.size
        if (total % 8 != 0 || total < 16) throw java.io.IOException("bad tea len " + total)
        val out = ByteArray(total)
        var bPrev = ByteArray(8)
        var cPrev = ByteArray(8)
        var off = 0
        while (off < total) {
            val c = cipher.copyOfRange(off, off + 8)
            // B_i = D(C_i xor B_{i-1})
            val xb = ByteArray(8) { i -> (c[i].toInt() xor bPrev[i].toInt()).toByte() }
            var v0 = 0
            var v1 = 0
            for (i in 0..3) {
                v0 = (v0 shl 8) or (xb[i].toInt() and 0xff)
                v1 = (v1 shl 8) or (xb[i + 4].toInt() and 0xff)
            }
            var sum = TEA_DELTA * 16
            var a = v0
            var bb = v1
            repeat(16) {
                bb -= ((((a shl 4) + k[2]) xor (a + sum)) xor ((a ushr 5) + k[3]))
                a -= ((((bb shl 4) + k[0]) xor (bb + sum)) xor ((bb ushr 5) + k[1]))
                sum -= TEA_DELTA
            }
            val e = byteArrayOf(
                (a ushr 24).toByte(), (a ushr 16).toByte(), (a ushr 8).toByte(), a.toByte(),
                (bb ushr 24).toByte(), (bb ushr 16).toByte(), (bb ushr 8).toByte(), bb.toByte()
            )
            val b = e
            val p = ByteArray(8) { i -> (b[i].toInt() xor cPrev[i].toInt()).toByte() }
            System.arraycopy(p, 0, out, off, 8)
            bPrev = b
            cPrev = c
            off += 8
        }
        val pad = out[0].toInt() and 0x07
        return out.copyOfRange(pad + 3, total - 7)
    }

    private fun hexb(s: String): ByteArray {
        val o = ByteArray(s.length / 2)
        for (i in o.indices) o[i] = s.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        return o
    }

    /** 与 Dart 侧一致的信封常量（TIM 4.1.0 档案 + identity-tim 设备）。 */
    private const val SUB_ID = 537298353
    private const val SESSION_ID = "01020304"
    private const val IMEI_SLOT = "66323364643535346139663433633961"
    private const val KSID_RAW = "b3db8ece2bf594e80578a6dedda1d2f1"
    private const val KSID_ASCII = "7c7c41342e312e302e34303530"
    private const val RESERVE = "48017000800180cdc8840d900100980101a00101a80100c20100e00103"
    private const val BUF_UNKNOWN = "010000000000000000000100"

    /** TIM 的 oicq 包 → [登录信封][SSO 信封][oicq 包]（SSO 段用全零 TEA）。 */
    private fun wrapFull(payload: ByteArray, uin: String, seq: Int): ByteArray {
        val sso = java.io.ByteArrayOutputStream()
        sso.write(u32(seq))
        sso.write(u32(SUB_ID))
        sso.write(u32(SUB_ID))
        sso.write(hexb(BUF_UNKNOWN))
        sso.write(withLen(ByteArray(0)))                       // tgt 空
        sso.write(withLen("wtlogin.login".toByteArray()))      // cmd
        sso.write(withLen(hexb(SESSION_ID)))
        sso.write(withLen(hexb(IMEI_SLOT)))
        sso.write(withLen(hexb(KSID_RAW)))
        val ksid = hexb(KSID_ASCII)
        sso.write((ksid.size + 2) ushr 8); sso.write(ksid.size + 2)   // u16
        sso.write(ksid)
        sso.write(withLen(hexb(RESERVE)))
        val inner = java.io.ByteArrayOutputStream()
        inner.write(withLen(sso.toByteArray()))
        inner.write(withLen(payload))
        val enc = teaEncrypt(inner.toByteArray(), ByteArray(16))
        val outer = java.io.ByteArrayOutputStream()
        outer.write(u32(0x0A))
        outer.write(2)
        outer.write(withLen(ByteArray(0)))                     // d2 空
        outer.write(0)
        outer.write(withLen(uin.toByteArray(Charsets.UTF_8)))
        outer.write(enc)
        return withLen(outer.toByteArray())
    }

    /** 服务端响应 → TIM 需要的 oicq 包（剥登录信封、TEA 全零解密、剥 SSO 头）。 */
    private fun unwrapToOicq(frame: ByteArray): ByteArray {
        if (frame.size < 12) throw java.io.IOException("resp too short " + frame.size)
        val magic = ((frame[0].toInt() and 0xff) shl 24) or ((frame[1].toInt() and 0xff) shl 16) or
                ((frame[2].toInt() and 0xff) shl 8) or (frame[3].toInt() and 0xff)
        if (magic != 0x0A) throw java.io.IOException("resp magic " + magic)
        val flag = frame[4].toInt() and 0xff
        val d2Len = ((frame[5].toInt() and 0xff) shl 24) or ((frame[6].toInt() and 0xff) shl 16) or
                ((frame[7].toInt() and 0xff) shl 8) or (frame[8].toInt() and 0xff)
        if (d2Len != 0) throw java.io.IOException("resp d2Len " + d2Len)
        val uinLenField = frame[9].toInt() and 0xff
        val uinLen = if (uinLenField >= 4) uinLenField - 4 else uinLenField
        val ctStart = 10 + uinLen
        if (ctStart >= frame.size) throw java.io.IOException("resp uin overrun " + ctStart)
        val ct = frame.copyOfRange(ctStart, frame.size)
        val plain = when (flag) {
            0 -> ct
            2 -> teaDecrypt(ct, ByteArray(16))
            else -> throw java.io.IOException("resp flag " + flag)
        }
        var p = 0
        fun rdu32(): Int {
            val v = ((plain[p].toInt() and 0xff) shl 24) or ((plain[p + 1].toInt() and 0xff) shl 16) or
                    ((plain[p + 2].toInt() and 0xff) shl 8) or (plain[p + 3].toInt() and 0xff)
            p += 4
            return v
        }
        val ssoLen = rdu32()
        p += ssoLen - 4
        val bodyLen = rdu32()
        Log.i(TAG, "unwrapToOicq: flag=" + flag + " ssoLen=" + ssoLen + " bodyLen=" + bodyLen + " plainLen=" + plain.size)
        if (p + bodyLen - 4 > plain.size) throw java.io.IOException("body overrun " + p + "+" + (bodyLen - 4) + "/" + plain.size)
        return plain.copyOfRange(p, p + bodyLen - 4)
    }

    @JvmStatic
    fun sendData(
        sigInfo: WUserSigInfo?,
        uin: String?,
        serviceCmd: String?,
        data: ByteArray?,
        timeout: Int,
        flag: Boolean,
        cb: WtloginMsfListener?
    ): Int {
        val u = uin ?: ""
        val cmd = serviceCmd ?: ""
        val payload = data ?: ByteArray(0)
        val h = host
        val p = port
        Log.i(TAG, "sendData uin=" + u + " cmd=" + cmd + " len=" + payload.size +
                " timeout=" + timeout + " flag=" + flag + " head=" + hex(payload, 24))
        try {
            val f = dumpFile
            if (f != null) java.io.File(f).writeText("REQ " + hex(payload, payload.size))
        } catch (t: Throwable) { Log.e(TAG, "dump fail", t) }
        Thread {
            try {
                synchronized(lock) {
                val s = ensureSocket(h, p, if (timeout > 0) timeout * 1000 else 20000)
                val out = when (wrapMode) {
                    1 -> wrapLogin(payload, u, 2)
                    2 -> wrapFull(payload, u, 1)
                    else -> payload
                }
                Log.i(TAG, "wire len=" + out.size + " head=" + hex(out, 24))
                try {
                    val f2 = dumpFile
                    if (f2 != null) java.io.File(f2).writeText("REQ " + hex(payload, payload.size) + "\nWIRE " + hex(out, out.size))
                } catch (e: Throwable) {}
                s.getOutputStream().write(out)
                s.getOutputStream().flush()
                val ins: InputStream = s.getInputStream()
                val hdr = ByteArray(4)
                readFully(ins, hdr)
                val total = ((hdr[0].toInt() and 0xff) shl 24) or
                        ((hdr[1].toInt() and 0xff) shl 16) or
                        ((hdr[2].toInt() and 0xff) shl 8) or
                        (hdr[3].toInt() and 0xff)
                Log.i(TAG, "resp frame total=" + total)
                if (total < 5 || total > (4 shl 20)) throw IOException("bad frame " + total)
                val body = ByteArray(total - 4)
                readFully(ins, body)
                Log.i(TAG, "resp len=" + body.size + " head=" + hex(body, 32) + " (conn kept)");
                val payloadIn = when (stripOuter) {
                    1 -> stripLogin(body)
                    2 -> unwrapToOicq(body)
                    else -> body
                }
                Log.i(TAG, "deliver uin=" + u + " cmd=" + cmd + " len=" + payloadIn.size + " head=" + hex(payloadIn, 16))
                try {
                    val d = respDir
                    if (d != null) {
                        val f = java.io.File(d, "tim_resp_" + cmd.replace('|', '_') + ".bin")
                        f.writeBytes(payloadIn)
                        Log.i(TAG, "resp dumped to " + f.absolutePath + " len=" + payloadIn.size)
                    }
                } catch (e: Throwable) { Log.e(TAG, "dump resp fail " + e) }
                cb?.onReceiveData(u, cmd, payloadIn)
                }
            } catch (t: Throwable) {
                Log.e(TAG, "send fail: " + Log.getStackTraceString(t))
                closeSocket()
                try { cb?.onReceiveFail(u, cmd, -1000) } catch (e: Throwable) {}
            }
        }.start()
        return 1
    }

    private val lock = Any()
    private var sock: Socket? = null

    @Synchronized
    private fun closeSocket() {
        try { sock?.close() } catch (e: Throwable) {}
        sock = null
    }

    private fun ensureSocket(h: String, p: Int, soTimeoutMs: Int): Socket {
        var s = sock
        if (s == null || s.isClosed || !s.isConnected) {
            s = Socket()
            s.connect(InetSocketAddress(h, p), 10000)
            sock = s
            Log.i(TAG, "new socket to " + h + ":" + p)
        } else {
            Log.i(TAG, "reuse socket")
        }
        s.soTimeout = soTimeoutMs
        return s
    }

    private fun readFully(ins: InputStream, buf: ByteArray) {
        var off = 0
        while (off < buf.size) {
            val n = ins.read(buf, off, buf.size - off)
            if (n <= 0) throw IOException("eof after " + off + "/" + buf.size)
            off += n
        }
    }
}