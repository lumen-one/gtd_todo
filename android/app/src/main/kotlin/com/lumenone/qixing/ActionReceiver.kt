package com.lumenone.qixing

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 通知按钮（done / snooze1h）的落地点。
 *
 * 只做两件事：撤销该任务的通知、把 `action` 事件交给 Dart。
 * 刻意不启动 Activity —— 点按钮不应该把用户从当前界面拽走。
 */
class ActionReceiver : BroadcastReceiver() {

    companion object {
        /** PendingIntent 身份的一部分；固定值，避免每次投递产生新 PendingIntent。 */
        const val ACTION_REMINDER_ACTION = "com.lumenone.qixing.action.REMINDER_ACTION"

        const val EXTRA_ACTION_ID = "actionId"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_REMINDER_ACTION) return
        val app = context.applicationContext
        val taskId = intent.getStringExtra(ReminderExtras.TASK_ID)
        val actionId = intent.getStringExtra(EXTRA_ACTION_ID)
        if (taskId.isNullOrEmpty() || actionId.isNullOrEmpty()) {
            Log.w("gtd", "ActionReceiver missing taskId/actionId, ignored")
            return
        }
        try {
            Notifier.cancel(app, taskId)
            Log.i("gtd", "action=$actionId taskId=$taskId")
            NativeEventQueue.publish(
                app,
                mapOf("type" to "action", "actionId" to actionId, "taskId" to taskId),
            )
        } catch (t: Throwable) {
            Log.w("gtd", "action handling failed: ${t.message}", t)
        }
    }
}
