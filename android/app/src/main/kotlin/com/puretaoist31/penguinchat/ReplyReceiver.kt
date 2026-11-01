package com.puretaoist31.penguinchat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput

/**
 * 通知栏「直接回复」的接收端。
 *
 * 用户长按/展开消息通知，在输入框里打字点发送后，系统会把文字塞进
 * [RemoteInput] 的结果里，然后发一条广播到这里。
 *
 * ## 只支持"进程还活着"的场景
 *
 * 我们的连接跑在 Dart 侧（Flutter 引擎里）。进程活着 ⇒ Dart 通道在 ⇒ 这条回复
 * 能立刻发出去；进程已被系统回收 ⇒ 通知早就没了，不会有广播。所以这里不做
 * 持久化队列，也不在失败时偷偷重试（那会给用户发出"隔天突然后悔"的消息）。
 *
 * ## 成功/失败都要收尾
 *
 * 系统在等待结果期间会让通知显示"正在发送"。不管发送成功与否，都必须
 * 撤销/替换那条通知，否则通知栏会一直转圈。
 */
class ReplyReceiver : BroadcastReceiver() {

    companion object {
        /** RemoteInput 的结果键。与 MessageNotifier 里 Builder 用的必须一致。 */
        const val KEY_REPLY_TEXT = "reply_text"

        /** 通知里带过来的会话 id。 */
        const val EXTRA_CHAT_ID = "chat_id"

        /** 广播 action，仅用于日志辨识。 */
        const val ACTION_REPLY = "com.puretaoist31.penguinchat.action.REPLY"

        /**
         * 由 [MainActivity] 在通道就绪时注册的"投递给 Dart"回调。
         *
         * 返回 false 表示通道不在（引擎已死/未就绪）——此时回复发不出去。
         * 用 @Volatile 是因为广播回调在 binder 线程，而注册在主线程。
         */
        @Volatile
        var dispatcher: ((String, String) -> Boolean)? = null
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_REPLY) return
        val results = RemoteInput.getResultsFromIntent(intent) ?: return
        val text = results.getCharSequence(KEY_REPLY_TEXT)?.toString()?.trim().orEmpty()
        val chatId = intent.getStringExtra(EXTRA_CHAT_ID).orEmpty()
        if (text.isEmpty() || chatId.isEmpty()) return

        val dispatched = try {
            dispatcher?.invoke(chatId, text) ?: false
        } catch (t: Throwable) {
            false
        }

        if (dispatched) {
            // 撤回该会话的通知：回复已提交，通知里那批旧消息没必要继续占位。
            MessageNotifier.cancelChat(context, chatId)
        } else {
            MessageNotifier.showReplyFailed(context, chatId, text)
        }
    }
}
