package com.example.gtd_todo

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.util.Log

/**
 * 系统闹钟到点时的落地点（进程可能完全没起来）。
 *
 * 职责：投递通知 → 给 Dart 发 `alarmFired` 事件。不重排任何闹钟。
 */
class ReminderReceiver : BroadcastReceiver() {

    companion object {
        /** 空闲闹钟用的固定 action，是 PendingIntent 身份的一部分（见 alarmIntent）。 */
        const val ACTION_REMINDER_ALARM = "com.example.gtd_todo.action.REMINDER_ALARM"

        /** 通知按钮的 requestCode 派生规则，Dart 侧不需要知道，但必须与 Notifier 一致。 */
        fun actionRequestCode(taskId: String, index: Int): Int {
            var code = 31 * taskId.hashCode() + index
            // 与闹钟的 requestCode 0 错开，避免 PendingIntent "身份"撞车。
            if (code == 0) code = 1
            return code
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_REMINDER_ALARM) return
        val app = context.applicationContext
        val reminder = reminderFromIntent(intent)
        if (reminder.taskId.isEmpty()) {
            Log.w("gtd", "ReminderReceiver got an alarm without taskId, ignored")
            return
        }

        // 闹钟唤醒瞬间拿一段短 wakelock，确保通知真的投递出去。
        val wakeLock = acquireWakeLock(app)
        try {
            val posted = Notifier.post(app, reminder)
            Log.i("gtd", "alarm fired taskId=${reminder.taskId} posted=$posted")
            NativeEventQueue.publish(app, mapOf("type" to "alarmFired", "taskId" to reminder.taskId))
        } catch (t: Throwable) {
            Log.w("gtd", "alarm handling failed: ${t.message}", t)
        } finally {
            releaseWakeLock(wakeLock)
        }
    }

    private fun acquireWakeLock(context: Context): PowerManager.WakeLock? = try {
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        power?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "gtd:reminder")?.apply {
            setReferenceCounted(false)
            acquire(10_000L)
        }
    } catch (t: Throwable) {
        Log.w("gtd", "wakelock acquire failed: ${t.message}")
        null
    }

    private fun releaseWakeLock(lock: PowerManager.WakeLock?) {
        try {
            if (lock != null && lock.isHeld) lock.release()
        } catch (_: Throwable) {
            // 忽略：wakelock 释放失败不影响通知已经投递的事实。
        }
    }
}
