package com.example.qqclient

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 唯一的原生入口。除了 Flutter 默认行为，只多一件事：
 * 把「后台保活」暴露成 `MethodChannel('qqclient/keepalive')`。
 *
 * ## 为什么原生代码这么少
 *
 * 这个项目是纯 Dart 实现，协议、存储、UI 全在 Dart 侧。原生只承担
 * **Dart 做不到的事**——而"前台服务"恰好是其中之一（需要 Android
 * 的 Service 生命周期与通知渠道，Dart 没有对应 API）。
 *
 * 除此之外不要再往这里加东西：每加一处原生代码，就多一处
 * 无法用 `dart run tool/xxx_selftest.dart` 覆盖的地方。
 *
 * ## 权限申请为什么要回传结果
 *
 * Android 13+ 的 `POST_NOTIFICATIONS` 是**运行时**权限，弹框是异步的。
 * 如果不回传结果，Dart 侧就无法知道用户点了"允许"还是"拒绝"，
 * 也就无法决定"要不要提示用户去设置里开"。所以这里用
 * [pendingPermissionResult] 挂起 MethodChannel 的 result，等
 * `onRequestPermissionsResult` 回来再完成它。
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "qqclient/keepalive"

        /** 设备信息通道（见 [DeviceProbe]）。 */
        private const val DEVICE_CHANNEL = "qqclient/device"

        /** 通知权限请求码。任意值，只要与别处不冲突。 */
        private const val REQUEST_NOTIFICATIONS = 0x5101
    }

    /** 等待系统权限对话框结果的 MethodChannel result；null 表示没有挂起的请求。 */
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val title = call.argument<String>("title") ?: "保持连接"
                        val text = call.argument<String>("text") ?: "正在后台保持消息连接"
                        try {
                            KeepAliveService.start(this, title, text)
                            result.success(null)
                        } catch (e: Exception) {
                            // Android 12+ 的后台启动限制会在这里抛
                            // ForegroundServiceStartNotAllowedException。
                            // 回传错误让 Dart 侧记日志——但 Dart 侧不该因此崩溃，
                            // 连接本身还在，只是可能在后台被回收。
                            result.error("start_failed", e.message, e.javaClass.simpleName)
                        }
                    }

                    "stop" -> {
                        try {
                            KeepAliveService.stop(this)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("stop_failed", e.message, e.javaClass.simpleName)
                        }
                    }

                    "isRunning" -> result.success(KeepAliveService.isRunning)

                    "ensurePermission" -> ensureNotificationPermission(result)

                    else -> result.notImplemented()
                }
            }

        // 设备信息通道。刻意与保活分成两个 channel：
        // 两者生命周期完全无关（保活是常驻状态机，设备信息是一次性只读），
        // 合在一起会让「只想读一次设备」也必须先经过保活的状态判断。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "version" ->
                        // 构建标识（人类可读单行）。保留这个老方法名，
                        // 因为 Dart 侧 `DeviceInfo.buildTag` 已经在用。
                        result.success(DeviceProbe.BUILD_TAG)

                    "buildInfo" ->
                        // 结构化构建信息，供日志导出抬头使用。
                        // 与 "version" 的区别只在形态：那个是给人看的单行，
                        // 这个是给 `LogExporter.buildReport(metadata:)` 用的键值对。
                        result.success(buildInfo())

                    "snapshot" -> {
                        try {
                            result.success(DeviceProbe.snapshot(this))
                        } catch (e: Exception) {
                            // 采集整体失败（极罕见）：回 null，Dart 侧据此退回合成派生。
                            result.success(null)
                        }
                    }

                    "hasLocationPermission" ->
                        result.success(DeviceProbe.hasLocationPermission(this))

                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 构建信息。**这是排障的第一手证据**。
     *
     * 起因：有四次提交都没改过 `DeviceProbe.BUILD_TAG`，真机日志里那一行长得
     * 一模一样，我无法判断装的是哪一版，只好解包 APK 翻 dex。这种事不该做第二次。
     *
     * 字段说明：
     * * `app_version` —— `pubspec.yaml` 的 version（`0.1.0+1` 形态），
     *   用户报障时最容易对上的一条；
     * * `git_commit` —— 构建时的提交号，带 `+dirty` 表示工作区有未提交改动；
     * * `build_time` —— 构建时刻（本地时区，精确到秒）；
     * * `api_host` —— 编译进包里的登录服务器，排查 DNS/网络问题时必需，
     *   否则无法区分「服务器换过」和「网络挂了」。
     */
    private fun buildInfo(): Map<String, String> = linkedMapOf(
        "app_version" to BuildConfig.APP_VERSION,
        "git_commit" to BuildConfig.GIT_COMMIT,
        "build_time" to BuildConfig.BUILD_TIME,
        "api_host" to BuildConfig.API_HOST,
        "probe_version" to DeviceProbe.PROBE_VERSION,
    )

    private fun ensureNotificationPermission(result: MethodChannel.Result) {
        // Android 13 以下没有这个运行时权限，直接算已授予。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        // 上一次请求还没回来就再来一次：不复用挂起状态，直接回 false。
        // 理由：MethodChannel 的 result 只能完成一次，覆盖会让前一个永远不完成，
        // 在 Dart 侧表现为那个 Future 永不 resolve（比返回 false 糟得多）。
        if (pendingPermissionResult != null) {
            result.success(false)
            return
        }
        pendingPermissionResult = result
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_NOTIFICATIONS) return
        val result = pendingPermissionResult ?: return
        pendingPermissionResult = null
        result.success(
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        )
    }
}
