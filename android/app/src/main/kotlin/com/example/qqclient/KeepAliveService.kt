package com.example.qqclient

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * 前台服务：把进程钉在「用户知道它在跑」的状态，避免后台被系统回收。
 *
 * ## 为什么必须是前台服务
 *
 * Android 6.0 起对后台进程有明确的回收策略：应用一进后台就开始倒计时，
 * 到点直接杀进程。进程一没，Dart 隔离区就没了，WebSocket 自然断。
 * 唯一不违反系统规则的做法是 `startForeground`——带一条常驻通知，
 * 系统就按「用户可见的正在运行的服务」对待它。
 *
 * ## 这个服务不干任何业务
 *
 * 它**不**持有连接、**不**跑网络、**不**碰 Dart。真正保活的是
 * 「进程没被杀」这件事本身——Dart 隔离区一直在跑，WebSocket 一直在收。
 * 服务唯一的作用是让系统别杀这个进程。
 *
 * 这一点很重要：如果哪天要给消息加通知，那属于另一个服务/另一处逻辑，
 * 不要把业务塞进来。
 */
class KeepAliveService : Service() {

    companion object {
        /** 通知渠道 id。渠道一旦创建，其重要性就不能再改——改名要换 id。 */
        private const val CHANNEL_ID = "qqclient.keepalive"

        /** 固定通知 id。固定值保证重复 start 时不会堆出多条通知。 */
        private const val NOTIFICATION_ID = 0x5100

        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"

        /**
         * 服务是否在跑。
         *
         * 为什么不查 `ActivityManager.getRunningServices`：那个 API 从 API 21 起
         * 对第三方应用只返回**自己**的服务，从 API 26 起更是被限制成
         * "只有自己"。既然我们本来就只关心自己，维护一个静态标志既准确
         * 又不受系统版本行为差异影响。
         *
         * 它是 `@Volatile`：写在主线程（Service 回调），读来自 Dart 侧的
         * MethodChannel 调用（同样在主线程），跨线程可见性在这里是必需的。
         */
        @Volatile
        var isRunning: Boolean = false
            private set

        /**
         * 启动服务。
         *
         * `startForegroundService` 是 API 26+ 才有的；低于它直接 `startService`
         * 即可（那时前台服务概念还没引入，`startForeground` 照样能用）。
         *
         * Android 12+ 对「从后台启动前台服务」有限制，会抛
         * `ForegroundServiceStartNotAllowedException`。调用方（MainActivity）
         * 负责捕获——**在这里捕获会丢掉"服务没起来"这个事实**，而调用方需要
         * 知道失败以决定要不要重试或降级。
         */
        fun start(context: Context, title: String, text: String) {
            val intent = Intent(context, KeepAliveService::class.java).apply {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, KeepAliveService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "保持连接"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "正在后台保持消息连接"

        // 必须先建渠道再 startForeground，否则 API 26+ 会抛
        // IllegalArgumentException（通知没有渠道 = 不合法通知）。
        ensureChannel()

        val notification = buildNotification(title, text)
        // 前台服务类型必须与 manifest 的 `foregroundServiceType` 对得上，
        // 否则系统会按「类型不匹配」直接杀服务。这里按 API 等级分三档：
        //
        //   API 34+  remoteMessaging —— 「设备之间传递文本消息」，语义正是聊天。
        //            **关键**：Android 15 起 dataSync 类型的服务有 6 小时/24 小时
        //            的累计时长上限，到点系统会强停。聊天客户端要常驻，不能用它。
        //   API 29+  dataSync —— 那时 remoteMessaging 还不存在；29~33 上
        //            dataSync 没有时长限制，是当时唯一合适的选择。
        //   API <29  不传类型 —— 前台服务类型这个概念还没引入。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING,
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // START_NOT_STICKY 而不是 START_STICKY。
        //
        // 这个服务与 Flutter 引擎**同进程**，真正干活的是 Dart 隔离区里的
        // WebSocket。进程被杀 = 服务被杀 = Dart 也一起没了。如果这里用
        // START_STICKY，系统会重建服务——但那是一个**没有 Flutter 引擎的新进程**，
        // 结果是一条"正在保持连接"的通知挂在那儿，后面什么都没有。
        // 僵尸通知比没有通知更糟：用户以为连接还在，实际收不到任何消息。
        //
        // 所以正确的恢复路径是"用户重新打开应用"，而不是让系统拉起一个空壳。
        isRunning = true
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        // 显式撤掉通知：stopService 在某些 ROM 上不会自动清通知，
        // 留下一条"正在保持连接"的僵尸通知比没有更糟。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "后台连接",
            // IMPORTANCE_LOW：不要提示音、不要横幅。这是一条"状态指示"，
            // 不是通知——用户不应该被自己的保活服务打扰。
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "保持消息连接时显示"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(title: String, text: String): Notification {
        // 点通知回到应用。用 LAUNCHER intent 而不是自建 Activity，
        // 保证行为与点桌面图标完全一致（不会叠出第二个任务栈）。
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setOngoing(true)          // 不可滑动清除——它是服务状态的指示
            .setShowWhen(false)        // 不显示时间戳：它不是事件
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(contentIntent)
            .build()
    }
}
