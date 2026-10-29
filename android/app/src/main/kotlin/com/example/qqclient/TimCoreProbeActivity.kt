package com.example.qqclient

import android.app.Application
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.util.Log
import android.view.ViewGroup
import android.widget.Button
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.io.File
import java.lang.reflect.Modifier

/**
 * Stage-1 spike for route B: try to stand up TIM's own MSF stack inside our app.
 * Pure reflection: no compile-time reference to com.tencent.* classes (they come from
 * TIM's dex files merged into this APK).
 */
class TimCoreProbeActivity : android.app.Activity() {

    private val sb = StringBuilder()
    private var tv: TextView? = null
    private var helperRef: Any? = null
    private var sigRef: Any? = null
    private var submitted = false

    private fun log(s: String) {
        Log.i("TIMCORE", s)
        sb.append(s).append('\n')
        val t = tv ?: return
        runOnUiThread { t.append(s + "\n") }
    }

    private fun saveLog() {
        try {
            File(filesDir, "timcore-probe.txt").writeText(sb.toString())
        } catch (t: Throwable) {
            Log.e("TIMCORE", "write fail", t)
        }
    }

    private fun buildUi() {
        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setBackgroundColor(Color.parseColor("#101014"))
        val dpi = resources.displayMetrics.density
        root.setPadding(0, (56 * dpi).toInt(), 0, (24 * dpi).toInt())

        val barInner = LinearLayout(this)
        barInner.orientation = LinearLayout.VERTICAL

        fun mkBtn(label: String, action: () -> Unit) {
            val b = Button(this)
            b.text = label
            b.isAllCaps = false
            b.textSize = 15f
            b.setTextColor(Color.parseColor("#101014"))
            b.setBackgroundColor(Color.parseColor("#FFC107"))
            b.setOnClickListener { Thread { action() }.start() }
            barInner.addView(b, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        mkBtn("① 首发登录(官方栈)") { runLogin() }
        mkBtn("② 清屏") {
            sb.setLength(0)
            runOnUiThread { tv?.text = "" }
        }
        root.addView(barInner, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        val sv = ScrollView(this)
        val t = TextView(this)
        t.setTextIsSelectable(true)
        t.typeface = Typeface.MONOSPACE
        t.textSize = 10f
        t.setTextColor(Color.parseColor("#D8D8D8"))
        t.setPadding(16, 16, 16, 16)
        sv.addView(t)
        root.addView(sv, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        setContentView(root)
        tv = t
        log("就绪：点【① 首发登录】。wrap=2/strip=2（完整信封）。")
        log("结果同时写到 files/timcore-probe.txt 与 logcat TIMCORE / TIMBRIDGE。")
    }

    private fun runLogin() {
        try {
            loginProbe()
        } catch (t: Throwable) {
            log("FATAL" + Log.getStackTraceString(t))
        }
        saveLog()
        log("=== DONE ===")
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
        buildUi()
        val mode0 = intent?.getStringExtra("only")
        if (mode0 != null) {
            // adb 触发模式：自动跑一次
            Thread {
                try {
                    if (mode0 == "login") loginProbe()
                    else if (mode0 == "web") {
                        runOnUiThread {
                            val f = File(filesDir, "web-url.txt")
                            val u = if (f.exists()) f.readText().trim() else (intent?.getStringExtra("url") ?: "")
                            log(">>> web mode url=" + u.take(120))
                            if (u.isNotEmpty()) submitWithUrl(u)
                        }
                    } else run()
                } catch (t: Throwable) {
                    log("FATAL" + Log.getStackTraceString(t))
                }
                saveLog()
                Log.i("TIMCORE", "=== DONE ===")
            }.start()
        }
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
        if (mode0 == "fekitattach") {
            Thread { fekitAttachDump() }.start()
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

    companion object {
        private const val PROBE_JS = "(function(){if(window.__pq){return;}window.__pq=1;window.addEventListener('message',function(ev){try{var d=ev&&ev.data;var s=(d&&d.data)?JSON.stringify(d.data):String(d);window.PenguinCaptcha.postMessage(JSON.stringify({k:'message',t:s}));}catch(e){}});})();"
    }

    private fun dumpObj(o: Any?, label: String, depth: Int) {
        if (o == null) return
        val c = o.javaClass
        log("-- " + label + " : " + c.name)
        for (f in c.declaredFields) {
            if (java.lang.reflect.Modifier.isStatic(f.modifiers)) continue
            try {
                f.isAccessible = true
                val t = f.type
                val nm = f.name
                when {
                    t == ByteArray::class.java -> {
                        val v = f.get(o) as ByteArray?
                        if (v != null && v.isNotEmpty()) log("   " + nm + "[" + v.size + "]=" + v.take(80).joinToString("") { String.format("%02x", it) } + (if (v.size > 20) " txt=" + String(v).filter { it.code in 32..126 }.take(200) else ""))
                    }
                    t.isPrimitive || t == String::class.java -> {
                        val v = f.get(o)
                        log("   " + nm + "=" + v)
                        if (v is String && v.contains("http")) {
                            File(filesDir, "captcha-url.txt").writeText(v.trim())
                            log(">>> saved captcha-url.txt from " + nm)
                        }
                    }
                    depth > 0 && !t.name.startsWith("android.") && !t.name.startsWith("java.") -> {
                        val v = f.get(o)
                        if (v != null) dumpObj(v, label + "." + nm, depth - 1)
                    }
                }
            } catch (t: Throwable) { }
        }
    }

    @Volatile private var lastTicket: String = ""
    @Volatile private var lastRandstr: String = ""
    @Volatile private var submitScheduled = false
    @Volatile private var ticketSeq = 0

    inner class JsBridge {
        @android.webkit.JavascriptInterface
        fun postMessage(s: String?) {
            if (s == null) return
            log("JS> " + s.take(400))
            try { File(filesDir, "js_msgs.txt").appendText(System.currentTimeMillis().toString() + " " + s + "\n") } catch (t: Throwable) {}
            val u = s.replace("\\\"", "\"")
            val mt = Regex("\"ticket\"\\s*:\\s*\"([^\"]+)\"").find(u)
            val mr = Regex("\"randstr\"\\s*:\\s*\"([^\"]*)\"").find(u)
            if (mr != null) lastRandstr = mr.groupValues[1]
            if (mt != null) {
                lastTicket = mt.groupValues[1].trim()
                ticketSeq++
                log(">>> JS ticket#" + ticketSeq + " len=" + lastTicket.length + " head=" + lastTicket.take(12) + " tail=" + lastTicket.takeLast(8) + " randstr=" + lastRandstr)
                val manual = (intent?.getIntExtra("manual", 0) ?: 0) != 0
                val noSubmit = (intent?.getIntExtra("nosubmit", 0) ?: 0) != 0
                if (noSubmit) {
                    log(">>> harvest-only 票已记录，不提交 len=" + lastTicket.length)
                } else if (manual) {
                    Thread {
                        Thread.sleep(2000)
                        val t2 = lastTicket
                        log(">>> manual 提交票 len=" + t2.length + " seq=" + ticketSeq)
                        doSubmit(t2, lastRandstr)
                    }.start()
                } else if (!submitScheduled) {
                    submitScheduled = true
                    submitted = true
                    Thread {
                        Thread.sleep(12000)
                        val t = lastTicket
                        log(">>> 延迟12s提交最后一张票 len=" + t.length + " seq=" + ticketSeq)
                        doSubmit(t, lastRandstr)
                    }.start()
                }
            }
        }
    }

    private fun submitWithUrl(url: String) {
        try {
            try { android.webkit.WebView.setWebContentsDebuggingEnabled(true) } catch (e: Throwable) { log("devtools ERR " + e) }
            val wv = android.webkit.WebView(this)
            val st = wv.settings
            st.userAgentString = "Mozilla/5.0 (Linux; Android 13; HA2CSJR5 Build/TKQ1.221114.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/116.0.0.0 Mobile Safari/537.36"
            wv.setLayerType(android.view.View.LAYER_TYPE_SOFTWARE, null)
            wv.setBackgroundColor(android.graphics.Color.WHITE)
            st.useWideViewPort = false
            st.loadWithOverviewMode = false
            st.setSupportZoom(true)
            st.builtInZoomControls = true
            st.displayZoomControls = false
            wv.webChromeClient = object : android.webkit.WebChromeClient() {
                override fun onConsoleMessage(cm: android.webkit.ConsoleMessage?): Boolean {
                    if (cm != null) log("CONSOLE " + cm.message().take(200))
                    return true
                }
            }
            st.javaScriptEnabled = true
            st.domStorageEnabled = true
            st.javaScriptCanOpenWindowsAutomatically = true
            wv.addJavascriptInterface(JsBridge(), "PenguinCaptcha")
            wv.webViewClient = object : android.webkit.WebViewClient() {
                override fun onPageFinished(view: android.webkit.WebView?, u: String?) {
                    log("page finished " + (u ?: "").take(100))
                    view?.evaluateJavascript(PROBE_JS, null)
                    val v0 = view ?: return
                    val h = android.os.Handler(android.os.Looper.getMainLooper())
                    val doZoom = {
                        try {
                            v0.zoomBy(1.6f)
                            log("zoom: after zoomBy scale=" + v0.scale)
                            h.postDelayed({ try { v0.translationX = 0f; v0.translationY = 520f; log("zoom: translated") } catch (e3: Throwable) { log("zoom: tr ERR " + e3) } }, 500)
                        } catch (e: Throwable) {
                            log("zoom: zoomBy ERR " + e)
                            try { for (i in 1..4) v0.zoomIn(); log("zoom: after zoomIn x4 scale=" + v0.scale) } catch (e2: Throwable) { log("zoom: zoomIn ERR " + e2) }
                        }
                    }
                    h.postDelayed({ doZoom() }, 3000)
                }
            }
            setContentView(wv)
            window.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(android.graphics.Color.WHITE))
            wv.loadUrl(url)
            log("webview loading ...")
            val h = android.os.Handler(android.os.Looper.getMainLooper())
            val tick = object : Runnable {
                var n = 0
                override fun run() {
                    n++
                    if (submitted || n > 300) return
                    wv.evaluateJavascript(
                        "(function(){try{return location.href+'\\n'+document.body.innerText;}catch(e){return '';}})()"
                    ) { r ->
                        if (r != null && r.length > 2) {
                            val u = r.replace("\\u003C", "<").replace("\\\\", "")
                            if (n % 5 == 0) log("poll#" + n + " " + u.take(160))
                            try {
                                val jf = File(filesDir, "js_cmd.txt")
                                if (jf.exists()) {
                                    val code = jf.readText(); jf.delete()
                                    log("JSCMD " + code.take(120))
                                    wv.evaluateJavascript(code) { r2 -> log("JSRES " + (r2 ?: "null").take(1500)) }
                                }
                            } catch (t: Throwable) { }
                            if (n % 10 == 0) wv.evaluateJavascript("(function(){try{return 'H'+document.documentElement.outerHTML.length+' rs='+document.readyState+' vis='+document.visibilityState;}catch(e){return 'E'+e;}})()") { r2 -> if (r2 != null) log("poll#" + n + " " + r2.replace("\"","")) }
                            val m = Regex("[?&]ticket=([^&\"'\\\\]+)").find(u)
                                ?: Regex("\"ticket\"\\s*:\\s*\"([^\"]+)\"").find(u)
                            if (m != null && !submitted) {
                                submitted = true
                                val t = m.groupValues[1]
                                log(">>> poll 拿到 ticket(" + t.length + ")")
                                Thread { doSubmit(t) }.start()
                            }
                        }
                    }
                    h.postDelayed(this, 1200)
                }
            }
            h.postDelayed(tick, 1500)
        } catch (t: Throwable) { log("webview FAIL" + short(t)) }
    }

    // 账号与口令 MD5 一律由 adb 传入（--es uin / --es md5），默认留空：
    // 凭据不写进仓库（AGENTS.md「不提交任何凭据」）。
    private val uinArg: String get() = intent?.getStringExtra("uin") ?: ""
    private val md5Arg: String get() = intent?.getStringExtra("md5") ?: ""

    private fun errMsgOf(): String {
        return try {
            val uCls9 = Class.forName("oicq.wlogin_sdk.request.u")
            val f0 = uCls9.getDeclaredField("o0"); f0.isAccessible = true
            val map = f0.get(null) as java.util.TreeMap<*, *>
            val sb = StringBuilder()
            for ((k, v) in map) {
                val em = v.javaClass.getDeclaredField("_last_err_msg"); em.isAccessible = true
                val e = em.get(v) ?: continue
                val ft = e.javaClass.getDeclaredField("title"); ft.isAccessible = true
                val fm = e.javaClass.getDeclaredField("message"); fm.isAccessible = true
                val fy = e.javaClass.getDeclaredField("type"); fy.isAccessible = true
                sb.append(" AC[").append(k).append("]t").append(fy.get(e)).append(" ").append(ft.get(e)).append("/").append(fm.get(e))
            }
            sb.toString()
        } catch (t: Throwable) { " errMsg FAIL" }
    }

    private fun dumpAsyncCtx(label: String) {
        val uCls9 = Class.forName("oicq.wlogin_sdk.request.u")
        val f0 = uCls9.getDeclaredField("o0"); f0.isAccessible = true
        val map = f0.get(null) as java.util.TreeMap<*, *>
        log("=== async_context dump (" + label + ") size=" + map.size + " ===")
        for ((k, v) in map) dumpObj(v, "AC[" + k + "]", 1)
    }

    private fun doSubmit(ticketIn: String, randstr: String = "") {
        try {
            val h = helperRef ?: run { log("no helper"); return }
            val sig = sigRef ?: run { log("no sig"); return }
            val hCls = h.javaClass
            var m5: java.lang.reflect.Method? = null
            var m3: java.lang.reflect.Method? = null
            for (mm in hCls.declaredMethods) {
                if (mm.name != "CheckPictureAndGetSt") continue
                log("cand " + mm.parameterCount + " " + mm)
                if (mm.parameterCount == 5) m5 = mm
                if (mm.parameterCount == 3) m3 = mm
            }
            try {
                val nCls = Class.forName("oicq.wlogin_sdk.request.n")
                val useWebsig = (intent?.getIntExtra("nv", 1) ?: 1) != 0
                val vf = nCls.getDeclaredField("v"); vf.isAccessible = true; vf.setBoolean(null, useWebsig)
                log("n.v=" + useWebsig + (if (useWebsig) " (websig 0x193 形态)" else " (0x2+sig 形态)"))
            } catch (t: Throwable) { log("set n.v FAIL" + short(t)) }
            val rf = File(filesDir, "tim_resp_wtlogin.login.bin")
            val useWebsig = (intent?.getIntExtra("nv", 1) ?: 1) != 0
            val variants = if (!useWebsig || randstr.isEmpty()) listOf("raw#1" to ticketIn, "raw#2" to ticketIn, "raw#3" to ticketIn) else listOf(
                "raw" to ticketIn,
                "ticket+randstr" to (ticketIn + randstr),
                "ticket,randstr" to (ticketIn + "," + randstr),
                "randstr+ticket" to (randstr + ticketIn)
            )
            var ret = -9999
            var n = 0
            for ((vname, tk) in variants) {
                n++
                val before = if (rf.exists()) rf.length() else -1L
                val tb = tk.toByteArray(Charsets.UTF_8)
                if (m5 != null) {
                    m5.isAccessible = true
                    ret = m5.invoke(h, uinArg, tb, sig, emptyArray<ByteArray>(), 1) as Int
                } else if (m3 != null) {
                    m3.isAccessible = true
                    ret = m3.invoke(h, uinArg, tb, sig) as Int
                } else { log("no CheckPictureAndGetSt"); return }
                log(">>> attempt#" + n + " [" + vname + "] len=" + tb.size + " ret=" + ret + " resp=" + (if (rf.exists()) rf.length() else -1) + "(before " + before + ")" + errMsgOf())
                if (ret == 0) { log("*** 官方栈提交成功 ret=0 ***"); break }
                if (ret == 2) { log("*** ret=2 又是验证码，停 ***"); break }
                if (n < variants.size) Thread.sleep(8000)
            }
            runCatching { dumpAsyncCtx("AFTER-SUBMIT") }
            for (fld in sig.javaClass.fields) {
                if (fld.type == Int::class.javaPrimitiveType) log("S2." + fld.name + "=" + fld.get(sig))
            }
            log("=== submit 完成，ret 0=成功 ===")
            saveLog()
        } catch (t: Throwable) { log("submit FAIL" + short(t)) }
    }

    private fun scanTlv(buf: ByteArray) {
        var i = 0
        while (i + 4 <= buf.size) {
            val tag = ((buf[i].toInt() and 0xff) shl 8) or (buf[i + 1].toInt() and 0xff)
            val len = ((buf[i + 2].toInt() and 0xff) shl 8) or (buf[i + 3].toInt() and 0xff)
            if (tag in setOf(0x104, 0x192, 0x193, 0x547, 0x546, 0x544, 0x553, 0x105) && len in 0..(buf.size - i - 4)) {
                val v = buf.copyOfRange(i + 4, i + 4 + len)
                val hexs = v.take(64).joinToString("") { String.format("%02x", it) }
                val txt = String(v, Charsets.UTF_8)
                val printable = txt.filter { it.code in 32..126 }
                log("TLV 0x" + Integer.toHexString(tag) + " len=" + len + " hex=" + hexs +
                        (if (printable.length > 12) " txt=" + printable.take(300) else ""))
                if (tag == 0x192 && printable.contains("http")) {
                    File(filesDir, "captcha-url.txt").writeText(txt.trim { it <= ' ' })
                    log(">>> saved captcha-url.txt")
                }
            }
            i += 1
        }
    }

    private fun loginProbe() {
        TimDataSenderBridge.wrapMode = intent?.getIntExtra("wrap", 2) ?: 2
        TimDataSenderBridge.stripOuter = intent?.getIntExtra("strip", 2) ?: 2
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
                TimDataSenderBridge.respDir = filesDir.absolutePath
                val uCls2 = Class.forName("oicq.wlogin_sdk.request.u")
                val l0 = uCls2.getDeclaredField("l0"); l0.isAccessible = true
                l0.set(null, "com.example.qqclient:MSF")
                val pm = uCls2.getMethod("f").invoke(null)
                log("u.l0 set, f()=" + pm)
            } catch (t: Throwable) { log("set l0 FAIL" + short(t)) }
            val sigCls = Class.forName("oicq.wlogin_sdk.request.WUserSigInfo")
            val sig = sigCls.getConstructor().newInstance()
            helperRef = h
            sigRef = sig
            var m: java.lang.reflect.Method? = null
            for (mm in hCls.declaredMethods) {
                if (mm.name == "GetStWithPasswd" && mm.parameterCount == 11) { m = mm }
            }
            log("syncMethod=" + (m?.toString() ?: "null"))
            m?.isAccessible = true
            val args = arrayOf<Any?>(uinArg, 16L, 16724722, 1L, null, true, md5Arg, sig, null, false, 1)
            log("invoke sync GetStWithPasswd ...")
            val ret = m!!.invoke(h, *args) as Int
            log("ret(sync)=" + ret)
            try {
                val rf = File(filesDir, "tim_resp_wtlogin.login.bin")
                if (rf.exists()) {
                    log("resp file=" + rf.length() + "B, scan TLV:")
                    scanTlv(rf.readBytes())
                } else {
                    log("no resp file: " + rf.absolutePath)
                }
            } catch (t: Throwable) { log("scan FAIL" + short(t)) }
            if (ret == 2) {
                val uf = File(filesDir, "captcha-url.txt")
                if (uf.exists()) {
                    val u = uf.readText().trim()
                    log(">>> 打开验证页: " + u.take(120))
                    if (intent?.getIntExtra("junk", 0) == 1) {
                        log(">>> junk 模式：用假 ticket 提交")
                        Thread { doSubmit("junk-" + "x".repeat(180)) }.start()
                    } else {
                        runOnUiThread { submitWithUrl(u) }
                    }
                } else {
                    log(">>> 没拿到验证地址（captcha-url.txt 不存在）")
                }
            }
            try {
                val gr = hCls.getMethod("getLoginResultData", sigCls, Int::class.javaPrimitiveType).invoke(h, sig, 0) as ByteArray?
                if (gr != null) log("resultData len=" + gr.size + " head=" + gr.take(16).joinToString("") { String.format("%02x", it) })
            } catch (t: Throwable) { log("resultData FAIL") }
            for (fld in sigCls.fields) {
                if (fld.type == Int::class.javaPrimitiveType || fld.type == java.lang.Long.TYPE) {
                    log("S." + fld.name + "=" + fld.get(sig))
                }
            }
            try {
                val uCls9 = Class.forName("oicq.wlogin_sdk.request.u")
                val f0 = uCls9.getDeclaredField("o0"); f0.isAccessible = true
                val map = f0.get(null) as java.util.TreeMap<*, *>
                log("=== async_context dump (o0 size=" + map.size + ") ===")
                for ((k, v) in map) {
                    dumpObj(v, "AC[" + k + "]", 1)
                }
            } catch (t: Throwable) { log("async_context FAIL" + short(t)) }
            try {
                log("=== helper 2-level dump ===")
                for (f in hCls.declaredFields) {
                    if (java.lang.reflect.Modifier.isStatic(f.modifiers)) continue
                    val t = f.type
                    if (t.isPrimitive || t == String::class.java || t == Context::class.java) continue
                    try {
                        f.isAccessible = true
                        dumpObj(f.get(h), "H." + f.name, 2)
                    } catch (e: Throwable) { }
                }
            } catch (t: Throwable) { log("dump FAIL" + short(t)) }
            for (fld in sigCls.fields) {
                if (fld.type == ByteArray::class.java) {
                    fld.isAccessible = true
                    val v = fld.get(sig) as ByteArray?
                    if (v != null && v.isNotEmpty()) {
                        log("S.bytes." + fld.name + " len=" + v.size + " hex=" + v.take(260).joinToString("") { String.format("%02x", it) })
                    }
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

    /**
     * 直接向 TIM 的 QSec 要 FEKit attach（TLV 0x553 的 body）。
     *
     * 用处：0x553 是 9.3.60/TIM 密码包里多出来的唯一一条 TLV，body 来自
     * native libfekit；我们在 Dart 里造不出来，只能从这里取真值，再喂给
     * `tool/qq8_live_smoke.dart --t553=<hex>` 做 A/B。
     *
     * 用法：am start -n <pkg>/com.example.qqclient.TimCoreProbeActivity
     *        --es only fekitattach --es uin <uin>
     * 产物：files/fekit-9.hex / fekit-2.hex / fekit-a.hex / fekit-f.hex + logcat。
     */
    private fun fekitAttachDump() {
        log("=== fekitattach start")
        loadLib("c++_shared")
        loadLib("QSec")
        loadLib("fekit")
        // native 侧要用 BaseApplication 这个静态 context，先造一个（同 run()）
        try {
            val baCls = Class.forName("com.tencent.qphone.base.util.BaseApplication")
            val ba = baCls.getDeclaredConstructor().newInstance()
            val attach = android.content.ContextWrapper::class.java
                .getDeclaredMethod("attachBaseContext", Context::class.java)
            attach.isAccessible = true
            attach.invoke(ba, applicationContext)
            val f = baCls.getDeclaredField("context")
            f.isAccessible = true
            f.set(null, ba)
            log("BaseApplication ready for fekit")
        } catch (t: Throwable) {
            log("BaseApplication FAIL" + short(t))
        }
        val uin = intent?.getStringExtra("uin") ?: ""
        log("uin=" + uin)
        val qsecCls = Class.forName("com.tencent.mobileqq.qsec.qsecurity.QSec")
        val qsec = qsecCls.getMethod("getInstance").invoke(null)
        val m = qsecCls.getMethod(
            "getFeKitAttach",
            Context::class.java, String::class.java, String::class.java, String::class.java,
        )
        for (sub in listOf("0x9", "0x2", "0xA", "0xF")) {
            try {
                val b = m.invoke(qsec, applicationContext, uin, "0x810", sub) as? ByteArray
                val hex = b?.joinToString("") { String.format("%02x", it) } ?: ""
                log("FEKIT sub=" + sub + " len=" + (b?.size ?: -1) + " hex=" + hex)
                File(filesDir, "fekit-" + sub.removePrefix("0x") + ".hex").writeText(hex)
            } catch (t: Throwable) {
                log("FEKIT sub=" + sub + " FAIL" + short(t))
                val c = t.cause
                if (c != null) log("stack: " + Log.getStackTraceString(c).take(2000))
            }
        }
        log(">>> fekitattach done")
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