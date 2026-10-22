package com.example.qqclient

import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import java.io.File

/**
 * 本机设备信息采集。
 *
 * ## 这个文件为什么存在
 *
 * 服务端判「这是不是一台它见过的设备」看的是固定几个字段。以前我们在
 * Dart 侧自己编一台设备（`Qq8Device.generate`），编出来的东西
 * `brand=OICQX`、`model=Konata 2020` 在现实里不存在，且自称 Android 10
 * 却跑在 Android 16 的机器上——两个都是白送的破绽。
 *
 * 这里把官方 `oicq.wlogin_sdk.tools.util` 读的那些字段**用同一套系统 API**
 * 读出来（逐项对齐见 `analysis/QQ-官方三版本登录流程对照.md`）。
 *
 * ## 字段名与 Dart 侧严格一致
 *
 * 键名与 `identity.json` / `Qq8DeviceIdentity.fromJson` 完全相同
 * （`android_id` / `mac` / `boot_id` / `proc_version` …），
 * 这样 Dart 侧不需要第二套映射表。两套映射迟早会漂移，
 * 而漂移的表现是「某个字段悄悄丢了」，非常难查。
 *
 * ## 读不到就返回 null，不编
 *
 * 每个字段单独 try/catch。权限被拒、ROM 裁剪、SELinux 限制都会让个别字段
 * 读不到——那就在 Map 里不放这个键。**绝不编一个值填进去**：
 * 编出来的值比缺失更容易露。唯一例外是 [baseband]，官方读不到时回
 * 空字符串（`util.java:794-801`），我们照做。
 */
object DeviceProbe {
    /**
     * 构建标识（出现在日志「设备采集: 构建=…」里）。
     *
     * 唯一用途是**自证**：一次真机日志里完全看不到本文件对应的 Dart 侧日志，
     * 只能靠解包 APK 翻 dex 才确认装的是旧包。这种事不该靠猜第二次。
     * 改本文件的采集逻辑时顺手改这个字符串。
     */
    const val BUILD_TAG = "device-probe/2-local-android"


    /** 官方读不到的占位返回值（`util.java:794-801` 的 `"no message"` 分支）。 */
    private const val ABSENT = "no message"

    fun snapshot(context: Context): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()

        put(out, "android_id", androidId(context))
        put(out, "mac", macAddress(context))
        put(out, "wifi_bssid", wifiBssid(context))
        put(out, "wifi_ssid", wifiSsid(context))

        put(out, "model", Build.MODEL)
        put(out, "brand", brand())
        put(out, "product", Build.PRODUCT)
        put(out, "device", Build.DEVICE)
        put(out, "board", Build.BOARD)
        put(out, "bootloader", Build.BOOTLOADER)
        put(out, "fingerprint", Build.FINGERPRINT)

        put(out, "boot_id", bootId())
        put(out, "proc_version", procVersion())
        put(out, "baseband", baseband())

        put(out, "incremental", Build.VERSION.INCREMENTAL)
        put(out, "display", Build.DISPLAY)
        put(out, "release", Build.VERSION.RELEASE)
        put(out, "codename", Build.VERSION.CODENAME)
        out["sdk"] = Build.VERSION.SDK_INT

        put(out, "sim", simOperatorName(context))
        put(out, "apn", apn(context))
        out["os_type"] = "android"

        return out
    }

    /** 值为 null 或空串就不放进 Map——上层用「键不存在」表示「没读到」。 */
    private fun put(map: MutableMap<String, Any?>, key: String, value: String?) {
        if (!value.isNullOrEmpty()) map[key] = value
    }

    private fun androidId(context: Context): String? = runCatching {
        Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
    }.getOrNull()

    /**
     * 品牌。vivo 机器上官方取 `ro.vivo.market.name`（`t.java` 的 `I`/`P` 分支），
     * 因为 `Build.BRAND` 在那些机型上是 `vivo` 而市场名是别的。照做。
     */
    private fun brand(): String? = runCatching {
        val brand = Build.BRAND
        if (brand.equals("vivo", ignoreCase = true)) {
            systemProperty("ro.vivo.market.name") ?: brand
        } else {
            brand
        }
    }.getOrNull()

    /**
     * 反射读 `android.os.SystemProperties.get`。
     *
     * 官方也是反射（`util.java:794-801`），因为这是 `@hide` API。
     * 读不到返回 null。
     */
    private fun systemProperty(key: String): String? = runCatching {
        val clazz = Class.forName("android.os.SystemProperties")
        val get = clazz.getMethod("get", String::class.java, String::class.java)
        val v = get.invoke(null, key, ABSENT) as? String
        if (v == null || v == ABSENT) null else v
    }.getOrNull()

    /**
     * Wi-Fi MAC。Android 6+ 普通应用恒为 `02:00:00:00:00:00`——
     * 这不是失败，这是系统的固定答复，官方客户端读到的也是它。
     */
    @Suppress("DEPRECATION")
    private fun macAddress(context: Context): String? = runCatching {
        val wm = context.applicationContext
            .getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
        wm.connectionInfo?.macAddress
    }.getOrNull()

    /** BSSID，官方会 `toLowerCase()` 后再 MD5（见 `t.java:292-297`）。这里原样返回小写。 */
    @Suppress("DEPRECATION")
    private fun wifiBssid(context: Context): String? = runCatching {
        val wm = context.applicationContext
            .getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
        wm.connectionInfo?.bssid?.lowercase()
    }.getOrNull()

    /** SSID 原文（系统返回是带双引号的，官方不做处理，照发）。 */
    @Suppress("DEPRECATION")
    private fun wifiSsid(context: Context): String? = runCatching {
        val wm = context.applicationContext
            .getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
        wm.connectionInfo?.ssid
    }.getOrNull()

    /**
     * boot_id：内核每次启动生成的随机 UUID。
     *
     * 这是「这台机器这次开机以来有没有换过」的证据，服务端很在意。
     * 合成设备给的是哈希切片拼的 UUID，格式对但语义是假的。
     */
    private fun bootId(): String? = runCatching {
        File("/proc/sys/kernel/random/boot_id").readLines().firstOrNull()?.trim()
    }.getOrNull()

    /** `/proc/version` 首行（0x52D 的 `bytes_version`）。 */
    private fun procVersion(): String? = runCatching {
        File("/proc/version").readLines().firstOrNull()?.trim()
    }.getOrNull()

    /** 基带版本。读不到回空串（官方同行为）。 */
    private fun baseband(): String = systemProperty("gsm.version.baseband") ?: ""

    /** SIM 运营商名（0x124 的 sim 槽）。 */
    private fun simOperatorName(context: Context): String? = runCatching {
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE)
            as? android.telephony.TelephonyManager ?: return null
        tm.simOperatorName
    }.getOrNull()

    /**
     * APN 名：移动网取 `getExtraInfo()`，Wi-Fi 恒为 `"wifi"`（`util.java:635-642`）。
     */
    @Suppress("DEPRECATION")
    private fun apn(context: Context): String? = runCatching {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE)
            as? ConnectivityManager ?: return null
        val info = cm.activeNetworkInfo ?: return "wifi"
        if (info.type == ConnectivityManager.TYPE_WIFI) {
            "wifi"
        } else {
            info.extraInfo ?: "wifi"
        }
    }.getOrNull()

    /** 是否已授予定位权限——BSSID/SSID 依赖它，用来给 Dart 侧解释「为什么这两个字段空着」。 */
    fun hasLocationPermission(context: Context): Boolean = runCatching {
        context.checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
    }.getOrDefault(false)
}
