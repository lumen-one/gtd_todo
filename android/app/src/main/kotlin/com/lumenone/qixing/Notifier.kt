package com.lumenone.qixing

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * 系统通知的唯一出口：闹钟触发（[ReminderReceiver]）与立即预览
 * （`showNotification`）都经由这里投递。
 *
 * 设计要点（与 Dart 侧契约一致）：
 * - 通知 id = taskId.hashCode()，同一任务重复投递是"替换"而非"堆叠"；
 * - 两个渠道在首次使用时创建：gtd_normal（默认）/ gtd_alarm（高优先级 + 震动）；
 * - 未授予 POST_NOTIFICATIONS 时 [post] 返回 false，绝不抛异常。
 */
object Notifier {

    const val CHANNEL_RING = "gtd_ring"
    const val CHANNEL_SILENT = "gtd_silent"
    const val CHANNEL_ALARM = "gtd_alarm"
    const val CHANNEL_OVERLAY = "gtd_overlay"

    /** 旧版本的普通通知渠道：渠道属性（重要性、声音）建完就不可改，只能删掉换新 id。 */
    private const val CHANNEL_LEGACY_NORMAL = "gtd_normal"

    private const val CHANNEL_RING_NAME = "任务提醒"
    private const val CHANNEL_SILENT_NAME = "任务提醒（静音）"
    private const val CHANNEL_ALARM_NAME = "闹钟提醒"
    private const val CHANNEL_OVERLAY_NAME = "悬浮手柄"

    /** 悬浮手柄常驻通知用固定 id（与任务通知的 hashCode 空间不冲突的负数）。 */
    const val OVERLAY_NOTIFICATION_ID = -0x0F10

    private val VIBRATION_PATTERN = longArrayOf(0L, 400L, 200L, 400L)

    /** 通知 id 的稳定映射：跨进程重启后仍是同一任务同一 id。 */
    fun notificationId(taskId: String): Int = taskId.hashCode()

    /** 渠道创建是幂等的，可以每次投递前都调一次。 */
    fun ensureChannels(context: Context, overlay: Boolean = false) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        val app = context.applicationContext

        // 旧渠道删掉：留着会让系统设置里出现两个"任务提醒"，而且旧的 IMPORTANCE_DEFAULT
        // 不弹横幅。删频道会连带清掉用户在上面调过的手动设置，这是渠道不可变的代价。
        manager.deleteNotificationChannel(CHANNEL_LEGACY_NORMAL)

