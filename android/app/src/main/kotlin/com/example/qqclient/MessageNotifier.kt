package com.example.qqclient

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.Person

/**
 * 新消息通知。
 *
 * ## 与 [KeepAliveService] 的分工
 *
 * 那个服务只负责"让进程活着"，唯一一条常驻通知是**状态指示**（IMPORTANCE_LOW、
 * 不可清除）。这里是**事件通知**（IMPORTANCE_HIGH、可划走、点击进会话）。
 * 两者渠道分开、通知 id 分开，互不干扰——[cancelAll] 只撤自己发过的。
 *
 * ## 形态参照 Telegram Android
 *
 * 参考 TMessagesProj/src/main/java/org/telegram/messenger/NotificationsController.java：
 *
 *   * 每个会话一条通知，id 由会话标识派生（:5012
 *     `internalId = (int) dialogId + (int) (dialogId >> 32)`）——这里用
 *     chatId.hashCode()，同样做到"同会话合并、不同会话并存，且不占用固定小号"；
 *   * 通知体用 **MessagingStyle**（:5268-5277、:5642-5656），不是 BigTextStyle。
 *     前者才能把一个会话里的多条消息按"发言人 + 时间"排成对话，群聊里还能显示
 *     会话标题；后者只有一行大文本，看不出谁在什么时候说了什么；
 *   * 多条通知用**分组 + 汇总**（:4646-4647 setGroup/setGroupSummary、
 *     :5675-5676 children 设 GROUP_ALERT_SUMMARY、:5762-5763 发 summary），
 *     避免"三个会话各响一声"；
 *   * 用户划掉通知后不再为同一批旧消息重弹（:4908 dismissDate）——本项目用
 *     Dart 侧的 5 分钟新鲜度窗口达成同样效果（见 notify_policy.dart），
 *     所以这里不做 dismiss 记录。
 *
 * ## 为什么通知 id 用 chatId.hashCode()
 *
 * 同一个会话的多条消息应该合并成一条通知（QQ/微信都是这个行为），
 * 而不是叠成十条。用会话 id 的哈希当通知 id，后一条自动覆盖前一条。
 * 哈希碰撞的代价只是两个会话共用一条通知，不影响消息本身。
 */
object MessageNotifier {

    /** 消息通知渠道。与保活渠道(qqclient.keepalive)刻意分开。 */
    const val CHANNEL_ID = "qqclient.messages"

    /** 通知里携带"要打开哪个会话"。 */
    const val EXTRA_CHAT_ID = "chat_id"

    /** 汇总通知的固定 id，取 1（会话通知 id 是 hash，撞上也只是合并）。 */
    private const val SUMMARY_ID = 1

    /** 分组键：所有会话通知 + 汇总通知同组，系统才会折叠成一个通知组。 */
    private const val GROUP_KEY = "qqclient.messages.group"

    /** 单个会话最多记住多少条（MessagingStyle 展开后能看到的行数）。 */
    private const val MAX_LINES_PER_CHAT = 6

    private class Line(val sender: String, val text: String, val timeMs: Long)

    /** 每个会话最近几条消息，用于 MessagingStyle 展开。key = chatId.hashCode()。 */
    private val history = mutableMapOf<Int, ArrayDeque<Line>>()

    /** 每个会话的最新一条，用于汇总通知里列"哪个会话说了什么"。 */
    private val latest = LinkedHashMap<Int, Pair<String, String>>()

