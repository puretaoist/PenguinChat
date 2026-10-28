package com.example.qqclient

import android.app.Activity
import android.os.Bundle
import android.util.Log
import com.tencent.mobileqq.qsec.qsecdandelionsdk.Dandelion
import com.tencent.mobileqq.qsec.qsecurity.QSec
import java.io.File

/**
 * 一次性探针 Activity：把 TIM 的 native 安全库装进我们自己的 APK（包名 com.example.qqclient、
 * 签名是 debug key），看 ①JNI_OnLoad 能不能在「非腾讯宿主」里完成注册 ②energy() 还出不出签名。
 * 只在真机上 adb am start 手动拉起，不参与正常启动流程。
 *
 * 批处理模式：若 files/fekit_req.txt 存在，每行 `moduleId|bodyHex`，
 * 结果写 files/fekit_res.txt，每行 `moduleId|len|hex`。用于从 PC 侧喂任意 salt 取真签。
 */
class FekitProbeActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val sb = StringBuilder()

        fun step(name: String, body: () -> Unit) {
            val t0 = System.currentTimeMillis()
            try {
                body()
                sb.append("OK   ${name}  (${System.currentTimeMillis() - t0}ms)\n")
            } catch (t: Throwable) {
                sb.append("FAIL ${name}: ${t::class.java.name}: ${t.message}\n")
            }
        }

        fun hex(b: ByteArray?): String =
            if (b == null) "null" else b.take(48).joinToString("") { "%02x".format(it) } +
                (if (b.size > 48) "...(${b.size}B)" else "(${b.size}B)")

        step("load wtecdh") { System.loadLibrary("wtecdh") }
        step("load MMANDKSignature") { System.loadLibrary("MMANDKSignature") }
        step("load QSec") { System.loadLibrary("QSec") }
        step("load fekit") { System.loadLibrary("fekit") }

        step("Dandelion.fly(0x810, 64B)") {
            val r = Dandelion.getInstance().fly("0x810", ByteArray(64) { 0x41 })
            sb.append("     -> ${hex(r)}\n")
        }
        step("Dandelion.fly(0x810, 0B)") {
            val r = Dandelion.getInstance().fly("0x810", ByteArray(0))
            sb.append("     -> ${hex(r)}\n")
        }
        step("QSec.getXwDebugID(uin)") {
            val r = QSec.getInstance().probeXwDebugId("3499239040")
            val hx = r?.joinToString("") { "%02x".format(it) } ?: "null"
            sb.append("     -> len=${r?.size ?: -1} hex=$hx\n")
        }
        step("QSec.doSomething(ctx, 2)") {
            sb.append("     -> rc=${QSec.getInstance().probeDoSomething(this, 2)}\n")
        }
        for (sub in listOf("0x9", "0xf", "0xa", "0x19", "0x7", "0x14")) {
            step("QSec.getFeKitAttach(uin,\"0x810\",\"$sub\")") {
                val r = QSec.getInstance().probeFeKitAttach(this, "3499239040", "0x810", sub)
                val hx = r?.joinToString("") { "%02x".format(it) } ?: "null"
                sb.append("     -> len=${r?.size ?: -1} hex=$hx\n")
            }
        }

        // ── 批处理：喂任意 moduleId + salt，取真签 ──
        val req = File(filesDir, "fekit_req.txt")
        if (req.exists()) {
            val out = StringBuilder()
            req.readLines().forEach { line ->
                val s = line.trim()
                if (s.isEmpty() || s.startsWith("#")) return@forEach
                val parts = s.split("|")
                if (parts.size < 2) { out.append("BADLINE ${s.take(40)}\n"); return@forEach }
                val modId = parts[0].trim()
                val bodyHex = parts[1].trim()
                try {
                    val body = if (bodyHex.isEmpty()) ByteArray(0) else
                        ByteArray(bodyHex.length / 2) { i ->
                            bodyHex.substring(i * 2, i * 2 + 2).toInt(16).toByte()
                        }
                    val t0 = System.currentTimeMillis()
                    val r = Dandelion.getInstance().fly(modId, body)
                    val hx = r?.joinToString("") { "%02x".format(it) } ?: "null"
                    out.append("$modId|${r?.size ?: -1}|$hx|${System.currentTimeMillis() - t0}ms\n")
                } catch (t: Throwable) {
                    out.append("$modId|ERR|${t::class.java.name}: ${t.message}\n")
                }
            }
            File(filesDir, "fekit_res.txt").writeText(out.toString())
            sb.append("OK   batch: ${out.lines().size} lines -> fekit_res.txt\n")
        }

        val text = sb.toString()
        Log.i("FEKITPROBE", "==== probe begin ====\n$text==== probe end ====")
        try { File(filesDir, "fekit-probe.txt").writeText(text) } catch (_: Throwable) {}
    }
}