        // 有声：IMPORTANCE_HIGH = 横幅必现；声音 + 震动都挂在渠道上。
        if (manager.getNotificationChannel(CHANNEL_RING) == null) {
            val channel = NotificationChannel(CHANNEL_RING, CHANNEL_RING_NAME, NotificationManager.IMPORTANCE_HIGH)
            channel.enableVibration(true)
            channel.vibrationPattern = VIBRATION_PATTERN
            channel.setShowBadge(true)
            channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            val audio = AudioAttributes.Builder()
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .build()
            channel.setSound(android.provider.Settings.System.DEFAULT_NOTIFICATION_URI, audio)
            manager.createNotificationChannel(channel)
        }
        // 静音：同一个重要性（横幅照弹），但没有声音与震动。
        if (manager.getNotificationChannel(CHANNEL_SILENT) == null) {
            val channel = NotificationChannel(CHANNEL_SILENT, CHANNEL_SILENT_NAME, NotificationManager.IMPORTANCE_HIGH)
            channel.enableVibration(false)
            channel.setSound(null, null)
            channel.setShowBadge(true)
            channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            manager.createNotificationChannel(channel)
        }
        if (manager.getNotificationChannel(CHANNEL_ALARM) == null) {
            val channel = NotificationChannel(CHANNEL_ALARM, CHANNEL_ALARM_NAME, NotificationManager.IMPORTANCE_HIGH)
            channel.enableVibration(true)
            channel.vibrationPattern = VIBRATION_PATTERN
            channel.setShowBadge(true)
            channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            val audio = AudioAttributes.Builder()
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(AudioAttributes.USAGE_ALARM)
                .build()
            channel.setSound(android.provider.Settings.System.DEFAULT_ALARM_ALERT_URI, audio)
            manager.createNotificationChannel(channel)
        }
        // 悬浮手柄的常驻通知必须是最低打扰：静音、不震动、不打扰锁屏。
        if (overlay && manager.getNotificationChannel(CHANNEL_OVERLAY) == null) {
            val channel = NotificationChannel(CHANNEL_OVERLAY, CHANNEL_OVERLAY_NAME, NotificationManager.IMPORTANCE_MIN)
            channel.setShowBadge(false)
            channel.enableVibration(false)
            channel.lockscreenVisibility = Notification.VISIBILITY_SECRET
            manager.createNotificationChannel(channel)
        }
    }

    /** 悬浮手柄前台服务的常驻通知（低优先级、无声音、不可划走）。 */
    fun buildOverlayNotification(context: Context): Notification {
        ensureChannels(context, overlay = true)
        val contentIntent = PendingIntent.getActivity(
            context,
            0x0F10,
            Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra(MainActivity.EXTRA_OPEN_PANEL, true)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(context, CHANNEL_OVERLAY)
            .setSmallIcon(R.drawable.ic_notify_star)
            .setContentTitle("启行")
            .setContentText("悬浮手柄已开启，点按可打开面板")
            .setContentIntent(contentIntent)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .build()
    }

    /**
     * 投递（或替换）一条任务通知。
     *
     * @return 真正交给系统返回 true；缺权限、渠道被禁用等软失败返回 false。
     */
    fun post(context: Context, reminder: Reminder): Boolean = try {
        ensureChannels(context)
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) {
            false
        } else {
            manager.notify(notificationId(reminder.taskId), build(context, reminder))
            true
        }
    } catch (_: Throwable) {
        // 任何厂商 ROM 的 SecurityException / 引擎异常都不应打断闹钟链路。
        false
    }

    fun cancel(context: Context, taskId: String): Boolean = try {
        NotificationManagerCompat.from(context).cancel(notificationId(taskId))
        true
    } catch (_: Throwable) {
        false
    }

    private fun build(context: Context, reminder: Reminder): Notification {
        val alarm = reminder.channel == ReminderChannel.ALARM
        val channelId = when (reminder.channel) {
            ReminderChannel.ALARM -> CHANNEL_ALARM
            ReminderChannel.SILENT -> CHANNEL_SILENT
            ReminderChannel.RING -> CHANNEL_RING
        }
        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_notify_star)
            .setContentTitle(reminder.title)
            .setContentText(reminder.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(reminder.body ?: reminder.title))
            .setAutoCancel(true)
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)

        // 内容点击 → MainActivity，带 focusTaskId 供 Dart 定位任务。
        // 注意：这里刻意不写 actionId，避免与 ActionReceiver 的语义混淆。
        val contentIntent = PendingIntent.getActivity(
            context,
            notificationId(reminder.taskId),
            Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra(MainActivity.EXTRA_FOCUS_TASK_ID, reminder.taskId)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        builder.setContentIntent(contentIntent)

        if (alarm) {
            builder.setCategory(NotificationCompat.CATEGORY_ALARM)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setOngoing(true)
                .setDefaults(NotificationCompat.DEFAULT_ALL)
            // 震动由 gtd_alarm 渠道承载（O+）；低版本由 setDefaults 兜底。
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                builder.setVibrate(VIBRATION_PATTERN)
            }
            if (reminder.fullScreen && canUseFullScreenIntent(context)) {
                builder.setFullScreenIntent(contentIntent, true)
            }
        } else {
            // 横幅靠渠道重要性（O+）；O 以下靠 PRIORITY_HIGH。静音那条只掐声音与震动。
            builder.setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
            if (reminder.channel == ReminderChannel.SILENT) {
                builder.setSilent(true).setDefaults(0)
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    builder.setVibrate(longArrayOf(0L))
                }
            } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                builder.setDefaults(NotificationCompat.DEFAULT_ALL)
                builder.setVibrate(VIBRATION_PATTERN)
            }
        }

        reminder.actions.forEachIndexed { index, action ->
            val actionIntent = PendingIntent.getBroadcast(
                context,
                ReminderReceiver.actionRequestCode(reminder.taskId, index),
                Intent(context, ActionReceiver::class.java).apply {
                    // 固定 action 串，保证 PendingIntent 身份稳定（extras 不参与匹配）。
                    setAction(ActionReceiver.ACTION_REMINDER_ACTION)
                    putExtra(ReminderExtras.TASK_ID, reminder.taskId)
                    putExtra(ActionReceiver.EXTRA_ACTION_ID, action.id)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.addAction(0, action.label, actionIntent)
        }
        return builder.build()
    }

    /** Android 14 起全屏意图成为可选权限，未授予时只能退化成普通通知。 */
    fun canUseFullScreenIntent(context: Context): Boolean =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            true
        } else {
            try {
                val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.canUseFullScreenIntent()
            } catch (_: Throwable) {
                false
            }
        }
}
