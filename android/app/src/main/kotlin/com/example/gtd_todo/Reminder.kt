package com.example.gtd_todo

/**
 * 一条提醒的全部渲染数据（原生侧 DTO）。
 *
 * 由 MethodChannel `gtd/native` 的 scheduleAlarm / showNotification 参数构造，
 * 经 PendingIntent extras 在闹钟触发时原样传给 [ReminderReceiver]。
 * Dart 侧会持续发相同字段，这里只做搬运，不做业务判断。
 */
data class Reminder(
    val taskId: String,
    val title: String,
    val body: String?,
    val alarmChannel: Boolean,
    val fullScreen: Boolean,
    val actions: List<ReminderAction>,
)

/** 通知按钮：id 回到 Dart（`done` / `snooze1h`），label 只用于显示。 */
data class ReminderAction(val id: String, val label: String)

/** Intent extras 的键名集中在此，避免收发两端写错字符串。 */
object ReminderExtras {
    const val TASK_ID = "taskId"
    const val TITLE = "title"
    const val BODY = "body"
    const val ALARM_CHANNEL = "alarmChannel"
    const val FULL_SCREEN = "fullScreen"
    const val ACTION_IDS = "actionIds"
    const val ACTION_LABELS = "actionLabels"
}