    /** 本对象发过的会话通知 id，用于 [cancelAll] 精确撤销。 */
    private val posted = mutableSetOf<Int>()

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "新消息",
            // IMPORTANCE_HIGH：要横幅 + 声音。这是"有事件发生"，不是状态。
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "收到新消息时提醒"
            enableVibration(true)
            setShowBadge(true)
        }
        manager.createNotificationChannel(channel)
    }

    /**
     * 弹一条（或合并更新）会话通知，并维护汇总通知。
     *
     * @param chatId 会话 id（private_10001 / group_486045673）
     * @param title  会话标题（私聊=对方昵称；群=群名）
     * @param text   正文摘要
     * @param sender 发言人名字（群聊必传；私聊可为空，空时用 title）
     * @param isGroup 是否群聊：决定是否设 conversationTitle 与 groupConversation
     * @param timeMs 消息时间（毫秒）。传 0 则用当前时间
     */
    fun notify(
        context: Context,
        chatId: String,
        title: String,
        text: String,
        sender: String,
        isGroup: Boolean,
        timeMs: Long,
    ) {
        ensureChannel(context)
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val id = chatId.hashCode()
        val at = if (timeMs > 0) timeMs else System.currentTimeMillis()
        // MessagingStyle 用「发言人」而不是会话标题：私聊如果不给，系统会拿消息里的
        // 原始 QQ 号当标题，通知栏就出现一串数字（用户反馈：私聊群聊都显示号码）。
        // 私聊的发言人就是会话对方，直接用 title；群聊用发言人，实在没有就给个中性词。
        val who = if (!isGroup) {
            title
        } else {
            sender.ifEmpty { "群成员" }
        }

        val lines = history.getOrPut(id) { ArrayDeque() }
        lines.addLast(Line(who, text, at))
        while (lines.size > MAX_LINES_PER_CHAT) lines.removeFirst()
        latest[id] = title to text
        posted.add(id)

        val intent = Intent(context, MainActivity::class.java).apply {
            // CLEAR_TOP + SINGLE_TOP：应用已在后台时不再叠一个 Activity 实例。
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_CHAT_ID, chatId)
        }
        val pending = PendingIntent.getActivity(
            context,
            id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        // MessagingStyle 的"我"这一栏；本项目只对收到的消息弹通知，所以用会话标题占位。
        val self = Person.Builder().setName(if (isGroup) title else who).build()
        val style = NotificationCompat.MessagingStyle(self)
        if (isGroup) {
            // 群聊必须给会话标题，否则展开后只有发言人、看不出是哪个群。
            style.setConversationTitle(title)
        }
        style.setGroupConversation(isGroup)
        for (line in lines) {
            style.addMessage(line.text, line.timeMs, Person.Builder().setName(line.sender).build())
        }

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(style)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setWhen(at)
            .setShowWhen(true)
            .setNumber(lines.size)
            .setGroup(GROUP_KEY)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_SUMMARY)
            .setContentIntent(pending)

        manager.notify(id, builder.build())
        notifySummary(context, manager)
    }

    /**
     * 汇总通知。只要还有会话通知就发一条，系统把它当通知组的标题行。
     *
     * 为什么 children 用 GROUP_ALERT_SUMMARY：否则三个会话同时来消息会响三声。
     */
    private fun notifySummary(context: Context, manager: NotificationManager) {
        if (latest.isEmpty()) return
        val style = NotificationCompat.InboxStyle()
        for ((id, pair) in latest) {
            style.addLine(pair.first + "：" + pair.second)
        }
        val count = latest.size
        style.setBigContentTitle(if (count == 1) "1 个会话有新消息" else count.toString() + " 个会话有新消息")

        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val summary = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle("新消息")
            .setContentText(if (count == 1) "1 个会话有新消息" else count.toString() + " 个会话有新消息")
            .setStyle(style)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setGroup(GROUP_KEY)
            .setGroupSummary(true)
            .setContentIntent(open)
            .build()

        manager.notify(SUMMARY_ID, summary)
    }

    /**
     * 撤掉本通道发过的全部通知（会话通知 + 汇总）。
     *
     * **不要用 [NotificationManager.cancelAll]()**：那个会把保活服务的常驻通知一起撤掉，
     * 前台服务还在跑但通知没了，系统会认为状态不一致。
     *
     * 同时清空会话历史：回到前台后用户已经看到消息，下次再弹只该带新的那几条，
     * 不能让上次的旧消息重新出现在 MessagingStyle 里。
     */
    fun cancelAll(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        for (id in posted) manager.cancel(id)
        manager.cancel(SUMMARY_ID)
        posted.clear()
        history.clear()
        latest.clear()
    }

    /** 仅诊断/自测用：当前记住的会话数。 */
    fun debugChatCount(): Int = posted.size
}
