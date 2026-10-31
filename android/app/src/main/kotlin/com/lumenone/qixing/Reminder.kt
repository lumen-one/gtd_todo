package com.lumenone.qixing

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
    val channel: ReminderChannel,
    val fullScreen: Boolean,
    val actions: List<ReminderAction>,
)

/**
 * 通知渠道三档（与 Dart 侧 `ReminderChannel` 同名同序）：
 * - [RING] 有声 + 震动，IMPORTANCE_HIGH（横幅必现）；
 * - [SILENT] 同样 IMPORTANCE_HIGH、横幅照弹，但没有声音与震动；
 * - [ALARM] 全屏 + 持续响铃，只在设置页开了『闹钟模式』的时点提醒上用。
 */
enum class ReminderChannel {
    RING, SILENT, ALARM;

    companion object {
        /** Dart 传的是枚举名（ring / silent / alarm）；认不出按有声走。 */
        fun fromName(name: String?): ReminderChannel = when (name) {
            "silent" -> SILENT
            "alarm" -> ALARM
            else -> RING
        }
    }
}

/** 通知按钮：id 回到 Dart（`done` / `snooze1h`），label 只用于显示。 */
data class ReminderAction(val id: String, val label: String)

/** Intent extras 的键名集中在此，避免收发两端写错字符串。 */
object ReminderExtras {
    const val TASK_ID = "taskId"
    const val TITLE = "title"
    const val BODY = "body"
    const val CHANNEL = "channel"
    const val FULL_SCREEN = "fullScreen"
    const val ACTION_IDS = "actionIds"
    const val ACTION_LABELS = "actionLabels"
}
