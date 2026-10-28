package com.example.qqclient

import android.app.Application
import android.content.Context
import android.os.Bundle
import android.util.Log
import java.io.File
import java.lang.reflect.Modifier

/**
 * Stage-1 spike for route B: try to stand up TIM's own MSF stack inside our app.
 * Pure reflection: no compile-time reference to com.tencent.* classes (they come from
 * TIM's dex files merged into this APK).
 */
class TimCoreProbeActivity : android.app.Activity() {

    private val sb = StringBuilder()

    private fun log(s: String) {
        Log.i("TIMCORE", s)
        sb.append(s).append('\n')
    }

    private fun short(t: Throwable, depth: Int = 6): String {
        val out = StringBuilder()
        var e: Throwable? = t
        var i = 0
        while (e != null && i < depth) {
            out.append(" <- ").append(e.javaClass.name).append(": ").append(e.message)
            e = e.cause
            i++
        }
        return out.toString()
    }

    private fun loadLib(name: String): Boolean {
        return try {
            System.loadLibrary(name)
            log("load $name OK")
            true
        } catch (t: Throwable) {
            log("load $name FAIL" + short(t, 2))
            false
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val out = File(filesDir, "timcore-probe.txt")
        try {
            run()
        } catch (t: Throwable) {
            log("FATAL" + Log.getStackTraceString(t))
        }
        try {
            out.writeText(sb.toString())
        } catch (t: Throwable) {
            Log.e("TIMCORE", "write fail", t)
        }
        Log.i("TIMCORE", "=== DONE ===")
    }

    private fun run() {
        log("=== stage1 start PROBEVER-3, pid=" + android.os.Process.myPid() + " process=" + Application.getProcessName())

        val mode0 = intent?.getStringExtra("only")
        if (mode0 == "helper") {
            helperProbe(false)
            return
        }
        if (mode0 == "helperreal") {
            helperProbe(true)
            return
        }
        if (mode0 == "login") {
            Thread { loginProbe() }.start()
            return
        }
        if (mode0 == "helperapi") {
            helperApi()
            return
        }
        if (intent?.getStringExtra("only") == "reflect") {
            reflectDump()
            return
        }

        // 1) load natives that MSF/wtlogin need
        loadLib("c++_shared")
        val only = intent?.getStringExtra("only") ?: "msfkernel"
        when (only) {
            "all" -> {
                loadLib("wtecdh")
                loadLib("codecwrapperV2")
                loadLib("msfbootV2")
                loadLib("MMANDKSignature")
                loadLib("QSec")
                loadLib("fekit")
                loadLib("MSFKernel")
            }
            "qsec" -> { loadLib("QSec") }
            "fekit" -> { loadLib("fekit") }
            else -> { loadLib("MSFKernel") }
        }

        // 2) make a real BaseApplication instance and publish it as the static context
        try {
            val baCls = Class.forName("com.tencent.qphone.base.util.BaseApplication")
            val ba = baCls.getDeclaredConstructor().newInstance()
            // attachBaseContext is protected on ContextWrapper
            val attach = android.content.ContextWrapper::class.java.getDeclaredMethod("attachBaseContext", Context::class.java)
            attach.isAccessible = true
            attach.invoke(ba, applicationContext)
            val f = baCls.getDeclaredField("context")
            f.isAccessible = true
            f.set(null, ba)
            log("BaseApplication ready: " + baCls.name + " ctx=" + (baCls.getMethod("getContext").invoke(null) != null))
        } catch (t: Throwable) {
            log("BaseApplication FAIL" + short(t))
        }

        // 3) MsfCore init
        try {
            val coreCls = Class.forName("com.tencent.mobileqq.msf.core.MsfCore")
            val core = coreCls.getDeclaredConstructor().newInstance()
            log("MsfCore instantiated")
            val init = coreCls.getMethod("init", Context::class.java, Boolean::class.javaPrimitiveType)
            val ok = init.invoke(core, applicationContext, true)
            log("MsfCore.init returned " + ok)
        } catch (t: Throwable) {
            log("MsfCore.init FAIL" + short(t))
            val c = t.cause
            if (c != null) log("stack: " + Log.getStackTraceString(c).take(4000))
        }

        // 4) can we even build a WtloginHelper?
        try {
            val hCls = Class.forName("oicq.wlogin_sdk.request.WtloginHelper")
            val h = hCls.getConstructor(Context::class.java).newInstance(this)
            log("WtloginHelper(Context) OK -> " + h.javaClass.name)
        } catch (t: Throwable) {
            log("WtloginHelper FAIL" + short(t))
            val c = t.cause
            if (c != null) log("stack: " + Log.getStackTraceString(c).take(4000))
        }
    }

    private fun defaultFor(t: Class<*>): Any? = when (t) {
        java.lang.Boolean.TYPE -> false
        java.lang.Integer.TYPE -> 0
        java.lang.Long.TYPE -> 0L
        java.lang.Short.TYPE -> 0.toShort()
        java.lang.Byte.TYPE -> 0.toByte()
        java.lang.Float.TYPE -> 0f
        java.lang.Double.TYPE -> 0.0
        else -> null
    }

    private fun helperProbe(useReal: Boolean) {
        loadLib("c++_shared")
        loadLib("mmkv")
        try {
            val iface = Class.forName("com.tencent.mobileqq.qmmkv.MMKVHandlerBase")
            val ifaces = mutableListOf<Class<*>>(iface)
            for (n in listOf("com.tencent.mobileqq.qmmkv.v2.g", "com.tencent.mobileqq.qmmkv.g")) {
                try {
                    val c = Class.forName(n, false, javaClass.classLoader)
                    log("extra iface " + n + " isInterface=" + c.isInterface)
                    if (c.isInterface && !ifaces.contains(c)) ifaces.add(c)
                } catch (t: Throwable) { log("extra iface " + n + " MISSING") }
            }
            val proxy = java.lang.reflect.Proxy.newProxyInstance(javaClass.classLoader, ifaces.toTypedArray()) { _, m, _ ->
                when {
                    m.name == "isFileAvailable" -> true
                    m.returnType == Void.TYPE -> null
                    m.returnType.isInterface -> java.lang.reflect.Proxy.newProxyInstance(javaClass.classLoader, arrayOf(m.returnType)) { _, m2, _ -> if (m2.returnType == Void.TYPE) null else defaultFor(m2.returnType) }
                    else -> defaultFor(m.returnType)
                }
            }
            val qmmkv = Class.forName("com.tencent.mobileqq.qmmkv.QMMKV")
            val init = qmmkv.getMethod("initializeInternal", Context::class.java, iface)
            if (useReal) {
                init.invoke(null, applicationContext, null as Any?)
                log("initializeInternal(real handler) invoked")
            } else {
                init.invoke(null, applicationContext, proxy)
            }
            val fInited = qmmkv.getDeclaredField("mmkvInited"); fInited.isAccessible = true
            log("QMMKV.initializeInternal OK, mmkvInited=" + fInited.get(null))
            val hField = qmmkv.getDeclaredField("mmkvFileHandler"); hField.isAccessible = true
            val handler = hField.get(null)
            log("handler=" + handler?.javaClass?.name)
            val mFile = iface.getMethod("isFileAvailable", String::class.java)
            log("isFileAvailable(wtlogin_mmkv_file)=" + mFile.invoke(handler, "wtlogin_mmkv_file"))
        } catch (t: Throwable) {
            log("QMMKV init FAIL" + short(t))
            val c = t.cause
            if (c != null) log("stack: " + Log.getStackTraceString(c).take(3000))
        }
        try {
            val hCls = Class.forName("oicq.wlogin_sdk.request.WtloginHelper")
            val h = hCls.getConstructor(Context::class.java).newInstance(this)
            log("WtloginHelper(Context) OK")
            val sender = hCls.getMethod("getWtDataSender").invoke(h)
            log("wtDataSender = " + sender)
        } catch (t: Throwable) {
            log("WtloginHelper FAIL" + short(t))
            val c = t.cause
            if (c != null) log("stack: " + Log.getStackTraceString(c).take(3000))
        }
    }

    private fun loginProbe() {
        TimDataSenderBridge.wrapMode = intent?.getIntExtra("wrap", 0) ?: 0
        TimDataSenderBridge.stripOuter = intent?.getIntExtra("strip", 0) ?: 0
        log("wrap=" + TimDataSenderBridge.wrapMode + " strip=" + TimDataSenderBridge.stripOuter)
        loadLib("c++_shared")
        loadLib("mmkv")
        try {
            val iface = Class.forName("com.tencent.mobileqq.qmmkv.MMKVHandlerBase")
            val qmmkv = Class.forName("com.tencent.mobileqq.qmmkv.QMMKV")
            qmmkv.getMethod("initializeInternal", Context::class.java, iface).invoke(null, applicationContext, null as Any?)
            log("qmmkv inited")
        } catch (t: Throwable) {
            log("qmmkv FAIL" + short(t, 3))
            return
        }
        try {
            val plCls = Class.forName("oicq.wlogin_sdk.listener.PrivacyListener")
            val proxy = java.lang.reflect.Proxy.newProxyInstance(plCls.classLoader, arrayOf(plCls)) { _, m, _ ->
                when (m!!.name) {
                    "getAndroidID" -> "f23dd554a9f43c9a"
                    "getMac" -> "02:00:00:00:00:00"
                    "getBssid" -> "02:00:00:00:00:00"
                    "getSsid" -> "\"i-HDU\""
                    "getDeviceModel" -> "25091RP04C"
                    "getImsi" -> ""
                    else -> null
                }
            }
            val util = Class.forName("oicq.wlogin_sdk.tools.util")
            val f = util.getDeclaredField("privacyListener")
            f.isAccessible = true
            f.set(null, proxy)
            log("privacyListener set")
        } catch (t: Throwable) { log("privacy FAIL" + short(t)) }
        try {
            val msfCls = Class.forName("oicq.wlogin_sdk.request.WtloginMsfListener")
            val cf = msfCls.getDeclaredField("CLIENT_CLASSNAME")
            cf.isAccessible = true
            cf.set(null, "com.example.qqclient.TimDataSenderBridge")
            log("CLIENT_CLASSNAME=" + cf.get(null))
        } catch (t: Throwable) { log("CLIENT_CLASSNAME FAIL" + short(t)) }
        try {
            val fDev = java.io.File(filesDir, "wlogin_device.dat")
            if (fDev.exists()) log("deleted wlogin_device.dat=" + fDev.delete())
            try {
                val uu = Class.forName("oicq.wlogin_sdk.tools.util")
                val fl = uu.getDeclaredField("LOGCAT_OUT"); fl.isAccessible = true; fl.setBoolean(null, true)
                val flv = uu.getDeclaredField("LOG_LEVEL"); flv.isAccessible = true; flv.setInt(null, 2)
                log("LOGCAT_OUT=true LOG_LEVEL=2")
            } catch (t: Throwable) { log("log enable FAIL" + short(t)) }
            val ua = Class.forName("oicq.wlogin_sdk.utils.a")
            val fa = ua.getDeclaredField("a"); fa.isAccessible = true; fa.set(null, "f23dd554a9f43c9a")
            log("utils.a.a=" + fa.get(null))
        } catch (t: Throwable) { log("identity pre FAIL" + short(t)) }
        try {
            val uCls0 = Class.forName("oicq.wlogin_sdk.request.u")
            val g0 = uCls0.getDeclaredField("g0"); g0.isAccessible = true
            val guidHex = "e0aebbd3a617abd2dee808576a2904cf"
            val gb = ByteArray(16) { guidHex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
            g0.set(null, gb)
            log("u.g0 set=" + guidHex)
        } catch (t: Throwable) { log("u.g0 FAIL" + short(t)) }
        try {
            val hCls = Class.forName("oicq.wlogin_sdk.request.WtloginHelper")
            val h = hCls.getConstructor(Context::class.java).newInstance(this)
            log("helper ok")
            try {
                var uInst: Any? = null
                for (f in hCls.declaredFields) {
                    if (f.type.name == "oicq.wlogin_sdk.request.u") {
                        f.isAccessible = true
                        uInst = f.get(h)
                        log("u field name=" + f.name)
                    }
                }
                if (uInst == null) {
                    val sb = StringBuilder()
                    for (f in hCls.declaredFields) sb.append(f.name).append(':').append(f.type.simpleName).append(' ')
                    log("ALLFIELDS " + sb)
                } else {
                    val uCls = uInst.javaClass
                    for (n in arrayOf("i","j")) {
                        try {
                            val fx = uCls.getDeclaredField(n); fx.isAccessible = true
                            log("u." + n + " old=" + fx.getInt(uInst))
                            fx.setInt(uInst, if (n == "i") 1 else 8000)
                            log("u." + n + " new=" + fx.getInt(uInst))
                        } catch (t: Throwable) { log("u." + n + " FAIL" + short(t)) }
                    }
                }
            } catch (t: Throwable) { log("set u.i FAIL" + short(t)) }
            try {
                TimDataSenderBridge.dumpFile = java.io.File(filesDir, "tim_req.hex").absolutePath
                val uCls2 = Class.forName("oicq.wlogin_sdk.request.u")
                val l0 = uCls2.getDeclaredField("l0"); l0.isAccessible = true
                l0.set(null, "com.example.qqclient:MSF")
                val pm = uCls2.getMethod("f").invoke(null)
                log("u.l0 set, f()=" + pm)
            } catch (t: Throwable) { log("set l0 FAIL" + short(t)) }
            val sigCls = Class.forName("oicq.wlogin_sdk.request.WUserSigInfo")
            val sig = sigCls.getConstructor().newInstance()
            var m: java.lang.reflect.Method? = null
            for (mm in hCls.declaredMethods) {
                if (mm.name == "GetStWithPasswd" && mm.parameterCount == 11) { m = mm }
            }
            log("syncMethod=" + (m?.toString() ?: "null"))
            m?.isAccessible = true
            val args = arrayOf<Any?>("3499239040", 16L, 16724722, 1L, null, true, "00000000000000000000000000000000", sig, null, false, 1)
            log("invoke sync GetStWithPasswd ...")
            val ret = m!!.invoke(h, *args) as Int
            log("ret(sync)=" + ret)
            try {
                val gr = hCls.getMethod("getLoginResultData", sigCls, Int::class.javaPrimitiveType).invoke(h, sig, 0) as ByteArray?
                if (gr != null) log("resultData len=" + gr.size + " head=" + gr.take(16).joinToString("") { String.format("%02x", it) })
            } catch (t: Throwable) { log("resultData FAIL") }
            for (fld in sigCls.fields) {
                if (fld.type == Int::class.javaPrimitiveType || fld.type == java.lang.Long.TYPE) {
                    log("S." + fld.name + "=" + fld.get(sig))
                }
            }
            val st = Class.forName("oicq.wlogin_sdk.request.u")
            for (fn in listOf("D", "E", "G", "H", "I")) {
                try {
                    val ff = st.getDeclaredField(fn)
                    ff.isAccessible = true
                    val v = ff.get(null)
                    if (v is ByteArray) log("u." + fn + "=" + v.joinToString("") { String.format("%02x", it) })
                } catch (t: Throwable) {}
            }
        } catch (t: Throwable) {
            log("LOGIN FAIL" + short(t))
            val c = t.cause
            if (c != null) log("stack: " + Log.getStackTraceString(c).take(3000))
        }
    }

    private fun helperApi() {
        loadLib("c++_shared")
        loadLib("mmkv")
        try {
            val iface = Class.forName("com.tencent.mobileqq.qmmkv.MMKVHandlerBase")
            val qmmkv = Class.forName("com.tencent.mobileqq.qmmkv.QMMKV")
            qmmkv.getMethod("initializeInternal", Context::class.java, iface).invoke(null, applicationContext, null as Any?)
            log("qmmkv inited")
        } catch (t: Throwable) { log("qmmkv FAIL" + short(t, 3)) }
        try {
            val hCls = Class.forName("oicq.wlogin_sdk.request.WtloginHelper")
            val h = hCls.getConstructor(Context::class.java).newInstance(this)
            log("WtloginHelper OK")
            for (m in hCls.declaredMethods) {
                val n = m.name
                if (n.contains("GetSt") || n.contains("Login") || n.contains("WtDataSender") || n.contains("CommitST") || n.contains("CheckPicture") || n.contains("QuickLogin")) {
                    log("H." + n + "(" + m.parameterTypes.joinToString(",") { it.name } + "):" + m.returnType.name)
                }
            }
            for (f in hCls.declaredFields) {
                if (!f.name.contains("HelperHandler")) log("HF " + f.name + ":" + f.type.name)
            }
        } catch (t: Throwable) {
            log("WtloginHelper FAIL" + short(t))
            val c = t.cause
            if (c != null) log("stack: " + Log.getStackTraceString(c).take(2500))
        }
        for (cn in listOf("oicq.wlogin_sdk.request.IWtDataSender", "com.tencent.mobileqq.msf.sdk.MsfServiceSdk")) {
            try {
                val c = Class.forName(cn, false, javaClass.classLoader)
                log("== " + cn + " iface=" + c.isInterface)
                for (m in c.declaredMethods) log("   " + (if (Modifier.isStatic(m.modifiers)) "S " else "") + m.name + "(" + m.parameterTypes.joinToString(",") { it.name } + "):" + m.returnType.name)
            } catch (t: Throwable) { log("== " + cn + " MISSING") }
        }
    }

    private fun reflectDump() {
        val names = listOf(
            "com.tencent.mobileqq.qmmkv.v2.MMKVOptionEntityV2",
            "com.tencent.mobileqq.qmmkv.QMMKV",
            "com.tencent.mobileqq.qmmkv.v2.g",
            "com.tencent.mobileqq.qmmkv.g",
            "oicq.wlogin_sdk.persistence.a",
            "oicq.wlogin_sdk.utils.a"
        )
        for (cn in names) {
            try {
                val c = Class.forName(cn, false, javaClass.classLoader)
                log("== " + cn + " iface=" + c.isInterface)
                for (k in c.declaredConstructors) log("   C (" + k.parameterTypes.joinToString(",") { it.name } + ")")
                for (m in c.declaredMethods) {
                    log("   " + (if (Modifier.isStatic(m.modifiers)) "S " else "") + m.name + "(" + m.parameterTypes.joinToString(",") { it.name } + "):" + m.returnType.name)
                }
                for (f in c.declaredFields) log("   F " + f.name + ":" + f.type.name)
            } catch (t: Throwable) {
                log("== " + cn + " MISSING " + short(t, 2))
            }
        }
}
}